#!/usr/bin/env bash
# 04-drivers.sh - install GPU and platform drivers BEFORE the desktop.
#
# Physical ASUS (AMD iGPU + NVIDIA dGPU): install the reviewed driver set
# first so the desktop never renders without working graphics. VMs skip this
# step entirely (no real GPU). supergfxctl mode is left at its default; the
# operator picks Hybrid/Integrated/dGPU after reboot via supergfxctl.
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=00-utils.sh
source "${SCRIPT_DIR}/00-utils.sh"

if [[ "${MACHINE_TYPE}" != "physical" ]]; then
  log "VM: skipping driver step (no real GPU)."
  exit 0
fi

POLICY="${PROJECT_DIR}/manifests/workstation-packages.tsv"

# Driver modules: AMD iGPU stack, NVIDIA dGPU stack, platform firmware,
# ASUS control (asusctl/rog-control-center/supergfxctl come from archlinuxcn,
# which 03-packages already configured and bootstrapped).
DRIVER_MODULES=(graphics-amd graphics-nvidia hardware-tools asus-hardware)

section "Installing GPU and platform drivers (physical)"

DRIVERS=()
while IFS=$'\t' read -r pkg channel repo acq module _restore pol _origin _purpose; do
  [[ -z "${pkg}" || "${pkg}" == "#"* ]] && continue
  [[ "${pol}" == "verify" || "${pol}" == "deferred" ]] && continue
  for m in "${DRIVER_MODULES[@]}"; do
    if [[ "${module}" == "${m}" ]]; then
      DRIVERS+=("${pkg}")
      break
    fi
  done
done < "${POLICY}"

if (( ${#DRIVERS[@]} == 0 )); then
  warn "no driver packages selected; continuing"
  exit 0
fi

log "Installing driver packages: ${DRIVERS[*]}"
run pacman -S --needed --noconfirm "${DRIVERS[@]}" || {
  error "driver install failed; trying individually to locate the problem..."
  for p in "${DRIVERS[@]}"; do
    run pacman -S --needed --noconfirm "${p}" >/dev/null 2>&1 || warn "failed: ${p}"
  done
}

log "Enabling ASUS control services (asusd, supergfxd)..."
run systemctl daemon-reload
for svc in asusd supergfxd; do
  if run systemctl enable --now "${svc}" 2>/dev/null; then
    log "service: ${svc}"
  else
    warn "could not enable ${svc} (unit missing on this machine)"
  fi
done

success "Drivers installed (${#DRIVERS[@]} packages)"
log "Note: NVIDIA DKMS modules need a reboot to take effect; pick the GPU"
log "mode afterwards with: supergfxctl -m Hybrid (or Integrated/dGPU)."
