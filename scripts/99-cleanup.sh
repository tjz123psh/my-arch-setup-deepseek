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
# restore the default sudo timeout extended by install.sh pre-flight
run rm -f /etc/sudoers.d/99-install-timeout 2>/dev/null || true
success "Cleanup complete"
