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
inventory_path = root / "manifests/workstation-package-inventory.tsv"
reconciliation_path = root / "manifests/workstation-packages.tsv"
modules_path = root / "manifests/modules.tsv"
profiles_path = root / "manifests/profile-modules.tsv"
mappings_path = root / "manifests/config-mappings.tsv"

if not reconciliation_path.is_file() or reconciliation_path.is_symlink():
    raise SystemExit("reconciled workstation package manifest is missing or unsafe")
lines = reconciliation_path.read_text().splitlines()
if not lines or lines[0] != "# schema=1":
    raise SystemExit("reconciled workstation package manifest has an unsupported schema")

inventory: dict[str, tuple[str, str, str]] = {}
for line_number, parts in enumerate(csv.reader(inventory_path.read_text().splitlines()[1:], delimiter="\t"), 2):
    if not parts or not parts[0] or parts[0].startswith("#"):
        continue
    if len(parts) != 6:
        raise SystemExit(f"invalid source inventory row at line {line_number}")
    package, version, channel, repository, restore_mode, execution = parts
    inventory[package] = (channel, repository, restore_mode)
if len(inventory) != 178:
    raise SystemExit(f"source inventory no longer proves 178 explicit packages: {len(inventory)}")

modules: dict[str, tuple[str, ...]] = {}
for parts in csv.reader(modules_path.read_text().splitlines()[1:], delimiter="\t"):
    if parts and parts[0] and not parts[0].startswith("#"):
        modules[parts[0]] = () if parts[3] == "-" else tuple(parts[3].split(","))

asus_profile: dict[str, str] = {}
for parts in csv.reader(profiles_path.read_text().splitlines()[1:], delimiter="\t"):
    if parts and parts[0] == "asus-amd-nvidia":
        asus_profile[parts[2]] = parts[3]

asus_closure = set(asus_profile)
pending = list(asus_profile)
while pending:
    current_module = pending.pop()
    for dependency in modules[current_module]:
        if dependency not in asus_closure:
            asus_closure.add(dependency)
            pending.append(dependency)

mapping_modules: Counter[str] = Counter()
for parts in csv.reader(mappings_path.read_text().splitlines()[1:], delimiter="\t"):
    if parts and parts[0] and not parts[0].startswith("#"):
        mapping_modules[parts[1]] += 1

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
    if acquisition not in {"pacman", "archlinuxcn-bootstrap", "aur-build", "paru-bootstrap", "verify-only", "deferred"}:
        raise SystemExit(f"invalid acquisition policy for {package}: {acquisition}")
    expected_acquisition = {
        "verify": "verify-only",
        "deferred": "deferred",
    }.get(policy)
    if expected_acquisition is not None and acquisition != expected_acquisition:
        raise SystemExit(f"policy/acquisition mismatch for {package}: {policy}/{acquisition}")
    if policy == "install" and channel == "pacman" and repository in {"core", "extra", "multilib"} and acquisition != "pacman":
        raise SystemExit(f"official package has non-pacman acquisition: {package}: {acquisition}")
    if policy == "install" and channel == "aur" and acquisition not in {"aur-build", "paru-bootstrap"}:
        raise SystemExit(f"AUR package has unsafe acquisition: {package}: {acquisition}")
    if module not in modules:
        raise SystemExit(f"unknown package module for {package}: {module}")
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
    if policy != "deferred" and module not in asus_closure:
        raise SystemExit(f"package module is not offered by ASUS profile: {package}: {module}")
    if origin not in {"current-explicit", "confirmed-desired"}:
        raise SystemExit(f"invalid reconciliation origin for {package}: {origin}")
    if any(ord(character) < 32 for character in purpose):
        raise SystemExit(f"control character in purpose for {package}")
    if restore_mode == "config-backed" and mapping_modules[module] == 0:
        raise SystemExit(f"config-backed package has no same-module mapping: {package}: {module}")
    records[package] = {
        "channel": channel,
        "repository": repository,
        "acquisition": acquisition,
        "module": module,
        "restore_mode": restore_mode,
        "policy": policy,
        "origin": origin,
    }

current = {name for name, record in records.items() if record["origin"] == "current-explicit"}
if current != set(inventory):
    raise SystemExit(f"current explicit reconciliation drift: {sorted(current ^ set(inventory))}")
transitions_path = root / "manifests/package-source-transitions.tsv"
if not transitions_path.is_file() or transitions_path.is_symlink():
    raise SystemExit("package source transition manifest is missing or unsafe")
transition_lines = transitions_path.read_text().splitlines()
if not transition_lines or transition_lines[0] != "# schema=1":
    raise SystemExit("package source transition manifest has an unsupported schema")
transitions = {}
for line_number, parts in enumerate(csv.reader(transition_lines[1:], delimiter="\t"), 2):
    if not parts or not parts[0] or parts[0].startswith("#"):
        continue
    if len(parts) != 6 or not all(parts):
        raise SystemExit(f"invalid package source transition at line {line_number}")
    package, observed_channel, observed_repository, target_channel, target_repository, rationale = parts
    if package in transitions:
        raise SystemExit(f"duplicate package source transition: {package}")
    transitions[package] = (observed_channel, observed_repository, target_channel, target_repository)

source_changes = set()
for package in sorted(current):
    expected_channel, expected_repository, _old_mode = inventory[package]
    record = records[package]
    observed = (expected_channel, expected_repository)
    target = (record["channel"], record["repository"] )
    if target != observed:
        source_changes.add(package)
        if transitions.get(package) != (*observed, *target):
            raise SystemExit(f"current package source changed without exact transition evidence: {package}")
if set(transitions) != source_changes:
    raise SystemExit(f"stale or missing package source transitions: {sorted(set(transitions) ^ source_changes)}")

required_desired = {
    "alsa-ucm-conf",
    "bash",
    "bluez-utils",
    "coreutils",
    "devtools",
    "ffmpeg",
    "gawk",
    "hyprland",
    "libnotify",
    "mesa",
    "pipewire-audio",
    "python-gobject",
    "ripgrep",
    "sed",
    "ttf-jetbrains-mono-nerd",
    "udisks2",
    "wf-recorder",
    "xdg-desktop-portal",
    "xdg-desktop-portal-gtk",
    "xdg-desktop-portal-hyprland",
}
desired = {name for name, record in records.items() if record["origin"] == "confirmed-desired"}
missing_desired = required_desired - desired
if missing_desired:
    raise SystemExit(f"confirmed desired non-explicit packages are missing: {sorted(missing_desired)}")
if desired & set(inventory):
    raise SystemExit(f"desired rows duplicate explicit inventory origins: {sorted(desired & set(inventory))}")

for package in ("linuxqq-appimage", "wechat-appimage", "obsidian-bin", "google-chrome"):
    record = records.get(package)
    if record is None or record["restore_mode"] != "package-only" or record["policy"] != "install":
        raise SystemExit(f"daily application is not retained package-only: {package}: {record}")
for package in ("niri", "hyprland", "neovim", "fcitx5", "fcitx5-rime", "fish", "kitty"):
    record = records.get(package)
    if record is None or record["restore_mode"] != "config-backed":
        raise SystemExit(f"configured package lost config-backed responsibility: {package}: {record}")
for stale in ("fuzzel", "mako", "sddm"):
    if stale in records:
        raise SystemExit(f"superseded or stale package leaked into target reconciliation: {stale}")
if records["fuzzel-ime-git"]["repository"] != "aur":
    raise SystemExit("the reviewed IME-capable Fuzzel provider was lost")
if (records["paru"]["channel"], records["paru"]["repository"], records["paru"]["acquisition"]) != ("aur", "aur", "paru-bootstrap"):
    raise SystemExit(f"fixed-source Paru bootstrap policy was lost: {records['paru']}")
if records["archlinuxcn-keyring"]["acquisition"] != "archlinuxcn-bootstrap":
    raise SystemExit("archlinuxcn keyring bootstrap was flattened into an already-trusted repo install")
if records["greetd-dms-greeter-git"]["policy"] != "deferred":
    raise SystemExit("greeter deferral was lost")
for header in ("linux-headers", "linux-zen-headers"):
    if records[header]["policy"] != "install":
        raise SystemExit(f"matching kernel headers remain incorrectly manual: {header}")

print(
    "Workstation package reconciliation checks passed: "
    f"current={len(current)} desired={len(desired)} total={len(records)}"
)
PY
