#!/usr/bin/env bash
# 03-packages.sh - install the reviewed workstation package policy.
# Reads manifests/workstation-packages.tsv (reused asset); selects packages
# by module set: physical -> all modules; vm -> everything except the
# GPU/hardware-specific modules (no NVIDIA/AMD driver, no ASUS control, no
# hardware tools). Everything else installs identically on both.
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=00-utils.sh
source "${SCRIPT_DIR}/00-utils.sh"

POLICY="${PROJECT_DIR}/manifests/workstation-packages.tsv"

# Operator decision (2026-08-05): VM installs everything physical does except
# GPU/hardware modules. kernel-support stays (headers needed for DKMS).
VM_SKIP_MODULES=(graphics-amd graphics-nvidia asus-hardware hardware-tools)

module_selected() {
  local mod="$1"
  if [[ "${MACHINE_TYPE}" == "vm" ]]; then
    for m in "${VM_SKIP_MODULES[@]}"; do
      [[ "${mod}" == "${m}" ]] && return 1
    done
    return 0
  fi
  return 0  # physical: all modules
}

section "Installing packages (${MACHINE_TYPE})"
log "Reading package policy from ${POLICY} ..."

# official packages (pacman channel, install policy), filtered by module.
# NOTE: column 2 is the channel (pacman/aur), column 3 is the repository
# (core/extra/multilib/archlinuxcn). archlinuxcn packages install via pacman
# but need the [archlinuxcn] repo configured + keyring bootstrapped first.
OFFICIAL=()
AUR_PKGS=()
HAVE_ARCHLINUXCN=false
while IFS=$'\t' read -r pkg channel repo acq module _restore pol _origin _purpose; do
  [[ -z "${pkg}" || "${pkg}" == "#"* ]] && continue
  module_selected "${module}" || continue
  # verify-only rows are handoff preconditions (base/grub/linux/mkinitcpio/...)
  # checked for presence, never installed; deferred rows are never installed.
  [[ "${pol}" == "verify" || "${pol}" == "deferred" ]] && continue
  case "${channel}" in
    pacman) OFFICIAL+=("${pkg}") ;;
    aur) AUR_PKGS+=("${pkg}") ;;
  esac
  [[ "${repo}" == "archlinuxcn" ]] && HAVE_ARCHLINUXCN=true
done < "${POLICY}"

log "Official packages: ${#OFFICIAL[@]}, AUR: ${#AUR_PKGS[@]}"

# archlinuxcn repo + keyring bootstrap (only when the selection uses it)
if [[ "${HAVE_ARCHLINUXCN}" == "true" ]]; then
  log "Configuring archlinuxcn repository and keyring..."
  if ! grep -q '^\[archlinuxcn\]' /etc/pacman.conf; then
    # Multiple mirrors for failover, matching the 01-mirror strategy.
    run bash -c 'printf "%s\n" \
      "[archlinuxcn]" \
      "Server = https://mirrors.aliyun.com/archlinuxcn/\$arch" \
      "Server = https://mirrors.ustc.edu.cn/archlinuxcn/\$arch" \
      "Server = https://mirrors.tuna.tsinghua.edu.cn/archlinuxcn/\$arch" \
      >> /etc/pacman.conf'
  fi
  if ! pacman -Q archlinuxcn-keyring >/dev/null 2>&1; then
    # Let pacman resolve the exact keyring package version from the repo.
    run pacman -Sy --noconfirm || die "pacman -Sy failed; cannot reach archlinuxcn repo"
    run pacman -S --noconfirm archlinuxcn-keyring || \
      die "archlinuxcn-keyring install failed; cannot install archlinuxcn packages"
  fi
  run pacman -Sy
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
