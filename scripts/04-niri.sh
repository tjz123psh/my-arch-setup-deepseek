#!/usr/bin/env bash
# 04-niri.sh - Niri desktop environment + configuration.
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=00-utils.sh
source "${SCRIPT_DIR}/00-utils.sh"

section "Installing Niri desktop"
run pacman -S --needed --noconfirm niri xdg-desktop-portal-gnome xwayland-satellite
success "Niri installed"
