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
  # makepkg refuses to run as root; in the strap.sh (root) path the build must
  # run as the target user, with the build dir owned by that user.
  if [[ "$(id -u)" -eq 0 ]]; then
    chown -R "${TARGET_USER}:${TARGET_USER}" "${work}"
  fi
  cp -a "${dir}/." "${work}/"

  # Inject private sources for local-fixed recipes (linuxqq-appimage, paru,
  # wechat-appimage): their PKGBUILDs reference an external-source file that
  # is not downloadable (vendor tarball / signed AppImage). The file must be
  # present in the source cache ~/.cache/my-archlinux-setup/aur-sources/<pkg>/
  # (populated on the operator's machine); copy it into the build dir so
  # makepkg finds it.
  local src_policy ext_src
  src_policy="$(awk -F'\t' -v p="${recipe}" '$1==p{print $10}' "${PROJECT_DIR}/manifests/aur-recipes.tsv" 2>/dev/null | head -1)"
  ext_src="$(awk -F'\t' -v p="${recipe}" '$1==p{print $11}' "${PROJECT_DIR}/manifests/aur-recipes.tsv" 2>/dev/null | head -1)"
  if [[ "${src_policy}" == "local-fixed" && -n "${ext_src}" && "${ext_src}" != "-" ]]; then
    local cache_dir="${TARGET_HOME}/.cache/my-archlinux-setup/aur-sources/${recipe}"
    if [[ -f "${cache_dir}/${ext_src}" ]]; then
      cp -a "${cache_dir}/${ext_src}" "${work}/${ext_src}"
      log "Injected private source: ${recipe}/${ext_src}"
    else
      warn "local-fixed source missing: ${cache_dir}/${ext_src}"
      warn "Place the private source in the cache, or run this step on the operator machine."
      rm -rf "${work}"
      return 1
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
