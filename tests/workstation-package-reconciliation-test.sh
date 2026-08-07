#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

python - "$root" <<'PY'
from __future__ import annotations

import csv
import re
import sys
from collections import Counter
from pathlib import Path

root = Path(sys.argv[1])
packages_path = root / "manifests/workstation-packages.tsv"
mappings_path = root / "manifests/config-mappings.tsv"
recipes_path = root / "manifests/aur-recipes.tsv"
recipes_dir = root / "third_party/aur"

for path in (packages_path, mappings_path, recipes_path):
    if not path.is_file() or path.is_symlink():
        raise SystemExit(f"manifest is missing or unsafe: {path}")

# ---- workstation-packages.tsv (installer 03-packages.sh input) ----
lines = packages_path.read_text().splitlines()
if not lines or lines[0] != "# schema=1":
    raise SystemExit("reconciled workstation package manifest has an unsupported schema")

records: dict[str, dict[str, str]] = {}
for line_number, parts in enumerate(csv.reader(lines[1:], delimiter="\t"), 2):
    if not parts or not parts[0] or parts[0].startswith("#"):
        continue
    if len(parts) != 9 or not all(parts):
        raise SystemExit(f"invalid reconciled workstation package row at line {line_number}")
    package, channel, repository, acquisition, module, restore_mode, policy, origin, purpose = parts
    if not re.fullmatch(r"[a-z0-9@._+:-]+", package):
        raise SystemExit(f"unsafe package name at line {line_number}: {package}")
    if package in records:
        raise SystemExit(f"duplicate reconciled workstation package: {package}")
    expected_repositories = {
        "pacman": {"core", "extra", "multilib", "archlinuxcn"},
        "aur": {"aur"},
    }
    if channel not in expected_repositories or repository not in expected_repositories[channel]:
        raise SystemExit(f"invalid channel/repository for {package}: {channel}/{repository}")
    if policy not in {"install", "verify", "deferred"}:
        raise SystemExit(f"invalid policy for {package}: {policy}")
    if restore_mode not in {"package-only", "config-backed", "manual-precondition", "deferred"}:
        raise SystemExit(f"invalid restore mode for {package}: {restore_mode}")
    expected_policy = {
        "package-only": "install",
        "config-backed": "install",
        "manual-precondition": "verify",
        "deferred": "deferred",
    }[restore_mode]
    if policy != expected_policy:
        raise SystemExit(f"restore-mode/policy mismatch for {package}: {restore_mode}/{policy}")
    if origin not in {"current-explicit", "confirmed-desired"}:
        raise SystemExit(f"invalid reconciliation origin for {package}: {origin}")
    if any(ord(character) < 32 for character in purpose):
        raise SystemExit(f"control character in purpose for {package}")
    records[package] = {
        "channel": channel,
        "repository": repository,
        "module": module,
        "restore_mode": restore_mode,
        "policy": policy,
    }

install_rows = {name for name, record in records.items() if record["policy"] == "install"}
verify_rows = {name for name, record in records.items() if record["policy"] == "verify"}
deferred_rows = {name for name, record in records.items() if record["policy"] == "deferred"}
if not install_rows:
    raise SystemExit("no install rows in workstation package policy")
if not verify_rows:
    raise SystemExit("no verify rows in workstation package policy")

# ---- config-mappings.tsv (installer 06-config.sh input) ----
mapping_modules: Counter[str] = Counter()
mapping_sources: set[str] = set()
for line_number, parts in enumerate(csv.reader(mappings_path.read_text().splitlines()[1:], delimiter="\t"), 2):
    if not parts or not parts[0] or parts[0].startswith("#"):
        continue
    if len(parts) != 5:
        raise SystemExit(f"invalid config mapping row at line {line_number}")
    scope, module, src, _tgt, mode = parts
    if scope != "physical-v1":
        raise SystemExit(f"invalid mapping scope at line {line_number}: {scope} (only physical-v1 is deployed; the vm-v1 split was removed)")
    if not re.fullmatch(r"[0-7]{3,4}", mode):
        raise SystemExit(f"invalid mapping mode at line {line_number}: {mode}")
    mapping_modules[module] += 1
    mapping_sources.add(src)

# every config-backed package must have at least one same-module mapping
for package, record in records.items():
    if record["restore_mode"] == "config-backed" and mapping_modules[record["module"]] == 0:
        raise SystemExit(f"config-backed package has no same-module mapping: {package}: {record['module']}")

# every mapping source file must exist in config/
config_dir = root / "config"
for src in mapping_sources:
    local = config_dir / src.removeprefix("config/")
    if not local.is_file():
        raise SystemExit(f"config mapping source file missing: {src}")

# ---- aur-recipes.tsv (installer 06-aur.sh input; slim single-column list) ----
recipe_names: set[str] = set()
for line_number, parts in enumerate(csv.reader(recipes_path.read_text().splitlines()[1:], delimiter="\t"), 2):
    if not parts or not parts[0] or parts[0].startswith("#"):
        continue
    if len(parts) != 1:
        raise SystemExit(f"invalid AUR recipe row at line {line_number}")
    recipe_names.add(parts[0])

# every AUR install row must have a pinned recipe tree
aur_install = {name for name, record in records.items() if record["channel"] == "aur" and record["policy"] == "install"}
missing_recipes = aur_install - recipe_names
if missing_recipes:
    raise SystemExit(f"AUR install rows without a pinned recipe: {sorted(missing_recipes)}")
for recipe in recipe_names:
    if not (recipes_dir / recipe).is_dir():
        raise SystemExit(f"AUR recipe directory missing: {recipes_dir / recipe}")

print(
    "Workstation package checks passed: "
    f"install={len(install_rows)} verify={len(verify_rows)} deferred={len(deferred_rows)} "
    f"total={len(records)}, mappings={len(mapping_sources)}, recipes={len(recipe_names)}"
)
PY
