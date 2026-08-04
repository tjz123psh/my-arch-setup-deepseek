#!/usr/bin/env bash
# 02-system.sh - full system upgrade + core tooling.
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=00-utils.sh
source "${SCRIPT_DIR}/00-utils.sh"

section "系统升级与基础工具"
log "安装必要基础包..."
run pacman -S --needed --noconfirm base-devel git python3 curl
log "完整系统升级..."
run pacman -Syu --noconfirm
success "系统已是最新"
