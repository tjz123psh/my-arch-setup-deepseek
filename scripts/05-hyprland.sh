#!/usr/bin/env bash
# 05-hyprland.sh - Hyprland desktop environment + configuration.
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=00-utils.sh
source "${SCRIPT_DIR}/00-utils.sh"

section "Installing Hyprland desktop"
run pacman -S --needed --noconfirm hyprland socat xdg-desktop-portal-hyprland
success "Hyprland installed"
