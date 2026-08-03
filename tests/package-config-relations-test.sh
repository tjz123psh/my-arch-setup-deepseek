#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
python - "$root" <<'PY'
from __future__ import annotations

import csv
import re
import sys
from collections import Counter
from pathlib import Path, PurePosixPath

root = Path(sys.argv[1])
policy_path = root / "manifests/workstation-packages.tsv"
relations_path = root / "manifests/package-config-relations.tsv"
mappings_path = root / "manifests/config-mappings.tsv"

if not relations_path.is_file() or relations_path.is_symlink():
    raise SystemExit("package/config relation manifest is missing or unsafe")
lines = relations_path.read_text().splitlines()
if not lines or lines[0] != "# schema=1":
    raise SystemExit("package/config relation manifest has an unsupported schema")

policies = {}
for parts in csv.reader(policy_path.read_text().splitlines()[1:], delimiter="\t"):
    if parts and parts[0] and not parts[0].startswith("#"):
        policies[parts[0]] = {"module": parts[4], "restore_mode": parts[5], "policy": parts[6]}

mappings = []
for parts in csv.reader(mappings_path.read_text().splitlines()[1:], delimiter="\t"):
    if parts and parts[0] and not parts[0].startswith("#"):
        mappings.append({"scope": parts[0], "module": parts[1], "target": parts[3]})

relations = []
seen = set()
for line_number, parts in enumerate(csv.reader(lines[1:], delimiter="\t"), 2):
    if not parts or not parts[0] or parts[0].startswith("#"):
        continue
    if len(parts) != 5 or not all(parts):
        raise SystemExit(f"invalid package/config relation row at line {line_number}")
    package, module, relation, target_prefix, purpose = parts
    if package not in policies:
        raise SystemExit(f"relation references unknown package: {package}")
    if policies[package]["restore_mode"] != "config-backed":
        raise SystemExit(f"non-config-backed package owns config relation: {package}")
    if module != policies[package]["module"]:
        raise SystemExit(f"package/config module mismatch: {package}: {module}")
    if relation not in {"owner", "consumer", "runtime-dependency", "optional-enhancement"}:
        raise SystemExit(f"invalid package/config relation type: {package}: {relation}")
    if not target_prefix.startswith((".config/", ".local/share/", "scripts/")):
        raise SystemExit(f"unsafe package/config target prefix: {package}: {target_prefix}")
    normalized = PurePosixPath(target_prefix.rstrip("/")).as_posix()
    if normalized != target_prefix.rstrip("/") or ".." in PurePosixPath(normalized).parts:
        raise SystemExit(f"non-normalized package/config target prefix: {package}: {target_prefix}")
    key = (package, target_prefix)
    if key in seen:
        raise SystemExit(f"duplicate package/config relation: {package}: {target_prefix}")
    seen.add(key)
    matches = [
        row for row in mappings
        if row["module"] == module and (
            row["target"] == target_prefix.rstrip("/")
            or (target_prefix.endswith("/") and row["target"].startswith(target_prefix))
        )
    ]
    if not matches:
        raise SystemExit(f"package/config relation matches no same-module mapping: {package}: {target_prefix}")
    if any(ord(character) < 32 for character in purpose):
        raise SystemExit(f"control character in package/config purpose: {package}")
    relations.append((package, module, relation, target_prefix))

covered = Counter(package for package, *_rest in relations)
expected = {name for name, row in policies.items() if row["restore_mode"] == "config-backed"}
if set(covered) != expected:
    raise SystemExit(f"config-backed package relation coverage drift: {sorted(set(covered) ^ expected)}")
if not any(package == "fcitx5" and relation == "owner" for package, _module, relation, _prefix in relations):
    raise SystemExit("Fcitx5 configuration owner relation is missing")
if not any(package == "neovide" and relation == "consumer" for package, _module, relation, _prefix in relations):
    raise SystemExit("Neovide consumer relation is missing")
if not any(package == "quickshell" and relation == "runtime-dependency" for package, _module, relation, _prefix in relations):
    raise SystemExit("Quickshell DMS runtime relation is missing")
print(f"Package/config relation checks passed: packages={len(expected)} relations={len(relations)}")
PY
