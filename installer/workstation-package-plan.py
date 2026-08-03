#!/usr/bin/env python3
"""Render the reconciled ASUS workstation package policy without applying it."""

from __future__ import annotations

import argparse
import csv
import json
import re
import sys
from collections import Counter
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parent.parent
INVENTORY = ROOT / "manifests/workstation-package-inventory.tsv"
POLICY = ROOT / "manifests/workstation-packages.tsv"
MODULES = ROOT / "manifests/modules.tsv"
MAPPINGS = ROOT / "manifests/config-mappings.tsv"
TRANSITIONS = ROOT / "manifests/package-source-transitions.tsv"
PACKAGE_RE = re.compile(r"[a-z0-9@._+:-]+")
CHANNELS = {"pacman", "aur"}
REPOSITORIES = {
    "pacman": {"core", "extra", "multilib", "archlinuxcn"},
    "aur": {"aur"},
}
RESTORE_MODES = {
    "package-only",
    "config-backed",
    "manual-precondition",
    "deferred",
}
POLICY_BY_MODE = {
    "package-only": "install",
    "config-backed": "install",
    "manual-precondition": "verify",
    "deferred": "deferred",
}
ORIGINS = {"current-explicit", "confirmed-desired"}


@dataclass(frozen=True)
class InventoryRecord:
    package: str
    installed_version: str
    channel: str
    repository: str
    restore_mode: str
    execution: str


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


def fail(message: str) -> None:
    print(f"workstation-package-plan: {message}", file=sys.stderr)
    raise SystemExit(1)


def safe_lines(path: Path, schema: str, label: str) -> list[str]:
    if not path.is_file() or path.is_symlink():
        fail(f"{label} is missing or unsafe")
    lines = path.read_text().splitlines()
    if not lines or lines[0] != schema:
        fail(f"{label} has an unsupported schema")
    return lines


def load_inventory() -> dict[str, InventoryRecord]:
    lines = safe_lines(INVENTORY, "# schema=1", "workstation package inventory")
    records: dict[str, InventoryRecord] = {}
    for line_number, parts in enumerate(csv.reader(lines[1:], delimiter="\t"), 2):
        if not parts or not parts[0] or parts[0].startswith("#"):
            continue
        if len(parts) != 6 or not all(parts):
            fail(f"invalid inventory row at line {line_number}")
        record = InventoryRecord(*parts)
        if PACKAGE_RE.fullmatch(record.package) is None:
            fail(f"unsafe inventory package at line {line_number}: {record.package}")
        if record.package in records:
            fail(f"duplicate inventory package: {record.package}")
        if record.channel not in CHANNELS or record.repository not in REPOSITORIES[record.channel]:
            fail(
                f"inventory channel/repository mismatch for {record.package}: "
                f"{record.channel}/{record.repository}"
            )
        if record.restore_mode not in RESTORE_MODES:
            fail(f"invalid inventory restore mode for {record.package}: {record.restore_mode}")
        if record.execution != "inventory-only":
            fail(f"inventory package became executable: {record.package}")
        if any(ord(character) < 32 for character in record.installed_version):
            fail(f"control character in inventory version for {record.package}")
        records[record.package] = record
    if len(records) != 180:
        fail(f"expected 180 current explicit inventory rows, found {len(records)}")
    return records


def load_modules() -> set[str]:
    lines = safe_lines(MODULES, "# schema=1", "module registry")
    modules: set[str] = set()
    for line_number, parts in enumerate(csv.reader(lines[1:], delimiter="\t"), 2):
        if not parts or not parts[0] or parts[0].startswith("#"):
            continue
        if len(parts) != 6 or not all(parts):
            fail(f"invalid module registry row at line {line_number}")
        module = parts[0]
        if module in modules:
            fail(f"duplicate module registry row: {module}")
        modules.add(module)
    if not modules:
        fail("module registry is empty")
    return modules


def load_mapping_modules() -> Counter[str]:
    lines = safe_lines(MAPPINGS, "# schema=2", "configuration mapping")
    counts: Counter[str] = Counter()
    for line_number, parts in enumerate(csv.reader(lines[1:], delimiter="\t"), 2):
        if not parts or not parts[0] or parts[0].startswith("#"):
            continue
        if len(parts) != 4 or not all(parts):
            fail(f"invalid configuration mapping row at line {line_number}")
        counts[parts[1]] += 1
    if not counts:
        fail("configuration mapping is empty")
    return counts


def load_source_transitions() -> dict[str, tuple[str, str, str, str]]:
    lines = safe_lines(TRANSITIONS, "# schema=1", "package source transition manifest")
    transitions: dict[str, tuple[str, str, str, str]] = {}
    for line_number, parts in enumerate(csv.reader(lines[1:], delimiter="\t"), 2):
        if not parts or not parts[0] or parts[0].startswith("#"):
            continue
        if len(parts) != 6 or not all(parts):
            fail(f"invalid package source transition at line {line_number}")
        package, observed_channel, observed_repository, target_channel, target_repository, rationale = parts
        if package in transitions:
            fail(f"duplicate package source transition: {package}")
        if observed_channel not in CHANNELS or observed_repository not in REPOSITORIES[observed_channel]:
            fail(f"invalid observed transition source for {package}")
        if target_channel not in CHANNELS or target_repository not in REPOSITORIES[target_channel]:
            fail(f"invalid target transition source for {package}")
        if any(ord(character) < 32 for character in rationale):
            fail(f"control character in transition rationale for {package}")
        transitions[package] = (observed_channel, observed_repository, target_channel, target_repository)
    return transitions


def load_policy(
    inventory: dict[str, InventoryRecord],
    modules: set[str],
    mapping_modules: Counter[str],
    transitions: dict[str, tuple[str, str, str, str]],
) -> list[PackagePolicy]:
    lines = safe_lines(POLICY, "# schema=1", "reconciled workstation package manifest")
    records: dict[str, PackagePolicy] = {}
    for line_number, parts in enumerate(csv.reader(lines[1:], delimiter="\t"), 2):
        if not parts or not parts[0] or parts[0].startswith("#"):
            continue
        if len(parts) != 9 or not all(parts):
            fail(f"invalid reconciled package row at line {line_number}")
        record = PackagePolicy(*parts)
        if PACKAGE_RE.fullmatch(record.package) is None:
            fail(f"unsafe reconciled package at line {line_number}: {record.package}")
        if record.package in records:
            fail(f"duplicate reconciled package: {record.package}")
        if record.channel not in CHANNELS or record.repository not in REPOSITORIES[record.channel]:
            fail(
                f"reconciled channel/repository mismatch for {record.package}: "
                f"{record.channel}/{record.repository}"
            )
        if record.acquisition not in {
            "pacman", "archlinuxcn-bootstrap", "aur-build", "paru-bootstrap",
            "verify-only", "deferred",
        }:
            fail(f"invalid acquisition for {record.package}: {record.acquisition}")
        if record.module not in modules:
            fail(f"reconciled package references unknown module: {record.package}: {record.module}")
        if record.restore_mode not in RESTORE_MODES:
            fail(f"invalid restore mode for {record.package}: {record.restore_mode}")
        if record.policy != POLICY_BY_MODE[record.restore_mode]:
            fail(
                f"restore-mode/policy mismatch for {record.package}: "
                f"{record.restore_mode}/{record.policy}"
            )
        if record.policy == "verify" and record.acquisition != "verify-only":
            fail(f"verify policy has unsafe acquisition for {record.package}")
        if record.policy == "deferred" and record.acquisition != "deferred":
            fail(f"deferred policy has unsafe acquisition for {record.package}")
        if (
            record.policy == "install"
            and record.channel == "pacman"
            and record.repository in {"core", "extra", "multilib"}
            and record.acquisition != "pacman"
        ):
            fail(f"official package has unsafe acquisition for {record.package}")
        if (
            record.policy == "install"
            and record.channel == "aur"
            and record.acquisition not in {"aur-build", "paru-bootstrap"}
        ):
            fail(f"AUR package has unsafe acquisition for {record.package}")
        if record.origin not in ORIGINS:
            fail(f"invalid origin for {record.package}: {record.origin}")
        if any(ord(character) < 32 for character in record.purpose):
            fail(f"control character in purpose for {record.package}")
        if record.restore_mode == "config-backed" and mapping_modules[record.module] == 0:
            fail(
                f"config-backed package has no same-module mapping: "
                f"{record.package}: {record.module}"
            )
        records[record.package] = record

    current = {
        name for name, record in records.items() if record.origin == "current-explicit"
    }
    if current != set(inventory):
        fail(f"current-explicit reconciliation drift: {sorted(current ^ set(inventory))}")
    source_changes: set[str] = set()
    for package in sorted(current):
        source = inventory[package]
        target = records[package]
        observed = (source.channel, source.repository)
        desired_source = (target.channel, target.repository)
        if desired_source != observed:
            source_changes.add(package)
            if transitions.get(package) != (*observed, *desired_source):
                fail(f"current package source changed without exact transition evidence: {package}")
    if set(transitions) != source_changes:
        fail(f"stale or missing package source transitions: {sorted(set(transitions) ^ source_changes)}")
    desired = {
        name for name, record in records.items() if record.origin == "confirmed-desired"
    }
    if desired & set(inventory):
        fail(f"confirmed-desired rows duplicate current inventory: {sorted(desired & set(inventory))}")
    if not desired:
        fail("reconciled policy contains no confirmed desired non-explicit packages")
    return sorted(records.values(), key=lambda record: record.package)


def build_plan(records: list[PackagePolicy]) -> dict[str, Any]:
    install = [record for record in records if record.policy == "install"]
    verify = [record for record in records if record.policy == "verify"]
    deferred = [record for record in records if record.policy == "deferred"]
    package_only = [record for record in records if record.restore_mode == "package-only"]
    config_backed = [record for record in records if record.restore_mode == "config-backed"]
    current = [record for record in records if record.origin == "current-explicit"]
    desired = [record for record in records if record.origin == "confirmed-desired"]
    official = [
        record
        for record in install
        if record.channel == "pacman" and record.repository in {"core", "extra", "multilib"}
    ]
    archlinuxcn = [
        record
        for record in install
        if record.channel == "pacman"
        and record.repository == "archlinuxcn"
        and record.acquisition == "pacman"
    ]
    archlinuxcn_bootstrap = [
        record for record in install if record.acquisition == "archlinuxcn-bootstrap"
    ]
    aur = [record for record in install if record.acquisition == "aur-build"]
    paru_bootstrap = [
        record for record in install if record.acquisition == "paru-bootstrap"
    ]

    def names(selected: list[PackagePolicy]) -> list[str]:
        return [record.package for record in selected]

    return {
        "schema": 2,
        "snapshot_date": "2026-07-31",
        "safety": {
            "planning_only": True,
            "apply_authorized": False,
            "installer_apply_integration": False,
            "system_changes": False,
        },
        "evidence": {
            "current_live_recheck_date": "2026-08-01",
            "explicit_inventory_query": "ok",
            "native_inventory_query": "ok",
            "foreign_inventory_query": "ok",
            "current_manifest_comparison": "matched",
            "repository_membership_queries": "ok",
            "aur_metadata_queries": "ok",
            "failed_queries": [],
        },
        "counts": {
            "reconciled_packages": len(records),
            "current_explicit": len(current),
            "confirmed_desired": len(desired),
            "install": len(install),
            "verify": len(verify),
            "deferred": len(deferred),
            "package_only": len(package_only),
            "config_backed": len(config_backed),
            "manual_preconditions": len(verify),
            "official_install": len(official),
            "archlinuxcn_install": len(archlinuxcn),
            "archlinuxcn_bootstrap": len(archlinuxcn_bootstrap),
            "aur_install": len(aur),
            "paru_bootstrap": len(paru_bootstrap),
        },
        "review_transaction": {
            "records": [asdict(record) for record in records],
            "install_packages": names(install),
            "verify_packages": names(verify),
            "deferred_packages": names(deferred),
            "package_only_packages": names(package_only),
            "config_backed_packages": names(config_backed),
            "current_explicit_packages": names(current),
            "confirmed_desired_packages": names(desired),
            "official_packages": names(official),
            "archlinuxcn_packages": names(archlinuxcn),
            "archlinuxcn_bootstrap_packages": names(archlinuxcn_bootstrap),
            "aur_packages": names(aur),
            "paru_bootstrap_packages": names(paru_bootstrap),
            "official_command": None,
            "archlinuxcn_command": None,
            "aur_command": None,
        },
    }


def print_text(plan: dict[str, Any]) -> None:
    counts = plan["counts"]
    transaction = plan["review_transaction"]
    print("Reconciled workstation package plan (NOT executable)")
    print(f"Policy rows: {counts['reconciled_packages']}")
    print(f"Current explicit rows: {counts['current_explicit']}")
    print(f"Confirmed desired rows: {counts['confirmed_desired']}")
    print(f"Install: {counts['install']}")
    print(f"Verify manual preconditions: {counts['verify']}")
    print(f"Deferred: {counts['deferred']}")
    print(f"Official install: {counts['official_install']}")
    print(f"archlinuxcn install: {counts['archlinuxcn_install']}")
    print(f"archlinuxcn bootstrap: {counts['archlinuxcn_bootstrap']}")
    print(f"AUR install: {counts['aur_install']}")
    print(f"Paru bootstrap: {counts['paru_bootstrap']}")
    print("Confirmed desired non-explicit packages:")
    for package in transaction["confirmed_desired_packages"]:
        print(f"- {package}")
    print("Apply authorization: false")


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        description="Render the complete reconciled workstation package policy without applying it."
    )
    parser.add_argument("--json", action="store_true", help="emit machine-readable JSON")
    args = parser.parse_args(argv)
    inventory = load_inventory()
    records = load_policy(
        inventory, load_modules(), load_mapping_modules(), load_source_transitions()
    )
    plan = build_plan(records)
    if args.json:
        json.dump(plan, sys.stdout, indent=2, sort_keys=True)
        print()
    else:
        print_text(plan)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
