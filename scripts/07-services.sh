#!/usr/bin/env bash
# 07-services.sh - enable reviewed system services.
# Physical-scoped services only on physical machines; VM keeps user units.
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=00-utils.sh
source "${SCRIPT_DIR}/00-utils.sh"

section "Enabling system services (${MACHINE_TYPE})"

# user units (always; run as the target user so systemctl --user works)
# helper: run a command as the target user (root path uses runuser)
as_user() {
  if [[ "$(id -u)" -eq 0 ]]; then
    runuser -u "${TARGET_USER}" -- "$@"
  else
    "$@"
  fi
}

for u in "${TARGET_HOME}/.config/systemd/user/"*.service; do
  [[ -e "${u}" ]] || continue
  unit="$(basename "${u}")"
  as_user systemctl --user enable "${unit}" 2>/dev/null && log "User service: ${unit}"
done

if [[ "${MACHINE_TYPE}" == "physical" ]]; then
  SERVICES=(bluetooth.service power-profiles-daemon.service docker.service \
            libvirtd.service NetworkManager.service)
  for s in "${SERVICES[@]}"; do
    if systemctl list-unit-files "${s}" >/dev/null 2>&1; then
      run systemctl enable --now "${s}" && log "Service: ${s}"
    fi
  done
  # libvirt default network
  if command -v virsh >/dev/null 2>&1; then
    run virsh net-autostart default 2>/dev/null && log "libvirt default network autostart"
  fi
  log "Note: docker/libvirt group membership and supergfxd mode are manual"
else
  log "VM: skipping physical services"
fi

success "Service configuration complete"
