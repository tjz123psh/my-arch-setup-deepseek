#!/usr/bin/env bash
# 05-aur.sh - build and install the 13 reviewed AUR recipes.
# Recipes are pinned in third_party/aur/ (reused asset); built with makepkg
# in a clean per-recipe dir. Uses paru if available, else builds paru first.
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=00-utils.sh
source "${SCRIPT_DIR}/00-utils.sh"

RECIPES_DIR="${PROJECT_DIR}/third_party/aur"
BUILD_BASE="${PROJECT_DIR}/.aur-build"
RECIPES=(clash-verge-rev-bin dsearch-bin fcitx5-skin-fluentdark-git flclash-bin \
         fuzzel-ime-git google-chrome leaf-markdown-viewer-bin linuxqq-appimage \
         obsidian-bin opencode-bin paru wechat-appimage wooz-git)

section "Building and installing AUR packages (${#RECIPES[@]})"

# devtools for clean build env
run pacman -S --needed --noconfirm base-devel git curl

HAVE_PARU=false
command -v paru >/dev/null 2>&1 && HAVE_PARU=true

install_recipe() {
  local recipe="$1"
  local dir="${RECIPES_DIR}/${recipe}"
  [[ -d "${dir}" ]] || { warn "Missing recipe: ${recipe}"; return 1; }
  log "Building ${recipe} ..."
  local work
  work="$(mktemp -d "${BUILD_BASE}.XXXXXX")"
  cp -a "${dir}/." "${work}/"
  (
    cd "${work}"
    # makepkg as the invoking user (non-root); install with sudo
    if command -v paru >/dev/null 2>&1; then
      paru -Ui --noconfirm . 2>/dev/null || \
        { makepkg -s --noconfirm; run pacman -U --noconfirm ./*.pkg.tar.*; }
    else
      makepkg -s --noconfirm
      run pacman -U --noconfirm ./*.pkg.tar.*
    fi
  )
  rm -rf "${work}"
  success "Installed: ${recipe}"
}

# build paru first if needed (it is the AUR helper for the rest)
if [[ "${HAVE_PARU}" == "false" ]] && [[ -d "${RECIPES_DIR}/paru" ]]; then
  log "paru not installed; building paru first..."
  install_recipe paru
fi

failed=0
for recipe in "${RECIPES[@]}"; do
  [[ "${recipe}" == "paru" ]] && [[ "${HAVE_PARU}" == "true" ]] && continue
  if ! install_recipe "${recipe}"; then
    warn "Skipped failed: ${recipe}"
    failed=$((failed + 1))
  fi
done

if (( failed > 0 )); then
  warn "${failed} AUR package(s) failed; rerun this step to retry"
fi
success "AUR stage complete"
