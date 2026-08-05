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
         fuzzel-ime-git google-chrome greetd-dms-greeter-git \
         leaf-markdown-viewer-bin linuxqq-appimage obsidian-bin opencode-bin \
         paru wechat-appimage wooz-git)

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
  # makepkg refuses to run as root; in the strap.sh (root) path the build must
  # run as the target user, with the build dir owned by that user.
  if [[ "$(id -u)" -eq 0 ]]; then
    chown -R "${TARGET_USER}:${TARGET_USER}" "${work}"
  fi
  cp -a "${dir}/." "${work}/"

  # Private-source recipes (linuxqq-appimage, paru, wechat-appimage): their
  # PKGBUILDs now carry real download URLs, so makepkg fetches them normally.
  # If the operator pre-seeded the local cache, reuse it to save bandwidth.
  local src_policy ext_src
  src_policy="$(awk -F'\t' -v p="${recipe}" '$1==p{print $10}' "${PROJECT_DIR}/manifests/aur-recipes.tsv" 2>/dev/null | head -1)"
  ext_src="$(awk -F'\t' -v p="${recipe}" '$1==p{print $11}' "${PROJECT_DIR}/manifests/aur-recipes.tsv" 2>/dev/null | head -1)"
  if [[ "${src_policy}" == "local-fixed" && -n "${ext_src}" && "${ext_src}" != "-" ]]; then
    local cache_dir="${TARGET_HOME}/.cache/my-archlinux-setup/aur-sources/${recipe}"
    if [[ -f "${cache_dir}/${ext_src}" ]]; then
      cp -a "${cache_dir}/${ext_src}" "${work}/${ext_src}"
      log "Reused cached source: ${recipe}/${ext_src}"
    fi
  fi
  local build_cmd
  build_cmd="cd '${work}' && makepkg -s --noconfirm"
  if command -v paru >/dev/null 2>&1; then
    # paru as the user, then root installs the built package
    if [[ "$(id -u)" -eq 0 ]]; then
      if runuser -u "${TARGET_USER}" -- bash -c "cd '${work}' && paru -Ui --noconfirm ." 2>/dev/null; then
        rm -rf "${work}"; success "Installed: ${recipe}"; return 0
      fi
    elif paru -Ui --noconfirm . 2>/dev/null; then
      rm -rf "${work}"; success "Installed: ${recipe}"; return 0
    fi
  fi
  # fallback: plain makepkg then root pacman -U
  if [[ "$(id -u)" -eq 0 ]]; then
    runuser -u "${TARGET_USER}" -- bash -c "${build_cmd}" || { rm -rf "${work}"; return 1; }
    run pacman -U --noconfirm "${work}"/*.pkg.tar.* || { rm -rf "${work}"; return 1; }
  else
    ( cd "${work}" && makepkg -s --noconfirm ) || { rm -rf "${work}"; return 1; }
    run pacman -U --noconfirm "${work}"/*.pkg.tar.* || { rm -rf "${work}"; return 1; }
  fi
  rm -rf "${work}"
  success "Installed: ${recipe}"
}

# Ensure a usable Rust toolchain for the paru build. base-devel does not
# include rust; rustup (when installed) has no default toolchain until one
# is set, and makepkg builds as the target user (root path uses runuser), so
# the toolchain must be installed into that user's HOME and detected there.
ensure_rust() {
  # cargo may exist as a rustup shim while no toolchain is active (common:
  # rustup installed without 'rustup default stable'). Verify an active
  # toolchain, not just the shim's presence.
  local active
  if [[ "$(id -u)" -eq 0 ]]; then
    active="$(runuser -u "${TARGET_USER}" -- bash -lc 'rustup show active-toolchain 2>/dev/null' || true)"
  else
    active="$(rustup show active-toolchain 2>/dev/null || true)"
  fi
  if [[ -n "${active}" ]]; then
    return 0
  fi
  local have_rustup
  if [[ "$(id -u)" -eq 0 ]]; then
    have_rustup="$(runuser -u "${TARGET_USER}" -- bash -lc 'command -v rustup' 2>/dev/null || true)"
  else
    have_rustup="$(command -v rustup 2>/dev/null || true)"
  fi
  if [[ -n "${have_rustup}" ]]; then
    log "rustup present but no active toolchain; setting stable..."
    if [[ "$(id -u)" -eq 0 ]]; then
      runuser -u "${TARGET_USER}" -- bash -lc 'rustup default stable' || \
        warn "rustup default stable failed; paru build may fail"
    else
      rustup default stable || warn "rustup default stable failed; paru build may fail"
    fi
    return 0
  fi
  log "installing rustup and stable toolchain..."
  run pacman -S --needed --noconfirm rustup
  if [[ "$(id -u)" -eq 0 ]]; then
    runuser -u "${TARGET_USER}" -- bash -lc 'rustup default stable' || \
      warn "rustup default stable failed; paru build may fail"
  else
    rustup default stable || warn "rustup default stable failed; paru build may fail"
  fi
}

# build paru first if needed (it is the AUR helper for the rest)
if [[ "${HAVE_PARU}" == "false" ]] && [[ -d "${RECIPES_DIR}/paru" ]]; then
  log "paru not installed; building paru first..."
  ensure_rust
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
