#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

python - "$root" <<'PY'
from collections import Counter
from pathlib import Path
import csv
import re
import sys

root = Path(sys.argv[1])
manifest = root / "manifests/workstation-package-inventory.tsv"
if not manifest.is_file() or manifest.is_symlink():
    raise SystemExit("workstation package inventory is missing or unsafe")
lines = manifest.read_text().splitlines()
if not lines or lines[0] != "# schema=1":
    raise SystemExit("workstation package inventory has an unsupported schema")

records = {}
for line_number, parts in enumerate(csv.reader(lines[1:], delimiter="\t"), 2):
    if not parts or not parts[0] or parts[0].startswith("#"):
        continue
    if len(parts) != 6 or not all(parts):
        raise SystemExit(f"invalid workstation package row at line {line_number}")
    package, version, channel, repository, restore_mode, execution = parts
    if not re.fullmatch(r"[a-z0-9@._+:-]+", package):
        raise SystemExit(f"unsafe package name at line {line_number}: {package}")
    if package in records:
        raise SystemExit(f"duplicate workstation package row: {package}")
    if channel not in {"pacman", "aur"}:
        raise SystemExit(f"invalid package channel for {package}: {channel}")
    expected_repositories = {
        "pacman": {"core", "extra", "multilib", "archlinuxcn"},
        "aur": {"aur"},
    }
    if repository not in expected_repositories[channel]:
        raise SystemExit(f"channel/repository mismatch for {package}: {channel}/{repository}")
    if restore_mode not in {"package-only", "config-backed", "manual-precondition", "deferred"}:
        raise SystemExit(f"invalid restore mode for {package}: {restore_mode}")
    if execution != "inventory-only":
        raise SystemExit(f"inventory row became executable: {package}: {execution}")
    if any(ord(character) < 32 for character in version):
        raise SystemExit(f"control character in version for {package}")
    records[package] = {
        "version": version,
        "channel": channel,
        "repository": repository,
        "restore_mode": restore_mode,
        "execution": execution,
    }

if len(records) != 178:
    raise SystemExit(f"expected the complete 178-package live explicit inventory, got {len(records)}")
channel_counts = Counter(record["channel"] for record in records.values())
if channel_counts != {"pacman": 165, "aur": 13}:
    raise SystemExit(f"unexpected install-channel split: {dict(channel_counts)}")
repository_counts = Counter(record["repository"] for record in records.values())
if repository_counts != {"extra": 141, "core": 13, "archlinuxcn": 10, "aur": 13, "multilib": 1}:
    raise SystemExit(f"unexpected repository split: {dict(repository_counts)}")

expected_archlinuxcn = {
    "archlinuxcn-keyring", "asusctl", "cc-switch", "downgrade", "paru",
    "rime-ice-git", "rime-wanxiang-gram-zh-hans", "rog-control-center",
    "supergfxctl", "wl-screenrec-git",
}
expected_aur = {
    "clash-verge-rev-bin", "dsearch-bin",
    "fcitx5-skin-fluentdark-git", "flclash-bin", "fuzzel-ime-git",
    "google-chrome", "greetd-dms-greeter-git",
    "leaf-markdown-viewer-bin",
    "linuxqq-appimage", "obsidian-bin", "opencode-bin", "wechat-appimage",
    "wooz-git",
}
actual_archlinuxcn = {name for name, record in records.items() if record["repository"] == "archlinuxcn"}
actual_aur = {name for name, record in records.items() if record["channel"] == "aur"}
if actual_archlinuxcn != expected_archlinuxcn:
    raise SystemExit(f"archlinuxcn package inventory drifted: {sorted(actual_archlinuxcn ^ expected_archlinuxcn)}")
if actual_aur != expected_aur:
    raise SystemExit(f"AUR package inventory drifted: {sorted(actual_aur ^ expected_aur)}")

for package in ("linuxqq-appimage", "wechat-appimage", "obsidian-bin", "google-chrome"):
    record = records.get(package)
    if record is None or record["channel"] != "aur" or record["restore_mode"] != "package-only":
        raise SystemExit(f"daily application was omitted or assigned config migration: {package}: {record}")
for package in ("niri", "neovim", "fcitx5", "fcitx5-rime", "fish", "kitty"):
    record = records.get(package)
    if record is None or record["restore_mode"] != "config-backed":
        raise SystemExit(f"configured workstation package lost config ownership: {package}: {record}")
greeter = records.get("greetd-dms-greeter-git")
if greeter is None or greeter["restore_mode"] != "deferred":
    raise SystemExit(f"deferred greeter decision was lost: {greeter}")

installer = (root / "installer/install.sh").read_text()
if "manifests/workstation-package-inventory.tsv" in installer:
    raise SystemExit("observation-only inventory became direct installer input")
if "manifests/workstation-packages.tsv" not in installer:
    raise SystemExit("installer does not consume the separate reconciled package policy")
print("Workstation package inventory checks passed.")
PY
