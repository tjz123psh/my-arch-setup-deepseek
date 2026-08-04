#!/usr/bin/env bash
# 02-system.sh - full system upgrade + core tooling.
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=00-utils.sh
source "${SCRIPT_DIR}/00-utils.sh"

section "System upgrade and base tools"
log "Installing required base packages..."
run pacman -S --needed --noconfirm base-devel git python3 curl
log "Running full system upgrade..."
run pacman -Syu --noconfirm
success "System is up to date"
