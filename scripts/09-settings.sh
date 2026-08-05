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

success "System settings complete"
