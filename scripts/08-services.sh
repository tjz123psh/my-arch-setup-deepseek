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

# Package-provided user units that must be enabled to match the host snapshot:
# dms.service (DankMaterialShell, wants of niri.service) and dsearch.service
# (DankSearch, wants of default.target). These live in /usr/lib/systemd/user,
# NOT in ~/.config/systemd/user, so a loop over the user config dir alone
# misses them (the earlier bug: dms stayed disabled and never autostarted).
PACKAGE_USER_UNITS=(dms.service dsearch.service)
for unit in "${PACKAGE_USER_UNITS[@]}"; do
  if [[ -f "/usr/lib/systemd/user/${unit}" ]]; then
    as_user systemctl --user enable "${unit}" 2>/dev/null && log "User service: ${unit}"
  fi
done

# user-provided units under ~/.config/systemd/user (vellum, custom services...)
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
# dms-greeter reads /etc/greetd/niri/config.kdl (which includes dms.kdl);
# deploy the reviewed greeter configs so the login screen starts.
run bash -c "cp -f '${PROJECT_DIR}/config/etc/greetd/niri/config.kdl' /etc/greetd/niri/config.kdl && cp -f '${PROJECT_DIR}/config/etc/greetd/niri/dms.kdl' /etc/greetd/niri/dms.kdl && chown root:greeter /etc/greetd/niri/config.kdl /etc/greetd/niri/dms.kdl && chmod 644 /etc/greetd/niri/config.kdl /etc/greetd/niri/dms.kdl"
# list-unit-files can report "0 unit files listed" before a daemon-reload;
# check the unit file on disk and enable directly instead.
run systemctl daemon-reload || true
if [[ -f /usr/lib/systemd/system/greetd.service ]]; then
  run systemctl enable greetd && log "Service: greetd"
fi

# Operator decision (2026-08-05): the VM enables the same services as the
# physical machine (consistency); the services are harmless in a VM. Only the
# libvirt-docker-forward helper stays manual (host-custom iptables, not a
# package) and supergfxd is not present in the VM.
SERVICES=(bluetooth.service power-profiles-daemon.service docker.service \
          libvirtd.service NetworkManager.service grub-btrfsd.service)
run systemctl daemon-reload
for s in "${SERVICES[@]}"; do
  if run systemctl enable --now "${s}" 2>/dev/null; then
    log "Service: ${s}"
  else
    warn "could not enable ${s} (unit missing?)"
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
if [[ "${MACHINE_TYPE}" == "physical" ]]; then
  log "Note: docker/libvirt group membership and supergfxd mode are manual"
  log "Note: clash-verge-service is intentionally NOT enabled (private config)"
fi

success "Service configuration complete"
