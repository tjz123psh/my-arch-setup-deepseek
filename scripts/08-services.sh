#!/usr/bin/env bash
# 08-services.sh - enable reviewed system and user services.
# Matches the operator host snapshot: greetd login (niri via dms-greeter) on
# every machine; physical-only services (bluetooth, power, docker, libvirt,
# NetworkManager, ASUS, btrfs/grub, cleanup timers). clash-verge is installed
# as a package but its service is NOT enabled (config is private).
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=00-utils.sh
source "${SCRIPT_DIR}/00-utils.sh"

section "Enabling system and user services (${MACHINE_TYPE})"

# user units (always; run as the target user so systemctl --user works)
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

# greetd login manager (every machine; niri session via dms-greeter)
log "Configuring greetd (dms-greeter -> niri)..."
run bash -c 'mkdir -p /etc/greetd/niri && cat > /etc/greetd/config.toml <<EOF
[terminal]
vt = 1

[default_session]
command = "/usr/bin/dms-greeter --command niri --cache-dir /var/cache/dms-greeter -C /etc/greetd/niri/config.kdl"
user = "greeter"
EOF'
if systemctl list-unit-files greetd >/dev/null 2>&1; then
  run systemctl enable greetd && log "Service: greetd"
fi

if [[ "${MACHINE_TYPE}" == "physical" ]]; then
  SERVICES=(bluetooth.service power-profiles-daemon.service docker.service \
            libvirtd.service NetworkManager.service \
            grub-btrfsd.service libvirt-docker-forward.service)
  for s in "${SERVICES[@]}"; do
    if systemctl list-unit-files "${s}" >/dev/null 2>&1; then
      run systemctl enable --now "${s}" && log "Service: ${s}"
    fi
  done
  # cleanup timers
  for t in paccache.timer snapper-cleanup.timer; do
    if systemctl list-unit-files "${t}" >/dev/null 2>&1; then
      run systemctl enable --now "${t}" && log "Timer: ${t}"
    fi
  done
  # libvirt default network
  if command -v virsh >/dev/null 2>&1; then
    run virsh net-autostart default 2>/dev/null && log "libvirt default network autostart"
  fi
  log "Note: docker/libvirt group membership and supergfxd mode are manual"
  log "Note: clash-verge-service is intentionally NOT enabled (private config)"
else
  log "VM: skipping physical services"
fi

success "Service configuration complete"
