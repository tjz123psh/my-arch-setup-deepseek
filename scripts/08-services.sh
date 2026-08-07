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
    # runuser does not inherit the caller's session env; systemctl --user
    # needs XDG_RUNTIME_DIR to reach the user bus (else enable silently
    # fails and e.g. dms.service stays disabled -> no desktop shell).
    runuser -u "${TARGET_USER}" -- env XDG_RUNTIME_DIR="/run/user/$(id -u "${TARGET_USER}")" "$@"
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
# greetd's config uses user="greeter"; the package does NOT create that user
# (verified: greetd ships no install hook). Ensure it exists so the greeter
# session can start; matches the host snapshot (greeter uid 961).
if ! getent passwd greeter >/dev/null 2>&1; then
  log "Creating greeter user for greetd..."
  run useradd --system --home-dir / --shell /bin/bash greeter || \
    warn "could not create greeter user; greetd login may fail"
fi
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
          libvirtd.service NetworkManager.service grub-btrfsd.service \
          systemd-timesyncd.service)
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
# btrfs scrub monthly timer (matches host: btrfs-scrub@-.timer enabled).
# Only meaningful on btrfs roots, so skip when the root is not btrfs.
# Check the TEMPLATE unit (btrfs-scrub@.timer): the instance @- has no unit
# file of its own, so list-unit-files on the instance name always reports
# rc=1 and the enable would be silently skipped (observed 2026-08-07).
if command -v btrfs >/dev/null 2>&1 \
  && [[ "$(findmnt -no FSTYPE / 2>/dev/null)" == "btrfs" ]] \
  && systemctl list-unit-files 'btrfs-scrub@.timer' >/dev/null 2>&1; then
  run systemctl enable --now 'btrfs-scrub@-.timer' && log "Timer: btrfs-scrub@-.timer"
fi
# libvirt default network (physical only). In the VM the operator's host
# already provides a virbr0 on 192.168.122.0/24; if the guest's own
# libvirtd autostarts its default network it creates a colliding virbr0
# on the same subnet, breaking guest networking. So skip it on vm.
if [[ "${MACHINE_TYPE}" == "physical" ]] && command -v virsh >/dev/null 2>&1; then
  run virsh net-autostart default 2>/dev/null && log "libvirt default network autostart"
fi
if [[ "${MACHINE_TYPE}" == "physical" ]]; then
  log "Note: docker/libvirt group membership and supergfxd mode are manual"
  log "Note: clash-verge-service is intentionally NOT enabled (private config)"
fi

# --- required user groups ---
# dms (DankMaterialShell) needs the 'input' group to read evdev devices for
# its plugins (dankmaintenance collect-status, ShorinScreenrec); without it
# dms logs 'insufficient permissions to access input devices' and the plugins
# appear inactive even though the files are deployed. docker/libvirt groups
# are added too so the services are usable after a relogin.
REQUIRED_GROUPS=(input docker libvirt)
for g in "${REQUIRED_GROUPS[@]}"; do
  if ! getent group "${g}" >/dev/null 2>&1; then
    run groupadd "${g}" 2>/dev/null || true
  fi
  if ! id -nG "${TARGET_USER}" 2>/dev/null | grep -qw "${g}"; then
    run usermod -a -G "${g}" "${TARGET_USER}" && log "Added ${TARGET_USER} to group ${g}"
  fi
done

# --- GRUB theme (all machine types) ---
# Operator decision (2026-08-05): the host uses the Elegant grub2 theme
# (vinceliuice/Elegant-grub2-themes, mountain-blur-left-dark). Deploy the
# captured theme files, set GRUB_THEME, then regenerate the config with
# grub-mkconfig so the theme takes effect immediately. Runs on both physical
# and VM so the theme path is exercised (and visible) everywhere. This is a
# config refresh (grub.cfg is a text menu generated from /etc/default/grub);
# the actual boot install (grub-install) remains the operator's handoff step.
THEME_DIR="/boot/grub/themes/Elegant-mountain-blur-left-dark"
log "Deploying GRUB theme (Elegant-mountain-blur-left-dark)..."
# Use cp -r (not -a): /boot is often a vfat ESP where chown/chmod are not
# supported, so -a would print a "failed to preserve ownership" error per
# file. The theme needs no special permissions; -r copies contents cleanly.
run bash -c "mkdir -p /boot/grub/themes && cp -r '${PROJECT_DIR}/config/etc/grub/themes/Elegant-mountain-blur-left-dark' /boot/grub/themes/"
if [[ ! -f /etc/default/grub ]]; then
  warn "/etc/default/grub missing; GRUB theme not configured (is grub installed?)"
elif ! grep -q '^GRUB_THEME=' /etc/default/grub; then
  run bash -c 'echo "GRUB_THEME=\"/boot/grub/themes/Elegant-mountain-blur-left-dark/theme.txt\"" >> /etc/default/grub'
else
  log "GRUB_THEME already present in /etc/default/grub"
fi
# Ensure a graphical terminal (gfxterm): grub-mkconfig only applies GRUB_THEME
# when gfxterm is enabled. The legacy GRUB_TERMINAL variable (deprecated in
# grub-mkconfig) overrides both INPUT/OUTPUT, so a handoff/base install that
# set GRUB_TERMINAL="serial console" would silently drop the theme. Remove it
# and force GRUB_TERMINAL_OUTPUT="gfxterm".
run bash -c '
  sed -i "/^GRUB_TERMINAL=/d" /etc/default/grub
  if ! grep -q "^GRUB_TERMINAL_OUTPUT=.*gfxterm" /etc/default/grub; then
    sed -i "s|^GRUB_TERMINAL_OUTPUT=.*|GRUB_TERMINAL_OUTPUT=\"gfxterm\"|" /etc/default/grub
    grep -q "^GRUB_TERMINAL_OUTPUT=" /etc/default/grub || echo "GRUB_TERMINAL_OUTPUT=\"gfxterm\"" >> /etc/default/grub
  fi
'
log "Enabled GRUB gfxterm for the theme"
# regenerate the menu so the theme applies now; back up the current
# grub.cfg first and never abort the install if regeneration fails.
if command -v grub-mkconfig >/dev/null 2>&1; then
  log "Regenerating GRUB config (grub-mkconfig)..."
  run bash -c 'cp -f /boot/grub/grub.cfg /boot/grub/grub.cfg.bak-$(date +%Y%m%d%H%M%S) 2>/dev/null || true'
  if run grub-mkconfig -o /boot/grub/grub.cfg 2>/dev/null; then
    success "GRUB theme applied (grub.cfg regenerated)"
  else
    warn "grub-mkconfig failed; run 'sudo grub-mkconfig -o /boot/grub/grub.cfg' manually"
  fi
else
  warn "grub-mkconfig not found; run it manually after installing grub"
fi

# --- paru.conf (AUR helper options, matches host snapshot) ---
log "Deploying paru.conf..."
run bash -c "cp -f '${PROJECT_DIR}/config/etc/paru.conf' /etc/paru.conf && chmod 644 /etc/paru.conf"

success "Service configuration complete"
