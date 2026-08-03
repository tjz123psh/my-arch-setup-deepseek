#!/usr/bin/env python3
"""Review, enable, inspect, or restore the narrow VM candidate manifest gates.

This tool changes only this checkout's ``modules.tsv`` and ``stages.tsv``.  It
never installs a package or changes a service/system file.  Enabling is allowed
only after exact confirmation and a successful VM-runtime query.  Original
manifest bytes are retained in private state and restore refuses concurrent
drift.
"""

from __future__ import annotations

import argparse
import ctypes
import csv
import hashlib
import json
import os
import re
import stat
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any, NoReturn, Sequence

PROJECT_ROOT = Path(__file__).resolve().parent.parent
MODULES_PATH = PROJECT_ROOT / "manifests/modules.tsv"
STAGES_PATH = PROJECT_ROOT / "manifests/stages.tsv"
STATE_SUFFIX = Path("my-archlinux-setup/vm-candidate-gate")
VM_MODULES = (
    "base-preconditions",
    "archlinuxcn-trust",
    "build-foundation",
    "fonts",
    "audio",
)
STAGE_IDS = (
    "privilege-wrapper",
    "official-update",
    "official-packages",
    "archlinuxcn-bootstrap",
    "archlinuxcn-packages",
    "aur-source-acquisition",
    "aur-build-install",
    "user-config",
    "system-actions",
)
HEX64_RE = re.compile(r"[0-9a-f]{64}")
TOKEN_RE = re.compile(r"[a-z0-9][a-z0-9-]*")
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


class GateFailure(Exception):
    def __init__(self, message: str, status: int = 2) -> None:
        super().__init__(message)
        self.status = normalize_status(status)


@dataclass(frozen=True)
class ManifestSnapshot:
    path: Path
    data: bytes
    mode: int
    digest: str
    lines: tuple[str, ...]
    device: int = 0
    inode: int = 0


@dataclass(frozen=True)
class FileIdentity:
    digest: str
    mode: int
    device: int
    inode: int


@dataclass(frozen=True)
class GatePolicy:
    modules: ManifestSnapshot
    stages: ManifestSnapshot
    candidate_modules: bytes
    candidate_stages: bytes

    @property
    def original_hashes(self) -> dict[str, str]:
        return {"modules": self.modules.digest, "stages": self.stages.digest}

    @property
    def candidate_hashes(self) -> dict[str, str]:
        return {
            "modules": hashlib.sha256(self.candidate_modules).hexdigest(),
            "stages": hashlib.sha256(self.candidate_stages).hexdigest(),
        }


def normalize_status(status: int) -> int:
    if status < 0:
        return min(255, 128 + abs(status))
    return min(255, max(0, status))


def fail(message: str, status: int = 2) -> NoReturn:
    raise GateFailure(message, status)


def lexical_absolute(path: Path) -> Path:
    return Path(os.path.abspath(os.fspath(path.expanduser())))


def read_regular(path: Path, label: str, *, owner: bool = True) -> tuple[bytes, os.stat_result]:
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
    except FileNotFoundError:
        fail(f"{label} is missing: {path}")
    except OSError as exc:
        fail(f"could not open {label} {path}: {exc}")
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
            fail(f"{label} is not a single-link regular file: {path}")
        if owner and before.st_uid != os.geteuid():
            fail(f"{label} is not owned by the invoking user: {path}")
        chunks: list[bytes] = []
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            chunks.append(chunk)
        after = os.fstat(descriptor)
    except OSError as exc:
        fail(f"could not read {label} {path}: {exc}")
    finally:
        os.close(descriptor)
    if (
        before.st_dev,
        before.st_ino,
        before.st_size,
        before.st_mtime_ns,
        before.st_mode,
        before.st_nlink,
        before.st_uid,
        before.st_gid,
    ) != (
        after.st_dev,
        after.st_ino,
        after.st_size,
        after.st_mtime_ns,
        after.st_mode,
        after.st_nlink,
        after.st_uid,
        after.st_gid,
    ):
        fail(f"{label} changed while being read: {path}")
    return b"".join(chunks), after


def manifest_snapshot(path: Path, schema: str, label: str) -> ManifestSnapshot:
    data, info = read_regular(path, label)
    mode = stat.S_IMODE(info.st_mode)
    if mode & 0o022:
        fail(f"{label} is group/world writable: {path}")
    try:
        lines = tuple(data.decode("utf-8").splitlines())
    except UnicodeDecodeError as exc:
        fail(f"{label} is not UTF-8: {exc}")
    if not lines or lines[0] != schema:
        fail(f"{label} has an unsupported schema")
    return ManifestSnapshot(
        path,
        data,
        mode,
        hashlib.sha256(data).hexdigest(),
        lines,
        info.st_dev,
        info.st_ino,
    )


def data_rows(lines: Sequence[str], fields: int, label: str) -> list[tuple[int, list[str]]]:
    result: list[tuple[int, list[str]]] = []
    for number, row in enumerate(csv.reader(lines[1:], delimiter="\t"), 2):
        if not row or not row[0] or row[0].startswith("#"):
            continue
        if len(row) != fields or not all(row):
            fail(f"{label} has an invalid row at line {number}")
        result.append((number, row))
    return result


def transform_manifest(
    snapshot: ManifestSnapshot,
    *,
    fields: int,
    id_field: int,
    value_field: int,
    targets: Sequence[str],
    expected_values: set[str],
    candidate_value: str,
    label: str,
) -> bytes:
    target_set = set(targets)
    found: set[str] = set()
    output = list(snapshot.lines)
    for number, row in data_rows(snapshot.lines, fields, label):
        identity = row[id_field]
        if TOKEN_RE.fullmatch(identity) is None:
            fail(f"{label} has an unsafe id at line {number}")
        if identity not in target_set:
            continue
        if identity in found:
            fail(f"{label} repeats candidate id {identity}")
        found.add(identity)
        if row[value_field] not in expected_values:
            fail(f"{label} candidate {identity} has unexpected current value {row[value_field]}", 1)
        row[value_field] = candidate_value
        output[number - 1] = "\t".join(row)
    if found != target_set:
        fail(f"{label} lacks candidate ids: {sorted(target_set - found)}")
    return ("\n".join(output) + "\n").encode("utf-8")


def load_policy() -> GatePolicy:
    modules = manifest_snapshot(MODULES_PATH, "# schema=1", "module registry")
    stages = manifest_snapshot(STAGES_PATH, "# schema=2", "stage manifest")
    candidate_modules = transform_manifest(
        modules,
        fields=6,
        id_field=0,
        value_field=1,
        targets=VM_MODULES,
        expected_values={"planning", "available"},
        candidate_value="available",
        label="module registry",
    )
    candidate_stages = transform_manifest(
        stages,
        fields=8,
        id_field=0,
        value_field=6,
        targets=STAGE_IDS,
        expected_values={"false", "true"},
        candidate_value="true",
        label="stage manifest",
    )
    return GatePolicy(modules, stages, candidate_modules, candidate_stages)


def state_base() -> Path:
    home = os.environ.get("HOME", "")
    if not home or not os.path.isabs(home):
        fail("HOME must be absolute")
    raw = os.environ.get("XDG_STATE_HOME") or str(Path(home) / ".local/state")
    if not os.path.isabs(raw):
        fail("XDG_STATE_HOME must be absolute")
    return lexical_absolute(Path(raw)) / STATE_SUFFIX


def inspect_directory(path: Path, label: str, *, private: bool, allow_missing: bool = False) -> bool:
    try:
        info = path.lstat()
    except FileNotFoundError:
        if allow_missing:
            return False
        fail(f"{label} is missing: {path}")
    except OSError as exc:
        fail(f"could not inspect {label} {path}: {exc}")
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode) or info.st_uid != os.geteuid():
        fail(f"{label} is unsafe: {path}")
    mode = stat.S_IMODE(info.st_mode)
    if (private and mode != 0o700) or (not private and info.st_mode & 0o002):
        fail(f"{label} has unsafe permissions: {path}")
    return True


def ensure_external_parent(path: Path) -> None:
    if inspect_directory(path, "state parent", private=False, allow_missing=True):
        return
    try:
        path.mkdir(parents=True, mode=0o700)
        os.chmod(path, 0o700)
    except OSError as exc:
        fail(f"could not create state parent {path}: {exc}")


def ensure_private(path: Path) -> None:
    if inspect_directory(path, "private state directory", private=True, allow_missing=True):
        return
    if path.parent.name == "vm-candidate-gate" or path.parent.name == "my-archlinux-setup":
        ensure_private(path.parent)
    else:
        ensure_external_parent(path.parent)
    try:
        path.mkdir(mode=0o700)
        os.chmod(path, 0o700)
    except OSError as exc:
        fail(f"could not create private directory {path}: {exc}")


def fsync_directory(path: Path) -> None:
    descriptor: int | None = None
    try:
        descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0))
        os.fsync(descriptor)
    except OSError as exc:
        fail(f"could not fsync directory {path}: {exc}")
    finally:
        if descriptor is not None:
            os.close(descriptor)


def atomic_write(path: Path, data: bytes, mode: int) -> None:
    descriptor: int | None = None
    temporary: Path | None = None
    try:
        descriptor, raw = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
        temporary = Path(raw)
        os.fchmod(descriptor, mode)
        offset = 0
        while offset < len(data):
            offset += os.write(descriptor, data[offset:])
        os.fsync(descriptor)
        os.close(descriptor)
        descriptor = None
        os.replace(temporary, path)
        temporary = None
        os.chmod(path, mode)
        fsync_directory(path.parent)
    except OSError as exc:
        fail(f"could not atomically write {path}: {exc}", 1)
    finally:
        if descriptor is not None:
            os.close(descriptor)
        if temporary is not None:
            try:
                temporary.unlink()
            except FileNotFoundError:
                pass


def atomic_json(path: Path, value: dict[str, Any]) -> None:
    atomic_write(path, json.dumps(value, sort_keys=True, indent=2).encode("utf-8") + b"\n", 0o600)


def current_hashes(policy: GatePolicy) -> dict[str, str]:
    return policy.original_hashes


def state_document(path: Path) -> dict[str, Any] | None:
    if not path.exists() and not path.is_symlink():
        return None
    data, info = read_regular(path, "VM candidate state")
    if stat.S_IMODE(info.st_mode) != 0o600:
        fail("VM candidate state is not mode 600")
    try:
        value: Any = json.loads(data)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        fail(f"VM candidate state is malformed: {exc}")
    expected = {
        "schema",
        "project_root",
        "status",
        "original_hashes",
        "candidate_hashes",
        "modules_mode",
        "stages_mode",
    }
    if not isinstance(value, dict) or set(value) != expected or value["schema"] != 1:
        fail("VM candidate state has an unsupported schema")
    if value["project_root"] != str(PROJECT_ROOT) or value["status"] not in {"enabling", "enabled", "restoring", "restored"}:
        fail("VM candidate state belongs to another checkout or has invalid status")
    for key in ("original_hashes", "candidate_hashes"):
        hashes = value[key]
        if not isinstance(hashes, dict) or set(hashes) != {"modules", "stages"}:
            fail(f"VM candidate state has invalid {key}")
        if any(not isinstance(item, str) or HEX64_RE.fullmatch(item) is None for item in hashes.values()):
            fail(f"VM candidate state has invalid hashes in {key}")
    for key in ("modules_mode", "stages_mode"):
        if not isinstance(value[key], int) or not 0 <= value[key] <= 0o777:
            fail(f"VM candidate state has invalid {key}")
    return value


def detector_path() -> Path:
    testing = os.environ.get("VM_CANDIDATE_GATE_TESTING")
    override = os.environ.get("VM_CANDIDATE_GATE_DETECTOR")
    if testing == "1" and override:
        path = lexical_absolute(Path(override))
    elif testing or override:
        fail("VM candidate detector override requires both test variables")
    else:
        path = Path("/usr/bin/systemd-detect-virt")
    data, info = read_regular(path, "VM runtime detector", owner=testing == "1")
    _ = data
    if not info.st_mode & 0o111:
        fail("VM runtime detector is not executable")
    return path


def require_vm() -> None:
    path = detector_path()
    try:
        completed = subprocess.run([str(path), "--vm"], stdin=subprocess.DEVNULL, check=False)
    except OSError as exc:
        fail(f"could not execute VM runtime detector: {exc}", 127 if isinstance(exc, FileNotFoundError) else 2)
    status = normalize_status(completed.returncode)
    if status == 0:
        return
    if status == 1:
        fail("candidate gates may be enabled only inside a detected VM", 1)
    fail(f"VM runtime query failed with exit {status}", status)


def candidate_changes(policy: GatePolicy) -> tuple[list[str], list[str]]:
    module_values = {
        row[0]: row[1]
        for _number, row in data_rows(policy.modules.lines, 6, "module registry")
    }
    stage_values = {
        row[0]: row[6]
        for _number, row in data_rows(policy.stages.lines, 8, "stage manifest")
    }
    module_changes = [module for module in VM_MODULES if module_values[module] != "available"]
    stage_changes = [stage for stage in STAGE_IDS if stage_values[stage] != "true"]
    return stage_changes, module_changes


def make_plan(policy: GatePolicy) -> dict[str, Any]:
    stage_changes, module_changes = candidate_changes(policy)
    return {
        "schema": 1,
        "action": "plan" if stage_changes or module_changes else "already-promoted",
        "stage_changes": stage_changes,
        "module_changes": module_changes,
        "current_hashes": current_hashes(policy),
        "candidate_hashes": policy.candidate_hashes,
        "requires_vm": bool(stage_changes or module_changes),
        "system_changes": False,
        "targets": ["manifests/modules.tsv", "manifests/stages.tsv"],
        "rollback": "restore exact private backups after candidate manifests are unchanged",
    }


def require_confirmation(args: argparse.Namespace) -> None:
    if not args.confirm_vm_candidate:
        fail("candidate gate change requires --confirm-vm-candidate after reviewing --plan", 1)


def prepare_state(policy: GatePolicy, root: Path) -> tuple[dict[str, Any], Path]:
    ensure_private(root)
    backup = root / "backup"
    ensure_private(backup)
    state_path = root / "state.json"
    existing = state_document(state_path)
    if existing is not None:
        return existing, backup
    atomic_write(backup / "modules.tsv", policy.modules.data, 0o600)
    atomic_write(backup / "stages.tsv", policy.stages.data, 0o600)
    document = {
        "schema": 1,
        "project_root": str(PROJECT_ROOT),
        "status": "enabling",
        "original_hashes": policy.original_hashes,
        "candidate_hashes": policy.candidate_hashes,
        "modules_mode": policy.modules.mode,
        "stages_mode": policy.stages.mode,
    }
    atomic_json(state_path, document)
    return document, backup


def manifest_modes_match(policy: GatePolicy, document: dict[str, Any]) -> bool:
    return (
        policy.modules.mode == document["modules_mode"]
        and policy.stages.mode == document["stages_mode"]
    )


def policy_matches(policy: GatePolicy, hashes: dict[str, str], document: dict[str, Any]) -> bool:
    return policy.original_hashes == hashes and manifest_modes_match(policy, document)


def commit_terminal_state(
    state_path: Path,
    document: dict[str, Any],
    *,
    terminal_status: str,
    transient_status: str,
    expected_hashes: dict[str, str],
) -> None:
    """Write a terminal state only while the manifests still prove it.

    The post-write read closes the state-file rename window as far as a
    separate, non-cooperating writer can be observed.  ``status()`` performs
    the same truth check later and reports drift instead of repeating a stale
    terminal status.
    """
    document["status"] = terminal_status
    atomic_json(state_path, document)
    try:
        final = load_policy()
        if not policy_matches(final, expected_hashes, document):
            fail(f"manifest changed before {terminal_status} state could be committed", 1)
    except GateFailure as exc:
        document["status"] = transient_status
        try:
            atomic_json(state_path, document)
        except GateFailure as state_exc:
            fail(
                f"{exc}; could not record transient state after concurrent manifest change: {state_exc}",
                1,
            )
        raise


def hash_data(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def identity_of_snapshot(snapshot: ManifestSnapshot) -> FileIdentity:
    return FileIdentity(snapshot.digest, snapshot.mode, snapshot.device, snapshot.inode)


def read_identity(path: Path, label: str) -> FileIdentity:
    data, info = read_regular(path, label)
    return FileIdentity(
        hash_data(data),
        stat.S_IMODE(info.st_mode),
        info.st_dev,
        info.st_ino,
    )


def renameat2(path_from: Path, path_to: Path, flags: int, *, phase: str) -> None:
    """Perform the final manifest rename without a check/replace gap."""
    sys.audit(
        "myarch.vm-conditional-replace",
        os.fspath(path_from),
        os.fspath(path_to),
        phase,
    )
    if _RENAMEAT2 is None:
        fail("renameat2 is unavailable; cannot commit manifest conditionally", 1)
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


def conditional_manifest_write(
    path: Path,
    data: bytes,
    mode: int,
    expected: ManifestSnapshot | None,
    label: str,
) -> None:
    """Commit a manifest only if the reviewed directory entry is unchanged.

    For an existing target, ``RENAME_EXCHANGE`` first places the new inode at
    the target and displaces the reviewed inode at the temporary name.  The
    displaced inode is then checked by hash, mode, device, and inode.  A
    mismatch is rolled back when the new inode is still at the target; if a
    second writer reaches that boundary, both names are deliberately retained
    and the operation fails rather than deleting an unknown writer's bytes.
    """
    descriptor: int | None = None
    temporary: Path | None = None
    preserve_temporary = False
    desired: FileIdentity | None = None
    try:
        descriptor, raw = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
        temporary = Path(raw)
        os.fchmod(descriptor, mode)
        offset = 0
        while offset < len(data):
            written = os.write(descriptor, data[offset:])
            if written <= 0:
                fail(f"could not prepare conditional manifest write for {path}", 1)
            offset += written
        os.fsync(descriptor)
        prepared_info = os.fstat(descriptor)
        desired = FileIdentity(
            hash_data(data),
            stat.S_IMODE(prepared_info.st_mode),
            prepared_info.st_dev,
            prepared_info.st_ino,
        )
        os.close(descriptor)
        descriptor = None

        if expected is None:
            try:
                renameat2(temporary, path, RENAME_NOREPLACE, phase="create")
            except OSError as exc:
                fail(f"{label} changed at final create boundary: {path}: {exc}", 1)
            temporary = None
            if read_identity(path, f"created {label}") != desired:
                fail(f"{label} differed from the prepared create inode: {path}", 1)
            fsync_directory(path.parent)
            return

        try:
            renameat2(temporary, path, RENAME_EXCHANGE, phase="replace")
        except OSError as exc:
            fail(f"{label} changed at final replace boundary: {path}: {exc}", 1)

        try:
            displaced = read_identity(temporary, f"displaced {label}")
        except GateFailure:
            displaced = None
        try:
            installed = read_identity(path, f"installed conditional {label}")
        except GateFailure:
            installed = None
        expected_identity = identity_of_snapshot(expected)
        if displaced == expected_identity and installed == desired:
            try:
                temporary.unlink()
            except OSError as exc:
                preserve_temporary = True
                fail(f"could not remove displaced reviewed {label} {temporary}: {exc}", 1)
            temporary = None
            fsync_directory(path.parent)
            return

        # The first exchange succeeded, but the displaced directory entry was
        # not the exact reviewed file.  Exchange back, then verify both sides
        # before removing anything.  If the target changed again, retaining
        # the two names is safer than a best-effort rollback plus unlink.
        preserve_temporary = True
        try:
            renameat2(temporary, path, RENAME_EXCHANGE, phase="rollback")
        except OSError as exc:
            try:
                fsync_directory(path.parent)
            except GateFailure:
                pass
            fail(
                f"{label} changed at final replace boundary and rollback exchange failed; "
                f"conflicting files retained at {temporary}: {exc}",
                1,
            )

        try:
            rollback_target = read_identity(path, f"rolled-back {label}")
            rollback_temporary = read_identity(temporary, f"retained conditional {label}")
        except GateFailure as exc:
            try:
                fsync_directory(path.parent)
            except GateFailure:
                pass
            fail(
                f"{label} changed during rollback; conflicting files retained at {temporary}: {exc}",
                1,
            )

        if displaced is None or rollback_target != displaced or rollback_temporary != desired:
            try:
                fsync_directory(path.parent)
            except GateFailure:
                pass
            fail(
                f"{label} changed during rollback; conflicting files retained at {temporary}",
                1,
            )

        # The displaced pre-commit file is back at the target name and the
        # proposed bytes remain at the generated temporary name.  Keep it until a
        # caller explicitly cleans it: unlinking it here would reintroduce a
        # second race against a writer that discovered the exchange boundary.
        try:
            fsync_directory(path.parent)
        except GateFailure:
            pass
        fail(
            f"{label} changed at final replace boundary; displaced file restored and "
            f"proposed bytes retained at {temporary}",
            1,
        )
    except GateFailure:
        raise
    except OSError as exc:
        fail(f"could not conditionally write {label} {path}: {exc}", 1)
    finally:
        if descriptor is not None:
            os.close(descriptor)
        if temporary is not None and not preserve_temporary:
            try:
                temporary.unlink()
            except FileNotFoundError:
                pass


def enable(policy: GatePolicy, args: argparse.Namespace) -> int:
    require_confirmation(args)
    stage_changes, module_changes = candidate_changes(policy)
    root = state_base()
    state_path = root / "state.json"
    existing = state_document(state_path) if root.exists() or root.is_symlink() else None
    if not stage_changes and not module_changes and existing is None:
        fail("candidate gates are already canonical; no VM-local enable transaction is permitted", 1)
    require_vm()
    current = policy.original_hashes
    candidates = policy.candidate_hashes
    if existing is not None:
        if existing["status"] == "restored":
            # A prior cycle was restored; start a new evidence cycle without
            # discarding the old backups/state implicitly.
            fail("restored candidate state already exists; archive/remove it explicitly before a new cycle", 1)
        if existing["candidate_hashes"] != candidates:
            fail("candidate policy changed since private state was created", 1)
        if not manifest_modes_match(policy, existing):
            fail("candidate manifest mode drifted from the reviewed cycle", 1)
        allowed_modules = {existing["original_hashes"]["modules"], candidates["modules"]}
        allowed_stages = {existing["original_hashes"]["stages"], candidates["stages"]}
        if current["modules"] not in allowed_modules or current["stages"] not in allowed_stages:
            fail("candidate manifest drifted from both original and reviewed candidate", 1)
        if current == candidates and existing["status"] == "enabled":
            print("vm-candidate-gate: candidate gates already enabled")
            return 0
    else:
        # A fresh cycle starts only from the reviewed closed-gate values.
        if any(b"\ttrue\t" in line for line in policy.stages.data.splitlines() if line and not line.startswith(b"#")):
            fail("fresh candidate enable did not start from all-false stage gates", 1)
        module_rows = {row[1][0]: row[1][1] for row in data_rows(policy.modules.lines, 6, "module registry")}
        if any(module_rows[module] != "planning" for module in VM_MODULES):
            fail("fresh candidate enable did not start from planning VM modules", 1)
    document, _backup = prepare_state(policy, root)
    document["status"] = "enabling"
    atomic_json(state_path, document)
    if current["modules"] != candidates["modules"]:
        if current["modules"] != document["original_hashes"]["modules"]:
            fail("module manifest drifted before candidate write", 1)
        conditional_manifest_write(
            MODULES_PATH,
            policy.candidate_modules,
            policy.modules.mode,
            policy.modules,
            "module manifest",
        )
    refreshed_stages = manifest_snapshot(STAGES_PATH, "# schema=2", "stage manifest")
    if refreshed_stages.mode != document["stages_mode"]:
        fail("stage manifest mode drifted before candidate write", 1)
    if refreshed_stages.digest != candidates["stages"]:
        if refreshed_stages.digest != document["original_hashes"]["stages"]:
            fail("stage manifest drifted before candidate write", 1)
        conditional_manifest_write(
            STAGES_PATH,
            policy.candidate_stages,
            policy.stages.mode,
            refreshed_stages,
            "stage manifest",
        )
    final = load_policy()
    if not policy_matches(final, candidates, document):
        fail("candidate manifests did not reach the reviewed candidate hashes", 1)
    commit_terminal_state(
        state_path,
        document,
        terminal_status="enabled",
        transient_status="enabling",
        expected_hashes=candidates,
    )
    print("vm-candidate-gate: enabled exact VM candidate stage/module gates")
    return 0


def restore(policy: GatePolicy, args: argparse.Namespace) -> int:
    require_confirmation(args)
    root = state_base()
    inspect_directory(root, "VM candidate state root", private=True)
    state_path = root / "state.json"
    document = state_document(state_path)
    if document is None:
        fail("VM candidate state is missing", 1)
    backup = root / "backup"
    inspect_directory(backup, "VM candidate backup directory", private=True)
    original_modules, modules_info = read_regular(backup / "modules.tsv", "original module backup")
    original_stages, stages_info = read_regular(backup / "stages.tsv", "original stage backup")
    if stat.S_IMODE(modules_info.st_mode) != 0o600 or stat.S_IMODE(stages_info.st_mode) != 0o600:
        fail("VM candidate backups are not mode 600")
    if hash_data(original_modules) != document["original_hashes"]["modules"] or hash_data(original_stages) != document["original_hashes"]["stages"]:
        fail("VM candidate original backup hash mismatch")
    current = policy.original_hashes
    original = document["original_hashes"]
    candidate = document["candidate_hashes"]
    if not manifest_modes_match(policy, document):
        fail("candidate manifest mode drifted from the reviewed cycle", 1)
    if current == original and document["status"] == "restored":
        print("vm-candidate-gate: original closed gates already restored")
        return 0
    if current["modules"] not in {original["modules"], candidate["modules"]} or current["stages"] not in {
        original["stages"],
        candidate["stages"],
    }:
        fail("candidate manifest drifted; refusing to overwrite concurrent checkout changes", 1)
    document["status"] = "restoring"
    atomic_json(state_path, document)
    if current["modules"] != original["modules"]:
        conditional_manifest_write(
            MODULES_PATH,
            original_modules,
            document["modules_mode"],
            policy.modules,
            "module manifest",
        )
    refreshed_stages = manifest_snapshot(STAGES_PATH, "# schema=2", "stage manifest")
    if refreshed_stages.mode != document["stages_mode"]:
        fail("stage manifest mode drifted during restore", 1)
    if refreshed_stages.digest != original["stages"]:
        if refreshed_stages.digest != candidate["stages"]:
            fail("candidate manifest drifted during restore", 1)
        conditional_manifest_write(
            STAGES_PATH,
            original_stages,
            document["stages_mode"],
            refreshed_stages,
            "stage manifest",
        )
    restored = load_policy()
    if not policy_matches(restored, original, document):
        fail("candidate restore did not recover exact original manifests", 1)
    commit_terminal_state(
        state_path,
        document,
        terminal_status="restored",
        transient_status="restoring",
        expected_hashes=original,
    )
    print("vm-candidate-gate: restored exact original closed gates")
    return 0


def status(policy: GatePolicy, as_json: bool) -> int:
    root = state_base()
    state_path = root / "state.json"
    status_code = 0
    if not root.exists() and not root.is_symlink():
        value = {
            "schema": 1,
            "status": "untracked",
            "candidate_matches": policy.original_hashes == policy.candidate_hashes,
            "original_matches": None,
        }
    else:
        inspect_directory(root, "VM candidate state root", private=True)
        document = state_document(state_path)
        if document is None:
            fail("VM candidate state root exists without state")
        current = policy.original_hashes
        state_value = document["status"]
        if state_value == "enabled" and not policy_matches(policy, document["candidate_hashes"], document):
            # Never present a stale terminal state as a successful candidate.
            state_value = "drifted"
            status_code = 1
        elif state_value == "restored" and not policy_matches(policy, document["original_hashes"], document):
            state_value = "drifted"
            status_code = 1
        value = {
            "schema": 1,
            "status": state_value,
            "candidate_matches": current == document["candidate_hashes"],
            "original_matches": current == document["original_hashes"],
        }
    if as_json:
        print(json.dumps(value, sort_keys=True, separators=(",", ":")))
    else:
        print("vm-candidate-gate: " + " ".join(f"{key}={value[key]}" for key in sorted(value)))
    return status_code


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description="Review and reversibly toggle only the narrow VM candidate manifest gates")
    action = result.add_mutually_exclusive_group(required=True)
    action.add_argument("--plan", action="store_true")
    action.add_argument("--enable", action="store_true")
    action.add_argument("--restore", action="store_true")
    action.add_argument("--status", action="store_true")
    result.add_argument("--json", action="store_true")
    result.add_argument("--confirm-vm-candidate", action="store_true")
    return result


def run(argv: Sequence[str] | None = None) -> int:
    args = parser().parse_args(argv)
    if os.geteuid() == 0:
        fail("VM candidate gate tool must run as the ordinary checkout owner", 1)
    if args.confirm_vm_candidate and not (args.enable or args.restore):
        fail("--confirm-vm-candidate is valid only with --enable or --restore", 1)
    policy = load_policy()
    if args.plan:
        value = make_plan(policy)
        if args.json:
            print(json.dumps(value, sort_keys=True, indent=2))
        else:
            if value["action"] == "already-promoted":
                print("VM candidate manifest plan: exact candidate gates are already canonical")
                print("  stages: none")
                print("  modules: none")
            else:
                print("VM candidate manifest plan (no system changes)")
                print("  stages: " + ",".join(value["stage_changes"]))
                print("  modules: " + ",".join(value["module_changes"]))
                print("  enable requires: detected VM + --confirm-vm-candidate")
                print("  rollback: exact private backups; concurrent drift refuses overwrite")
            print("  targets: manifests/modules.tsv,manifests/stages.tsv")
        return 0
    if args.enable:
        return enable(policy, args)
    if args.restore:
        return restore(policy, args)
    return status(policy, args.json)


def main() -> None:
    try:
        result = run()
    except GateFailure as exc:
        print(f"vm-candidate-gate: {exc}", file=sys.stderr)
        raise SystemExit(exc.status) from exc
    except KeyboardInterrupt as exc:
        print("vm-candidate-gate: interrupted", file=sys.stderr)
        raise SystemExit(130) from exc
    raise SystemExit(result)


if __name__ == "__main__":
    main()
