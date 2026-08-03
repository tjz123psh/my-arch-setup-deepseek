#!/usr/bin/env python3
"""Reviewed production adapter for the schema-2 ``system-actions`` stage.

The ordinary entry point accepts its complete plan only through the
FULL_ORCHESTRATOR_* environment.  It has no public action, unit, package, or
path switches.  The sole command-line interface is a deliberately hidden,
fixed-target root helper; production reaches that helper only through the
reviewed per-user gsudo payload.
"""

from __future__ import annotations

import argparse
import ctypes
import csv
import hashlib
import json
import os
import platform
import pwd
import re
import stat
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable, NoReturn, Sequence

PROJECT_ROOT = Path(__file__).resolve().parent.parent
SCRIPT_PATH = Path(__file__).resolve()
MODULES_PATH = PROJECT_ROOT / "manifests/modules.tsv"
PROFILES_PATH = PROJECT_ROOT / "manifests/profile-modules.tsv"
ACTIONS_PATH = PROJECT_ROOT / "manifests/system-actions.tsv"
CONFLICTS_PATH = PROJECT_ROOT / "manifests/system-action-conflicts.tsv"
PACKAGES_PATH = PROJECT_ROOT / "manifests/workstation-packages.tsv"
REPOSITORY_GSUDO = PROJECT_ROOT / "config/home/scripts/desktop/gsudo"
REPOSITORY_ASKPASS = PROJECT_ROOT / "config/home/scripts/desktop/fuzzel-askpass"

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

AUDITED_GSUDO_SHA256 = "7a63f2b74c6ab2d005dd84d03851148b129dbd530c753453f1c1f680414253b7"
AUDITED_ASKPASS_SHA256 = "4396717f5a63e25ebff7d64aeb49b2b1fb26956da0f22e1aed7a34ad768edb8a"

STATE_SUFFIX = Path("my-archlinux-setup/system-actions")
NETWORK_XML = Path("/usr/share/libvirt/networks/default.xml")
LOCALE_GEN = Path("/etc/locale.gen")
LOCALE_CONF = Path("/etc/locale.conf")
ENVIRONMENT_FILE = Path("/etc/environment")
OFFICIAL_REACHABILITY_PACKAGE = "pacman"
PERSONAL_USER_UNITS = (
    "openai-oauth.service",
    "penpot-mcp.service",
    "vellum-tray.service",
    "vellum.service",
)

TOKEN_RE = re.compile(r"[a-z0-9][a-z0-9-]*")
PACKAGE_RE = re.compile(r"[a-z0-9@._+:-]+")
UNIT_RE = re.compile(r"[A-Za-z0-9@_.:-]+")
HEX64_RE = re.compile(r"[0-9a-f]{64}")
RUN_ID_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:-]*")
VERSION_RE = re.compile(r"[^\s\x00-\x1f\x7f]+")
CONTROLLER_RE = re.compile(
    r"Controller [0-9A-F]{2}(?::[0-9A-F]{2}){5} [^\r\n]+(?: \[default\])?"
)

# These are the executable parts of the reviewed manifest.  Descriptive text
# may improve without granting a new command capability, but any action,
# handler, target, dependency, privilege, applicability, or conflict drift is
# rejected until this adapter is reviewed again.
REVIEWED_ACTION_ROWS: tuple[tuple[str, ...], ...] = (
    ("base-network-handoff", "base-preconditions", "all", "verify", "none", "verify-network-handoff", "NetworkManager.service", "always", "-", "-"),
    ("base-package-preconditions", "base-preconditions", "all", "verify", "none", "verify-policy-packages", "workstation:verify-only", "always", "-", "base-network-handoff"),
    ("failed-unit-baseline", "base-preconditions", "all", "verify", "none", "verify-failed-units", "system,user", "always", "-", "base-network-handoff"),
    ("time-sync-service", "base-preconditions", "all", "apply", "root", "enable-system-unit", "systemd-timesyncd.service", "always", "ntp-owner-conflicts", "base-network-handoff"),
    ("audio-package-activation", "audio", "all", "verify", "none", "verify-package-owned-audio", "pipewire.socket,pipewire-pulse.socket,wireplumber.service", "always", "pipewire-owner-conflicts", "base-package-preconditions"),
    ("portal-package-activation", "desktop-shared", "all", "verify", "none", "verify-package-owned-portals", "selected-wm-portal-set", "graphical-session-optional", "portal-override-conflicts", "base-package-preconditions"),
    ("fcitx-session-owner", "input-fcitx-rime", "all", "verify", "none", "verify-session-owner", "fcitx5", "graphical-session-optional", "-", "base-package-preconditions"),
    ("blueman-session-owner", "bluetooth", "asus-amd-nvidia,desktop-amd", "verify", "none", "verify-session-owner", "blueman-applet", "graphical-session-optional", "-", "base-package-preconditions"),
    ("bluetooth-service", "bluetooth", "asus-amd-nvidia,desktop-amd", "apply", "root", "enable-system-unit", "bluetooth.service", "bluetooth-controller-optional", "-", "base-package-preconditions"),
    ("power-profiles-service", "power", "asus-amd-nvidia,desktop-amd", "apply", "root", "enable-system-unit", "power-profiles-daemon.service", "power-profiles-supported", "power-owner-conflicts", "base-package-preconditions"),
    ("dms-niri-session-wants", "wm-niri", "all", "apply", "user", "add-user-wants", "niri.service:dms.service", "niri-selected", "-", "base-package-preconditions"),
    ("dsearch-user-service", "desktop-shared", "all", "apply", "user", "enable-user-unit", "dsearch.service", "dsearch-installed", "-", "base-package-preconditions"),
    ("personal-user-unit-reload", "personal-user-services", "asus-amd-nvidia", "apply", "user", "daemon-reload-user", "mapped-user-units", "files-deployed", "-", "base-package-preconditions"),
    ("docker-service", "container-tools", "asus-amd-nvidia,desktop-amd", "apply", "root", "enable-system-unit", "docker.service", "package-installed", "-", "base-package-preconditions"),
    ("libvirtd-service", "virtualization", "asus-amd-nvidia,desktop-amd", "apply", "root", "enable-system-unit", "libvirtd.service", "package-installed", "libvirt-daemon-model-conflicts", "base-package-preconditions"),
    ("libvirt-default-network", "virtualization", "asus-amd-nvidia,desktop-amd", "apply", "root", "ensure-libvirt-network", "default", "libvirtd-ready", "-", "libvirtd-service"),
    ("locale-zh-cn", "input-fcitx-rime", "asus-amd-nvidia,desktop-amd", "apply", "root", "manage-locale", "en_US.UTF-8,zh_CN.UTF-8", "physical-input-selected", "-", "base-package-preconditions"),
    ("fcitx-system-environment", "input-fcitx-rime", "all", "apply", "root", "manage-environment", "QT_IM_MODULE=fcitx,XMODIFIERS=@im=fcitx", "input-selected", "-", "base-package-preconditions"),
    ("kernel-dkms-verification", "kernel-support", "asus-amd-nvidia,desktop-amd", "verify", "none", "verify-kernel-support", "detected-kernels", "physical-kernel", "-", "base-package-preconditions"),
    ("asusd-package-activation", "asus-hardware", "asus-amd-nvidia", "verify", "none", "verify-package-activation", "asusd.service", "exact-asus-hardware", "-", "base-package-preconditions"),
    ("supergfxd-physical-service", "asus-hardware", "asus-amd-nvidia", "manual", "root", "report-manual", "supergfxd.service", "exact-asus-hardware", "-", "asusd-package-activation"),
    ("snapper-configs", "storage-maintenance", "asus-amd-nvidia,desktop-amd", "manual", "root", "report-manual", "root,home", "btrfs-root-home", "-", "base-package-preconditions"),
    ("snapper-timers", "storage-maintenance", "asus-amd-nvidia,desktop-amd", "manual", "root", "report-manual", "snapper-timeline.timer,snapper-cleanup.timer", "btrfs-root-home", "-", "snapper-configs"),
    ("grub-btrfs-recovery", "storage-maintenance", "asus-amd-nvidia,desktop-amd", "deferred", "root", "report-deferred", "grub-btrfsd.service", "manual-boot-boundary", "-", "snapper-configs"),
    ("docker-group-membership", "container-tools", "asus-amd-nvidia,desktop-amd", "manual", "root", "report-manual", "docker", "root-equivalent-group", "-", "docker-service"),
    ("libvirt-group-membership", "virtualization", "asus-amd-nvidia,desktop-amd", "manual", "root", "report-manual", "libvirt", "privileged-group", "-", "libvirtd-service"),
    ("virtualization-hugepages", "virtualization", "asus-amd-nvidia,desktop-amd", "deferred", "root", "report-deferred", "hugepages", "workload-specific", "-", "libvirtd-service"),
    ("physical-hardware-acceptance", "asus-hardware", "asus-amd-nvidia", "manual", "none", "report-manual", "gpu,display,audio,bluetooth,power,suspend", "exact-asus-hardware", "-", "asusd-package-activation"),
    ("relogin-reboot-report", "base-preconditions", "all", "verify", "none", "report-relogin-reboot", "locale,groups,kernel,dkms", "always", "-", "base-package-preconditions"),
    ("greeter-login-manager", "dms-greetd", "all", "deferred", "root", "report-deferred", "greetd,sddm", "manual-login-boundary", "-", "-"),
)

REVIEWED_CONFLICTS: dict[str, tuple[tuple[str, ...], tuple[str, ...], tuple[str, ...], str]] = {
    "ntp-owner-conflicts": (
        ("networkmanager-dispatcher-ntpd", "ntp", "chrony", "openntpd"),
        ("ntpd.service", "chronyd.service", "openntpd.service"),
        (),
        "block-active-or-installed",
    ),
    "pipewire-owner-conflicts": (
        ("pulseaudio", "pulseaudio-bluetooth", "pipewire-media-session", "jack", "jack2"),
        (),
        ("pulseaudio.service", "pulseaudio.socket", "pipewire-media-session.service"),
        "block-active-or-installed",
    ),
    "power-owner-conflicts": (
        ("tlp", "tuned", "tuned-ppd", "auto-cpufreq", "system76-power"),
        ("tlp.service", "tuned.service", "auto-cpufreq.service", "system76-power.service"),
        (),
        "block-active-or-installed",
    ),
    "libvirt-daemon-model-conflicts": (
        (),
        ("virtqemud.service", "virtqemud.socket", "virtnetworkd.service", "virtnetworkd.socket", "virtstoraged.service", "virtstoraged.socket"),
        (),
        "block-active",
    ),
    "portal-override-conflicts": ((), (), (), "block-managed-paths"),
}

ACTION_PACKAGES: dict[str, tuple[str, ...]] = {
    "audio-package-activation": ("pipewire", "pipewire-pulse", "wireplumber"),
    "portal-package-activation": ("xdg-desktop-portal",),
    "fcitx-session-owner": ("fcitx5",),
    "blueman-session-owner": ("blueman",),
    "bluetooth-service": ("bluez", "bluez-utils"),
    "power-profiles-service": ("power-profiles-daemon",),
    "dms-niri-session-wants": ("niri", "dms-shell"),
    "dsearch-user-service": ("dsearch-bin",),
    "docker-service": ("docker",),
    "libvirtd-service": ("libvirt",),
    "libvirt-default-network": ("libvirt",),
    "fcitx-system-environment": ("fcitx5",),
    "kernel-dkms-verification": ("linux-headers", "linux-zen-headers"),
    "asusd-package-activation": ("asusctl",),
}

SYSTEM_UNIT_ACTIONS = {
    "time-sync-service": "systemd-timesyncd.service",
    "bluetooth-service": "bluetooth.service",
    "power-profiles-service": "power-profiles-daemon.service",
    "docker-service": "docker.service",
    "libvirtd-service": "libvirtd.service",
}


class AdapterFailure(Exception):
    def __init__(self, status: int, message: str):
        super().__init__(message)
        self.status = normalize_status(status)
        self.message = message


@dataclass(frozen=True)
class Module:
    module_id: str
    availability: str
    kind: str
    requires_all: tuple[str, ...]
    requires_any: tuple[str, ...]


@dataclass(frozen=True)
class Profile:
    name: str
    offered: frozenset[str]


@dataclass(frozen=True)
class Action:
    action_id: str
    module: str
    profiles: tuple[str, ...]
    disposition: str
    privilege: str
    handler: str
    target: str
    applicability: str
    conflict_set: str | None
    requires: tuple[str, ...]
    rollback: str
    post_check: str
    purpose: str
    evidence: str


@dataclass(frozen=True)
class Conflict:
    conflict_id: str
    packages: tuple[str, ...]
    system_units: tuple[str, ...]
    user_units: tuple[str, ...]
    behavior: str
    purpose: str


@dataclass(frozen=True)
class PackagePolicy:
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
class Stage:
    action: str
    profile: str
    mode: str
    modules: tuple[str, ...]
    stage_modules: tuple[str, ...]
    effects: tuple[dict[str, str], ...]
    fingerprint: str
    run_id: str
    attempt: int
    actions: tuple[Action, ...]
    verify_packages: tuple[PackagePolicy, ...]
    policies: tuple[PackagePolicy, ...]
    conflicts: dict[str, Conflict]


@dataclass(frozen=True)
class ExecutionContext:
    testing: bool
    target_root: Path
    command_dir: Path | None
    owner_uid: int
    owner_gid: int


@dataclass(frozen=True)
class CommandResult:
    status: int
    stdout: str
    stderr: str


@dataclass(frozen=True)
class FileSnapshot:
    path: Path
    exists: bool
    data: bytes | None
    sha256: str | None
    mode: int | None
    uid: int | None
    gid: int | None
    device: int | None
    inode: int | None

    @property
    def expected_token(self) -> str:
        return "absent" if not self.exists else f"sha256:{self.sha256}"

    def state_document(self, backup: str | None = None) -> dict[str, Any]:
        result: dict[str, Any] = {
            "exists": self.exists,
            "sha256": self.sha256,
            "mode": self.mode,
            "uid": self.uid,
            "gid": self.gid,
        }
        if backup is not None:
            result["backup"] = backup
        return result


@dataclass
class Outcome:
    action_id: str
    classification: str
    success: bool
    status: int = 0
    prior: dict[str, Any] | None = None
    result: dict[str, Any] | None = None
    message: str = ""


class IssueCollector:
    def __init__(self) -> None:
        self.first_status = 0
        self.count = 0

    def add(self, status: int, message: str, **fields: Any) -> None:
        code = normalize_status(status) or 1
        if self.first_status == 0:
            self.first_status = code
        self.count += 1
        emit("check", classification="unavailable" if code != 1 else "blocker", message=message, **fields)


def normalize_status(status: int) -> int:
    if status < 0:
        return min(255, 128 + abs(status))
    if status == 0:
        return 0
    return min(255, status)


def fail(message: str, status: int = 2) -> NoReturn:
    raise AdapterFailure(status, message)


def contains_control(value: str) -> bool:
    return any(ord(character) < 32 or ord(character) == 127 for character in value)


def emit(event: str, **fields: Any) -> None:
    document = {"event": event, **fields}
    print(json.dumps(document, ensure_ascii=True, sort_keys=True, separators=(",", ":")), flush=True)


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
            info = current.lstat()
        except FileNotFoundError:
            return None
        except OSError as error:
            fail(f"could not inspect path component {current}: {error}", 1)
        if stat.S_ISLNK(info.st_mode):
            return current
    return None


def read_regular(
    path: Path,
    label: str,
    *,
    require_owner: int | None = None,
    require_single_link: bool = True,
) -> tuple[bytes, os.stat_result]:
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    try:
        fd = os.open(path, flags)
    except FileNotFoundError as error:
        raise AdapterFailure(1, f"{label} is missing: {path}") from error
    except OSError as error:
        raise AdapterFailure(1, f"could not open {label} {path}: {error}") from error
    try:
        before = os.fstat(fd)
        if not stat.S_ISREG(before.st_mode):
            raise AdapterFailure(1, f"{label} is not a regular file: {path}")
        if require_single_link and before.st_nlink != 1:
            raise AdapterFailure(1, f"{label} must have exactly one hard link: {path}")
        if require_owner is not None and before.st_uid != require_owner:
            raise AdapterFailure(1, f"{label} has an unexpected owner: {path}")
        chunks: list[bytes] = []
        while True:
            chunk = os.read(fd, 1024 * 1024)
            if not chunk:
                break
            chunks.append(chunk)
        after = os.fstat(fd)
    except OSError as error:
        raise AdapterFailure(1, f"could not read {label} {path}: {error}") from error
    finally:
        os.close(fd)
    before_identity = (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns)
    after_identity = (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns)
    if before_identity != after_identity:
        raise AdapterFailure(1, f"{label} changed while being read: {path}")
    return b"".join(chunks), after


def safe_lines(path: Path, schema: str, label: str) -> list[str]:
    data, info = read_regular(path, label, require_owner=os.geteuid())
    if stat.S_IMODE(info.st_mode) & 0o022:
        fail(f"{label} is group/world writable", 1)
    try:
        lines = data.decode("utf-8").splitlines()
    except UnicodeDecodeError as error:
        fail(f"{label} is not UTF-8: {error}")
    if not lines or lines[0] != schema:
        fail(f"{label} has an unsupported schema")
    return lines


def rows(path: Path, schema: str, label: str, fields: int) -> Iterable[tuple[int, tuple[str, ...]]]:
    for line_number, parts in enumerate(csv.reader(safe_lines(path, schema, label)[1:], delimiter="\t"), 2):
        if not parts or not parts[0] or parts[0].startswith("#"):
            continue
        values = tuple(parts)
        if len(values) != fields or any(value == "" for value in values):
            fail(f"{label} has an invalid row at line {line_number}")
        if any(contains_control(value) for value in values):
            fail(f"{label} has a control character at line {line_number}")
        yield line_number, values


def parse_list(raw: str, owner: str, pattern: re.Pattern[str]) -> tuple[str, ...]:
    if raw == "-":
        return ()
    values = tuple(raw.split(","))
    if not values or len(values) != len(set(values)) or any(pattern.fullmatch(value) is None for value in values):
        fail(f"{owner} contains an unsafe or duplicate list")
    return values


def parse_modules_env(raw: str, label: str) -> tuple[str, ...]:
    if raw == "none":
        return ()
    values = tuple(raw.split(","))
    if not values or len(values) != len(set(values)) or any(TOKEN_RE.fullmatch(value) is None for value in values):
        fail(f"{label} is malformed")
    return values


def load_modules() -> tuple[dict[str, Module], tuple[str, ...]]:
    result: dict[str, Module] = {}
    order: list[str] = []
    for line_number, values in rows(MODULES_PATH, "# schema=1", "module registry", 6):
        module_id, availability, kind, requires_all, requires_any, _purpose = values
        if TOKEN_RE.fullmatch(module_id) is None or module_id in result:
            fail(f"module registry has an unsafe or duplicate id at line {line_number}")
        if availability not in {"available", "planning", "unavailable"} or kind not in {"selectable", "dependency"}:
            fail(f"module registry has an invalid row at line {line_number}")
        result[module_id] = Module(
            module_id,
            availability,
            kind,
            parse_list(requires_all, module_id, TOKEN_RE),
            parse_list(requires_any, module_id, TOKEN_RE),
        )
        order.append(module_id)
    if not result:
        fail("module registry is empty")
    for module in result.values():
        for dependency in (*module.requires_all, *module.requires_any):
            if dependency not in result:
                fail(f"module {module.module_id} references unknown dependency {dependency}")
    return result, tuple(order)


def load_profiles(modules: dict[str, Module]) -> dict[str, Profile]:
    offered: dict[str, set[str]] = {}
    seen: set[tuple[str, str]] = set()
    for line_number, values in rows(PROFILES_PATH, "# schema=1", "profile module manifest", 4):
        profile, _scope, module, state = values
        if TOKEN_RE.fullmatch(profile) is None or module not in modules or state not in {"selected", "disabled"}:
            fail(f"profile module manifest has an invalid row at line {line_number}")
        if (profile, module) in seen:
            fail(f"profile module manifest repeats {profile}/{module}")
        if modules[module].kind != "selectable":
            fail(f"profile exposes a dependency-only module at line {line_number}")
        seen.add((profile, module))
        offered.setdefault(profile, set()).add(module)
    return {name: Profile(name, frozenset(values)) for name, values in offered.items()}


def load_conflicts() -> dict[str, Conflict]:
    result: dict[str, Conflict] = {}
    observed_rows: list[tuple[str, tuple[str, ...], tuple[str, ...], tuple[str, ...], str]] = []
    for line_number, values in rows(CONFLICTS_PATH, "# schema=1", "system action conflict manifest", 6):
        conflict_id, packages, system_units, user_units, behavior, purpose = values
        if TOKEN_RE.fullmatch(conflict_id) is None or conflict_id in result:
            fail(f"conflict manifest has an unsafe or duplicate id at line {line_number}")
        conflict = Conflict(
            conflict_id,
            parse_list(packages, conflict_id, PACKAGE_RE),
            parse_list(system_units, conflict_id, UNIT_RE),
            parse_list(user_units, conflict_id, UNIT_RE),
            behavior,
            purpose,
        )
        result[conflict_id] = conflict
        observed_rows.append((conflict_id, conflict.packages, conflict.system_units, conflict.user_units, behavior))
    expected_rows = [
        (name, packages, system_units, user_units, behavior)
        for name, (packages, system_units, user_units, behavior) in REVIEWED_CONFLICTS.items()
    ]
    if observed_rows != expected_rows:
        fail("system action conflict manifest differs from the reviewed command policy")
    return result


def load_actions(modules: dict[str, Module], conflicts: dict[str, Conflict]) -> tuple[Action, ...]:
    actions: list[Action] = []
    executable_rows: list[tuple[str, ...]] = []
    for line_number, values in rows(ACTIONS_PATH, "# schema=1", "system action manifest", 14):
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
            requires_raw,
            rollback,
            post_check,
            purpose,
            evidence,
        ) = values
        if module not in modules:
            fail(f"system action {action_id} references unknown module at line {line_number}")
        profiles = tuple(sorted(load_profiles_token(profiles_raw)))
        conflict = None if conflict_raw == "-" else conflict_raw
        if conflict is not None and conflict not in conflicts:
            fail(f"system action {action_id} references unknown conflict {conflict}")
        requires = parse_list(requires_raw, action_id, TOKEN_RE)
        actions.append(
            Action(
                action_id,
                module,
                profiles,
                disposition,
                privilege,
                handler,
                target,
                applicability,
                conflict,
                requires,
                rollback,
                post_check,
                purpose,
                evidence,
            )
        )
        executable_rows.append(values[:10])
    if tuple(executable_rows) != REVIEWED_ACTION_ROWS:
        fail("system action manifest differs from the reviewed executable action policy")
    action_ids = {action.action_id for action in actions}
    for action in actions:
        if any(dependency not in action_ids for dependency in action.requires):
            fail(f"system action {action.action_id} has an unknown dependency")
    return tuple(actions)


def load_profiles_token(raw: str) -> set[str]:
    if raw == "all":
        return {"asus-amd-nvidia", "desktop-amd", "vm"}
    values = raw.split(",")
    if not values or len(values) != len(set(values)) or any(TOKEN_RE.fullmatch(value) is None for value in values):
        fail("system action manifest has an invalid profile list")
    return set(values)


def load_policies(modules: dict[str, Module]) -> tuple[PackagePolicy, ...]:
    result: list[PackagePolicy] = []
    seen: set[str] = set()
    for line_number, values in rows(PACKAGES_PATH, "# schema=1", "workstation package manifest", 9):
        policy = PackagePolicy(*values)
        if PACKAGE_RE.fullmatch(policy.package) is None or policy.package in seen:
            fail(f"workstation package manifest has an unsafe or duplicate package at line {line_number}")
        if policy.module not in modules:
            fail(f"workstation package {policy.package} references unknown module")
        if policy.policy not in {"install", "verify", "deferred"}:
            fail(f"workstation package {policy.package} has an invalid policy")
        seen.add(policy.package)
        result.append(policy)
    return tuple(result)


def require_env(name: str) -> str:
    value = os.environ.get(name)
    if value is None or value == "" or contains_control(value):
        fail(f"{name} is missing or malformed")
    return value


def parse_effects(raw: str) -> tuple[dict[str, str], ...]:
    try:
        document = json.loads(raw)
    except json.JSONDecodeError as error:
        fail(f"FULL_ORCHESTRATOR_EFFECTS_JSON is malformed: {error}")
    if not isinstance(document, list):
        fail("FULL_ORCHESTRATOR_EFFECTS_JSON must be an array")
    effects: list[dict[str, str]] = []
    for index, item in enumerate(document):
        if not isinstance(item, dict) or set(item) != {"id", "module", "detail"}:
            fail(f"effect {index} does not have the exact reviewed keys")
        if not all(isinstance(item[key], str) and item[key] and not contains_control(item[key]) for key in item):
            fail(f"effect {index} contains a malformed value")
        effects.append({"id": item["id"], "module": item["module"], "detail": item["detail"]})
    if len({effect["id"] for effect in effects}) != len(effects):
        fail("effects contain a duplicate id")
    return tuple(effects)


def validate_selection(
    selected: tuple[str, ...],
    profile: Profile,
    modules: dict[str, Module],
    module_order: tuple[str, ...],
) -> None:
    if selected != tuple(module for module in module_order if module in set(selected)):
        fail("FULL_ORCHESTRATOR_MODULES is not in exact manifest order")
    selected_set = set(selected)
    for module_id in selected:
        module = modules.get(module_id)
        if module is None:
            fail(f"FULL_ORCHESTRATOR_MODULES contains unknown module {module_id}")
        if module.kind == "selectable" and module_id not in profile.offered:
            fail(f"profile {profile.name} does not offer selected module {module_id}")
        if any(dependency not in selected_set for dependency in module.requires_all):
            fail(f"selected module {module_id} is missing a requires-all dependency")
        if module.requires_any and not any(choice in selected_set for choice in module.requires_any):
            fail(f"selected module {module_id} is missing a requires-any dependency")


def action_effect(action: Action) -> dict[str, str]:
    return {
        "id": f"action:{action.action_id}",
        "module": action.module,
        "detail": " ".join(
            (
                f"disposition={action.disposition}",
                f"privilege={action.privilege}",
                f"handler={action.handler}",
                f"target={action.target}",
                f"applicability={action.applicability}",
                f"conflict={action.conflict_set or '-'}",
            )
        ),
    }


def package_effect(policy: PackagePolicy) -> dict[str, str]:
    return {
        "id": f"verify:{policy.package}",
        "module": policy.module,
        "detail": (
            f"package={policy.package} channel={policy.channel} "
            f"repository={policy.repository} acquisition={policy.acquisition}"
        ),
    }


def load_stage() -> Stage:
    action = require_env("FULL_ORCHESTRATOR_ACTION")
    if action not in {"preflight", "execute", "verify"}:
        fail("FULL_ORCHESTRATOR_ACTION is unsupported")
    if require_env("FULL_ORCHESTRATOR_STAGE") != "system-actions":
        fail("adapter may only handle the system-actions stage")
    profile_name = require_env("FULL_ORCHESTRATOR_PROFILE")
    mode = require_env("FULL_ORCHESTRATOR_MODE")
    if mode not in {"new", "reconcile"}:
        fail("FULL_ORCHESTRATOR_MODE is unsupported")
    selected = parse_modules_env(require_env("FULL_ORCHESTRATOR_MODULES"), "FULL_ORCHESTRATOR_MODULES")
    stage_modules = parse_modules_env(
        require_env("FULL_ORCHESTRATOR_STAGE_MODULES"), "FULL_ORCHESTRATOR_STAGE_MODULES"
    )
    effects = parse_effects(require_env("FULL_ORCHESTRATOR_EFFECTS_JSON"))
    fingerprint = require_env("FULL_ORCHESTRATOR_PLAN_FINGERPRINT")
    run_id = require_env("FULL_ORCHESTRATOR_RUN_ID")
    attempt_raw = require_env("FULL_ORCHESTRATOR_ATTEMPT")
    if HEX64_RE.fullmatch(fingerprint) is None or RUN_ID_RE.fullmatch(run_id) is None or len(run_id) > 128:
        fail("orchestrator fingerprint or run id is malformed")
    if not attempt_raw.isascii() or not attempt_raw.isdigit() or int(attempt_raw) < 1:
        fail("FULL_ORCHESTRATOR_ATTEMPT is malformed")

    modules, module_order = load_modules()
    profiles = load_profiles(modules)
    if profile_name not in profiles:
        fail(f"unknown profile {profile_name}")
    validate_selection(selected, profiles[profile_name], modules, module_order)
    conflicts = load_conflicts()
    all_actions = load_actions(modules, conflicts)
    policies = load_policies(modules)
    selected_set = set(selected)
    selected_actions = tuple(
        row for row in all_actions if row.module in selected_set and profile_name in row.profiles
    )
    selected_ids = {row.action_id for row in selected_actions}
    for row in selected_actions:
        if any(dependency not in selected_ids for dependency in row.requires):
            fail(f"selected action {row.action_id} is missing selected dependency")
    verify_packages = tuple(
        sorted(
            (
                row
                for row in policies
                if row.module in selected_set and row.policy == "verify" and row.acquisition == "verify-only"
            ),
            key=lambda row: row.package,
        )
    )
    expected_effects = tuple(action_effect(row) for row in selected_actions) + tuple(
        package_effect(row) for row in verify_packages
    )
    if effects != expected_effects:
        fail("FULL_ORCHESTRATOR_EFFECTS_JSON differs from the exact selected action/package plan")
    effect_modules = {effect["module"] for effect in effects}
    expected_stage_modules = tuple(module for module in selected if module in effect_modules)
    if stage_modules != expected_stage_modules:
        fail("FULL_ORCHESTRATOR_STAGE_MODULES differs from exact effect module order")
    return Stage(
        action,
        profile_name,
        mode,
        selected,
        stage_modules,
        effects,
        fingerprint,
        run_id,
        int(attempt_raw),
        selected_actions,
        verify_packages,
        policies,
        conflicts,
    )


def inspect_directory(
    path: Path,
    label: str,
    *,
    owner: int | None = None,
    exact_mode: int | None = None,
    writable_ok: bool = False,
) -> os.stat_result:
    if first_symlink(path) is not None:
        fail(f"{label} path contains a symlink", 1)
    try:
        info = path.lstat()
    except OSError as error:
        fail(f"could not inspect {label}: {error}", 1)
    if not stat.S_ISDIR(info.st_mode):
        fail(f"{label} is not a directory", 1)
    if owner is not None and info.st_uid != owner:
        fail(f"{label} has an unexpected owner", 1)
    if exact_mode is not None and stat.S_IMODE(info.st_mode) != exact_mode:
        fail(f"{label} must have mode {exact_mode:o}", 1)
    if not writable_ok and stat.S_IMODE(info.st_mode) & 0o022:
        fail(f"{label} is group/world writable", 1)
    return info


def load_context() -> ExecutionContext:
    testing_raw = os.environ.get("SYSTEM_ACTION_APPLY_TESTING")
    root_raw = os.environ.get("SYSTEM_ACTION_APPLY_TEST_ROOT")
    command_raw = os.environ.get("SYSTEM_ACTION_TEST_COMMAND_DIR")
    if testing_raw is None and root_raw is None and command_raw is None:
        return ExecutionContext(False, Path("/"), None, 0, 0)
    if testing_raw != "1" or not root_raw or not command_raw:
        fail("test mode requires testing=1, an isolated root, and a fixed command directory")
    target_root = lexical_absolute(Path(root_raw))
    command_dir = lexical_absolute(Path(command_raw))
    if target_root == Path("/"):
        fail("test mode cannot target the real root")
    inspect_directory(target_root, "isolated test root", owner=os.geteuid(), exact_mode=0o700)
    inspect_directory(command_dir, "test command directory", owner=os.geteuid(), writable_ok=True)
    return ExecutionContext(True, target_root, command_dir, os.geteuid(), os.getegid())


def target_path(context: ExecutionContext, absolute: Path) -> Path:
    if not absolute.is_absolute() or ".." in absolute.parts:
        fail("internal fixed target is not absolute")
    if context.target_root == Path("/"):
        return absolute
    return context.target_root / absolute.relative_to("/")


def production_environment() -> dict[str, str]:
    environment = os.environ.copy()
    environment["LC_ALL"] = "C"
    environment["LANG"] = "C"
    return environment


def command_path(name: str, context: ExecutionContext, *, required: bool = True) -> Path | None:
    path = (context.command_dir / name) if context.testing and context.command_dir else Path("/usr/bin") / name
    try:
        data, info = read_regular(path, f"command {name}", require_owner=context.owner_uid if context.testing else 0)
    except AdapterFailure:
        if not required:
            return None
        raise
    del data
    if not info.st_mode & 0o111 or stat.S_IMODE(info.st_mode) & 0o022:
        fail(f"command {name} is not a safe executable", 1)
    return path


def run_command(arguments: Sequence[str | Path]) -> CommandResult:
    argv = [os.fspath(value) for value in arguments]
    try:
        completed = subprocess.run(
            argv,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            env=production_environment(),
        )
    except OSError as error:
        raise AdapterFailure(1, f"could not execute fixed command {Path(argv[0]).name}: {error}") from error
    status = normalize_status(completed.returncode)
    stdout = completed.stdout.decode("utf-8", errors="replace")
    stderr = completed.stderr.decode("utf-8", errors="replace")
    return CommandResult(status, stdout, stderr)


def require_root_wrapper(context: ExecutionContext, *, allow_expected_pending: bool = False) -> Path | None:
    if context.testing:
        home = lexical_absolute(Path.home())
        expected_wrapper = os.environ.get("SYSTEM_ACTION_TEST_GSUDO_SHA256", "")
        expected_helper = os.environ.get("SYSTEM_ACTION_TEST_ASKPASS_SHA256", "")
        if HEX64_RE.fullmatch(expected_wrapper) is None or HEX64_RE.fullmatch(expected_helper) is None:
            fail("test mode requires fixed wrapper/helper SHA-256 values")
    else:
        try:
            home = lexical_absolute(Path(pwd.getpwuid(os.geteuid()).pw_dir))
        except KeyError as error:
            raise AdapterFailure(1, "could not resolve ordinary-user home") from error
        expected_wrapper = AUDITED_GSUDO_SHA256
        expected_helper = AUDITED_ASKPASS_SHA256
    if first_symlink(home) is not None:
        fail("ordinary-user home contains a symlink", 1)
    wrapper = home / "scripts/desktop/gsudo"
    helper = home / "scripts/desktop/fuzzel-askpass"
    wrapper_present = wrapper.exists() or wrapper.is_symlink()
    helper_present = helper.exists() or helper.is_symlink()
    if not wrapper_present and not helper_present:
        if not allow_expected_pending:
            fail("gsudo wrapper and askpass helper are not installed", 1)
        for path, label, expected in (
            (REPOSITORY_GSUDO, "repository gsudo payload", AUDITED_GSUDO_SHA256),
            (REPOSITORY_ASKPASS, "repository askpass payload", AUDITED_ASKPASS_SHA256),
        ):
            data, info = read_regular(path, label, require_owner=os.geteuid())
            if not info.st_mode & 0o111 or stat.S_IMODE(info.st_mode) & 0o022:
                fail(f"{label} is not a safe executable", 1)
            if sha256_bytes(data) != expected:
                fail(f"{label} differs from the fixed production payload", 1)
        emit(
            "privilege-wrapper",
            classification="expected-pending",
            reason="exact repository payloads await the earlier privilege-wrapper stage",
        )
        return None
    if wrapper_present != helper_present:
        fail("gsudo wrapper/helper installation is partial", 1)
    for path, label, expected in (
        (wrapper, "gsudo wrapper", expected_wrapper),
        (helper, "gsudo askpass helper", expected_helper),
    ):
        data, info = read_regular(path, label, require_owner=os.geteuid())
        if not info.st_mode & 0o111 or stat.S_IMODE(info.st_mode) & 0o022:
            fail(f"{label} must be executable and not group/world writable", 1)
        if sha256_bytes(data) != expected:
            fail(f"{label} differs from the reviewed fixed payload", 1)
    return wrapper


def run_root(wrapper: Path, arguments: Sequence[str | Path], description: str) -> CommandResult:
    result = run_command([wrapper, "--", *arguments])
    if result.status != 0:
        raise AdapterFailure(result.status, f"{description} through gsudo failed with exit {result.status}")
    return result


def read_os_release(context: ExecutionContext) -> None:
    path = target_path(context, Path("/usr/lib/os-release"))
    data, info = read_regular(path, "Arch os-release", require_owner=context.owner_uid)
    if stat.S_IMODE(info.st_mode) & 0o022:
        fail("Arch os-release is group/world writable", 1)
    try:
        lines = data.decode("utf-8").splitlines()
    except UnicodeDecodeError as error:
        fail(f"Arch os-release is not UTF-8: {error}", 1)
    values: dict[str, str] = {}
    for line in lines:
        if "=" not in line or line.startswith("#"):
            continue
        key, value = line.split("=", 1)
        values[key] = value.strip().strip('"')
    if values.get("ID") != "arch":
        fail("system-actions adapter requires Arch Linux", 1)


def query_package_inventory(context: ExecutionContext) -> dict[str, str]:
    pacman = command_path("pacman", context)
    assert pacman is not None
    result = run_command([pacman, "-Q"])
    if result.status != 0:
        emit("package-inventory", classification="unavailable", exit_status=result.status)
        raise AdapterFailure(result.status, f"package inventory query unavailable with exit {result.status}")
    installed: dict[str, str] = {}
    for line in result.stdout.splitlines():
        if not line:
            continue
        fields = line.split()
        if (
            len(fields) != 2
            or PACKAGE_RE.fullmatch(fields[0]) is None
            or VERSION_RE.fullmatch(fields[1]) is None
            or fields[0] in installed
        ):
            fail("successful package inventory returned malformed or duplicate rows", 1)
        installed[fields[0]] = fields[1]
    emit("package-inventory", classification="ready", installed_count=len(installed))
    return installed


def policy_is_earlier_install(policy: PackagePolicy) -> bool:
    return policy.policy == "install" and policy.acquisition in {
        "pacman",
        "archlinuxcn-bootstrap",
        "aur-build",
        "paru-bootstrap",
    }


def selected_policies(stage: Stage) -> tuple[PackagePolicy, ...]:
    selected = set(stage.modules)
    return tuple(row for row in stage.policies if row.module in selected)


def report_package_classifications(
    stage: Stage, installed: dict[str, str], *, preflight: bool, issues: IssueCollector | None = None
) -> None:
    for policy in sorted(selected_policies(stage), key=lambda row: row.package):
        if policy.package in installed:
            emit(
                "package",
                package=policy.package,
                classification="ready",
                expectation="current" if policy.policy == "verify" else "earlier-stage",
                version=installed[policy.package],
            )
        elif policy.policy == "verify" and policy.acquisition == "verify-only":
            emit("package", package=policy.package, classification="missing-current", expectation="current")
            if issues is not None:
                issues.add(1, f"required current verify-only package is missing: {policy.package}", package=policy.package)
        elif policy_is_earlier_install(policy):
            classification = "expected-pending" if preflight else "missing-earlier-stage"
            emit("package", package=policy.package, classification=classification, expectation="earlier-stage")
        else:
            emit("package", package=policy.package, classification="deferred", expectation="none")


def require_action_packages(action: Action, installed: dict[str, str]) -> None:
    for package in ACTION_PACKAGES.get(action.action_id, ()):
        if package not in installed:
            raise AdapterFailure(1, f"action {action.action_id} requires earlier-stage package {package}")


def query_active(context: ExecutionContext, unit: str, *, user: bool = False, global_scope: bool = False) -> bool:
    systemctl = command_path("systemctl", context)
    assert systemctl is not None
    prefix: list[str | Path] = [systemctl]
    if user:
        prefix.append("--user")
    elif global_scope:
        prefix.append("--global")
    result = run_command([*prefix, "is-active", unit])
    text = result.stdout.strip()
    if result.status == 0 and text == "active":
        return True
    if result.status in {3, 4} and text in {"inactive", "failed", "unknown", "deactivating"}:
        return False
    raise AdapterFailure(result.status or 1, f"systemctl is-active query unavailable/malformed for {unit}")


def query_enabled(context: ExecutionContext, unit: str, *, user: bool = False, global_scope: bool = False) -> bool:
    systemctl = command_path("systemctl", context)
    assert systemctl is not None
    prefix: list[str | Path] = [systemctl]
    if user:
        prefix.append("--user")
    elif global_scope:
        prefix.append("--global")
    result = run_command([*prefix, "is-enabled", unit])
    text = result.stdout.strip()
    if result.status == 0 and text in {"enabled", "enabled-runtime"}:
        return True
    if result.status in {1, 3, 4} and text in {"disabled", "static", "indirect", "masked", "not-found", "generated", "transient"}:
        return False
    raise AdapterFailure(result.status or 1, f"systemctl is-enabled query unavailable/malformed for {unit}")


def query_load(context: ExecutionContext, unit: str, *, user: bool = False) -> str:
    systemctl = command_path("systemctl", context)
    assert systemctl is not None
    prefix: list[str | Path] = [systemctl]
    if user:
        prefix.append("--user")
    result = run_command([*prefix, "show", "--property=LoadState", "--value", unit])
    text = result.stdout.strip()
    if result.status == 0 and text in {"loaded", "not-found", "masked", "error"}:
        return text
    raise AdapterFailure(result.status or 1, f"systemctl LoadState query unavailable/malformed for {unit}")


def query_wants(context: ExecutionContext) -> bool:
    systemctl = command_path("systemctl", context)
    assert systemctl is not None
    result = run_command(
        [systemctl, "--user", "show", "--property=Wants", "--value", "niri.service"]
    )
    if result.status != 0:
        raise AdapterFailure(result.status, "niri.service Wants query failed")
    units = result.stdout.split()
    if any(UNIT_RE.fullmatch(unit) is None for unit in units):
        fail("niri.service Wants query returned malformed output", 1)
    return "dms.service" in units


def query_failed_units(context: ExecutionContext, *, user: bool) -> list[str]:
    systemctl = command_path("systemctl", context)
    assert systemctl is not None
    arguments: list[str | Path] = [systemctl]
    if user:
        arguments.append("--user")
    arguments.extend(("--failed", "--output=json", "--no-legend"))
    result = run_command(arguments)
    scope = "user" if user else "system"
    if result.status != 0:
        emit("failed-units", scope=scope, classification="unavailable", exit_status=result.status)
        raise AdapterFailure(result.status, f"{scope} failed-unit query failed with exit {result.status}")
    try:
        document = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        fail(f"{scope} failed-unit query returned malformed JSON: {error}", 1)
    if not isinstance(document, list):
        fail(f"{scope} failed-unit query did not return an array", 1)
    units: list[str] = []
    for item in document:
        if not isinstance(item, dict) or not isinstance(item.get("unit"), str) or UNIT_RE.fullmatch(item["unit"]) is None:
            fail(f"{scope} failed-unit query returned malformed entries", 1)
        units.append(item["unit"])
    if units:
        emit("failed-units", scope=scope, classification="nonempty", units=units)
    else:
        emit("failed-units", scope=scope, classification="empty", units=[])
    return units


def query_network(context: ExecutionContext) -> None:
    if not query_active(context, "NetworkManager.service"):
        raise AdapterFailure(1, "NetworkManager.service is not active")
    getent = command_path("getent", context)
    assert getent is not None
    dns = run_command([getent, "ahostsv4", "archlinux.org"])
    if dns.status != 0:
        raise AdapterFailure(dns.status, f"DNS query failed with exit {dns.status}")
    if not dns.stdout.strip() or any(contains_control(line) for line in dns.stdout.splitlines()):
        fail("DNS query succeeded without recognized address evidence", 1)
    pacman = command_path("pacman", context)
    assert pacman is not None
    mirror = run_command([pacman, "-Si", "--", OFFICIAL_REACHABILITY_PACKAGE])
    if mirror.status != 0:
        raise AdapterFailure(mirror.status, f"official repository metadata query failed with exit {mirror.status}")
    fields: dict[str, list[str]] = {}
    for line in mirror.stdout.splitlines():
        if ":" not in line:
            continue
        key, value = (part.strip() for part in line.split(":", 1))
        fields.setdefault(key, []).append(value)
    if fields.get("Repository") != ["core"] or fields.get("Name") != [OFFICIAL_REACHABILITY_PACKAGE]:
        fail("official repository metadata query returned unexpected identity", 1)
    emit("network", classification="ready", manager="NetworkManager.service", dns="recognized")


def query_bluetooth(context: ExecutionContext, *, required: bool = True) -> str:
    tool = command_path("bluetoothctl", context, required=required)
    if tool is None:
        return "expected-pending"
    result = run_command([tool, "list"])
    if result.status != 0:
        raise AdapterFailure(result.status, f"bluetooth controller query failed with exit {result.status}")
    lines = [line for line in result.stdout.splitlines() if line]
    if not lines:
        return "none"
    if any(CONTROLLER_RE.fullmatch(line) is None for line in lines):
        fail("bluetooth controller query returned unrecognized output", 1)
    return "present"


def query_power_profiles(context: ExecutionContext, *, required: bool = True) -> str:
    tool = command_path("powerprofilesctl", context, required=required)
    if tool is None:
        return "expected-pending"
    result = run_command([tool, "list"])
    if result.status != 0:
        raise AdapterFailure(result.status, f"power profile query failed with exit {result.status}")
    profiles = {
        match.group(1)
        for line in result.stdout.splitlines()
        if (match := re.fullmatch(r"\s*\*?\s*(performance|balanced|power-saver):\s*", line))
    }
    if not profiles:
        fail("power profile query returned no recognized profiles", 1)
    return "ready"


def query_time_sync(context: ExecutionContext) -> str:
    timedatectl = command_path("timedatectl", context)
    assert timedatectl is not None
    result = run_command([timedatectl, "show", "--property=NTPSynchronized", "--value"])
    value = result.stdout.strip()
    if result.status != 0:
        raise AdapterFailure(result.status, f"timedatectl query failed with exit {result.status}")
    if value not in {"yes", "no"}:
        fail("timedatectl query returned an unrecognized value", 1)
    return "synchronized" if value == "yes" else "synchronizing"


def portal_override_paths(context: ExecutionContext) -> tuple[Path, ...]:
    config_home_raw = os.environ.get("XDG_CONFIG_HOME")
    config_home = lexical_absolute(Path(config_home_raw)) if config_home_raw else lexical_absolute(Path.home() / ".config")
    return (
        target_path(context, Path("/etc/xdg/xdg-desktop-portal/portals.conf")),
        config_home / "xdg-desktop-portal/portals.conf",
    )


def check_conflict(
    context: ExecutionContext,
    conflict: Conflict,
    installed: dict[str, str],
) -> None:
    if conflict.behavior == "block-active-or-installed":
        found = [package for package in conflict.packages if package in installed]
        if found:
            raise AdapterFailure(1, f"conflict {conflict.conflict_id} has installed package(s): {','.join(found)}")
    for unit in conflict.system_units:
        if query_active(context, unit):
            raise AdapterFailure(1, f"conflict {conflict.conflict_id} has active system unit {unit}")
    for unit in conflict.user_units:
        if query_active(context, unit, user=True):
            raise AdapterFailure(1, f"conflict {conflict.conflict_id} has active user unit {unit}")
    if conflict.behavior == "block-managed-paths":
        for path in portal_override_paths(context):
            try:
                info = path.lstat()
            except FileNotFoundError:
                continue
            except OSError as error:
                raise AdapterFailure(1, f"could not inspect portal override path {path}: {error}") from error
            kind = "symlink" if stat.S_ISLNK(info.st_mode) else "existing"
            raise AdapterFailure(1, f"portal override conflict path is {kind}: {path}")


def snapshot_fixed(
    context: ExecutionContext,
    absolute: Path,
    label: str,
    *,
    allow_missing: bool,
) -> FileSnapshot:
    path = target_path(context, absolute)
    parent = path.parent
    if first_symlink(parent) is not None:
        fail(f"{label} parent path contains a symlink", 1)
    try:
        parent_info = parent.lstat()
    except OSError as error:
        raise AdapterFailure(1, f"could not inspect {label} parent: {error}") from error
    if not stat.S_ISDIR(parent_info.st_mode):
        fail(f"{label} parent is not a directory", 1)
    if parent_info.st_uid != context.owner_uid or stat.S_IMODE(parent_info.st_mode) & 0o022:
        fail(f"{label} parent owner/mode is unsafe", 1)
    try:
        data, info = read_regular(path, label, require_owner=context.owner_uid)
    except AdapterFailure as error:
        if allow_missing and not path.exists() and not path.is_symlink():
            return FileSnapshot(path, False, None, None, None, None, None, None, None)
        raise error
    mode = stat.S_IMODE(info.st_mode)
    if mode & 0o022:
        fail(f"{label} is group/world writable", 1)
    return FileSnapshot(path, True, data, sha256_bytes(data), mode, info.st_uid, info.st_gid, info.st_dev, info.st_ino)


def decode_file(snapshot: FileSnapshot, label: str) -> str:
    if not snapshot.exists:
        return ""
    assert snapshot.data is not None
    try:
        return snapshot.data.decode("utf-8")
    except UnicodeDecodeError as error:
        fail(f"{label} is not UTF-8: {error}", 1)


def has_gtk_im_module(snapshot: FileSnapshot) -> bool:
    text = decode_file(snapshot, "/etc/environment")
    return any(re.match(r"^\s*(?:export\s+)?GTK_IM_MODULE\s*=", line) for line in text.splitlines())


def desired_locale_gen(current: bytes) -> bytes:
    try:
        text = current.decode("utf-8")
    except UnicodeDecodeError as error:
        fail(f"locale.gen is not UTF-8: {error}", 1)
    desired = ("en_US.UTF-8 UTF-8", "zh_CN.UTF-8 UTF-8")
    patterns = {
        "en_US.UTF-8 UTF-8": re.compile(r"^\s*#?\s*en_US\.UTF-8\s+UTF-8\s*$"),
        "zh_CN.UTF-8 UTF-8": re.compile(r"^\s*#?\s*zh_CN\.UTF-8\s+UTF-8\s*$"),
    }
    output: list[str] = []
    inserted: set[str] = set()
    for line in text.splitlines():
        matched = next((value for value in desired if patterns[value].fullmatch(line)), None)
        if matched is None:
            output.append(line)
        elif matched not in inserted:
            output.append(matched)
            inserted.add(matched)
    for value in desired:
        if value not in inserted:
            output.append(value)
    return ("\n".join(output) + "\n").encode("utf-8")


def desired_locale_conf() -> bytes:
    return b"LANG=zh_CN.UTF-8\nLC_CTYPE=en_US.UTF-8\n"


def desired_environment(snapshot: FileSnapshot) -> bytes:
    text = decode_file(snapshot, "/etc/environment")
    lines = text.splitlines()
    if any(re.match(r"^\s*(?:export\s+)?GTK_IM_MODULE\s*=", line) for line in lines):
        fail("/etc/environment contains GTK_IM_MODULE and must be reviewed manually", 1)
    output = [
        line
        for line in lines
        if not re.match(r"^\s*(?:export\s+)?(?:QT_IM_MODULE|XMODIFIERS)\s*=", line)
    ]
    output.extend(("QT_IM_MODULE=fcitx", "XMODIFIERS=@im=fcitx"))
    return ("\n".join(output) + "\n").encode("utf-8")


def query_locales(context: ExecutionContext) -> bool:
    locale = command_path("locale", context)
    assert locale is not None
    result = run_command([locale, "-a"])
    if result.status != 0:
        raise AdapterFailure(result.status, f"locale -a query failed with exit {result.status}")
    normalized = {value.strip().lower().replace("utf-8", "utf8") for value in result.stdout.splitlines() if value.strip()}
    return {"en_us.utf8", "zh_cn.utf8"}.issubset(normalized)


def inspect_user_unit_files(*, require_present: bool) -> tuple[Path, ...]:
    config_home_raw = os.environ.get("XDG_CONFIG_HOME")
    config_home = lexical_absolute(Path(config_home_raw)) if config_home_raw else lexical_absolute(Path.home() / ".config")
    paths = tuple(config_home / "systemd/user" / unit for unit in PERSONAL_USER_UNITS)
    for path in paths:
        try:
            data, info = read_regular(path, f"mapped user unit {path.name}", require_owner=os.geteuid())
            del data
            if stat.S_IMODE(info.st_mode) & 0o022:
                fail(f"mapped user unit is group/world writable: {path}", 1)
        except AdapterFailure:
            if not require_present and not path.exists() and not path.is_symlink():
                continue
            raise
    return paths


def inspect_network_xml(context: ExecutionContext, *, allow_pending: bool) -> str:
    path = target_path(context, NETWORK_XML)
    try:
        data, info = read_regular(path, "libvirt default network XML", require_owner=context.owner_uid)
        del data
    except AdapterFailure:
        if allow_pending and not path.exists() and not path.is_symlink():
            return "expected-pending"
        raise
    if stat.S_IMODE(info.st_mode) & 0o022:
        fail("libvirt default network XML is group/world writable", 1)
    pacman = command_path("pacman", context)
    assert pacman is not None
    result = run_command([pacman, "-Qo", "--", path])
    if result.status != 0:
        raise AdapterFailure(result.status, f"libvirt default XML ownership query failed with exit {result.status}")
    expected = f"{path} is owned by libvirt "
    if len(result.stdout.splitlines()) != 1 or not result.stdout.startswith(expected):
        fail("libvirt default XML is not owned by the official libvirt package", 1)
    return "ready"


def parse_network_info(result: CommandResult) -> dict[str, Any] | None:
    if result.status == 1 and not result.stdout.strip() and "failed to get network 'default'" in result.stderr:
        return None
    if result.status != 0:
        raise AdapterFailure(result.status, f"virsh net-info query failed with exit {result.status}")
    fields: dict[str, str] = {}
    for line in result.stdout.splitlines():
        if ":" not in line:
            continue
        key, value = (part.strip() for part in line.split(":", 1))
        if key in fields:
            fail("virsh net-info returned duplicate fields", 1)
        fields[key] = value
    if (
        fields.get("Name") != "default"
        or fields.get("Persistent") != "yes"
        or fields.get("Active") not in {"yes", "no"}
        or fields.get("Autostart") not in {"yes", "no"}
    ):
        fail("virsh net-info returned an unexpected default network", 1)
    return {
        "defined": True,
        "active": fields["Active"] == "yes",
        "autostart": fields["Autostart"] == "yes",
    }


def query_network_info(context: ExecutionContext) -> dict[str, Any] | None:
    virsh = command_path("virsh", context)
    assert virsh is not None
    return parse_network_info(run_command([virsh, "--connect", "qemu:///system", "net-info", "default"]))


def query_libvirt_uri(context: ExecutionContext) -> None:
    virsh = command_path("virsh", context)
    assert virsh is not None
    result = run_command([virsh, "--connect", "qemu:///system", "uri"])
    if result.status != 0:
        raise AdapterFailure(result.status, f"libvirt connection query failed with exit {result.status}")
    if result.stdout.strip() != "qemu:///system":
        fail("libvirt connection query returned an unexpected URI", 1)


def preflight_action(
    context: ExecutionContext,
    stage: Stage,
    action: Action,
    installed: dict[str, str],
) -> tuple[str, str]:
    if action.disposition in {"manual", "deferred"}:
        return action.disposition, "review-only action is intentionally not executed"
    if action.conflict_set:
        check_conflict(context, stage.conflicts[action.conflict_set], installed)
    if action.action_id == "base-network-handoff":
        query_network(context)
    elif action.action_id == "base-package-preconditions":
        missing = [row.package for row in stage.verify_packages if row.package not in installed]
        if missing:
            raise AdapterFailure(1, f"verify-only package(s) missing: {','.join(missing)}")
    elif action.action_id == "failed-unit-baseline":
        failed = query_failed_units(context, user=False) + query_failed_units(context, user=True)
        if failed:
            raise AdapterFailure(1, f"failed-unit baseline is nonempty: {','.join(failed)}")
    elif action.action_id == "bluetooth-service":
        state = query_bluetooth(context, required="bluez-utils" in installed)
        if state == "none":
            return "not-applicable", "recognized controller query found no controller"
        if state == "expected-pending":
            return "expected-pending", "bluetooth tools await an earlier package stage"
    elif action.action_id == "power-profiles-service":
        state = query_power_profiles(context, required="power-profiles-daemon" in installed)
        if state == "expected-pending":
            return state, "power profile tool awaits an earlier package stage"
    elif action.action_id == "personal-user-unit-reload":
        inspect_user_unit_files(require_present=False)
    elif action.action_id == "libvirt-default-network":
        state = inspect_network_xml(context, allow_pending="libvirt" not in installed)
        if state == "expected-pending":
            return state, "official libvirt network XML awaits an earlier package stage"
    elif action.action_id == "locale-zh-cn":
        snapshot_fixed(context, LOCALE_GEN, "locale.gen", allow_missing=False)
        snapshot_fixed(context, LOCALE_CONF, "locale.conf", allow_missing=True)
        command_path("locale", context)
        command_path("locale-gen", context)
    elif action.action_id == "fcitx-system-environment":
        environment = snapshot_fixed(context, ENVIRONMENT_FILE, "environment", allow_missing=True)
        if has_gtk_im_module(environment):
            raise AdapterFailure(1, "/etc/environment contains GTK_IM_MODULE")
    elif action.action_id in SYSTEM_UNIT_ACTIONS:
        load = query_load(context, SYSTEM_UNIT_ACTIONS[action.action_id])
        if load == "not-found" and any(package not in installed for package in ACTION_PACKAGES.get(action.action_id, ())):
            return "expected-pending", "unit awaits an earlier package stage"
        if load != "loaded":
            raise AdapterFailure(1, f"target system unit is not safely loaded: {SYSTEM_UNIT_ACTIONS[action.action_id]}")
    elif action.action_id == "dms-niri-session-wants":
        for unit in ("niri.service", "dms.service"):
            load = query_load(context, unit, user=True)
            if load == "not-found" and any(package not in installed for package in ACTION_PACKAGES[action.action_id]):
                return "expected-pending", "user units await an earlier package stage"
            if load != "loaded":
                raise AdapterFailure(1, f"target user unit is not safely loaded: {unit}")
    elif action.action_id == "dsearch-user-service":
        load = query_load(context, "dsearch.service", user=True)
        if load == "not-found" and "dsearch-bin" not in installed:
            return "expected-pending", "dsearch unit awaits an earlier package stage"
        if load != "loaded":
            raise AdapterFailure(1, "dsearch.service is not safely loaded")
    elif action.action_id == "audio-package-activation":
        for unit in action.target.split(","):
            query_load(context, unit, user=True)
    elif action.action_id == "asusd-package-activation":
        query_load(context, "asusd.service")
    return "ready", "read-only checks completed"


def preflight(context: ExecutionContext, stage: Stage) -> int:
    if os.geteuid() == 0:
        fail("system-actions adapter main process must run as an ordinary user", 1)
    if platform.machine() != "x86_64":
        fail("system-actions adapter requires x86_64", 1)
    read_os_release(context)
    systemd_analyze = command_path("systemd-analyze", context)
    assert systemd_analyze is not None
    version = run_command([systemd_analyze, "--version"])
    if version.status != 0:
        raise AdapterFailure(version.status, f"systemd version query failed with exit {version.status}")
    if not version.stdout.startswith("systemd "):
        fail("systemd version query returned unrecognized output", 1)
    command_path("systemctl", context)
    command_path("getent", context)
    command_path("pacman", context)
    wrapper = require_root_wrapper(context, allow_expected_pending=True)
    if wrapper is not None:
        emit("privilege-wrapper", classification="ready")
    installed = query_package_inventory(context)
    issues = IssueCollector()
    report_package_classifications(stage, installed, preflight=True, issues=issues)
    for action in stage.actions:
        try:
            classification, message = preflight_action(context, stage, action, installed)
            emit(
                "action-check",
                action="preflight",
                action_id=action.action_id,
                classification=classification,
                disposition=action.disposition,
                message=message,
            )
        except AdapterFailure as error:
            issues.add(error.status, error.message, action_id=action.action_id)
    emit("stage", action="preflight", classification="ready" if not issues.count else "blocked", issues=issues.count)
    return issues.first_status


def state_root() -> Path:
    raw = os.environ.get("XDG_STATE_HOME")
    base = lexical_absolute(Path(raw)) if raw else lexical_absolute(Path.home() / ".local/state")
    if not base.is_absolute():
        fail("XDG_STATE_HOME must be absolute")
    return base / STATE_SUFFIX


def ensure_private_directory(path: Path) -> None:
    path = lexical_absolute(path)
    if path.exists() or path.is_symlink():
        inspect_directory(path, "private state directory", owner=os.geteuid(), exact_mode=0o700)
        return
    missing: list[Path] = []
    cursor = path
    while not cursor.exists() and cursor != cursor.parent:
        missing.append(cursor)
        cursor = cursor.parent
    if first_symlink(cursor) is not None:
        fail("private state parent contains a symlink", 1)
    for directory in reversed(missing):
        try:
            directory.mkdir(mode=0o700)
            os.chmod(directory, 0o700)
        except FileExistsError:
            pass
        except OSError as error:
            raise AdapterFailure(1, f"could not create private state directory: {error}") from error
    inspect_directory(path, "private state directory", owner=os.geteuid(), exact_mode=0o700)


def fsync_directory(path: Path) -> None:
    try:
        fd = os.open(path, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0))
        try:
            os.fsync(fd)
        finally:
            os.close(fd)
    except OSError as error:
        raise AdapterFailure(1, f"could not fsync directory {path}: {error}") from error


def renameat2(path_from: Path, path_to: Path, flags: int, *, audit: bool = True) -> None:
    if audit:
        sys.audit("myarch.system-conditional-replace", os.fspath(path_from), os.fspath(path_to))
    if _RENAMEAT2 is None:
        raise AdapterFailure(1, "renameat2 is unavailable; cannot commit fixed system file conditionally")
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


def displaced_fixed_snapshot_matches(path: Path, prior: FileSnapshot) -> bool:
    if not prior.exists or prior.sha256 is None or prior.mode is None:
        return False
    try:
        data, info = read_regular(path, "displaced fixed system target", require_owner=prior.uid)
    except AdapterFailure:
        return False
    return (
        sha256_bytes(data),
        stat.S_IMODE(info.st_mode),
        info.st_uid,
        info.st_gid,
        info.st_dev,
        info.st_ino,
    ) == (
        prior.sha256,
        prior.mode,
        prior.uid,
        prior.gid,
        prior.device,
        prior.inode,
    )


def conditional_replace_fixed(temporary: Path, target: Path, prior: FileSnapshot) -> None:
    if not prior.exists:
        try:
            renameat2(temporary, target, RENAME_NOREPLACE)
        except OSError as error:
            raise AdapterFailure(1, f"fixed target changed at final create boundary {target}: {error}") from error
        return

    try:
        renameat2(temporary, target, RENAME_EXCHANGE)
    except OSError as error:
        raise AdapterFailure(1, f"fixed target changed at final replace boundary {target}: {error}") from error
    if displaced_fixed_snapshot_matches(temporary, prior):
        try:
            temporary.unlink()
        except OSError as error:
            raise AdapterFailure(1, f"could not remove displaced fixed target {temporary}: {error}") from error
        return

    try:
        renameat2(temporary, target, RENAME_EXCHANGE, audit=False)
    except OSError as error:
        failure = AdapterFailure(
            1,
            f"fixed target changed at final replace boundary and rollback exchange failed; "
            f"conflicting bytes retained at {temporary}: {error}",
        )
        setattr(failure, "preserve_temporary", True)
        raise failure from error
    raise AdapterFailure(1, f"fixed target changed at final replace boundary: {target}")


def atomic_write(path: Path, data: bytes, mode: int) -> None:
    ensure_private_directory(path.parent)
    temporary: str | None = None
    fd: int | None = None
    try:
        fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
        os.fchmod(fd, mode)
        offset = 0
        while offset < len(data):
            offset += os.write(fd, data[offset:])
        os.fsync(fd)
        os.close(fd)
        fd = None
        os.replace(temporary, path)
        temporary = None
        fsync_directory(path.parent)
    except OSError as error:
        raise AdapterFailure(1, f"atomic private write failed for {path}: {error}") from error
    finally:
        if fd is not None:
            os.close(fd)
        if temporary is not None:
            try:
                os.unlink(temporary)
            except FileNotFoundError:
                pass


def initial_state(stage: Stage) -> dict[str, Any]:
    return {
        "schema": 1,
        "stage": "system-actions",
        "plan_fingerprint": stage.fingerprint,
        "run_id": stage.run_id,
        "profile": stage.profile,
        "modules": list(stage.modules),
        "attempt": stage.attempt,
        "actions": {},
    }


def load_or_create_state(stage: Stage) -> tuple[Path, Path, dict[str, Any]]:
    root = state_root()
    ensure_private_directory(root)
    run_dir = root / stage.run_id
    ensure_private_directory(run_dir)
    path = run_dir / "actions.json"
    if not path.exists() and not path.is_symlink():
        document = initial_state(stage)
        atomic_write(path, json.dumps(document, sort_keys=True, separators=(",", ":")).encode() + b"\n", 0o600)
        return run_dir, path, document
    data, info = read_regular(path, "action state", require_owner=os.geteuid())
    if stat.S_IMODE(info.st_mode) != 0o600:
        fail("action state must be mode 600", 1)
    try:
        document = json.loads(data)
    except (json.JSONDecodeError, UnicodeDecodeError) as error:
        fail(f"action state is malformed: {error}")
    expected = initial_state(stage)
    if not isinstance(document, dict) or set(document) != set(expected):
        fail("action state has an unexpected schema")
    for key in ("schema", "stage", "plan_fingerprint", "run_id", "profile", "modules"):
        if document.get(key) != expected[key]:
            fail(f"action state differs from current plan at {key}")
    if not isinstance(document.get("attempt"), int) or not isinstance(document.get("actions"), dict):
        fail("action state has malformed attempt/actions fields")
    if document["attempt"] < 1 or stage.attempt < document["attempt"]:
        fail("action state attempt is newer than the current retry")
    actions_by_id = {action.action_id: action for action in stage.actions}
    expected_entry_keys = {
        "disposition",
        "classification",
        "exit_status",
        "target",
        "prior",
        "result",
        "rollback_guidance",
    }
    for action_id, entry in document["actions"].items():
        action = actions_by_id.get(action_id)
        if action is None or not isinstance(entry, dict) or set(entry) != expected_entry_keys:
            fail("action state contains an unknown or malformed action entry")
        if (
            entry.get("disposition") != action.disposition
            or entry.get("target") != action.target
            or entry.get("rollback_guidance") != action.rollback
            or not isinstance(entry.get("classification"), str)
            or not isinstance(entry.get("exit_status"), int)
            or not 0 <= entry["exit_status"] <= 255
            or not isinstance(entry.get("prior"), dict)
            or not isinstance(entry.get("result"), dict)
        ):
            fail("action state entry differs from the current reviewed action")
    document["attempt"] = stage.attempt
    return run_dir, path, document


def save_outcome(
    path: Path,
    state: dict[str, Any],
    action: Action,
    outcome: Outcome,
) -> None:
    prior = outcome.prior or {}
    existing = state["actions"].get(action.action_id)
    if isinstance(existing, dict):
        existing_prior = existing.get("prior")
        # The first nonempty prior is the rollback origin for this run. A retry
        # may re-query a now-converged target, but must never replace that
        # origin or discard backup references captured before the first write.
        if isinstance(existing_prior, dict) and existing_prior:
            prior = existing_prior
    entry: dict[str, Any] = {
        "disposition": action.disposition,
        "classification": outcome.classification,
        "exit_status": outcome.status,
        "target": action.target,
        "prior": prior,
        "result": outcome.result or {},
        "rollback_guidance": action.rollback,
    }
    state["actions"][action.action_id] = entry
    atomic_write(path, json.dumps(state, ensure_ascii=True, sort_keys=True, separators=(",", ":")).encode() + b"\n", 0o600)


def backup_snapshot(run_dir: Path, snapshot: FileSnapshot, absolute: Path) -> str:
    backup_root = run_dir / "backups"
    path = backup_root / absolute.relative_to("/")
    if snapshot.exists:
        assert snapshot.data is not None
        if path.exists() or path.is_symlink():
            data, info = read_regular(path, "existing private backup", require_owner=os.geteuid())
            if stat.S_IMODE(info.st_mode) != 0o600:
                fail("existing private backup is not mode 600", 1)
            return os.fspath(path)
        atomic_write(path, snapshot.data, 0o600)
    else:
        marker = path.with_name(path.name + ".absent.json")
        if not marker.exists() and not marker.is_symlink():
            atomic_write(marker, b'{"prior":"absent"}\n', 0o600)
        path = marker
    return os.fspath(path)


def write_evidence(run_dir: Path, name: str, result: CommandResult) -> Path:
    evidence = run_dir / "evidence" / name
    data = (
        f"exit={result.status}\nstdout:\n{result.stdout}\nstderr:\n{result.stderr}"
    ).encode("utf-8", errors="replace")
    atomic_write(evidence, data, 0o600)
    return evidence


def verify_system_unit(context: ExecutionContext, action_id: str, unit: str) -> dict[str, Any]:
    enabled = query_enabled(context, unit)
    active = query_active(context, unit)
    if not enabled or not active:
        raise AdapterFailure(1, f"verification drift for {unit}: enabled={enabled} active={active}")
    result: dict[str, Any] = {"enabled": enabled, "active": active}
    if action_id == "time-sync-service":
        result["time_sync"] = query_time_sync(context)
    elif action_id == "bluetooth-service":
        controller = query_bluetooth(context)
        if controller == "none":
            result["applicability"] = "not-applicable"
        elif controller != "present":
            raise AdapterFailure(1, "bluetooth verification lacks a recognized controller query")
    elif action_id == "power-profiles-service":
        result["power_profiles"] = query_power_profiles(context)
    elif action_id == "libvirtd-service":
        query_libvirt_uri(context)
        result["uri"] = "qemu:///system"
    return result


def execute_system_unit(
    context: ExecutionContext,
    action: Action,
    installed: dict[str, str],
    wrapper: Path,
) -> Outcome:
    require_action_packages(action, installed)
    if action.conflict_set:
        # Recheck immediately before changing this branch.
        # The caller passes the stage conflict separately through a closure.
        pass
    if action.action_id == "bluetooth-service":
        controller = query_bluetooth(context)
        if controller == "none":
            return Outcome(action.action_id, "not-applicable", True, result={"controller": "none"})
    if action.action_id == "power-profiles-service":
        query_power_profiles(context)
    unit = SYSTEM_UNIT_ACTIONS[action.action_id]
    prior = {"enabled": query_enabled(context, unit), "active": query_active(context, unit)}
    if not prior["enabled"] or not prior["active"]:
        systemctl = command_path("systemctl", context)
        assert systemctl is not None
        run_root(wrapper, [systemctl, "enable", "--now", unit], f"enable fixed system unit {unit}")
        classification = "applied"
    else:
        classification = "unchanged"
    result = verify_system_unit(context, action.action_id, unit)
    return Outcome(action.action_id, classification, True, prior=prior, result=result)


def execute_user_wants(context: ExecutionContext, action: Action, installed: dict[str, str]) -> Outcome:
    require_action_packages(action, installed)
    prior = {"wants_dms": query_wants(context)}
    if not prior["wants_dms"]:
        systemctl = command_path("systemctl", context)
        assert systemctl is not None
        result = run_command([systemctl, "--user", "add-wants", "niri.service", "dms.service"])
        if result.status != 0:
            raise AdapterFailure(result.status, f"systemctl --user add-wants failed with exit {result.status}")
        classification = "applied"
    else:
        classification = "unchanged"
    if not query_wants(context):
        raise AdapterFailure(1, "niri.service does not want dms.service after apply")
    return Outcome(action.action_id, classification, True, prior=prior, result={"wants_dms": True})


def execute_user_service(context: ExecutionContext, action: Action, installed: dict[str, str]) -> Outcome:
    require_action_packages(action, installed)
    unit = "dsearch.service"
    prior = {"enabled": query_enabled(context, unit, user=True), "active": query_active(context, unit, user=True)}
    if not prior["enabled"] or not prior["active"]:
        systemctl = command_path("systemctl", context)
        assert systemctl is not None
        result = run_command([systemctl, "--user", "enable", "--now", unit])
        if result.status != 0:
            raise AdapterFailure(result.status, f"user unit enable failed with exit {result.status}")
        classification = "applied"
    else:
        classification = "unchanged"
    enabled = query_enabled(context, unit, user=True)
    active = query_active(context, unit, user=True)
    if not enabled or not active:
        raise AdapterFailure(1, "dsearch.service did not verify enabled and active")
    return Outcome(action.action_id, classification, True, prior=prior, result={"enabled": True, "active": True})


def execute_user_reload(context: ExecutionContext, action: Action) -> Outcome:
    paths = inspect_user_unit_files(require_present=True)
    analyze = command_path("systemd-analyze", context)
    assert analyze is not None
    checked = run_command([analyze, "--user", "verify", "--", *paths])
    if checked.status != 0:
        raise AdapterFailure(checked.status, f"mapped user unit verification failed with exit {checked.status}")
    systemctl = command_path("systemctl", context)
    assert systemctl is not None
    reloaded = run_command([systemctl, "--user", "daemon-reload"])
    if reloaded.status != 0:
        raise AdapterFailure(reloaded.status, f"user daemon-reload failed with exit {reloaded.status}")
    for unit in PERSONAL_USER_UNITS:
        if query_load(context, unit, user=True) != "loaded":
            raise AdapterFailure(1, f"mapped user unit did not load after daemon-reload: {unit}")
    return Outcome(
        action.action_id,
        "applied",
        True,
        prior={"files_verified": list(PERSONAL_USER_UNITS)},
        result={"daemon_reloaded": True},
    )


def execute_network(
    context: ExecutionContext,
    action: Action,
    installed: dict[str, str],
    wrapper: Path,
) -> Outcome:
    require_action_packages(action, installed)
    inspect_network_xml(context, allow_pending=False)
    prior_info = query_network_info(context)
    prior = prior_info or {"defined": False, "active": False, "autostart": False}
    virsh = command_path("virsh", context)
    assert virsh is not None
    changed = False
    if prior_info is None:
        run_root(
            wrapper,
            [virsh, "--connect", "qemu:///system", "net-define", target_path(context, NETWORK_XML)],
            "define fixed libvirt default network",
        )
        changed = True
    current = query_network_info(context)
    if current is None:
        raise AdapterFailure(1, "default network remained undefined after net-define")
    if not current["active"]:
        run_root(
            wrapper,
            [virsh, "--connect", "qemu:///system", "net-start", "default"],
            "start fixed libvirt default network",
        )
        changed = True
    current = query_network_info(context)
    assert current is not None
    if not current["autostart"]:
        run_root(
            wrapper,
            [virsh, "--connect", "qemu:///system", "net-autostart", "default"],
            "autostart fixed libvirt default network",
        )
        changed = True
    final = query_network_info(context)
    if final != {"defined": True, "active": True, "autostart": True}:
        raise AdapterFailure(1, "default network did not verify persistent, active, and autostart")
    return Outcome(action.action_id, "applied" if changed else "unchanged", True, prior=prior, result=final)


def execute_locale(
    context: ExecutionContext,
    action: Action,
    wrapper: Path,
    run_dir: Path,
) -> Outcome:
    locale_gen = snapshot_fixed(context, LOCALE_GEN, "locale.gen", allow_missing=False)
    locale_conf = snapshot_fixed(context, LOCALE_CONF, "locale.conf", allow_missing=True)
    assert locale_gen.data is not None
    files_match = locale_gen.data == desired_locale_gen(locale_gen.data) and (
        locale_conf.data if locale_conf.exists else b""
    ) == desired_locale_conf()
    locales_ready = query_locales(context)
    prior = {
        "locale_gen": locale_gen.state_document(),
        "locale_conf": locale_conf.state_document(),
        "locales_available": locales_ready,
    }
    if files_match and locales_ready:
        return Outcome(action.action_id, "unchanged", True, prior=prior, result={"locales_available": True})
    locale_gen_backup = backup_snapshot(run_dir, locale_gen, LOCALE_GEN)
    locale_conf_backup = backup_snapshot(run_dir, locale_conf, LOCALE_CONF)
    prior["locale_gen"]["backup"] = locale_gen_backup
    prior["locale_conf"]["backup"] = locale_conf_backup
    helper_result = run_command(
        [
            wrapper,
            "--",
            SCRIPT_PATH,
            "--root-helper",
            "locale",
            "--target-root",
            context.target_root,
            "--expected-locale-gen",
            locale_gen.expected_token,
            "--expected-locale-conf",
            locale_conf.expected_token,
        ]
    )
    if helper_result.status != 0:
        evidence = write_evidence(run_dir, "locale-gen.txt", helper_result)
        error = AdapterFailure(helper_result.status, f"locale helper through gsudo failed with exit {helper_result.status}")
        setattr(error, "prior", prior)
        setattr(error, "result", {"evidence": os.fspath(evidence), "automatic_rollback": False})
        raise error
    final_gen = snapshot_fixed(context, LOCALE_GEN, "locale.gen", allow_missing=False)
    final_conf = snapshot_fixed(context, LOCALE_CONF, "locale.conf", allow_missing=False)
    assert final_gen.data is not None and final_conf.data is not None
    if final_gen.data != desired_locale_gen(final_gen.data) or final_conf.data != desired_locale_conf() or not query_locales(context):
        raise AdapterFailure(1, "locale files/locales did not verify after helper")
    return Outcome(
        action.action_id,
        "applied",
        True,
        prior=prior,
        result={"locales_available": True, "automatic_rollback": False},
    )


def execute_environment(
    context: ExecutionContext,
    action: Action,
    wrapper: Path,
    run_dir: Path,
) -> Outcome:
    snapshot = snapshot_fixed(context, ENVIRONMENT_FILE, "environment", allow_missing=True)
    desired = desired_environment(snapshot)
    prior = {"environment": snapshot.state_document()}
    current = snapshot.data if snapshot.exists else b""
    if current == desired:
        return Outcome(action.action_id, "unchanged", True, prior=prior, result={"reviewed_assignments": True})
    backup = backup_snapshot(run_dir, snapshot, ENVIRONMENT_FILE)
    prior["environment"]["backup"] = backup
    run_root(
        wrapper,
        [
            SCRIPT_PATH,
            "--root-helper",
            "environment",
            "--target-root",
            context.target_root,
            "--expected-environment",
            snapshot.expected_token,
        ],
        "write fixed system environment target",
    )
    final = snapshot_fixed(context, ENVIRONMENT_FILE, "environment", allow_missing=False)
    if final.data != desired_environment(final):
        raise AdapterFailure(1, "/etc/environment did not verify after helper")
    return Outcome(
        action.action_id,
        "applied",
        True,
        prior=prior,
        result={"reviewed_assignments": True, "automatic_rollback": False},
    )


def verify_read_only_action(
    context: ExecutionContext,
    stage: Stage,
    action: Action,
    installed: dict[str, str],
) -> Outcome:
    if action.conflict_set:
        check_conflict(context, stage.conflicts[action.conflict_set], installed)
    if action.action_id == "base-network-handoff":
        query_network(context)
        return Outcome(action.action_id, "verified", True)
    if action.action_id == "base-package-preconditions":
        missing = [row.package for row in stage.verify_packages if row.package not in installed]
        if missing:
            raise AdapterFailure(1, f"verify-only package(s) missing: {','.join(missing)}")
        return Outcome(action.action_id, "verified", True, result={"packages": len(stage.verify_packages)})
    if action.action_id == "failed-unit-baseline":
        failed = query_failed_units(context, user=False) + query_failed_units(context, user=True)
        if failed:
            raise AdapterFailure(1, f"failed-unit arrays are nonempty: {','.join(failed)}")
        return Outcome(action.action_id, "verified", True, result={"failed_units": []})
    if action.action_id == "audio-package-activation":
        require_action_packages(action, installed)
        for unit in action.target.split(","):
            if not query_enabled(context, unit, global_scope=True):
                raise AdapterFailure(1, f"package-owned audio unit is not globally enabled: {unit}")
        classification = "pending" if not graphical_session_available() else "verified"
        return Outcome(action.action_id, classification, True, result={"clean_login_check": classification})
    if action.action_id == "portal-package-activation":
        require_action_packages(action, installed)
        classification = "pending" if not graphical_session_available() else "pending"
        return Outcome(action.action_id, classification, True, message="interactive portal acceptance remains pending")
    if action.action_id in {"fcitx-session-owner", "blueman-session-owner"}:
        require_action_packages(action, installed)
        return Outcome(action.action_id, "pending", True, message="clean graphical login ownership check remains pending")
    if action.action_id == "kernel-dkms-verification":
        require_action_packages(action, installed)
        return Outcome(action.action_id, "pending", True, message="running-kernel DKMS/reboot acceptance remains pending")
    if action.action_id == "asusd-package-activation":
        require_action_packages(action, installed)
        if query_load(context, "asusd.service") != "loaded" or not query_active(context, "asusd.service"):
            raise AdapterFailure(1, "package-owned asusd.service is not loaded and active")
        return Outcome(action.action_id, "verified", True)
    if action.action_id == "relogin-reboot-report":
        return Outcome(action.action_id, "pending", True, message="relogin/reboot remains user-controlled")
    return Outcome(action.action_id, "pending", True, message="non-changing acceptance remains pending")


def graphical_session_available() -> bool:
    return bool(os.environ.get("WAYLAND_DISPLAY") and os.environ.get("XDG_CURRENT_DESKTOP"))


def execute_apply_action(
    context: ExecutionContext,
    stage: Stage,
    action: Action,
    installed: dict[str, str],
    wrapper: Path,
    run_dir: Path,
) -> Outcome:
    if action.conflict_set:
        check_conflict(context, stage.conflicts[action.conflict_set], installed)
    if action.handler == "enable-system-unit":
        return execute_system_unit(context, action, installed, wrapper)
    if action.handler == "add-user-wants":
        return execute_user_wants(context, action, installed)
    if action.handler == "enable-user-unit":
        return execute_user_service(context, action, installed)
    if action.handler == "daemon-reload-user":
        return execute_user_reload(context, action)
    if action.handler == "ensure-libvirt-network":
        return execute_network(context, action, installed, wrapper)
    if action.handler == "manage-locale":
        return execute_locale(context, action, wrapper, run_dir)
    if action.handler == "manage-environment":
        return execute_environment(context, action, wrapper, run_dir)
    fail(f"internal error: unsupported apply handler {action.handler}")


def execute(context: ExecutionContext, stage: Stage) -> int:
    if os.geteuid() == 0:
        fail("system-actions adapter main process must run as an ordinary user", 1)
    # All manifest/effect validation happened before this first write.  State is
    # also validated before any changing command.
    installed = query_package_inventory(context)
    wrapper = require_root_wrapper(context)
    assert wrapper is not None
    run_dir, state_path, state = load_or_create_state(stage)
    outcomes: dict[str, Outcome] = {}
    first_status = 0
    for action in stage.actions:
        failed_dependencies = [
            dependency
            for dependency in action.requires
            if dependency in outcomes and not outcomes[dependency].success
        ]
        if action.disposition == "apply" and failed_dependencies:
            outcome = Outcome(
                action.action_id,
                "skipped-dependency",
                False,
                1,
                result={"failed_dependencies": failed_dependencies},
                message="dependency failed",
            )
        elif action.disposition == "manual":
            outcome = Outcome(action.action_id, "manual", True, message="manual action intentionally not executed")
        elif action.disposition == "deferred":
            outcome = Outcome(action.action_id, "deferred", True, message="deferred action intentionally not executed")
        else:
            try:
                if action.disposition == "verify":
                    outcome = verify_read_only_action(context, stage, action, installed)
                else:
                    outcome = execute_apply_action(context, stage, action, installed, wrapper, run_dir)
            except AdapterFailure as error:
                prior = getattr(error, "prior", None)
                result = getattr(error, "result", None)
                outcome = Outcome(
                    action.action_id,
                    "failed",
                    False,
                    error.status,
                    prior=prior,
                    result=result,
                    message=error.message,
                )
        outcomes[action.action_id] = outcome
        if not outcome.success and first_status == 0:
            first_status = outcome.status or 1
        save_outcome(state_path, state, action, outcome)
        emit(
            "action-result",
            action_id=action.action_id,
            classification=outcome.classification,
            disposition=action.disposition,
            exit_status=outcome.status,
            message=outcome.message,
        )
    emit("stage", action="execute", classification="completed" if not first_status else "failed", exit_status=first_status)
    return first_status


def verify_apply_action(
    context: ExecutionContext,
    action: Action,
    installed: dict[str, str],
) -> Outcome:
    require_action_packages(action, installed)
    if action.handler == "enable-system-unit":
        if action.action_id == "bluetooth-service":
            controller = query_bluetooth(context)
            if controller == "none":
                return Outcome(action.action_id, "not-applicable", True, result={"controller": "none"})
        unit = SYSTEM_UNIT_ACTIONS[action.action_id]
        result = verify_system_unit(context, action.action_id, unit)
        return Outcome(action.action_id, "verified", True, result=result)
    if action.handler == "add-user-wants":
        if not query_wants(context):
            raise AdapterFailure(1, "dms.service wants link drifted")
        return Outcome(action.action_id, "verified", True)
    if action.handler == "enable-user-unit":
        if not query_enabled(context, "dsearch.service", user=True) or not query_active(context, "dsearch.service", user=True):
            raise AdapterFailure(1, "dsearch.service drifted")
        return Outcome(action.action_id, "verified", True)
    if action.handler == "daemon-reload-user":
        inspect_user_unit_files(require_present=True)
        for unit in PERSONAL_USER_UNITS:
            if query_load(context, unit, user=True) != "loaded":
                raise AdapterFailure(1, f"mapped user unit drifted: {unit}")
        return Outcome(action.action_id, "verified", True)
    if action.handler == "ensure-libvirt-network":
        inspect_network_xml(context, allow_pending=False)
        info = query_network_info(context)
        if info != {"defined": True, "active": True, "autostart": True}:
            raise AdapterFailure(1, "libvirt default network drifted")
        return Outcome(action.action_id, "verified", True, result=info)
    if action.handler == "manage-locale":
        locale_gen = snapshot_fixed(context, LOCALE_GEN, "locale.gen", allow_missing=False)
        locale_conf = snapshot_fixed(context, LOCALE_CONF, "locale.conf", allow_missing=False)
        assert locale_gen.data is not None and locale_conf.data is not None
        if locale_gen.data != desired_locale_gen(locale_gen.data) or locale_conf.data != desired_locale_conf() or not query_locales(context):
            raise AdapterFailure(1, "managed locale state drifted")
        return Outcome(action.action_id, "verified", True)
    if action.handler == "manage-environment":
        environment = snapshot_fixed(context, ENVIRONMENT_FILE, "environment", allow_missing=False)
        if environment.data != desired_environment(environment):
            raise AdapterFailure(1, "managed environment state drifted")
        return Outcome(action.action_id, "verified", True)
    fail(f"internal error: unsupported verify handler {action.handler}")


def inspect_optional_state(stage: Stage) -> None:
    path = state_root() / stage.run_id / "actions.json"
    if not path.exists() and not path.is_symlink():
        return
    # Verification never creates a state path, but an existing one must be
    # parseable and bound to this exact plan.
    data, info = read_regular(path, "action state", require_owner=os.geteuid())
    if stat.S_IMODE(info.st_mode) != 0o600:
        fail("action state must be mode 600", 1)
    try:
        document = json.loads(data)
    except (json.JSONDecodeError, UnicodeDecodeError) as error:
        fail(f"action state is malformed: {error}")
    if (
        not isinstance(document, dict)
        or document.get("plan_fingerprint") != stage.fingerprint
        or document.get("run_id") != stage.run_id
        or not isinstance(document.get("actions"), dict)
    ):
        fail("action state is not bound to the current plan")


def verify(context: ExecutionContext, stage: Stage) -> int:
    if os.geteuid() == 0:
        fail("system-actions adapter main process must run as an ordinary user", 1)
    inspect_optional_state(stage)
    installed = query_package_inventory(context)
    first_status = 0
    outcomes: dict[str, Outcome] = {}
    for action in stage.actions:
        try:
            if action.conflict_set:
                check_conflict(context, stage.conflicts[action.conflict_set], installed)
            if action.disposition == "apply":
                outcome = verify_apply_action(context, action, installed)
            elif action.disposition == "verify":
                outcome = verify_read_only_action(context, stage, action, installed)
            elif action.disposition == "manual":
                outcome = Outcome(action.action_id, "pending", True, message="manual acceptance remains pending")
            else:
                outcome = Outcome(action.action_id, "pending", True, message="deferred boundary remains pending")
        except AdapterFailure as error:
            outcome = Outcome(action.action_id, "failed", False, error.status, message=error.message)
        outcomes[action.action_id] = outcome
        if not outcome.success and first_status == 0:
            first_status = outcome.status or 1
        emit(
            "action-result",
            action_id=action.action_id,
            classification=outcome.classification,
            disposition=action.disposition,
            exit_status=outcome.status,
            message=outcome.message,
        )
    emit("stage", action="verify", classification="completed" if not first_status else "failed", exit_status=first_status)
    return first_status


def validate_expected_token(raw: str, label: str) -> str | None:
    if raw == "absent":
        return None
    if raw.startswith("sha256:") and HEX64_RE.fullmatch(raw.removeprefix("sha256:")):
        return raw.removeprefix("sha256:")
    fail(f"root helper received malformed {label} expected state")


def helper_snapshot(
    context: ExecutionContext,
    absolute: Path,
    label: str,
    expected_raw: str,
    *,
    allow_missing: bool,
) -> FileSnapshot:
    expected = validate_expected_token(expected_raw, label)
    snapshot = snapshot_fixed(context, absolute, label, allow_missing=allow_missing)
    if expected is None:
        if snapshot.exists:
            raise AdapterFailure(1, f"{label} appeared after ordinary-user backup")
    elif not snapshot.exists or snapshot.sha256 != expected:
        raise AdapterFailure(1, f"{label} changed after ordinary-user backup")
    return snapshot


def atomic_replace_fixed(path: Path, data: bytes, prior: FileSnapshot, context: ExecutionContext) -> None:
    parent = path.parent
    if prior.exists:
        assert prior.mode is not None and prior.uid is not None and prior.gid is not None
        mode, uid, gid = prior.mode, prior.uid, prior.gid
    else:
        mode, uid, gid = 0o644, context.owner_uid, context.owner_gid
    temporary: Path | None = None
    fd: int | None = None
    try:
        fd, name = tempfile.mkstemp(prefix=f".{path.name}.", dir=parent)
        temporary = Path(name)
        os.fchmod(fd, mode)
        os.fchown(fd, uid, gid)
        offset = 0
        while offset < len(data):
            offset += os.write(fd, data[offset:])
        os.fsync(fd)
        os.close(fd)
        fd = None
        conditional_replace_fixed(temporary, path, prior)
        temporary = None
        fsync_directory(parent)
    except AdapterFailure as error:
        if getattr(error, "preserve_temporary", False):
            temporary = None
        raise
    except OSError as error:
        raise AdapterFailure(1, f"atomic write failed for fixed target {path}: {error}") from error
    finally:
        if fd is not None:
            os.close(fd)
        if temporary is not None:
            try:
                os.unlink(temporary)
            except FileNotFoundError:
                pass


def root_helper(argv: Sequence[str]) -> int:
    parser = argparse.ArgumentParser(add_help=False, allow_abbrev=False)
    parser.add_argument("--root-helper", action="store_true", required=True)
    parser.add_argument("operation", choices=("locale", "environment"))
    parser.add_argument("--target-root", type=Path, required=True)
    parser.add_argument("--expected-locale-gen")
    parser.add_argument("--expected-locale-conf")
    parser.add_argument("--expected-environment")
    args = parser.parse_args(argv)
    context = load_context()
    requested_root = lexical_absolute(args.target_root)
    if requested_root != context.target_root:
        fail("root helper target root differs from fixed execution context")
    if context.testing:
        if os.geteuid() == 0:
            fail("test-mode root helper must not run as root")
    elif os.geteuid() != 0 or requested_root != Path("/"):
        fail("production root helper requires EUID 0 and target root /", 1)
    if args.operation == "locale":
        if args.expected_locale_gen is None or args.expected_locale_conf is None or args.expected_environment is not None:
            fail("locale root helper received a non-exact argument set")
        locale_gen = helper_snapshot(
            context, LOCALE_GEN, "locale.gen", args.expected_locale_gen, allow_missing=False
        )
        locale_conf = helper_snapshot(
            context, LOCALE_CONF, "locale.conf", args.expected_locale_conf, allow_missing=True
        )
        assert locale_gen.data is not None
        new_gen = desired_locale_gen(locale_gen.data)
        new_conf = desired_locale_conf()
        if locale_gen.data != new_gen:
            atomic_replace_fixed(locale_gen.path, new_gen, locale_gen, context)
        if (locale_conf.data if locale_conf.exists else b"") != new_conf:
            atomic_replace_fixed(locale_conf.path, new_conf, locale_conf, context)
        final_gen = snapshot_fixed(context, LOCALE_GEN, "locale.gen", allow_missing=False)
        final_conf = snapshot_fixed(context, LOCALE_CONF, "locale.conf", allow_missing=False)
        assert final_gen.data is not None and final_conf.data is not None
        if final_gen.data != desired_locale_gen(final_gen.data) or final_conf.data != new_conf:
            raise AdapterFailure(1, "locale root-helper post-write verification failed")
        locale_gen_command = command_path("locale-gen", context)
        assert locale_gen_command is not None
        generated = run_command([locale_gen_command])
        if generated.stdout:
            print(generated.stdout, end="")
        if generated.stderr:
            print(generated.stderr, end="", file=sys.stderr)
        if generated.status != 0:
            return generated.status
        return 0
    if args.expected_environment is None or args.expected_locale_gen is not None or args.expected_locale_conf is not None:
        fail("environment root helper received a non-exact argument set")
    environment = helper_snapshot(
        context, ENVIRONMENT_FILE, "environment", args.expected_environment, allow_missing=True
    )
    desired = desired_environment(environment)
    if (environment.data if environment.exists else b"") != desired:
        atomic_replace_fixed(environment.path, desired, environment, context)
    final = snapshot_fixed(context, ENVIRONMENT_FILE, "environment", allow_missing=False)
    if final.data != desired_environment(final):
        raise AdapterFailure(1, "environment root-helper post-write verification failed")
    return 0


def ordinary_main(argv: Sequence[str]) -> int:
    if argv:
        fail("system-actions adapter accepts no ordinary command-line arguments")
    if os.geteuid() == 0:
        fail("system-actions adapter main process must run as an ordinary user", 1)
    stage = load_stage()
    context = load_context()
    if stage.action == "preflight":
        return preflight(context, stage)
    if stage.action == "execute":
        return execute(context, stage)
    return verify(context, stage)


def dispatch(argv: Sequence[str]) -> int:
    if argv and argv[0] == "--root-helper":
        return root_helper(argv)
    return ordinary_main(argv)


def main() -> None:
    try:
        status = dispatch(sys.argv[1:])
    except AdapterFailure as error:
        print(
            json.dumps(
                {
                    "event": "adapter-error",
                    "classification": "unavailable" if error.status != 1 else "blocker",
                    "exit_status": error.status,
                    "message": error.message,
                },
                ensure_ascii=True,
                sort_keys=True,
                separators=(",", ":"),
            ),
            file=sys.stderr,
        )
        raise SystemExit(error.status) from error
    except KeyboardInterrupt as error:
        print('{"classification":"interrupted","event":"adapter-error","exit_status":130}', file=sys.stderr)
        raise SystemExit(130) from error
    raise SystemExit(status)


if __name__ == "__main__":
    main()
