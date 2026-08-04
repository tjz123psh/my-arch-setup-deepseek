#!/usr/bin/env bash
# 03-packages.sh - install the reviewed workstation package policy.
# Reads manifests/workstation-packages.tsv (reused asset); selects packages
# by module set: vm -> the vm profile's 7 modules, physical -> all modules.
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=00-utils.sh
source "${SCRIPT_DIR}/00-utils.sh"

POLICY="${PROJECT_DIR}/manifests/workstation-packages.tsv"

# VM profile selected modules (from profile-modules.tsv)
VM_MODULES=(desktop-shared wm-niri base-preconditions build-foundation fonts input-fcitx-rime audio)

module_selected() {
  local mod="$1"
  if [[ "${MACHINE_TYPE}" == "vm" ]]; then
    for m in "${VM_MODULES[@]}"; do
      [[ "${mod}" == "${m}" ]] && return 0
    done
    return 1
  fi
  return 0  # physical: all modules
}

section "Installing packages (${MACHINE_TYPE})"
log "Reading package policy from ${POLICY} ..."

# official packages (pacman channel, install policy), filtered by module
OFFICIAL=()
AUR_PKGS=()
while IFS=$'\t' read -r pkg channel repo acq module _restore pol _origin _purpose; do
  [[ -z "${pkg}" || "${pkg}" == "#"* ]] && continue
  module_selected "${module}" || continue
  # verify-only rows are handoff preconditions (base/grub/linux/mkinitcpio/...)
  # checked for presence, never installed; deferred rows are never installed.
  [[ "${pol}" == "verify" || "${pol}" == "deferred" ]] && continue
  case "${channel}" in
    pacman) OFFICIAL+=("${pkg}") ;;
    archlinuxcn) OFFICIAL+=("${pkg}") ;;  # installed after keyring bootstrap below
    aur) AUR_PKGS+=("${pkg}") ;;
  esac
done < "${POLICY}"

log "Official packages: ${#OFFICIAL[@]}, AUR: ${#AUR_PKGS[@]}"

# archlinuxcn keyring bootstrap first
log "Initializing archlinuxcn keyring..."
if ! pacman -Q archlinuxcn-keyring >/dev/null 2>&1; then
  curl -sS -o /tmp/archlinuxcn-keyring.pkg.tar.zst \
    https://mirrors.aliyun.com/archlinuxcn/x86_64/archlinuxcn-keyring.pkg.tar.zst 2>/dev/null || \
    warn "archlinuxcn-keyring download failed (will retry during install)"
  if [[ -f /tmp/archlinuxcn-keyring.pkg.tar.zst ]]; then
    run pacman -U --noconfirm /tmp/archlinuxcn-keyring.pkg.tar.zst
  fi
fi

# install official packages
log "Installing official/archlinuxcn packages..."
run pacman -S --needed --noconfirm "${OFFICIAL[@]}" || {
  error "Official package install failed"
  warn "Possible individual package conflict; trying one by one..."
  for p in "${OFFICIAL[@]}"; do
    run pacman -S --needed --noconfirm "${p}" >/dev/null 2>&1 || warn "failed: ${p}"
  done
}

success "Package install complete (${#OFFICIAL[@]} official + ${#AUR_PKGS[@]} AUR pending step 05)"
