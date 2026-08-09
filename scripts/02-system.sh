#!/usr/bin/env bash
# 02-system.sh - full system upgrade + core tooling.
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=00-utils.sh
source "${SCRIPT_DIR}/00-utils.sh"

section "System upgrade and base tools"
# Step 2 (D-03, follow-up 2): the official-repo sync/upgrade runs FIRST so
# the package database is current before we install tooling (a fresh local
# db can be stale/pruned, and -S on an old db 404s). Default -Syu; -Syyu
# only under FORCE_REFRESH=1 (--force-refresh, explicit repair mode). No
# other module runs pacman -Sy/-Syu/-Syyu.
log "Running full system upgrade (single sync/upgrade owner)..."
sync_official
log "Installing required base packages..."
run pacman -S --needed --noconfirm base-devel git python3 curl
success "System is up to date"
