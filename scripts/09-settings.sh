#!/usr/bin/env bash
# 09-settings.sh - system settings matching the operator host snapshot:
# locale (zh_CN.UTF-8 + en_US.UTF-8), timezone (Asia/Shanghai), hostname
# (default), zram swap, and the 32-bit multilib flag already handled by 01.
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=00-utils.sh
source "${SCRIPT_DIR}/00-utils.sh"

section "System settings"

# --- locale ---
log "Configuring locale (zh_CN.UTF-8, en_US.UTF-8)..."
# A fresh base may ship a minimal locale.gen (e.g. cloud-init image) with no
# commented zh_CN line; sed-uncommenting then misses it. Enable lines that
# exist, and append missing ones.
run bash -c 'sed -i "s/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/; s/^#zh_CN.UTF-8 UTF-8/zh_CN.UTF-8 UTF-8/" /etc/locale.gen; grep -q "^en_US.UTF-8 UTF-8" /etc/locale.gen || echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen; grep -q "^zh_CN.UTF-8 UTF-8" /etc/locale.gen || echo "zh_CN.UTF-8 UTF-8" >> /etc/locale.gen'
run locale-gen
run bash -c 'printf "LANG=zh_CN.UTF-8\nLC_CTYPE=en_US.UTF-8\n" > /etc/locale.conf'
success "Locale: LANG=zh_CN.UTF-8, LC_CTYPE=en_US.UTF-8"

# --- timezone ---
log "Setting timezone to Asia/Shanghai..."
run bash -c 'ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime'
run bash -c 'printf "Asia/Shanghai\n" > /etc/timezone'
success "Timezone: Asia/Shanghai"

# --- hostname (default unless already set) ---
if [[ ! -s /etc/hostname ]]; then
  log "Setting hostname to archlinux..."
  run bash -c 'printf "archlinux\n" > /etc/hostname'
else
  log "Hostname already set: $(cat /etc/hostname)"
fi

# --- zram (matches host /etc/systemd/zram-generator.conf) ---
if ! pacman -Q zram-generator >/dev/null 2>&1; then
  log "Installing zram-generator..."
  run pacman -S --needed --noconfirm zram-generator
fi
log "Writing zram-generator.conf..."
run bash -c 'cat > /etc/systemd/zram-generator.conf <<EOF
[zram0]
zram-size = ram
compression-algorithm = zstd
EOF'
run systemctl daemon-reload
success "zram configured (zstd, size=ram)"

# --- standard user directories (empty, xdg defaults) ---
# Operator decision (2026-08-05): only create the default empty dirs that a
# fresh xdg-user-dirs setup provides; the host's existing files in them are
# personal data and are NOT migrated. user-dirs.dirs is deployed by 07-config
# and defines the paths; this step creates the directories themselves.
log "Creating standard user directories (Desktop/Documents/Downloads/Music/Public/Templates/Videos)..."
STD_DIRS=(Desktop Documents Downloads Music Public Templates Videos)
if [[ "$(id -u)" -eq 0 ]]; then
  for d in "${STD_DIRS[@]}"; do
    mkdir -p "${TARGET_HOME}/${d}"
    chown "${TARGET_USER}:${TARGET_USER}" "${TARGET_HOME}/${d}"
  done
else
  for d in "${STD_DIRS[@]}"; do
    mkdir -p "${HOME}/${d}"
  done
fi
success "Standard user directories ready"

# --- dms plugin runtime dependencies ---
# dankmaintenance and ShorinScreenrec run a startup check that requires these
# paths; a fresh install lacks them, so the plugins report "启动失败" until the
# directories exist. Create them so the plugins load right after deployment.
# shorin-screenrec-menu (user script, kept under config/home/.local/bin) is
# installed to /usr/local/bin because the plugin's startup check runs under
# `sh -c 'command -v ...'` whose PATH does not include ~/.local/bin.
log "Creating dms plugin dependency paths..."
mkdir -p "${TARGET_HOME}/.cache/checkallupdates"
if [[ "$(id -u)" -eq 0 ]]; then
  chown "${TARGET_USER}:${TARGET_USER}" "${TARGET_HOME}/.cache/checkallupdates"
fi
run mkdir -p /.snapshots /home/.snapshots
if [[ -f "${PROJECT_DIR}/config/home/.local/bin/shorin-screenrec-menu" ]]; then
  run install -m 755 "${PROJECT_DIR}/config/home/.local/bin/shorin-screenrec-menu" /usr/local/bin/shorin-screenrec-menu
  log "Deployed shorin-screenrec-menu to /usr/local/bin"
else
  warn "shorin-screenrec-menu not found in config; ShorinScreenrec plugin may fail its startup check"
fi

# Preset the recording engine per machine type. The plugin's startup check
# only verifies shorin-screenrec-menu exists; the actual engine pick happens
# at record time from ~/.cache/shorin-screenrec/engine. The script defaults
# to wl-screenrec (GPU), which starts and immediately fails on a VM without
# GPU acceleration - so a VM must be pinned to wf-recorder (CPU) up front.
log "Presetting screen recording engine for ${MACHINE_TYPE}..."
mkdir -p "${TARGET_HOME}/.cache/shorin-screenrec"
if [[ "${MACHINE_TYPE}" == "vm" ]]; then
  printf 'wf-recorder\n' > "${TARGET_HOME}/.cache/shorin-screenrec/engine"
else
  printf 'wl-screenrec\n' > "${TARGET_HOME}/.cache/shorin-screenrec/engine"
fi
if [[ "$(id -u)" -eq 0 ]]; then
  chown -R "${TARGET_USER}:${TARGET_USER}" "${TARGET_HOME}/.cache/shorin-screenrec"
fi
log "Recording engine: $(cat "${TARGET_HOME}/.cache/shorin-screenrec/engine")"
success "dms plugin dependencies ready"

success "System settings complete"
