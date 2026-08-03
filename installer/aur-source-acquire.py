#!/usr/bin/env python3
"""Plan or acquire the three fixed local AUR source preconditions."""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import time
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any
from urllib.parse import urlsplit

SCHEMA = 1
HEX64_RE = re.compile(r"[0-9a-f]{64}")
SAFE_FILE_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._+@:-]*")
PACKAGE_RE = re.compile(r"[a-z0-9@._+:-]+")
METHODS = {"direct-download", "signed-url-download", "cargo-vendor"}
METHOD_COMMANDS = {
    "direct-download": ("curl",),
    "signed-url-download": ("curl",),
    "cargo-vendor": ("curl", "cargo", "tar", "zstd"),
}
METHOD_SPACE_BYTES = {
    "direct-download": 1024**3,
    "signed-url-download": 1024**3,
    "cargo-vendor": 2 * 1024**3,
}
SIGN_HEADER = 'x-oidb: {"uint32_command":"0x9b8e","uint32_service_type":1}'


@dataclass(frozen=True)
class AcquisitionPolicy:
    package: str
    method: str
    output: str
    output_sha256: str
    expected_bytes: str
    primary_url: str
    primary_sha256: str
    lock_sha256: str
    bootstrap_url: str
    auxiliary_url: str
    allowed_host: str
    authorization: str
    purpose: str


class PolicyError(Exception):
    pass


class AcquisitionFailure(Exception):
    def __init__(self, status: int, message: str):
        super().__init__(message)
        self.status = status
        self.message = message


def paths(project_root: Path) -> dict[str, Path]:
    return {
        "manifest": project_root / "manifests/aur-source-acquisition.tsv",
        "recipes": project_root / "manifests/aur-recipes.tsv",
    }


def safe_lines(path: Path, schema: str, label: str) -> list[str]:
    if not path.is_file() or path.is_symlink():
        raise PolicyError(f"{label} is missing or unsafe")
    try:
        lines = path.read_text().splitlines()
    except OSError as error:
        raise PolicyError(f"could not read {label}: {error}") from error
    if not lines or lines[0] != schema:
        raise PolicyError(f"{label} has an unsupported schema")
    return lines


def validate_https(url: str, label: str, package: str) -> None:
    parsed = urlsplit(url)
    if parsed.scheme != "https" or not parsed.netloc or parsed.username or parsed.password:
        raise PolicyError(f"{package}: {label} must be an unauthenticated HTTPS URL")
    if any(ord(character) < 33 for character in url):
        raise PolicyError(f"{package}: {label} contains whitespace/control characters")


def load_policy(path: Path) -> dict[str, AcquisitionPolicy]:
    lines = safe_lines(path, "# schema=1", "AUR source acquisition manifest")
    records: dict[str, AcquisitionPolicy] = {}
    for line_number, parts in enumerate(csv.reader(lines[1:], delimiter="\t"), 2):
        if not parts or not parts[0] or parts[0].startswith("#"):
            continue
        if len(parts) != 13 or not all(parts):
            raise PolicyError(f"invalid acquisition row at line {line_number}")
        record = AcquisitionPolicy(*parts)
        if PACKAGE_RE.fullmatch(record.package) is None or record.package in records:
            raise PolicyError(f"invalid/duplicate acquisition package at line {line_number}")
        if record.method not in METHODS:
            raise PolicyError(f"invalid acquisition method for {record.package}: {record.method}")
        if SAFE_FILE_RE.fullmatch(record.output) is None:
            raise PolicyError(f"unsafe acquisition output for {record.package}")
        if HEX64_RE.fullmatch(record.output_sha256) is None or HEX64_RE.fullmatch(record.primary_sha256) is None:
            raise PolicyError(f"invalid fixed SHA-256 for {record.package}")
        if record.expected_bytes != "-" and (not record.expected_bytes.isdigit() or int(record.expected_bytes) <= 0):
            raise PolicyError(f"invalid expected size for {record.package}")
        validate_https(record.primary_url, "primary URL", record.package)
        if urlsplit(record.primary_url).hostname != record.allowed_host:
            raise PolicyError(f"{record.package}: primary URL host differs from the allowlist")
        if not re.fullmatch(r"[A-Za-z0-9.-]+", record.allowed_host):
            raise PolicyError(f"{record.package}: invalid allowed host")
        if record.authorization != "aur":
            raise PolicyError(f"{record.package}: acquisition lost the independent AUR authorization")
        if record.method == "signed-url-download":
            validate_https(record.bootstrap_url, "bootstrap URL", record.package)
            validate_https(record.auxiliary_url, "signing URL", record.package)
            if urlsplit(record.bootstrap_url).hostname != "im.qq.com" or urlsplit(record.auxiliary_url).hostname != "im.qq.com":
                raise PolicyError(f"{record.package}: signing endpoints differ from the reviewed host")
            if record.lock_sha256 != "-":
                raise PolicyError(f"{record.package}: unexpected lock hash")
        elif record.method == "cargo-vendor":
            if HEX64_RE.fullmatch(record.lock_sha256) is None:
                raise PolicyError(f"{record.package}: invalid Cargo.lock SHA-256")
            if record.bootstrap_url != "-" or record.auxiliary_url != "-" or record.expected_bytes == "-":
                raise PolicyError(f"{record.package}: incomplete Cargo vendor policy")
        else:
            if record.lock_sha256 != "-" or record.bootstrap_url != "-" or record.auxiliary_url != "-":
                raise PolicyError(f"{record.package}: unexpected method-specific values")
        if any(ord(character) < 32 for character in record.purpose):
            raise PolicyError(f"{record.package}: control character in purpose")
        records[record.package] = record
    if set(records) != {"linuxqq-appimage", "paru", "wechat-appimage"}:
        raise PolicyError(f"acquisition manifest package set is not exact: {sorted(records)}")
    return records


def load_external_recipe_sources(path: Path) -> dict[str, str]:
    lines = safe_lines(path, "# schema=2", "AUR recipe manifest")
    external: dict[str, str] = {}
    for line_number, parts in enumerate(csv.reader(lines[1:], delimiter="\t"), 2):
        if not parts or not parts[0] or parts[0].startswith("#"):
            continue
        if len(parts) != 14:
            raise PolicyError(f"invalid AUR recipe row at line {line_number}")
        package, source_policy, output = parts[0], parts[9], parts[10]
        if source_policy == "local-fixed":
            external[package] = output
    return external


def parse_selection(value: str | None, known: set[str]) -> list[str]:
    if value is None or value == "all":
        return sorted(known)
    selected: list[str] = []
    seen: set[str] = set()
    for package in value.split(","):
        if not package:
            raise PolicyError("empty package in --packages")
        if package in seen:
            raise PolicyError(f"duplicate package in --packages: {package}")
        if package not in known:
            raise PolicyError(f"undeclared acquisition package: {package}")
        seen.add(package)
        selected.append(package)
    return selected


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def reject_symlink_components(path: Path, stop: Path | None = None) -> str | None:
    current = path
    parts: list[Path] = []
    while True:
        parts.append(current)
        if stop is not None and current == stop:
            break
        if current.parent == current:
            break
        current = current.parent
    for candidate in reversed(parts):
        try:
            if candidate.is_symlink():
                return str(candidate)
        except OSError:
            return str(candidate)
    return None


def nearest_existing_parent(path: Path) -> Path:
    current = path
    while not current.exists():
        if current.parent == current:
            return current
        current = current.parent
    return current


def inspect_record(record: AcquisitionPolicy, cache_root: Path) -> dict[str, Any]:
    blockers: list[str] = []
    unavailable: list[str] = []
    target = cache_root / record.package / record.output
    symlink = reject_symlink_components(target, nearest_existing_parent(cache_root))
    if symlink is not None:
        blockers.append(f"{record.package}: source-cache path contains a symlink")
        state = "unsafe-path"
        actual_hash = None
        actual_bytes = None
    elif not target.exists():
        state = "absent"
        actual_hash = None
        actual_bytes = None
    elif target.is_symlink() or not target.is_file():
        state = "conflict"
        actual_hash = None
        actual_bytes = None
        blockers.append(f"{record.package}: cache target is not a regular file")
    else:
        try:
            file_stat = target.stat()
            actual_hash = sha256_file(target)
        except OSError as error:
            state = "query-failed"
            actual_hash = None
            actual_bytes = None
            unavailable.append(f"{record.package}: cache hash query failed ({type(error).__name__})")
        else:
            actual_bytes = file_stat.st_size
            if actual_hash != record.output_sha256:
                state = "conflict"
                blockers.append(f"{record.package}: existing cache file has the wrong SHA-256")
            elif record.expected_bytes != "-" and actual_bytes != int(record.expected_bytes):
                state = "conflict"
                blockers.append(f"{record.package}: existing cache file has the wrong size")
            else:
                state = "matching"

    commands: list[dict[str, Any]] = []
    if state == "absent":
        for command_name in METHOD_COMMANDS[record.method]:
            resolved = shutil.which(command_name)
            if resolved is None:
                commands.append({"command": command_name, "state": "missing"})
                unavailable.append(f"{record.package}: required acquisition command is missing: {command_name}")
            else:
                commands.append({"command": command_name, "state": "available", "path": resolved})
    return {
        **asdict(record),
        "target": str(target),
        "state": state,
        "actual_sha256": actual_hash,
        "actual_bytes": actual_bytes,
        "commands": commands,
        "effect": None if state == "matching" else f"acquire {record.output}" if state == "absent" else None,
        "blockers": blockers,
        "unavailable_checks": unavailable,
    }


def build_plan(
    records: dict[str, AcquisitionPolicy],
    selected: list[str],
    cache_root: Path,
    project_root: Path,
) -> dict[str, Any]:
    reports = [inspect_record(records[name], cache_root) for name in selected]
    blockers = [item for report in reports for item in report["blockers"]]
    unavailable = [item for report in reports for item in report["unavailable_checks"]]
    if "paru" in selected:
        lock_override = project_root / "third_party/aur/paru/Cargo.lock.libalpm16"
        if lock_override.is_symlink() or not lock_override.is_file():
            blockers.append("paru: reviewed libalpm-16 Cargo.lock override is missing or unsafe")
        else:
            try:
                lock_hash = sha256_file(lock_override)
            except OSError as error:
                unavailable.append(f"paru: lock override hash query failed ({type(error).__name__})")
            else:
                if lock_hash != records["paru"].lock_sha256:
                    blockers.append("paru: reviewed libalpm-16 Cargo.lock override SHA-256 mismatch")
    required_space = sum(METHOD_SPACE_BYTES[records[name].method] for name in selected if next(r for r in reports if r["package"] == name)["state"] == "absent")
    space_report: dict[str, Any]
    try:
        parent = nearest_existing_parent(cache_root)
        usage = shutil.disk_usage(parent)
    except OSError as error:
        space_report = {"status": "query-failed", "query_exit": None, "error": type(error).__name__}
        unavailable.append("source-cache free-space query failed")
    else:
        space_report = {
            "status": "available",
            "path": str(parent),
            "free_bytes": usage.free,
            "required_bytes": required_space,
        }
        if usage.free < required_space:
            blockers.append(
                f"source cache has insufficient space: requires {required_space} bytes, found {usage.free}"
            )
    if os.geteuid() == 0:
        blockers.append("AUR source acquisition must run as an ordinary user, not root")
    if unavailable:
        status, exit_code = "unavailable", 2
    elif blockers:
        status, exit_code = "blocked", 1
    else:
        status, exit_code = "ready", 0
    effects = [
        {"package": report["package"], "method": report["method"], "output": report["output"]}
        for report in reports if report["state"] == "absent"
    ]
    return {
        "schema": SCHEMA,
        "selection": {"packages": selected, "source": "all" if len(selected) == len(records) else "explicit"},
        "cache_root": str(cache_root),
        "records": reports,
        "effects": effects,
        "space": space_report,
        "overall": {"status": status, "exit_code": exit_code, "blockers": blockers, "unavailable_checks": unavailable},
        "confirmation": {"authorization": "aur", "required_flag": "--confirm-aur"},
        "rollback": [
            "No existing cache file is overwritten or removed.",
            "A failed acquisition removes only its private temporary directory.",
            "A newly created matching cache file may be removed manually after confirming no build uses it.",
        ],
        "apply": {"authorized": False, "commands": None},
        "safety": {
            "read_only": True,
            "system_changes": False,
            "package_changes": False,
            "executes_downloaded_sources": False,
            "credentials_persisted": False,
        },
    }


def private_directory(path: Path) -> None:
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    if path.is_symlink() or not path.is_dir():
        raise AcquisitionFailure(1, f"private path is not a safe directory: {path}")
    os.chmod(path, 0o700)


def private_log_path() -> Path:
    state = Path(os.environ.get("XDG_STATE_HOME", str(Path.home() / ".local/state"))) / "my-archlinux-setup/logs"
    private_directory(state)
    stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    path = state / f"aur-source-acquire-{stamp}-{os.getpid()}.log"
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    os.close(descriptor)
    return path


def log_line(log_path: Path, message: str) -> None:
    with log_path.open("a", encoding="utf-8") as handle:
        handle.write(message + "\n")


def run_command(
    command: list[str],
    *,
    cwd: Path | None = None,
    environment: dict[str, str] | None = None,
    capture_stdout: bool = False,
    label: str,
    log_path: Path,
) -> subprocess.CompletedProcess[str]:
    log_line(log_path, f"start: {label}")
    try:
        result = subprocess.run(
            command,
            cwd=cwd,
            env=environment,
            text=True,
            stdout=subprocess.PIPE if capture_stdout else subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            check=False,
        )
    except OSError as error:
        log_line(log_path, f"failed: {label}: command unavailable ({type(error).__name__})")
        raise AcquisitionFailure(127, f"{label} could not execute") from error
    log_line(log_path, f"exit: {label}: {result.returncode}")
    if result.returncode != 0:
        status = result.returncode if 1 <= result.returncode <= 125 else 1
        raise AcquisitionFailure(status, f"{label} failed with exit {result.returncode}")
    return result


def curl_base(curl: str) -> list[str]:
    return [curl, "--fail", "--location", "--silent", "--show-error", "--proto", "=https", "--tlsv1.2"]


def download_direct(record: AcquisitionPolicy, destination: Path, log_path: Path) -> None:
    curl = shutil.which("curl")
    if curl is None:
        raise AcquisitionFailure(127, "curl is unavailable")
    run_command(
        [*curl_base(curl), "--output", str(destination), record.primary_url],
        label=f"{record.package} fixed download",
        log_path=log_path,
    )


def curl_config_value(value: str) -> str:
    if any(ord(character) < 32 for character in value):
        raise AcquisitionFailure(1, "unsafe control character in private curl configuration")
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def validate_signed_url(record: AcquisitionPolicy, url: str) -> None:
    parsed = urlsplit(url)
    expected = urlsplit(record.primary_url)
    if (
        parsed.scheme != "https"
        or parsed.hostname != record.allowed_host
        or parsed.path != expected.path
        or parsed.username
        or parsed.password
        or any(ord(character) < 33 for character in url)
    ):
        raise AcquisitionFailure(1, f"{record.package} signing service returned an unexpected download identity")


def download_signed(record: AcquisitionPolicy, destination: Path, temporary: Path, log_path: Path) -> None:
    curl = shutil.which("curl")
    if curl is None:
        raise AcquisitionFailure(127, "curl is unavailable")
    cookie = temporary / "cookie.jar"
    cookie.touch(mode=0o600)
    run_command(
        [*curl_base(curl), "--cookie-jar", str(cookie), "--output", "/dev/null", record.bootstrap_url],
        label=f"{record.package} signing bootstrap",
        log_path=log_path,
    )
    payload = json.dumps({"url": record.primary_url}, separators=(",", ":"))
    response = run_command(
        [
            *curl_base(curl),
            "--cookie", str(cookie),
            "--json", payload,
            "--header", SIGN_HEADER,
            record.auxiliary_url,
        ],
        capture_stdout=True,
        label=f"{record.package} signing query",
        log_path=log_path,
    )
    try:
        decoded = json.loads(response.stdout)
        signed_url = decoded["data"]["url"]
    except (json.JSONDecodeError, KeyError, TypeError) as error:
        raise AcquisitionFailure(1, f"{record.package} signing response was invalid") from error
    if not isinstance(signed_url, str):
        raise AcquisitionFailure(1, f"{record.package} signing response omitted a URL")
    validate_signed_url(record, signed_url)
    config = temporary / "signed-download.curl"
    config.write_text(
        "\n".join(
            (
                "fail",
                "location",
                "silent",
                "show-error",
                'proto = "=https"',
                "tlsv1.2",
                f"output = {curl_config_value(str(destination))}",
                f"url = {curl_config_value(signed_url)}",
                "",
            )
        )
    )
    os.chmod(config, 0o600)
    run_command(
        [curl, "--config", str(config)],
        label=f"{record.package} signed fixed download",
        log_path=log_path,
    )
    config.unlink(missing_ok=True)
    cookie.unlink(missing_ok=True)


def safe_extract_source(archive: Path, destination: Path, package: str) -> Path:
    try:
        with tarfile.open(archive, "r:gz") as handle:
            members = handle.getmembers()
            roots: set[str] = set()
            for member in members:
                pure = Path(member.name)
                if pure.is_absolute() or ".." in pure.parts or not pure.parts:
                    raise AcquisitionFailure(1, f"{package} source archive contains an unsafe path")
                roots.add(pure.parts[0])
                if member.issym() or member.islnk():
                    target = Path(member.linkname)
                    if target.is_absolute() or ".." in target.parts:
                        raise AcquisitionFailure(1, f"{package} source archive contains an unsafe link")
            if len(roots) != 1:
                raise AcquisitionFailure(1, f"{package} source archive has an unexpected root layout")
            handle.extractall(destination, filter="data")
    except (tarfile.TarError, OSError) as error:
        raise AcquisitionFailure(1, f"{package} source archive extraction failed") from error
    source_root = destination / next(iter(roots))
    if not source_root.is_dir() or source_root.is_symlink():
        raise AcquisitionFailure(1, f"{package} extracted source root is unsafe")
    return source_root


def create_cargo_vendor(
    record: AcquisitionPolicy,
    destination: Path,
    temporary: Path,
    lock_override: Path,
    log_path: Path,
) -> None:
    source_archive = temporary / "source.tar.gz"
    download_direct(record, source_archive, log_path)
    if sha256_file(source_archive) != record.primary_sha256:
        raise AcquisitionFailure(1, f"{record.package} upstream source SHA-256 mismatch")
    source_parent = temporary / "source"
    source_parent.mkdir(mode=0o700)
    source_root = safe_extract_source(source_archive, source_parent, record.package)
    lock = source_root / "Cargo.lock"
    if lock_override.is_symlink() or not lock_override.is_file():
        raise AcquisitionFailure(1, f"{record.package} reviewed Cargo.lock override is missing or unsafe")
    if sha256_file(lock_override) != record.lock_sha256:
        raise AcquisitionFailure(1, f"{record.package} reviewed Cargo.lock override SHA-256 mismatch")
    shutil.copy2(lock_override, lock)
    if sha256_file(lock) != record.lock_sha256:
        raise AcquisitionFailure(1, f"{record.package} staged Cargo.lock override SHA-256 mismatch")
    vendor = temporary / "vendor"
    cargo_home = temporary / "cargo-home"
    home = temporary / "home"
    cargo_home.mkdir(mode=0o700)
    home.mkdir(mode=0o700)
    environment = os.environ.copy()
    # The cargo binary is a rustup shim on Arch; rustup locates its toolchain
    # under $HOME/.rustup (RUSTUP_HOME). Since the subprocess HOME is redirected
    # to an isolated temporary directory, resolve the real toolchain location
    # from the caller's environment before overwriting HOME.
    caller_home = environment.get("HOME") or "/root"
    rustup_home = environment.get("RUSTUP_HOME") or caller_home + "/.rustup"
    environment.update(
        {
            "HOME": str(home),
            "CARGO_HOME": str(cargo_home),
            "RUSTUP_HOME": rustup_home,
            "CARGO_NET_GIT_FETCH_WITH_CLI": "false",
            "LC_ALL": "C",
        }
    )
    cargo = shutil.which("cargo")
    tar = shutil.which("tar")
    zstd = shutil.which("zstd")
    if cargo is None or tar is None or zstd is None:
        raise AcquisitionFailure(127, "cargo-vendor acquisition command became unavailable")
    run_command(
        [cargo, "vendor", "--locked", "--versioned-dirs", str(vendor)],
        cwd=source_root,
        environment=environment,
        label=f"{record.package} Cargo vendor acquisition",
        log_path=log_path,
    )
    tar_path = temporary / "vendor.tar"
    run_command(
        [
            tar,
            "--sort=name",
            "--mtime=@0",
            "--owner=0",
            "--group=0",
            "--numeric-owner",
            "--format=posix",
            "--pax-option=delete=atime,delete=ctime",
            "-C",
            str(temporary),
            "-cf",
            str(tar_path),
            "vendor",
        ],
        label=f"{record.package} deterministic vendor archive",
        log_path=log_path,
    )
    run_command(
        [zstd, "-q", "-T1", "-10", "-f", "-o", str(destination), str(tar_path)],
        label=f"{record.package} deterministic vendor compression",
        log_path=log_path,
    )


def acquire_one(record: AcquisitionPolicy, cache_root: Path, project_root: Path, log_path: Path) -> None:
    package_dir = cache_root / record.package
    private_directory(package_dir)
    target = package_dir / record.output
    if target.exists():
        if target.is_file() and not target.is_symlink() and sha256_file(target) == record.output_sha256:
            log_line(log_path, f"skip: {record.package}: matching source already present")
            return
        raise AcquisitionFailure(1, f"{record.package}: refusing to overwrite a conflicting cache target")
    with tempfile.TemporaryDirectory(prefix=f".{record.package}-", dir=package_dir) as temporary_name:
        temporary = Path(temporary_name)
        os.chmod(temporary, 0o700)
        candidate = temporary / record.output
        if record.method == "direct-download":
            download_direct(record, candidate, log_path)
        elif record.method == "signed-url-download":
            download_signed(record, candidate, temporary, log_path)
        elif record.method == "cargo-vendor":
            create_cargo_vendor(
                record, candidate, temporary,
                project_root / "third_party/aur/paru/Cargo.lock.libalpm16", log_path,
            )
        else:
            raise AcquisitionFailure(1, f"unsupported acquisition method: {record.method}")
        if not candidate.is_file() or candidate.is_symlink():
            raise AcquisitionFailure(1, f"{record.package}: acquisition did not produce a regular file")
        actual_size = candidate.stat().st_size
        if record.expected_bytes != "-" and actual_size != int(record.expected_bytes):
            raise AcquisitionFailure(1, f"{record.package}: acquired source size mismatch")
        actual_hash = sha256_file(candidate)
        if actual_hash != record.output_sha256:
            raise AcquisitionFailure(1, f"{record.package}: acquired source SHA-256 mismatch")
        os.chmod(candidate, 0o600)
        os.replace(candidate, target)
        log_line(log_path, f"passed: {record.package}: fixed source acquired and hash-verified")


def apply_plan(
    plan: dict[str, Any],
    records: dict[str, AcquisitionPolicy],
    cache_root: Path,
    project_root: Path,
) -> Path:
    if plan["overall"]["status"] != "ready":
        raise AcquisitionFailure(plan["overall"]["exit_code"], "acquisition plan is not ready")
    private_directory(cache_root)
    log_path = private_log_path()
    log_line(log_path, "authorization: independent AUR source acquisition confirmed")
    log_line(log_path, f"selection: {','.join(plan['selection']['packages'])}")
    for package in plan["selection"]["packages"]:
        report = next(item for item in plan["records"] if item["package"] == package)
        if report["state"] == "matching":
            log_line(log_path, f"skip: {package}: matching source already present")
            continue
        acquire_one(records[package], cache_root, project_root, log_path)
    return log_path


def render_text(plan: dict[str, Any]) -> None:
    print("Fixed local AUR source acquisition plan")
    print(f"Status: {plan['overall']['status']}")
    print(f"Cache: {plan['cache_root']}")
    for record in plan["records"]:
        print(f"  [{record['state']}/{record['method']}] {record['package']} -> {record['output']}")
    if plan["overall"]["blockers"]:
        print("Blockers:")
        for item in plan["overall"]["blockers"]:
            print(f"  - {item}")
    if plan["overall"]["unavailable_checks"]:
        print("Unavailable checks:")
        for item in plan["overall"]["unavailable_checks"]:
            print(f"  - {item}")
    print("Authorization: independent AUR confirmation required; no system/package change is performed.")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    actions = parser.add_mutually_exclusive_group()
    actions.add_argument("--plan", action="store_true", help="render the read-only plan (default)")
    actions.add_argument("--apply", action="store_true", help="acquire missing fixed sources after confirmation")
    parser.add_argument("--confirm-aur", action="store_true", help="required with --apply; confirms only AUR source acquisition")
    parser.add_argument("--packages", help="exact comma-separated acquisition package subset, or all")
    parser.add_argument(
        "--cache-root",
        type=Path,
        default=Path(os.environ.get("XDG_CACHE_HOME", str(Path.home() / ".cache"))) / "my-archlinux-setup/aur-sources",
    )
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--project-root", type=Path, help=argparse.SUPPRESS)
    arguments = parser.parse_args()
    if arguments.confirm_aur and not arguments.apply:
        parser.error("--confirm-aur is valid only with --apply")
    if arguments.apply and not arguments.confirm_aur:
        parser.error("--apply requires the independent --confirm-aur flag")
    project_root = (arguments.project_root or Path(__file__).resolve().parent.parent).resolve()
    cache_root = Path(os.path.abspath(os.fspath(arguments.cache_root.expanduser())))
    try:
        records = load_policy(paths(project_root)["manifest"])
        external = load_external_recipe_sources(paths(project_root)["recipes"])
        expected_external = {package: record.output for package, record in records.items()}
        if external != expected_external:
            raise PolicyError(f"acquisition/recipe external-source mismatch: acquisition={expected_external}, recipes={external}")
        selected = parse_selection(arguments.packages, set(records))
        plan = build_plan(records, selected, cache_root, project_root)
    except PolicyError as error:
        print(f"aur-source-acquire: {error}", file=sys.stderr)
        raise SystemExit(2) from error
    if not arguments.apply:
        if arguments.json:
            json.dump(plan, sys.stdout, indent=2, sort_keys=True)
            print()
        else:
            render_text(plan)
        raise SystemExit(plan["overall"]["exit_code"])
    try:
        log_path = apply_plan(plan, records, cache_root, project_root)
    except AcquisitionFailure as error:
        print(f"aur-source-acquire: {error.message}", file=sys.stderr)
        raise SystemExit(error.status) from error
    result = build_plan(records, selected, cache_root, project_root)
    if result["overall"]["status"] != "ready" or any(record["state"] != "matching" for record in result["records"]):
        print("aur-source-acquire: post-check did not verify every selected cache source", file=sys.stderr)
        raise SystemExit(1)
    if arguments.json:
        result["apply"] = {"authorized": True, "completed": True, "log_path": str(log_path)}
        result["safety"]["read_only"] = False
        json.dump(result, sys.stdout, indent=2, sort_keys=True)
        print()
    else:
        print(f"Fixed AUR sources acquired and verified; private log: {log_path}")


if __name__ == "__main__":
    main()
