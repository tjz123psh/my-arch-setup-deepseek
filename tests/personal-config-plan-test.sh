#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

python - "$root" <<'PY'
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])
manifest = root / "manifests/personal-config-candidates.tsv"
if not manifest.is_file() or manifest.is_symlink():
    raise SystemExit("personal config candidate manifest is missing or unsafe")

lines = manifest.read_text().splitlines()
if not lines or lines[0] != "# schema=1":
    raise SystemExit("personal config candidate manifest schema is missing")

rows = []
seen = set()
for line_number, raw in enumerate(lines[1:], 2):
    if not raw or raw.startswith("#"):
        continue
    fields = raw.split("\t")
    if len(fields) != 7 or not all(fields):
        raise SystemExit(f"invalid personal config candidate row at line {line_number}")
    area, module, path, mode, disposition, review_state, purpose = fields
    if path in seen:
        raise SystemExit(f"duplicate personal config candidate path: {path}")
    seen.add(path)
    if path.startswith("/") or ".." in Path(path).parts:
        raise SystemExit(f"unsafe personal config candidate path: {path}")
    if not path.startswith((".config/", ".local/share/fcitx5/rime/", "scripts/")):
        raise SystemExit(f"candidate path outside approved roots: {path}")
    if "/.git/" in f"/{path}/" or path.endswith("/.git"):
        raise SystemExit(f"nested VCS state entered candidate manifest: {path}")
    if not re.fullmatch(r"[0-7]{3,4}", mode):
        raise SystemExit(f"invalid candidate mode at line {line_number}: {mode}")
    if disposition not in {"personal-include", "candidate"}:
        raise SystemExit(f"invalid candidate disposition: {disposition}")
    if review_state not in {"reviewed-functional", "metadata-only"}:
        raise SystemExit(f"invalid candidate review state: {review_state}")
    if disposition == "personal-include" and review_state != "reviewed-functional":
        raise SystemExit(f"unreviewed row marked personal-include: {path}")
    if any(ord(ch) < 32 for ch in purpose):
        raise SystemExit(f"control character in candidate purpose at line {line_number}")
    rows.append(fields)

if len(rows) != 77:
    raise SystemExit(f"expected 77 personal config candidates, found {len(rows)}")
if sum(row[4] == "personal-include" for row in rows) != 77:
    raise SystemExit("reviewed 77-file personal include boundary changed")
if sum(row[5] == "metadata-only" for row in rows) != 0:
    raise SystemExit("metadata-only candidate count changed")

required = {
    ".config/DankMaterialShell/monitors.json",
    ".config/hypr/conf/autostart.lua",
    ".config/hypr/scripts/hypr-force-kill-window",
    ".config/niri/dms/outputs.kdl",
    ".config/niri/scripts/niri-force-kill-window",
    ".config/systemd/user/openai-oauth.service",
    ".config/systemd/user/penpot-mcp.service",
    ".config/systemd/user/vellum-tray.service",
    ".config/systemd/user/vellum.service",
    ".config/rog/rog-control-center.cfg",
    ".config/autostart/FlClash.desktop",
    ".local/share/fcitx5/rime/default.custom.yaml",
    "scripts/desktop/gsudo",
    "scripts/maintenance/backup-restore",
}
missing = sorted(required - seen)
if missing:
    raise SystemExit(f"personal config candidate manifest omitted required paths: {', '.join(missing)}")

mapping_path = root / "manifests/config-mappings.tsv"
mapping_rows = {}
for line_number, raw in enumerate(mapping_path.read_text().splitlines(), 1):
    if not raw or raw.startswith("#"):
        continue
    scope, module, source, target, mode = raw.split("\t")
    mapping_rows[(scope, target)] = (module, source, mode)

expected_promotions = {
    ".config/DankMaterialShell/firefox.css": ("desktop-shared", "644"),
    ".config/DankMaterialShell/monitors.json": ("desktop-shared", "644"),
    ".config/DankMaterialShell/plugins/ShorinScreenrec/plugin.json": ("desktop-shared", "644"),
    ".config/DankMaterialShell/plugins/ShorinScreenrec/ShorinScreenrecSettings.qml": ("desktop-shared", "644"),
    ".config/DankMaterialShell/plugins/ShorinScreenrec/ShorinScreenrecWidget.qml": ("desktop-shared", "644"),
    ".config/DankMaterialShell/plugins/ShorinScreenrec/StartupCheck.qml": ("desktop-shared", "644"),
    ".config/dankcal/ui-settings.json": ("desktop-shared", "644"),
    ".config/danksearch/config.toml": ("desktop-shared", "644"),
    ".config/dgop/colors.json": ("desktop-shared", "644"),
    ".config/matugen/dms/configs/fuzzel.toml": ("desktop-shared", "644"),
    ".config/matugen/templates/fuzzel.ini": ("desktop-shared", "644"),
    ".local/share/fcitx5/rime/default.custom.yaml": ("input-fcitx-rime", "644"),
    ".local/share/fcitx5/rime/rime_ice.custom.yaml": ("input-fcitx-rime", "644"),
    "scripts/desktop/fuzzel-askpass": ("desktop-shared", "755"),
    "scripts/desktop/gsudo": ("desktop-shared", "755"),
    "scripts/desktop/screenshot-sound": ("desktop-shared", "755"),
    "scripts/maintenance/lib/ui.sh": ("desktop-shared", "644"),
    "scripts/desktop/hypr-keys": ("wm-hyprland", "755"),
    "scripts/desktop/hypr-magnifier": ("wm-hyprland", "755"),
    "scripts/desktop/niri-keys": ("wm-niri", "755"),
    "scripts/desktop/niri-quit": ("wm-niri", "755"),
    ".config/hypr/conf/autostart.lua": ("wm-hyprland", "644"),
    ".config/hypr/dms/layout.lua": ("wm-hyprland", "644"),
    ".config/hypr/dms/outputs.lua": ("wm-hyprland", "644"),
    ".config/hypr/keybinds.list": ("wm-hyprland", "644"),
    ".config/hypr/scripts/fake-overview.sh": ("wm-hyprland", "755"),
    ".config/hypr/scripts/hypr-force-kill-window": ("wm-hyprland", "755"),
    ".config/hypr/scripts/hypr-keys": ("wm-hyprland", "755"),
    ".config/niri/dms/binds.kdl": ("wm-niri", "644"),
    ".config/niri/dms/outputs.kdl": ("wm-niri", "644"),
    ".config/niri/dms/wpblur.kdl": ("wm-niri", "644"),
    ".config/niri/scripts/niri-force-kill-window": ("wm-niri", "755"),
    ".config/autostart/FlClash.desktop": ("personal-autostart", "644"),
    ".config/rog/rog-control-center.cfg": ("asus-hardware", "644"),
    ".config/systemd/user/openai-oauth.service": ("personal-user-services", "644"),
    ".config/systemd/user/penpot-mcp.service": ("personal-user-services", "644"),
    ".config/systemd/user/vellum-tray.service": ("personal-user-services", "644"),
    ".config/systemd/user/vellum.service": ("personal-user-services", "644"),
}
include_rows = {row[2]: row for row in rows if row[4] == "personal-include"}
physical_targets = {target for scope, target in mapping_rows if scope == "physical-v1"}
if set(include_rows) - physical_targets:
    missing = sorted(set(include_rows) - physical_targets)
    raise SystemExit(f"reviewed personal include lacks executable mapping: {', '.join(missing)}")
if set(expected_promotions) - set(include_rows):
    missing = sorted(set(expected_promotions) - set(include_rows))
    raise SystemExit(f"critical reviewed promotion disappeared: {', '.join(missing)}")
for target, row in include_rows.items():
    if target in expected_promotions:
        expected_module, expected_mode = expected_promotions[target]
    elif target.startswith("scripts/"):
        expected_module, expected_mode = "personal-scripts", row[3]
    else:
        raise SystemExit(f"unexpected personal include target without explicit module expectation: {target}")
    candidate_mode = row[3]
    if candidate_mode != expected_mode:
        raise SystemExit(f"candidate mode changed for {target}: {candidate_mode}")
    mapping = mapping_rows.get(("physical-v1", target))
    expected_source = f"config/home/{target}"
    if mapping is None or mapping[:2] != (expected_module, expected_source):
        raise SystemExit(f"personal include is not mapped to {expected_module}: {target}")
    declared_mode = mapping[2]
    if declared_mode != expected_mode:
        raise SystemExit(f"mapping declared mode changed for {target}: {declared_mode}")
    source_path = root / expected_source
    if not source_path.is_file() or source_path.is_symlink():
        raise SystemExit(f"promoted personal source is missing or unsafe: {expected_source}")

installer_text = (root / "installer/install.sh").read_text()
if "personal-config-candidates.tsv" in installer_text:
    raise SystemExit("planning-only personal config candidates became executable input")
PY

printf 'Personal config candidate plan checks passed.\n'
