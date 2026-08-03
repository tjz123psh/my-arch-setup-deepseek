#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT

fail() {
  printf 'production readiness test failed: %s\n' "$*" >&2
  exit 1
}

# The disposable candidate/canonical matrix built exactly these three recipes.
# Every other fixed recipe remains reviewed source policy, but must be blocked
# from production apply until it has its own runtime evidence.
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
proven = {
    "dsearch-bin",
    "fcitx5-skin-fluentdark-git",
    "fuzzel-ime-git",
}
recipes: list[tuple[str, str]] = []
with (root / "manifests/aur-recipes.tsv").open(newline="") as handle:
    for row in csv.reader(handle, delimiter="\t"):
        if row and row[0] and not row[0].startswith("#"):
            assert len(row) == 14
            recipes.append((row[0], row[3]))

unproven = [(package, module) for package, module in recipes if package not in proven]
assert len(recipes) == 13, recipes
assert len(unproven) == 10, unproven
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
} == {"available": 9, "planning": 21, "unavailable": 2}
assert all(
    module_availability[module] == "available"
    for module, readiness in production_readiness.items()
    if readiness == "available"
)

# These five configuration surfaces were already marked available before the VM
# run but were absent from every exact VM selection.  Audit their package/config/
# system effects explicitly and keep their independent production gate closed.
audit_modules = {
    "developer-editor",
    "personal-scripts",
    "personal-autostart",
    "asus-hardware",
    "personal-user-services",
}
assert all(module_availability[module] == "available" for module in audit_modules)
assert all(production_readiness[module] == "planning" for module in audit_modules)

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
    "personal-autostart": [("flclash-bin", "aur-build", "aur")],
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
    "personal-autostart": 1,
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
    "personal-autostart": [],
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

for package, module in unproven:
    plan = plans[module]
    effects = {
        effect["id"]
        for stage in plan["stages"]
        for effect in stage["effects"]
    }
    assert f"acquire-source:{package}" in effects, (package, module, sorted(effects))
    assert f"build-install:{package}" in effects, (package, module, sorted(effects))
    blockers = plan["apply_blockers"]["non_executable_modules"]
    assert module in blockers, (
        f"unproven AUR recipe escaped production readiness: {package} via {module}; "
        f"blockers={blockers}"
    )

readiness_digest = hashlib.sha256(
    (root / "manifests/production-module-readiness.tsv").read_bytes()
).hexdigest()
for plan in plans.values():
    assert plan["inputs"]["production-module-readiness"] == readiness_digest

for module in audit_modules:
    blockers = plans[module]["apply_blockers"]["non_executable_modules"]
    assert module in blockers, (module, blockers)
    selected_readiness = plans[module]["selection"]["production_readiness"]
    assert selected_readiness[module] == "planning", (module, selected_readiness)

flclash = plans["personal-autostart"]
assert "personal-autostart" in flclash["apply_blockers"]["non_executable_modules"]
assert not (test_root / "state").exists(), "read-only production readiness plans wrote state"
PY

printf '%s\n' 'Production effect readiness checks passed.'
