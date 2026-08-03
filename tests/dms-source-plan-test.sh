#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

python - "$root" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
plan = root / "docs/dms-source-plan.md"
candidates = root / "manifests/dms-package-candidates.tsv"
modules = root / "manifests/modules.tsv"
installer = root / "installer/install.sh"

for path in (plan, candidates, modules, installer):
    if not path.is_file() or path.is_symlink():
        raise SystemExit(f"DMS source input is missing or unsafe: {path.relative_to(root)}")

plan_text = plan.read_text()
for marker in (
    "Official shell choice is confirmed",
    "Greeter remains independently blocked",
    "Niri-only selector",
    "Hyprland selector",
    "Both-WM selector requires VM proof",
    "No executable module is unlocked",
    "No system changes were performed",
):
    if marker not in plan_text:
        raise SystemExit(f"DMS source plan is missing boundary: {marker}")

lines = candidates.read_text().splitlines()
if not lines or lines[0] != "# schema=1":
    raise SystemExit("unsupported or missing DMS candidate schema")
rows: dict[str, list[str]] = {}
sources = {"official", "foreign", "unresolved"}
dispositions = {"pending-decision", "proposed", "transitive", "blocked-unvalidated", "blocked-source"}
for raw in lines:
    if not raw or raw.startswith("#"):
        continue
    parts = raw.split("\t")
    if len(parts) != 7 or not all(parts):
        raise SystemExit("invalid DMS package candidate row")
    if parts[2] not in sources or parts[3] not in dispositions:
        raise SystemExit(f"invalid DMS source/disposition: {parts[1]}")
    if parts[2] != "official" and not parts[3].startswith("blocked-"):
        raise SystemExit(f"non-official DMS candidate is not blocked: {parts[1]}")
    package = parts[1]
    if package in rows:
        raise SystemExit(f"duplicate DMS package candidate: {package}")
    rows[package] = parts

required = {
    "dms-shell": ("dms-shell", "official", "proposed", "dms-selected", "-", "Shared DMS shell from Arch extra"),
    "quickshell": ("dms-shell", "official", "transitive", "dms-selected", "-", "Toolkit dependency of the official shell"),
    "dms-shell-niri": ("dms-shell", "official", "proposed", "niri-only", "-", "Zero-payload compositor dependency selector for Niri-only installs"),
    "dms-shell-hyprland": ("dms-shell", "official", "proposed", "hyprland-selected", "-", "Zero-payload compositor dependency selector when Hyprland is selected"),
    "greetd": ("dms-greetd", "official", "proposed", "dms-greetd", "greeter-source-blocked", "Official login daemon foundation"),
    "greetd-agreety": ("dms-greetd", "official", "transitive", "dms-greetd", "-", "Bundled greetd dependency, not an automatic fallback display manager"),
    "greetd-dms-greeter-git": ("dms-greetd", "foreign", "blocked-unvalidated", "dms-greetd", "rolling-unvalidated", "Currently working foreign greeter package with no package validation"),
    "greetd-dms-greeter": ("dms-greetd", "unresolved", "blocked-source", "dms-greetd", "fixed-source-required", "Future pinned and verified non-rolling greeter package"),
}
for package, expected in required.items():
    if package not in rows:
        raise SystemExit(f"missing DMS candidate: {package}")
    actual = (rows[package][0], *rows[package][2:])
    if actual != expected:
        raise SystemExit(f"incorrect DMS candidate semantics: {package}")

module_rows = {
    raw.split("\t", 1)[0]: raw.split("\t")
    for raw in modules.read_text().splitlines()
    if raw and not raw.startswith("#")
}
for module in ("dms-greetd", "dms-niri-greeter"):
    if module_rows.get(module, [None, None])[1] != "unavailable":
        raise SystemExit(f"DMS module was unlocked before source decision: {module}")

installer_text = installer.read_text()
for planning_input in ("dms-source-plan.md", "dms-package-candidates.tsv"):
    if planning_input in installer_text:
        raise SystemExit(f"DMS planning input is referenced by installer: {planning_input}")
PY

printf 'DMS source planning checks passed.\n'
