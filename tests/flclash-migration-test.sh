#!/usr/bin/env bash
# flclash-migration-test.sh - static contract for the flclash-bin ->
# archlinuxcn/flclash migration. It does not install or remove packages.
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

python3 - "$root" <<'PY'
from __future__ import annotations

import csv
import sys
from pathlib import Path

root = Path(sys.argv[1])
packages = root / "manifests/workstation-packages.tsv"
recipes = root / "manifests/aur-recipes.tsv"

rows = [
    row
    for row in csv.reader(packages.read_text().splitlines(), delimiter="\t")
    if row and not row[0].startswith("#")
]
flclash_rows = [row for row in rows if row[0] == "flclash"]
if flclash_rows != [
    [
        "flclash",
        "pacman",
        "archlinuxcn",
        "pacman",
        "personal-autostart",
        "config-backed",
        "install",
        "current-explicit",
        "Graphical multi-platform proxy client from archlinuxcn with reviewed autostart entry",
    ]
]:
    raise SystemExit(f"unexpected flclash manifest row: {flclash_rows!r}")
if any(row[0] == "flclash-bin" for row in rows):
    raise SystemExit("legacy flclash-bin remains an active package row")

recipe_names = {
    row[0]
    for row in csv.reader(recipes.read_text().splitlines(), delimiter="\t")
    if row and not row[0].startswith("#")
}
if "flclash-bin" in recipe_names:
    raise SystemExit("legacy flclash-bin remains in the AUR recipe manifest")
if (root / "third_party/aur/flclash-bin").exists():
    raise SystemExit("legacy flclash-bin recipe tree still exists")

for relative in (
    "scripts/06-aur.sh",
    "fetch-aur-sources.sh",
):
    text = (root / relative).read_text()
    if "flclash-bin" in text:
        raise SystemExit(f"legacy AUR reference remains in active file: {relative}")

if "Exec=flclash\n" not in (root / "config/home/.config/autostart/FlClash.desktop").read_text():
    raise SystemExit("autostart desktop entry does not use the pacman-provided launcher")
if "|| flclash\"" not in (root / "config/home/.config/hypr/conf/autostart.lua").read_text():
    raise SystemExit("Hyprland autostart does not use the pacman-provided launcher")

packages_script = (root / "scripts/03-packages.sh").read_text()
for required in (
    'installed_packages="$(pacman -Qq)"',
    "pacman -R --noconfirm flclash-bin",
    "grep -Fx flclash",
    "legacy flclash-bin remains installed",
):
    if required not in packages_script:
        raise SystemExit(f"flclash migration guard missing: {required}")

print("flclash migration checks passed: archlinuxcn pacman target + explicit legacy replacement")
PY
