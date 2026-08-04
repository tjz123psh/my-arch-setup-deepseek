#!/usr/bin/env bash
# 99-cleanup.sh - final cleanup.
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=00-utils.sh
source "${SCRIPT_DIR}/00-utils.sh"

section "清理"
log "清理 pacman 缓存..."
run pacman -Sc --noconfirm 2>/dev/null || warn "缓存清理跳过"
log "清理构建目录..."
rm -rf "${PROJECT_DIR}/.aur-build"* 2>/dev/null || true
success "清理完成"
