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

# UWSM_BIN is injectable so tests are independent of the host's PATH (a host
# with or without uwsm installed must behave identically; Codex R4.1). The
# greetd/dms-greeter/niri preflight paths are injectable the same way
# (R4.2/R4.3).
UWSM_BIN="${UWSM_BIN:-uwsm}"
PYTHON_BIN="${PYTHON_BIN:-python3}"
GREETD_SERVICE_UNIT="${GREETD_SERVICE_UNIT:-/usr/lib/systemd/system/greetd.service}"
DMS_GREETER_BIN="${DMS_GREETER_BIN:-/usr/bin/dms-greeter}"
NIRI_BIN="${NIRI_BIN:-/usr/bin/niri}"
GREETER_CONFIG_DIR="${GREETER_CONFIG_DIR:-${PROJECT_DIR}/config/etc/greetd/niri}"
GREETER_USER_NAME="${GREETER_USER_NAME:-greeter}"

# P1-4 / Codex R4.5: 07-config deploys user units into ~/.config/systemd/user.
# A is a TRUE zero-modification preflight: NO daemon-reload, NO stale
# cleanup, NO LoadState query, NO memory migration, NO enable, NO /etc write
# until every preflight check (python validator, uwsm, greetd.service,
# dms-greeter, niri, greeter config sources, secondary candidate) has
# succeeded. Only then is the user manager reloaded (so enable/LoadState
# below see freshly deployed units), followed by B safe backup+cleanup,
# C verify UWSM's effective entry, D enable/write. A preflight failure
# therefore leaves the log free of daemon-reload.

# --- A. zero-modification preflight (desktop modes) ---
if [[ "${DESKTOP_ENV}" != "none" ]]; then
  if [[ ! -f /usr/lib/systemd/user/dms.service ]]; then
    error "dms.service unit missing from /usr/lib/systemd/user (dms-shell not installed?)"
    exit 1
  fi
  if [[ ! -f /usr/lib/systemd/user/dsearch.service ]]; then
    warn "dsearch.service unit missing from /usr/lib/systemd/user (optional)"
  fi
  # R4.2 item 5: greetd login chain must be complete BEFORE cleanup /
  # enable / any /etc write; a missing greetd must never silently pass.
  if [[ ! -f "${GREETD_SERVICE_UNIT}" ]]; then
    error "greetd.service unit missing (${GREETD_SERVICE_UNIT}); the desktop modes require greetd for login"
    exit 1
  fi
  if [[ ! -x "${DMS_GREETER_BIN}" ]]; then
    error "dms-greeter binary missing (${DMS_GREETER_BIN}); the greetd login screen cannot start"
    exit 1
  fi
  # R4.3 item 5: `dms-greeter --command niri` really needs the niri
  # executable; checked BEFORE stale cleanup / enable / memory / /etc writes.
  if [[ ! -x "${NIRI_BIN}" ]]; then
    error "niri missing (${NIRI_BIN}); the greeter login screen cannot start"
    exit 1
  fi
  if [[ ! -f "${GREETER_CONFIG_DIR}/config.kdl" || ! -f "${GREETER_CONFIG_DIR}/dms.kdl" ]]; then
    error "greeter config sources missing under ${GREETER_CONFIG_DIR} (config.kdl / dms.kdl)"
    exit 1
  fi
  if [[ "${DESKTOP_ENV}" == "both" ]]; then
    # R4.4: the python validator MUST be available and runnable BEFORE any
    # cleanup / backup / daemon-reload / memory migration / enable / /etc
    # write. An interpreter failure (42/126/127/...) is an infrastructure
    # error, never a "corrupt desktop entry".
    if ! command -v "${PYTHON_BIN}" >/dev/null 2>&1; then
      error "python/validator unavailable (${PYTHON_BIN} not found); cannot validate the UWSM desktop entry"
      exit 1
    fi
    if ! "${PYTHON_BIN}" -c 'import sys; sys.exit(0)' >/dev/null 2>&1; then
      error "python/validator unavailable (${PYTHON_BIN} interpreter failed); cannot validate the UWSM desktop entry"
      exit 1
    fi
    missing_hypr=0
    if ! command -v "${UWSM_BIN}" >/dev/null 2>&1; then
      error "uwsm not found (${UWSM_BIN}; uwsm package missing from the wm-hyprland install?)"
      missing_hypr=1
    fi
    uwsm_entry="/usr/share/wayland-sessions/hyprland-uwsm.desktop"
    if [[ ! -f "${uwsm_entry}" ]]; then
      error "hyprland-uwsm.desktop session entry missing (hyprland package too old?)"
      missing_hypr=1
    else
      uwsm_exec="$(sed -n 's/^Exec=//p' "${uwsm_entry}" | head -1)"
      uwsm_try="$(sed -n 's/^TryExec=//p' "${uwsm_entry}" | head -1)"
      if [[ "${uwsm_exec}" != "uwsm start -e -D Hyprland hyprland.desktop" ]]; then
        error "hyprland-uwsm.desktop Exec unexpected: '${uwsm_exec}' (expected: uwsm start -e -D Hyprland hyprland.desktop)"
        missing_hypr=1
      fi
      if [[ "${uwsm_try}" != "uwsm" ]]; then
        error "hyprland-uwsm.desktop TryExec unexpected: '${uwsm_try}' (expected: uwsm)"
        missing_hypr=1
      fi
    fi
    # classification (informational): where does `hyprland.desktop` resolve
    # BEFORE cleanup? The authoritative check runs after cleanup in C. rc=1
    # (no candidate) and rc=3 (validator unavailable) both fail HERE, before
    # cleanup - cleanup cannot create a system entry and must never run
    # without a working validator (R4.4).
    rc_pre=0
    pre_resolved="$(resolve_hyprland_desktop)" || rc_pre=$?
    if [[ "${rc_pre}" -eq 1 ]]; then
      error "no hyprland.desktop candidate found for UWSM secondary resolution; cleanup cannot create a system entry"
      exit 1
    fi
    if [[ "${rc_pre}" -eq 2 ]]; then
      warn "preflight: hyprland.desktop first candidate unusable: ${pre_resolved}"
    elif [[ "${rc_pre}" -eq 3 ]]; then
      error "python/validator unavailable during preflight; cannot validate the UWSM desktop entry"
      exit 1
    elif [[ -n "${pre_resolved}" && "${pre_resolved}" != "/usr/share/wayland-sessions/hyprland.desktop" ]]; then
      warn "preflight: hyprland.desktop currently resolves to ${pre_resolved} (non-system); exact project files are removed below, a user-modified copy stays and BLOCKS verification"
    fi
    if (( missing_hypr > 0 )); then
      error "uwsm-managed Hyprland session components missing (${missing_hypr}); refusing to continue"
      exit 1
    fi
    log "preflight: uwsm + hyprland-uwsm.desktop present"
  fi
fi

# A succeeded (or DESKTOP_ENV=none, where A is empty): now reload the user
# manager so enable/LoadState below see freshly deployed units. A preflight
# failure above exits BEFORE this point, so the log stays free of
# daemon-reload (R4.5 item 1).
as_user systemctl --user daemon-reload || warn "user daemon-reload failed"

# --- B. safe backup + cleanup (all modes; a both->none downgrade cleans too) ---
# stale_hypr_cleanup (00-utils): lstat-every-component path safety, only
# exact-content project files removed (backup first), Round-2 watcher set
# detected+warned only (content never committed, no guessing).
stale_hypr_cleanup
as_user systemctl --user daemon-reload || warn "user daemon-reload failed after stale cleanup"
for stale_unit in hyprland.service hyprland-shutdown.target hyprland-session.target hyprland-session.service; do
  # LoadState with the REAL query rc (R4.3 item 3): only query_rc=0 AND
  # LoadState=not-found is written as confirmed. A nonzero rc (even with
  # stdout=not-found), empty or unknown stdout are all NOT confirmed.
  query_rc=0
  query_stdout="$(as_user systemctl --user show -p LoadState --value "${stale_unit}" 2>/dev/null)" || query_rc=$?
  if [[ "${query_rc}" -ne 0 ]]; then
    warn "query failed (rc=${query_rc}) for stale unit ${stale_unit}; cleanup NOT confirmed"
  elif [[ -z "${query_stdout}" ]]; then
    warn "empty LoadState for stale unit ${stale_unit}; cleanup NOT confirmed"
  elif [[ "${query_stdout}" == "not-found" ]]; then
    log "confirmed: stale unit ${stale_unit} no longer loads (LoadState=not-found)"
  elif [[ "${query_stdout}" == "loaded" ]]; then
    warn "stale unit ${stale_unit} still loads (LoadState=loaded; left in place or provided elsewhere)"
  else
    warn "stale unit ${stale_unit} state=${query_stdout} (unknown); cleanup NOT confirmed"
  fi
done

# --- C. verify UWSM's effective secondary entry (both) ---
# `uwsm start -e -D Hyprland hyprland.desktop` re-resolves hyprland.desktop
# via XDG_DATA_HOME -> /usr/local/share -> /usr/share. A user/local override
# that survived cleanup would shadow the system entry and break the
# uwsm-managed session; fail closed with the offending path (Codex R4.1).
if [[ "${DESKTOP_ENV}" == "both" ]]; then
  rc_res=0
  resolved="$(resolve_hyprland_desktop)" || rc_res=$?
  if [[ "${rc_res}" -eq 2 ]]; then
    error "UWSM secondary entry unusable: ${resolved} exists but is a symlink/non-regular/corrupt desktop file; remove or fix it, then re-run"
    exit 1
  fi
  if [[ "${rc_res}" -eq 3 ]]; then
    error "python/validator unavailable; cannot validate the UWSM desktop entry (dependency missing)"
    exit 1
  fi
  if [[ -z "${resolved}" ]]; then
    error "no hyprland.desktop found for UWSM secondary resolution (expected /usr/share/wayland-sessions/hyprland.desktop)"
    exit 1
  fi
  if [[ "${resolved}" != "/usr/share/wayland-sessions/hyprland.desktop" ]]; then
    error "UWSM would resolve a non-system hyprland.desktop: ${resolved} (a user/local override shadows the system entry; the uwsm-managed session would be broken). Remove or restore it, then re-run."
    exit 1
  fi
  log "uwsm-managed Hyprland session verified (uwsm + hyprland-uwsm.desktop + effective hyprland.desktop)"
  # dms-greeter remembers the last session; migrate any old
  # hyprland.desktop memory reference to hyprland-uwsm.desktop atomically
  # (Codex R4.2 item 7); failure is fail-closed with the path reported.
  # /var/cache/dms-greeter is normally owned by the greeter account; the
  # desktop user may be unable to traverse its parent directories.  Keep the
  # migration fail-closed, but run only this narrowly scoped transaction via
  # the existing privileged wrapper when needed.  The utility itself remains
  # unprivileged by default for direct callers and tests.
  if ! GREETER_MEMORY_USE_PRIVILEGED_RUN=1 migrate_greeter_memory; then
    error "dms-greeter session memory still references the old hyprland.desktop and could not be migrated; remove/fix the reported file(s), then re-run"
    exit 1
  fi
fi

# --- D. enable / write (desktop modes) or converge to TTY login (none) ---
if [[ "${DESKTOP_ENV}" != "none" ]]; then
  # Package-provided user units that must be enabled to match the host
  # snapshot: dms.service (wants of graphical-session.target) and
  # dsearch.service (wants of default.target). They live in
  # /usr/lib/systemd/user, NOT in ~/.config/systemd/user.
  PACKAGE_USER_UNITS=(dms.service dsearch.service)
  for unit in "${PACKAGE_USER_UNITS[@]}"; do
    if [[ -f "/usr/lib/systemd/user/${unit}" ]]; then
      # dms.service is REQUIRED for both desktop modes (it is the shell);
      # a failed enable must fail the step, not warn-and-continue.
      if as_user systemctl --user enable "${unit}" 2>/dev/null; then
        log "User service: ${unit}"
      else
        if [[ "${unit}" == "dms.service" ]]; then
          error "could not enable ${unit} (required for the desktop shell)"
          exit 1
        fi
        warn "could not enable ${unit}"
      fi
    elif [[ "${unit}" == "dms.service" ]]; then
      error "dms.service unit missing from /usr/lib/systemd/user (dms-shell not installed?)"
      exit 1
    fi
  done
  # verify the actual enable result, not just an is-enabled query: the enable
  # must have created the .wants symlink that makes dms follow the session.
  dms_want="${TARGET_HOME}/.config/systemd/user/graphical-session.target.wants/dms.service"
  if [[ -L "${dms_want}" ]] && [[ -e "${dms_want}" ]]; then
    log "Verified: ${dms_want} -> $(readlink "${dms_want}")"
  else
    error "dms.service not enabled under graphical-session.target (missing ${dms_want})"
    exit 1
  fi

  # user-provided units under ~/.config/systemd/user (vellum, custom services...)
  for u in "${TARGET_HOME}/.config/systemd/user/"*.service; do
    [[ -e "${u}" ]] || continue
    unit="$(basename "${u}")"
    as_user systemctl --user enable "${unit}" 2>/dev/null && log "User service: ${unit}"
  done

  # greetd login manager. `--command niri` selects ONLY the compositor that
  # renders the GREETER login screen itself - it does NOT set the target
  # user's default session (Codex R4.2 item 7): the user's session is chosen
  # in the greeter UI and remembered in the greeter cache (an old
  # hyprland.desktop memory reference was migrated to hyprland-uwsm.desktop
  # above). dms-greeter supports --command niri|hyprland|sway|scroll|
  # miracle|mango|labwc; the greeter always runs niri (pure hyprland entry
  # removed 2026-08-08; Hyprland runs only via "both").
  greeter_cmd="dms-greeter --command niri --cache-dir /var/cache/dms-greeter -C /etc/greetd/niri/config.kdl"
  log "Configuring greetd (${greeter_cmd})..."
  if ! getent passwd "${GREETER_USER_NAME}" >/dev/null 2>&1; then
    log "Creating greeter user (${GREETER_USER_NAME}) for greetd..."
    if ! run useradd --system --home-dir / --shell /bin/bash "${GREETER_USER_NAME}"; then
      error "could not create greeter user ${GREETER_USER_NAME} (required for the greetd login screen)"
      exit 1
    fi
    # postcondition: useradd reported success but the user is still missing
    # -> fail; never leave a half-configured greetd behind (R4.3 item 5)
    if ! getent passwd "${GREETER_USER_NAME}" >/dev/null 2>&1; then
      error "greeter user ${GREETER_USER_NAME} still missing after useradd (getent check failed); refusing to continue"
      exit 1
    fi
  fi
  run bash -c "mkdir -p /etc/greetd/niri && cat > /etc/greetd/config.toml <<EOF
[terminal]
vt = 1

[default_session]
command = \"/usr/bin/${greeter_cmd}\"
user = \"greeter\"
EOF"
  run bash -c "mkdir -p /etc/greetd/niri && cp -f '${GREETER_CONFIG_DIR}/config.kdl' /etc/greetd/niri/config.kdl && cp -f '${GREETER_CONFIG_DIR}/dms.kdl' /etc/greetd/niri/dms.kdl && chown root:${GREETER_USER_NAME} /etc/greetd/niri/config.kdl /etc/greetd/niri/dms.kdl && chmod 644 /etc/greetd/niri/config.kdl /etc/greetd/niri/dms.kdl"
  run systemctl daemon-reload || true
  if [[ -f "${GREETD_SERVICE_UNIT}" ]]; then
    if run systemctl enable greetd; then
      log "Service: greetd"
    else
      error "could not enable greetd.service"
      exit 1
    fi
  fi
else
  # DESKTOP_ENV=none (TTY login): converge from any previous desktop install.
  # dms and greetd are project-managed -> a failed disable FAILS the step and
  # the disabled postcondition is verified; dsearch is optional (R4.2 item 4).
  if [[ -f /usr/lib/systemd/user/dms.service ]]; then
    if ! as_user systemctl --user disable dms.service 2>/dev/null; then
      error "could not disable dms.service (DESKTOP_ENV=none convergence)"
      exit 1
    fi
    # postcondition: [[ -e || -L ]] - a dangling wants symlink still counts
    # as residual (R4.3 item 3)
    if [[ -e "${TARGET_HOME}/.config/systemd/user/graphical-session.target.wants/dms.service" \
       || -L "${TARGET_HOME}/.config/systemd/user/graphical-session.target.wants/dms.service" ]]; then
      error "dms.service still enabled after disable (graphical-session.target.wants symlink present); convergence failed"
      exit 1
    fi
    log "User service disabled: dms (DESKTOP_ENV=none convergence)"
  fi
  if [[ -f /usr/lib/systemd/user/dsearch.service ]]; then
    if as_user systemctl --user disable dsearch.service 2>/dev/null; then
      log "User service disabled: dsearch (DESKTOP_ENV=none convergence, optional)"
    else
      warn "could not disable dsearch.service (optional; was it enabled?)"
    fi
  fi
  if [[ -f "${GREETD_SERVICE_UNIT}" ]]; then
    if ! run systemctl disable greetd 2>/dev/null; then
      error "could not disable greetd.service (DESKTOP_ENV=none convergence)"
      exit 1
    fi
    # postcondition via is-enabled with its REAL rc/stdout (R4.3 item 3):
    # pass only on the canonical disabled/not-found results; enabled, empty
    # or unknown output, or a nonzero rc that is not a canonical result,
    # all fail.
    isen_rc=0
    isen_out="$(run systemctl is-enabled greetd 2>/dev/null)" || isen_rc=$?
    if [[ "${isen_rc}" -eq 1 && "${isen_out}" == "disabled" ]]; then
      log "Service disabled: greetd (DESKTOP_ENV=none convergence)"
    elif [[ "${isen_rc}" -eq 4 && "${isen_out}" == "not-found" ]]; then
      # the host's real systemctl contract: unknown unit -> rc=4 + not-found
      log "greetd is-enabled=not-found (rc=4); treated as converged (DESKTOP_ENV=none)"
    else
      error "greetd.service is-enabled query = '${isen_out}' (rc=${isen_rc}); convergence NOT verified"
      exit 1
    fi
  fi
fi

# Operator decision (2026-08-05): the VM enables the same services as the
# physical machine (consistency); the services are harmless in a VM. Since
# 2026-08-08 the project runs on VMware (KVM removed from the restore
# payload), so libvirtd is no longer in the service set; VMware host/guest
# services are handled below per machine role.
SERVICES=(bluetooth.service power-profiles-daemon.service docker.service \
          NetworkManager.service grub-btrfsd.service \
          systemd-timesyncd.service)
run systemctl daemon-reload
for s in "${SERVICES[@]}"; do
  if run systemctl enable --now "${s}" 2>/dev/null; then
    log "Service: ${s}"
  else
    warn "could not enable ${s} (unit missing?)"
  fi
done
# cleanup + timeline timers. snapper-timeline.timer is what actually
# schedules the hourly TIMELINE_CREATE snapshots from each snapper config;
# without it the configs say TIMELINE_CREATE=yes but no snapshot is ever
# auto-created (matches host: snapper-timeline.timer enabled).
for t in paccache.timer snapper-cleanup.timer snapper-timeline.timer; do
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
# --- VMware role services (KVM removed from the restore payload 2026-08-08) ---
# physical / VMware host: vmware-networks + vmware-usbarbitrator (matches the
# host snapshot). vmware-networks-configuration.service is static (oneshot)
# and is NOT enabled; there is no vmware-vmnet.service unit (host ops notes
# 2026-08-07). In the simulated-physical profile inside a VMware guest,
# starting the host network stack would nest VMware networking - record the
# action as NOT_APPLICABLE_SIMULATED instead of executing it.
if [[ "${MACHINE_TYPE}" == "physical" ]]; then
  if [[ "${TEST_PROFILE:-}" == "physical-sim-vmware" ]]; then
    log "NOT_APPLICABLE_SIMULATED: vmware-networks.service enable (no nested host networking in guest)"
    log "NOT_APPLICABLE_SIMULATED: vmware-usbarbitrator.service enable (no host USB arbitration in guest)"
  else
    for s in vmware-networks.service vmware-usbarbitrator.service; do
      if [[ -f "/usr/lib/systemd/system/${s}" ]]; then
        run systemctl enable --now "${s}" && log "Service: ${s}"
      else
        warn "VMware host service unit missing: ${s} (is vmware-workstation installed?)"
      fi
    done
    # DKMS module verification: vmmon/vmnet must build and load. The unit
    # check above is not enough - a DKMS rebuild after a kernel upgrade can
    # silently break module loading. Required when Workstation is installed:
    # a missing vmmon module means the VMware host stack cannot run (P1-8).
    if [[ -f /usr/lib/systemd/system/vmware-networks.service ]] \
       && command -v dkms >/dev/null 2>&1; then
      if ! dkms status 2>/dev/null | grep -q vmmon; then
        error "dkms status shows no vmmon module; VMware host stack cannot load (run: sudo dkms autoinstall; kernel headers required)"
        exit 1
      fi
    fi
  fi
  log "Note: docker group membership and supergfxd mode are manual"
  log "Note: clash-verge-service is intentionally NOT enabled (private config)"
elif [[ "${MACHINE_TYPE}" == "vm" ]]; then
  # vm / VMware guest: vmtoolsd is the required guest core (P1-8) - a
  # missing unit or a failed enable FAILS the step. vmware-vmblock-fuse is
  # optional (copy/paste + drag&drop) and only enabled when present.
  if [[ -f /usr/lib/systemd/system/vmtoolsd.service ]]; then
    if run systemctl enable --now vmtoolsd.service; then
      log "Service: vmtoolsd.service"
    else
      error "could not enable vmtoolsd.service"
      exit 1
    fi
  else
    error "vmtoolsd.service unit missing (open-vm-tools not installed?)"
    exit 1
  fi
  if [[ -f /usr/lib/systemd/system/vmware-vmblock-fuse.service ]]; then
    run systemctl enable --now vmware-vmblock-fuse.service && log "Service: vmware-vmblock-fuse.service"
  fi
fi

# --- required user groups ---
# dms (DankMaterialShell) needs the 'input' group to read evdev devices for
# its plugins (dankmaintenance collect-status, ShorinScreenrec); without it
# dms logs 'insufficient permissions to access input devices' and the plugins
# appear inactive even though the files are deployed. The docker group is
# added too so docker is usable after a relogin. (libvirt group was removed
# with the KVM->VMware migration on 2026-08-08.)
REQUIRED_GROUPS=(input docker)
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
log "Deploying GRUB theme (${THEME_DIR})..."
# Use cp -r (not -a): /boot is often a vfat ESP where chown/chmod are not
# supported, so -a would print a "failed to preserve ownership" error per
# file. The theme needs no special permissions; -r copies contents cleanly.
run bash -c "mkdir -p /boot/grub/themes && cp -r '${PROJECT_DIR}/config/etc/grub/themes/Elegant-mountain-blur-left-dark' /boot/grub/themes/"
if [[ ! -f /etc/default/grub ]]; then
  warn "/etc/default/grub missing; GRUB theme not configured (is grub installed?)"
elif ! grep -q '^GRUB_THEME=' /etc/default/grub; then
  run bash -c "echo 'GRUB_THEME=\"${THEME_DIR}/theme.txt\"' >> /etc/default/grub"
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
