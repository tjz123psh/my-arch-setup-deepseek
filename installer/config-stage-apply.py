#!/usr/bin/env python3
"""Preflight, deploy, or verify the fingerprint-bound user configuration stage."""

from __future__ import annotations

import argparse
import ctypes
import csv
import hashlib
import secrets
import json
import os
import re
import stat
import sys
import tempfile
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable, NoReturn, Sequence

PROJECT_ROOT = Path(__file__).resolve().parent.parent
MODULES_PATH = PROJECT_ROOT / "manifests/modules.tsv"
PROFILES_PATH = PROJECT_ROOT / "manifests/profile-modules.tsv"
MAPPINGS_PATH = PROJECT_ROOT / "manifests/config-mappings.tsv"
TOKEN_RE = re.compile(r"[a-z0-9][a-z0-9-]*")
HEX64_RE = re.compile(r"[0-9a-f]{64}")
RUN_ID_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:-]*")
BACKUP_ID_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:-]{0,199}")
SAFE_PATH_RE = re.compile(r"[A-Za-z0-9._/+:-]+")
ALLOWED_SOURCE_MODES = frozenset({0o600, 0o644, 0o744, 0o755})
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


class ConfigFailure(Exception):
    def __init__(self, message: str, status: int = 2) -> None:
        super().__init__(message)
        self.status = normalize_status(status)


@dataclass(frozen=True)
class Mapping:
    scope: str
    module: str
    source_relative: str
    target_relative: str
    source: Path
    source_data: bytes
    source_sha256: str
    source_mode: int

    def effect(self) -> dict[str, str]:
        return {
            "detail": f"source={self.source_relative} target={self.target_relative}",
            "id": f"deploy:{self.target_relative}",
            "module": self.module,
            "payload_sha256": self.source_sha256,
        }


@dataclass(frozen=True)
class Context:
    action: str
    stage: str
    profile: str
    mode: str
    modules: tuple[str, ...]
    stage_modules: tuple[str, ...]
    fingerprint: str
    run_id: str
    attempt: int
    scope: str
    mappings: tuple[Mapping, ...]


@dataclass(frozen=True)
class TargetSnapshot:
    path: Path
    exists: bool
    data: bytes | None
    sha256: str | None
    mode: int | None
    device: int | None
    inode: int | None


@dataclass(frozen=True)
class TargetPlan:
    mapping: Mapping
    snapshot: TargetSnapshot
    classification: str


@dataclass(frozen=True)
class RestorePlan:
    mapping: Mapping
    snapshot: TargetSnapshot
    desired_exists: bool
    desired_data: bytes | None
    desired_sha256: str | None
    desired_mode: int | None
    classification: str


def normalize_status(status: int) -> int:
    if status < 0:
        return min(255, 128 + abs(status))
    if status == 0:
        return 0
    return min(255, status)


def fail(message: str, status: int = 2) -> NoReturn:
    raise ConfigFailure(message, status)


def contains_control(value: str) -> bool:
    return any(ord(character) < 32 or ord(character) == 127 for character in value)


def lexical_absolute(path: Path) -> Path:
    return Path(os.path.abspath(os.fspath(path.expanduser())))


def read_regular(
    path: Path, label: str, *, require_owner: bool = True
) -> tuple[bytes, os.stat_result]:
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    try:
        fd = os.open(path, flags)
    except FileNotFoundError as exc:
        fail(f"{label} is missing: {path}")
    except OSError as exc:
        fail(f"could not open {label} {path}: {exc}")
    try:
        before = os.fstat(fd)
        if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
            fail(f"{label} is not a single-link regular file: {path}")
        if require_owner and before.st_uid != os.geteuid():
            fail(f"{label} is not owned by the invoking user: {path}")
        chunks: list[bytes] = []
        while True:
            chunk = os.read(fd, 1024 * 1024)
            if not chunk:
                break
            chunks.append(chunk)
        after = os.fstat(fd)
    except OSError as exc:
        fail(f"could not read {label} {path}: {exc}")
    finally:
        os.close(fd)
    if (
        before.st_dev,
        before.st_ino,
        before.st_size,
        before.st_mtime_ns,
    ) != (
        after.st_dev,
        after.st_ino,
        after.st_size,
        after.st_mtime_ns,
    ):
        fail(f"{label} changed while being read: {path}")
    return b"".join(chunks), after


def safe_lines(path: Path, schema: str, label: str) -> list[str]:
    data, info = read_regular(path, label)
    if info.st_mode & 0o022:
        fail(f"{label} is group/world writable")
    try:
        lines = data.decode("utf-8").splitlines()
    except UnicodeDecodeError as exc:
        fail(f"{label} is not UTF-8: {exc}")
    if not lines or lines[0] != schema:
        fail(f"{label} has an unsupported schema")
    return lines


def rows(
    path: Path, schema: str, label: str, fields: int
) -> Iterable[tuple[int, list[str]]]:
    for line_number, parts in enumerate(
        csv.reader(safe_lines(path, schema, label)[1:], delimiter="\t"), 2
    ):
        if not parts or not parts[0] or parts[0].startswith("#"):
            continue
        if len(parts) != fields or not all(parts):
            fail(f"{label} has an invalid row at line {line_number}")
        if any(contains_control(value) for value in parts):
            fail(f"{label} has a control character at line {line_number}")
        yield line_number, parts


def safe_relative(value: str, label: str) -> None:
    path = Path(value)
    if (
        not value
        or path.is_absolute()
        or SAFE_PATH_RE.fullmatch(value) is None
        or any(part in {"", ".", ".."} for part in path.parts)
        or "//" in value
    ):
        fail(f"unsafe {label}: {value}")


def allowed_target(value: str) -> bool:
    return (
        value.startswith(".config/")
        or value.startswith(".local/share/fcitx5/rime/")
        or value.startswith("scripts/")
    )


def parse_modules(raw: str, label: str) -> tuple[str, ...]:
    if raw == "none":
        return ()
    values = tuple(raw.split(","))
    if not values or any(TOKEN_RE.fullmatch(value) is None for value in values):
        fail(f"{label} is malformed")
    if len(values) != len(set(values)):
        fail(f"{label} contains a duplicate")
    return values


def load_modules() -> dict[str, str]:
    result: dict[str, str] = {}
    for line_number, parts in rows(MODULES_PATH, "# schema=1", "module registry", 6):
        module, _availability, kind = parts[:3]
        if (
            TOKEN_RE.fullmatch(module) is None
            or module in result
            or kind not in {"selectable", "dependency"}
        ):
            fail(
                f"module registry has an unsafe, duplicate, or invalid module at line {line_number}"
            )
        result[module] = kind
    if not result:
        fail("module registry has no entries")
    return result


def load_profile_scope(profile: str, known_modules: set[str]) -> tuple[str, set[str]]:
    scopes: set[str] = set()
    offered: set[str] = set()
    profiles: set[str] = set()
    seen: set[tuple[str, str]] = set()
    for line_number, parts in rows(
        PROFILES_PATH, "# schema=1", "profile module manifest", 4
    ):
        row_profile, scope, module, state = parts
        profiles.add(row_profile)
        key = (row_profile, module)
        if key in seen:
            fail(f"profile module manifest repeats {row_profile}/{module}")
        seen.add(key)
        if TOKEN_RE.fullmatch(row_profile) is None or (
            scope != "none" and TOKEN_RE.fullmatch(scope) is None
        ):
            fail(
                f"profile module manifest has an unsafe profile/scope at line {line_number}"
            )
        if module not in known_modules or state not in {"selected", "disabled"}:
            fail(
                f"profile module manifest has an invalid module/state at line {line_number}"
            )
        if row_profile == profile:
            scopes.add(scope)
            offered.add(module)
    if profile not in profiles:
        fail(f"unknown profile: {profile}")
    if len(scopes) != 1:
        fail(f"profile {profile} has a missing or conflicting config scope")
    return next(iter(scopes)), offered


def load_mappings(
    scope: str,
    selected: set[str],
    known_modules: set[str],
    *,
    privilege_only: bool = False,
) -> tuple[Mapping, ...]:
    selected_rows: list[Mapping] = []
    seen: set[tuple[str, str]] = set()
    seen_sources: set[tuple[str, str]] = set()
    for line_number, parts in rows(
        MAPPINGS_PATH, "# schema=3", "config mapping manifest", 5
    ):
        row_scope, module, source_relative, target_relative, mode_raw = parts
        if TOKEN_RE.fullmatch(row_scope) is None or module not in known_modules:
            fail(f"config mapping has an invalid scope/module at line {line_number}")
        safe_relative(source_relative, "configuration source")
        safe_relative(target_relative, "configuration target")
        if not allowed_target(target_relative):
            fail(
                f"configuration target is outside approved user roots: {target_relative}"
            )
        if re.fullmatch(r"[0-7]{3,4}", mode_raw) is None:
            fail(f"config mapping has an invalid mode at line {line_number}")
        source_mode = int(mode_raw, 8)
        if source_mode not in ALLOWED_SOURCE_MODES:
            fail(f"config mapping declares an unsupported mode: {mode_raw}")
        key = (row_scope, target_relative)
        source_key = (row_scope, source_relative)
        if key in seen:
            fail(f"config mapping repeats target {row_scope}/{target_relative}")
        if source_key in seen_sources:
            fail(f"config mapping repeats source {row_scope}/{source_relative}")
        seen.add(key)
        seen_sources.add(source_key)
        source = PROJECT_ROOT / source_relative
        source_data, source_info = read_regular(
            source, f"configuration source {source_relative}"
        )
        if source_info.st_mode & 0o022:
            fail(f"configuration source is group/world writable: {source_relative}")
        privilege_target = target_relative in {
            "scripts/desktop/gsudo",
            "scripts/desktop/fuzzel-askpass",
        }
        if row_scope == scope and (
            (privilege_only and privilege_target)
            or (not privilege_only and not privilege_target and module in selected)
        ):
            selected_rows.append(
                Mapping(
                    row_scope,
                    module,
                    source_relative,
                    target_relative,
                    source,
                    source_data,
                    hashlib.sha256(source_data).hexdigest(),
                    source_mode,
                )
            )
    return tuple(sorted(selected_rows, key=lambda item: item.target_relative))


def require_env(name: str) -> str:
    value = os.environ.get(name)
    if value is None or value == "" or "\x00" in value:
        fail(f"required orchestrator environment is missing or unsafe: {name}")
    return value


def parse_effects(raw: str) -> tuple[dict[str, str], ...]:
    try:
        value: Any = json.loads(raw)
    except json.JSONDecodeError as exc:
        fail(f"FULL_ORCHESTRATOR_EFFECTS_JSON is malformed: {exc}")
    if not isinstance(value, list):
        fail("FULL_ORCHESTRATOR_EFFECTS_JSON is not an array")
    result: list[dict[str, str]] = []
    for index, item in enumerate(value):
        expected = {"detail", "id", "module", "payload_sha256"}
        if not isinstance(item, dict) or set(item) != expected:
            fail(f"configuration effect {index} has malformed fields")
        if not all(
            isinstance(item[key], str) and item[key] and not contains_control(item[key])
            for key in expected
        ):
            fail(f"configuration effect {index} has an unsafe value")
        if HEX64_RE.fullmatch(item["payload_sha256"]) is None:
            fail(f"configuration effect {index} has an invalid payload SHA-256")
        result.append(
            {key: item[key] for key in ("detail", "id", "module", "payload_sha256")}
        )
    return tuple(result)


def load_context() -> Context:
    action = require_env("FULL_ORCHESTRATOR_ACTION")
    stage = require_env("FULL_ORCHESTRATOR_STAGE")
    profile = require_env("FULL_ORCHESTRATOR_PROFILE")
    mode = require_env("FULL_ORCHESTRATOR_MODE")
    modules = parse_modules(
        require_env("FULL_ORCHESTRATOR_MODULES"), "FULL_ORCHESTRATOR_MODULES"
    )
    stage_modules = parse_modules(
        require_env("FULL_ORCHESTRATOR_STAGE_MODULES"),
        "FULL_ORCHESTRATOR_STAGE_MODULES",
    )
    effects = parse_effects(require_env("FULL_ORCHESTRATOR_EFFECTS_JSON"))
    fingerprint = require_env("FULL_ORCHESTRATOR_PLAN_FINGERPRINT")
    run_id = require_env("FULL_ORCHESTRATOR_RUN_ID")
    attempt_raw = require_env("FULL_ORCHESTRATOR_ATTEMPT")
    if action not in {"preflight", "execute", "verify"}:
        fail(f"unsupported orchestrator action: {action}")
    if stage not in {"privilege-wrapper", "user-config"}:
        fail(f"config stage adapter cannot handle stage: {stage}")
    if TOKEN_RE.fullmatch(profile) is None or mode not in {"new", "reconcile"}:
        fail("orchestrator profile or deployment mode is invalid")
    if HEX64_RE.fullmatch(fingerprint) is None or RUN_ID_RE.fullmatch(run_id) is None:
        fail("orchestrator fingerprint or run id is invalid")
    if not attempt_raw.isdigit() or int(attempt_raw) < 1:
        fail("orchestrator attempt is invalid")
    module_registry = load_modules()
    module_order = tuple(module_registry)
    if any(module not in module_registry for module in modules):
        fail("orchestrator selection references an unknown module")
    scope, offered = load_profile_scope(profile, set(module_registry))
    if any(
        module_registry[module] == "selectable" and module not in offered
        for module in modules
    ):
        fail(
            "orchestrator selection contains a selectable module not offered by the profile"
        )
    if scope == "none":
        fail(f"profile {profile} has no applicable configuration scope")
    mappings = load_mappings(
        scope,
        set(modules),
        set(module_registry),
        privilege_only=stage == "privilege-wrapper",
    )
    if not mappings:
        fail(f"applicable {stage} stage has no selected mapping")
    if stage == "privilege-wrapper" and {
        mapping.target_relative for mapping in mappings
    } != {
        "scripts/desktop/gsudo",
        "scripts/desktop/fuzzel-askpass",
    }:
        fail("privilege-wrapper stage does not contain the exact two reviewed targets")
    expected_modules = tuple(
        module for module in modules if any(row.module == module for row in mappings)
    )
    if stage_modules != expected_modules:
        fail("user-config stage modules do not reproduce the selected mapping policy")
    expected_effects = tuple(mapping.effect() for mapping in mappings)
    if effects != expected_effects:
        fail(
            "orchestrator effects do not exactly reproduce the reviewed config mappings"
        )
    return Context(
        action,
        stage,
        profile,
        mode,
        modules,
        stage_modules,
        fingerprint,
        run_id,
        int(attempt_raw),
        scope,
        mappings,
    )


def inspect_home() -> Path:
    raw = os.environ.get("HOME", "")
    if not raw or not os.path.isabs(raw):
        fail("HOME must be absolute")
    home = lexical_absolute(Path(raw))
    try:
        info = home.lstat()
    except OSError as exc:
        fail(f"could not inspect HOME: {exc}")
    if (
        stat.S_ISLNK(info.st_mode)
        or not stat.S_ISDIR(info.st_mode)
        or info.st_uid != os.geteuid()
        or info.st_mode & 0o022
    ):
        fail("HOME must be a non-writable real directory owned by the invoking user")
    return home


def inspect_components(home: Path, target: Path) -> None:
    try:
        relative = target.relative_to(home)
    except ValueError:
        fail(f"target escapes HOME: {target}")
    current = home
    for part in relative.parts[:-1]:
        current /= part
        try:
            info = current.lstat()
        except FileNotFoundError:
            return
        except OSError as exc:
            fail(f"could not inspect target parent {current}: {exc}")
        if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
            fail(f"target parent is not a real directory: {current}")
        if info.st_uid != os.geteuid() or info.st_mode & 0o022:
            fail(
                f"target parent is not exclusively writable by the invoking user: {current}"
            )


def inspect_target(home: Path, mapping: Mapping) -> TargetSnapshot:
    path = home / mapping.target_relative
    inspect_components(home, path)
    try:
        info = path.lstat()
    except FileNotFoundError:
        return TargetSnapshot(path, False, None, None, None, None, None)
    except OSError as exc:
        fail(f"could not inspect configuration target {mapping.target_relative}: {exc}")
    if (
        stat.S_ISLNK(info.st_mode)
        or not stat.S_ISREG(info.st_mode)
        or info.st_nlink != 1
    ):
        fail(
            f"configuration target is not a single-link regular file: {mapping.target_relative}"
        )
    if info.st_uid != os.geteuid():
        fail(
            f"configuration target is not owned by the invoking user: {mapping.target_relative}"
        )
    data, stable = read_regular(path, f"configuration target {mapping.target_relative}")
    return TargetSnapshot(
        path,
        True,
        data,
        hashlib.sha256(data).hexdigest(),
        stat.S_IMODE(stable.st_mode),
        stable.st_dev,
        stable.st_ino,
    )


def classify(context: Context, home: Path) -> tuple[TargetPlan, ...]:
    result: list[TargetPlan] = []
    for mapping in context.mappings:
        snapshot = inspect_target(home, mapping)
        if not snapshot.exists:
            classification = "create"
        elif (
            snapshot.sha256 == mapping.source_sha256
            and snapshot.mode == mapping.source_mode
        ):
            classification = "unchanged"
        else:
            classification = "replace"
        result.append(TargetPlan(mapping, snapshot, classification))
    return tuple(result)


def ensure_external_parent(path: Path) -> None:
    if path.exists() or path.is_symlink():
        try:
            info = path.lstat()
        except OSError as exc:
            fail(f"could not inspect state parent {path}: {exc}")
        if (
            stat.S_ISLNK(info.st_mode)
            or not stat.S_ISDIR(info.st_mode)
            or info.st_uid != os.geteuid()
        ):
            fail(f"state parent is unsafe: {path}")
        if info.st_mode & 0o002:
            fail(f"state parent is world-writable: {path}")
        return
    try:
        path.mkdir(parents=True, mode=0o700)
        os.chmod(path, 0o700)
    except OSError as exc:
        fail(f"could not create state parent {path}: {exc}")


def ensure_private_directory(path: Path) -> None:
    if path.exists() or path.is_symlink():
        try:
            info = path.lstat()
        except OSError as exc:
            fail(f"could not inspect private directory {path}: {exc}")
        if (
            stat.S_ISLNK(info.st_mode)
            or not stat.S_ISDIR(info.st_mode)
            or info.st_uid != os.geteuid()
            or stat.S_IMODE(info.st_mode) != 0o700
        ):
            fail(f"private directory is unsafe or not mode 700: {path}")
        return
    ensure_private_directory(
        path.parent
    ) if path.parent.name == "my-archlinux-setup" else ensure_external_parent(
        path.parent
    )
    try:
        path.mkdir(mode=0o700)
        os.chmod(path, 0o700)
    except OSError as exc:
        fail(f"could not create private directory {path}: {exc}")


def state_base(home: Path) -> Path:
    raw = os.environ.get("XDG_STATE_HOME") or str(home / ".local/state")
    if not os.path.isabs(raw):
        fail("XDG_STATE_HOME must resolve to an absolute path")
    return lexical_absolute(Path(raw))


def writable_state_directories(home: Path) -> tuple[Path, Path, Path]:
    base = state_base(home)
    ensure_external_parent(base)
    project = base / "my-archlinux-setup"
    ensure_private_directory(project)
    config_state = project / "config-stage"
    backups = project / "backups"
    ensure_private_directory(config_state)
    ensure_private_directory(backups)
    return project, config_state, backups


def state_paths(context: Context, home: Path) -> tuple[Path, Path, Path]:
    project, config_state, backups = writable_state_directories(home)
    provenance = config_state / f"{context.fingerprint}-{context.stage}.json"
    backup_root = backups / f"{context.run_id}-{context.stage}"
    return provenance, backup_root, project


def fsync_directory(path: Path) -> None:
    try:
        fd = os.open(
            path,
            os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0),
        )
        os.fsync(fd)
        os.close(fd)
    except OSError as exc:
        fail(f"could not fsync directory {path}: {exc}")


def renameat2(
    path_from: Path, path_to: Path, flags: int, *, audit: bool = True
) -> None:
    if audit:
        sys.audit(
            "myarch.config-conditional-replace",
            os.fspath(path_from),
            os.fspath(path_to),
        )
    if _RENAMEAT2 is None:
        fail("renameat2 is unavailable; cannot commit configuration conditionally", 1)
    ctypes.set_errno(0)
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


def regular_file_snapshot(path: Path, label: str) -> TargetSnapshot:
    data, info = read_regular(path, label)
    return TargetSnapshot(
        path,
        True,
        data,
        hashlib.sha256(data).hexdigest(),
        stat.S_IMODE(info.st_mode),
        info.st_dev,
        info.st_ino,
    )


def displaced_snapshot_matches(path: Path, expected: TargetSnapshot) -> bool:
    if (
        not expected.exists
        or expected.data is None
        or expected.sha256 is None
        or expected.mode is None
    ):
        return False
    try:
        data, info = read_regular(path, "displaced configuration target")
    except ConfigFailure:
        return False
    return (
        data,
        hashlib.sha256(data).hexdigest(),
        stat.S_IMODE(info.st_mode),
        info.st_dev,
        info.st_ino,
    ) == (
        expected.data,
        expected.sha256,
        expected.mode,
        expected.device,
        expected.inode,
    )


def conditional_replace_target(
    temporary: Path, target: Path, expected: TargetSnapshot
) -> None:
    if not expected.exists:
        try:
            renameat2(temporary, target, RENAME_NOREPLACE)
        except OSError as exc:
            fail(
                f"configuration target changed at final create boundary: {target}: {exc}",
                1,
            )
        return

    installer_temporary = regular_file_snapshot(
        temporary, "installer temporary payload"
    )
    try:
        renameat2(temporary, target, RENAME_EXCHANGE)
    except OSError as exc:
        fail(
            f"configuration target changed at final replace boundary: {target}: {exc}",
            1,
        )
    if displaced_snapshot_matches(temporary, expected):
        try:
            temporary.unlink()
        except OSError as exc:
            fail(f"could not remove displaced reviewed target {temporary}: {exc}", 1)
        return

    try:
        renameat2(temporary, target, RENAME_EXCHANGE, audit=False)
    except OSError as exc:
        error = ConfigFailure(
            f"configuration target changed at final replace boundary and rollback exchange failed; "
            f"conflicting bytes retained; recovery path={temporary}: {exc}",
            1,
        )
        setattr(error, "preserve_temporary", True)
        setattr(error, "recovery_path", temporary)
        raise error from exc
    if not displaced_snapshot_matches(temporary, installer_temporary):
        error = ConfigFailure(
            f"configuration target changed at final replace boundary; rollback restored the displaced target, "
            f"but additional concurrent content was retained; recovery path={temporary}",
            1,
        )
        setattr(error, "preserve_temporary", True)
        setattr(error, "recovery_path", temporary)
        raise error
    try:
        temporary.unlink()
    except OSError as exc:
        fail(
            f"could not remove verified installer temporary payload {temporary}: {exc}",
            1,
        )
    fail(f"configuration target changed at final replace boundary: {target}", 1)


def conditional_remove_target(target: Path, expected: TargetSnapshot) -> None:
    if not expected.exists:
        return
    fd: int | None = None
    quarantine: Path | None = None
    try:
        fd, name = tempfile.mkstemp(
            prefix=f".myarch-remove-{target.name}.", dir=target.parent
        )
        quarantine = Path(name)
        os.close(fd)
        fd = None
        quarantine.unlink()
        sys.audit(
            "myarch.config-conditional-remove", os.fspath(target), os.fspath(quarantine)
        )
        renameat2(target, quarantine, RENAME_NOREPLACE, audit=False)
    except OSError as exc:
        fail(
            f"configuration target changed at final remove boundary: {target}: {exc}", 1
        )
    finally:
        if fd is not None:
            os.close(fd)

    assert quarantine is not None
    if displaced_snapshot_matches(quarantine, expected):
        try:
            quarantine.unlink()
        except OSError as exc:
            fail(f"could not remove approved displaced target {quarantine}: {exc}", 1)
        return
    try:
        renameat2(quarantine, target, RENAME_NOREPLACE, audit=False)
    except OSError as exc:
        fail(
            f"configuration target changed at final remove boundary and rollback rename failed; "
            f"conflicting bytes retained at {quarantine}: {exc}",
            1,
        )
    fail(f"configuration target changed at final remove boundary: {target}", 1)


def atomic_write(path: Path, data: bytes, mode: int) -> None:
    ensure_private_directory(path.parent)
    fd: int | None = None
    temporary: Path | None = None
    try:
        fd, name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
        temporary = Path(name)
        os.fchmod(fd, mode)
        offset = 0
        while offset < len(data):
            offset += os.write(fd, data[offset:])
        os.fsync(fd)
        os.close(fd)
        fd = None
        os.replace(temporary, path)
        temporary = None
        os.chmod(path, mode)
        fsync_directory(path.parent)
    except OSError as exc:
        fail(f"could not atomically write {path}: {exc}")
    finally:
        if fd is not None:
            os.close(fd)
        if temporary is not None:
            try:
                temporary.unlink()
            except FileNotFoundError:
                pass


def atomic_json(path: Path, document: dict[str, Any]) -> None:
    atomic_write(
        path,
        json.dumps(document, ensure_ascii=False, sort_keys=True, indent=2).encode(
            "utf-8"
        )
        + b"\n",
        0o600,
    )


def policy_sha256() -> str:
    digest = hashlib.sha256()
    for label, path in (
        ("modules", MODULES_PATH),
        ("profiles", PROFILES_PATH),
        ("mappings", MAPPINGS_PATH),
    ):
        data, _info = read_regular(path, f"{label} policy manifest")
        digest.update(label.encode("ascii") + b"\0" + data + b"\0")
    return digest.hexdigest()


def inspect_optional_directory(path: Path, label: str, *, private: bool) -> bool:
    try:
        info = path.lstat()
    except FileNotFoundError:
        return False
    except OSError as exc:
        fail(f"could not inspect {label} {path}: {exc}")
    if (
        stat.S_ISLNK(info.st_mode)
        or not stat.S_ISDIR(info.st_mode)
        or info.st_uid != os.geteuid()
    ):
        fail(f"{label} is unsafe: {path}")
    mode = stat.S_IMODE(info.st_mode)
    if (private and mode != 0o700) or (not private and info.st_mode & 0o002):
        fail(f"{label} has unsafe permissions: {path}")
    return True


def readonly_backups_root(home: Path) -> Path | None:
    base = state_base(home)
    if not inspect_optional_directory(base, "state base", private=False):
        return None
    project = base / "my-archlinux-setup"
    if not inspect_optional_directory(project, "private project state", private=True):
        return None
    backups = project / "backups"
    if not inspect_optional_directory(
        backups, "private backup directory", private=True
    ):
        return None
    return backups


def backup_mode(value: Any, label: str) -> int:
    if not isinstance(value, str) or re.fullmatch(r"[0-7]{3}", value) is None:
        fail(f"{label} has an invalid file mode")
    return int(value, 8)


def validate_backup_tree(root: Path, document: dict[str, Any]) -> None:
    expected: dict[Path, dict[str, Any]] = {}
    for entry in document["targets"]:
        if entry["exists"]:
            expected[root / entry["backup"]] = entry
    observed: set[Path] = set()
    try:
        iterator = os.walk(root, topdown=True, followlinks=False)
        for raw_directory, directory_names, file_names in iterator:
            directory = Path(raw_directory)
            info = directory.lstat()
            if (
                stat.S_ISLNK(info.st_mode)
                or not stat.S_ISDIR(info.st_mode)
                or info.st_uid != os.geteuid()
                or stat.S_IMODE(info.st_mode) != 0o700
            ):
                fail(f"backup directory tree is unsafe: {directory}")
            for name in directory_names:
                child = directory / name
                child_info = child.lstat()
                if stat.S_ISLNK(child_info.st_mode) or not stat.S_ISDIR(
                    child_info.st_mode
                ):
                    fail(f"backup directory tree contains an unsafe entry: {child}")
            for name in file_names:
                path = directory / name
                if path == root / ".backup.json":
                    continue
                entry = expected.get(path)
                if entry is None:
                    fail(
                        f"backup directory contains an unrecorded file: {path.relative_to(root)}"
                    )
                data, info = read_regular(
                    path, f"backup payload {path.relative_to(root)}"
                )
                if hashlib.sha256(data).hexdigest() != entry["sha256"]:
                    fail(f"backup payload hash mismatch: {path.relative_to(root)}")
                if stat.S_IMODE(info.st_mode) != backup_mode(
                    entry["mode"], "backup target"
                ):
                    fail(f"backup payload mode mismatch: {path.relative_to(root)}")
                observed.add(path)
    except ConfigFailure:
        raise
    except OSError as exc:
        fail(f"could not enumerate backup directory {root}: {exc}")
    for path, entry in expected.items():
        if entry["captured"] and path not in observed:
            fail(f"captured backup payload is missing: {path.relative_to(root)}")


def load_backup_document(root: Path) -> dict[str, Any]:
    if not inspect_optional_directory(root, "backup root", private=True):
        fail(f"backup does not exist: {root.name}", 1)
    manifest = root / ".backup.json"
    data, info = read_regular(manifest, f"backup metadata for {root.name}")
    if stat.S_IMODE(info.st_mode) != 0o600:
        fail(f"backup metadata is not mode 600: {root.name}")
    try:
        value: Any = json.loads(data)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        fail(f"backup metadata is malformed for {root.name}: {exc}")
    expected = {
        "schema",
        "id",
        "kind",
        "profile",
        "stage",
        "mode",
        "policy_sha256",
        "plan_fingerprint",
        "run_id",
        "source_backup_id",
        "status",
        "targets",
    }
    if (
        not isinstance(value, dict)
        or set(value) != expected
        or value.get("schema") != 1
    ):
        fail(f"backup metadata has an unsupported schema for {root.name}")
    backup_id = value["id"]
    if (
        not isinstance(backup_id, str)
        or BACKUP_ID_RE.fullmatch(backup_id) is None
        or backup_id != root.name
    ):
        fail(f"backup metadata id is unsafe or mismatched for {root.name}")
    if value["kind"] not in {"deployment-replacement", "pre-restore"}:
        fail(f"backup metadata kind is invalid for {backup_id}")
    if (
        not isinstance(value["profile"], str)
        or TOKEN_RE.fullmatch(value["profile"]) is None
    ):
        fail(f"backup metadata profile is invalid for {backup_id}")
    if value["stage"] not in {"privilege-wrapper", "user-config"}:
        fail(f"backup metadata stage is invalid for {backup_id}")
    if value["mode"] not in {"new", "reconcile", "restore"}:
        fail(f"backup metadata mode is invalid for {backup_id}")
    if (
        not isinstance(value["policy_sha256"], str)
        or HEX64_RE.fullmatch(value["policy_sha256"]) is None
    ):
        fail(f"backup metadata policy digest is invalid for {backup_id}")
    if (
        not isinstance(value["plan_fingerprint"], str)
        or HEX64_RE.fullmatch(value["plan_fingerprint"]) is None
    ):
        fail(f"backup metadata plan fingerprint is invalid for {backup_id}")
    if (
        not isinstance(value["run_id"], str)
        or RUN_ID_RE.fullmatch(value["run_id"]) is None
    ):
        fail(f"backup metadata run id is invalid for {backup_id}")
    source_id = value["source_backup_id"]
    if source_id is not None and (
        not isinstance(source_id, str)
        or BACKUP_ID_RE.fullmatch(source_id) is None
        or source_id == backup_id
    ):
        fail(f"backup metadata source id is invalid for {backup_id}")
    if value["status"] not in {"running", "completed", "failed"} or not isinstance(
        value["targets"], list
    ):
        fail(f"backup metadata status/targets are invalid for {backup_id}")
    targets: list[dict[str, Any]] = []
    seen: set[str] = set()
    target_fields = {
        "target",
        "source",
        "exists",
        "sha256",
        "mode",
        "backup",
        "captured",
    }
    for index, entry in enumerate(value["targets"]):
        if not isinstance(entry, dict) or set(entry) != target_fields:
            fail(f"backup target {index} has malformed fields for {backup_id}")
        target = entry["target"]
        source = entry["source"]
        if not isinstance(target, str) or not isinstance(source, str):
            fail(f"backup target {index} has invalid paths for {backup_id}")
        safe_relative(target, "backup target")
        safe_relative(source, "backup source")
        if not allowed_target(target) or target in seen:
            fail(
                f"backup target {index} is outside approved roots or duplicated for {backup_id}"
            )
        seen.add(target)
        if not isinstance(entry["exists"], bool) or not isinstance(
            entry["captured"], bool
        ):
            fail(f"backup target {index} has invalid state for {backup_id}")
        if entry["exists"]:
            if (
                not isinstance(entry["sha256"], str)
                or HEX64_RE.fullmatch(entry["sha256"]) is None
                or backup_mode(entry["mode"], "backup target") > 0o777
                or entry["backup"] != target
            ):
                fail(
                    f"backup target {index} has invalid payload metadata for {backup_id}"
                )
        elif (
            entry["sha256"] is not None
            or entry["mode"] is not None
            or entry["backup"] is not None
        ):
            fail(f"absent backup target {index} has payload metadata for {backup_id}")
        targets.append(entry)
    value["targets"] = sorted(targets, key=lambda item: item["target"])
    if value["status"] == "completed" and any(
        not entry["captured"] for entry in targets
    ):
        fail(f"completed backup contains an uncaptured target: {backup_id}")
    validate_backup_tree(root, value)
    return value


def approved_backup_mappings(document: dict[str, Any]) -> dict[str, Mapping]:
    registry = load_modules()
    scope, _offered = load_profile_scope(document["profile"], set(registry))
    if scope == "none":
        fail(
            f"backup profile no longer has an approved config scope: {document['profile']}",
            1,
        )
    mappings = load_mappings(
        scope,
        set(registry),
        set(registry),
        privilege_only=document["stage"] == "privilege-wrapper",
    )
    by_target = {mapping.target_relative: mapping for mapping in mappings}
    for entry in document["targets"]:
        mapping = by_target.get(entry["target"])
        if mapping is None or mapping.source_relative != entry["source"]:
            fail(
                f"backup target is no longer in the approved profile scope: {entry['target']}",
                1,
            )
    return by_target


def backup_inventory(home: Path) -> list[tuple[Path, dict[str, Any]]]:
    backups = readonly_backups_root(home)
    if backups is None:
        return []
    try:
        entries = sorted(backups.iterdir(), key=lambda item: item.name)
    except OSError as exc:
        fail(f"could not enumerate private backups: {exc}")
    result: list[tuple[Path, dict[str, Any]]] = []
    for root in entries:
        if BACKUP_ID_RE.fullmatch(root.name) is None:
            fail(f"private backup directory contains an unsafe entry: {root.name}")
        document = load_backup_document(root)
        try:
            approved_backup_mappings(document)
            policy_blocker: str | None = None
        except ConfigFailure as exc:
            if exc.status != 1:
                raise
            policy_blocker = str(exc)
        document["_policy_blocker"] = policy_blocker
        result.append((root, document))
    return result


def list_backups(home: Path) -> int:
    public: list[dict[str, Any]] = []
    for _root, document in backup_inventory(home):
        blocker = document.get("_policy_blocker")
        public.append(
            {
                "id": document["id"],
                "kind": document["kind"],
                "profile": document["profile"],
                "stage": document["stage"],
                "status": document["status"],
                "source_backup_id": document["source_backup_id"],
                "targets": [entry["target"] for entry in document["targets"]],
                "restorable": document["status"] == "completed" and blocker is None,
                "blocker": blocker,
            }
        )
    print(
        json.dumps(
            {"schema": 1, "backups": public},
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
        )
    )
    return 0


def deployment_backup_document(context: Context, backup_id: str) -> dict[str, Any]:
    return {
        "schema": 1,
        "id": backup_id,
        "kind": "deployment-replacement",
        "profile": context.profile,
        "stage": context.stage,
        "mode": context.mode,
        "policy_sha256": policy_sha256(),
        "plan_fingerprint": context.fingerprint,
        "run_id": context.run_id,
        "source_backup_id": None,
        "status": "completed",
        "targets": [],
    }


def validate_deployment_backup(
    context: Context, root: Path, document: dict[str, Any]
) -> None:
    expected = {
        "id": root.name,
        "kind": "deployment-replacement",
        "profile": context.profile,
        "stage": context.stage,
        "mode": context.mode,
        "policy_sha256": policy_sha256(),
        "plan_fingerprint": context.fingerprint,
        "run_id": context.run_id,
        "source_backup_id": None,
    }
    for key, value in expected.items():
        if document[key] != value:
            fail(f"existing deployment backup has mismatched {key}: {root.name}")
    approved_backup_mappings(document)


def ensure_backup_parents(root: Path, relative: str) -> Path:
    path = root / relative
    parent = path.parent
    missing: list[Path] = []
    while parent != root and not parent.exists() and not parent.is_symlink():
        missing.append(parent)
        parent = parent.parent
    if parent != root:
        info = parent.lstat()
        if (
            stat.S_ISLNK(info.st_mode)
            or not stat.S_ISDIR(info.st_mode)
            or info.st_uid != os.geteuid()
        ):
            fail(f"backup parent is unsafe: {parent}")
    for directory in reversed(missing):
        try:
            directory.mkdir(mode=0o700)
            os.chmod(directory, 0o700)
        except OSError as exc:
            fail(f"could not create private backup directory {directory}: {exc}")
    current = root
    for part in Path(relative).parts[:-1]:
        current /= part
        info = current.lstat()
        if (
            stat.S_ISLNK(info.st_mode)
            or not stat.S_ISDIR(info.st_mode)
            or info.st_uid != os.geteuid()
            or stat.S_IMODE(info.st_mode) != 0o700
        ):
            fail(f"backup parent is unsafe: {current}")
    return path


def snapshot_entry(mapping: Mapping, snapshot: TargetSnapshot) -> dict[str, Any]:
    return {
        "target": mapping.target_relative,
        "source": mapping.source_relative,
        "exists": snapshot.exists,
        "sha256": snapshot.sha256 if snapshot.exists else None,
        "mode": f"{snapshot.mode:03o}"
        if snapshot.exists and snapshot.mode is not None
        else None,
        "backup": mapping.target_relative if snapshot.exists else None,
        "captured": False,
    }


def capture_snapshot(
    root: Path,
    document: dict[str, Any],
    mapping: Mapping,
    snapshot: TargetSnapshot,
    *,
    home: Path | None = None,
) -> None:
    if home is not None and not snapshot_matches(home, mapping, snapshot):
        fail(
            f"configuration target changed before backup capture: {mapping.target_relative}",
            1,
        )
    expected = snapshot_entry(mapping, snapshot)
    matches = [
        entry
        for entry in document["targets"]
        if entry["target"] == mapping.target_relative
    ]
    if len(matches) > 1:
        fail(f"backup metadata repeats target: {mapping.target_relative}")
    if matches:
        entry = matches[0]
        if any(
            entry[key] != value for key, value in expected.items() if key != "captured"
        ):
            fail(
                f"existing backup does not match the first observed target state: {mapping.target_relative}",
                1,
            )
    else:
        entry = expected
        document["targets"].append(entry)
        document["targets"].sort(key=lambda item: item["target"])
    document["status"] = "running"
    atomic_json(root / ".backup.json", document)
    if snapshot.exists:
        if (
            snapshot.data is None
            or snapshot.sha256 is None
            or snapshot.mode is None
            or snapshot.mode > 0o777
        ):
            fail(
                f"cannot safely capture target mode/content: {mapping.target_relative}"
            )
        backup = ensure_backup_parents(root, mapping.target_relative)
        if backup.exists() or backup.is_symlink():
            data, info = read_regular(
                backup, f"existing config backup {mapping.target_relative}"
            )
            if (
                hashlib.sha256(data).hexdigest() != snapshot.sha256
                or stat.S_IMODE(info.st_mode) != snapshot.mode
            ):
                fail(
                    f"existing backup content/mode mismatch: {mapping.target_relative}",
                    1,
                )
        else:
            atomic_write_backup(backup, snapshot.data, snapshot.mode)
    entry["captured"] = True
    document["status"] = "completed"
    atomic_json(root / ".backup.json", document)


def prepare_deployment_backup(
    context: Context,
    backup_root: Path,
    plans: tuple[TargetPlan, ...],
) -> dict[str, Any] | None:
    replacements = [plan for plan in plans if plan.classification == "replace"]
    if backup_root.exists() or backup_root.is_symlink():
        document = load_backup_document(backup_root)
        validate_deployment_backup(context, backup_root, document)
        return document
    if not replacements:
        return None
    ensure_private_directory(backup_root)
    document = deployment_backup_document(context, backup_root.name)
    atomic_json(backup_root / ".backup.json", document)
    return document


def named_backup(
    home: Path, backup_id: str
) -> tuple[Path, dict[str, Any], dict[str, Mapping]]:
    if BACKUP_ID_RE.fullmatch(backup_id) is None or backup_id in {".", ".."}:
        fail(f"unsafe backup id: {backup_id}")
    backups = readonly_backups_root(home)
    if backups is None:
        fail(f"backup does not exist: {backup_id}", 1)
    root = backups / backup_id
    document = load_backup_document(root)
    if document["status"] != "completed":
        fail(f"backup is not complete and cannot be restored: {backup_id}", 1)
    mappings = approved_backup_mappings(document)
    return root, document, mappings


def build_restore_plans(
    home: Path,
    root: Path,
    document: dict[str, Any],
    mappings: dict[str, Mapping],
) -> tuple[RestorePlan, ...]:
    plans: list[RestorePlan] = []
    for entry in document["targets"]:
        if not entry["captured"]:
            fail(f"backup target was not fully captured: {entry['target']}", 1)
        mapping = mappings[entry["target"]]
        current = inspect_target(home, mapping)
        if entry["exists"]:
            path = root / entry["backup"]
            data, info = read_regular(path, f"restore source {entry['target']}")
            desired_hash = hashlib.sha256(data).hexdigest()
            desired_mode = stat.S_IMODE(info.st_mode)
            if desired_hash != entry["sha256"] or desired_mode != backup_mode(
                entry["mode"], "backup target"
            ):
                fail(f"restore source changed after inventory: {entry['target']}")
            if not current.exists:
                classification = "create"
            elif current.sha256 == desired_hash and current.mode == desired_mode:
                classification = "unchanged"
            else:
                classification = "replace"
            plans.append(
                RestorePlan(
                    mapping,
                    current,
                    True,
                    data,
                    desired_hash,
                    desired_mode,
                    classification,
                )
            )
        else:
            classification = "remove" if current.exists else "unchanged"
            plans.append(
                RestorePlan(mapping, current, False, None, None, None, classification)
            )
    return tuple(plans)


def new_restore_root(backups: Path) -> tuple[str, Path]:
    timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    for _attempt in range(32):
        backup_id = f"restore-{timestamp}-{secrets.token_hex(6)}"
        root = backups / backup_id
        try:
            root.mkdir(mode=0o700)
            os.chmod(root, 0o700)
            return backup_id, root
        except FileExistsError:
            continue
        except OSError as exc:
            fail(f"could not create pre-restore backup root: {exc}")
    fail("could not allocate a unique pre-restore backup id")


def restore_document(source: dict[str, Any], backup_id: str) -> dict[str, Any]:
    return {
        "schema": 1,
        "id": backup_id,
        "kind": "pre-restore",
        "profile": source["profile"],
        "stage": source["stage"],
        "mode": "restore",
        "policy_sha256": policy_sha256(),
        "plan_fingerprint": source["plan_fingerprint"],
        "run_id": backup_id,
        "source_backup_id": source["id"],
        "status": "completed",
        "targets": [],
    }


def atomically_restore_target(home: Path, plan: RestorePlan) -> None:
    mapping = plan.mapping
    if not snapshot_matches(home, mapping, plan.snapshot):
        fail(
            f"configuration target changed after restore confirmation: {mapping.target_relative}",
            1,
        )
    path = plan.snapshot.path
    if not plan.desired_exists:
        if plan.snapshot.exists:
            conditional_remove_target(path, plan.snapshot)
            fsync_directory(path.parent)
        return
    if (
        plan.desired_data is None
        or plan.desired_mode is None
        or plan.desired_sha256 is None
    ):
        fail(f"internal restore payload error: {mapping.target_relative}")
    ensure_target_parents(home, path)
    if not snapshot_matches(home, mapping, plan.snapshot):
        fail(
            f"configuration target changed while preparing restore: {mapping.target_relative}",
            1,
        )
    fd: int | None = None
    temporary: Path | None = None
    try:
        fd, name = tempfile.mkstemp(
            prefix=f".my-arch-restore-{path.name}.", dir=path.parent
        )
        temporary = Path(name)
        os.fchmod(fd, plan.desired_mode)
        offset = 0
        while offset < len(plan.desired_data):
            offset += os.write(fd, plan.desired_data[offset:])
        os.fsync(fd)
        os.close(fd)
        fd = None
        conditional_replace_target(temporary, path, plan.snapshot)
        temporary = None
        fsync_directory(path.parent)
    except ConfigFailure as exc:
        if getattr(exc, "preserve_temporary", False):
            temporary = None
        raise
    except OSError as exc:
        fail(f"could not atomically restore {mapping.target_relative}: {exc}", 1)
    finally:
        if fd is not None:
            os.close(fd)
        if temporary is not None:
            try:
                temporary.unlink()
            except FileNotFoundError:
                pass


def restore_backup(home: Path, backup_id: str) -> int:
    root, source, mappings = named_backup(home, backup_id)
    plans = build_restore_plans(home, root, source, mappings)
    changing = tuple(plan for plan in plans if plan.classification != "unchanged")
    for plan in plans:
        suffix = (
            "absent"
            if not plan.desired_exists
            else f"sha256={plan.desired_sha256} mode={plan.desired_mode:03o}"
        )
        print(
            f"config-stage-apply: restore-plan {plan.classification} {plan.mapping.target_relative} {suffix}"
        )
    if not changing:
        print(
            f"config-stage-apply: backup {backup_id} already matches all approved targets"
        )
        return 0
    print(
        f"config-stage-apply: confirmation required; type exactly: restore {backup_id}",
        file=sys.stderr,
    )
    answer = sys.stdin.readline()
    if answer != f"restore {backup_id}\n":
        print(
            "config-stage-apply: restore cancelled; no target or state was changed",
            file=sys.stderr,
        )
        return 1
    for plan in changing:
        if not snapshot_matches(home, plan.mapping, plan.snapshot):
            fail(
                f"configuration target changed while restore confirmation was pending: {plan.mapping.target_relative}",
                1,
            )

    _project, config_state, backups = writable_state_directories(home)
    rollback_id, rollback_root = new_restore_root(backups)
    rollback = restore_document(source, rollback_id)
    atomic_json(rollback_root / ".backup.json", rollback)
    try:
        # Capture every current target before the first restore write.
        for plan in changing:
            capture_snapshot(
                rollback_root, rollback, plan.mapping, plan.snapshot, home=home
            )
        rollback["status"] = "completed"
        atomic_json(rollback_root / ".backup.json", rollback)
    except ConfigFailure:
        rollback["status"] = "failed"
        atomic_json(rollback_root / ".backup.json", rollback)
        raise

    operation_path = config_state / f"{rollback_id}-restore.json"
    operation: dict[str, Any] = {
        "schema": 1,
        "source_backup_id": backup_id,
        "rollback_backup_id": rollback_id,
        "profile": source["profile"],
        "stage": source["stage"],
        "status": "running",
        "targets": [],
    }
    atomic_json(operation_path, operation)
    try:
        for plan in changing:
            # Revalidate the immutable backup source immediately before use.
            if plan.desired_exists:
                data, info = read_regular(
                    root / plan.mapping.target_relative,
                    f"restore source {plan.mapping.target_relative}",
                )
                if (
                    hashlib.sha256(data).hexdigest() != plan.desired_sha256
                    or stat.S_IMODE(info.st_mode) != plan.desired_mode
                ):
                    fail(
                        f"restore source changed before apply: {plan.mapping.target_relative}"
                    )
            atomically_restore_target(home, plan)
            operation["targets"].append(
                {"target": plan.mapping.target_relative, "status": "restored"}
            )
            atomic_json(operation_path, operation)
            print(f"config-stage-apply: restored {plan.mapping.target_relative}")
    except ConfigFailure:
        operation["status"] = "failed"
        atomic_json(operation_path, operation)
        raise
    operation["status"] = "completed"
    atomic_json(operation_path, operation)
    print(f"config-stage-apply: restore completed; rollback-backup={rollback_id}")
    return 0


def ensure_target_parents(home: Path, target: Path) -> None:
    relative = target.relative_to(home)
    current = home
    for part in relative.parts[:-1]:
        current /= part
        try:
            info = current.lstat()
        except FileNotFoundError:
            try:
                current.mkdir(mode=0o700)
                os.chmod(current, 0o700)
            except OSError as exc:
                fail(f"could not create target parent {current}: {exc}")
            continue
        except OSError as exc:
            fail(f"could not inspect target parent {current}: {exc}")
        if (
            stat.S_ISLNK(info.st_mode)
            or not stat.S_ISDIR(info.st_mode)
            or info.st_uid != os.geteuid()
            or info.st_mode & 0o022
        ):
            fail(f"target parent became unsafe: {current}")


def snapshot_matches(home: Path, mapping: Mapping, expected: TargetSnapshot) -> bool:
    current = inspect_target(home, mapping)
    return (
        current.exists,
        current.sha256,
        current.mode,
        current.device,
        current.inode,
    ) == (
        expected.exists,
        expected.sha256,
        expected.mode,
        expected.device,
        expected.inode,
    )


def atomic_write_backup(path: Path, data: bytes, mode: int) -> None:
    # Backup subdirectories are private, but the original file mode is retained
    # as evidence exactly as required by the deployment contract.
    fd: int | None = None
    temporary: Path | None = None
    try:
        fd, name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
        temporary = Path(name)
        os.fchmod(fd, mode)
        offset = 0
        while offset < len(data):
            offset += os.write(fd, data[offset:])
        os.fsync(fd)
        os.close(fd)
        fd = None
        os.replace(temporary, path)
        temporary = None
        os.chmod(path, mode)
        fsync_directory(path.parent)
    except OSError as exc:
        fail(f"could not create config backup {path}: {exc}")
    finally:
        if fd is not None:
            os.close(fd)
        if temporary is not None:
            try:
                temporary.unlink()
            except FileNotFoundError:
                pass


def deploy_target(home: Path, plan: TargetPlan) -> None:
    mapping = plan.mapping
    ensure_target_parents(home, plan.snapshot.path)
    if not snapshot_matches(home, mapping, plan.snapshot):
        fail(
            f"configuration target changed after preflight: {mapping.target_relative}",
            1,
        )
    parent = plan.snapshot.path.parent
    fd: int | None = None
    temporary: Path | None = None
    try:
        fd, name = tempfile.mkstemp(
            prefix=f".my-arch-config-{plan.snapshot.path.name}.", dir=parent
        )
        temporary = Path(name)
        os.fchmod(fd, mapping.source_mode)
        offset = 0
        while offset < len(mapping.source_data):
            offset += os.write(fd, mapping.source_data[offset:])
        os.fsync(fd)
        os.close(fd)
        fd = None
        conditional_replace_target(temporary, plan.snapshot.path, plan.snapshot)
        temporary = None
        fsync_directory(parent)
    except ConfigFailure as exc:
        if getattr(exc, "preserve_temporary", False):
            temporary = None
        raise
    except OSError as exc:
        fail(f"could not atomically deploy {mapping.target_relative}: {exc}", 1)
    finally:
        if fd is not None:
            os.close(fd)
        if temporary is not None:
            try:
                temporary.unlink()
            except FileNotFoundError:
                pass


def preflight(context: Context, home: Path) -> int:
    plans = classify(context, home)
    for plan in plans:
        print(
            f"config-stage-apply: {plan.classification} {plan.mapping.target_relative}"
        )
    print(
        "config-stage-apply: read-only preflight passed "
        f"({len(plans)} exact target(s), mode={context.mode})"
    )
    return 0


def execute(context: Context, home: Path) -> int:
    plans = classify(context, home)
    provenance, backup_root, _project = state_paths(context, home)
    backup_document = prepare_deployment_backup(context, backup_root, plans)
    state: dict[str, Any] = {
        "schema": 1,
        "plan_fingerprint": context.fingerprint,
        "run_id": context.run_id,
        "profile": context.profile,
        "stage": context.stage,
        "mode": context.mode,
        "backup_id": backup_document["id"] if backup_document is not None else None,
        "status": "running",
        "targets": [],
    }
    atomic_json(provenance, state)
    try:
        for plan in plans:
            mapping = plan.mapping
            if plan.classification == "unchanged":
                result = "unchanged"
                backup_relative = None
            else:
                backup_relative = None
                if plan.classification == "replace":
                    if backup_document is None:
                        fail("internal error: replacement has no backup manifest")
                    capture_snapshot(
                        backup_root, backup_document, mapping, plan.snapshot, home=home
                    )
                    backup_relative = mapping.target_relative
                deploy_target(home, plan)
                result = "deployed"
            state["targets"].append(
                {
                    "target": mapping.target_relative,
                    "source": mapping.source_relative,
                    "source_sha256": mapping.source_sha256,
                    "mode": f"{mapping.source_mode:03o}",
                    "status": result,
                    "backup": backup_relative,
                }
            )
            atomic_json(provenance, state)
            print(f"config-stage-apply: {result} {mapping.target_relative}")
    except ConfigFailure:
        state["status"] = "failed"
        atomic_json(provenance, state)
        if backup_document is not None and backup_document["status"] == "running":
            backup_document["status"] = "failed"
            atomic_json(backup_root / ".backup.json", backup_document)
        raise
    state["status"] = "completed"
    atomic_json(provenance, state)
    print(f"config-stage-apply: deployment completed ({len(plans)} exact target(s))")
    return 0


def verify(context: Context, home: Path) -> int:
    failures: list[str] = []
    for mapping in context.mappings:
        try:
            snapshot = inspect_target(home, mapping)
        except ConfigFailure as exc:
            print(
                f"config-stage-apply: verification unavailable for {mapping.target_relative}: {exc}",
                file=sys.stderr,
            )
            return exc.status
        if not snapshot.exists:
            failures.append(f"missing {mapping.target_relative}")
        elif snapshot.sha256 != mapping.source_sha256:
            failures.append(f"content-drift {mapping.target_relative}")
        elif snapshot.mode != mapping.source_mode:
            failures.append(f"mode-drift {mapping.target_relative}")
    if failures:
        for failure in failures:
            print(
                f"config-stage-apply: verification blocker: {failure}", file=sys.stderr
            )
        return 1
    print(f"config-stage-apply: verified {len(context.mappings)} exact target(s)")
    return 0


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(
        description=(
            "Execute a fingerprint-bound FULL_ORCHESTRATOR config stage, list private backups, "
            "or explicitly restore one approved backup."
        )
    )
    actions = result.add_mutually_exclusive_group()
    actions.add_argument(
        "--list-backups",
        action="store_true",
        help="emit a read-only JSON backup inventory",
    )
    actions.add_argument(
        "--restore-backup",
        metavar="ID",
        help="preview and explicitly confirm one scoped restore",
    )
    return result


def main(argv: Sequence[str] | None = None) -> int:
    args = parser().parse_args(argv)
    try:
        if os.geteuid() == 0:
            fail("config stage must run as the invoking ordinary user")
        home = inspect_home()
        if args.list_backups:
            return list_backups(home)
        if args.restore_backup is not None:
            return restore_backup(home, args.restore_backup)
        context = load_context()
        if context.action == "preflight":
            return preflight(context, home)
        if context.action == "execute":
            return execute(context, home)
        return verify(context, home)
    except ConfigFailure as exc:
        print(f"config-stage-apply: {exc}", file=sys.stderr)
        return exc.status
    except KeyboardInterrupt:
        print("config-stage-apply: interrupted", file=sys.stderr)
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
