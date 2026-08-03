#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tool="$root/installer/workstation-package-plan.py"
if [[ ! -f $tool || -L $tool ]]; then
  printf '%s\n' 'workstation package planner is missing or unsafe' >&2
  exit 1
fi

report=$(python "$tool" --json)
python - "$root" "$report" <<'PY'
from pathlib import Path
import json
import sys

root = Path(sys.argv[1])
report = json.loads(sys.argv[2])
if report["safety"] != {
    "planning_only": True,
    "apply_authorized": False,
    "installer_apply_integration": False,
    "system_changes": False,
}:
    raise SystemExit(f"unexpected package-plan safety boundary: {report['safety']}")
expected_counts = {
    "reconciled_packages": 198,
    "current_explicit": 178,
    "confirmed_desired": 20,
    "install": 179,
    "verify": 18,
    "deferred": 1,
    "package_only": 153,
    "config_backed": 26,
    "manual_preconditions": 18,
    "official_install": 157,
    "archlinuxcn_install": 8,
    "archlinuxcn_bootstrap": 1,
    "aur_install": 12,
    "paru_bootstrap": 1,
}
if report["counts"] != expected_counts:
    raise SystemExit(f"unexpected package-plan counts: {report['counts']}")
transaction = report["review_transaction"]
for package in ("linuxqq-appimage", "wechat-appimage", "obsidian-bin", "google-chrome"):
    if package not in transaction["package_only_packages"] or package not in transaction["aur_packages"]:
        raise SystemExit(f"daily AUR application was omitted: {package}")
for package in ("niri", "hyprland", "neovim", "fcitx5", "fcitx5-rime", "fish", "kitty"):
    if package not in transaction["config_backed_packages"]:
        raise SystemExit(f"configured package was omitted: {package}")
for package in (
    "bluez-utils", "devtools", "hyprland", "mesa", "pipewire-audio", "ripgrep",
    "ttf-jetbrains-mono-nerd", "wf-recorder", "xdg-desktop-portal",
    "xdg-desktop-portal-gtk", "xdg-desktop-portal-hyprland",
):
    if package not in transaction["confirmed_desired_packages"]:
        raise SystemExit(f"confirmed desired package was omitted: {package}")
if "greetd-dms-greeter-git" not in transaction["deferred_packages"]:
    raise SystemExit("deferred greeter decision was lost")
if "greetd-dms-greeter-git" in transaction["aur_packages"]:
    raise SystemExit("deferred greeter leaked into AUR install candidates")
if set(transaction["official_packages"]) & set(transaction["archlinuxcn_packages"]):
    raise SystemExit("official and archlinuxcn buckets overlap")
if transaction["official_command"] is not None or transaction["archlinuxcn_command"] is not None or transaction["aur_command"] is not None:
    raise SystemExit("review plan exposed an install command")
if "fuzzel" in transaction["install_packages"] or "mako" in transaction["install_packages"]:
    raise SystemExit("stale starter package leaked into reconciled install set")
if "fuzzel-ime-git" not in transaction["aur_packages"]:
    raise SystemExit("IME-capable Fuzzel provider was lost")
if transaction["paru_bootstrap_packages"] != ["paru"] or "paru" in transaction["aur_packages"]:
    raise SystemExit("Paru bootstrap leaked into the regular declared-AUR batch")
if transaction["archlinuxcn_bootstrap_packages"] != ["archlinuxcn-keyring"] or "archlinuxcn-keyring" in transaction["archlinuxcn_packages"]:
    raise SystemExit("archlinuxcn keyring bootstrap leaked into the already-trusted repository batch")
print("Workstation package plan checks passed.")
PY

if grep -Eq 'pacman -S|paru -S' <<<"$report"; then
  printf '%s\n' 'workstation package plan exposed an install command' >&2
  exit 1
fi

test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT
mkdir -p "$test_root/home"
HOME="$test_root/home" XDG_STATE_HOME="$test_root/home/.local/state" \
  "$root/installer/install.sh" --profile asus-amd-nvidia --plan \
  >"$test_root/installer-plan.out"
grep -Fq 'workstation package reconciliation: 198 policy row(s) (178 current + 20 confirmed desired), review only' \
  "$test_root/installer-plan.out" || {
  printf '%s\n' 'installer plan omitted the complete reconciled workstation policy' >&2
  exit 1
}
grep -Fq 'workstation install candidates: official=157 archlinuxcn=8 archlinuxcn-bootstrap=1 AUR=12 paru-bootstrap=1' \
  "$test_root/installer-plan.out" || {
  printf '%s\n' 'installer plan omitted trust-domain candidate counts' >&2
  exit 1
}
for package in linuxqq-appimage wechat-appimage obsidian-bin; do
  grep -Fq "[install/aur/aur/aur-build/daily-apps] $package" "$test_root/installer-plan.out" || {
    printf 'installer plan omitted daily application: %s\n' "$package" >&2
    exit 1
  }
done
for package in niri neovim fcitx5; do
  grep -Eq "\[install/pacman/(extra|core)/pacman/[^]]+\] $package" "$test_root/installer-plan.out" || {
    printf 'installer plan omitted configured package: %s\n' "$package" >&2
    exit 1
  }
done
for package in hyprland ripgrep bluez-utils xdg-desktop-portal-hyprland; do
  grep -Eq "\[install/pacman/(extra|core)/pacman/[^]]+\] $package" "$test_root/installer-plan.out" || {
    printf 'installer plan omitted confirmed desired package: %s\n' "$package" >&2
    exit 1
  }
done
[[ ! -e "$test_root/home/.local/state/my-archlinux-setup" ]] || {
  printf '%s\n' 'read-only workstation package plan wrote installer state' >&2
  exit 1
}
printf '%s\n' 'Installer workstation reconciliation plan checks passed.'

symlink_project="$test_root/symlink-project"
mkdir -p "$symlink_project/installer" "$symlink_project/manifests"
cp -- "$root/installer/install.sh" "$symlink_project/installer/install.sh"
cp -a -- "$root/config" "$symlink_project/config"
cp -- "$root/manifests/"*.tsv "$symlink_project/manifests/"
mv -- "$symlink_project/manifests/workstation-packages.tsv" \
  "$test_root/external-workstation-packages.tsv"
ln -s -- "$test_root/external-workstation-packages.tsv" \
  "$symlink_project/manifests/workstation-packages.tsv"
set +e
HOME="$test_root/home" XDG_STATE_HOME="$test_root/home/.local/state" \
  "$symlink_project/installer/install.sh" --profile asus-amd-nvidia --plan \
  >"$test_root/symlink-plan.out" 2>&1
symlink_status=$?
set -e
((symlink_status != 0)) || {
  printf '%s\n' 'symlinked workstation package policy was accepted' >&2
  exit 1
}
grep -Fq 'approved source path contains a symlink: manifests/workstation-packages.tsv' \
  "$test_root/symlink-plan.out" || {
  printf '%s\n' 'symlinked workstation policy failure was not explained' >&2
  exit 1
}
[[ ! -e "$test_root/home/.local/state/my-archlinux-setup" ]] || {
  printf '%s\n' 'rejected symlinked policy wrote installer state' >&2
  exit 1
}

malformed_project="$test_root/malformed-project"
mkdir -p "$malformed_project/installer" "$malformed_project/manifests"
cp -- "$root/installer/install.sh" "$malformed_project/installer/install.sh"
cp -a -- "$root/config" "$malformed_project/config"
cp -- "$root/manifests/"*.tsv "$malformed_project/manifests/"
printf '%s\n' $'bad-row\tpacman\textra\tpacman\tdesktop-shared\tpackage-only\texecute\tcurrent-explicit\tbad policy' \
  >>"$malformed_project/manifests/workstation-packages.tsv"
set +e
HOME="$test_root/home" XDG_STATE_HOME="$test_root/home/.local/state" \
  "$malformed_project/installer/install.sh" --profile asus-amd-nvidia --plan \
  >"$test_root/malformed-plan.out" 2>&1
malformed_status=$?
set -e
((malformed_status != 0)) || {
  printf '%s\n' 'invalid workstation package policy was accepted' >&2
  exit 1
}
grep -Fq 'invalid workstation package policy: bad-row (execute)' \
  "$test_root/malformed-plan.out" || {
  printf '%s\n' 'invalid workstation policy failure was not explained' >&2
  exit 1
}
[[ ! -e "$test_root/home/.local/state/my-archlinux-setup" ]] || {
  printf '%s\n' 'rejected malformed policy wrote installer state' >&2
  exit 1
}
printf '%s\n' 'Workstation package policy failure-path checks passed.'
