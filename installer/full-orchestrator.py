#!/usr/bin/env python3
"""Schema-2, adapter-only one-click DAG and resumable state engine.

This file deliberately contains no package-manager, service-manager, or system
configuration commands.  Applicable stages can run only through either the
explicit test execution-map boundary or a hash-pinned reviewed executable
manifest supplied by the caller.
"""

from __future__ import annotations

import argparse
import csv
import datetime as dt
import fcntl
import hashlib
import json
import os
import re
import stat
import subprocess
import sys
import tempfile
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable, Sequence


ROOT = Path(__file__).resolve().parent.parent
MODULES_PATH = ROOT / "manifests/modules.tsv"
PRODUCTION_READINESS_PATH = ROOT / "manifests/production-module-readiness.tsv"
PROFILES_PATH = ROOT / "manifests/profile-modules.tsv"
STAGES_PATH = ROOT / "manifests/stages.tsv"
WORKSTATION_PATH = ROOT / "manifests/workstation-packages.tsv"
CONFIG_PATH = ROOT / "manifests/config-mappings.tsv"
SYSTEM_ACTIONS_PATH = ROOT / "manifests/system-actions.tsv"
SYSTEM_CONFLICTS_PATH = ROOT / "manifests/system-action-conflicts.tsv"
CANONICAL_EXECUTABLE_MANIFEST = ROOT / "manifests/stage-executables.tsv"
STAGE_INPUTS_PATH = ROOT / "manifests/stage-inputs.tsv"
SCRIPT_PATH = Path(__file__).resolve()
PROJECT_STATE_NAME = "my-archlinux-setup/full-orchestrator"

TOKEN_RE = re.compile(r"^[a-z0-9][a-z0-9-]*$")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
STAGE_INPUT_ID_RE = re.compile(r"^[a-z0-9][a-z0-9.:-]*$")
RUN_ID_RE = re.compile(r"^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{12}$")
REQUIRED_STAGES = {
    "privilege-wrapper",
    "official-update",
    "official-packages",
    "archlinuxcn-bootstrap",
    "archlinuxcn-packages",
    "aur-source-acquisition",
    "aur-build-install",
    "user-config",
    "system-actions",
}
AUXILIARY_INPUT_REQUIRED_STAGES = {
    "official-update",
    "official-packages",
    "archlinuxcn-bootstrap",
    "archlinuxcn-packages",
    "aur-source-acquisition",
    "aur-build-install",
}
KNOWN_EFFECT_SOURCES = {
    "derived:official-update",
    "workstation:official-install",
    "workstation:archlinuxcn-bootstrap",
    "workstation:archlinuxcn-install",
    "workstation:aur-source",
    "workstation:aur-build-install",
    "config:mappings",
    "config:privilege-wrapper",
    "system:actions",
    "none",
}
STAGE_STATUSES = {
    "pending",
    "running",
    "passed",
    "failed",
    "skipped-dependency",
    "not-applicable",
}
RUN_STATUSES = {"running", "failed", "completed"}
CONFIRMATION_ORDER = ("system", "archlinuxcn", "aur")
CONFIRMATION_FLAGS = {
    "system": "--confirm-system-changes",
    "archlinuxcn": "--confirm-archlinuxcn",
    "aur": "--confirm-aur",
}
CONFIRMATION_TOKENS = {
    "system": "confirm-system-changes",
    "archlinuxcn": "confirm-archlinuxcn",
    "aur": "confirm-aur",
}


class OrchestratorError(Exception):
    def __init__(self, message: str, status: int = 1):
        super().__init__(message)
        self.status = normalize_exit(status)


class Cancelled(OrchestratorError):
    def __init__(self, message: str):
        super().__init__(message, 130)


@dataclass(frozen=True)
class Snapshot:
    label: str
    path: Path
    data: bytes
    digest: str
    lines: tuple[str, ...]


@dataclass(frozen=True)
class Module:
    module_id: str
    availability: str
    kind: str
    requires_all: tuple[str, ...]
    requires_any: tuple[str, ...]
    purpose: str


@dataclass(frozen=True)
class Profile:
    name: str
    config_scope: str
    offered: tuple[str, ...]
    defaults: tuple[str, ...]


@dataclass(frozen=True)
class Selection:
    source: str
    requested: tuple[str, ...]
    resolved: tuple[str, ...]
    origins: dict[str, str]


@dataclass(frozen=True)
class StageDefinition:
    stage_id: str
    trust_domain: str
    criticality: str
    dependencies: tuple[str, ...]
    confirmation: str
    effect_source: str
    production_apply_integration: bool
    purpose: str


@dataclass(frozen=True)
class PolicyRow:
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
class ConfigRow:
    scope: str
    module: str
    source: str
    target: str


@dataclass(frozen=True)
class SystemActionRow:
    action_id: str
    module: str
    profiles: tuple[str, ...]
    disposition: str
    privilege: str
    handler: str
    target: str
    applicability: str
    conflict_set: str | None
    dependencies: tuple[str, ...]
    rollback: str
    post_check: str
    purpose: str
    evidence: str


@dataclass(frozen=True)
class Effect:
    effect_id: str
    module: str
    detail: str
    payload_sha256: str | None = None

    def document(self) -> dict[str, Any]:
        result: dict[str, Any] = {
            "id": self.effect_id,
            "module": self.module,
            "detail": self.detail,
        }
        if self.payload_sha256 is not None:
            result["payload_sha256"] = self.payload_sha256
        return result


@dataclass(frozen=True)
class PlannedStage:
    definition: StageDefinition
    effects: tuple[Effect, ...]
    modules: tuple[str, ...]

    @property
    def applicable(self) -> bool:
        return bool(self.effects)

    @property
    def effect_fingerprint(self) -> str:
        return canonical_digest([effect.document() for effect in self.effects])


@dataclass(frozen=True)
class PlanInput:
    label: str
    path: Path
    digest: str
    kind: str = "file"


@dataclass(frozen=True)
class CommandSpec:
    argv: tuple[str, ...]
    executable: Path
    executable_digest: str


@dataclass(frozen=True)
class Adapter:
    kind: str
    fingerprint: str | None
    commands: dict[str, dict[str, CommandSpec]]
    input_files: tuple[PlanInput, ...]


@dataclass(frozen=True)
class RuntimePlan:
    document: dict[str, Any]
    fingerprint: str
    stages: tuple[PlannedStage, ...]
    input_files: tuple[PlanInput, ...]
    adapter: Adapter


@dataclass(frozen=True)
class PriorRun:
    state_path: Path
    log_path: Path
    state: dict[str, Any]


@dataclass(frozen=True)
class RunAction:
    kind: str
    prior: PriorRun | None = None
    retry_stage: str | None = None


class StateStore:
    """Private state directory, lock, latest pointer, and atomic JSON writes."""

    def __init__(self, root: Path):
        self.root = root
        self.runs = root / "runs"
        self.latest = root / "latest.json"
        self.lock_path = root / "orchestrator.lock"
        self._lock_fd: int | None = None

    def ensure_for_write(self) -> None:
        ensure_private_directory(self.root)
        ensure_private_directory(self.runs)

    def acquire(self) -> None:
        self.ensure_for_write()
        flags = os.O_RDWR | os.O_CREAT
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        try:
            fd = os.open(self.lock_path, flags, 0o600)
        except OSError as error:
            raise OrchestratorError(
                f"could not open state lock {self.lock_path}: {error}"
            ) from error
        try:
            inspect_private_fd(fd, self.lock_path, 0o600, "state lock")
            os.fchmod(fd, 0o600)
            fcntl.flock(fd, fcntl.LOCK_EX)
        except Exception:
            os.close(fd)
            raise
        self._lock_fd = fd

    def release(self) -> None:
        if self._lock_fd is not None:
            try:
                fcntl.flock(self._lock_fd, fcntl.LOCK_UN)
            finally:
                os.close(self._lock_fd)
                self._lock_fd = None

    def read_latest(self, plan: RuntimePlan | None = None) -> PriorRun | None:
        if not self.root.exists():
            return None
        inspect_private_directory(self.root, "orchestrator state directory")
        if not self.latest.exists() and not self.latest.is_symlink():
            return None
        latest = read_private_json(self.latest, "latest run pointer")
        if set(latest) != {"schema", "run_id", "plan_fingerprint"}:
            raise OrchestratorError("latest run pointer has malformed fields")
        if latest["schema"] != 1:
            raise OrchestratorError("latest run pointer has unsupported schema")
        run_id = latest["run_id"]
        fingerprint = latest["plan_fingerprint"]
        if not isinstance(run_id, str) or RUN_ID_RE.fullmatch(run_id) is None:
            raise OrchestratorError("latest run pointer has an unsafe run id")
        if not isinstance(fingerprint, str) or SHA256_RE.fullmatch(fingerprint) is None:
            raise OrchestratorError(
                "latest run pointer has an invalid plan fingerprint"
            )
        run_dir = self.runs / run_id
        inspect_private_directory(run_dir, "latest run directory")
        state_path = run_dir / "state.json"
        log_path = run_dir / "run.log"
        state_data = read_private_json(state_path, "run state")
        validate_state_shape(state_data)
        if (
            state_data["run_id"] != run_id
            or state_data["plan_fingerprint"] != fingerprint
        ):
            raise OrchestratorError(
                "latest pointer and run state are not bound to the same run/fingerprint"
            )
        inspect_private_file(log_path, 0o600, "run log")
        if plan is not None and fingerprint == plan.fingerprint:
            validate_state_against_plan(state_data, plan)
        return PriorRun(state_path, log_path, state_data)

    def create_run(
        self, plan: RuntimePlan, selection: Selection, profile: Profile
    ) -> PriorRun:
        self.ensure_for_write()
        run_id = f"{utc_timestamp()}-{uuid.uuid4().hex[:12]}"
        run_dir = self.runs / run_id
        try:
            run_dir.mkdir(mode=0o700)
        except OSError as error:
            raise OrchestratorError(
                f"could not create run directory {run_dir}: {error}"
            ) from error
        os.chmod(run_dir, 0o700)
        log_path = run_dir / "run.log"
        create_private_log(log_path, plan.fingerprint, run_id)
        now = utc_timestamp()
        state = {
            "schema": 3,
            "run_id": run_id,
            "plan_fingerprint": plan.fingerprint,
            "profile": profile.name,
            "mode": plan.document["mode"],
            "requested_modules": list(selection.requested),
            "resolved_modules": list(selection.resolved),
            "config_scope": profile.config_scope,
            "status": "running",
            "attempt": 1,
            "created_at": now,
            "updated_at": now,
            "failure_exit": 0,
            "failed_stage": None,
            "retry": None,
            "interruptions": 0,
            "acceptance": plan.document["acceptance"],
            "stages": [initial_stage_state(stage) for stage in plan.stages],
        }
        state_path = run_dir / "state.json"
        atomic_write_json(state_path, state, 0o600)
        atomic_write_json(
            self.latest,
            {"schema": 1, "run_id": run_id, "plan_fingerprint": plan.fingerprint},
            0o600,
        )
        append_log(log_path, plan.fingerprint, "run-created", attempt=1)
        return PriorRun(state_path, log_path, state)

    def write_state(self, prior: PriorRun) -> None:
        prior.state["updated_at"] = utc_timestamp()
        atomic_write_json(prior.state_path, prior.state, 0o600)


def normalize_exit(status: int) -> int:
    if status < 0:
        return min(255, 128 + abs(status))
    if status == 0:
        return 1
    return min(255, status)


def utc_timestamp() -> str:
    return dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def canonical_json(value: Any) -> bytes:
    return json.dumps(
        value, ensure_ascii=False, sort_keys=True, separators=(",", ":")
    ).encode("utf-8")


def canonical_digest(value: Any) -> str:
    return hashlib.sha256(canonical_json(value)).hexdigest()


def has_control(value: str) -> bool:
    return any(ord(character) < 32 or ord(character) == 127 for character in value)


def validate_token(value: str, label: str) -> None:
    if TOKEN_RE.fullmatch(value) is None:
        raise OrchestratorError(f"invalid {label}: {value!r}")


def split_dependency(raw: str, owner: str, label: str) -> tuple[str, ...]:
    if raw == "-":
        return ()
    if not raw or raw.startswith(",") or raw.endswith(",") or ",," in raw:
        raise OrchestratorError(f"{owner} has an invalid {label} list")
    values = tuple(raw.split(","))
    if len(set(values)) != len(values):
        raise OrchestratorError(f"{owner} repeats a {label} entry")
    for value in values:
        validate_token(value, f"{label} entry for {owner}")
    return values


def open_regular_nofollow(path: Path, label: str) -> tuple[int, os.stat_result]:
    flags = os.O_RDONLY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        fd = os.open(path, flags)
    except FileNotFoundError as error:
        raise OrchestratorError(f"{label} is missing: {path}") from error
    except OSError as error:
        raise OrchestratorError(f"could not open {label} {path}: {error}") from error
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode):
            raise OrchestratorError(f"{label} is not a regular file: {path}")
        if info.st_nlink != 1:
            raise OrchestratorError(f"{label} must have exactly one hard link: {path}")
        return fd, info
    except Exception:
        os.close(fd)
        raise


def read_regular_bytes(path: Path, label: str) -> bytes:
    fd, before = open_regular_nofollow(path, label)
    try:
        chunks: list[bytes] = []
        while True:
            chunk = os.read(fd, 1024 * 1024)
            if not chunk:
                break
            chunks.append(chunk)
        after = os.fstat(fd)
    except OSError as error:
        raise OrchestratorError(f"could not read {label} {path}: {error}") from error
    finally:
        os.close(fd)
    if (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns) != (
        after.st_dev,
        after.st_ino,
        after.st_size,
        after.st_mtime_ns,
    ):
        raise OrchestratorError(f"{label} changed while it was being read: {path}")
    return b"".join(chunks)


def snapshot(path: Path, schema: str, label: str) -> Snapshot:
    data = read_regular_bytes(path, label)
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError as error:
        raise OrchestratorError(f"{label} is not valid UTF-8: {path}") from error
    lines = tuple(text.splitlines())
    if not lines:
        raise OrchestratorError(f"{label} is empty: {path}")
    if lines[0] != schema:
        raise OrchestratorError(f"{label} has unsupported or missing schema marker")
    return Snapshot(label, path, data, hashlib.sha256(data).hexdigest(), lines)


def tsv_rows(
    source: Snapshot, expected_fields: int
) -> Iterable[tuple[int, tuple[str, ...]]]:
    for line_number, parts in enumerate(
        csv.reader(source.lines[1:], delimiter="\t"), 2
    ):
        if not parts or not parts[0] or parts[0].startswith("#"):
            continue
        values = tuple(parts)
        if len(values) != expected_fields or any(value == "" for value in values):
            raise OrchestratorError(f"invalid {source.label} row at line {line_number}")
        yield line_number, values


def load_modules() -> tuple[dict[str, Module], Snapshot]:
    source = snapshot(MODULES_PATH, "# schema=1", "module registry")
    modules: dict[str, Module] = {}
    for line_number, parts in tsv_rows(source, 6):
        module_id, availability, kind, requires_all, requires_any, purpose = parts
        validate_token(module_id, f"module id at line {line_number}")
        if availability not in {"available", "planning", "unavailable"}:
            raise OrchestratorError(
                f"invalid module availability at line {line_number}: {availability}"
            )
        if kind not in {"selectable", "dependency"}:
            raise OrchestratorError(
                f"invalid module kind at line {line_number}: {kind}"
            )
        if has_control(purpose):
            raise OrchestratorError(
                f"control character in module purpose at line {line_number}"
            )
        if module_id in modules:
            raise OrchestratorError(
                f"duplicate module at line {line_number}: {module_id}"
            )
        modules[module_id] = Module(
            module_id,
            availability,
            kind,
            split_dependency(requires_all, module_id, "requires-all"),
            split_dependency(requires_any, module_id, "requires-any"),
            purpose,
        )
    if not modules:
        raise OrchestratorError("module registry has no entries")
    for module in modules.values():
        for dependency in module.requires_all + module.requires_any:
            if dependency not in modules:
                raise OrchestratorError(
                    f"module {module.module_id} references unknown dependency {dependency}"
                )
            if dependency == module.module_id:
                raise OrchestratorError(f"module {module.module_id} depends on itself")
    validate_requires_all_cycles(modules)
    return modules, source


def load_production_readiness(
    modules: dict[str, Module],
) -> tuple[dict[str, str], Snapshot]:
    source = snapshot(
        PRODUCTION_READINESS_PATH,
        "# schema=1",
        "production module readiness registry",
    )
    readiness: dict[str, str] = {}
    for line_number, parts in tsv_rows(source, 3):
        module_id, state, evidence = parts
        validate_token(module_id, f"production readiness module at line {line_number}")
        if module_id not in modules:
            raise OrchestratorError(
                f"production readiness references unknown module at line {line_number}: {module_id}"
            )
        if module_id in readiness:
            raise OrchestratorError(
                f"duplicate production readiness row at line {line_number}: {module_id}"
            )
        if state not in {"available", "planning", "unavailable"}:
            raise OrchestratorError(
                f"invalid production readiness at line {line_number}: {state}"
            )
        if has_control(evidence):
            raise OrchestratorError(
                f"control character in production readiness evidence at line {line_number}"
            )
        module_state = modules[module_id].availability
        if state == "available" and module_state != "available":
            raise OrchestratorError(
                f"production readiness cannot exceed module availability at line {line_number}: {module_id}"
            )
        if module_state == "unavailable" and state != "unavailable":
            raise OrchestratorError(
                f"unavailable module has inconsistent production readiness at line {line_number}: {module_id}"
            )
        readiness[module_id] = state
    if set(readiness) != set(modules):
        missing = sorted(set(modules) - set(readiness))
        extra = sorted(set(readiness) - set(modules))
        raise OrchestratorError(
            f"production readiness coverage mismatch: missing={','.join(missing) or 'none'} "
            f"extra={','.join(extra) or 'none'}"
        )
    return readiness, source


def validate_requires_all_cycles(modules: dict[str, Module]) -> None:
    visiting: set[str] = set()
    visited: set[str] = set()

    def visit(module_id: str, trail: tuple[str, ...]) -> None:
        if module_id in visiting:
            cycle = " -> ".join(trail + (module_id,))
            raise OrchestratorError(
                f"module requires-all graph contains a cycle: {cycle}"
            )
        if module_id in visited:
            return
        visiting.add(module_id)
        for dependency in modules[module_id].requires_all:
            visit(dependency, trail + (module_id,))
        visiting.remove(module_id)
        visited.add(module_id)

    for module_id in modules:
        visit(module_id, ())


def load_profiles(modules: dict[str, Module]) -> tuple[dict[str, Profile], Snapshot]:
    source = snapshot(PROFILES_PATH, "# schema=1", "profile module manifest")
    rows: dict[str, list[tuple[str, str, str]]] = {}
    seen: set[tuple[str, str]] = set()
    for line_number, parts in tsv_rows(source, 4):
        profile_name, scope, module_id, default_state = parts
        validate_token(profile_name, f"profile at line {line_number}")
        if scope != "none":
            validate_token(scope, f"config scope at line {line_number}")
        validate_token(module_id, f"profile module at line {line_number}")
        if module_id not in modules:
            raise OrchestratorError(
                f"profile row references unknown module at line {line_number}: {module_id}"
            )
        if modules[module_id].kind != "selectable":
            raise OrchestratorError(
                f"profile offers dependency-only module at line {line_number}: {module_id}"
            )
        if default_state not in {"selected", "disabled"}:
            raise OrchestratorError(
                f"invalid profile default state at line {line_number}: {default_state}"
            )
        key = (profile_name, module_id)
        if key in seen:
            raise OrchestratorError(
                f"duplicate profile/module row at line {line_number}: {profile_name}/{module_id}"
            )
        seen.add(key)
        rows.setdefault(profile_name, []).append((scope, module_id, default_state))
    if not rows:
        raise OrchestratorError("profile module manifest has no entries")
    profiles: dict[str, Profile] = {}
    module_order = tuple(modules)
    for name, profile_rows in rows.items():
        scopes = {row[0] for row in profile_rows}
        if len(scopes) != 1:
            raise OrchestratorError(f"profile {name} has conflicting config scopes")
        offered_set = {row[1] for row in profile_rows}
        default_set = {row[1] for row in profile_rows if row[2] == "selected"}
        profiles[name] = Profile(
            name,
            next(iter(scopes)),
            tuple(module for module in module_order if module in offered_set),
            tuple(module for module in module_order if module in default_set),
        )
    return profiles, source


def load_stages() -> tuple[tuple[StageDefinition, ...], Snapshot]:
    source = snapshot(STAGES_PATH, "# schema=2", "stage manifest")
    definitions: list[StageDefinition] = []
    seen: set[str] = set()
    for line_number, parts in tsv_rows(source, 8):
        (
            stage_id,
            trust,
            criticality,
            dependencies_raw,
            confirmation,
            effect_source,
            integrated,
            purpose,
        ) = parts
        validate_token(stage_id, f"stage id at line {line_number}")
        validate_token(trust, f"trust domain at line {line_number}")
        if stage_id in seen:
            raise OrchestratorError(
                f"duplicate stage at line {line_number}: {stage_id}"
            )
        seen.add(stage_id)
        if criticality not in {"core", "optional"}:
            raise OrchestratorError(
                f"invalid stage criticality at line {line_number}: {criticality}"
            )
        if confirmation not in {"none", *CONFIRMATION_ORDER}:
            raise OrchestratorError(
                f"invalid stage confirmation at line {line_number}: {confirmation}"
            )
        if effect_source not in KNOWN_EFFECT_SOURCES:
            raise OrchestratorError(
                f"unknown stage effect source at line {line_number}: {effect_source}"
            )
        if integrated not in {"true", "false"}:
            raise OrchestratorError(
                f"invalid production integration value at line {line_number}: {integrated}"
            )
        if has_control(purpose):
            raise OrchestratorError(
                f"control character in stage purpose at line {line_number}"
            )
        definitions.append(
            StageDefinition(
                stage_id,
                trust,
                criticality,
                split_dependency(dependencies_raw, stage_id, "stage dependency"),
                confirmation,
                effect_source,
                integrated == "true",
                purpose,
            )
        )
    if set(seen) != REQUIRED_STAGES:
        missing = sorted(REQUIRED_STAGES - seen)
        extra = sorted(seen - REQUIRED_STAGES)
        raise OrchestratorError(
            f"stage manifest does not define the exact schema-2 stage set; missing={missing} extra={extra}"
        )
    by_id = {definition.stage_id: definition for definition in definitions}
    for definition in definitions:
        for dependency in definition.dependencies:
            if dependency not in by_id:
                raise OrchestratorError(
                    f"stage {definition.stage_id} references unknown dependency {dependency}"
                )
            if dependency == definition.stage_id:
                raise OrchestratorError(
                    f"stage {definition.stage_id} depends on itself"
                )
    return topological_stages(tuple(definitions)), source


def topological_stages(
    definitions: tuple[StageDefinition, ...],
) -> tuple[StageDefinition, ...]:
    order_index = {
        definition.stage_id: index for index, definition in enumerate(definitions)
    }
    remaining = {
        definition.stage_id: set(definition.dependencies) for definition in definitions
    }
    result: list[StageDefinition] = []
    by_id = {definition.stage_id: definition for definition in definitions}
    while remaining:
        ready = sorted(
            (stage for stage, deps in remaining.items() if not deps),
            key=order_index.__getitem__,
        )
        if not ready:
            cycle = ",".join(sorted(remaining, key=order_index.__getitem__))
            raise OrchestratorError(f"stage dependency graph contains a cycle: {cycle}")
        # Consume one row at a time so a newly unblocked earlier manifest row
        # is not overtaken by a later row that happened to be in the same batch.
        stage_id = ready[0]
        result.append(by_id[stage_id])
        del remaining[stage_id]
        for dependencies in remaining.values():
            dependencies.discard(stage_id)
    return tuple(result)


def parse_modules_argument(
    raw: str, modules: dict[str, Module], profile: Profile
) -> tuple[str, ...]:
    if raw == "none":
        return ()
    if not raw or raw.startswith(",") or raw.endswith(",") or ",," in raw:
        raise OrchestratorError(
            "--modules requires an exact comma-separated list or 'none'"
        )
    requested = raw.split(",")
    if len(set(requested)) != len(requested):
        raise OrchestratorError("--modules contains a duplicate module")
    offered = set(profile.offered)
    for module_id in requested:
        validate_token(module_id, "module in --modules")
        if module_id not in modules:
            raise OrchestratorError(f"unknown module in --modules: {module_id}")
        if modules[module_id].kind != "selectable":
            raise OrchestratorError(f"module is not directly selectable: {module_id}")
        if module_id not in offered:
            raise OrchestratorError(
                f"module is not supported by profile {profile.name}: {module_id}"
            )
    requested_set = set(requested)
    return tuple(module_id for module_id in modules if module_id in requested_set)


def resolve_selection(
    requested: Sequence[str], source: str, modules: dict[str, Module], profile: Profile
) -> Selection:
    selected = set(requested)
    origins = {module_id: source for module_id in requested}
    changed = True
    offered = set(profile.offered)
    while changed:
        changed = False
        for module_id in modules:
            if module_id not in selected:
                continue
            for dependency in modules[module_id].requires_all:
                dependency_model = modules[dependency]
                if dependency_model.kind == "selectable" and dependency not in offered:
                    raise OrchestratorError(
                        f"profile {profile.name} cannot satisfy dependency {dependency} required by {module_id}"
                    )
                if dependency not in selected:
                    selected.add(dependency)
                    origins[dependency] = f"dependency-of:{module_id}"
                    changed = True
    for module_id in modules:
        if module_id not in selected or not modules[module_id].requires_any:
            continue
        if not any(
            dependency in selected for dependency in modules[module_id].requires_any
        ):
            choices = ",".join(modules[module_id].requires_any)
            raise OrchestratorError(f"module {module_id} requires one of: {choices}")
    resolved = tuple(module_id for module_id in modules if module_id in selected)
    canonical_requested = tuple(
        module_id for module_id in modules if module_id in set(requested)
    )
    return Selection(source, canonical_requested, resolved, origins)


def state_root() -> Path:
    xdg = os.environ.get("XDG_STATE_HOME")
    base = Path(xdg) if xdg else Path.home() / ".local/state"
    if not base.is_absolute():
        raise OrchestratorError("XDG_STATE_HOME must be an absolute path")
    return base / PROJECT_STATE_NAME


def selection_manifest_fingerprint(
    module_source: Snapshot, profile_source: Snapshot
) -> str:
    return canonical_digest(
        {
            "modules": module_source.digest,
            "profiles": profile_source.digest,
        }
    )


def selection_path(root: Path, profile: Profile) -> Path:
    return root / "selections" / f"{profile.name}.json"


def load_saved_selection(
    root: Path,
    profile: Profile,
    modules: dict[str, Module],
    manifest_fingerprint: str,
    *,
    required: bool,
) -> tuple[str, ...] | None:
    path = selection_path(root, profile)
    if not path.exists() and not path.is_symlink():
        if required:
            raise OrchestratorError(
                f"no saved selection exists for profile {profile.name}"
            )
        return None
    data = read_private_json(path, "saved selection")
    expected = {
        "schema",
        "profile",
        "requested_modules",
        "selection_manifest_fingerprint",
    }
    if set(data) != expected or data.get("schema") != 1:
        raise OrchestratorError(
            "saved selection has malformed fields or unsupported schema"
        )
    if data.get("profile") != profile.name:
        raise OrchestratorError("saved selection profile does not match its path")
    if data.get("selection_manifest_fingerprint") != manifest_fingerprint:
        raise OrchestratorError(
            "saved selection was reviewed against changed module/profile manifests; edit and replace it explicitly"
        )
    raw_modules = data.get("requested_modules")
    if not isinstance(raw_modules, list) or not all(
        isinstance(value, str) for value in raw_modules
    ):
        raise OrchestratorError("saved selection has an invalid module list")
    return parse_modules_argument(
        ",".join(raw_modules) if raw_modules else "none", modules, profile
    )


def save_selection(
    root: Path,
    profile: Profile,
    requested: tuple[str, ...],
    manifest_fingerprint: str,
    replace: bool,
) -> None:
    path = selection_path(root, profile)
    document = {
        "schema": 1,
        "profile": profile.name,
        "requested_modules": list(requested),
        "selection_manifest_fingerprint": manifest_fingerprint,
    }
    if path.exists() or path.is_symlink():
        existing = read_private_json(path, "saved selection")
        if existing == document:
            return
        if not replace:
            raise OrchestratorError(
                "a different saved selection already exists; use --replace-saved-selection or interactive replace"
            )
    selections_dir = root / "selections"
    ensure_private_directory(root)
    ensure_private_directory(selections_dir)
    atomic_write_json(path, document, 0o600)


def prompt_line(prompt: str) -> str:
    print(prompt, end="", file=sys.stderr, flush=True)
    line = sys.stdin.readline()
    if line == "":
        raise Cancelled("selection/confirmation input ended; cancelled")
    return line.rstrip("\n")


def interactive_selection(
    root: Path,
    profile: Profile,
    modules: dict[str, Module],
    manifest_fingerprint: str,
) -> Selection:
    saved = load_saved_selection(
        root, profile, modules, manifest_fingerprint, required=False
    )
    defaults_text = ",".join(profile.defaults) if profile.defaults else "none"
    print(f"Profile defaults: {defaults_text}", file=sys.stderr)
    if saved is not None:
        saved_text = ",".join(saved) if saved else "none"
        print(
            f"Saved selection (not automatically reused): {saved_text}", file=sys.stderr
        )
        choices = "profile/edit/saved/cancel"
    else:
        choices = "profile/edit/cancel"
    action = prompt_line(f"Selection action [{choices}]: ")
    if action == "cancel":
        raise Cancelled("module selection cancelled")
    if action == "profile":
        return resolve_selection(
            profile.defaults, "interactive-profile", modules, profile
        )
    if action == "saved":
        if saved is None:
            raise OrchestratorError("no saved selection is available")
        return resolve_selection(saved, "interactive-saved-explicit", modules, profile)
    if action != "edit":
        raise OrchestratorError(f"unknown interactive selection action: {action!r}")
    raw = prompt_line("Exact modules (comma-separated or none): ")
    requested = parse_modules_argument(raw, modules, profile)
    selection = resolve_selection(requested, "interactive-edit", modules, profile)
    if saved is None:
        save_action = prompt_line("Saved selection action [keep/save/cancel]: ")
        if save_action == "cancel":
            raise Cancelled("module selection cancelled before saving")
        if save_action == "save":
            save_selection(
                root, profile, selection.requested, manifest_fingerprint, replace=False
            )
        elif save_action != "keep":
            raise OrchestratorError(f"unknown saved selection action: {save_action!r}")
    elif tuple(saved) != selection.requested:
        save_action = prompt_line("Saved selection action [keep/replace/cancel]: ")
        if save_action == "cancel":
            raise Cancelled(
                "module selection cancelled before replacing saved selection"
            )
        if save_action == "replace":
            save_selection(
                root, profile, selection.requested, manifest_fingerprint, replace=True
            )
        elif save_action != "keep":
            raise OrchestratorError(f"unknown saved selection action: {save_action!r}")
    return selection


def load_policy(modules: dict[str, Module]) -> tuple[tuple[PolicyRow, ...], Snapshot]:
    source = snapshot(WORKSTATION_PATH, "# schema=1", "workstation package policy")
    rows: list[PolicyRow] = []
    seen: set[str] = set()
    acquisitions = {
        "pacman",
        "verify-only",
        "archlinuxcn-bootstrap",
        "aur-build",
        "paru-bootstrap",
        "deferred",
    }
    for line_number, parts in tsv_rows(source, 9):
        (
            package,
            channel,
            repository,
            acquisition,
            module,
            restore_mode,
            policy,
            origin,
            purpose,
        ) = parts
        if (
            not package
            or package[0] not in "abcdefghijklmnopqrstuvwxyz0123456789"
            or has_control(package)
        ):
            raise OrchestratorError(
                f"unsafe package name at line {line_number}: {package!r}"
            )
        for value, label in (
            (channel, "channel"),
            (repository, "repository"),
            (acquisition, "acquisition"),
        ):
            if not value or has_control(value):
                raise OrchestratorError(f"invalid {label} at line {line_number}")
        validate_token(module, f"workstation module at line {line_number}")
        if module not in modules:
            raise OrchestratorError(
                f"workstation policy references unknown module at line {line_number}: {module}"
            )
        if acquisition not in acquisitions:
            raise OrchestratorError(
                f"unknown acquisition at line {line_number}: {acquisition}"
            )
        if policy not in {"install", "verify", "deferred"}:
            raise OrchestratorError(
                f"invalid execution policy at line {line_number}: {policy}"
            )
        if has_control(restore_mode) or has_control(origin) or has_control(purpose):
            raise OrchestratorError(
                f"control character in workstation policy at line {line_number}"
            )
        if package in seen:
            raise OrchestratorError(
                f"duplicate workstation package at line {line_number}: {package}"
            )
        seen.add(package)
        rows.append(PolicyRow(*parts))
    if not rows:
        raise OrchestratorError("workstation package policy has no entries")
    return tuple(rows), source


def safe_relative(value: str, label: str, line_number: int) -> None:
    path = Path(value)
    if (
        path.is_absolute()
        or not value
        or "\x00" in value
        or any(part in {"", ".", ".."} for part in path.parts)
    ):
        raise OrchestratorError(f"unsafe {label} at line {line_number}: {value!r}")
    if has_control(value):
        raise OrchestratorError(f"control character in {label} at line {line_number}")


def load_config(modules: dict[str, Module]) -> tuple[tuple[ConfigRow, ...], Snapshot]:
    source = snapshot(CONFIG_PATH, "# schema=3", "configuration mapping")
    rows: list[ConfigRow] = []
    seen: set[tuple[str, str]] = set()
    for line_number, parts in tsv_rows(source, 5):
        scope, module, source_path, target, _mode = parts
        validate_token(scope, f"configuration scope at line {line_number}")
        validate_token(module, f"configuration module at line {line_number}")
        if module not in modules:
            raise OrchestratorError(
                f"configuration mapping references unknown module at line {line_number}: {module}"
            )
        safe_relative(source_path, "configuration source", line_number)
        safe_relative(target, "configuration target", line_number)
        key = (scope, target)
        if key in seen:
            raise OrchestratorError(
                f"duplicate configuration target at line {line_number}: {scope}/{target}"
            )
        seen.add(key)
        rows.append(ConfigRow(scope, module, source_path, target))
    if not rows:
        raise OrchestratorError("configuration mapping has no entries")
    return tuple(rows), source


def load_system_actions(
    modules: dict[str, Module],
    known_profiles: set[str],
) -> tuple[tuple[SystemActionRow, ...], Snapshot, Snapshot]:
    conflict_source = snapshot(
        SYSTEM_CONFLICTS_PATH, "# schema=1", "system action conflict manifest"
    )
    conflict_ids: set[str] = set()
    for line_number, parts in tsv_rows(conflict_source, 6):
        conflict_id, packages, system_units, user_units, behavior, purpose = parts
        validate_token(conflict_id, f"system conflict id at line {line_number}")
        if conflict_id in conflict_ids:
            raise OrchestratorError(
                f"duplicate system conflict id at line {line_number}: {conflict_id}"
            )
        conflict_ids.add(conflict_id)
        if behavior not in {
            "block-active-or-installed",
            "block-active",
            "block-managed-paths",
        }:
            raise OrchestratorError(
                f"invalid system conflict behavior at line {line_number}"
            )
        if any(
            has_control(value)
            for value in (packages, system_units, user_units, purpose)
        ):
            raise OrchestratorError(
                f"control character in system conflict manifest at line {line_number}"
            )

    source = snapshot(SYSTEM_ACTIONS_PATH, "# schema=1", "system action manifest")
    actions: list[SystemActionRow] = []
    seen: set[str] = set()
    allowed_dispositions = {"apply", "verify", "manual", "deferred"}
    allowed_privileges = {"none", "user", "root"}
    for line_number, parts in tsv_rows(source, 14):
        (
            action_id,
            module,
            profiles_raw,
            disposition,
            privilege,
            handler,
            target,
            applicability,
            conflict_raw,
            dependencies_raw,
            rollback,
            post_check,
            purpose,
            evidence,
        ) = parts
        validate_token(action_id, f"system action id at line {line_number}")
        if action_id in seen:
            raise OrchestratorError(
                f"duplicate system action at line {line_number}: {action_id}"
            )
        seen.add(action_id)
        validate_token(module, f"system action module at line {line_number}")
        if module not in modules:
            raise OrchestratorError(
                f"system action references unknown module at line {line_number}: {module}"
            )
        if profiles_raw == "all":
            action_profiles = tuple(sorted(known_profiles))
        else:
            action_profiles = split_dependency(
                profiles_raw, action_id, "system action profile"
            )
            if not set(action_profiles).issubset(known_profiles):
                raise OrchestratorError(
                    f"system action references unknown profile at line {line_number}"
                )
        if (
            disposition not in allowed_dispositions
            or privilege not in allowed_privileges
        ):
            raise OrchestratorError(
                f"invalid system action disposition/privilege at line {line_number}"
            )
        validate_token(handler, f"system action handler at line {line_number}")
        validate_token(
            applicability, f"system action applicability at line {line_number}"
        )
        conflict = None if conflict_raw == "-" else conflict_raw
        if conflict is not None:
            validate_token(conflict, f"system action conflict at line {line_number}")
            if conflict not in conflict_ids:
                raise OrchestratorError(
                    f"system action references unknown conflict set at line {line_number}: {conflict}"
                )
        dependencies = split_dependency(
            dependencies_raw, action_id, "system action dependency"
        )
        if any(
            has_control(value)
            for value in (target, rollback, post_check, purpose, evidence)
        ):
            raise OrchestratorError(
                f"control character in system action at line {line_number}"
            )
        actions.append(
            SystemActionRow(
                action_id,
                module,
                action_profiles,
                disposition,
                privilege,
                handler,
                target,
                applicability,
                conflict,
                dependencies,
                rollback,
                post_check,
                purpose,
                evidence,
            )
        )
    if not actions:
        raise OrchestratorError("system action manifest has no entries")
    by_id = {action.action_id: action for action in actions}
    for action in actions:
        for dependency in action.dependencies:
            if dependency not in by_id:
                raise OrchestratorError(
                    f"system action {action.action_id} references unknown dependency {dependency}"
                )
    visiting: set[str] = set()
    visited: set[str] = set()

    def visit(action_id: str) -> None:
        if action_id in visiting:
            raise OrchestratorError(
                f"system action dependency cycle includes {action_id}"
            )
        if action_id in visited:
            return
        visiting.add(action_id)
        for dependency in by_id[action_id].dependencies:
            visit(dependency)
        visiting.remove(action_id)
        visited.add(action_id)

    for action in actions:
        visit(action.action_id)
    return tuple(actions), source, conflict_source


def policy_buckets(
    rows: Sequence[PolicyRow], selected: set[str]
) -> dict[str, list[PolicyRow]]:
    buckets = {
        "official": [],
        "arch-bootstrap": [],
        "arch-packages": [],
        "aur": [],
        "verify": [],
    }
    for row in rows:
        if row.module not in selected:
            continue
        if (
            row.policy == "install"
            and row.acquisition == "pacman"
            and row.repository != "archlinuxcn"
        ):
            buckets["official"].append(row)
        elif row.policy == "install" and row.acquisition == "archlinuxcn-bootstrap":
            buckets["arch-bootstrap"].append(row)
        elif (
            row.policy == "install"
            and row.acquisition == "pacman"
            and row.repository == "archlinuxcn"
        ):
            buckets["arch-packages"].append(row)
        elif row.policy == "install" and row.acquisition in {
            "aur-build",
            "paru-bootstrap",
        }:
            buckets["aur"].append(row)
        elif row.policy == "verify" and row.acquisition == "verify-only":
            buckets["verify"].append(row)
    for values in buckets.values():
        values.sort(key=lambda row: row.package)
    return buckets


def package_effect(row: PolicyRow, prefix: str) -> Effect:
    return Effect(
        f"{prefix}{row.package}",
        row.module,
        f"package={row.package} channel={row.channel} repository={row.repository} acquisition={row.acquisition}",
    )


def archlinuxcn_bootstrap_effect(row: PolicyRow) -> Effect:
    return Effect(
        f"bootstrap:{row.package}",
        row.module,
        (
            f"package={row.package} channel={row.channel} repository={row.repository} "
            f"acquisition={row.acquisition} repository-config=fixed-include-fragment "
            "refresh=conditional-full-system-and-repository"
        ),
    )


def derive_stages(
    definitions: Sequence[StageDefinition],
    selection: Selection,
    profile: Profile,
    policy: Sequence[PolicyRow],
    config: Sequence[ConfigRow],
    system_actions: Sequence[SystemActionRow],
) -> tuple[tuple[PlannedStage, ...], tuple[tuple[str, Path, str], ...]]:
    selected = set(selection.resolved)
    buckets = policy_buckets(policy, selected)
    package_modules = tuple(
        module
        for module in selection.resolved
        if any(
            row.module == module
            for key in ("official", "arch-bootstrap", "arch-packages", "aur")
            for row in buckets[key]
        )
    )
    payload_inputs: list[tuple[str, Path, str]] = []
    planned: list[PlannedStage] = []
    for definition in definitions:
        effects: list[Effect]
        modules: tuple[str, ...]
        source = definition.effect_source
        if source == "derived:official-update":
            effects = (
                [
                    Effect(
                        "full-system-refresh",
                        "-",
                        "rolling full-system refresh boundary",
                    )
                ]
                if package_modules
                else []
            )
            modules = package_modules
        elif source == "workstation:official-install":
            effects = [package_effect(row, "install:") for row in buckets["official"]]
            modules = effect_modules(effects, selection.resolved)
        elif source == "workstation:archlinuxcn-bootstrap":
            effects = [
                archlinuxcn_bootstrap_effect(row) for row in buckets["arch-bootstrap"]
            ]
            modules = effect_modules(effects, selection.resolved)
        elif source == "workstation:archlinuxcn-install":
            effects = [
                package_effect(row, "install:") for row in buckets["arch-packages"]
            ]
            modules = effect_modules(effects, selection.resolved)
        elif source == "workstation:aur-source":
            effects = [package_effect(row, "acquire-source:") for row in buckets["aur"]]
            modules = effect_modules(effects, selection.resolved)
        elif source == "workstation:aur-build-install":
            effects = [package_effect(row, "build-install:") for row in buckets["aur"]]
            modules = effect_modules(effects, selection.resolved)
        elif source == "system:actions":
            effects = [
                Effect(
                    f"action:{action.action_id}",
                    action.module,
                    " ".join(
                        (
                            f"disposition={action.disposition}",
                            f"privilege={action.privilege}",
                            f"handler={action.handler}",
                            f"target={action.target}",
                            f"applicability={action.applicability}",
                            f"conflict={action.conflict_set or '-'}",
                        )
                    ),
                )
                for action in system_actions
                if action.module in selected and profile.name in action.profiles
            ]
            effects.extend(package_effect(row, "verify:") for row in buckets["verify"])
            modules = effect_modules(effects, selection.resolved)
        elif source == "config:privilege-wrapper":
            effects = []
            if profile.config_scope != "none":
                wrapper_targets = {
                    "scripts/desktop/gsudo",
                    "scripts/desktop/fuzzel-askpass",
                }
                wrapper_rows = sorted(
                    (
                        entry
                        for entry in config
                        if entry.scope == profile.config_scope
                        and entry.target in wrapper_targets
                    ),
                    key=lambda entry: entry.target,
                )
                if {entry.target for entry in wrapper_rows} != wrapper_targets:
                    raise OrchestratorError(
                        f"profile {profile.name} config scope lacks the exact privilege wrapper mappings"
                    )
                for row in wrapper_rows:
                    payload_path = ROOT / row.source
                    payload_data = read_regular_bytes(
                        payload_path, f"privilege wrapper source {row.source}"
                    )
                    payload_digest = hashlib.sha256(payload_data).hexdigest()
                    payload_inputs.append(
                        (f"privilege-source:{row.source}", payload_path, payload_digest)
                    )
                    effects.append(
                        Effect(
                            f"deploy:{row.target}",
                            row.module,
                            f"source={row.source} target={row.target}",
                            payload_digest,
                        )
                    )
            modules = effect_modules(effects, selection.resolved)
        elif source == "config:mappings":
            effects = []
            if profile.config_scope != "none":
                for row in sorted(
                    (
                        entry
                        for entry in config
                        if entry.scope == profile.config_scope
                        and entry.module in selected
                        and entry.target
                        not in {
                            "scripts/desktop/gsudo",
                            "scripts/desktop/fuzzel-askpass",
                        }
                    ),
                    key=lambda entry: entry.target,
                ):
                    payload_path = ROOT / row.source
                    payload_data = read_regular_bytes(
                        payload_path, f"selected config source {row.source}"
                    )
                    payload_digest = hashlib.sha256(payload_data).hexdigest()
                    payload_inputs.append(
                        (f"config-source:{row.source}", payload_path, payload_digest)
                    )
                    effects.append(
                        Effect(
                            f"deploy:{row.target}",
                            row.module,
                            f"source={row.source} target={row.target}",
                            payload_digest,
                        )
                    )
            modules = effect_modules(effects, selection.resolved)
        elif source == "none":
            effects = []
            modules = ()
        else:  # guarded by stage-manifest validation
            raise OrchestratorError(f"internal error: unhandled effect source {source}")
        if len({effect.effect_id for effect in effects}) != len(effects):
            raise OrchestratorError(
                f"stage {definition.stage_id} derived duplicate effect ids"
            )
        planned.append(PlannedStage(definition, tuple(effects), modules))
    return tuple(planned), tuple(payload_inputs)


def effect_modules(
    effects: Sequence[Effect], selection_order: Sequence[str]
) -> tuple[str, ...]:
    found = {effect.module for effect in effects if effect.module != "-"}
    return tuple(module for module in selection_order if module in found)


def reviewed_executable_path(raw: str, line_number: int) -> Path:
    path = Path(raw)
    if path.is_absolute():
        return path
    if (
        not path.parts
        or path.parts[0] != "installer"
        or any(part in {"", ".", ".."} for part in path.parts)
        or "//" in raw
    ):
        raise OrchestratorError(
            f"reviewed executable path at line {line_number} is not an approved project-relative installer path: {raw}"
        )
    candidate = ROOT / path
    current = ROOT
    for part in path.parts[:-1]:
        current /= part
        try:
            info = current.lstat()
        except OSError as error:
            raise OrchestratorError(
                f"could not inspect reviewed executable parent {current}: {error}"
            ) from error
        if (
            stat.S_ISLNK(info.st_mode)
            or not stat.S_ISDIR(info.st_mode)
            or info.st_uid not in {0, os.geteuid()}
            or info.st_mode & 0o022
        ):
            raise OrchestratorError(f"reviewed executable parent is unsafe: {current}")
    return candidate


def validate_reviewed_file(path: Path, label: str) -> None:
    try:
        info = path.stat(follow_symlinks=False)
    except OSError as error:
        raise OrchestratorError(f"could not inspect {label} {path}: {error}") from error
    if (
        stat.S_ISLNK(info.st_mode)
        or not stat.S_ISREG(info.st_mode)
        or info.st_nlink != 1
        or info.st_uid not in {0, os.geteuid()}
        or info.st_mode & 0o022
    ):
        raise OrchestratorError(
            f"{label} is not a protected single-link regular file: {path}"
        )


def hash_executable(path: Path, expected: str | None = None) -> str:
    if not path.is_absolute():
        raise OrchestratorError(f"adapter executable path must be absolute: {path}")
    data = read_regular_bytes(path, "adapter executable")
    try:
        info = path.stat(follow_symlinks=False)
    except OSError as error:
        raise OrchestratorError(
            f"could not inspect adapter executable {path}: {error}"
        ) from error
    if not info.st_mode & 0o111:
        raise OrchestratorError(f"adapter executable is not executable: {path}")
    digest = hashlib.sha256(data).hexdigest()
    if expected is not None and digest != expected:
        raise OrchestratorError(f"adapter executable hash mismatch: {path}")
    return digest


def validate_argv(raw: Any, stage: str, action: str) -> tuple[str, ...]:
    if (
        not isinstance(raw, list)
        or not raw
        or not all(isinstance(value, str) and value for value in raw)
    ):
        raise OrchestratorError(
            f"test execution map has invalid {action} argv for stage {stage}"
        )
    for value in raw:
        if "\x00" in value or has_control(value):
            raise OrchestratorError(
                f"test execution map has unsafe {action} argv for stage {stage}"
            )
    return tuple(raw)


def load_test_adapter(path: Path, definitions: Sequence[StageDefinition]) -> Adapter:
    if os.environ.get("FULL_ORCHESTRATOR_TESTING") != "1":
        raise OrchestratorError(
            "--test-execution-map is disabled unless FULL_ORCHESTRATOR_TESTING=1"
        )
    data = read_regular_bytes(path, "test execution map")
    try:
        document = json.loads(data)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise OrchestratorError(
            f"test execution map is malformed JSON: {error}"
        ) from error
    if not isinstance(document, dict) or set(document) != {
        "schema",
        "test_only",
        "stages",
    }:
        raise OrchestratorError("test execution map has malformed top-level fields")
    if (
        document["schema"] != 1
        or document["test_only"] is not True
        or not isinstance(document["stages"], dict)
    ):
        raise OrchestratorError(
            "test execution map has unsupported schema or is not marked test-only"
        )
    known = {definition.stage_id for definition in definitions}
    if not set(document["stages"]).issubset(known):
        raise OrchestratorError("test execution map references an unknown stage")
    commands: dict[str, dict[str, CommandSpec]] = {}
    executable_inputs: dict[Path, str] = {}
    for stage, actions in document["stages"].items():
        if not isinstance(actions, dict) or set(actions) != {"execute", "verify"}:
            raise OrchestratorError(
                f"test execution map must define execute and verify for stage {stage}"
            )
        commands[stage] = {}
        for action in ("execute", "verify"):
            argv = validate_argv(actions[action], stage, action)
            executable = Path(argv[0])
            digest = hash_executable(executable)
            executable_inputs[executable] = digest
            commands[stage][action] = CommandSpec(argv, executable, digest)
        # Preflight uses the reviewed execute entrypoint with a distinct action
        # environment.  Schema 1 remains compatible while every adapter must
        # implement a read-only preflight branch before it may execute.
        commands[stage]["preflight"] = commands[stage]["execute"]
    map_digest = hashlib.sha256(data).hexdigest()
    fingerprint = canonical_digest(
        {
            "kind": "test-only",
            "map": map_digest,
            "executables": sorted(
                (str(path), digest) for path, digest in executable_inputs.items()
            ),
        }
    )
    inputs = [PlanInput("test-execution-map", path, map_digest)]
    inputs.extend(
        PlanInput(f"adapter-executable:{item}", item, digest)
        for item, digest in sorted(executable_inputs.items())
    )
    return Adapter("test-only", fingerprint, commands, tuple(inputs))


def project_stage_input_path(raw: str, kind: str, line_number: int) -> Path:
    relative = Path(raw)
    allowed = (
        relative.parts[:1] == ("installer",)
        or relative.parts[:1] == ("manifests",)
        or relative.parts[:2] == ("config", "templates")
        or relative.parts[:2] == ("third_party", "aur")
    )
    if (
        relative.is_absolute()
        or not relative.parts
        or any(part in {"", ".", ".."} for part in relative.parts)
        or "//" in raw
        or not allowed
        or (kind == "tree" and relative.parts[:2] != ("third_party", "aur"))
    ):
        raise OrchestratorError(
            f"unsafe reviewed stage input path at line {line_number}: {raw}"
        )
    path = ROOT / relative
    current = ROOT
    for part in relative.parts[:-1]:
        current /= part
        try:
            info = current.lstat()
        except OSError as error:
            raise OrchestratorError(
                f"could not inspect reviewed stage input parent {current}: {error}"
            ) from error
        if (
            stat.S_ISLNK(info.st_mode)
            or not stat.S_ISDIR(info.st_mode)
            or info.st_uid not in {0, os.geteuid()}
            or info.st_mode & 0o022
        ):
            raise OrchestratorError(f"reviewed stage input parent is unsafe: {current}")
    return path


def tree_input_digest(path: Path, label: str) -> str:
    try:
        root_info = path.lstat()
    except OSError as error:
        raise OrchestratorError(f"could not inspect {label} {path}: {error}") from error
    if (
        stat.S_ISLNK(root_info.st_mode)
        or not stat.S_ISDIR(root_info.st_mode)
        or root_info.st_uid not in {0, os.geteuid()}
        or root_info.st_mode & 0o022
    ):
        raise OrchestratorError(f"{label} is not a protected directory: {path}")
    try:
        entries = sorted(path.iterdir(), key=lambda item: os.fsencode(item.name))
    except OSError as error:
        raise OrchestratorError(
            f"could not enumerate {label} {path}: {error}"
        ) from error
    if not entries:
        raise OrchestratorError(f"{label} is empty: {path}")
    digest = hashlib.sha256()
    for entry in entries:
        try:
            info = entry.lstat()
        except OSError as error:
            raise OrchestratorError(
                f"could not inspect {label} entry {entry}: {error}"
            ) from error
        if (
            stat.S_ISLNK(info.st_mode)
            or not stat.S_ISREG(info.st_mode)
            or info.st_nlink != 1
            or info.st_uid not in {0, os.geteuid()}
            or info.st_mode & 0o022
        ):
            raise OrchestratorError(f"{label} contains an unsafe entry: {entry}")
        data = read_regular_bytes(entry, f"{label} entry")
        digest.update(entry.name.encode())
        digest.update(b"\0")
        digest.update(f"{stat.S_IMODE(info.st_mode):04o}".encode())
        digest.update(b"\0")
        digest.update(hashlib.sha256(data).hexdigest().encode())
        digest.update(b"\n")
    return digest.hexdigest()


def plan_input_digest(item: PlanInput) -> str:
    if item.kind == "file":
        return hashlib.sha256(
            read_regular_bytes(item.path, f"plan input {item.label}")
        ).hexdigest()
    if item.kind == "tree":
        return tree_input_digest(item.path, f"plan input {item.label}")
    raise OrchestratorError(f"internal error: unsupported plan input kind {item.kind}")


def load_stage_inputs(
    definitions: Sequence[StageDefinition],
    stages: Sequence[PlannedStage],
    *,
    required: bool,
) -> tuple[PlanInput, ...]:
    try:
        source = snapshot(
            STAGE_INPUTS_PATH, "# schema=1", "reviewed stage input manifest"
        )
    except OrchestratorError as error:
        if not required and " is missing:" in str(error):
            return ()
        raise
    validate_reviewed_file(STAGE_INPUTS_PATH, "reviewed stage input manifest")
    known = {definition.stage_id for definition in definitions}
    applicable = {stage.definition.stage_id for stage in stages if stage.applicable}
    result: list[PlanInput] = [
        PlanInput("stage-input-manifest", STAGE_INPUTS_PATH, source.digest)
    ]
    seen_ids: set[str] = set()
    seen_paths: set[Path] = set()
    covered_applicable_stages: set[str] = set()
    for line_number, parts in tsv_rows(source, 5):
        input_id, raw_stages, kind, raw_path, expected = parts
        if STAGE_INPUT_ID_RE.fullmatch(input_id) is None or input_id in seen_ids:
            raise OrchestratorError(
                f"unsafe or duplicate reviewed stage input id at line {line_number}: {input_id}"
            )
        seen_ids.add(input_id)
        stage_ids = tuple(raw_stages.split(","))
        if (
            not stage_ids
            or len(stage_ids) != len(set(stage_ids))
            or any(stage not in known for stage in stage_ids)
        ):
            raise OrchestratorError(
                f"reviewed stage input has invalid stages at line {line_number}"
            )
        if kind not in {"file", "tree"} or SHA256_RE.fullmatch(expected) is None:
            raise OrchestratorError(
                f"reviewed stage input has invalid kind/hash at line {line_number}"
            )
        path = project_stage_input_path(raw_path, kind, line_number)
        if path in seen_paths:
            raise OrchestratorError(
                f"reviewed stage input repeats a path at line {line_number}: {raw_path}"
            )
        seen_paths.add(path)
        item = PlanInput(f"stage-input:{input_id}", path, expected, kind)
        actual = plan_input_digest(item)
        if actual != expected:
            raise OrchestratorError(f"reviewed stage input hash mismatch: {input_id}")
        matched_stages = applicable.intersection(stage_ids)
        if matched_stages:
            result.append(item)
            covered_applicable_stages.update(matched_stages)
    missing_required = sorted(
        applicable.intersection(AUXILIARY_INPUT_REQUIRED_STAGES)
        - covered_applicable_stages
    )
    if required and missing_required:
        raise OrchestratorError(
            "applicable stages lack required auxiliary inputs: "
            + ",".join(missing_required)
        )
    return tuple(result)


def load_reviewed_adapter(
    path: Path, definitions: Sequence[StageDefinition]
) -> Adapter:
    source = snapshot(path, "# schema=1", "reviewed executable manifest")
    validate_reviewed_file(path, "reviewed executable manifest")
    if len(source.lines) < 2 or source.lines[1] != "# reviewed=true":
        raise OrchestratorError(
            "reviewed executable manifest lacks the exact '# reviewed=true' marker"
        )
    known = {definition.stage_id for definition in definitions}
    commands: dict[str, dict[str, CommandSpec]] = {}
    executable_inputs: dict[Path, str] = {}
    for line_number, parts in tsv_rows(source, 5):
        stage, execute_path, execute_hash, verify_path, verify_hash = parts
        if stage not in known:
            raise OrchestratorError(
                f"reviewed executable manifest references unknown stage at line {line_number}: {stage}"
            )
        if stage in commands:
            raise OrchestratorError(
                f"duplicate reviewed executable stage at line {line_number}: {stage}"
            )
        if (
            SHA256_RE.fullmatch(execute_hash) is None
            or SHA256_RE.fullmatch(verify_hash) is None
        ):
            raise OrchestratorError(f"invalid executable hash at line {line_number}")
        execute = reviewed_executable_path(execute_path, line_number)
        verify = reviewed_executable_path(verify_path, line_number)
        validate_reviewed_file(execute, "reviewed adapter executable")
        validate_reviewed_file(verify, "reviewed adapter executable")
        execute_actual = hash_executable(execute, execute_hash)
        verify_actual = hash_executable(verify, verify_hash)
        executable_inputs[execute] = execute_actual
        executable_inputs[verify] = verify_actual
        execute_spec = CommandSpec((str(execute),), execute, execute_actual)
        commands[stage] = {
            "preflight": execute_spec,
            "execute": execute_spec,
            "verify": CommandSpec((str(verify),), verify, verify_actual),
        }
    kind = (
        "canonical-reviewed-executable-manifest"
        if path == CANONICAL_EXECUTABLE_MANIFEST
        else "external-reviewed-executable-manifest"
    )
    fingerprint = canonical_digest(
        {
            "kind": kind,
            "manifest": source.digest,
            "executables": sorted(
                (str(item), digest) for item, digest in executable_inputs.items()
            ),
        }
    )
    inputs = [PlanInput("reviewed-executable-manifest", path, source.digest)]
    inputs.extend(
        PlanInput(f"adapter-executable:{item}", item, digest)
        for item, digest in sorted(executable_inputs.items())
    )
    return Adapter(kind, fingerprint, commands, tuple(inputs))


def no_adapter() -> Adapter:
    return Adapter("none", None, {}, ())


def acceptance_summary(
    stages: Sequence[PlannedStage],
    actions: Sequence[SystemActionRow],
) -> dict[str, Any]:
    system_stage = next(
        (stage for stage in stages if stage.definition.stage_id == "system-actions"),
        None,
    )
    applicable_ids = {
        effect.effect_id.removeprefix("action:")
        for effect in (() if system_stage is None else system_stage.effects)
        if effect.effect_id.startswith("action:")
    }
    manual: list[str] = []
    deferred: list[str] = []
    conditional: list[str] = []
    relogin_or_reboot: list[dict[str, str]] = []
    pending: list[str] = []
    for action in actions:
        if action.action_id not in applicable_ids:
            continue
        categories = 0
        if action.disposition == "manual":
            manual.append(action.action_id)
            categories += 1
        if action.disposition == "deferred":
            deferred.append(action.action_id)
            categories += 1
        if action.applicability != "always":
            conditional.append(action.action_id)
            categories += 1
        combined = " ".join(
            (action.rollback, action.post_check, action.purpose)
        ).lower()
        if "relogin" in combined or "reboot" in combined or "log out" in combined:
            relogin_or_reboot.append(
                {"action": action.action_id, "reason": action.post_check}
            )
            categories += 1
        if categories:
            pending.append(action.action_id)
    return {
        "pending_actions": pending,
        "manual_actions": manual,
        "deferred_actions": deferred,
        "conditional_actions": conditional,
        "relogin_or_reboot_reasons": relogin_or_reboot,
    }


def build_plan(
    profile: Profile,
    mode: str,
    selection: Selection,
    module_source: Snapshot,
    production_readiness_source: Snapshot,
    production_readiness: dict[str, str],
    profile_source: Snapshot,
    stage_source: Snapshot,
    workstation_source: Snapshot,
    config_source: Snapshot,
    system_action_source: Snapshot,
    system_conflict_source: Snapshot,
    stages: tuple[PlannedStage, ...],
    payload_inputs: tuple[tuple[str, Path, str], ...],
    stage_inputs: tuple[PlanInput, ...],
    adapter: Adapter,
    modules: dict[str, Module],
    system_actions: Sequence[SystemActionRow],
) -> RuntimePlan:
    script_digest = hashlib.sha256(
        read_regular_bytes(SCRIPT_PATH, "orchestrator source")
    ).hexdigest()
    inputs: list[PlanInput] = [
        PlanInput("orchestrator", SCRIPT_PATH, script_digest),
        PlanInput("modules", MODULES_PATH, module_source.digest),
        PlanInput(
            "production-module-readiness",
            PRODUCTION_READINESS_PATH,
            production_readiness_source.digest,
        ),
        PlanInput("profiles", PROFILES_PATH, profile_source.digest),
        PlanInput("stages", STAGES_PATH, stage_source.digest),
        PlanInput("workstation-policy", WORKSTATION_PATH, workstation_source.digest),
        PlanInput("config-mappings", CONFIG_PATH, config_source.digest),
        PlanInput("system-actions", SYSTEM_ACTIONS_PATH, system_action_source.digest),
        PlanInput(
            "system-action-conflicts",
            SYSTEM_CONFLICTS_PATH,
            system_conflict_source.digest,
        ),
    ]
    inputs.extend(PlanInput(*item) for item in payload_inputs)
    inputs.extend(stage_inputs)
    inputs.extend(adapter.input_files)
    if len({item.label for item in inputs}) != len(inputs):
        raise OrchestratorError("plan input labels are not unique")
    stage_documents = []
    for planned in stages:
        definition = planned.definition
        stage_documents.append(
            {
                "id": definition.stage_id,
                "trust_domain": definition.trust_domain,
                "criticality": definition.criticality,
                "dependencies": list(definition.dependencies),
                "confirmation": definition.confirmation,
                "effect_source": definition.effect_source,
                "production_apply_integration": definition.production_apply_integration,
                "applicable": planned.applicable,
                "modules": list(planned.modules),
                "effects": [effect.document() for effect in planned.effects],
                "purpose": definition.purpose,
            }
        )
    blocked_modules = [
        module_id
        for module_id in selection.resolved
        if production_readiness[module_id] != "available"
    ]
    required_confirmations = [
        domain
        for domain in CONFIRMATION_ORDER
        if any(
            stage.applicable and stage.definition.confirmation == domain
            for stage in stages
        )
    ]
    missing_adapter_stages = [
        stage.definition.stage_id
        for stage in stages
        if stage.applicable and stage.definition.stage_id not in adapter.commands
    ]
    non_integrated_stages = [
        stage.definition.stage_id
        for stage in stages
        if stage.applicable and not stage.definition.production_apply_integration
    ]
    canonical_adapter = adapter.kind == "canonical-reviewed-executable-manifest"
    production_integration = (
        canonical_adapter and not missing_adapter_stages and not non_integrated_stages
    )
    base_document = {
        "schema": 2,
        "profile": profile.name,
        "mode": mode,
        "config_scope": profile.config_scope,
        "selection": {
            "source": selection.source,
            "requested_modules": list(selection.requested),
            "resolved_modules": list(selection.resolved),
            "production_readiness": {
                module_id: production_readiness[module_id]
                for module_id in selection.resolved
            },
        },
        "stages": stage_documents,
        "acceptance": acceptance_summary(stages, system_actions),
        "required_confirmations": required_confirmations,
        "apply_blockers": {
            "non_executable_modules": blocked_modules,
            "missing_adapter_stages": missing_adapter_stages,
            "non_integrated_stages": non_integrated_stages,
            "noncanonical_adapter": adapter.kind
            not in {"canonical-reviewed-executable-manifest", "test-only"},
        },
        "safety": {
            "production_apply_integration": production_integration,
            "execution_adapter": adapter.kind,
            "adapter_fingerprint": adapter.fingerprint,
            "real_system_commands_embedded": False,
        },
        "inputs": {item.label: item.digest for item in inputs},
    }
    fingerprint = canonical_digest(base_document)
    document = dict(base_document)
    document["plan_fingerprint"] = fingerprint
    return RuntimePlan(document, fingerprint, stages, tuple(inputs), adapter)


def modules_text(modules: Sequence[str]) -> str:
    return ",".join(modules) if modules else "none"


def render_plan(plan: RuntimePlan, as_json: bool) -> None:
    if as_json:
        print(json.dumps(plan.document, ensure_ascii=False, sort_keys=True, indent=2))
        return
    document = plan.document
    selection = document["selection"]
    print("One-click stage/effect plan (schema 2)")
    print(f"Plan fingerprint: {plan.fingerprint}")
    print(
        f"Profile: {document['profile']} (mode={document['mode']}, config-scope={document['config_scope']})"
    )
    print(f"Selection source: {selection['source']}")
    print(f"Requested modules: {modules_text(selection['requested_modules'])}")
    print(f"Resolved modules: {modules_text(selection['resolved_modules'])}")
    print(
        f"Production apply integration: {str(document['safety']['production_apply_integration']).lower()}"
    )
    print(f"Execution adapter: {document['safety']['execution_adapter']}")
    if document["safety"]["adapter_fingerprint"]:
        print(f"Adapter fingerprint: {document['safety']['adapter_fingerprint']}")
    print("Stage rows:")
    for index, stage in enumerate(document["stages"], 1):
        dependencies = (
            ",".join(stage["dependencies"]) if stage["dependencies"] else "none"
        )
        modules = modules_text(stage["modules"])
        status = "planned" if stage["applicable"] else "not-applicable"
        print(
            f"  {index:02d}. {stage['id']} status={status} trust={stage['trust_domain']} "
            f"criticality={stage['criticality']} depends={dependencies} confirmation={stage['confirmation']} "
            f"modules={modules} effects={len(stage['effects'])}"
        )
        for effect in stage["effects"]:
            payload = (
                f" sha256={effect['payload_sha256']}"
                if "payload_sha256" in effect
                else ""
            )
            print(
                f"      effect: {effect['id']} module={effect['module']}{payload} :: {effect['detail']}"
            )
    acceptance = document["acceptance"]
    print(
        "Pending acceptance: "
        + (
            ",".join(acceptance["pending_actions"])
            if acceptance["pending_actions"]
            else "none"
        )
    )
    confirmations = document["required_confirmations"]
    print(
        f"Required confirmations: {','.join(confirmations) if confirmations else 'none'}"
    )
    blockers = document["apply_blockers"]
    blocked = modules_text(blockers["non_executable_modules"])
    adapters = ",".join(blockers["missing_adapter_stages"]) or "none"
    integration = ",".join(blockers["non_integrated_stages"]) or "none"
    noncanonical = str(blockers["noncanonical_adapter"]).lower()
    print(
        f"Apply blockers: non-executable-modules={blocked}; missing-adapter-stages={adapters}; "
        f"non-integrated-stages={integration}; noncanonical-adapter={noncanonical}"
    )


def inspect_private_fd(fd: int, path: Path, expected_mode: int, label: str) -> None:
    info = os.fstat(fd)
    if not stat.S_ISREG(info.st_mode):
        raise OrchestratorError(f"{label} is not a regular file: {path}")
    if info.st_nlink != 1:
        raise OrchestratorError(f"{label} must have exactly one hard link: {path}")
    if info.st_uid != os.geteuid():
        raise OrchestratorError(f"{label} is not owned by the current user: {path}")
    mode = stat.S_IMODE(info.st_mode)
    if mode != expected_mode:
        raise OrchestratorError(
            f"{label} must have mode {expected_mode:03o}, found {mode:03o}: {path}"
        )


def inspect_private_file(path: Path, expected_mode: int, label: str) -> None:
    fd, _ = open_regular_nofollow(path, label)
    try:
        inspect_private_fd(fd, path, expected_mode, label)
    finally:
        os.close(fd)


def inspect_private_directory(path: Path, label: str) -> None:
    try:
        info = path.lstat()
    except OSError as error:
        raise OrchestratorError(f"could not inspect {label} {path}: {error}") from error
    if not stat.S_ISDIR(info.st_mode) or stat.S_ISLNK(info.st_mode):
        raise OrchestratorError(f"{label} is not a real directory: {path}")
    if info.st_uid != os.geteuid():
        raise OrchestratorError(f"{label} is not owned by the current user: {path}")
    mode = stat.S_IMODE(info.st_mode)
    if mode != 0o700:
        raise OrchestratorError(f"{label} must have mode 700, found {mode:03o}: {path}")


def ensure_private_directory(path: Path) -> None:
    if path.exists() or path.is_symlink():
        inspect_private_directory(path, "private directory")
        return
    parent = path.parent
    if parent != path and not parent.exists():
        ensure_private_directory(parent)
    try:
        path.mkdir(mode=0o700)
    except FileExistsError:
        pass
    except OSError as error:
        raise OrchestratorError(
            f"could not create private directory {path}: {error}"
        ) from error
    os.chmod(path, 0o700)
    inspect_private_directory(path, "private directory")


def atomic_write_json(path: Path, document: dict[str, Any], mode: int) -> None:
    parent = path.parent
    ensure_private_directory(parent)
    if path.exists() or path.is_symlink():
        inspect_private_file(path, mode, "atomic JSON target")
    payload = (
        json.dumps(document, ensure_ascii=False, sort_keys=True, indent=2).encode(
            "utf-8"
        )
        + b"\n"
    )
    fd: int | None = None
    temporary: str | None = None
    try:
        fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=parent)
        os.fchmod(fd, mode)
        offset = 0
        while offset < len(payload):
            offset += os.write(fd, payload[offset:])
        os.fsync(fd)
        os.close(fd)
        fd = None
        os.replace(temporary, path)
        temporary = None
        directory_fd = os.open(parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    except OSError as error:
        raise OrchestratorError(
            f"could not atomically write {path}: {error}"
        ) from error
    finally:
        if fd is not None:
            os.close(fd)
        if temporary is not None:
            try:
                os.unlink(temporary)
            except FileNotFoundError:
                pass


def read_private_json(path: Path, label: str) -> dict[str, Any]:
    inspect_private_file(path, 0o600, label)
    data = read_regular_bytes(path, label)
    try:
        value = json.loads(data)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise OrchestratorError(f"{label} is malformed JSON: {error}") from error
    if not isinstance(value, dict):
        raise OrchestratorError(f"{label} must contain a JSON object")
    return value


def create_private_log(path: Path, fingerprint: str, run_id: str) -> None:
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        fd = os.open(path, flags, 0o600)
        os.fchmod(fd, 0o600)
        header = (
            canonical_json(
                {
                    "event": "log-created",
                    "plan_fingerprint": fingerprint,
                    "run_id": run_id,
                    "timestamp": utc_timestamp(),
                }
            )
            + b"\n"
        )
        os.write(fd, header)
        os.fsync(fd)
        os.close(fd)
    except OSError as error:
        raise OrchestratorError(
            f"could not create private run log {path}: {error}"
        ) from error


def append_log(path: Path, fingerprint: str, event: str, **fields: Any) -> None:
    flags = os.O_WRONLY | os.O_APPEND
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        fd = os.open(path, flags)
        inspect_private_fd(fd, path, 0o600, "run log")
        record = {
            "event": event,
            "plan_fingerprint": fingerprint,
            "timestamp": utc_timestamp(),
            **fields,
        }
        payload = canonical_json(record) + b"\n"
        os.write(fd, payload)
        os.fsync(fd)
        os.close(fd)
    except OSError as error:
        raise OrchestratorError(
            f"could not append private run log {path}: {error}"
        ) from error


def initial_stage_state(stage: PlannedStage) -> dict[str, Any]:
    return {
        "id": stage.definition.stage_id,
        "status": "pending" if stage.applicable else "not-applicable",
        "attempts": 0,
        "last_exit": 0,
        "modules": list(stage.modules),
        "effect_count": len(stage.effects),
        "effect_fingerprint": stage.effect_fingerprint,
    }


def validate_acceptance(value: Any) -> None:
    expected = {
        "pending_actions",
        "manual_actions",
        "deferred_actions",
        "conditional_actions",
        "relogin_or_reboot_reasons",
    }
    if not isinstance(value, dict) or set(value) != expected:
        raise OrchestratorError("run state has malformed acceptance fields")
    category_ids: set[str] = set()
    for key in (
        "pending_actions",
        "manual_actions",
        "deferred_actions",
        "conditional_actions",
    ):
        rows = value[key]
        if (
            not isinstance(rows, list)
            or not all(
                isinstance(item, str) and TOKEN_RE.fullmatch(item) for item in rows
            )
            or len(rows) != len(set(rows))
        ):
            raise OrchestratorError(f"run state has invalid {key}")
        if key != "pending_actions":
            category_ids.update(rows)
    reasons = value["relogin_or_reboot_reasons"]
    reason_ids: set[str] = set()
    if not isinstance(reasons, list):
        raise OrchestratorError("run state has invalid relogin/reboot reasons")
    for row in reasons:
        if (
            not isinstance(row, dict)
            or set(row) != {"action", "reason"}
            or not isinstance(row["action"], str)
            or TOKEN_RE.fullmatch(row["action"]) is None
            or row["action"] in reason_ids
            or not isinstance(row["reason"], str)
            or not row["reason"]
            or has_control(row["reason"])
        ):
            raise OrchestratorError("run state has a malformed relogin/reboot reason")
        reason_ids.add(row["action"])
    category_ids.update(reason_ids)
    if set(value["pending_actions"]) != category_ids:
        raise OrchestratorError(
            "run state pending acceptance does not cover every acceptance category"
        )


def validate_state_shape(state: dict[str, Any]) -> None:
    expected = {
        "schema",
        "run_id",
        "plan_fingerprint",
        "profile",
        "mode",
        "requested_modules",
        "resolved_modules",
        "config_scope",
        "status",
        "attempt",
        "created_at",
        "updated_at",
        "failure_exit",
        "failed_stage",
        "retry",
        "interruptions",
        "acceptance",
        "stages",
    }
    if set(state) != expected:
        raise OrchestratorError("run state has malformed top-level fields")
    if state["schema"] != 3:
        raise OrchestratorError("run state has unsupported schema")
    if (
        not isinstance(state["run_id"], str)
        or RUN_ID_RE.fullmatch(state["run_id"]) is None
    ):
        raise OrchestratorError("run state has an invalid run id")
    if (
        not isinstance(state["plan_fingerprint"], str)
        or SHA256_RE.fullmatch(state["plan_fingerprint"]) is None
    ):
        raise OrchestratorError("run state has an invalid plan fingerprint")
    if (
        not isinstance(state["profile"], str)
        or TOKEN_RE.fullmatch(state["profile"]) is None
    ):
        raise OrchestratorError("run state has an invalid profile")
    if state["mode"] not in {"new", "reconcile"}:
        raise OrchestratorError("run state has an invalid deployment mode")
    for key in ("requested_modules", "resolved_modules"):
        if not isinstance(state[key], list) or not all(
            isinstance(item, str) and TOKEN_RE.fullmatch(item) for item in state[key]
        ):
            raise OrchestratorError(f"run state has an invalid {key}")
        if len(set(state[key])) != len(state[key]):
            raise OrchestratorError(f"run state repeats an entry in {key}")
    if state["config_scope"] != "none" and (
        not isinstance(state["config_scope"], str)
        or TOKEN_RE.fullmatch(state["config_scope"]) is None
    ):
        raise OrchestratorError("run state has an invalid config scope")
    if state["status"] not in RUN_STATUSES:
        raise OrchestratorError("run state has an invalid status")
    if (
        not isinstance(state["attempt"], int)
        or isinstance(state["attempt"], bool)
        or state["attempt"] < 1
    ):
        raise OrchestratorError("run state has an invalid attempt")
    if (
        not isinstance(state["interruptions"], int)
        or isinstance(state["interruptions"], bool)
        or state["interruptions"] < 0
    ):
        raise OrchestratorError("run state has an invalid interruption count")
    if (
        not isinstance(state["failure_exit"], int)
        or isinstance(state["failure_exit"], bool)
        or not 0 <= state["failure_exit"] <= 255
    ):
        raise OrchestratorError("run state has an invalid failure exit")
    if state["failed_stage"] is not None and not isinstance(state["failed_stage"], str):
        raise OrchestratorError("run state has an invalid failed stage")
    if state["retry"] is not None and not isinstance(state["retry"], str):
        raise OrchestratorError("run state has an invalid retry description")
    for key in ("created_at", "updated_at"):
        if not isinstance(state[key], str) or not re.fullmatch(
            r"[0-9]{8}T[0-9]{6}Z", state[key]
        ):
            raise OrchestratorError(f"run state has an invalid {key}")
    validate_acceptance(state["acceptance"])
    if not isinstance(state["stages"], list) or not state["stages"]:
        raise OrchestratorError("run state has no dynamic stage rows")
    stage_expected = {
        "id",
        "status",
        "attempts",
        "last_exit",
        "modules",
        "effect_count",
        "effect_fingerprint",
    }
    seen: set[str] = set()
    running = 0
    failed = 0
    for row in state["stages"]:
        if not isinstance(row, dict) or set(row) != stage_expected:
            raise OrchestratorError("run state has a malformed stage row")
        if (
            not isinstance(row["id"], str)
            or TOKEN_RE.fullmatch(row["id"]) is None
            or row["id"] in seen
        ):
            raise OrchestratorError("run state has an invalid or duplicate stage id")
        seen.add(row["id"])
        if row["status"] not in STAGE_STATUSES:
            raise OrchestratorError(
                f"run state has invalid status for stage {row['id']}"
            )
        running += row["status"] == "running"
        failed += row["status"] == "failed"
        if (
            not isinstance(row["attempts"], int)
            or isinstance(row["attempts"], bool)
            or row["attempts"] < 0
        ):
            raise OrchestratorError(
                f"run state has invalid attempts for stage {row['id']}"
            )
        if (
            not isinstance(row["last_exit"], int)
            or isinstance(row["last_exit"], bool)
            or not 0 <= row["last_exit"] <= 255
        ):
            raise OrchestratorError(
                f"run state has invalid last exit for stage {row['id']}"
            )
        if row["status"] == "failed" and row["last_exit"] == 0:
            raise OrchestratorError(f"failed stage {row['id']} has no failure exit")
        if not isinstance(row["modules"], list) or not all(
            isinstance(item, str) and TOKEN_RE.fullmatch(item)
            for item in row["modules"]
        ):
            raise OrchestratorError(
                f"run state has invalid modules for stage {row['id']}"
            )
        if len(set(row["modules"])) != len(row["modules"]):
            raise OrchestratorError(f"run state repeats modules for stage {row['id']}")
        if (
            not isinstance(row["effect_count"], int)
            or isinstance(row["effect_count"], bool)
            or row["effect_count"] < 0
        ):
            raise OrchestratorError(
                f"run state has invalid effect count for stage {row['id']}"
            )
        if (
            not isinstance(row["effect_fingerprint"], str)
            or SHA256_RE.fullmatch(row["effect_fingerprint"]) is None
        ):
            raise OrchestratorError(
                f"run state has invalid effect fingerprint for stage {row['id']}"
            )
    if running > 1:
        raise OrchestratorError("run state has more than one running stage")
    if state["status"] == "completed" and any(
        row["status"] not in {"passed", "not-applicable"} for row in state["stages"]
    ):
        raise OrchestratorError("completed run state has unfinished or failed stages")
    if state["status"] == "failed" and failed == 0:
        raise OrchestratorError("failed run state has no failed stage rows")
    if state["status"] == "failed" and state["failure_exit"] == 0:
        raise OrchestratorError("failed run state has no preserved failure exit")


def validate_state_against_plan(state: dict[str, Any], plan: RuntimePlan) -> None:
    if state["profile"] != plan.document["profile"]:
        raise OrchestratorError(
            "run state profile does not match the fingerprint-bound plan"
        )
    if state["mode"] != plan.document["mode"]:
        raise OrchestratorError(
            "run state deployment mode does not match the fingerprint-bound plan"
        )
    if state["requested_modules"] != plan.document["selection"]["requested_modules"]:
        raise OrchestratorError(
            "run state requested modules do not match the fingerprint-bound plan"
        )
    if state["resolved_modules"] != plan.document["selection"]["resolved_modules"]:
        raise OrchestratorError(
            "run state resolved modules do not match the fingerprint-bound plan"
        )
    if state["config_scope"] != plan.document["config_scope"]:
        raise OrchestratorError(
            "run state config scope does not match the fingerprint-bound plan"
        )
    if state["acceptance"] != plan.document["acceptance"]:
        raise OrchestratorError(
            "run state acceptance contract does not match the fingerprint-bound plan"
        )
    if len(state["stages"]) != len(plan.stages):
        raise OrchestratorError("run state stage row count does not match the plan")
    for row, stage in zip(state["stages"], plan.stages, strict=True):
        expected_status = "not-applicable" if not stage.applicable else None
        if row["id"] != stage.definition.stage_id:
            raise OrchestratorError("run state stage order/id does not match the plan")
        if row["modules"] != list(stage.modules):
            raise OrchestratorError(f"run state modules do not match stage {row['id']}")
        if (
            row["effect_count"] != len(stage.effects)
            or row["effect_fingerprint"] != stage.effect_fingerprint
        ):
            raise OrchestratorError(f"run state effects do not match stage {row['id']}")
        if expected_status and row["status"] != expected_status:
            raise OrchestratorError(
                f"non-applicable stage {row['id']} has an executable status"
            )
        if stage.applicable and row["status"] == "not-applicable":
            raise OrchestratorError(
                f"applicable stage {row['id']} is marked not-applicable"
            )


def stage_rows(state: dict[str, Any]) -> dict[str, dict[str, Any]]:
    return {row["id"]: row for row in state["stages"]}


def descendants(plan: RuntimePlan, stage_id: str) -> set[str]:
    result: set[str] = set()
    changed = True
    while changed:
        changed = False
        for stage in plan.stages:
            if (
                stage.definition.stage_id in result
                or stage.definition.stage_id == stage_id
            ):
                continue
            if any(
                dependency == stage_id or dependency in result
                for dependency in stage.definition.dependencies
            ):
                result.add(stage.definition.stage_id)
                changed = True
    return result


def determine_action(
    store: StateStore, plan: RuntimePlan, args: argparse.Namespace
) -> RunAction:
    prior = store.read_latest(plan)
    retry_requested = args.retry_stage is not None or args.retry_module is not None
    if prior is None:
        if retry_requested:
            raise OrchestratorError("no prior run exists for retry")
        if args.resume:
            raise OrchestratorError("no prior run exists for --resume")
        if args.rerun:
            raise OrchestratorError("no prior run exists for --rerun")
        return RunAction("new")
    prior_fingerprint = prior.state["plan_fingerprint"]
    if retry_requested or args.resume or args.rerun:
        if prior_fingerprint != plan.fingerprint:
            raise OrchestratorError(
                "latest run plan fingerprint does not match the exact current plan"
            )
    if args.rerun:
        return RunAction("rerun", prior)
    if args.resume:
        if prior.state["status"] != "running":
            raise OrchestratorError(
                "--resume requires a fingerprint-matching interrupted/running run"
            )
        return RunAction("resume", prior)
    if retry_requested:
        if prior.state["status"] not in {"failed", "running"}:
            raise OrchestratorError("retry requires a failed or interrupted run")
        rows = stage_rows(prior.state)
        if args.retry_stage is not None:
            if args.retry_stage not in rows:
                raise OrchestratorError(
                    f"retry stage is not in the current plan: {args.retry_stage}"
                )
            if rows[args.retry_stage]["status"] not in {"failed", "running"}:
                raise OrchestratorError(
                    f"retry stage {args.retry_stage} is not failed or interrupted (status={rows[args.retry_stage]['status']})"
                )
            return RunAction("retry", prior, args.retry_stage)
        assert args.retry_module is not None
        if args.retry_module not in plan.document["selection"]["resolved_modules"]:
            raise OrchestratorError(
                f"retry module is not selected by the current plan: {args.retry_module}"
            )
        candidates = [
            stage.definition.stage_id
            for stage in plan.stages
            if args.retry_module in rows[stage.definition.stage_id]["modules"]
            and rows[stage.definition.stage_id]["status"] in {"failed", "running"}
        ]
        if not candidates:
            raise OrchestratorError(
                f"retry module {args.retry_module} has no failed/interrupted stage effect"
            )
        return RunAction("retry", prior, candidates[0])
    if prior_fingerprint == plan.fingerprint:
        if prior.state["status"] == "completed":
            raise OrchestratorError(
                "the latest matching plan is completed; use --rerun for an intentional rerun"
            )
        if prior.state["status"] == "running":
            raise OrchestratorError(
                "the latest matching plan is interrupted/incomplete; use --resume, retry, or --rerun"
            )
        raise OrchestratorError(
            "the latest matching plan failed; use --retry-stage, --retry-module, or --rerun"
        )
    return RunAction("new")


def prepare_existing_run(
    store: StateStore, plan: RuntimePlan, action: RunAction
) -> PriorRun:
    assert action.prior is not None
    # Re-read under the lock; never rely on the unlocked pre-confirmation snapshot.
    current = store.read_latest(plan)
    if current is None or current.state["run_id"] != action.prior.state["run_id"]:
        raise OrchestratorError(
            "latest run changed while confirmations were being collected"
        )
    state = current.state
    state["attempt"] += 1
    state["status"] = "running"
    state["failure_exit"] = 0
    state["failed_stage"] = None
    if action.kind == "retry":
        assert action.retry_stage is not None
        rows = stage_rows(state)
        target = rows[action.retry_stage]
        target["status"] = "pending"
        target["last_exit"] = 0
        for stage_id in descendants(plan, action.retry_stage):
            row = rows[stage_id]
            if row["status"] == "skipped-dependency":
                row["status"] = "pending"
                row["last_exit"] = 0
        state["retry"] = f"stage:{action.retry_stage}"
    elif action.kind == "resume":
        rows = stage_rows(state)
        running = [row for row in state["stages"] if row["status"] == "running"]
        if running:
            target_id = running[0]["id"]
            running[0]["status"] = "pending"
            running[0]["last_exit"] = 0
            for stage_id in descendants(plan, target_id):
                row = rows[stage_id]
                if row["status"] == "skipped-dependency":
                    row["status"] = "pending"
                    row["last_exit"] = 0
            state["retry"] = f"resume-stage:{target_id}"
        else:
            state["retry"] = "resume-finalize-or-pending"
        state["interruptions"] += 1
    else:
        raise OrchestratorError(
            f"internal error: cannot prepare existing action {action.kind}"
        )
    store.write_state(current)
    append_log(
        current.log_path,
        plan.fingerprint,
        "run-resumed",
        action=action.kind,
        attempt=state["attempt"],
        retry=state["retry"],
    )
    return current


def verify_plan_inputs(plan: RuntimePlan) -> None:
    for item in plan.input_files:
        actual = plan_input_digest(item)
        if actual != item.digest:
            raise OrchestratorError(
                f"fingerprint-bound plan input changed before execution: {item.label}"
            )


def required_confirmations(plan: RuntimePlan) -> tuple[str, ...]:
    return tuple(plan.document["required_confirmations"])


def collect_confirmations(plan: RuntimePlan, args: argparse.Namespace) -> None:
    required = required_confirmations(plan)
    supplied = {
        "system": args.confirm_system_changes,
        "archlinuxcn": args.confirm_archlinuxcn,
        "aur": args.confirm_aur,
    }
    for domain, was_supplied in supplied.items():
        if was_supplied and domain not in required:
            raise OrchestratorError(
                f"{CONFIRMATION_FLAGS[domain]} was supplied but no {domain} stage is applicable"
            )
    missing = [domain for domain in required if not supplied[domain]]
    if not missing:
        return
    if not args.interactive and not sys.stdin.isatty():
        flags = " ".join(CONFIRMATION_FLAGS[domain] for domain in missing)
        raise OrchestratorError(
            f"non-interactive apply requires independent confirmation flags: {flags}"
        )
    for domain in missing:
        token = CONFIRMATION_TOKENS[domain]
        response = prompt_line(
            f"Type {token} to authorize applicable {domain} stages: "
        )
        if response != token:
            raise Cancelled(f"{domain} stage authorization cancelled")


def ensure_apply_ready(plan: RuntimePlan, production_readiness: dict[str, str]) -> None:
    blockers = plan.document["apply_blockers"]
    if plan.adapter.kind == "none":
        raise OrchestratorError(
            "production apply integration is false; the canonical reviewed executable manifest is unavailable"
        )
    if plan.adapter.kind != "test-only":
        if plan.adapter.kind != "canonical-reviewed-executable-manifest":
            raise OrchestratorError(
                "production apply rejects a noncanonical reviewed executable manifest"
            )
        non_integrated = blockers["non_integrated_stages"]
        if non_integrated:
            raise OrchestratorError(
                "applicable stages are not production-integrated: "
                + ",".join(non_integrated)
            )
    missing = blockers["missing_adapter_stages"]
    if missing:
        raise OrchestratorError(
            f"execution adapter is missing applicable stage handlers: {','.join(missing)}"
        )
    blocked = blockers["non_executable_modules"]
    if blocked:
        descriptions = ", ".join(
            f"{module}({production_readiness[module]})" for module in blocked
        )
        raise OrchestratorError(
            "selected modules are not production-ready and block adapter apply: "
            + descriptions
        )


REVIEWED_ENVIRONMENT_DENYLIST = frozenset(
    {
        "ARCHLINUXCN_APPLY_TESTING",
        "ARCHLINUXCN_APPLY_TEST_ROOT",
        "ARCHLINUXCN_TEST_GSUDO_SHA256",
        "ARCHLINUXCN_TEST_ASKPASS_SHA256",
        "SYSTEM_ACTION_APPLY_TESTING",
        "SYSTEM_ACTION_APPLY_TEST_ROOT",
        "SYSTEM_ACTION_TEST_COMMAND_DIR",
        "SYSTEM_ACTION_TEST_GSUDO_SHA256",
        "SYSTEM_ACTION_TEST_ASKPASS_SHA256",
        "FULL_ORCHESTRATOR_TESTING",
        "PYTHONPATH",
        "PYTHONHOME",
        "PYTHONSTARTUP",
        "PYTHONINSPECT",
        "BASH_ENV",
        "ENV",
        "CDPATH",
        "LD_PRELOAD",
        "LD_LIBRARY_PATH",
        "DBUS_SYSTEM_BUS_ADDRESS",
        "SYSTEMD_OFFLINE",
        "SYSTEMD_UNIT_PATH",
        "LIBVIRT_DEFAULT_URI",
        "VIRSH_DEFAULT_CONNECT_URI",
        "GNUPGHOME",
    }
)


def adapter_environment(
    plan: RuntimePlan,
    stage: PlannedStage,
    action: str,
    run_id: str,
    attempt: int,
) -> dict[str, str]:
    environment = os.environ.copy()
    if plan.adapter.kind != "test-only":
        for name in REVIEWED_ENVIRONMENT_DENYLIST:
            environment.pop(name, None)
        # Production adapters resolve all package/system tools from the
        # distribution-owned directory; caller-controlled mock/bin prefixes are
        # never evidence for a reviewed run.
        environment["PATH"] = "/usr/bin"
        environment["FULL_ORCHESTRATOR_ADAPTER_KIND"] = plan.adapter.kind
    environment.update(
        {
            "FULL_ORCHESTRATOR_ACTION": action,
            "FULL_ORCHESTRATOR_STAGE": stage.definition.stage_id,
            "FULL_ORCHESTRATOR_PROFILE": plan.document["profile"],
            "FULL_ORCHESTRATOR_MODE": plan.document["mode"],
            "FULL_ORCHESTRATOR_MODULES": modules_text(
                plan.document["selection"]["resolved_modules"]
            ),
            "FULL_ORCHESTRATOR_STAGE_MODULES": modules_text(stage.modules),
            "FULL_ORCHESTRATOR_EFFECTS_JSON": json.dumps(
                [effect.document() for effect in stage.effects],
                ensure_ascii=False,
                sort_keys=True,
                separators=(",", ":"),
            ),
            "FULL_ORCHESTRATOR_PLAN_FINGERPRINT": plan.fingerprint,
            "FULL_ORCHESTRATOR_RUN_ID": run_id,
            "FULL_ORCHESTRATOR_ATTEMPT": str(attempt),
        }
    )
    return environment


def invoke_preflight(plan: RuntimePlan, stage: PlannedStage) -> int:
    spec = plan.adapter.commands[stage.definition.stage_id]["preflight"]
    actual = hash_executable(spec.executable)
    if actual != spec.executable_digest:
        raise OrchestratorError(
            f"adapter executable changed after plan fingerprinting: {spec.executable}"
        )
    verify_plan_inputs(plan)
    environment = adapter_environment(
        plan,
        stage,
        "preflight",
        f"preflight-{plan.fingerprint[:12]}",
        1,
    )
    try:
        completed = subprocess.run(
            spec.argv,
            stdin=subprocess.DEVNULL,
            env=environment,
            check=False,
            start_new_session=True,
        )
    except OSError as error:
        status = 127 if isinstance(error, FileNotFoundError) else 2
        raise OrchestratorError(
            f"could not execute preflight adapter for stage {stage.definition.stage_id}: {error}",
            status,
        ) from error
    return 0 if completed.returncode == 0 else normalize_exit(completed.returncode)


def run_all_preflights(plan: RuntimePlan) -> int:
    print("Read-only stage preflight:")
    first_failure = 0
    for stage in plan.stages:
        if not stage.applicable:
            continue
        stage_id = stage.definition.stage_id
        print(f"stage {stage_id}: preflight running")
        status = invoke_preflight(plan, stage)
        if status == 0:
            print(f"stage {stage_id}: preflight passed")
            continue
        print(f"stage {stage_id}: preflight failed exit={status}")
        if first_failure == 0:
            first_failure = status
    if first_failure != 0:
        print(
            "Read-only stage preflight failed; no confirmation, run state, or execute action occurred."
        )
    return first_failure


def invoke_adapter(
    plan: RuntimePlan,
    prior: PriorRun,
    stage: PlannedStage,
    action: str,
) -> int:
    spec = plan.adapter.commands[stage.definition.stage_id][action]
    actual = hash_executable(spec.executable)
    if actual != spec.executable_digest:
        raise OrchestratorError(
            f"adapter executable changed after plan fingerprinting: {spec.executable}"
        )
    verify_plan_inputs(plan)
    environment = adapter_environment(
        plan,
        stage,
        action,
        prior.state["run_id"],
        prior.state["attempt"],
    )
    append_log(
        prior.log_path,
        plan.fingerprint,
        "adapter-start",
        stage=stage.definition.stage_id,
        action=action,
    )
    flags = os.O_WRONLY | os.O_APPEND
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        log_fd = os.open(prior.log_path, flags)
        inspect_private_fd(log_fd, prior.log_path, 0o600, "run log")
        completed = subprocess.run(
            spec.argv,
            stdin=subprocess.DEVNULL,
            stdout=log_fd,
            stderr=subprocess.STDOUT,
            env=environment,
            check=False,
            start_new_session=True,
        )
        os.fsync(log_fd)
        os.close(log_fd)
    except OSError as error:
        raise OrchestratorError(
            f"could not execute {action} adapter for stage {stage.definition.stage_id}: {error}"
        ) from error
    status = 0 if completed.returncode == 0 else normalize_exit(completed.returncode)
    append_log(
        prior.log_path,
        plan.fingerprint,
        "adapter-finish",
        stage=stage.definition.stage_id,
        action=action,
        exit=status,
    )
    return status


def write_transition(
    store: StateStore,
    prior: PriorRun,
    plan: RuntimePlan,
    event: str,
    **fields: Any,
) -> None:
    store.write_state(prior)
    append_log(prior.log_path, plan.fingerprint, event, **fields)


def stop_after_passed_stage(
    store: StateStore,
    prior: PriorRun,
    plan: RuntimePlan,
    stage_id: str,
) -> int:
    prior.state["interruptions"] += 1
    write_transition(store, prior, plan, "graceful-stop-after-stage", stage=stage_id)
    print(
        f"graceful stop after passed stage {stage_id}; run remains resumable",
        file=sys.stderr,
    )
    show_final_report(prior.state)
    return 75


def stop_at_failed_boundary(
    store: StateStore,
    prior: PriorRun,
    plan: RuntimePlan,
    stage_id: str,
) -> int:
    failed = [row for row in prior.state["stages"] if row["status"] == "failed"]
    if not failed:
        raise OrchestratorError(
            f"failed stop boundary {stage_id} has no preserved failed stage"
        )
    ordered = failed[0]
    prior.state["status"] = "failed"
    prior.state["failed_stage"] = ordered["id"]
    prior.state["failure_exit"] = ordered["last_exit"]
    write_transition(
        store,
        prior,
        plan,
        "run-failed-stop-boundary",
        stop_stage=stage_id,
        failed_stage=ordered["id"],
        exit=ordered["last_exit"],
        failed_stages=[row["id"] for row in failed],
    )
    print(
        f"failed stop boundary {stage_id}; preserved {ordered['id']} exit={ordered['last_exit']} "
        "without executing later stages",
        file=sys.stderr,
    )
    show_final_report(prior.state)
    return ordered["last_exit"]


def execute_run(
    store: StateStore,
    prior: PriorRun,
    plan: RuntimePlan,
    args: argparse.Namespace,
) -> int:
    rows = stage_rows(prior.state)
    first_failure: tuple[str, int] | None = None
    for stage in plan.stages:
        stage_id = stage.definition.stage_id
        row = rows[stage_id]
        if row["status"] == "not-applicable":
            print(f"stage {stage_id}: not-applicable")
            continue
        blocked_by = [
            dependency
            for dependency in stage.definition.dependencies
            if rows[dependency]["status"] in {"failed", "skipped-dependency"}
        ]
        if blocked_by:
            if row["status"] != "failed":
                row["status"] = "skipped-dependency"
                row["last_exit"] = 0
                write_transition(
                    store,
                    prior,
                    plan,
                    "stage-skipped-dependency",
                    stage=stage_id,
                    blocked_by=blocked_by,
                )
            print(f"stage {stage_id}: skipped-dependency ({','.join(blocked_by)})")
            if args.stop_after_stage == stage_id:
                return stop_at_failed_boundary(store, prior, plan, stage_id)
            continue
        if row["status"] == "skipped-dependency":
            row["status"] = "pending"
            row["last_exit"] = 0
            write_transition(store, prior, plan, "stage-unblocked", stage=stage_id)
        if row["status"] == "failed":
            if first_failure is None:
                first_failure = (stage_id, row["last_exit"])
            print(f"stage {stage_id}: failed (retained exit={row['last_exit']})")
            if args.stop_after_stage == stage_id:
                return stop_at_failed_boundary(store, prior, plan, stage_id)
            continue
        if row["status"] == "passed":
            print(f"stage {stage_id}: verifying prior pass")
            verification = invoke_adapter(plan, prior, stage, "verify")
            if verification == 0:
                append_log(
                    prior.log_path,
                    plan.fingerprint,
                    "stage-verified-skip",
                    stage=stage_id,
                )
                print(f"stage {stage_id}: verified; skipped")
                if args.stop_after_stage == stage_id:
                    return stop_after_passed_stage(store, prior, plan, stage_id)
                continue
            print(
                f"stage {stage_id}: verifier failed with exit {verification}; rerunning"
            )
            row["status"] = "pending"
            row["last_exit"] = verification
            write_transition(
                store,
                prior,
                plan,
                "stage-verifier-rerun",
                stage=stage_id,
                exit=verification,
            )
        if row["status"] not in {"pending", "running"}:
            raise OrchestratorError(
                f"internal error: unexpected stage status {stage_id}={row['status']}"
            )
        row["status"] = "running"
        row["attempts"] += 1
        row["last_exit"] = 0
        write_transition(
            store,
            prior,
            plan,
            "stage-running",
            stage=stage_id,
            stage_attempt=row["attempts"],
            run_attempt=prior.state["attempt"],
        )
        print(f"stage {stage_id}: running")
        if args.test_interrupt_stage == stage_id:
            prior.state["interruptions"] += 1
            write_transition(
                store, prior, plan, "test-interruption-running-stage", stage=stage_id
            )
            print(
                f"stage {stage_id}: test interruption left status=running",
                file=sys.stderr,
            )
            return 75
        execute_status = invoke_adapter(plan, prior, stage, "execute")
        if execute_status != 0:
            row["status"] = "failed"
            row["last_exit"] = execute_status
            write_transition(
                store,
                prior,
                plan,
                "stage-failed",
                stage=stage_id,
                action="execute",
                exit=execute_status,
            )
            print(f"stage {stage_id}: failed exit={execute_status}")
            if first_failure is None:
                first_failure = (stage_id, execute_status)
            if args.stop_after_stage == stage_id:
                return stop_at_failed_boundary(store, prior, plan, stage_id)
            continue
        verify_status = invoke_adapter(plan, prior, stage, "verify")
        if verify_status != 0:
            row["status"] = "failed"
            row["last_exit"] = verify_status
            write_transition(
                store,
                prior,
                plan,
                "stage-failed",
                stage=stage_id,
                action="verify",
                exit=verify_status,
            )
            print(f"stage {stage_id}: verifier failed exit={verify_status}")
            if first_failure is None:
                first_failure = (stage_id, verify_status)
            if args.stop_after_stage == stage_id:
                return stop_at_failed_boundary(store, prior, plan, stage_id)
            continue
        row["status"] = "passed"
        row["last_exit"] = 0
        write_transition(store, prior, plan, "stage-passed", stage=stage_id)
        print(f"stage {stage_id}: passed")
        if args.stop_after_stage == stage_id:
            return stop_after_passed_stage(store, prior, plan, stage_id)
    if args.test_interrupt_before_finalize:
        prior.state["interruptions"] += 1
        write_transition(store, prior, plan, "test-interruption-before-finalize")
        print(
            "test interruption before finalization; run remains recoverable",
            file=sys.stderr,
        )
        show_final_report(prior.state)
        return 75
    failures = [row for row in prior.state["stages"] if row["status"] == "failed"]
    unfinished = [
        row for row in prior.state["stages"] if row["status"] in {"pending", "running"}
    ]
    if unfinished:
        raise OrchestratorError(
            "scheduler reached finalization with unfinished stages: "
            + ",".join(row["id"] for row in unfinished)
        )
    if failures:
        ordered_failure = next(
            row for row in prior.state["stages"] if row["status"] == "failed"
        )
        prior.state["status"] = "failed"
        prior.state["failed_stage"] = ordered_failure["id"]
        prior.state["failure_exit"] = ordered_failure["last_exit"]
        write_transition(
            store,
            prior,
            plan,
            "run-failed",
            failed_stage=ordered_failure["id"],
            exit=ordered_failure["last_exit"],
            failed_stages=[row["id"] for row in failures],
        )
        show_final_report(prior.state)
        return ordered_failure["last_exit"]
    prior.state["status"] = "completed"
    prior.state["failed_stage"] = None
    prior.state["failure_exit"] = 0
    write_transition(
        store, prior, plan, "run-completed", attempt=prior.state["attempt"]
    )
    show_final_report(prior.state)
    return 0


def show_final_report(state: dict[str, Any]) -> None:
    print("Final stage report:")
    for row in state["stages"]:
        suffix = f" exit={row['last_exit']}" if row["status"] == "failed" else ""
        print(f"  {row['id']}: {row['status']}{suffix}")
    acceptance = state["acceptance"]
    pending = acceptance["pending_actions"]
    if state["status"] == "completed":
        result = (
            "automatic-stages-completed-with-pending-acceptance"
            if pending
            else "automatic-stages-completed"
        )
    else:
        result = state["status"]
    print(f"  result: {result}")
    print(f"  stage-state: {state['status']}")
    print(f"  pending-acceptance: {','.join(pending) if pending else 'none'}")
    print(
        "  manual-actions: "
        + (
            ",".join(acceptance["manual_actions"])
            if acceptance["manual_actions"]
            else "none"
        )
    )
    print(
        "  deferred-actions: "
        + (
            ",".join(acceptance["deferred_actions"])
            if acceptance["deferred_actions"]
            else "none"
        )
    )
    print(
        "  conditional-actions: "
        + (
            ",".join(acceptance["conditional_actions"])
            if acceptance["conditional_actions"]
            else "none"
        )
    )
    reasons = acceptance["relogin_or_reboot_reasons"]
    print(
        "  relogin-or-reboot: "
        + (",".join(row["action"] for row in reasons) if reasons else "none")
    )
    print(f"  run-id: {state['run_id']}")
    print(f"  failure-exit: {state['failure_exit']}")


def validate_cli(args: argparse.Namespace) -> None:
    if args.json and not args.plan:
        raise OrchestratorError("--json is supported only with --plan")
    if args.interactive and args.json:
        raise OrchestratorError("--interactive and --json cannot be combined")
    if args.modules is not None and args.use_saved_selection:
        raise OrchestratorError(
            "--modules and --use-saved-selection are mutually exclusive"
        )
    if args.replace_saved_selection:
        args.save_selection = True
    if (
        args.save_selection
        and args.use_saved_selection
        and args.replace_saved_selection
    ):
        raise OrchestratorError(
            "reusing and replacing the same saved selection is ambiguous"
        )
    apply_only = any(
        (
            args.confirm_system_changes,
            args.confirm_archlinuxcn,
            args.confirm_aur,
            args.retry_stage is not None,
            args.retry_module is not None,
            args.resume,
            args.rerun,
            args.stop_after_stage is not None,
            args.test_interrupt_stage is not None,
            args.test_interrupt_before_finalize,
        )
    )
    if apply_only and not args.apply:
        raise OrchestratorError("confirmation/recovery/rerun options require --apply")
    recovery_count = sum(
        (
            args.retry_stage is not None,
            args.retry_module is not None,
            args.resume,
            args.rerun,
        )
    )
    if recovery_count > 1:
        raise OrchestratorError(
            "select only one of --retry-stage, --retry-module, --resume, or --rerun"
        )
    if args.retry_stage is not None:
        validate_token(args.retry_stage, "retry stage")
    if args.retry_module is not None:
        validate_token(args.retry_module, "retry module")
    if args.stop_after_stage is not None:
        validate_token(args.stop_after_stage, "graceful stop stage")
    if args.test_interrupt_stage is not None or args.test_interrupt_before_finalize:
        if (
            os.environ.get("FULL_ORCHESTRATOR_TESTING") != "1"
            or args.test_execution_map is None
        ):
            raise OrchestratorError(
                "test interruption controls require FULL_ORCHESTRATOR_TESTING=1 and --test-execution-map"
            )


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(
        description="Render or drive the adapter-only schema-2 one-click DAG/state engine."
    )
    result.add_argument(
        "--profile", required=True, help="profile from manifests/profile-modules.tsv"
    )
    result.add_argument(
        "--modules", help="exact comma-separated selectable modules, or 'none'"
    )
    result.add_argument(
        "--mode",
        choices=("new", "reconcile"),
        default="new",
        help="configuration deployment mode (fingerprint-bound; default: new)",
    )
    result.add_argument(
        "--interactive",
        action="store_true",
        help="force interactive selection/confirmation input (useful when stdin is not a TTY)",
    )
    result.add_argument(
        "--use-saved-selection",
        action="store_true",
        help="explicitly reuse the private credential-free saved selection",
    )
    result.add_argument(
        "--save-selection",
        action="store_true",
        help="save the explicitly selected modules",
    )
    result.add_argument(
        "--replace-saved-selection",
        action="store_true",
        help="explicitly replace a different saved selection (implies --save-selection)",
    )
    action = result.add_mutually_exclusive_group(required=True)
    action.add_argument(
        "--plan",
        action="store_true",
        help="render the exact read-only stage/effect plan",
    )
    action.add_argument(
        "--apply", action="store_true", help="run only caller-supplied command adapters"
    )
    result.add_argument(
        "--json", action="store_true", help="render the plan as structured JSON"
    )
    result.add_argument("--confirm-system-changes", action="store_true")
    result.add_argument("--confirm-archlinuxcn", action="store_true")
    result.add_argument("--confirm-aur", action="store_true")
    recovery = result.add_mutually_exclusive_group()
    recovery.add_argument("--retry-stage")
    recovery.add_argument("--retry-module")
    recovery.add_argument("--resume", action="store_true")
    recovery.add_argument("--rerun", action="store_true")
    result.add_argument(
        "--stop-after-stage",
        help="gracefully exit 75 after the named stage passes; the run remains resumable",
    )
    adapters = result.add_mutually_exclusive_group()
    adapters.add_argument("--test-execution-map", type=Path, help=argparse.SUPPRESS)
    adapters.add_argument(
        "--executable-manifest",
        type=Path,
        help="hash-pinned '# reviewed=true' schema-1 stage executable manifest",
    )
    result.add_argument("--test-interrupt-stage", help=argparse.SUPPRESS)
    result.add_argument(
        "--test-interrupt-before-finalize", action="store_true", help=argparse.SUPPRESS
    )
    return result


def select_modules(
    args: argparse.Namespace,
    root: Path,
    profile: Profile,
    modules: dict[str, Module],
    module_source: Snapshot,
    profile_source: Snapshot,
) -> Selection:
    manifest_fingerprint = selection_manifest_fingerprint(module_source, profile_source)
    if args.modules is not None:
        requested = parse_modules_argument(args.modules, modules, profile)
        selection = resolve_selection(requested, "explicit--modules", modules, profile)
    elif args.use_saved_selection:
        requested = load_saved_selection(
            root, profile, modules, manifest_fingerprint, required=True
        )
        assert requested is not None
        selection = resolve_selection(
            requested, "explicit-saved-selection", modules, profile
        )
    elif args.interactive or sys.stdin.isatty():
        selection = interactive_selection(root, profile, modules, manifest_fingerprint)
    elif args.apply:
        raise OrchestratorError(
            "non-interactive apply requires exact --modules or explicit --use-saved-selection; saved/default selections are never inferred"
        )
    else:
        selection = resolve_selection(
            profile.defaults, "profile-defaults", modules, profile
        )
    if args.save_selection:
        save_selection(
            root,
            profile,
            selection.requested,
            manifest_fingerprint,
            replace=args.replace_saved_selection,
        )
    return selection


def run(argv: Sequence[str] | None = None) -> int:
    args = parser().parse_args(argv)
    validate_cli(args)
    modules, module_source = load_modules()
    production_readiness, production_readiness_source = load_production_readiness(
        modules
    )
    profiles, profile_source = load_profiles(modules)
    if args.profile not in profiles:
        raise OrchestratorError(
            f"profile is not present in current manifests: {args.profile}"
        )
    profile = profiles[args.profile]
    store = StateStore(state_root())
    selection = select_modules(
        args, store.root, profile, modules, module_source, profile_source
    )
    definitions, stage_source = load_stages()
    policy, workstation_source = load_policy(modules)
    config, config_source = load_config(modules)
    system_actions, system_action_source, system_conflict_source = load_system_actions(
        modules,
        set(profiles),
    )
    planned_stages, payload_inputs = derive_stages(
        definitions,
        selection,
        profile,
        policy,
        config,
        system_actions,
    )
    if args.test_execution_map is not None:
        adapter = load_test_adapter(args.test_execution_map.resolve(), definitions)
    elif args.executable_manifest is not None:
        adapter = load_reviewed_adapter(args.executable_manifest.resolve(), definitions)
    elif (
        CANONICAL_EXECUTABLE_MANIFEST.exists()
        or CANONICAL_EXECUTABLE_MANIFEST.is_symlink()
    ):
        adapter = load_reviewed_adapter(CANONICAL_EXECUTABLE_MANIFEST, definitions)
    else:
        adapter = no_adapter()
    stage_inputs = load_stage_inputs(
        definitions,
        planned_stages,
        required=adapter.kind == "canonical-reviewed-executable-manifest",
    )
    plan = build_plan(
        profile,
        args.mode,
        selection,
        module_source,
        production_readiness_source,
        production_readiness,
        profile_source,
        stage_source,
        workstation_source,
        config_source,
        system_action_source,
        system_conflict_source,
        planned_stages,
        payload_inputs,
        stage_inputs,
        adapter,
        modules,
        system_actions,
    )
    render_plan(plan, args.json)
    if args.plan:
        return 0
    ensure_apply_ready(plan, production_readiness)
    if args.stop_after_stage is not None and args.stop_after_stage not in {
        stage.definition.stage_id for stage in plan.stages if stage.applicable
    }:
        raise OrchestratorError(
            f"graceful stop stage is not applicable: {args.stop_after_stage}"
        )
    # Inspect before prompting, then repeat under the lock after all independent
    # confirmations.  The first pass writes nothing and catches stale/malformed
    # state without asking for authorization.
    action = determine_action(store, plan, args)
    preflight_status = run_all_preflights(plan)
    if preflight_status != 0:
        return preflight_status
    collect_confirmations(plan, args)
    verify_plan_inputs(plan)
    store.acquire()
    try:
        locked_action = determine_action(store, plan, args)
        if (locked_action.kind, locked_action.retry_stage) != (
            action.kind,
            action.retry_stage,
        ):
            raise OrchestratorError(
                "run context changed while confirmations were being collected"
            )
        if locked_action.kind in {"new", "rerun"}:
            prior = store.create_run(plan, selection, profile)
        else:
            prior = prepare_existing_run(store, plan, locked_action)
        return execute_run(store, prior, plan, args)
    finally:
        store.release()


def main() -> None:
    try:
        status = run()
    except Cancelled as error:
        print(f"full-orchestrator: cancelled: {error}", file=sys.stderr)
        raise SystemExit(error.status) from error
    except OrchestratorError as error:
        print(f"full-orchestrator: error: {error}", file=sys.stderr)
        raise SystemExit(error.status) from error
    except KeyboardInterrupt as error:
        print("full-orchestrator: interrupted", file=sys.stderr)
        raise SystemExit(130) from error
    raise SystemExit(status)


if __name__ == "__main__":
    main()
