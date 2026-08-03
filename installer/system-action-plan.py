#!/usr/bin/env python3
"""Render the reviewed post-package system/service action policy without applying it."""

from __future__ import annotations

import argparse
import csv
import json
import os
import re
import stat
import sys
from collections import Counter
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any, Iterable, NoReturn, Sequence

PROJECT_ROOT = Path(__file__).resolve().parent.parent
MODULES_PATH = PROJECT_ROOT / "manifests/modules.tsv"
PROFILES_PATH = PROJECT_ROOT / "manifests/profile-modules.tsv"
ACTIONS_PATH = PROJECT_ROOT / "manifests/system-actions.tsv"
CONFLICTS_PATH = PROJECT_ROOT / "manifests/system-action-conflicts.tsv"
KNOWN_PROFILES = frozenset({"asus-amd-nvidia", "desktop-amd", "vm"})
TOKEN_RE = re.compile(r"[a-z0-9][a-z0-9-]*")
PACKAGE_RE = re.compile(r"[a-z0-9@._+:-]+")
UNIT_RE = re.compile(r"[A-Za-z0-9@_.:-]+")
DISPOSITIONS = frozenset({"apply", "verify", "manual", "deferred"})
PRIVILEGES = frozenset({"none", "user", "root"})
HANDLERS = frozenset(
    {
        "verify-network-handoff",
        "verify-policy-packages",
        "verify-failed-units",
        "enable-system-unit",
        "verify-package-owned-audio",
        "verify-package-owned-portals",
        "verify-session-owner",
        "add-user-wants",
        "enable-user-unit",
        "daemon-reload-user",
        "ensure-libvirt-network",
        "manage-locale",
        "manage-environment",
        "verify-kernel-support",
        "verify-package-activation",
        "report-manual",
        "report-deferred",
        "report-relogin-reboot",
    }
)
APPLICABILITY = frozenset(
    {
        "always",
        "graphical-session-optional",
        "bluetooth-controller-optional",
        "power-profiles-supported",
        "niri-selected",
        "dsearch-installed",
        "files-deployed",
        "package-installed",
        "libvirtd-ready",
        "physical-input-selected",
        "input-selected",
        "physical-kernel",
        "exact-asus-hardware",
        "btrfs-root-home",
        "manual-boot-boundary",
        "root-equivalent-group",
        "privileged-group",
        "workload-specific",
        "manual-login-boundary",
    }
)


class PlanError(Exception):
    pass


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
    offered: tuple[str, ...]
    defaults: tuple[str, ...]


@dataclass(frozen=True)
class ConflictSet:
    conflict_id: str
    packages: tuple[str, ...]
    system_units: tuple[str, ...]
    user_units: tuple[str, ...]
    behavior: str
    purpose: str


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

    def document(self) -> dict[str, Any]:
        return {
            "id": self.action_id,
            "module": self.module,
            "profiles": list(self.profiles),
            "disposition": self.disposition,
            "privilege": self.privilege,
            "handler": self.handler,
            "target": self.target,
            "applicability": self.applicability,
            "conflict_set": self.conflict_set,
            "requires": list(self.requires),
            "rollback": self.rollback,
            "post_check": self.post_check,
            "purpose": self.purpose,
            "evidence": self.evidence,
        }


def fail(message: str) -> NoReturn:
    raise PlanError(message)


def safe_lines(path: Path, schema: str, label: str) -> list[str]:
    try:
        info = path.lstat()
    except OSError as exc:
        fail(f"could not inspect {label}: {exc}")
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
        fail(f"{label} is missing or unsafe")
    if info.st_uid != os.geteuid() or info.st_mode & 0o022:
        fail(f"{label} ownership or mode is unsafe")
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError) as exc:
        fail(f"could not read {label}: {exc}")
    if not lines or lines[0] != schema:
        fail(f"{label} has an unsupported schema")
    return lines


def data_rows(path: Path, schema: str, label: str, fields: int) -> Iterable[tuple[int, list[str]]]:
    lines = safe_lines(path, schema, label)
    for line_number, parts in enumerate(csv.reader(lines[1:], delimiter="\t"), 2):
        if not parts or not parts[0] or parts[0].startswith("#"):
            continue
        if len(parts) != fields or not all(parts):
            fail(f"{label} has an invalid row at line {line_number}")
        if any(any(ord(character) < 32 for character in value) for value in parts):
            fail(f"{label} has a control character at line {line_number}")
        yield line_number, parts


def parse_tokens(raw: str, owner: str, label: str, pattern: re.Pattern[str] = TOKEN_RE) -> tuple[str, ...]:
    if raw == "-":
        return ()
    values = tuple(raw.split(","))
    if not values or any(pattern.fullmatch(value) is None for value in values):
        fail(f"{owner} has an invalid {label} list")
    if len(values) != len(set(values)):
        fail(f"{owner} repeats a {label} entry")
    return values


def load_modules() -> dict[str, Module]:
    result: dict[str, Module] = {}
    for line_number, parts in data_rows(MODULES_PATH, "# schema=1", "module registry", 6):
        module_id, availability, kind, requires_all, requires_any, _purpose = parts
        if TOKEN_RE.fullmatch(module_id) is None or module_id in result:
            fail(f"module registry has an unsafe or duplicate id at line {line_number}")
        if availability not in {"available", "planning", "unavailable"} or kind not in {"selectable", "dependency"}:
            fail(f"module registry has invalid state at line {line_number}")
        result[module_id] = Module(
            module_id,
            availability,
            kind,
            parse_tokens(requires_all, module_id, "requires-all"),
            parse_tokens(requires_any, module_id, "requires-any"),
        )
    if not result:
        fail("module registry is empty")
    for module in result.values():
        for dependency in (*module.requires_all, *module.requires_any):
            if dependency not in result:
                fail(f"module {module.module_id} references unknown dependency {dependency}")
    visiting: set[str] = set()
    visited: set[str] = set()

    def visit(module_id: str) -> None:
        if module_id in visiting:
            fail(f"module requires-all dependency cycle includes {module_id}")
        if module_id in visited:
            return
        visiting.add(module_id)
        for dependency in result[module_id].requires_all:
            visit(dependency)
        visiting.remove(module_id)
        visited.add(module_id)

    for module_id in result:
        visit(module_id)
    return result


def load_profiles(modules: dict[str, Module]) -> dict[str, Profile]:
    rows: dict[str, list[tuple[str, str]]] = {}
    seen: set[tuple[str, str]] = set()
    for line_number, parts in data_rows(PROFILES_PATH, "# schema=1", "profile module manifest", 4):
        profile, _scope, module, state = parts
        if profile not in KNOWN_PROFILES or module not in modules or state not in {"selected", "disabled"}:
            fail(f"profile module manifest has an invalid row at line {line_number}")
        if modules[module].kind != "selectable":
            fail(f"profile exposes dependency-only module at line {line_number}")
        key = (profile, module)
        if key in seen:
            fail(f"profile module manifest repeats {profile}/{module}")
        seen.add(key)
        rows.setdefault(profile, []).append((module, state))
    if set(rows) != KNOWN_PROFILES:
        fail("profile module manifest does not define the exact profile set")
    module_order = tuple(modules)
    return {
        profile: Profile(
            profile,
            tuple(module for module in module_order if any(row[0] == module for row in values)),
            tuple(module for module in module_order if any(row == (module, "selected") for row in values)),
        )
        for profile, values in rows.items()
    }


def resolve_modules(raw: str | None, profile: Profile, modules: dict[str, Module]) -> tuple[tuple[str, ...], tuple[str, ...], str]:
    if raw is None:
        requested = profile.defaults
        source = "profile-defaults"
    elif raw == "none":
        requested = ()
        source = "explicit--modules"
    else:
        requested = tuple(raw.split(","))
        source = "explicit--modules"
        if not requested or any(TOKEN_RE.fullmatch(value) is None for value in requested):
            fail("--modules is malformed")
        if len(requested) != len(set(requested)):
            fail("--modules contains a duplicate")
        unsupported = [module for module in requested if module not in profile.offered]
        if unsupported:
            fail(f"profile {profile.name} does not offer module(s): {','.join(unsupported)}")
    selected = set(requested)
    pending = list(requested)
    while pending:
        module_id = pending.pop(0)
        for dependency in modules[module_id].requires_all:
            if dependency not in selected:
                selected.add(dependency)
                pending.append(dependency)
    order = tuple(module for module in modules if module in selected)
    for module_id in order:
        choices = modules[module_id].requires_any
        if choices and not any(choice in selected for choice in choices):
            fail(f"module {module_id} requires one of: {','.join(choices)}")
    return requested, order, source


def load_conflicts() -> dict[str, ConflictSet]:
    result: dict[str, ConflictSet] = {}
    for line_number, parts in data_rows(CONFLICTS_PATH, "# schema=1", "system action conflict manifest", 6):
        conflict_id, packages, system_units, user_units, behavior, purpose = parts
        if TOKEN_RE.fullmatch(conflict_id) is None or conflict_id in result:
            fail(f"conflict manifest has an unsafe or duplicate id at line {line_number}")
        if behavior not in {"block-active-or-installed", "block-active", "block-managed-paths"}:
            fail(f"conflict manifest has an invalid behavior at line {line_number}")
        result[conflict_id] = ConflictSet(
            conflict_id,
            parse_tokens(packages, conflict_id, "package", PACKAGE_RE),
            parse_tokens(system_units, conflict_id, "system unit", UNIT_RE),
            parse_tokens(user_units, conflict_id, "user unit", UNIT_RE),
            behavior,
            purpose,
        )
    if not result:
        fail("system action conflict manifest is empty")
    return result


def parse_profiles(raw: str, owner: str) -> tuple[str, ...]:
    if raw == "all":
        return tuple(sorted(KNOWN_PROFILES))
    profiles = tuple(raw.split(","))
    if not profiles or len(profiles) != len(set(profiles)) or not set(profiles).issubset(KNOWN_PROFILES):
        fail(f"action {owner} has an invalid profile list")
    return profiles


def load_actions(modules: dict[str, Module], conflicts: dict[str, ConflictSet]) -> tuple[Action, ...]:
    actions: list[Action] = []
    seen: set[str] = set()
    for line_number, parts in data_rows(ACTIONS_PATH, "# schema=1", "system action manifest", 14):
        (
            action_id,
            module,
            profiles,
            disposition,
            privilege,
            handler,
            target,
            applicability,
            conflict_set,
            requires,
            rollback,
            post_check,
            purpose,
            evidence,
        ) = parts
        if TOKEN_RE.fullmatch(action_id) is None or action_id in seen:
            fail(f"system action manifest has an unsafe or duplicate id at line {line_number}")
        if module not in modules:
            fail(f"system action {action_id} references unknown module")
        if disposition not in DISPOSITIONS or privilege not in PRIVILEGES or handler not in HANDLERS:
            fail(f"system action {action_id} has an invalid disposition/privilege/handler")
        if applicability not in APPLICABILITY:
            fail(f"system action {action_id} has an unknown applicability gate")
        conflict = None if conflict_set == "-" else conflict_set
        if conflict is not None and conflict not in conflicts:
            fail(f"system action {action_id} references unknown conflict set {conflict}")
        if disposition == "apply" and privilege == "none":
            fail(f"changing action {action_id} lacks an explicit user/root privilege")
        if disposition != "apply" and handler in {
            "enable-system-unit",
            "add-user-wants",
            "enable-user-unit",
            "daemon-reload-user",
            "ensure-libvirt-network",
            "manage-locale",
            "manage-environment",
        }:
            fail(f"non-apply action {action_id} uses a changing handler")
        action = Action(
            action_id,
            module,
            parse_profiles(profiles, action_id),
            disposition,
            privilege,
            handler,
            target,
            applicability,
            conflict,
            parse_tokens(requires, action_id, "action dependency"),
            rollback,
            post_check,
            purpose,
            evidence,
        )
        actions.append(action)
        seen.add(action_id)
    if not actions:
        fail("system action manifest is empty")
    by_id = {action.action_id: action for action in actions}
    for action in actions:
        for dependency in action.requires:
            if dependency not in by_id:
                fail(f"system action {action.action_id} references unknown dependency {dependency}")
            if dependency == action.action_id:
                fail(f"system action {action.action_id} depends on itself")
    visiting: set[str] = set()
    visited: set[str] = set()

    def visit(action_id: str) -> None:
        if action_id in visiting:
            fail(f"system action dependency cycle includes {action_id}")
        if action_id in visited:
            return
        visiting.add(action_id)
        for dependency in by_id[action_id].requires:
            visit(dependency)
        visiting.remove(action_id)
        visited.add(action_id)

    for action in actions:
        visit(action.action_id)
    return tuple(actions)


def build_plan(profile: Profile, requested: tuple[str, ...], selected_modules: tuple[str, ...], source: str, actions: tuple[Action, ...], conflicts: dict[str, ConflictSet]) -> dict[str, Any]:
    module_set = set(selected_modules)
    selected = tuple(action for action in actions if action.module in module_set and profile.name in action.profiles)
    selected_ids = {action.action_id for action in selected}
    blockers = [
        f"action {action.action_id} requires selected action {dependency}"
        for action in selected
        for dependency in action.requires
        if dependency not in selected_ids
    ]
    counts = Counter(action.disposition for action in selected)
    document_counts = {
        "selected": len(selected),
        "apply": counts["apply"],
        "verify": counts["verify"],
        "manual": counts["manual"],
        "deferred": counts["deferred"],
        "root_apply": sum(action.disposition == "apply" and action.privilege == "root" for action in selected),
        "user_apply": sum(action.disposition == "apply" and action.privilege == "user" for action in selected),
    }
    status = "blocked" if blockers else "ready"
    selected_conflicts = sorted({action.conflict_set for action in selected if action.conflict_set is not None})
    return {
        "schema": 1,
        "profile": profile.name,
        "selection": {
            "source": source,
            "requested_modules": list(requested),
            "resolved_modules": list(selected_modules),
        },
        "counts": document_counts,
        "actions": [action.document() for action in selected],
        "conflict_sets": {name: asdict(conflicts[name]) for name in selected_conflicts},
        "overall": {"status": status, "blockers": blockers, "unavailable_checks": []},
        "apply": {"authorized": False, "commands": None},
        "safety": {
            "read_only": True,
            "apply_authorized": False,
            "installer_apply_integration": False,
            "system_changes": False,
        },
    }


def render_text(plan: dict[str, Any]) -> None:
    print("Reviewed system/service action plan (read-only)")
    print(f"Profile: {plan['profile']}")
    print(f"Overall: {plan['overall']['status']}")
    print(f"Selected actions: {plan['counts']['selected']}")
    for action in plan["actions"]:
        print(
            f"  [{action['disposition']}/{action['privilege']}/{action['handler']}] "
            f"{action['id']} -> {action['target']}"
        )
    for blocker in plan["overall"]["blockers"]:
        print(f"BLOCKED: {blocker}")
    print("Apply authorization: false; commands: none")


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", required=True, choices=sorted(KNOWN_PROFILES))
    parser.add_argument("--modules", help="exact comma-separated selectable modules, or none")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args(argv)
    try:
        modules = load_modules()
        profiles = load_profiles(modules)
        requested, selected, source = resolve_modules(args.modules, profiles[args.profile], modules)
        conflicts = load_conflicts()
        actions = load_actions(modules, conflicts)
        plan = build_plan(profiles[args.profile], requested, selected, source, actions, conflicts)
    except PlanError as exc:
        print(f"system-action-plan: {exc}", file=sys.stderr)
        return 2
    if args.json:
        json.dump(plan, sys.stdout, indent=2, sort_keys=True)
        print()
    else:
        render_text(plan)
    return 0 if plan["overall"]["status"] == "ready" else 1


if __name__ == "__main__":
    raise SystemExit(main())
