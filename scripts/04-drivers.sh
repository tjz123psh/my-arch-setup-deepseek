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
# Required drivers (graphics + ASUS) MUST install: the desktop is useless
# without them. hardware-tools (evtest/fprintd/fwupd/powertop/linux-firmware)
# are optional conveniences: a failure there warns but does not abort
# (review C-04).
DRIVER_MODULES=(graphics-amd graphics-nvidia hardware-tools asus-hardware)
REQUIRED_MODULES=(graphics-amd graphics-nvidia asus-hardware)

section "Installing GPU and platform drivers (physical)"

REQUIRED=()
OPTIONAL=()
while IFS=$'\t' read -r pkg channel repo acq module _restore pol _origin _purpose; do
  [[ -z "${pkg}" || "${pkg}" == "#"* ]] && continue
  [[ "${pol}" == "verify" || "${pol}" == "deferred" ]] && continue
  for m in "${DRIVER_MODULES[@]}"; do
    if [[ "${module}" == "${m}" ]]; then
      if [[ " ${REQUIRED_MODULES[*]} " == *" ${m} "* ]]; then
        REQUIRED+=("${pkg}")
      else
        OPTIONAL+=("${pkg}")
      fi
      break
    fi
  done
done < "${POLICY}"

# --- simulated-physical profile (review 12.8) ---
# physical-sim-vmware runs the physical branch inside a disposable VMware
# guest: driver packages are installed for real (to surface dependency and
# file conflicts), but host-only runtime effects (hardware mode switching,
# ASUS service activation on non-ASUS hardware) are recorded as
# NOT_APPLICABLE_SIMULATED instead of being treated as success/failure.
if [[ "${TEST_PROFILE:-}" == "physical-sim-vmware" ]]; then
  log "Simulated-physical profile: installing driver packages for real..."
  if (( ${#REQUIRED[@]} > 0 )); then
    run pacman -S --needed --noconfirm "${REQUIRED[@]}" || {
      error "simulated driver install failed; aborting (required)"
      exit 1
    }
  fi
  if (( ${#OPTIONAL[@]} > 0 )); then
    run pacman -S --needed --noconfirm "${OPTIONAL[@]}" || warn "optional hardware tools failed; continuing"
  fi
  log "NOT_APPLICABLE_SIMULATED: supergfxd enable (no ASUS hardware in VMware guest)"
  log "NOT_APPLICABLE_SIMULATED: GPU mode switching (no NVIDIA/AMD dGPU present)"
  success "Simulated driver stage complete (${#REQUIRED[@]} required + ${#OPTIONAL[@]} optional installed)"
  exit 0
fi

if (( ${#REQUIRED[@]} == 0 && ${#OPTIONAL[@]} == 0 )); then
  warn "no driver packages selected; continuing"
  exit 0
fi

# required drivers first: a failure here must abort, not warn-and-continue
# into a desktop that cannot render.
if (( ${#REQUIRED[@]} > 0 )); then
  log "Installing required drivers: ${REQUIRED[*]}"
  if ! run pacman -S --needed --noconfirm "${REQUIRED[@]}"; then
    error "Required driver install failed; trying individually to locate the problem..."
    failed=0
    for p in "${REQUIRED[@]}"; do
      run pacman -S --needed --noconfirm "${p}" >/dev/null 2>&1 || { error "required driver failed: ${p}"; failed=$((failed + 1)); }
    done
    if (( failed > 0 )); then
      error "${failed} required driver package(s) failed; aborting (no desktop without working GPU drivers)"
      exit 1
    fi
  fi
fi

# optional hardware tools: warn only.
if (( ${#OPTIONAL[@]} > 0 )); then
  log "Installing optional hardware tools: ${OPTIONAL[*]}"
  run pacman -S --needed --noconfirm "${OPTIONAL[@]}" || warn "optional hardware tools failed; continuing"
fi

log "Enabling ASUS control services (supergfxd)..."
run systemctl daemon-reload
# asusd.service is a static unit (triggered via supergfxd); it must not be
# enabled directly. Only supergfxd gets enabled. On a real ASUS physical
# machine the unit must exist and start: a missing/failed supergfxd is a
# required failure (review C-04).
if ! run systemctl enable --now supergfxd 2>/dev/null; then
  error "could not enable supergfxd (required on physical ASUS machine)"
  exit 1
fi
log "service: supergfxd"

success "Drivers installed (${#REQUIRED[@]} required + ${#OPTIONAL[@]} optional)"
log "Note: NVIDIA DKMS modules need a reboot to take effect; pick the GPU"
log "mode afterwards with: supergfxctl -m Hybrid (or Integrated/dGPU)."
