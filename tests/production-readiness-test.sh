#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT

fail() {
  printf 'production readiness test failed: %s\n' "$*" >&2
  exit 1
}

# The disposable candidate/canonical matrix (2026-08-02) built these three
# recipes, and the module-level DAG (2026-08-04) validated every remaining
# fixed recipe in a full nine-stage run with idempotent rerun.  All fixed AUR
# recipes now carry runtime evidence; none may be blocked as unproven.
PYTHONDONTWRITEBYTECODE=1 python3 - "$root" "$test_root" <<'PY'
from __future__ import annotations

import csv
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

root = Path(sys.argv[1])
test_root = Path(sys.argv[2])
recipes: list[tuple[str, str]] = []
with (root / "manifests/aur-recipes.tsv").open(newline="") as handle:
    for row in csv.reader(handle, delimiter="\t"):
        if row and row[0] and not row[0].startswith("#"):
            assert len(row) == 14
            recipes.append((row[0], row[3]))

# Every fixed recipe now has runtime evidence (2026-08-02 matrix for the three
# base recipes; 2026-08-04 module-level DAG for the remaining ten).
proven = {package for package, _module in recipes}
unproven = [(package, module) for package, module in recipes if package not in proven]
assert len(recipes) == 13, recipes
assert len(unproven) == 0, unproven
assert {package for package, _module in recipes if package in proven} == proven

module_availability: dict[str, str] = {}
with (root / "manifests/modules.tsv").open(newline="") as handle:
    for row in csv.reader(handle, delimiter="\t"):
        if row and row[0] and not row[0].startswith("#"):
            assert len(row) == 6
            module_availability[row[0]] = row[1]

production_readiness: dict[str, str] = {}
with (root / "manifests/production-module-readiness.tsv").open(newline="") as handle:
    rows = list(csv.reader(handle, delimiter="\t"))
assert rows[:2] == [
    ["# schema=1"],
    ["# module<TAB>production-readiness<TAB>evidence"],
]
for row in rows[2:]:
    assert len(row) == 3 and all(row), row
    module, readiness, evidence = row
    assert module not in production_readiness
    assert readiness in {"available", "planning", "unavailable"}
    assert not any(ord(character) < 32 for character in evidence)
    production_readiness[module] = readiness
assert production_readiness.keys() == module_availability.keys()
assert {
    state: sum(value == state for value in production_readiness.values())
    for state in {"available", "planning", "unavailable"}
} == {"available": 30, "planning": 0, "unavailable": 2}
assert all(
    module_availability[module] == "available"
    for module, readiness in production_readiness.items()
    if readiness == "available"
)

# These four configuration surfaces were marked available in modules.tsv and
# were readiness-promoted after the full-DAG module selection of batch
# 2026-08-08.  Audit their package/config/system effects explicitly.
audit_modules = {
    "developer-editor",
    "personal-scripts",
    "asus-hardware",
    "personal-user-services",
}
assert all(module_availability[module] == "available" for module in audit_modules)
assert all(production_readiness[module] == "available" for module in audit_modules)

packages: dict[str, list[tuple[str, str, str]]] = {module: [] for module in audit_modules}
with (root / "manifests/workstation-packages.tsv").open(newline="") as handle:
    for row in csv.reader(handle, delimiter="\t"):
        if row and not row[0].startswith("#") and row[4] in packages:
            packages[row[4]].append((row[0], row[3], row[2]))
assert packages == {
    "developer-editor": [
        ("fd", "pacman", "extra"),
        ("lua-language-server", "pacman", "extra"),
        ("neovide", "pacman", "extra"),
        ("neovim", "pacman", "extra"),
        ("ripgrep", "pacman", "extra"),
        ("stylua", "pacman", "extra"),
    ],
    "personal-scripts": [],
    "asus-hardware": [
        ("asusctl", "pacman", "archlinuxcn"),
        ("rog-control-center", "pacman", "archlinuxcn"),
        ("supergfxctl", "pacman", "archlinuxcn"),
    ],
    "personal-user-services": [],
}

mapping_counts = {module: 0 for module in audit_modules}
with (root / "manifests/config-mappings.tsv").open(newline="") as handle:
    for row in csv.reader(handle, delimiter="\t"):
        if row and not row[0].startswith("#") and row[1] in mapping_counts:
            mapping_counts[row[1]] += 1
assert mapping_counts == {
    "developer-editor": 42,
    "personal-scripts": 39,
    "asus-hardware": 1,
    "personal-user-services": 4,
}

actions: dict[str, list[tuple[str, str, str, str]]] = {module: [] for module in audit_modules}
with (root / "manifests/system-actions.tsv").open(newline="") as handle:
    for row in csv.reader(handle, delimiter="\t"):
        if row and not row[0].startswith("#") and row[1] in actions:
            actions[row[1]].append((row[0], row[3], row[4], row[5]))
assert actions == {
    "developer-editor": [],
    "personal-scripts": [],
    "asus-hardware": [
        ("asusd-package-activation", "verify", "none", "verify-package-activation"),
        ("supergfxd-physical-service", "manual", "root", "report-manual"),
        ("physical-hardware-acceptance", "manual", "none", "report-manual"),
    ],
    "personal-user-services": [
        ("personal-user-unit-reload", "apply", "user", "daemon-reload-user")
    ],
}

home = test_root / "home"
home.mkdir(mode=0o700)
environment = os.environ.copy()
environment.update(
    HOME=os.fspath(home),
    XDG_STATE_HOME=os.fspath(test_root / "state"),
    PYTHONDONTWRITEBYTECODE="1",
)
plans: dict[str, dict[str, object]] = {}
for module in sorted({module for _package, module in unproven} | audit_modules):
    result = subprocess.run(
        [
            sys.executable,
            os.fspath(root / "installer/full-orchestrator.py"),
            "--profile",
            "asus-amd-nvidia",
            "--modules",
            module,
            "--plan",
            "--json",
        ],
        check=False,
        capture_output=True,
        text=True,
        env=environment,
    )
    assert result.returncode == 0, (module, result.returncode, result.stderr)
    plans[module] = json.loads(result.stdout)

assert not unproven, unproven  # every fixed recipe carries runtime evidence now

readiness_digest = hashlib.sha256(
    (root / "manifests/production-module-readiness.tsv").read_bytes()
).hexdigest()
for plan in plans.values():
    assert plan["inputs"]["production-module-readiness"] == readiness_digest

for module in audit_modules:
    blockers = plans[module]["apply_blockers"]["non_executable_modules"]
    assert module not in blockers, (module, blockers)
    selected_readiness = plans[module]["selection"]["production_readiness"]
    assert selected_readiness[module] == "available", (module, selected_readiness)

assert not (test_root / "state").exists(), "read-only production readiness plans wrote state"
PY

printf '%s\n' 'Production effect readiness checks passed.'
