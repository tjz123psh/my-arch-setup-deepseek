#!/usr/bin/env bash
# 01-mirror.sh - mirrorlist optimisation (China-aware).
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=00-utils.sh
source "${SCRIPT_DIR}/00-utils.sh"

section "镜像源优化"
TZ_CFG="$(readlink -f /etc/localtime 2>/dev/null || echo '')"

if [[ "${TZ_CFG}" == *"Shanghai"* ]] || [[ "${CN_MIRROR:-0}" == "1" ]]; then
  log "检测到中国时区，使用阿里云镜像..."
  run bash -c 'echo "Server = https://mirrors.aliyun.com/archlinux/\$repo/os/\$arch" > /etc/pacman.d/mirrorlist'
  success "已切换到阿里云镜像"
else
  log "使用 reflector 优化镜像列表..."
  run pacman -S --noconfirm --needed reflector
  run reflector --protocol https -a 12 -f 10 --sort rate --save /etc/pacman.d/mirrorlist || \
    warn "reflector 失败，使用现有镜像"
fi

# enable multilib (needed for lib32 packages)
if ! grep -q '^\[multilib\]' /etc/pacman.conf; then
  log "启用 multilib 仓库..."
  run bash -c 'sed -i "/^#\[multilib\]/,/^#Include/s/^#//" /etc/pacman.conf'
fi

run pacman -Sy
success "镜像源就绪"
