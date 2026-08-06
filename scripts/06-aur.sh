#!/usr/bin/env bash
# 06-aur.sh - build and install the 14 reviewed AUR recipes.
# Recipes are pinned in third_party/aur/ (reused asset); built with makepkg
# in a clean per-recipe dir. Uses paru if available, else builds paru first.
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=00-utils.sh
source "${SCRIPT_DIR}/00-utils.sh"

RECIPES_DIR="${PROJECT_DIR}/third_party/aur"
BUILD_BASE="${PROJECT_DIR}/.aur-build"
mkdir -p "${BUILD_BASE}"
RECIPES=(clash-verge-rev-bin dsearch-bin fcitx5-skin-fluentdark-git flclash-bin \
         fuzzel-ime-git google-chrome greetd-dms-greeter-git \
         leaf-markdown-viewer-bin linuxqq-appimage obsidian-bin opencode-bin \
         paru wechat-appimage wooz-git)

section "Building and installing AUR packages (${#RECIPES[@]})"

# Optional offline AUR source cache: if sources were pre-placed in
# .aur-sources/ (makepkg SRCDEST layout - git bare mirrors + downloaded
# files), makepkg uses them and never touches the network. This is how a
# physical machine with no overseas access still builds every AUR recipe.
if [[ -d "${PROJECT_DIR}/.aur-sources" ]] && \
   find "${PROJECT_DIR}/.aur-sources" -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
  log "Using local AUR source cache: ${PROJECT_DIR}/.aur-sources (offline mode)"
  export SRCDEST="${PROJECT_DIR}/.aur-sources"
  # Build-dependency caches for the Go (greetd-dms-greeter) and Rust (paru)
  # recipes; without them `go build` / `cargo build` hit the network even
  # though the PKGBUILD sources are cached.
  if [[ -d "${PROJECT_DIR}/.aur-sources/go-mod" ]]; then
    export GOMODCACHE="${PROJECT_DIR}/.aur-sources/go-mod"
  fi
  if [[ -d "${PROJECT_DIR}/.aur-sources/cargo" ]]; then
    export CARGO_HOME="${PROJECT_DIR}/.aur-sources/cargo"
  fi
else
  warn "AUR source cache NOT found at ${PROJECT_DIR}/.aur-sources - AUR recipes will download from the network (and paru/greetd builds need crates.io/proxy.golang.org). If this machine has no overseas access, extract aur-sources.tar.gz into the repo directory first (tar -xzf aur-sources.tar.gz -C ${PROJECT_DIR}/)."
fi

# makepkg's stock DLAGENTS curl has NO timeout: a stalled source host (e.g.
# codeberg for fuzzel-ime-git) hangs the build forever, exactly like the
# pacman libcurl issue fixed in 01-mirror. Add connect/max timeouts so a
# dead host fails the fetch and the recipe retry/failover kicks in instead.
# -sS silences the per-file progress spam while keeping error output.
if ! grep -q 'connect-timeout 15' /etc/makepkg.conf; then
  log "Adding timeouts to makepkg download agents..."
  run bash -c "sed -i 's|/usr/bin/curl -qgb \"\" -fLC - --retry 3 --retry-delay 3|/usr/bin/curl -qgb \"\" -fLC - -sS --connect-timeout 15 --max-time 600 --retry 3 --retry-delay 3|g' /etc/makepkg.conf"
fi

# base-devel/git/curl are already installed by 03-packages (build-foundation
# module); not re-installed here so we do not pay an extra sudo prompt.

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

  # PKGBUILDs carry real download URLs, so makepkg fetches them normally.
  local build_cmd
  build_cmd="cd '${work}' && makepkg -s --noconfirm"
  if [[ "$(id -u)" -eq 0 ]]; then
    runuser -u "${TARGET_USER}" -- bash -c "${build_cmd}" || { rm -rf "${work}"; return 1; }
  else
    ( cd "${work}" && makepkg -s --noconfirm ) || { rm -rf "${work}"; return 1; }
  fi
  # collect the built artifact; a single sudo installs everything at the end
  local pkg
  pkg="$(find "${work}" -maxdepth 1 -name '*.pkg.tar.*' | head -1)"
  if [[ -z "${pkg}" ]]; then
    rm -rf "${work}"
    warn "No package artifact produced: ${recipe}"
    return 1
  fi
  mv "${pkg}" "${BUILD_BASE}/"
  rm -rf "${work}"
  log "Built: ${recipe}"
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
  if install_recipe paru; then
    HAVE_PARU=true
  fi
fi

failed=0
for recipe in "${RECIPES[@]}"; do
  [[ "${recipe}" == "paru" ]] && [[ "${HAVE_PARU}" == "true" ]] && continue
  if ! install_recipe "${recipe}"; then
    # makepkg -s dependency resolution occasionally fails transiently
    # (e.g. fuzzel-ime-git's fcft/tllist); one retry usually succeeds
    warn "Retrying failed recipe once: ${recipe}"
    if ! install_recipe "${recipe}"; then
      warn "Skipped failed: ${recipe}"
      failed=$((failed + 1))
    fi
  fi
done

# install all built artifacts with a single sudo invocation (one password
# prompt instead of one per package; sudo cache alone is insufficient because
# long AUR builds outlive the default 5-minute timestamp)
mapfile -t pkgs < <(find "${BUILD_BASE}" -maxdepth 1 -name '*.pkg.tar.*' | sort)
if (( ${#pkgs[@]} > 0 )); then
  log "Installing ${#pkgs[@]} built AUR packages (single sudo)..."
  run pacman -U --noconfirm "${pkgs[@]}" || {
    warn "bulk AUR install failed; retry with: sudo pacman -U ${BUILD_BASE}/*.pkg.tar.*"
  }
  rm -f "${pkgs[@]}"
  success "Installed ${#pkgs[@]} AUR packages"
else
  warn "no AUR artifacts to install"
fi

if (( failed > 0 )); then
  error "${failed} AUR package(s) failed to build; rerun install.sh to resume (06 will be retried)"
  exit 1
fi
success "AUR stage complete"
