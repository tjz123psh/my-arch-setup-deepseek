#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import json
import shutil
import subprocess
import sys
from collections import Counter, defaultdict
from dataclasses import asdict, dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PHASE_C_MANIFEST = ROOT / "manifests/phase-c-package-candidates.tsv"
PROFILE_MODULES = ROOT / "manifests/profile-modules.tsv"
MODULES = ROOT / "manifests/modules.tsv"

SOURCES = {"official", "unavailable-official", "archlinuxcn"}
DISPOSITIONS = {
    "precondition",
    "proposed",
    "optional",
    "pending-decision",
    "transitive",
    "excluded",
    "blocked-third-party",
}
ACTIONABLE_DISPOSITIONS = {"precondition", "proposed", "optional", "pending-decision", "transitive"}


@dataclass(frozen=True)
class Candidate:
    module: str
    package: str
    source: str
    disposition: str
    applicability: str
    future_service_action: str
    blocker: str
    purpose: str


@dataclass(frozen=True)
class PackageStatus:
    package: str
    status: str
    query_exit: int | None


def fail(message: str) -> None:
    print(f"phase-c-plan: {message}", file=sys.stderr)
    raise SystemExit(1)


def require_safe_manifest(path: Path, schema: str, label: str) -> list[str]:
    if not path.is_file() or path.is_symlink():
        fail(f"{label} is missing or unsafe: {path.relative_to(ROOT)}")
    lines = path.read_text().splitlines()
    if not lines or lines[0] != schema:
        fail(f"{label} has unsupported or missing schema")
    return lines


def validate_token(value: str, label: str, line_number: int) -> None:
    allowed = set("abcdefghijklmnopqrstuvwxyz0123456789@._:+,-")
    if not value or value[0] not in "abcdefghijklmnopqrstuvwxyz0123456789" or any(ch not in allowed for ch in value):
        fail(f"unsafe {label} at line {line_number}: {value}")


def load_candidates() -> list[Candidate]:
    lines = require_safe_manifest(PHASE_C_MANIFEST, "# schema=1", "Phase C candidate manifest")
    candidates: list[Candidate] = []
    seen: set[tuple[str, str]] = set()
    reader = csv.reader(lines[1:], delimiter="\t")
    for offset, parts in enumerate(reader, 2):
        if not parts or not parts[0] or parts[0].startswith("#"):
            continue
        if len(parts) != 8 or not all(parts):
            fail(f"invalid Phase C candidate row at line {offset}")
        module, package, source, disposition, applicability, service_action, blocker, purpose = parts
        for label, value in (
            ("module", module),
            ("package", package),
            ("applicability", applicability),
            ("future service action", service_action),
        ):
            validate_token(value, label, offset)
        if blocker != "-":
            validate_token(blocker, "blocker", offset)
        if source not in SOURCES:
            fail(f"invalid source at line {offset}: {source}")
        if disposition not in DISPOSITIONS:
            fail(f"invalid disposition at line {offset}: {disposition}")
        if source == "archlinuxcn" and disposition != "blocked-third-party":
            fail(f"third-party candidate is not blocked at line {offset}")
        if source == "unavailable-official" and disposition != "excluded":
            fail(f"unavailable official candidate is not excluded at line {offset}")
        if disposition in ACTIONABLE_DISPOSITIONS and source != "official":
            fail(f"actionable candidate is not official at line {offset}")
        if any(ord(ch) < 32 for ch in purpose):
            fail(f"control character in purpose at line {offset}")
        key = (module, package)
        if key in seen:
            fail(f"duplicate Phase C candidate at line {offset}: {module}/{package}")
        seen.add(key)
        candidates.append(Candidate(*parts))
    if not candidates:
        fail("Phase C candidate manifest has no rows")
    return candidates


def load_module_states() -> dict[str, tuple[str, str]]:
    lines = require_safe_manifest(MODULES, "# schema=1", "module registry")
    states: dict[str, tuple[str, str]] = {}
    for line_number, raw in enumerate(lines[1:], 2):
        if not raw or raw.startswith("#"):
            continue
        parts = raw.split("\t")
        if len(parts) != 6:
            fail(f"invalid module registry row at line {line_number}")
        module, availability, kind, *_ = parts
        if availability not in {"available", "planning", "unavailable"}:
            fail(f"invalid module availability at line {line_number}: {availability}")
        states[module] = (availability, kind)
    return states


def load_available_modules() -> set[str]:
    return {
        module
        for module, (availability, kind) in load_module_states().items()
        if availability == "available" and kind == "selectable"
    }


def load_profile_defaults(profile: str) -> list[str]:
    states = load_module_states()
    available = {
        module for module, (availability, kind) in states.items()
        if availability == "available" and kind == "selectable"
    }
    lines = require_safe_manifest(PROFILE_MODULES, "# schema=1", "profile module manifest")
    selected: list[str] = []
    seen_profile = False
    for line_number, raw in enumerate(lines[1:], 2):
        if not raw or raw.startswith("#"):
            continue
        parts = raw.split("\t")
        if len(parts) != 4:
            fail(f"invalid profile module row at line {line_number}")
        row_profile, _scope, module, state = parts
        if row_profile != profile:
            continue
        seen_profile = True
        if module not in states:
            fail(f"profile references unknown selectable module at line {line_number}: {module}")
        availability, kind = states[module]
        if kind != "selectable":
            fail(f"profile references dependency-only module at line {line_number}: {module}")
        if availability == "planning":
            # The Phase C planner consumes its own candidate manifest. New full-policy
            # planning modules remain visible in installer plans but are not Phase C inputs.
            continue
        if module not in available:
            fail(f"profile references unavailable selectable module at line {line_number}: {module}")
        if state == "selected":
            selected.append(module)
        elif state != "disabled":
            fail(f"invalid profile default state at line {line_number}: {state}")
    if not seen_profile:
        fail(f"unknown profile: {profile}")
    return selected


def parse_modules_arg(value: str | None, profile: str) -> list[str]:
    if value is None:
        return load_profile_defaults(profile)
    available = load_available_modules()
    modules: list[str] = []
    seen: set[str] = set()
    for item in value.split(","):
        if not item:
            fail("invalid empty entry in --modules")
        if item in seen:
            fail(f"duplicate module in --modules: {item}")
        if item not in available:
            fail(f"unknown or unavailable module in --modules: {item}")
        seen.add(item)
        modules.append(item)
    return modules


def applicability_tokens(profile: str, selected_modules: list[str]) -> set[str]:
    selected = set(selected_modules)
    tokens: set[str] = {profile, "physical+vm"}
    if profile == "vm":
        tokens.add("vm")
    else:
        tokens.add("physical")
    if "wm-niri" in selected:
        tokens.add("wm-niri")
    if "wm-hyprland" in selected:
        tokens.add("wm-hyprland")
    if {"wm-niri", "wm-hyprland"} & selected:
        tokens.add("any-wayland-wm")
    if profile in {"asus-amd-nvidia", "desktop-amd"}:
        tokens.update({"chinese-input", "amd-cpu", "amd-gpu", "detected-linux"})
    if profile == "asus-amd-nvidia":
        tokens.update(
            {
                "asus-base-install",
                "detected-linux-zen",
                "nvidia-compatible",
                "hybrid-gpu",
            }
        )
    return tokens


def applies(expression: str, tokens: set[str]) -> bool:
    if expression == "physical+vm":
        return "physical" in tokens or "vm" in tokens
    if expression.startswith("multilib+"):
        return all(part in tokens for part in expression.split("+"))
    if "+" in expression:
        return all(part in tokens for part in expression.split("+"))
    return expression in tokens


def query_installed(packages: list[str]) -> dict[str, PackageStatus]:
    pacman = shutil.which("pacman")
    statuses: dict[str, PackageStatus] = {}
    if pacman is None:
        for package in packages:
            statuses[package] = PackageStatus(package, "query-failed", None)
        return statuses
    for package in packages:
        result = subprocess.run(
            [pacman, "-Qq", package],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )
        if result.returncode == 0:
            status = "installed"
        elif result.returncode == 1:
            status = "missing"
        else:
            status = "query-failed"
        statuses[package] = PackageStatus(package, status, result.returncode)
    return statuses


def build_review_transaction(
    applicable: list[Candidate],
    status_map: dict[str, PackageStatus],
    check_installed: bool,
) -> dict[str, object]:
    def packages_for(disposition: str, source: str | None = None) -> list[str]:
        return sorted(
            {
                candidate.package
                for candidate in applicable
                if candidate.disposition == disposition and (source is None or candidate.source == source)
            }
        )

    proposed = packages_for("proposed", "official")
    gates: dict[str, list[str]] = {}
    for blocker in sorted(
        {
            candidate.blocker
            for candidate in applicable
            if candidate.disposition == "proposed" and candidate.source == "official" and candidate.blocker != "-"
        }
    ):
        gates[blocker] = sorted(
            {
                candidate.package
                for candidate in applicable
                if candidate.disposition == "proposed"
                and candidate.source == "official"
                and candidate.blocker == blocker
            }
        )

    installed: list[str] = []
    missing: list[str] = []
    query_failed: list[str] = []
    if check_installed:
        status_buckets = {
            "installed": installed,
            "missing": missing,
            "query-failed": query_failed,
        }
        for package in proposed:
            package_status = status_map.get(package)
            status = package_status.status if package_status is not None else "query-failed"
            status_buckets.get(status, query_failed).append(package)

    return {
        "apply_authorized": False,
        "installer_integration": False,
        "install_command": None,
        "installed_state_checked": check_installed,
        "proposed_official_packages": proposed,
        "precondition_packages": packages_for("precondition", "official"),
        "dependency_only_packages": packages_for("transitive", "official"),
        "pending_decision_packages": packages_for("pending-decision", "official"),
        "optional_packages": packages_for("optional", "official"),
        "blocked_third_party_packages": packages_for("blocked-third-party"),
        "excluded_packages": packages_for("excluded"),
        "unresolved_proposed_gates": gates,
        "installed_proposed_packages": installed,
        "missing_proposed_packages": missing,
        "query_failed_proposed_packages": query_failed,
    }


def build_plan(profile: str, modules_arg: str | None, check_installed: bool) -> dict[str, object]:
    candidates = load_candidates()
    selected_modules = parse_modules_arg(modules_arg, profile)
    tokens = applicability_tokens(profile, selected_modules)
    applicable = [candidate for candidate in candidates if applies(candidate.applicability, tokens)]
    status_map: dict[str, PackageStatus] = {}
    if check_installed:
        status_map = query_installed(sorted({candidate.package for candidate in applicable}))
    review_transaction = build_review_transaction(applicable, status_map, check_installed)
    return {
        "schema": 1,
        "profile": profile,
        "selected_modules": selected_modules,
        "applicability_tokens": sorted(tokens),
        "safety": {
            "planning_only": True,
            "installer_apply_integration": False,
            "system_changes": False,
        },
        "counts": {
            "manifest_rows": len(candidates),
            "applicable_rows": len(applicable),
            "by_source": dict(sorted(Counter(candidate.source for candidate in applicable).items())),
            "by_disposition": dict(sorted(Counter(candidate.disposition for candidate in applicable).items())),
            "by_module": dict(sorted(Counter(candidate.module for candidate in applicable).items())),
        },
        "applicable_candidates": [
            {
                **asdict(candidate),
                "installed_status": status_map.get(candidate.package).status if candidate.package in status_map else "not-queried",
                "query_exit": status_map.get(candidate.package).query_exit if candidate.package in status_map else None,
            }
            for candidate in applicable
        ],
        "review_transaction": review_transaction,
    }


def print_text(plan: dict[str, object]) -> None:
    counts = plan["counts"]  # type: ignore[index]
    candidates = plan["applicable_candidates"]  # type: ignore[index]
    transaction = plan["review_transaction"]  # type: ignore[index]
    print("Phase C review plan (read-only)")
    print(f"  profile: {plan['profile']}")
    print(f"  selected phase-a modules: {','.join(plan['selected_modules'])}")  # type: ignore[index]
    print(f"  applicability tokens: {','.join(plan['applicability_tokens'])}")  # type: ignore[index]
    print("  safety: planning only; no package, service, /etc, boot, driver or repository changes")
    print("  installer integration: none; installer/install.sh must not consume this manifest")
    print(f"  manifest rows: {counts['manifest_rows']}")  # type: ignore[index]
    print(f"  applicable rows: {counts['applicable_rows']}")  # type: ignore[index]
    print(f"  by disposition: {', '.join(f'{k}={v}' for k, v in counts['by_disposition'].items())}")  # type: ignore[index,union-attr]
    print(f"  by source: {', '.join(f'{k}={v}' for k, v in counts['by_source'].items())}")  # type: ignore[index,union-attr]

    print("\nreview transaction (NOT executable):")
    print(f"  apply authorized: {'yes' if transaction['apply_authorized'] else 'no'}")  # type: ignore[index]
    print(f"  installer integration: {'yes' if transaction['installer_integration'] else 'no'}")  # type: ignore[index]
    install_command = transaction["install_command"]  # type: ignore[index]
    print(f"  install command: {install_command if install_command is not None else 'not generated'}")
    print(f"  installed state checked: {'yes' if transaction['installed_state_checked'] else 'no'}")  # type: ignore[index]

    transaction_buckets = (
        ("proposed official packages", "proposed_official_packages"),
        ("precondition packages", "precondition_packages"),
        ("dependency-only packages", "dependency_only_packages"),
        ("pending-decision packages", "pending_decision_packages"),
        ("optional packages", "optional_packages"),
        ("blocked third-party packages", "blocked_third_party_packages"),
        ("excluded packages", "excluded_packages"),
    )
    for label, key in transaction_buckets:
        packages = transaction[key]  # type: ignore[index]
        print(f"  {label} ({len(packages)}): {','.join(packages) if packages else '-'}")

    gates = transaction["unresolved_proposed_gates"]  # type: ignore[index]
    print("  unresolved proposed gates:")
    if gates:
        for gate, packages in gates.items():  # type: ignore[union-attr]
            print(f"    - {gate}: {','.join(packages)}")
    else:
        print("    - none")

    if transaction["installed_state_checked"]:  # type: ignore[index]
        for label, key in (
            ("installed proposed packages", "installed_proposed_packages"),
            ("missing proposed packages", "missing_proposed_packages"),
            ("query-failed proposed packages", "query_failed_proposed_packages"),
        ):
            packages = transaction[key]  # type: ignore[index]
            print(f"  {label} ({len(packages)}): {','.join(packages) if packages else '-'}")
    else:
        print("  proposed installed-state classification: not queried")

    grouped: dict[str, list[dict[str, object]]] = defaultdict(list)
    for candidate in candidates:  # type: ignore[assignment]
        grouped[str(candidate["disposition"])].append(candidate)

    for disposition in ("precondition", "proposed", "pending-decision", "optional", "transitive", "blocked-third-party", "excluded"):
        rows = grouped.get(disposition, [])
        if not rows:
            continue
        print(f"\n{disposition}:")
        for row in rows:
            status = row["installed_status"]
            query_exit = row["query_exit"]
            query = "not-queried" if status == "not-queried" else f"{status} query_exit={query_exit}"
            print(
                "  - "
                f"[{row['module']}] {row['package']} "
                f"source={row['source']} applicability={row['applicability']} "
                f"future_action={row['future_service_action']} blocker={row['blocker']} "
                f"status={query} — {row['purpose']}"
            )

    future_actions = sorted(
        {
            str(row["future_service_action"])
            for row in candidates  # type: ignore[assignment]
            if row["future_service_action"] != "none"
        }
    )
    if future_actions:
        print("\nfuture service/config actions listed but NOT executed:")
        for action in future_actions:
            print(f"  - {action}")
    print("\ncompletion gate: generate a separate exact transaction, prior-state inventory, rollback notes, VM apply evidence and explicit user approval before any apply work.")


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Generate a read-only Phase C review plan.")
    parser.add_argument("--profile", default="asus-amd-nvidia", choices=("asus-amd-nvidia", "desktop-amd", "vm"))
    parser.add_argument("--modules", help="comma-separated Phase A modules for applicability planning; defaults to profile selections")
    parser.add_argument("--check-installed", action="store_true", help="query current package installation state with pacman -Qq; read-only")
    parser.add_argument("--json", action="store_true", help="emit machine-readable JSON")
    args = parser.parse_args(argv)

    plan = build_plan(args.profile, args.modules, args.check_installed)
    if args.json:
        json.dump(plan, sys.stdout, indent=2, sort_keys=True)
        print()
    else:
        print_text(plan)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
