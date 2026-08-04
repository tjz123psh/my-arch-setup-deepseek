#!/usr/bin/env bash
# 01-mirror.sh - mirrorlist optimisation (China-aware).
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=00-utils.sh
source "${SCRIPT_DIR}/00-utils.sh"

section "Mirror optimization"
TZ_CFG="$(readlink -f /etc/localtime 2>/dev/null || echo '')"

if [[ "${TZ_CFG}" == *"Shanghai"* ]] || [[ "${CN_MIRROR:-0}" == "1" ]]; then
  log "China timezone detected, using Aliyun mirror..."
  run bash -c 'echo "Server = https://mirrors.aliyun.com/archlinux/\$repo/os/\$arch" > /etc/pacman.d/mirrorlist'
  success "Switched to Aliyun mirror"
else
  log "Optimizing mirrors with reflector..."
  run pacman -S --noconfirm --needed reflector
  run reflector --protocol https -a 12 -f 10 --sort rate --save /etc/pacman.d/mirrorlist || \
    warn "reflector failed, keeping existing mirror"
fi

# enable multilib (needed for lib32 packages)
if ! grep -q '^\[multilib\]' /etc/pacman.conf; then
  log "Enabling multilib repository..."
  run bash -c 'sed -i "/^#\[multilib\]/,/^#Include/s/^#//" /etc/pacman.conf'
fi

run pacman -Sy
success "Mirror source ready"
