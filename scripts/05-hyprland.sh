#!/usr/bin/env bash
# 05-hyprland.sh - Hyprland desktop environment + configuration.
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=00-utils.sh
source "${SCRIPT_DIR}/00-utils.sh"

section "Installing Hyprland desktop"
# socat 已归 daily-apps 清单（linuxqq 的 MAC 修复需要它，纯 niri 也要装），此处不再重复。
run pacman -S --needed --noconfirm hyprland xdg-desktop-portal-hyprland
success "Hyprland installed (stock session entry via start-hyprland)"
