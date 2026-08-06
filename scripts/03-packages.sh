#!/usr/bin/env bash
# 03-packages.sh - install the reviewed workstation package policy.
# Reads manifests/workstation-packages.tsv (reused asset); selects packages
# by module set: physical -> all modules; vm -> everything except the
# GPU/hardware-specific packages (NVIDIA driver, AMD ucode, ASUS control,
# hardware tools). mesa/vulkan stay (the compositor needs GL to render).
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=00-utils.sh
source "${SCRIPT_DIR}/00-utils.sh"

POLICY="${PROJECT_DIR}/manifests/workstation-packages.tsv"

# Driver/hardware-specific packages are excluded from the package step on
# BOTH machine types and installed by the dedicated 04-drivers step
# (physical only). amd-ucode is a CPU microcode update; the NVIDIA stack,
# ASUS control and hardware tools are host-only. mesa and the vulkan
# user-space layers stay: niri/hyprland need GL to render.
VM_SKIP_PKGS=(amd-ucode nvidia-open-dkms nvidia-utils nvidia-settings \
              nvidia-prime lib32-nvidia-utils libva-nvidia-driver libva-utils \
              asusctl rog-control-center supergfxctl \
              evtest fprintd fwupd linux-firmware powertop)

module_selected() {
  local pkg="$1"
  # Driver packages are handled by the dedicated 04-drivers step (physical
  # only), so 03-packages excludes them on BOTH machine types. This keeps
  # 03 identical between vm and physical (156 official + 14 AUR) and avoids
  # double-installing the 16 hardware driver packages. The mesa/vulkan
  # user-space GL layers are intentionally NOT excluded: VMs need them to
  # render, and on physical 04-drivers re-lists them (a no-op via --needed).
  for p in "${VM_SKIP_PKGS[@]}"; do
    [[ "${pkg}" == "${p}" ]] && return 1
  done
  return 0
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
  module_selected "${pkg}" || continue
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
# rustup conflicts with the rust/cargo packages but provides them too.
# Install it first so any package depending on cargo/rust (e.g. cargo-audit)
# is satisfied via rustup's provides instead of pulling the conflicting rust
# package during the batch dependency resolve.
if [[ " ${OFFICIAL[*]} " == *" rustup "* ]]; then
  log "Installing rustup first (it conflicts with rust/cargo)..."
  run pacman -S --needed --noconfirm rustup
fi
log "Installing official/archlinuxcn packages..."
run pacman -S --needed --noconfirm "${OFFICIAL[@]}" || {
  error "Official package install failed; retrying once (mirror stalls are common)..."
  if ! run pacman -S --needed --noconfirm "${OFFICIAL[@]}"; then
    error "Retry failed; installing individually to locate the problem..."
    failed=0
    for p in "${OFFICIAL[@]}"; do
      if ! run pacman -S --needed --noconfirm "${p}" >/dev/null 2>&1; then
        warn "failed: ${p}"
        failed=$((failed + 1))
      fi
    done
    if (( failed > 0 )); then
      error "${failed} official package(s) failed to install; rerun install.sh to resume (03 will be retried)"
      exit 1
    fi
  fi
}

success "Package install complete (${#OFFICIAL[@]} official + ${#AUR_PKGS[@]} AUR pending step 05)"
