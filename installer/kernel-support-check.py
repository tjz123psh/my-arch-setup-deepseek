#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any


@dataclass(frozen=True)
class KernelSpec:
    package: str
    header_package: str


@dataclass(frozen=True)
class ProfilePolicy:
    required_kernels: frozenset[str]
    require_supported_kernel: bool
    require_nvidia_dkms: bool


KERNEL_SPECS = (
    KernelSpec("linux", "linux-headers"),
    KernelSpec("linux-zen", "linux-zen-headers"),
)
PROFILE_POLICIES = {
    "asus-amd-nvidia": ProfilePolicy(frozenset({"linux", "linux-zen"}), True, True),
    "desktop-amd": ProfilePolicy(frozenset(), True, False),
    "vm": ProfilePolicy(frozenset(), True, False),
}
NVIDIA_PACKAGE = "nvidia-open-dkms"
NVIDIA_DKMS_MODULE = "nvidia"
PACKAGE_NOT_FOUND = re.compile(r"^error: package '[a-z0-9@._+:-]+' was not found$")
MODULE_PATH = re.compile(r"^/usr/lib/modules/([A-Za-z0-9._+:-]+)/")
DKMS_LINE = re.compile(
    r"^(?P<module>[A-Za-z0-9._+:-]+)/(?P<version>[^,\s]+),\s+"
    r"(?P<kernel>[A-Za-z0-9._+:-]+),\s+"
    r"(?P<arch>[A-Za-z0-9._+:-]+):\s+(?P<state>.+)$"
)
SAFE_RELEASE = re.compile(r"^[A-Za-z0-9._+:-]+$")
QUERY_FAILURE_STATES = {"unavailable", "query-failed", "parse-failed"}


@dataclass(frozen=True)
class CommandResult:
    status: str
    query_exit: int | None
    stdout: str
    stderr: str


def command_result(name: str, *arguments: str) -> CommandResult:
    executable = shutil.which(name)
    if executable is None:
        return CommandResult("unavailable", None, "", "")
    environment = os.environ.copy()
    environment["LC_ALL"] = "C"
    environment["LANG"] = "C"
    try:
        result = subprocess.run(
            [executable, *arguments],
            check=False,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=environment,
            timeout=15,
        )
    except (OSError, subprocess.TimeoutExpired):
        return CommandResult("query-failed", None, "", "")
    return CommandResult("executed", result.returncode, result.stdout, result.stderr)


def package_query(package: str) -> dict[str, Any]:
    result = command_result("pacman", "-Q", package)
    record: dict[str, Any] = {
        "status": result.status,
        "version": None,
        "query_exit": result.query_exit,
    }
    if result.status != "executed":
        return record
    if result.query_exit == 0:
        lines = [line for line in result.stdout.splitlines() if line]
        if len(lines) != 1:
            record["status"] = "parse-failed"
            return record
        parts = lines[0].split(maxsplit=1)
        if len(parts) != 2 or parts[0] != package or not parts[1]:
            record["status"] = "parse-failed"
            return record
        record["status"] = "installed"
        record["version"] = parts[1]
        return record
    if result.query_exit == 1:
        diagnostic = result.stderr.strip()
        if PACKAGE_NOT_FOUND.fullmatch(diagnostic) is not None:
            record["status"] = "missing"
        else:
            record["status"] = "query-failed"
        return record
    record["status"] = "query-failed"
    return record


def kernel_release_query(package: str) -> dict[str, Any]:
    result = command_result("pacman", "-Qql", package)
    record: dict[str, Any] = {
        "status": result.status,
        "query_exit": result.query_exit,
        "releases": [],
    }
    if result.status != "executed":
        return record
    if result.query_exit != 0:
        record["status"] = "query-failed"
        return record
    releases = sorted(
        {
            match.group(1)
            for line in result.stdout.splitlines()
            if (match := MODULE_PATH.match(line)) is not None
        }
    )
    if not releases:
        record["status"] = "parse-failed"
        return record
    record["status"] = "ok"
    record["releases"] = releases
    return record


def running_release_query() -> dict[str, Any]:
    result = command_result("uname", "-r")
    record: dict[str, Any] = {
        "status": result.status,
        "value": None,
        "query_exit": result.query_exit,
    }
    if result.status != "executed":
        return record
    if result.query_exit != 0:
        record["status"] = "query-failed"
        return record
    lines = [line for line in result.stdout.splitlines() if line]
    if len(lines) != 1 or SAFE_RELEASE.fullmatch(lines[0]) is None:
        record["status"] = "parse-failed"
        return record
    record["status"] = "ok"
    record["value"] = lines[0]
    return record


def modules_inventory(modules_root: Path) -> dict[str, Any]:
    record: dict[str, Any] = {
        "status": "ok",
        "releases": [],
        "unparsed_entry_count": 0,
    }
    try:
        entries = list(modules_root.iterdir())
    except OSError:
        record["status"] = "query-failed"
        return record
    releases: list[str] = []
    unparsed = 0
    for entry in entries:
        if not entry.is_dir():
            continue
        if SAFE_RELEASE.fullmatch(entry.name) is None:
            unparsed += 1
            continue
        releases.append(entry.name)
    record["releases"] = sorted(releases)
    record["unparsed_entry_count"] = unparsed
    if unparsed:
        record["status"] = "parse-failed"
    return record


def dkms_query(required: bool) -> dict[str, Any]:
    if not required:
        return {
            "status": "not-applicable",
            "query_exit": None,
            "empty_result": None,
            "entry_count": 0,
            "unparsed_line_count": 0,
            "entries": [],
        }
    result = command_result("dkms", "status")
    record: dict[str, Any] = {
        "status": result.status,
        "query_exit": result.query_exit,
        "empty_result": None,
        "entry_count": 0,
        "unparsed_line_count": 0,
        "entries": [],
    }
    if result.status != "executed":
        return record
    if result.query_exit != 0:
        record["status"] = "query-failed"
        return record
    lines = [line for line in result.stdout.splitlines() if line.strip()]
    entries: list[dict[str, str]] = []
    unparsed = 0
    for line in lines:
        match = DKMS_LINE.fullmatch(line.strip())
        if match is None:
            unparsed += 1
            continue
        entries.append(match.groupdict())
    record["entries"] = entries
    record["entry_count"] = len(entries)
    record["unparsed_line_count"] = unparsed
    record["empty_result"] = not lines
    record["status"] = "parse-failed" if unparsed else "ok"
    return record


def check(status: str, detail: str) -> dict[str, str]:
    return {"status": status, "detail": detail}


def unavailable_status(*states: str) -> bool:
    return any(state in QUERY_FAILURE_STATES for state in states)


def build_report(profile: str, modules_root: Path) -> dict[str, Any]:
    policy = PROFILE_POLICIES[profile]
    package_names = [item for spec in KERNEL_SPECS for item in (spec.package, spec.header_package)]
    if policy.require_nvidia_dkms:
        package_names.append(NVIDIA_PACKAGE)
    packages = {package: package_query(package) for package in package_names}

    module_inventory = modules_inventory(modules_root)
    running_release = running_release_query()
    kernels: list[dict[str, Any]] = []
    detected_releases: list[str] = []

    for spec in KERNEL_SPECS:
        package = packages[spec.package]
        header = packages[spec.header_package]
        release_query: dict[str, Any]
        if package["status"] == "installed":
            release_query = kernel_release_query(spec.package)
        else:
            release_query = {"status": "not-run", "query_exit": None, "releases": []}
        releases = list(release_query["releases"])
        detected_releases.extend(releases)
        builds = []
        for release in releases:
            try:
                present = (modules_root / release / "build").is_dir()
            except OSError:
                present = False
            builds.append({"release": release, "present": present})
        version_match: bool | None = None
        if package["status"] == "installed" and header["status"] == "installed":
            version_match = package["version"] == header["version"]
        kernels.append(
            {
                "package": spec.package,
                "required": spec.package in policy.required_kernels,
                "package_status": package["status"],
                "version": package["version"],
                "header_package": spec.header_package,
                "header_status": header["status"],
                "header_version": header["version"],
                "header_version_match": version_match,
                "release_query_status": release_query["status"],
                "release_query_exit": release_query["query_exit"],
                "module_releases": releases,
                "build_directories": builds,
            }
        )

    dkms = dkms_query(policy.require_nvidia_dkms)
    checks: dict[str, dict[str, str]] = {}

    package_failures = [name for name, item in packages.items() if item["status"] in QUERY_FAILURE_STATES]
    checks["package-queries"] = (
        check("unavailable", "one or more local package queries failed")
        if package_failures
        else check("pass", "all requested local package queries completed")
    )

    required_records = [kernel for kernel in kernels if kernel["required"]]
    if not required_records:
        checks["required-kernel-packages"] = check("not-applicable", "profile detects rather than mandates kernel packages")
    elif any(kernel["package_status"] in QUERY_FAILURE_STATES for kernel in required_records):
        checks["required-kernel-packages"] = check("unavailable", "required kernel package state is unavailable")
    elif any(kernel["package_status"] != "installed" for kernel in required_records):
        checks["required-kernel-packages"] = check("fail", "one or more required kernel packages are missing")
    else:
        checks["required-kernel-packages"] = check("pass", "all required kernel packages are installed")

    installed_kernels = [kernel for kernel in kernels if kernel["package_status"] == "installed"]
    kernel_query_unavailable = any(kernel["package_status"] in QUERY_FAILURE_STATES for kernel in kernels)
    if installed_kernels:
        checks["supported-kernel-present"] = check("pass", "at least one supported kernel package is installed")
    elif kernel_query_unavailable:
        checks["supported-kernel-present"] = check("unavailable", "supported kernel presence could not be determined")
    elif policy.require_supported_kernel:
        checks["supported-kernel-present"] = check("fail", "no supported kernel package is installed")
    else:
        checks["supported-kernel-present"] = check("not-applicable", "profile does not require a supported kernel")

    if not installed_kernels:
        checks["headers-present"] = check("not-applicable", "no installed supported kernel was detected")
        checks["header-version-match"] = check("not-applicable", "no installed kernel/header pair was detected")
        checks["package-release-mapping"] = check("not-applicable", "no installed supported kernel was detected")
        checks["build-directories"] = check("not-applicable", "no supported kernel release was detected")
    else:
        header_states = [kernel["header_status"] for kernel in installed_kernels]
        if unavailable_status(*header_states):
            checks["headers-present"] = check("unavailable", "one or more header package queries failed")
        elif any(state != "installed" for state in header_states):
            checks["headers-present"] = check("fail", "one or more installed kernels lack matching header packages")
        else:
            checks["headers-present"] = check("pass", "every installed supported kernel has its header package")

        version_matches = [kernel["header_version_match"] for kernel in installed_kernels]
        if any(value is None for value in version_matches):
            if unavailable_status(*header_states):
                checks["header-version-match"] = check("unavailable", "kernel/header version equality could not be determined")
            else:
                checks["header-version-match"] = check("fail", "kernel/header version equality is incomplete")
        elif any(value is False for value in version_matches):
            checks["header-version-match"] = check("fail", "at least one kernel/header package version differs")
        else:
            checks["header-version-match"] = check("pass", "all installed kernel/header package versions match exactly")

        release_states = [kernel["release_query_status"] for kernel in installed_kernels]
        if unavailable_status(*release_states):
            checks["package-release-mapping"] = check("unavailable", "one or more kernel package file-list queries failed")
        else:
            checks["package-release-mapping"] = check("pass", "installed kernel packages map to module releases")

        if module_inventory["status"] in QUERY_FAILURE_STATES or unavailable_status(*release_states):
            checks["build-directories"] = check("unavailable", "module/build directory state could not be determined")
        elif any(not build["present"] for kernel in installed_kernels for build in kernel["build_directories"]):
            checks["build-directories"] = check("fail", "one or more supported kernel releases lack a build directory")
        else:
            checks["build-directories"] = check("pass", "all supported kernel releases have build directories")

    if module_inventory["status"] in QUERY_FAILURE_STATES:
        checks["module-inventory"] = check("unavailable", "module directory inventory failed")
    else:
        checks["module-inventory"] = check("pass", "module directory inventory completed")

    if not policy.require_nvidia_dkms:
        checks["nvidia-package"] = check("not-applicable", "profile does not require NVIDIA DKMS")
        checks["dkms-query"] = check("not-applicable", "profile does not require DKMS coverage")
        checks["dkms-coverage"] = check("not-applicable", "profile does not require NVIDIA DKMS coverage")
    else:
        nvidia_package = packages[NVIDIA_PACKAGE]
        if nvidia_package["status"] in QUERY_FAILURE_STATES:
            checks["nvidia-package"] = check("unavailable", "NVIDIA DKMS package state is unavailable")
        elif nvidia_package["status"] != "installed":
            checks["nvidia-package"] = check("fail", "required NVIDIA DKMS package is missing")
        else:
            checks["nvidia-package"] = check("pass", "required NVIDIA DKMS package is installed")

        if dkms["status"] in QUERY_FAILURE_STATES:
            checks["dkms-query"] = check("unavailable", "DKMS status query failed or could not be parsed")
        else:
            checks["dkms-query"] = check("pass", "DKMS status query completed")

        release_query_states = [kernel["release_query_status"] for kernel in installed_kernels]
        if dkms["status"] in QUERY_FAILURE_STATES or unavailable_status(*release_query_states):
            checks["dkms-coverage"] = check("unavailable", "NVIDIA DKMS coverage could not be determined")
        elif not detected_releases:
            checks["dkms-coverage"] = check("fail", "no supported kernel release is available for DKMS coverage")
        else:
            installed_entries = {
                entry["kernel"]
                for entry in dkms["entries"]
                if entry["module"] == NVIDIA_DKMS_MODULE and entry["state"].startswith("installed")
            }
            missing_coverage = sorted(set(detected_releases) - installed_entries)
            if missing_coverage:
                checks["dkms-coverage"] = check("fail", "one or more supported kernel releases lack installed NVIDIA DKMS state")
            else:
                checks["dkms-coverage"] = check("pass", "NVIDIA DKMS is installed for every supported kernel release")

    warnings: list[str] = []
    detected_release_set = set(detected_releases)
    if running_release["status"] == "ok":
        if running_release["value"] in detected_release_set:
            checks["running-release-observation"] = check("pass", "running release maps to an installed supported kernel package")
        else:
            checks["running-release-observation"] = check("warning", "running release is not mapped to an installed supported kernel package")
            warnings.append("running-release-unmapped")
    else:
        checks["running-release-observation"] = check("unavailable", "running release query failed")
        warnings.append("running-release-query-unavailable")

    if module_inventory["status"] == "ok":
        unmapped = sorted(set(module_inventory["releases"]) - detected_release_set)
        if unmapped:
            warnings.append("unmapped-module-releases-present")
    else:
        unmapped = []

    readiness_checks = {
        name: item
        for name, item in checks.items()
        if name != "running-release-observation"
    }
    unavailable_checks = sorted(name for name, item in readiness_checks.items() if item["status"] == "unavailable")
    blockers = sorted(name for name, item in readiness_checks.items() if item["status"] == "fail")
    if unavailable_checks:
        overall_result = "unavailable"
        exit_code = 2
    elif blockers:
        overall_result = "blocked"
        exit_code = 1
    else:
        overall_result = "ready"
        exit_code = 0

    return {
        "schema": 1,
        "profile": profile,
        "safety": {
            "planning_only": True,
            "installer_apply_integration": False,
            "system_changes": False,
            "boot_changes": False,
        },
        "policy": {
            "required_kernel_packages": sorted(policy.required_kernels),
            "require_supported_kernel": policy.require_supported_kernel,
            "require_nvidia_dkms": policy.require_nvidia_dkms,
        },
        "running_release": running_release,
        "module_inventory": module_inventory,
        "unmapped_module_releases": unmapped,
        "packages": packages,
        "kernels": kernels,
        "dkms": dkms,
        "checks": checks,
        "overall": {
            "result": overall_result,
            "exit_code": exit_code,
            "blockers": blockers,
            "unavailable_checks": unavailable_checks,
            "warnings": sorted(warnings),
        },
    }


def kernel_summary(kernel: dict[str, Any]) -> str:
    if kernel["package_status"] in QUERY_FAILURE_STATES or kernel["header_status"] in QUERY_FAILURE_STATES:
        return "unavailable"
    if kernel["package_status"] != "installed":
        return "missing" if kernel["required"] else "not-installed"
    if kernel["header_status"] != "installed":
        return "fail"
    if kernel["header_version_match"] is not True:
        return "fail"
    if kernel["release_query_status"] != "ok":
        return "unavailable"
    if any(not item["present"] for item in kernel["build_directories"]):
        return "fail"
    return "pass"


def print_text(report: dict[str, Any]) -> None:
    overall = report["overall"]
    print("Kernel/header/DKMS review (read-only)")
    print(f"  profile: {report['profile']}")
    print("  safety: local queries only; no package install/removal, service action, initramfs rebuild or GRUB write")
    print("  installer integration: none")
    print("  boot changes: none")
    print(f"  overall: {overall['result']} (exit {overall['exit_code']})")
    running = report["running_release"]
    running_value = running["value"] if running["status"] == "ok" else "unavailable"
    print(f"  running release: {running_value} status={running['status']} query_exit={running['query_exit']}")
    print(f"  module inventory: {report['module_inventory']['status']}")
    print("\nkernel/header pairs:")
    for kernel in report["kernels"]:
        print(
            f"  - {kernel['package']} -> {kernel['header_package']}: {kernel_summary(kernel)} "
            f"kernel={kernel['package_status']} header={kernel['header_status']} "
            f"version_match={kernel['header_version_match']} releases={','.join(kernel['module_releases']) or '-'}"
        )
    nvidia = report["checks"]["nvidia-package"]
    dkms_query_check = report["checks"]["dkms-query"]
    coverage = report["checks"]["dkms-coverage"]
    print(f"\nNVIDIA package: {nvidia['status']}")
    print(
        f"DKMS query: {dkms_query_check['status']} "
        f"status={report['dkms']['status']} query_exit={report['dkms']['query_exit']} "
        f"empty_result={report['dkms']['empty_result']}"
    )
    print(f"DKMS nvidia coverage: {coverage['status']}")
    if overall["blockers"]:
        print("\nblockers:")
        for item in overall["blockers"]:
            print(f"  - {item}")
    if overall["unavailable_checks"]:
        print("\nunavailable checks:")
        for item in overall["unavailable_checks"]:
            print(f"  - {item}")
    if overall["warnings"]:
        print("\nwarnings:")
        for item in overall["warnings"]:
            print(f"  - {item}")
    print("\ncompletion gate: this report never authorizes package, DKMS, initramfs or boot changes.")


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Check kernel/header/DKMS readiness without changing the system.")
    parser.add_argument("--profile", choices=tuple(PROFILE_POLICIES), default="asus-amd-nvidia")
    parser.add_argument("--modules-root", type=Path, default=Path("/usr/lib/modules"))
    parser.add_argument("--json", action="store_true", help="emit machine-readable JSON")
    arguments = parser.parse_args(argv)

    report = build_report(arguments.profile, arguments.modules_root)
    if arguments.json:
        json.dump(report, sys.stdout, indent=2, sort_keys=True)
        print()
    else:
        print_text(report)
    return int(report["overall"]["exit_code"])


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
