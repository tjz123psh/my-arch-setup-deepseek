#!/usr/bin/env python3
"""Production stage adapter for reviewed archlinuxcn bootstrap/package effects.

The ordinary entry point consumes only FULL_ORCHESTRATOR_* context.  It embeds
no sudo fallback: every privileged operation is dispatched through the audited
~/scripts/desktop/gsudo wrapper.  The hidden root helper can modify only the two
fixed pacman configuration targets and is intentionally unusable as root in
explicit test mode.
"""

from __future__ import annotations

import argparse
import ctypes
import csv
import datetime as dt
import hashlib
import json
import os
import pwd
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Sequence
from urllib.parse import urlsplit


PROJECT_ROOT = Path(__file__).resolve().parent.parent
SCRIPT_PATH = Path(__file__).resolve()
PLANNER_PATH = PROJECT_ROOT / "installer/archlinuxcn-plan.py"
ARCHLINUXCN_PLANNER_SHA256 = "bbdeb4054c45c00e2e6d597f6d06f12a80c3aee69d7af808b879aec2d7ac082c"
BOOTSTRAP_MANIFEST = PROJECT_ROOT / "manifests/archlinuxcn-bootstrap.tsv"
WORKSTATION_MANIFEST = PROJECT_ROOT / "manifests/workstation-packages.tsv"
TEMPLATE_PATH = PROJECT_ROOT / "config/templates/archlinuxcn.conf"
STATE_SUFFIX = Path("my-archlinux-setup/archlinuxcn-apply")
FRAGMENT_RELATIVE = Path("etc/pacman.d/my-archlinux-setup-archlinuxcn.conf")
PACMAN_CONF_RELATIVE = Path("etc/pacman.conf")
FRAGMENT_TARGET = "/etc/pacman.d/my-archlinux-setup-archlinuxcn.conf"
INCLUDE_LINE = f"Include = {FRAGMENT_TARGET}"
AUDITED_GSUDO_SHA256 = "7a63f2b74c6ab2d005dd84d03851148b129dbd530c753453f1c1f680414253b7"
AUDITED_ASKPASS_SHA256 = "4396717f5a63e25ebff7d64aeb49b2b1fb26956da0f22e1aed7a34ad768edb8a"
PENDING_GSUDO_SHA256 = "7a63f2b74c6ab2d005dd84d03851148b129dbd530c753453f1c1f680414253b7"
PENDING_ASKPASS_SHA256 = "4396717f5a63e25ebff7d64aeb49b2b1fb26956da0f22e1aed7a34ad768edb8a"
AUDITED_GSUDO_PAYLOAD = PROJECT_ROOT / "config/home/scripts/desktop/gsudo"
AUDITED_ASKPASS_PAYLOAD = PROJECT_ROOT / "config/home/scripts/desktop/fuzzel-askpass"
PACKAGE_RE = re.compile(r"^[a-z0-9][a-z0-9@._+:-]*$")
TOKEN_RE = re.compile(r"^[a-z0-9][a-z0-9-]*$")
VERSION_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+:-]*$")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
FINGERPRINT_RE = re.compile(r"^[0-9A-F]{40}$")
RUN_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
EXPECTED_SIGLEVEL = "Required DatabaseOptional TrustedOnly"
EXPECTED_DATABASE_SIGNATURE = "unavailable-upstream"
EXPECTED_REPOSITORY = "archlinuxcn"
EXPECTED_AUTHORIZATION = "archlinuxcn"
EXPECTED_BOOTSTRAP_PACKAGE = "archlinuxcn-keyring"
MAX_EFFECTS_JSON = 256 * 1024
AT_FDCWD = -100
RENAME_NOREPLACE = 1
RENAME_EXCHANGE = 2

_LIBC = ctypes.CDLL(None, use_errno=True)
_RENAMEAT2 = getattr(_LIBC, "renameat2", None)
if _RENAMEAT2 is not None:
    _RENAMEAT2.argtypes = (
        ctypes.c_int,
        ctypes.c_char_p,
        ctypes.c_int,
        ctypes.c_char_p,
        ctypes.c_uint,
    )
    _RENAMEAT2.restype = ctypes.c_int


class AdapterFailure(Exception):
    def __init__(self, status: int, message: str):
        super().__init__(message)
        self.status = normalize_status(status)
        self.message = message


class RefreshRequired(AdapterFailure):
    def __init__(self, status: int):
        super().__init__(status, f"archlinuxcn metadata refresh required (pacman -Si exit {status})")


@dataclass(frozen=True)
class ExecutionContext:
    testing: bool
    target_root: Path


@dataclass(frozen=True)
class BootstrapPolicy:
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
    template: bytes
    template_sha256: str


@dataclass(frozen=True)
class WorkstationRow:
    package: str
    channel: str
    repository: str
    acquisition: str
    module: str
    restore_mode: str
    policy: str
    origin: str
    purpose: str


@dataclass(frozen=True)
class StageEffect:
    effect_id: str
    package: str
    module: str
    detail: str


@dataclass(frozen=True)
class StageContext:
    action: str
    stage: str
    profile: str
    selected_modules: tuple[str, ...]
    stage_modules: tuple[str, ...]
    effects: tuple[StageEffect, ...]
    plan_fingerprint: str
    run_id: str
    attempt: int


@dataclass(frozen=True)
class FileSnapshot:
    exists: bool
    data: bytes | None
    sha256: str | None
    mode: int | None
    uid: int | None
    gid: int | None
    device: int | None
    inode: int | None


@dataclass(frozen=True)
class PlannerState:
    status: str
    repository: str
    keyring: str
    report: dict[str, Any]


@dataclass(frozen=True)
class PrivatePaths:
    root: Path
    cache: Path
    logs: Path
    backups: Path
    log: Path


@dataclass(frozen=True)
class CommandResult:
    status: int
    stdout: str
    stderr: str


ACTIVE_LOG: Path | None = None
ACTIVE_FINGERPRINT: str | None = None


def normalize_status(status: int) -> int:
    if status == 0:
        return 1
    if status < 0:
        return min(255, 128 + abs(status))
    return min(255, status)


def now() -> str:
    return dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def contains_control(value: str) -> bool:
    return any(ord(character) < 32 or ord(character) == 127 for character in value)


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def lexical_absolute(path: Path) -> Path:
    return Path(os.path.abspath(os.fspath(path.expanduser())))


def first_symlink(path: Path) -> Path | None:
    absolute = lexical_absolute(path)
    current = Path(absolute.anchor)
    for part in absolute.parts[1:]:
        current /= part
        try:
            if current.is_symlink():
                return current
        except OSError as error:
            raise AdapterFailure(1, f"could not inspect path component: {current}: {error}") from error
    return None


def read_regular(path: Path, label: str, *, require_single_link: bool = True) -> tuple[bytes, os.stat_result]:
    path = lexical_absolute(path)
    if first_symlink(path) is not None:
        raise AdapterFailure(1, f"{label} contains a symlink")
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    try:
        fd = os.open(path, flags)
    except FileNotFoundError as error:
        raise AdapterFailure(1, f"{label} is missing") from error
    except OSError as error:
        raise AdapterFailure(1, f"could not open {label}: {error}") from error
    try:
        before = os.fstat(fd)
        if not stat.S_ISREG(before.st_mode):
            raise AdapterFailure(1, f"{label} is not a regular file")
        if require_single_link and before.st_nlink != 1:
            raise AdapterFailure(1, f"{label} must have exactly one hard link")
        chunks: list[bytes] = []
        while True:
            chunk = os.read(fd, 1024 * 1024)
            if not chunk:
                break
            chunks.append(chunk)
        after = os.fstat(fd)
    except OSError as error:
        raise AdapterFailure(1, f"could not read {label}: {error}") from error
    finally:
        os.close(fd)
    if (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns) != (
        after.st_dev,
        after.st_ino,
        after.st_size,
        after.st_mtime_ns,
    ):
        raise AdapterFailure(1, f"{label} changed while being read")
    return b"".join(chunks), after


def safe_lines(path: Path, schema: str, label: str) -> tuple[list[str], bytes]:
    data, _info = read_regular(path, label)
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError as error:
        raise AdapterFailure(2, f"{label} is not valid UTF-8") from error
    lines = text.splitlines()
    if not lines:
        raise AdapterFailure(2, f"{label} is empty")
    if lines[0] != schema:
        raise AdapterFailure(2, f"{label} has unsupported or missing schema")
    return lines, data


def tsv_rows(lines: Sequence[str], fields: int, label: str) -> list[tuple[int, tuple[str, ...]]]:
    result: list[tuple[int, tuple[str, ...]]] = []
    for line_number, parts in enumerate(csv.reader(lines[1:], delimiter="\t"), 2):
        if not parts or not parts[0] or parts[0].startswith("#"):
            continue
        values = tuple(parts)
        if len(values) != fields or any(value == "" for value in values):
            raise AdapterFailure(2, f"invalid {label} row at line {line_number}")
        result.append((line_number, values))
    return result


def validate_https(url: str, label: str) -> None:
    if contains_control(url):
        raise AdapterFailure(2, f"{label} contains a control character")
    parsed = urlsplit(url)
    if (
        parsed.scheme != "https"
        or not parsed.netloc
        or not parsed.hostname
        or parsed.username is not None
        or parsed.password is not None
        or parsed.fragment
    ):
        raise AdapterFailure(2, f"{label} must be a fixed HTTPS URL without embedded credentials or fragment")


def load_policy() -> BootstrapPolicy:
    lines, _manifest_data = safe_lines(BOOTSTRAP_MANIFEST, "# schema=1", "archlinuxcn bootstrap manifest")
    rows = tsv_rows(lines, 12, "archlinuxcn bootstrap manifest")
    if len(rows) != 1:
        raise AdapterFailure(2, "archlinuxcn bootstrap manifest must contain exactly one policy row")
    line_number, values = rows[0]
    policy_values = BootstrapPolicy(*values, b"", "")
    if policy_values.package != EXPECTED_BOOTSTRAP_PACKAGE or PACKAGE_RE.fullmatch(policy_values.package) is None:
        raise AdapterFailure(2, f"unexpected bootstrap package at line {line_number}")
    if VERSION_RE.fullmatch(policy_values.version) is None:
        raise AdapterFailure(2, f"invalid bootstrap version at line {line_number}")
    if SHA256_RE.fullmatch(policy_values.sha256) is None or SHA256_RE.fullmatch(policy_values.signature_sha256) is None:
        raise AdapterFailure(2, f"invalid bootstrap SHA-256 at line {line_number}")
    if FINGERPRINT_RE.fullmatch(policy_values.signer_primary_fingerprint) is None:
        raise AdapterFailure(2, f"invalid bootstrap signer primary fingerprint at line {line_number}")
    validate_https(policy_values.package_url, "bootstrap package URL")
    validate_https(policy_values.signature_url, "bootstrap signature URL")
    validate_https(policy_values.server.replace("$arch", "x86_64"), "archlinuxcn server")
    if (
        policy_values.repository != EXPECTED_REPOSITORY
        or policy_values.siglevel != EXPECTED_SIGLEVEL
        or policy_values.database_signature != EXPECTED_DATABASE_SIGNATURE
        or policy_values.authorization != EXPECTED_AUTHORIZATION
        or "$arch" not in policy_values.server
    ):
        raise AdapterFailure(2, "archlinuxcn bootstrap policy lost a fixed trust invariant")
    template, _template_info = read_regular(TEMPLATE_PATH, "archlinuxcn repository template")
    try:
        template_text = template.decode("utf-8")
    except UnicodeDecodeError as error:
        raise AdapterFailure(2, "archlinuxcn repository template is not valid UTF-8") from error
    effective = [line for line in template_text.splitlines() if line and not line.startswith("#")]
    expected_effective = [
        f"[{policy_values.repository}]",
        f"SigLevel = {policy_values.siglevel}",
        f"Server = {policy_values.server}",
    ]
    if effective != expected_effective:
        raise AdapterFailure(2, "archlinuxcn repository template differs from the exact manifest policy")
    return BootstrapPolicy(*values, template, sha256_bytes(template))


def load_workstation_policy() -> dict[str, WorkstationRow]:
    lines, _data = safe_lines(WORKSTATION_MANIFEST, "# schema=1", "workstation package policy")
    result: dict[str, WorkstationRow] = {}
    for line_number, values in tsv_rows(lines, 9, "workstation package policy"):
        row = WorkstationRow(*values)
        if PACKAGE_RE.fullmatch(row.package) is None or TOKEN_RE.fullmatch(row.module) is None:
            raise AdapterFailure(2, f"unsafe workstation package/module at line {line_number}")
        if row.package in result:
            raise AdapterFailure(2, f"duplicate workstation package at line {line_number}: {row.package}")
        if any(contains_control(value) for value in values):
            raise AdapterFailure(2, f"control character in workstation policy at line {line_number}")
        result[row.package] = row
    if not result:
        raise AdapterFailure(2, "workstation package policy has no entries")
    return result


def parse_module_list(raw: str, label: str) -> tuple[str, ...]:
    if raw == "none":
        return ()
    if not raw or raw.startswith(",") or raw.endswith(",") or ",," in raw:
        raise AdapterFailure(2, f"{label} is not an exact module list")
    modules = tuple(raw.split(","))
    if len(set(modules)) != len(modules):
        raise AdapterFailure(2, f"{label} repeats a module")
    if any(TOKEN_RE.fullmatch(module) is None for module in modules):
        raise AdapterFailure(2, f"{label} contains an invalid module")
    return modules


def required_env(name: str) -> str:
    value = os.environ.get(name)
    if value is None or value == "" or contains_control(value):
        raise AdapterFailure(2, f"missing or unsafe {name}")
    return value


def expected_detail(row: WorkstationRow) -> str:
    return (
        f"package={row.package} channel={row.channel} repository={row.repository} "
        f"acquisition={row.acquisition}"
    )


def expected_bootstrap_detail(row: WorkstationRow) -> str:
    return (
        f"{expected_detail(row)} repository-config=fixed-include-fragment "
        "refresh=conditional-full-system-and-repository"
    )


def parse_effects(raw: str) -> list[dict[str, str]]:
    if len(raw.encode("utf-8")) > MAX_EFFECTS_JSON:
        raise AdapterFailure(2, "FULL_ORCHESTRATOR_EFFECTS_JSON exceeds the safety limit")
    try:
        value = json.loads(raw)
    except json.JSONDecodeError as error:
        raise AdapterFailure(2, f"FULL_ORCHESTRATOR_EFFECTS_JSON is malformed: {error}") from error
    if not isinstance(value, list) or not value:
        raise AdapterFailure(2, "stage adapter requires a non-empty effects array")
    result: list[dict[str, str]] = []
    for item in value:
        if not isinstance(item, dict) or set(item) != {"id", "module", "detail"}:
            raise AdapterFailure(2, "stage effect has malformed fields")
        if not all(isinstance(item[key], str) and item[key] and not contains_control(item[key]) for key in item):
            raise AdapterFailure(2, "stage effect contains an unsafe value")
        result.append(item)
    return result


def load_stage_context(workstation: dict[str, WorkstationRow], policy: BootstrapPolicy) -> StageContext:
    action = required_env("FULL_ORCHESTRATOR_ACTION")
    if action not in {"preflight", "execute", "verify"}:
        raise AdapterFailure(2, f"unsupported FULL_ORCHESTRATOR_ACTION: {action}")
    stage = required_env("FULL_ORCHESTRATOR_STAGE")
    if stage not in {"archlinuxcn-bootstrap", "archlinuxcn-packages"}:
        raise AdapterFailure(2, f"unsupported FULL_ORCHESTRATOR_STAGE: {stage}")
    profile = required_env("FULL_ORCHESTRATOR_PROFILE")
    if TOKEN_RE.fullmatch(profile) is None:
        raise AdapterFailure(2, "FULL_ORCHESTRATOR_PROFILE is unsafe")
    selected_modules = parse_module_list(required_env("FULL_ORCHESTRATOR_MODULES"), "selected modules")
    stage_modules = parse_module_list(required_env("FULL_ORCHESTRATOR_STAGE_MODULES"), "stage modules")
    fingerprint = required_env("FULL_ORCHESTRATOR_PLAN_FINGERPRINT")
    if SHA256_RE.fullmatch(fingerprint) is None:
        raise AdapterFailure(2, "FULL_ORCHESTRATOR_PLAN_FINGERPRINT is invalid")
    run_id = required_env("FULL_ORCHESTRATOR_RUN_ID")
    if RUN_ID_RE.fullmatch(run_id) is None or len(run_id) > 128:
        raise AdapterFailure(2, "FULL_ORCHESTRATOR_RUN_ID is unsafe")
    attempt_raw = required_env("FULL_ORCHESTRATOR_ATTEMPT")
    if not attempt_raw.isdecimal() or int(attempt_raw) < 1:
        raise AdapterFailure(2, "FULL_ORCHESTRATOR_ATTEMPT is invalid")
    raw_effects = parse_effects(required_env("FULL_ORCHESTRATOR_EFFECTS_JSON"))
    effects: list[StageEffect] = []
    seen: set[str] = set()
    for item in raw_effects:
        effect_id = item["id"]
        expected_prefix = "bootstrap:" if stage == "archlinuxcn-bootstrap" else "install:"
        if not effect_id.startswith(expected_prefix):
            raise AdapterFailure(2, f"stage effect has the wrong id prefix: {effect_id}")
        package = effect_id[len(expected_prefix) :]
        if PACKAGE_RE.fullmatch(package) is None or effect_id in seen:
            raise AdapterFailure(2, f"stage effect has an unsafe or duplicate package id: {effect_id}")
        seen.add(effect_id)
        row = workstation.get(package)
        if row is None:
            raise AdapterFailure(2, f"stage effect names an undeclared package: {package}")
        expected_effect_detail = expected_bootstrap_detail(row) if stage == "archlinuxcn-bootstrap" else expected_detail(row)
        if item["module"] != row.module or item["detail"] != expected_effect_detail:
            raise AdapterFailure(2, f"stage effect differs from workstation policy: {package}")
        if row.module not in selected_modules:
            raise AdapterFailure(2, f"stage effect module is not selected: {package}/{row.module}")
        effects.append(StageEffect(effect_id, package, row.module, item["detail"]))
    if stage == "archlinuxcn-bootstrap":
        row = workstation.get(policy.package)
        if (
            len(effects) != 1
            or effects[0].package != policy.package
            or row is None
            or row.channel != "pacman"
            or row.repository != policy.repository
            or row.acquisition != "archlinuxcn-bootstrap"
            or row.policy != "install"
        ):
            raise AdapterFailure(2, "bootstrap stage effect is not the exact reviewed keyring policy")
    else:
        packages = [effect.package for effect in effects]
        if packages != sorted(packages):
            raise AdapterFailure(2, "archlinuxcn package effects are not in deterministic package order")
        for effect in effects:
            row = workstation[effect.package]
            if not (
                row.channel == "pacman"
                and row.repository == "archlinuxcn"
                and row.acquisition == "pacman"
                and row.policy == "install"
            ):
                raise AdapterFailure(2, f"package is not eligible for archlinuxcn install stage: {effect.package}")
    effect_modules = {effect.module for effect in effects}
    expected_stage_modules = tuple(module for module in selected_modules if module in effect_modules)
    if stage_modules != expected_stage_modules:
        raise AdapterFailure(2, "FULL_ORCHESTRATOR_STAGE_MODULES does not exactly match effect modules")
    return StageContext(
        action,
        stage,
        profile,
        selected_modules,
        stage_modules,
        tuple(effects),
        fingerprint,
        run_id,
        int(attempt_raw),
    )


def inspect_directory(path: Path, label: str, *, private: bool = False, owner: int | None = None) -> None:
    path = lexical_absolute(path)
    if first_symlink(path) is not None:
        raise AdapterFailure(1, f"{label} contains a symlink")
    try:
        info = path.lstat()
    except OSError as error:
        raise AdapterFailure(1, f"could not inspect {label}: {error}") from error
    if not stat.S_ISDIR(info.st_mode):
        raise AdapterFailure(1, f"{label} is not a directory")
    if owner is not None and info.st_uid != owner:
        raise AdapterFailure(1, f"{label} is not owned by the expected user")
    if private and stat.S_IMODE(info.st_mode) != 0o700:
        raise AdapterFailure(1, f"{label} must have mode 700")


def load_execution_context() -> ExecutionContext:
    testing = os.environ.get("ARCHLINUXCN_APPLY_TESTING")
    test_root_raw = os.environ.get("ARCHLINUXCN_APPLY_TEST_ROOT")
    if testing is None and test_root_raw is None:
        return ExecutionContext(False, Path("/"))
    if testing != "1" or not test_root_raw:
        raise AdapterFailure(2, "test mode requires both ARCHLINUXCN_APPLY_TESTING=1 and ARCHLINUXCN_APPLY_TEST_ROOT")
    target = lexical_absolute(Path(test_root_raw))
    if target == Path("/"):
        raise AdapterFailure(2, "test mode cannot target the real root")
    inspect_directory(target, "isolated test root", private=True, owner=os.geteuid())
    return ExecutionContext(True, target)


def create_private_directory(path: Path) -> None:
    path = lexical_absolute(path)
    if path.exists() or path.is_symlink():
        inspect_directory(path, "private state directory", private=True, owner=os.geteuid())
        return
    missing: list[Path] = []
    current = path
    while not current.exists() and current != current.parent:
        missing.append(current)
        current = current.parent
    for directory in reversed(missing):
        try:
            directory.mkdir(mode=0o700)
            os.chmod(directory, 0o700)
        except FileExistsError:
            pass
        except OSError as error:
            raise AdapterFailure(1, f"could not create private state directory: {error}") from error
    inspect_directory(path, "private state directory", private=True, owner=os.geteuid())


def state_root() -> Path:
    xdg = os.environ.get("XDG_STATE_HOME")
    base = Path(xdg) if xdg else Path.home() / ".local/state"
    if not base.is_absolute():
        raise AdapterFailure(2, "XDG_STATE_HOME must be absolute")
    return lexical_absolute(base) / STATE_SUFFIX


def inspect_private_file(path: Path, label: str) -> None:
    _data, info = read_regular(path, label)
    if info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) != 0o600:
        raise AdapterFailure(1, f"{label} must be current-user-owned mode 600")


def prepare_private_paths(stage: StageContext) -> PrivatePaths:
    root = state_root()
    cache = root / "cache"
    logs = root / "logs"
    backups = root / "backups"
    for directory in (root, cache, logs, backups):
        create_private_directory(directory)
    log_path = logs / f"{stage.run_id}.log"
    if log_path.exists() or log_path.is_symlink():
        inspect_private_file(log_path, "adapter log")
    else:
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
        try:
            fd = os.open(log_path, flags, 0o600)
            os.fchmod(fd, 0o600)
            os.close(fd)
        except OSError as error:
            raise AdapterFailure(1, f"could not create private adapter log: {error}") from error
    return PrivatePaths(root, cache, logs, backups, log_path)


def append_log(path: Path, fingerprint: str, event: str, **fields: str | int | bool) -> None:
    record: dict[str, Any] = {
        "timestamp": now(),
        "plan_fingerprint": fingerprint,
        "event": event,
        **fields,
    }
    payload = json.dumps(record, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8") + b"\n"
    flags = os.O_WRONLY | os.O_APPEND | getattr(os, "O_NOFOLLOW", 0)
    try:
        fd = os.open(path, flags)
        info = os.fstat(fd)
        if (
            not stat.S_ISREG(info.st_mode)
            or info.st_nlink != 1
            or info.st_uid != os.geteuid()
            or stat.S_IMODE(info.st_mode) != 0o600
        ):
            raise AdapterFailure(1, "adapter log lost its private-file invariants")
        os.write(fd, payload)
        os.fsync(fd)
        os.close(fd)
    except OSError as error:
        raise AdapterFailure(1, f"could not append private adapter log: {error}") from error


def log_event(event: str, **fields: str | int | bool) -> None:
    if ACTIVE_LOG is not None and ACTIVE_FINGERPRINT is not None:
        append_log(ACTIVE_LOG, ACTIVE_FINGERPRINT, event, **fields)


def run_command(command: Sequence[str], *, environment: dict[str, str] | None = None) -> CommandResult:
    env = os.environ.copy() if environment is None else environment.copy()
    env["LC_ALL"] = "C"
    try:
        completed = subprocess.run(
            list(command),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=env,
            check=False,
        )
    except OSError as error:
        raise AdapterFailure(127, f"could not execute required command: {Path(command[0]).name}: {error}") from error
    status = completed.returncode if completed.returncode == 0 else normalize_status(completed.returncode)
    return CommandResult(status, completed.stdout, completed.stderr)


def production_environment(context: ExecutionContext) -> dict[str, str]:
    environment = os.environ.copy()
    environment["LC_ALL"] = "C"
    if not context.testing:
        environment["PATH"] = "/usr/bin:/bin"
    return environment


def command_path(name: str, context: ExecutionContext) -> str:
    if context.testing:
        found = shutil.which(name)
        if found is None:
            raise AdapterFailure(127, f"required command is unavailable: {name}")
        path = lexical_absolute(Path(found))
    else:
        path = Path("/usr/bin") / name
    try:
        info = path.stat(follow_symlinks=False)
    except OSError as error:
        raise AdapterFailure(127, f"required command is unavailable: {name}: {error}") from error
    if not stat.S_ISREG(info.st_mode) or not os.access(path, os.X_OK):
        raise AdapterFailure(127, f"required command is not an executable regular file: {name}")
    return str(path)


def run_planner(context: ExecutionContext, policy: BootstrapPolicy) -> PlannerState:
    planner_data, planner_info = read_regular(PLANNER_PATH, "existing archlinuxcn planner")
    if hashlib.sha256(planner_data).hexdigest() != ARCHLINUXCN_PLANNER_SHA256:
        raise AdapterFailure(1, "existing archlinuxcn planner SHA-256 mismatch")
    if not planner_info.st_mode & 0o111:
        raise AdapterFailure(2, "existing archlinuxcn planner is not executable")
    command = [str(PLANNER_PATH), "--root", str(context.target_root), "--json"]
    result = run_command(command, environment=production_environment(context))
    if not result.stdout.strip():
        raise AdapterFailure(result.status if result.status else 2, "archlinuxcn planner returned an empty result")
    try:
        report = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise AdapterFailure(2, f"archlinuxcn planner returned malformed JSON: {error}") from error
    if not isinstance(report, dict):
        raise AdapterFailure(2, "archlinuxcn planner did not return a JSON object")
    try:
        overall = report["overall"]["status"]
        repository = report["current"]["repository"]["state"]
        keyring = report["current"]["keyring"]["state"]
        source = report["source_policy"]
        safety = report["safety"]
    except (KeyError, TypeError) as error:
        raise AdapterFailure(2, "archlinuxcn planner omitted required classification fields") from error
    expected_status = {"ready": 0, "blocked": 1, "unavailable": 2}.get(overall)
    if expected_status is None or result.status != expected_status:
        raise AdapterFailure(2, "archlinuxcn planner exit/status classification is inconsistent")
    expected_source = {
        "package": policy.package,
        "version": policy.version,
        "sha256": policy.sha256,
        "signature_sha256": policy.signature_sha256,
        "signer_primary_fingerprint": policy.signer_primary_fingerprint,
    }
    keyring_source = source.get("keyring") if isinstance(source, dict) else None
    repository_source = source.get("repository") if isinstance(source, dict) else None
    if not isinstance(keyring_source, dict) or any(
        keyring_source.get(key) != value for key, value in expected_source.items()
    ):
        raise AdapterFailure(2, "archlinuxcn planner source policy differs from the loaded bootstrap manifest")
    if (
        not isinstance(repository_source, dict)
        or repository_source.get("name") != policy.repository
        or repository_source.get("server") != policy.server
        or repository_source.get("siglevel") != policy.siglevel
        or repository_source.get("database_signature") != policy.database_signature
        or not isinstance(repository_source.get("template"), dict)
        or repository_source["template"].get("sha256") != policy.template_sha256
        or source.get("authorization") != policy.authorization
    ):
        raise AdapterFailure(2, "archlinuxcn planner repository policy differs from manifest/template")
    if safety != {
        "read_only": True,
        "apply_authorized": False,
        "installer_apply_integration": False,
        "system_changes": False,
    }:
        raise AdapterFailure(2, "archlinuxcn planner lost its read-only safety contract")
    if overall != "ready":
        classification = repository if repository not in {"absent", "matching"} else keyring
        if classification in {"absent", "matching"}:
            classification = overall
        raise AdapterFailure(
            expected_status,
            f"planner classification={classification} overall={overall} repository={repository} keyring={keyring}",
        )
    if repository not in {"absent", "matching"} or keyring not in {"absent", "matching"}:
        raise AdapterFailure(
            2,
            f"planner returned an unsupported ready classification "
            f"repository={repository} keyring={keyring}",
        )
    log_event("planner-classification", classification=overall, repository=repository, keyring=keyring)
    return PlannerState(overall, repository, keyring, report)


def require_root_wrapper(context: ExecutionContext, *, allow_pending: bool = False) -> Path:
    if context.testing:
        home = lexical_absolute(Path.home())
    else:
        try:
            home = lexical_absolute(Path(pwd.getpwuid(os.geteuid()).pw_dir))
        except KeyError as error:
            raise AdapterFailure(1, "could not resolve the ordinary user's audited home") from error
    if first_symlink(home) is not None:
        raise AdapterFailure(1, "HOME path contains a symlink")
    wrapper = home / "scripts/desktop/gsudo"
    helper = home / "scripts/desktop/fuzzel-askpass"
    wrapper_present = wrapper.exists() or wrapper.is_symlink()
    helper_present = helper.exists() or helper.is_symlink()
    if allow_pending and not wrapper_present and not helper_present:
        wrapper_data, wrapper_info = read_regular(AUDITED_GSUDO_PAYLOAD, "pending reviewed gsudo payload")
        helper_data, helper_info = read_regular(AUDITED_ASKPASS_PAYLOAD, "pending reviewed askpass payload")
        if not wrapper_info.st_mode & 0o111 or not helper_info.st_mode & 0o111:
            raise AdapterFailure(1, "pending privilege wrapper payload is not executable")
        if sha256_bytes(wrapper_data) != PENDING_GSUDO_SHA256 or sha256_bytes(helper_data) != PENDING_ASKPASS_SHA256:
            raise AdapterFailure(1, "pending privilege wrapper payload differs from the fixed review")
        return wrapper
    if allow_pending and wrapper_present != helper_present:
        raise AdapterFailure(1, "privilege wrapper prerequisite is partially present")
    if context.testing:
        expected_wrapper = os.environ.get("ARCHLINUXCN_TEST_GSUDO_SHA256", "")
        expected_helper = os.environ.get("ARCHLINUXCN_TEST_ASKPASS_SHA256", "")
        if SHA256_RE.fullmatch(expected_wrapper) is None or SHA256_RE.fullmatch(expected_helper) is None:
            raise AdapterFailure(2, "test mode requires fixed reviewed wrapper/helper SHA-256 values")
    else:
        expected_wrapper = AUDITED_GSUDO_SHA256
        expected_helper = AUDITED_ASKPASS_SHA256
    for path, label, expected in (
        (wrapper, "gsudo wrapper", expected_wrapper),
        (helper, "gsudo askpass helper", expected_helper),
    ):
        data, info = read_regular(path, label)
        if (
            info.st_uid != os.geteuid()
            or not info.st_mode & 0o111
            or stat.S_IMODE(info.st_mode) & 0o022
        ):
            raise AdapterFailure(
                1,
                f"{label} must be current-user-owned, executable, and not group/world-writable",
            )
        if sha256_bytes(data) != expected:
            raise AdapterFailure(1, f"{label} differs from the reviewed fixed payload")
    return wrapper


def run_root(
    context: ExecutionContext,
    wrapper: Path,
    arguments: Sequence[str],
    description: str,
) -> None:
    command = [str(wrapper), "--", *arguments]
    result = run_command(command, environment=production_environment(context))
    if result.status != 0:
        log_event("root-command-failed", operation=description, exit=result.status)
        raise AdapterFailure(result.status, f"{description} through gsudo failed with exit {result.status}")
    log_event("root-command-passed", operation=description)


def fsync_directory(path: Path) -> None:
    try:
        fd = os.open(path, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0))
        os.fsync(fd)
        os.close(fd)
    except OSError as error:
        raise AdapterFailure(1, f"could not fsync private directory: {error}") from error


MINIMUM_BOOTSTRAP_FREE_BYTES = 64 * 1024 * 1024


def nearest_existing_directory(path: Path) -> Path:
    candidate = lexical_absolute(path)
    while not candidate.exists():
        if candidate.is_symlink():
            raise AdapterFailure(1, "future private state path contains a symlink")
        if candidate == candidate.parent:
            raise AdapterFailure(1, "could not find an existing filesystem for private state")
        candidate = candidate.parent
    if candidate.is_symlink() or not candidate.is_dir():
        raise AdapterFailure(1, "private state ancestor is symlinked or not a directory")
    return candidate


def inspect_preflight_cache(policy: BootstrapPolicy) -> None:
    root = state_root()
    cache = root / "cache"
    if first_symlink(cache) is not None:
        raise AdapterFailure(1, "private cache path contains a symlink")
    if root.exists():
        inspect_directory(root, "private state root", private=True, owner=os.geteuid())
    if cache.exists():
        inspect_directory(cache, "private download cache", private=True, owner=os.geteuid())
        expected = (
            (f"{policy.package}-{policy.version}.pkg.tar.zst", policy.sha256, "package"),
            (f"{policy.package}-{policy.version}.pkg.tar.zst.sig", policy.signature_sha256, "signature"),
        )
        for filename, digest, label in expected:
            path = cache / filename
            if not path.exists() and not path.is_symlink():
                continue
            data, info = read_regular(path, f"cached {label}")
            if info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) != 0o600:
                raise AdapterFailure(1, f"cached {label} is not current-user-owned mode 600")
            if sha256_bytes(data) != digest:
                raise AdapterFailure(1, f"cached {label} SHA-256 mismatch")
    filesystem = nearest_existing_directory(cache)
    try:
        free = shutil.disk_usage(filesystem).free
    except OSError as error:
        raise AdapterFailure(1, f"could not query bootstrap cache free space: {error}") from error
    if free < MINIMUM_BOOTSTRAP_FREE_BYTES:
        raise AdapterFailure(1, "bootstrap cache filesystem has less than 64 MiB free")


def probe_https_source(
    context: ExecutionContext,
    curl: str,
    url: str,
    label: str,
) -> None:
    command = [
        curl,
        "--disable",
        "--fail",
        "--show-error",
        "--silent",
        "--location",
        "--proto",
        "=https",
        "--proto-redir",
        "=https",
        "--tlsv1.2",
        "--head",
        "--",
        url,
    ]
    result = run_command(command, environment=production_environment(context))
    if result.status != 0:
        raise AdapterFailure(result.status, f"HTTPS {label} reachability check failed with exit {result.status}")


def signing_keyring(context: ExecutionContext) -> Path:
    path = target_path(context, Path("etc/pacman.d/gnupg/pubring.gpg"))
    _data, info = read_regular(path, "initialized pacman signing keyring")
    if not context.testing and (info.st_uid != 0 or stat.S_IMODE(info.st_mode) & 0o022):
        raise AdapterFailure(1, "initialized pacman signing keyring is not root-owned/read-only")
    return path


def preflight_bootstrap(context: ExecutionContext, policy: BootstrapPolicy) -> None:
    planner = run_planner(context, policy)
    require_root_wrapper(context, allow_pending=True)
    curl = command_path("curl", context)
    command_path("gpg", context)
    command_path("pacman", context)
    signing_keyring(context)
    inspect_preflight_cache(policy)
    probe_https_source(context, curl, policy.package_url, "package source")
    probe_https_source(context, curl, policy.signature_url, "signature source")
    if planner.repository == "matching":
        try:
            verify_repository_metadata(
                context,
                policy,
                allow_refresh_required=True,
            )
        except RefreshRequired:
            # A known missing database is a reviewed state that execute repairs
            # only through one full -Syu.  Other failed queries remain fatal.
            pass


def preflight_packages(
    context: ExecutionContext,
    policy: BootstrapPolicy,
    packages: Sequence[str],
) -> None:
    # Global preflight runs before the privilege-wrapper stage executes. An
    # exactly absent installed pair is safe only while both reviewed repository
    # payloads still match; execute/verify retain the strict installed check.
    require_root_wrapper(context, allow_pending=True)
    command_path("pacman", context)
    planner = run_planner(context, policy)
    if planner.repository != "matching" or planner.keyring != "matching":
        print(
            "archlinuxcn-apply: packages bootstrap expected-pending "
            f"repository={planner.repository} keyring={planner.keyring}"
        )
        return
    try:
        verify_repository_metadata(context, policy, allow_refresh_required=True)
    except RefreshRequired:
        print("archlinuxcn-apply: packages metadata refresh expected-pending")
        return
    for package in packages:
        query_sync_info(context, package)


def cached_asset(
    paths: PrivatePaths,
    context: ExecutionContext,
    *,
    label: str,
    filename: str,
    url: str,
    expected_sha256: str,
) -> Path:
    target = paths.cache / filename
    if target.exists() or target.is_symlink():
        data, info = read_regular(target, f"cached {label}")
        if info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) != 0o600:
            raise AdapterFailure(1, f"cached {label} is not current-user-owned mode 600")
        if sha256_bytes(data) != expected_sha256:
            raise AdapterFailure(1, f"cached {label} SHA-256 mismatch")
        log_event("cache-hit", asset=label, sha256=expected_sha256)
        return target
    try:
        fd, temporary_name = tempfile.mkstemp(prefix=f".{filename}.", dir=paths.cache)
        os.fchmod(fd, 0o600)
        os.close(fd)
    except OSError as error:
        raise AdapterFailure(1, f"could not create private {label} download file: {error}") from error
    temporary = Path(temporary_name)
    curl = command_path("curl", context)
    command = [
        curl,
        "--disable",
        "--fail",
        "--show-error",
        "--silent",
        "--location",
        "--proto",
        "=https",
        "--proto-redir",
        "=https",
        "--tlsv1.2",
        "--output",
        str(temporary),
        "--",
        url,
    ]
    result = run_command(command, environment=production_environment(context))
    if result.status != 0:
        temporary.unlink(missing_ok=True)
        log_event("download-failed", asset=label, exit=result.status)
        raise AdapterFailure(result.status, f"curl {label} download failed with exit {result.status}")
    data, info = read_regular(temporary, f"downloaded {label}")
    if info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) != 0o600:
        temporary.unlink(missing_ok=True)
        raise AdapterFailure(1, f"downloaded {label} lost private mode/ownership")
    actual = sha256_bytes(data)
    if actual != expected_sha256:
        temporary.unlink(missing_ok=True)
        log_event("download-hash-mismatch", asset=label)
        raise AdapterFailure(1, f"{label} SHA-256 mismatch")
    try:
        os.link(temporary, target, follow_symlinks=False)
        temporary.unlink()
        fsync_directory(paths.cache)
    except FileExistsError:
        temporary.unlink(missing_ok=True)
        existing, existing_info = read_regular(target, f"concurrent cached {label}")
        if (
            existing_info.st_uid != os.geteuid()
            or stat.S_IMODE(existing_info.st_mode) != 0o600
            or sha256_bytes(existing) != expected_sha256
        ):
            raise AdapterFailure(1, f"concurrent cached {label} differs from the reviewed asset")
    except OSError as error:
        temporary.unlink(missing_ok=True)
        raise AdapterFailure(1, f"could not commit cached {label}: {error}") from error
    log_event("download-verified", asset=label, sha256=expected_sha256)
    return target


def target_path(context: ExecutionContext, relative: Path) -> Path:
    return lexical_absolute(context.target_root / relative)


def inspect_target(
    context: ExecutionContext,
    relative: Path,
    label: str,
    *,
    allow_missing: bool,
) -> FileSnapshot:
    root = lexical_absolute(context.target_root)
    inspect_directory(root, "target root")
    current = root
    parts = relative.parts
    for part in parts[:-1]:
        current /= part
        try:
            info = current.lstat()
        except OSError as error:
            raise AdapterFailure(1, f"{label} parent is missing or unavailable: {error}") from error
        if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
            raise AdapterFailure(1, f"{label} parent contains a symlink or non-directory")
    path = root / relative
    try:
        info = path.lstat()
    except FileNotFoundError:
        if allow_missing:
            return FileSnapshot(False, None, None, None, None, None, None, None)
        raise AdapterFailure(1, f"{label} is missing")
    except OSError as error:
        raise AdapterFailure(1, f"could not inspect {label}: {error}") from error
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
        raise AdapterFailure(1, f"{label} is symlinked or not a regular file")
    if info.st_nlink != 1:
        raise AdapterFailure(1, f"{label} must have exactly one hard link")
    data, opened = read_regular(path, label)
    if not context.testing and (opened.st_uid != 0 or stat.S_IMODE(opened.st_mode) & 0o022):
        raise AdapterFailure(1, f"{label} is not root-owned and protected from non-root writes")
    return FileSnapshot(
        True,
        data,
        sha256_bytes(data),
        stat.S_IMODE(opened.st_mode),
        opened.st_uid,
        opened.st_gid,
        opened.st_dev,
        opened.st_ino,
    )


def write_private_file(path: Path, data: bytes) -> None:
    if path.exists() or path.is_symlink():
        raise AdapterFailure(1, "refusing to overwrite prior-state evidence")
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
    try:
        fd = os.open(path, flags, 0o600)
        os.fchmod(fd, 0o600)
        offset = 0
        while offset < len(data):
            offset += os.write(fd, data[offset:])
        os.fsync(fd)
        os.close(fd)
    except OSError as error:
        raise AdapterFailure(1, f"could not write private prior-state evidence: {error}") from error


def backup_prior_config(
    context: ExecutionContext,
    paths: PrivatePaths,
    stage: StageContext,
) -> tuple[FileSnapshot, FileSnapshot, Path]:
    pacman_conf = inspect_target(context, PACMAN_CONF_RELATIVE, "pacman.conf", allow_missing=False)
    fragment = inspect_target(context, FRAGMENT_RELATIVE, "managed archlinuxcn fragment", allow_missing=True)
    run_directory = paths.backups / stage.run_id
    create_private_directory(run_directory)
    backup = run_directory / f"attempt-{stage.attempt}-{now()}-{uuid.uuid4().hex[:8]}"
    create_private_directory(backup)
    assert pacman_conf.data is not None
    write_private_file(backup / "pacman.conf.prior", pacman_conf.data)
    if fragment.exists:
        assert fragment.data is not None
        write_private_file(backup / "fragment.prior", fragment.data)
    metadata = {
        "schema": 1,
        "automatic_rollback": False,
        "pacman_conf": snapshot_document(pacman_conf),
        "fragment": snapshot_document(fragment),
    }
    write_private_file(backup / "prior.json", json.dumps(metadata, indent=2, sort_keys=True).encode("utf-8") + b"\n")
    fsync_directory(backup)
    log_event("prior-config-backed-up", backup_id=backup.name)
    return pacman_conf, fragment, backup


def snapshot_document(snapshot_value: FileSnapshot) -> dict[str, Any]:
    return {
        "exists": snapshot_value.exists,
        "sha256": snapshot_value.sha256,
        "mode": snapshot_value.mode,
        "uid": snapshot_value.uid,
        "gid": snapshot_value.gid,
        "device": snapshot_value.device,
        "inode": snapshot_value.inode,
    }


def record_prior_classification(
    paths: PrivatePaths,
    stage: StageContext,
    planner: PlannerState,
) -> None:
    run_directory = paths.backups / stage.run_id
    create_private_directory(run_directory)
    evidence = run_directory / (
        f"prior-classification-attempt-{stage.attempt}-{now()}-{uuid.uuid4().hex[:8]}.json"
    )
    document = {
        "schema": 1,
        "automatic_rollback": False,
        "repository": planner.repository,
        "keyring": planner.keyring,
        "planner_overall": planner.status,
    }
    write_private_file(
        evidence,
        json.dumps(document, indent=2, sort_keys=True).encode("utf-8") + b"\n",
    )
    fsync_directory(run_directory)
    log_event("prior-classification-recorded", evidence_id=evidence.name)


def verify_detached_signature(
    context: ExecutionContext,
    paths: PrivatePaths,
    policy: BootstrapPolicy,
    package: Path,
    signature: Path,
) -> None:
    keyring_path = signing_keyring(context)
    try:
        homedir = Path(tempfile.mkdtemp(prefix="gpg-", dir=paths.cache))
        os.chmod(homedir, 0o700)
    except OSError as error:
        raise AdapterFailure(1, f"could not create private offline GPG home: {error}") from error
    gpg = command_path("gpg", context)
    command = [
        gpg,
        "--batch",
        "--no-options",
        "--homedir",
        str(homedir),
        "--no-auto-key-retrieve",
        "--no-default-keyring",
        "--keyring",
        str(keyring_path),
        "--status-fd",
        "1",
        "--trust-model",
        "always",
        "--verify",
        str(signature),
        str(package),
    ]
    try:
        result = run_command(command, environment=production_environment(context))
    finally:
        shutil.rmtree(homedir, ignore_errors=True)
    if result.status != 0:
        log_event("signature-verification-failed", exit=result.status)
        raise AdapterFailure(result.status, f"offline GPG signature verification failed with exit {result.status}")
    status_lines = [line for line in result.stdout.splitlines() if line.startswith("[GNUPG:] ")]
    bad_markers = ("BADSIG", "ERRSIG", "NO_PUBKEY", "EXPKEYSIG", "REVKEYSIG")
    if any(any(f" {marker} " in f" {line} " for marker in bad_markers) for line in status_lines):
        raise AdapterFailure(1, "offline GPG status reported an invalid signature")
    if not any(line.startswith("[GNUPG:] GOODSIG ") for line in status_lines):
        raise AdapterFailure(1, "offline GPG status omitted GOODSIG")
    valid = [line.split() for line in status_lines if line.startswith("[GNUPG:] VALIDSIG ")]
    if len(valid) != 1 or len(valid[0]) < 12:
        raise AdapterFailure(1, "offline GPG status omitted one exact VALIDSIG")
    primary = valid[0][-1]
    if FINGERPRINT_RE.fullmatch(primary) is None or primary != policy.signer_primary_fingerprint:
        raise AdapterFailure(1, "primary signer fingerprint mismatch")
    log_event("signature-verified", signer_primary_fingerprint=primary)


MISSING_DATABASE_RE = re.compile(r"^error: database not found: archlinuxcn\s*$")


def verify_repository_metadata(
    context: ExecutionContext,
    policy: BootstrapPolicy,
    *,
    allow_refresh_required: bool,
) -> None:
    pacman = command_path("pacman", context)
    result = run_command(
        [pacman, "-Si", "--", policy.package],
        environment=production_environment(context),
    )
    if result.status != 0:
        if (
            allow_refresh_required
            and result.status == 1
            and MISSING_DATABASE_RE.fullmatch(result.stderr.strip()) is not None
        ):
            log_event("metadata-refresh-required", query_exit=result.status)
            raise RefreshRequired(result.status)
        raise AdapterFailure(
            result.status,
            f"archlinuxcn metadata query failed with exit {result.status}",
        )
    parse_sync_info(result.stdout, policy.package)
    log_event("repository-metadata-verified", package=policy.package)


def verify_bootstrap(context: ExecutionContext, policy: BootstrapPolicy) -> None:
    planner = run_planner(context, policy)
    if planner.repository != "matching" or planner.keyring != "matching":
        raise AdapterFailure(
            1,
            f"bootstrap verification incomplete repository={planner.repository} keyring={planner.keyring}",
        )
    verify_repository_metadata(context, policy, allow_refresh_required=True)
    log_event("bootstrap-verified")


def execute_bootstrap(
    context: ExecutionContext,
    paths: PrivatePaths,
    stage: StageContext,
    policy: BootstrapPolicy,
) -> None:
    planner = run_planner(context, policy)
    refresh_required = planner.repository == "absent"
    if planner.repository == "matching":
        try:
            verify_repository_metadata(context, policy, allow_refresh_required=True)
        except RefreshRequired:
            refresh_required = True
    if planner.repository == "matching" and planner.keyring == "matching" and not refresh_required:
        log_event("bootstrap-idempotent-noop")
        return
    wrapper = require_root_wrapper(context)
    record_prior_classification(paths, stage, planner)
    if planner.keyring == "absent":
        package = cached_asset(
            paths,
            context,
            label="package",
            filename=f"{policy.package}-{policy.version}.pkg.tar.zst",
            url=policy.package_url,
            expected_sha256=policy.sha256,
        )
        signature = cached_asset(
            paths,
            context,
            label="signature",
            filename=f"{policy.package}-{policy.version}.pkg.tar.zst.sig",
            url=policy.signature_url,
            expected_sha256=policy.signature_sha256,
        )
        verify_detached_signature(context, paths, policy, package, signature)
        run_root(
            context,
            wrapper,
            ["pacman", "-U", "--needed", "--noconfirm", "--", str(package)],
            "fixed keyring package install",
        )
        after_keyring = run_planner(context, policy)
        if after_keyring.keyring != "matching":
            raise AdapterFailure(1, "keyring install completed but exact pinned version did not verify")
    if planner.repository == "absent":
        pacman_conf, fragment, _backup = backup_prior_config(context, paths, stage)
        assert pacman_conf.sha256 is not None
        fragment_state = "absent" if not fragment.exists else f"sha256:{fragment.sha256}"
        run_root(
            context,
            wrapper,
            [
                str(SCRIPT_PATH),
                "--root-helper",
                "--target-root",
                str(context.target_root),
                "--expected-pacman-conf-sha256",
                pacman_conf.sha256,
                "--expected-fragment-state",
                fragment_state,
            ],
            "fixed repository configuration write",
        )
        configured = run_planner(context, policy)
        if configured.repository != "matching" or configured.keyring != "matching":
            raise AdapterFailure(
                1,
                f"repository configuration did not re-verify before refresh "
                f"repository={configured.repository} keyring={configured.keyring}",
            )
    if refresh_required:
        run_root(context, wrapper, ["pacman", "-Syu", "--noconfirm"], "full system and repository refresh")
    verify_bootstrap(context, policy)


def parse_sync_info(output: str, package: str) -> tuple[str, str]:
    if not output.strip():
        raise AdapterFailure(1, f"pacman -Si for {package} returned an empty result")
    fields: dict[str, list[str]] = {}
    for raw in output.splitlines():
        if not raw.strip():
            continue
        if ":" not in raw:
            raise AdapterFailure(1, f"pacman -Si for {package} returned malformed output")
        key, value = raw.split(":", 1)
        key = key.strip()
        value = value.strip()
        if not key or not value:
            raise AdapterFailure(1, f"pacman -Si for {package} returned malformed output")
        fields.setdefault(key, []).append(value)
    names = fields.get("Name", [])
    repositories = fields.get("Repository", [])
    if names != [package] or repositories != ["archlinuxcn"]:
        actual = repositories[0] if len(repositories) == 1 else "malformed"
        raise AdapterFailure(1, f"pacman -Si repository ownership mismatch for {package}: {actual}")
    return names[0], repositories[0]


def query_sync_info(context: ExecutionContext, package: str) -> None:
    pacman = command_path("pacman", context)
    result = run_command([pacman, "-Si", "--", package], environment=production_environment(context))
    if result.status != 0:
        raise AdapterFailure(result.status, f"pacman -Si query failed for {package} with exit {result.status}")
    parse_sync_info(result.stdout, package)
    log_event("repository-package-verified", package=package, repository="archlinuxcn")


def query_installed(context: ExecutionContext, package: str) -> str:
    pacman = command_path("pacman", context)
    result = run_command([pacman, "-Q", "--", package], environment=production_environment(context))
    if result.status != 0:
        raise AdapterFailure(result.status, f"pacman -Q query failed for {package} with exit {result.status}")
    if not result.stdout.strip():
        raise AdapterFailure(1, f"pacman -Q for {package} returned an empty result")
    lines = [line for line in result.stdout.splitlines() if line.strip()]
    if len(lines) != 1:
        raise AdapterFailure(1, f"pacman -Q for {package} returned malformed output")
    fields = lines[0].split()
    if len(fields) != 2 or fields[0] != package or not fields[1] or contains_control(fields[1]):
        raise AdapterFailure(1, f"pacman -Q for {package} returned malformed output")
    return fields[1]


def verify_packages(context: ExecutionContext, policy: BootstrapPolicy, packages: Sequence[str]) -> None:
    verify_bootstrap(context, policy)
    for package in packages:
        version = query_installed(context, package)
        query_sync_info(context, package)
        log_event("installed-package-verified", package=package, version=version)


def execute_packages(
    context: ExecutionContext,
    policy: BootstrapPolicy,
    packages: Sequence[str],
) -> None:
    verify_bootstrap(context, policy)
    for package in packages:
        query_sync_info(context, package)
    wrapper = require_root_wrapper(context)
    run_root(
        context,
        wrapper,
        ["pacman", "-S", "--needed", "--noconfirm", "--", *packages],
        "exact archlinuxcn package install",
    )
    verify_packages(context, policy, packages)


def target_bytes_for_helper(
    context: ExecutionContext,
    relative: Path,
    label: str,
    allow_missing: bool,
) -> FileSnapshot:
    return inspect_target(context, relative, label, allow_missing=allow_missing)


def regular_file_snapshot(path: Path, label: str) -> FileSnapshot:
    data, info = read_regular(path, label)
    return FileSnapshot(
        True,
        data,
        sha256_bytes(data),
        stat.S_IMODE(info.st_mode),
        info.st_uid,
        info.st_gid,
        info.st_dev,
        info.st_ino,
    )


def snapshot_matches(actual: FileSnapshot | None, expected: FileSnapshot) -> bool:
    return actual == expected


def renameat2(path_from: Path, path_to: Path, flags: int, *, phase: str) -> None:
    """Commit a fixed target without an unconditional check/replace window."""
    sys.audit(
        "myarch.archlinuxcn-conditional-replace",
        os.fspath(path_from),
        os.fspath(path_to),
        phase,
    )
    if _RENAMEAT2 is None:
        raise AdapterFailure(1, "renameat2 is unavailable; cannot commit fixed target conditionally")
    result = _RENAMEAT2(
        AT_FDCWD,
        os.fsencode(path_from),
        AT_FDCWD,
        os.fsencode(path_to),
        flags,
    )
    if result != 0:
        error_number = ctypes.get_errno()
        raise OSError(error_number, os.strerror(error_number), os.fspath(path_to))


def recovery_error(message: str, temporary: Path, cause: OSError | None = None) -> AdapterFailure:
    error = AdapterFailure(1, f"{message}; recovery path={temporary}")
    setattr(error, "preserve_temporary", True)
    setattr(error, "recovery_path", temporary)
    if cause is not None:
        error.__cause__ = cause
    return error


def atomic_replace_target(path: Path, data: bytes, prior: FileSnapshot) -> None:
    """Install ``data`` only if ``path`` still has the reviewed identity.

    Existing targets are exchanged with the prepared inode.  The displaced
    entry is then compared by bytes, digest, mode, owner, device, and inode.  A
    mismatch is exchanged back and both names are retained whenever rollback
    cannot prove that no second writer intervened.  Missing targets use
    ``RENAME_NOREPLACE`` so a concurrent creator is never overwritten.
    """
    parent = path.parent
    if prior.exists:
        assert prior.mode is not None and prior.uid is not None and prior.gid is not None
        mode, uid, gid = prior.mode, prior.uid, prior.gid
    else:
        mode, uid, gid = 0o644, os.geteuid(), os.getegid()
    temporary: Path | None = None
    fd: int | None = None
    preserve_temporary = False
    try:
        fd, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=parent)
        temporary = Path(temporary_name)
        os.fchmod(fd, mode)
        os.fchown(fd, uid, gid)
        offset = 0
        while offset < len(data):
            written = os.write(fd, data[offset:])
            if written <= 0:
                raise OSError("short write while preparing fixed target")
            offset += written
        os.fsync(fd)
        os.close(fd)
        fd = None
        desired = regular_file_snapshot(temporary, "prepared fixed-target payload")

        if not prior.exists:
            try:
                renameat2(temporary, path, RENAME_NOREPLACE, phase="create")
            except OSError as error:
                raise AdapterFailure(
                    1,
                    f"fixed target changed at final create boundary {path}: {error}",
                ) from error
            temporary = None
            installed = regular_file_snapshot(path, "created fixed target")
            if not snapshot_matches(installed, desired):
                raise AdapterFailure(1, f"created fixed target changed before verification: {path}")
            fsync_directory(parent)
            return

        try:
            renameat2(temporary, path, RENAME_EXCHANGE, phase="replace")
        except OSError as error:
            raise AdapterFailure(
                1,
                f"fixed target changed at final replace boundary {path}: {error}",
            ) from error

        try:
            displaced = regular_file_snapshot(temporary, "displaced fixed target")
        except AdapterFailure:
            displaced = None
        try:
            installed = regular_file_snapshot(path, "installed fixed target")
        except AdapterFailure:
            installed = None

        if snapshot_matches(displaced, prior) and snapshot_matches(installed, desired):
            try:
                temporary.unlink()
            except OSError as error:
                preserve_temporary = True
                raise recovery_error(
                    f"could not remove displaced reviewed fixed target after commit: {error}",
                    temporary,
                    error,
                )
            temporary = None
            fsync_directory(parent)
            return

        # A different directory entry was displaced, or the installed entry was
        # changed before verification.  Exchange back before examining either
        # name again.  The random temporary is preserved on every uncertain path.
        preserve_temporary = True
        try:
            renameat2(temporary, path, RENAME_EXCHANGE, phase="rollback")
        except OSError as error:
            try:
                fsync_directory(parent)
            except AdapterFailure:
                pass
            raise recovery_error(
                f"fixed target changed at final replace boundary and rollback exchange failed: {error}",
                temporary,
                error,
            )

        try:
            rollback_target = regular_file_snapshot(path, "rolled-back fixed target")
            rollback_temporary = regular_file_snapshot(temporary, "retained fixed-target payload")
        except AdapterFailure as error:
            try:
                fsync_directory(parent)
            except AdapterFailure:
                pass
            raise recovery_error(
                f"fixed target changed during rollback verification: {error}",
                temporary,
            ) from error

        try:
            fsync_directory(parent)
        except AdapterFailure as error:
            raise recovery_error(
                f"fixed target rollback could not be made durable: {error}",
                temporary,
            ) from error

        if displaced is None or not snapshot_matches(rollback_target, displaced):
            raise recovery_error(
                "fixed target changed during rollback; conflicting entries retained",
                temporary,
            )
        if not snapshot_matches(rollback_temporary, desired):
            raise recovery_error(
                "fixed target changed during rollback; additional concurrent content retained",
                temporary,
            )

        # The competing target is restored and the exact installer proposal is
        # retained for explicit inspection; do not unlink across another race.
        raise recovery_error(
            "fixed target changed at final replace boundary; displaced entry restored",
            temporary,
        )
    except AdapterFailure:
        raise
    except OSError as error:
        raise AdapterFailure(1, f"conditional write failed for fixed target {path}: {error}") from error
    finally:
        if fd is not None:
            os.close(fd)
        if temporary is not None and not preserve_temporary:
            try:
                temporary.unlink()
            except FileNotFoundError:
                pass


def build_pacman_conf(current: bytes) -> bytes:
    try:
        text = current.decode("utf-8")
    except UnicodeDecodeError as error:
        raise AdapterFailure(1, "pacman.conf is not valid UTF-8") from error
    lines = text.splitlines()
    if any(re.fullmatch(r"\s*\[\s*archlinuxcn\s*\]\s*", line) for line in lines):
        raise AdapterFailure(1, "pacman.conf already contains an unmanaged archlinuxcn section")
    exact = [line for line in lines if line == INCLUDE_LINE]
    same_target = [
        line
        for line in lines
        if re.fullmatch(r"\s*Include\s*=\s*/etc/pacman\.d/my-archlinux-setup-archlinuxcn\.conf\s*", line)
    ]
    if len(exact) > 1 or len(same_target) > 1 or (same_target and exact != same_target):
        raise AdapterFailure(1, "pacman.conf contains a duplicate or non-exact managed Include")
    if exact:
        return current
    prefix = current
    if prefix and not prefix.endswith(b"\n"):
        prefix += b"\n"
    if prefix and not prefix.endswith(b"\n\n"):
        prefix += b"\n"
    return prefix + INCLUDE_LINE.encode("utf-8") + b"\n"


def root_helper(argv: Sequence[str]) -> int:
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--root-helper", action="store_true", required=True)
    parser.add_argument("--target-root", type=Path, required=True)
    parser.add_argument("--expected-pacman-conf-sha256", required=True)
    parser.add_argument("--expected-fragment-state", required=True)
    args = parser.parse_args(argv)
    context = load_execution_context()
    requested_root = lexical_absolute(args.target_root)
    if requested_root != context.target_root:
        raise AdapterFailure(2, "root helper target root differs from the fixed execution context")
    if context.testing:
        if os.geteuid() == 0:
            raise AdapterFailure(2, "test-mode root helper must never run with root privileges")
    elif os.geteuid() != 0 or requested_root != Path("/"):
        raise AdapterFailure(1, "production root helper requires EUID 0 and target root /")
    if SHA256_RE.fullmatch(args.expected_pacman_conf_sha256) is None:
        raise AdapterFailure(2, "root helper received an invalid pacman.conf fingerprint")
    fragment_expected: str | None
    if args.expected_fragment_state == "absent":
        fragment_expected = None
    elif args.expected_fragment_state.startswith("sha256:") and SHA256_RE.fullmatch(
        args.expected_fragment_state.removeprefix("sha256:")
    ):
        fragment_expected = args.expected_fragment_state.removeprefix("sha256:")
    else:
        raise AdapterFailure(2, "root helper received an invalid fragment state")
    policy = load_policy()
    pacman_conf = target_bytes_for_helper(context, PACMAN_CONF_RELATIVE, "pacman.conf", False)
    fragment = target_bytes_for_helper(context, FRAGMENT_RELATIVE, "managed archlinuxcn fragment", True)
    if pacman_conf.sha256 != args.expected_pacman_conf_sha256:
        raise AdapterFailure(1, "pacman.conf changed after ordinary-user backup")
    if fragment_expected is None and fragment.exists:
        raise AdapterFailure(1, "managed fragment appeared after ordinary-user backup")
    if fragment_expected is not None and (not fragment.exists or fragment.sha256 != fragment_expected):
        raise AdapterFailure(1, "managed fragment changed after ordinary-user backup")
    assert pacman_conf.data is not None
    new_pacman_conf = build_pacman_conf(pacman_conf.data)
    fragment_path = target_path(context, FRAGMENT_RELATIVE)
    pacman_conf_path = target_path(context, PACMAN_CONF_RELATIVE)
    if not fragment.exists or fragment.data != policy.template:
        atomic_replace_target(fragment_path, policy.template, fragment)
    if new_pacman_conf != pacman_conf.data:
        atomic_replace_target(pacman_conf_path, new_pacman_conf, pacman_conf)
    # Reinspect both fixed targets after the atomic writes.  No rollback/removal
    # is attempted if either post-check fails; prior evidence remains outside
    # this privileged helper.
    final_fragment = target_bytes_for_helper(context, FRAGMENT_RELATIVE, "managed archlinuxcn fragment", False)
    final_conf = target_bytes_for_helper(context, PACMAN_CONF_RELATIVE, "pacman.conf", False)
    if final_fragment.data != policy.template:
        raise AdapterFailure(1, "managed fragment post-write verification failed")
    assert final_conf.data is not None
    final_lines = final_conf.data.decode("utf-8").splitlines()
    if final_lines.count(INCLUDE_LINE) != 1:
        raise AdapterFailure(1, "pacman.conf Include post-write verification failed")
    print("archlinuxcn root helper: fixed targets verified")
    return 0


def ordinary_main(argv: Sequence[str]) -> int:
    if argv:
        raise AdapterFailure(2, "stage adapter accepts no ordinary command-line arguments")
    if os.geteuid() == 0:
        raise AdapterFailure(1, "stage adapter main process must run as an ordinary user")
    context = load_execution_context()
    policy = load_policy()
    workstation = load_workstation_policy()
    stage = load_stage_context(workstation, policy)
    packages = [effect.package for effect in stage.effects]
    if stage.action == "preflight":
        if stage.stage == "archlinuxcn-bootstrap":
            preflight_bootstrap(context, policy)
        else:
            preflight_packages(context, policy, packages)
        print(f"archlinuxcn-apply: stage={stage.stage} action=preflight passed")
        return 0
    # Execute and verify are post-bootstrap actions. Even an idempotent or
    # read-only path must bind the installed audited pair before creating its
    # private log/state; only global preflight permits exact pending payloads.
    require_root_wrapper(context)
    paths = prepare_private_paths(stage)
    global ACTIVE_LOG, ACTIVE_FINGERPRINT
    ACTIVE_LOG = paths.log
    ACTIVE_FINGERPRINT = stage.plan_fingerprint
    log_event(
        "adapter-start",
        stage=stage.stage,
        action=stage.action,
        run_id=stage.run_id,
        attempt=stage.attempt,
        testing=context.testing,
    )
    if stage.stage == "archlinuxcn-bootstrap":
        if stage.action == "execute":
            execute_bootstrap(context, paths, stage, policy)
        else:
            verify_bootstrap(context, policy)
    else:
        if stage.action == "execute":
            execute_packages(context, policy, packages)
        else:
            verify_packages(context, policy, packages)
    log_event("adapter-passed", stage=stage.stage, action=stage.action)
    print(f"archlinuxcn-apply: stage={stage.stage} action={stage.action} passed")
    return 0


def dispatch(argv: Sequence[str]) -> int:
    if argv and argv[0] == "--root-helper":
        return root_helper(argv)
    return ordinary_main(argv)


def main() -> None:
    try:
        status = dispatch(sys.argv[1:])
    except AdapterFailure as error:
        try:
            log_event("adapter-failed", exit=error.status, reason=error.message)
        except AdapterFailure as log_error:
            print(f"archlinuxcn-apply: warning: failure log unavailable: {log_error.message}", file=sys.stderr)
        print(f"archlinuxcn-apply: error: {error.message}", file=sys.stderr)
        raise SystemExit(error.status) from error
    except KeyboardInterrupt as error:
        print("archlinuxcn-apply: interrupted", file=sys.stderr)
        raise SystemExit(130) from error
    raise SystemExit(status)


if __name__ == "__main__":
    main()
