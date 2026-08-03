#!/usr/bin/env python3
"""Execute or verify the policy-derived official pacman stages.

This is a stage adapter for ``full-orchestrator.py``.  It has no package-name
CLI: the exact effects arrive through fingerprint-bound FULL_ORCHESTRATOR_*
environment variables and must reproduce the reviewed workstation policy.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import os
import platform
import re
import shutil
import stat
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any, NoReturn, Sequence

PROJECT_ROOT = Path(__file__).resolve().parent.parent
POLICY_PATH = PROJECT_ROOT / "manifests/workstation-packages.tsv"
SYSTEM_ROOT = Path("/")
MINIMUM_FREE_BYTES = 5 * 1024 * 1024 * 1024
AUDITED_GSUDO_SHA256 = "7a63f2b74c6ab2d005dd84d03851148b129dbd530c753453f1c1f680414253b7"
AUDITED_ASKPASS_SHA256 = "4396717f5a63e25ebff7d64aeb49b2b1fb26956da0f22e1aed7a34ad768edb8a"
AUDITED_GSUDO_PAYLOAD = PROJECT_ROOT / "config/home/scripts/desktop/gsudo"
AUDITED_ASKPASS_PAYLOAD = PROJECT_ROOT / "config/home/scripts/desktop/fuzzel-askpass"
PENDING_GSUDO_SHA256 = "7a63f2b74c6ab2d005dd84d03851148b129dbd530c753453f1c1f680414253b7"
PENDING_ASKPASS_SHA256 = "4396717f5a63e25ebff7d64aeb49b2b1fb26956da0f22e1aed7a34ad768edb8a"
ARCHLINUXCN_PLANNER = PROJECT_ROOT / "installer/archlinuxcn-plan.py"
ARCHLINUXCN_PLANNER_SHA256 = "bbdeb4054c45c00e2e6d597f6d06f12a80c3aee69d7af808b879aec2d7ac082c"
OFFICIAL_REPOSITORIES = frozenset({"core", "extra", "multilib"})
KNOWN_PROFILES = frozenset({"asus-amd-nvidia", "desktop-amd", "vm"})
PACKAGE_RE = re.compile(r"[a-z0-9@._+:-]+")
TOKEN_RE = re.compile(r"[a-z0-9][a-z0-9-]*")
HEX64_RE = re.compile(r"[0-9a-f]{64}")
RUN_ID_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:-]*")


class AdapterError(Exception):
    """A classified adapter failure with a process-compatible status."""

    def __init__(self, message: str, status: int = 2) -> None:
        super().__init__(message)
        self.status = normalize_status(status)


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

    def effect(self) -> dict[str, str]:
        return {
            "detail": (
                f"package={self.package} channel={self.channel} "
                f"repository={self.repository} acquisition={self.acquisition}"
            ),
            "id": f"install:{self.package}",
            "module": self.module,
        }


@dataclass(frozen=True)
class RuntimeContext:
    action: str
    stage: str
    profile: str
    modules: tuple[str, ...]
    stage_modules: tuple[str, ...]
    effects: tuple[dict[str, str], ...]
    fingerprint: str
    run_id: str
    attempt: int
    packages: tuple[PolicyRow, ...]
    archlinuxcn_selected: bool


@dataclass(frozen=True)
class QueryResult:
    argv: tuple[str, ...]
    status: int
    stdout: str
    stderr: str


def normalize_status(status: int) -> int:
    if status < 0:
        return min(255, 128 + abs(status))
    if status == 0:
        return 0
    return min(255, status)


def error(message: str, status: int = 2) -> NoReturn:
    raise AdapterError(message, status)


def safe_regular_file(path: Path, label: str, *, executable: bool = False, missing_status: int = 2) -> os.stat_result:
    try:
        info = path.lstat()
    except FileNotFoundError:
        error(f"{label} is missing: {path}", missing_status)
    except OSError as exc:
        error(f"could not inspect {label} {path}: {exc}")
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
        error(f"{label} is not a safe regular file: {path}")
    if info.st_nlink != 1:
        error(f"{label} has an unsafe hard-link count: {path}")
    if info.st_uid != os.geteuid():
        error(f"{label} is not owned by the invoking user: {path}")
    if info.st_mode & 0o022:
        error(f"{label} is group/world writable: {path}")
    if executable and not info.st_mode & 0o111:
        error(f"{label} is not executable: {path}", missing_status)
    return info


def read_policy() -> tuple[PolicyRow, ...]:
    safe_regular_file(POLICY_PATH, "workstation package policy")
    try:
        lines = POLICY_PATH.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError) as exc:
        error(f"could not read workstation package policy: {exc}")
    if not lines or lines[0] != "# schema=1":
        error("workstation package policy has an unsupported schema")
    rows: list[PolicyRow] = []
    packages: set[str] = set()
    for line_number, parts in enumerate(csv.reader(lines[1:], delimiter="\t"), 2):
        if not parts or not parts[0] or parts[0].startswith("#"):
            continue
        if len(parts) != 9 or not all(parts):
            error(f"workstation package policy has an invalid row at line {line_number}")
        row = PolicyRow(*parts)
        if PACKAGE_RE.fullmatch(row.package) is None:
            error(f"workstation package policy has an unsafe package at line {line_number}")
        if TOKEN_RE.fullmatch(row.module) is None:
            error(f"workstation package policy has an unsafe module at line {line_number}")
        if row.package in packages:
            error(f"workstation package policy repeats package {row.package}")
        if any(ord(character) < 32 for field in parts for character in field):
            error(f"workstation package policy has a control character at line {line_number}")
        packages.add(row.package)
        rows.append(row)
    if not rows:
        error("workstation package policy has no rows")
    return tuple(rows)


def parse_modules(raw: str, label: str) -> tuple[str, ...]:
    if raw == "none":
        return ()
    values = tuple(raw.split(","))
    if not values or any(TOKEN_RE.fullmatch(value) is None for value in values):
        error(f"{label} is malformed")
    if len(values) != len(set(values)):
        error(f"{label} contains a duplicate module")
    return values


def load_effects(raw: str) -> tuple[dict[str, str], ...]:
    try:
        document: Any = json.loads(raw)
    except json.JSONDecodeError as exc:
        error(f"FULL_ORCHESTRATOR_EFFECTS_JSON is malformed: {exc}")
    if not isinstance(document, list):
        error("FULL_ORCHESTRATOR_EFFECTS_JSON is not an array")
    effects: list[dict[str, str]] = []
    for index, item in enumerate(document):
        if not isinstance(item, dict) or set(item) != {"detail", "id", "module"}:
            error(f"orchestrator effect {index} has malformed fields")
        if not all(isinstance(item[key], str) and item[key] for key in item):
            error(f"orchestrator effect {index} has an empty/non-string field")
        if any(any(ord(character) < 32 for character in value) for value in item.values()):
            error(f"orchestrator effect {index} contains a control character")
        effects.append({key: item[key] for key in ("detail", "id", "module")})
    return tuple(effects)


def require_env(name: str) -> str:
    value = os.environ.get(name)
    if value is None or value == "":
        error(f"required orchestrator environment is missing: {name}")
    if "\x00" in value:
        error(f"orchestrator environment contains NUL: {name}")
    return value


def policy_has_install_effect(row: PolicyRow) -> bool:
    if row.policy != "install":
        return False
    if row.channel == "aur" and row.repository == "aur" and row.acquisition in {"aur-build", "paru-bootstrap"}:
        return True
    if row.channel == "pacman" and row.repository == "archlinuxcn" and row.acquisition in {
        "pacman",
        "archlinuxcn-bootstrap",
    }:
        return True
    return row.channel == "pacman" and row.repository in OFFICIAL_REPOSITORIES and row.acquisition == "pacman"


def is_official_install(row: PolicyRow) -> bool:
    return (
        row.policy == "install"
        and row.channel == "pacman"
        and row.repository in OFFICIAL_REPOSITORIES
        and row.acquisition == "pacman"
    )


def load_context() -> RuntimeContext:
    action = require_env("FULL_ORCHESTRATOR_ACTION")
    stage = require_env("FULL_ORCHESTRATOR_STAGE")
    profile = require_env("FULL_ORCHESTRATOR_PROFILE")
    modules = parse_modules(require_env("FULL_ORCHESTRATOR_MODULES"), "FULL_ORCHESTRATOR_MODULES")
    stage_modules = parse_modules(
        require_env("FULL_ORCHESTRATOR_STAGE_MODULES"), "FULL_ORCHESTRATOR_STAGE_MODULES"
    )
    effects = load_effects(require_env("FULL_ORCHESTRATOR_EFFECTS_JSON"))
    fingerprint = require_env("FULL_ORCHESTRATOR_PLAN_FINGERPRINT")
    run_id = require_env("FULL_ORCHESTRATOR_RUN_ID")
    attempt_raw = require_env("FULL_ORCHESTRATOR_ATTEMPT")

    if action not in {"preflight", "execute", "verify"}:
        error(f"unsupported orchestrator action: {action}")
    if stage not in {"official-update", "official-packages"}:
        error(f"official package adapter cannot handle stage: {stage}")
    if profile not in KNOWN_PROFILES:
        error(f"unknown orchestrator profile: {profile}")
    if not modules or not stage_modules:
        error("an applicable official stage cannot have an empty module selection")
    if not set(stage_modules).issubset(modules):
        error("official stage modules are not a subset of the resolved selection")
    if HEX64_RE.fullmatch(fingerprint) is None:
        error("orchestrator plan fingerprint is malformed")
    if RUN_ID_RE.fullmatch(run_id) is None:
        error("orchestrator run id is malformed")
    if not attempt_raw.isdigit() or int(attempt_raw) < 1:
        error("orchestrator attempt is malformed")

    policy = read_policy()
    install_modules = {row.module for row in policy if policy_has_install_effect(row)}
    official_modules = {row.module for row in policy if is_official_install(row)}
    archlinuxcn_selected = any(
        row.policy == "install"
        and row.channel == "pacman"
        and row.repository == "archlinuxcn"
        and row.acquisition in {"pacman", "archlinuxcn-bootstrap"}
        and row.module in set(modules)
        for row in policy
    )
    expected_update_modules = tuple(module for module in modules if module in install_modules)
    expected_official_modules = tuple(module for module in modules if module in official_modules)

    if stage == "official-update":
        if stage_modules != expected_update_modules:
            error("official-update stage modules do not reproduce the selected package policy")
        expected_effects = (
            {
                "detail": "rolling full-system refresh boundary",
                "id": "full-system-refresh",
                "module": "-",
            },
        )
        packages: tuple[PolicyRow, ...] = ()
    else:
        if stage_modules != expected_official_modules:
            error("official-packages stage modules do not reproduce the selected official policy")
        packages = tuple(
            sorted(
                (row for row in policy if is_official_install(row) and row.module in set(stage_modules)),
                key=lambda row: row.package,
            )
        )
        if not packages:
            error("official-packages stage has no policy-derived package")
        expected_effects = tuple(row.effect() for row in packages)

    if effects != expected_effects:
        error("orchestrator effects do not exactly reproduce the reviewed official package policy")

    return RuntimeContext(
        action,
        stage,
        profile,
        modules,
        stage_modules,
        effects,
        fingerprint,
        run_id,
        int(attempt_raw),
        packages,
        archlinuxcn_selected,
    )


def system_path(relative: str) -> Path:
    return SYSTEM_ROOT / relative.lstrip("/")


def require_supported_runtime(*, privileged: bool, allow_pending_wrapper: bool = False) -> Path | None:
    if os.geteuid() == 0:
        error("run the official package adapter as the invoking ordinary user, not root")
    architecture = platform.machine()
    if architecture != "x86_64":
        error(f"unsupported architecture: {architecture} (x86_64 is required)")
    arch_release = system_path("etc/arch-release")
    try:
        release_info = arch_release.lstat()
    except FileNotFoundError:
        error(f"unsupported distribution: {arch_release} is missing")
    except OSError as exc:
        error(f"could not inspect Arch release marker {arch_release}: {exc}")
    if stat.S_ISLNK(release_info.st_mode) or not stat.S_ISREG(release_info.st_mode):
        error(f"Arch release marker is unsafe: {arch_release}")
    if shutil.which("pacman") is None:
        error("pacman was not found; this is not a supported Arch system", 127)
    if not privileged:
        return None

    home_raw = os.environ.get("HOME", "")
    if not home_raw or not os.path.isabs(home_raw):
        error("HOME must be an absolute path")
    gsudo = Path(home_raw) / "scripts/desktop/gsudo"
    helper = gsudo.with_name("fuzzel-askpass")
    gsudo_present = gsudo.exists() or gsudo.is_symlink()
    helper_present = helper.exists() or helper.is_symlink()
    if allow_pending_wrapper and not gsudo_present and not helper_present:
        safe_regular_file(AUDITED_GSUDO_PAYLOAD, "reviewed gsudo payload", executable=True)
        safe_regular_file(AUDITED_ASKPASS_PAYLOAD, "reviewed askpass payload", executable=True)
        try:
            gsudo_digest = hashlib.sha256(AUDITED_GSUDO_PAYLOAD.read_bytes()).hexdigest()
            helper_digest = hashlib.sha256(AUDITED_ASKPASS_PAYLOAD.read_bytes()).hexdigest()
        except OSError as exc:
            error(f"could not hash pending privilege wrapper payloads: {exc}")
        expected_gsudo = PENDING_GSUDO_SHA256
        expected_helper = PENDING_ASKPASS_SHA256
    else:
        if allow_pending_wrapper and gsudo_present != helper_present:
            error("privilege wrapper prerequisite is partially present instead of absent or complete")
        safe_regular_file(gsudo, "audited gsudo wrapper", executable=True, missing_status=127)
        safe_regular_file(helper, "audited fuzzel askpass helper", executable=True, missing_status=127)
        try:
            gsudo_digest = hashlib.sha256(gsudo.read_bytes()).hexdigest()
            helper_digest = hashlib.sha256(helper.read_bytes()).hexdigest()
        except OSError as exc:
            error(f"could not hash the audited privilege wrapper files: {exc}")
        expected_gsudo = AUDITED_GSUDO_SHA256
        expected_helper = AUDITED_ASKPASS_SHA256
    if gsudo_digest != expected_gsudo:
        error("installed gsudo wrapper differs from the reviewed project payload")
    if helper_digest != expected_helper:
        error("installed fuzzel askpass helper differs from the reviewed project payload")
    return gsudo


def environment() -> dict[str, str]:
    result = os.environ.copy()
    result["LC_ALL"] = "C"
    return result


def run_query(argv: Sequence[str]) -> QueryResult:
    try:
        completed = subprocess.run(
            list(argv),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=environment(),
            check=False,
        )
    except OSError as exc:
        status = 127 if isinstance(exc, FileNotFoundError) else 2
        error(f"could not execute read-only query {argv[0]}: {exc}", status)
    return QueryResult(tuple(argv), normalize_status(completed.returncode), completed.stdout, completed.stderr)


def run_effect(argv: Sequence[str], label: str) -> int:
    try:
        completed = subprocess.run(
            list(argv),
            stdin=subprocess.DEVNULL,
            env=environment(),
            check=False,
        )
    except OSError as exc:
        status = 127 if isinstance(exc, FileNotFoundError) else 2
        print(f"official-package-apply: {label} could not start: {exc}", file=sys.stderr)
        return status
    status = normalize_status(completed.returncode)
    if status != 0:
        print(f"official-package-apply: {label} failed with exit {status}", file=sys.stderr)
    return status


def pacman_conf_argv(*arguments: str) -> tuple[str, ...]:
    argv = ["pacman-conf"]
    if SYSTEM_ROOT != Path("/"):
        argv.extend(("--rootdir", str(SYSTEM_ROOT)))
    argv.extend(arguments)
    return tuple(argv)


def validate_archlinuxcn_existing_trust() -> int:
    try:
        planner_info = safe_regular_file(ARCHLINUXCN_PLANNER, "archlinuxcn trust planner", executable=True)
        del planner_info
        digest = hashlib.sha256(ARCHLINUXCN_PLANNER.read_bytes()).hexdigest()
    except OSError as exc:
        print(f"official-package-apply: could not hash archlinuxcn trust planner: {exc}", file=sys.stderr)
        return 2
    if digest != ARCHLINUXCN_PLANNER_SHA256:
        print("official-package-apply: archlinuxcn trust planner differs from the reviewed adapter pin", file=sys.stderr)
        return 2
    argv = [sys.executable, str(ARCHLINUXCN_PLANNER), "--json"]
    if SYSTEM_ROOT != Path("/"):
        argv.extend(("--root", str(SYSTEM_ROOT)))
    query = run_query(tuple(argv))
    if query.status != 0:
        print(
            f"official-package-apply: archlinuxcn trust inventory failed with exit {query.status}",
            file=sys.stderr,
        )
        return query.status
    try:
        report = json.loads(query.stdout)
        overall = report["overall"]["status"]
        repository = report["current"]["repository"]["state"]
        keyring = report["current"]["keyring"]["state"]
    except (json.JSONDecodeError, KeyError, TypeError):
        print("official-package-apply: archlinuxcn trust inventory returned malformed JSON", file=sys.stderr)
        return 2
    if overall != "ready" or repository != "matching" or keyring != "matching":
        print(
            "official-package-apply: existing archlinuxcn repository/keyring is not the exact reviewed state",
            file=sys.stderr,
        )
        return 1
    return 0


def repository_trust_preflight(context: RuntimeContext) -> int:
    if shutil.which("pacman-conf") is None:
        print("official-package-apply: pacman-conf is required to inventory active repositories", file=sys.stderr)
        return 127
    query = run_query(pacman_conf_argv("--repo-list"))
    if query.status != 0:
        print(
            f"official-package-apply: active repository query failed with exit {query.status}",
            file=sys.stderr,
        )
        return query.status
    raw_repositories = tuple(line.strip() for line in query.stdout.splitlines() if line.strip())
    if not raw_repositories:
        print("official-package-apply: active repository query succeeded empty", file=sys.stderr)
        return 2
    if len(raw_repositories) != len(set(raw_repositories)) or any(
        TOKEN_RE.fullmatch(repository) is None for repository in raw_repositories
    ):
        print("official-package-apply: active repository query returned malformed/duplicate names", file=sys.stderr)
        return 2
    repositories = set(raw_repositories)
    required_official = {"core", "extra"}
    if not required_official.issubset(repositories):
        print("official-package-apply: required core/extra repositories are not both active", file=sys.stderr)
        return 1
    unknown = repositories - OFFICIAL_REPOSITORIES - {"archlinuxcn"}
    if unknown:
        print(
            "official-package-apply: full transaction is blocked by unreviewed active repositories: "
            + ",".join(sorted(unknown)),
            file=sys.stderr,
        )
        return 1
    if "archlinuxcn" not in repositories:
        return 0
    if not context.archlinuxcn_selected:
        print(
            "official-package-apply: archlinuxcn is active but no independently authorized archlinuxcn effect is selected",
            file=sys.stderr,
        )
        return 1
    return validate_archlinuxcn_existing_trust()


def preflight_privileged(context: RuntimeContext, gsudo: Path) -> None:
    del gsudo  # The path was already inspected; keep this routine side-effect free until queries pass.
    trust_status = repository_trust_preflight(context)
    if trust_status != 0:
        error("active repository trust preflight did not pass", trust_status)
    lock = system_path("var/lib/pacman/db.lck")
    try:
        lock_info = lock.lstat()
    except FileNotFoundError:
        pass
    except OSError as exc:
        error(f"pacman lock query failed for {lock}: {exc}")
    else:
        kind = "regular" if stat.S_ISREG(lock_info.st_mode) else "non-regular"
        error(f"pacman lock exists ({kind}): {lock}")

    try:
        free_bytes = shutil.disk_usage(SYSTEM_ROOT).free
    except OSError as exc:
        error(f"root filesystem free-space query failed: {exc}")
    if free_bytes < MINIMUM_FREE_BYTES:
        error("less than the required 5 GiB safety margin is available on the target root")

    if shutil.which("getent") is None:
        error("getent is required for the DNS preflight", 127)
    dns = run_query(("getent", "ahosts", "archlinux.org"))
    if dns.status != 0:
        error(f"DNS resolution query failed with exit {dns.status}", dns.status)
    if not dns.stdout.strip():
        error("DNS resolution query succeeded but returned an empty result")


def repository_metadata(row: PolicyRow) -> int:
    query = run_query(("pacman", "-Si", "--", row.package))
    if query.status != 0:
        print(
            f"official-package-apply: repository query failed for {row.package} with exit {query.status}",
            file=sys.stderr,
        )
        return query.status
    if not query.stdout.strip():
        print(
            f"official-package-apply: repository query succeeded empty for {row.package}",
            file=sys.stderr,
        )
        return 2
    repository: str | None = None
    name: str | None = None
    for line in query.stdout.splitlines():
        match = re.fullmatch(r"Repository\s*:\s*(\S+)\s*", line)
        if match:
            repository = match.group(1)
            continue
        match = re.fullmatch(r"Name\s*:\s*(\S+)\s*", line)
        if match:
            name = match.group(1)
    if repository is None or name is None:
        print(
            f"official-package-apply: repository query output was unparseable for {row.package}",
            file=sys.stderr,
        )
        return 2
    if name != row.package or repository != row.repository:
        print(
            "official-package-apply: repository ownership mismatch for "
            f"{row.package} (expected {row.repository}, observed {repository})",
            file=sys.stderr,
        )
        return 1
    return 0


def verify_installed(packages: tuple[PolicyRow, ...]) -> int:
    names = tuple(row.package for row in packages)
    query = run_query(("pacman", "-Q", "--", *names))
    if query.status != 0:
        print(
            f"official-package-apply: installed-package query failed with exit {query.status}",
            file=sys.stderr,
        )
        return query.status
    if not query.stdout.strip():
        print("official-package-apply: installed-package query succeeded empty", file=sys.stderr)
        return 2
    observed: list[str] = []
    for line in query.stdout.splitlines():
        if not line.strip():
            continue
        parts = line.split()
        if len(parts) != 2 or PACKAGE_RE.fullmatch(parts[0]) is None:
            print("official-package-apply: installed-package query output was unparseable", file=sys.stderr)
            return 2
        observed.append(parts[0])
    if tuple(observed) != names:
        print("official-package-apply: installed-package query did not return the exact package set", file=sys.stderr)
        return 1
    for row in packages:
        status = repository_metadata(row)
        if status != 0:
            return status
    return 0


def verify_update() -> int:
    query = run_query(("pacman", "-Qu"))
    stdout_empty = not query.stdout.strip()
    stderr_empty = not query.stderr.strip()
    if query.status == 1 and stdout_empty and stderr_empty:
        print("official-package-apply: full-system refresh verification is current")
        return 0
    if query.status == 0 and not stdout_empty:
        print("official-package-apply: full-system refresh verification found pending updates", file=sys.stderr)
        return 1
    if query.status == 0 and stdout_empty:
        print("official-package-apply: pacman -Qu exited 0 with an ambiguous empty result", file=sys.stderr)
        return 2
    print(
        f"official-package-apply: pacman -Qu query failed with exit {query.status}",
        file=sys.stderr,
    )
    return query.status


def preflight(context: RuntimeContext, gsudo: Path) -> int:
    preflight_privileged(context, gsudo)
    if context.stage == "official-packages":
        for row in context.packages:
            status = repository_metadata(row)
            if status != 0:
                return status
    print(f"official-package-apply: {context.stage} read-only preflight passed")
    return 0


def execute_update(context: RuntimeContext, gsudo: Path) -> int:
    preflight_privileged(context, gsudo)
    print("official-package-apply: executing reviewed full-system refresh through audited gsudo")
    return run_effect((str(gsudo), "--", "pacman", "-Syu", "--noconfirm"), "full-system refresh")


def execute_packages(context: RuntimeContext, gsudo: Path, packages: tuple[PolicyRow, ...]) -> int:
    preflight_privileged(context, gsudo)
    for row in packages:
        status = repository_metadata(row)
        if status != 0:
            return status
    names = tuple(row.package for row in packages)
    print(f"official-package-apply: installing {len(names)} exact reviewed official package(s) with --needed")
    return run_effect(
        (str(gsudo), "--", "pacman", "-S", "--needed", "--noconfirm", "--", *names),
        "official package transaction",
    )


def parser() -> argparse.ArgumentParser:
    return argparse.ArgumentParser(
        description="Execute/verify fingerprint-bound official package stages for full-orchestrator."
    )


def main(argv: Sequence[str] | None = None) -> int:
    parser().parse_args(argv)
    try:
        context = load_context()
        gsudo = require_supported_runtime(
            privileged=context.action in {"preflight", "execute"},
            allow_pending_wrapper=context.action == "preflight",
        )
        if context.action == "verify":
            trust_status = repository_trust_preflight(context)
            if trust_status != 0:
                return trust_status
            return verify_update() if context.stage == "official-update" else verify_installed(context.packages)
        assert gsudo is not None
        if context.action == "preflight":
            return preflight(context, gsudo)
        if context.stage == "official-update":
            return execute_update(context, gsudo)
        return execute_packages(context, gsudo, context.packages)
    except AdapterError as exc:
        print(f"official-package-apply: {exc}", file=sys.stderr)
        return exc.status
    except KeyboardInterrupt:
        print("official-package-apply: interrupted", file=sys.stderr)
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
