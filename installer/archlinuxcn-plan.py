#!/usr/bin/env python3
"""Inspect and render the fixed archlinuxcn trust/bootstrap plan without applying it."""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import os
import platform
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any

PROJECT_ROOT = Path(__file__).resolve().parent.parent
MANIFEST = PROJECT_ROOT / "manifests/archlinuxcn-bootstrap.tsv"
TEMPLATE = PROJECT_ROOT / "config/templates/archlinuxcn.conf"
ABSENT_RE = re.compile(r"^error: package 'archlinuxcn-keyring' was not found\s*$")
HEX64_RE = re.compile(r"[0-9a-f]{64}")
FINGERPRINT_RE = re.compile(r"[0-9A-F]{40}")
EXPECTED_SIGLEVEL = {
    "PackageRequired",
    "PackageTrustedOnly",
    "DatabaseOptional",
    "DatabaseTrustedOnly",
}


@dataclass(frozen=True)
class SourcePolicy:
    package: str
    version: str
    package_url: str
    sha256: str
    signature_url: str
    signature_sha256: str
    signer_primary_fingerprint: str
    repository: str
    server: str
    siglevel: str
    database_signature: str
    authorization: str


def fail(message: str) -> None:
    print(f"archlinuxcn-plan: {message}", file=sys.stderr)
    raise SystemExit(2)


def load_policy() -> SourcePolicy:
    if not MANIFEST.is_file() or MANIFEST.is_symlink():
        fail("bootstrap manifest is missing or unsafe")
    lines = MANIFEST.read_text().splitlines()
    if not lines or lines[0] != "# schema=1":
        fail("bootstrap manifest has an unsupported schema")
    rows = [
        parts
        for parts in csv.reader(lines[1:], delimiter="\t")
        if parts and parts[0] and not parts[0].startswith("#")
    ]
    if len(rows) != 1 or len(rows[0]) != 12 or not all(rows[0]):
        fail("bootstrap manifest must contain exactly one complete policy row")
    policy = SourcePolicy(*rows[0])
    if policy.package != "archlinuxcn-keyring" or policy.repository != "archlinuxcn":
        fail("bootstrap manifest names an unexpected package or repository")
    if HEX64_RE.fullmatch(policy.sha256) is None or HEX64_RE.fullmatch(policy.signature_sha256) is None:
        fail("bootstrap manifest contains an invalid SHA-256")
    if FINGERPRINT_RE.fullmatch(policy.signer_primary_fingerprint) is None:
        fail("bootstrap manifest contains an invalid signer fingerprint")
    if not policy.package_url.startswith("https://") or not policy.signature_url.startswith("https://"):
        fail("bootstrap assets must use HTTPS")
    if policy.authorization != "archlinuxcn":
        fail("bootstrap manifest lost the independent archlinuxcn authorization gate")
    return policy


def load_template(policy: SourcePolicy) -> dict[str, Any]:
    if not TEMPLATE.is_file() or TEMPLATE.is_symlink():
        fail("repository template is missing or unsafe")
    content = TEMPLATE.read_text()
    if f"[{policy.repository}]" not in content:
        fail("repository template has the wrong section")
    if f"Server = {policy.server}" not in content:
        fail("repository template server differs from the pinned policy")
    if f"SigLevel = {policy.siglevel}" not in content:
        fail("repository template SigLevel differs from the pinned policy")
    return {
        "path": str(TEMPLATE.relative_to(PROJECT_ROOT)),
        "sha256": hashlib.sha256(TEMPLATE.read_bytes()).hexdigest(),
        "content_lines": [
            line for line in content.splitlines() if line and not line.startswith("#")
        ],
    }


def run(command: list[str]) -> dict[str, Any]:
    environment = os.environ.copy()
    environment["LC_ALL"] = "C"
    try:
        result = subprocess.run(
            command,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=environment,
            check=False,
        )
    except OSError as error:
        return {
            "status": "command-failed",
            "query_exit": None,
            "stdout": "",
            "stderr": str(error),
            "command": command[0],
        }
    return {
        "status": "ok" if result.returncode == 0 else "query-failed",
        "query_exit": result.returncode,
        "stdout": result.stdout,
        "stderr": result.stderr,
        "command": command[0],
    }


def parse_directive(output: str, directive: str) -> list[str]:
    values: list[str] = []
    prefix = f"{directive} = "
    for line in output.splitlines():
        if line.startswith(prefix):
            values.append(line[len(prefix) :].strip())
        elif line.strip():
            values.append(line.strip())
    return values


def pacman_conf_args(target_root: Path, *args: str) -> list[str]:
    command = ["pacman-conf"]
    if target_root != Path("/"):
        command.extend(["--rootdir", str(target_root)])
    command.extend(args)
    return command


def pacman_args(target_root: Path, *args: str) -> list[str]:
    command = ["pacman"]
    if target_root != Path("/"):
        command.extend(["--root", str(target_root)])
    command.extend(args)
    return command


def build_report(target_root: Path) -> dict[str, Any]:
    policy = load_policy()
    template = load_template(policy)
    blockers: list[str] = []
    unavailable: list[str] = []

    repo_query = run(pacman_conf_args(target_root, "--repo-list"))
    repositories: list[str] = []
    repository_report: dict[str, Any]
    if repo_query["status"] != "ok":
        unavailable.append(
            f"configured repository query failed (pacman-conf exit={repo_query['query_exit']})"
        )
        repository_report = {
            "state": "unavailable",
            "servers": [],
            "siglevel": [],
            "usage": [],
        }
    else:
        repositories = [line.strip() for line in repo_query["stdout"].splitlines() if line.strip()]
        if policy.repository not in repositories:
            repository_report = {
                "state": "absent",
                "servers": [],
                "siglevel": [],
                "usage": [],
            }
        else:
            server_query = run(
                pacman_conf_args(target_root, "--repo", policy.repository, "--verbose", "Server")
            )
            siglevel_query = run(
                pacman_conf_args(target_root, "--repo", policy.repository, "--verbose", "SigLevel")
            )
            usage_query = run(
                pacman_conf_args(target_root, "--repo", policy.repository, "--verbose", "Usage")
            )
            failed = [
                ("Server", server_query),
                ("SigLevel", siglevel_query),
                ("Usage", usage_query),
            ]
            for label, query in failed:
                if query["status"] != "ok":
                    unavailable.append(
                        f"archlinuxcn {label} query failed (pacman-conf exit={query['query_exit']})"
                    )
            servers = parse_directive(server_query["stdout"], "Server") if server_query["status"] == "ok" else []
            siglevel = parse_directive(siglevel_query["stdout"], "SigLevel") if siglevel_query["status"] == "ok" else []
            usage = parse_directive(usage_query["stdout"], "Usage") if usage_query["status"] == "ok" else []
            expected_server = policy.server.replace("$arch", platform.machine())
            if any(query["status"] != "ok" for _label, query in failed):
                state = "unavailable"
            elif servers != [expected_server]:
                state = "conflict"
                blockers.append(
                    "existing archlinuxcn Server differs from the pinned HTTPS mirror; no fallback or overwrite is allowed"
                )
            elif not siglevel:
                state = "unmanaged-existing"
                blockers.append(
                    "existing archlinuxcn repository inherits SigLevel instead of declaring the reviewed package-signature policy"
                )
            elif set(siglevel) != EXPECTED_SIGLEVEL or usage != ["All"]:
                state = "conflict"
                blockers.append(
                    "existing archlinuxcn SigLevel/Usage differs from the reviewed repository policy"
                )
            else:
                state = "matching"
            repository_report = {
                "state": state,
                "servers": servers,
                "siglevel": siglevel,
                "usage": usage,
            }

    keyring_query = run(pacman_args(target_root, "-Q", "--", policy.package))
    if keyring_query["status"] == "ok":
        fields = keyring_query["stdout"].strip().split()
        if len(fields) != 2 or fields[0] != policy.package:
            keyring_state = "unavailable"
            unavailable.append("installed keyring query returned malformed output")
            installed_version = None
        else:
            installed_version = fields[1]
            if installed_version == policy.version:
                keyring_state = "matching"
            else:
                keyring_state = "version-conflict"
                blockers.append(
                    f"installed archlinuxcn keyring version {installed_version} differs from pinned {policy.version}"
                )
    elif (
        keyring_query["query_exit"] == 1
        and ABSENT_RE.fullmatch(keyring_query["stderr"].strip()) is not None
    ):
        keyring_state = "absent"
        installed_version = None
    else:
        keyring_state = "unavailable"
        installed_version = None
        unavailable.append(
            f"installed keyring query failed (pacman exit={keyring_query['query_exit']})"
        )

    effects: list[dict[str, Any]] = []
    repository_state = repository_report["state"]
    if not unavailable and not blockers:
        if keyring_state == "absent":
            effects.append(
                {
                    "id": "bootstrap-keyring",
                    "privilege": "root",
                    "action": "verify pinned package hash and detached signature, then install only that package",
                    "rollback": "package removal is manual and never automatic",
                }
            )
        if repository_state == "absent":
            effects.extend(
                [
                    {
                        "id": "write-repository-fragment",
                        "privilege": "root",
                        "target": "/etc/pacman.d/my-archlinux-setup-archlinuxcn.conf",
                        "action": "backup any approved target then install the exact reviewed fragment",
                        "rollback": "restore the recorded prior file or remove the newly created fragment",
                    },
                    {
                        "id": "include-repository-fragment",
                        "privilege": "root",
                        "target": "/etc/pacman.conf",
                        "action": "backup and add one exact Include line only when archlinuxcn is absent",
                        "rollback": "restore the recorded pacman.conf backup",
                    },
                ]
            )

    status = "unavailable" if unavailable else "blocked" if blockers else "ready"
    return {
        "schema": 1,
        "safety": {
            "read_only": True,
            "apply_authorized": False,
            "installer_apply_integration": False,
            "system_changes": False,
        },
        "target_root": str(target_root),
        "source_policy": {
            "keyring": {
                "package": policy.package,
                "version": policy.version,
                "package_url": policy.package_url,
                "sha256": policy.sha256,
                "signature_url": policy.signature_url,
                "signature_sha256": policy.signature_sha256,
                "signer_primary_fingerprint": policy.signer_primary_fingerprint,
            },
            "repository": {
                "name": policy.repository,
                "server": policy.server,
                "siglevel": policy.siglevel,
                "database_signature": policy.database_signature,
                "template": template,
            },
            "authorization": policy.authorization,
        },
        "current": {
            "repositories": {
                "status": repo_query["status"],
                "query_exit": repo_query["query_exit"],
                "names": repositories,
            },
            "repository": repository_report,
            "keyring": {
                "state": keyring_state,
                "installed_version": installed_version,
                "query_exit": keyring_query["query_exit"],
            },
        },
        "effects": effects,
        "authorization": {
            "required": "archlinuxcn",
            "provided": False,
        },
        "apply": {
            "authorized": False,
            "commands": None,
        },
        "rollback": [
            "Record and preserve the prior keyring package state before bootstrap.",
            "Back up only the managed repository fragment and /etc/pacman.conf before writes.",
            "Never remove third-party packages, keys or repositories automatically.",
        ],
        "post_checks": [
            "Re-query the exact archlinuxcn Server, SigLevel and Usage through pacman-conf.",
            "Verify the installed keyring version and package-owned keyring paths.",
            "Perform a separately approved full-system database refresh; never use a partial -Sy path.",
            "Resolve every declared archlinuxcn target back to repository archlinuxcn before install.",
        ],
        "overall": {
            "status": status,
            "blockers": blockers,
            "unavailable_checks": unavailable,
        },
    }


def print_text(report: dict[str, Any]) -> None:
    print("archlinuxcn source/bootstrap plan (read-only)")
    print(f"Overall: {report['overall']['status']}")
    print(f"Repository: {report['current']['repository']['state']}")
    print(f"Keyring: {report['current']['keyring']['state']}")
    print("Planned effects:")
    for effect in report["effects"]:
        print(f"- {effect['id']}: {effect['action']}")
    for blocker in report["overall"]["blockers"]:
        print(f"BLOCKED: {blocker}")
    for unavailable in report["overall"]["unavailable_checks"]:
        print(f"UNAVAILABLE: {unavailable}")
    print("Apply authorization: false")


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path("/"), help="target root to inspect")
    parser.add_argument("--json", action="store_true", help="emit JSON")
    args = parser.parse_args(argv)
    target_root = args.root
    if not target_root.is_absolute():
        fail("target root must be absolute")
    if not target_root.is_dir() or target_root.is_symlink():
        fail("target root is missing, not a directory, or symlinked")
    report = build_report(target_root)
    if args.json:
        json.dump(report, sys.stdout, indent=2, sort_keys=True)
        print()
    else:
        print_text(report)
    return {"ready": 0, "blocked": 1, "unavailable": 2}[report["overall"]["status"]]


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
