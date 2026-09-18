#!/usr/bin/env bash
# 99-cleanup.sh - final cleanup.
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=00-utils.sh
source "${SCRIPT_DIR}/00-utils.sh"

section "Cleanup"
log "Cleaning pacman cache..."
run pacman -Sc --noconfirm 2>/dev/null || warn "cache cleanup skipped"
log "Cleaning AUR build directories..."
rm -rf "${PROJECT_DIR}/.aur-build"* 2>/dev/null || true
# restore the sudo privileges extended by install.sh pre-flight:
# the timestamp timeout AND the temporary NOPASSWD grant
# 99-install-timeout 是旧版安装器的文件名（当前 install.sh 只创建
# 99-install-nopasswd，timestamp_timeout 写在同一个文件里）；保留删除以清理历史残留。
run rm -f /etc/sudoers.d/99-install-timeout /etc/sudoers.d/99-install-nopasswd 2>/dev/null || true
success "Cleanup complete"
