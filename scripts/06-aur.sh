#!/usr/bin/env bash
# 06-aur.sh - build and install the 13 reviewed AUR target recipes.
# Recipes are pinned in third_party/aur/ (reused asset); built with makepkg
# in a clean per-recipe dir. Uses paru if available, else builds paru first.
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=00-utils.sh
source "${SCRIPT_DIR}/00-utils.sh"

RECIPES_DIR="${PROJECT_DIR}/third_party/aur"
BUILD_BASE="${PROJECT_DIR}/.aur-build"
mkdir -p "${BUILD_BASE}"
# AUR targets come from the package manifest (channel=aur, policy=install)
# filtered by the SAME module_selected() used by 03/07, so machine roles are
# honored here too: vmware-workstation lives in virtualization-vmware-host
# and is therefore built only on physical; -t vm never builds the host stack.
# vmware-keymaps is a pure AUR->AUR build dependency of vmware-workstation
# (installed before makepkg -s can resolve it), NOT an install target, so it
# is deliberately absent from this list and bootstrapped separately below.
RECIPES=()
while IFS=$'\t' read -r pkg channel _repo _acq module _restore pol _origin _purpose; do
  [[ -z "${pkg}" || "${pkg}" == "#"* ]] && continue
  [[ "${channel}" == "aur" && "${pol}" == "install" ]] || continue
  module_selected "${pkg}" "${module}" || continue
  RECIPES+=("${pkg}")
done < "${PROJECT_DIR}/manifests/workstation-packages.tsv"
# paru is the AUR helper used elsewhere; build it first when missing (below).
# Keep it first in the batch so a bare system gets the helper early.

section "Building and installing AUR target packages (${#RECIPES[@]})"

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
  # verify the patch actually landed: a customized makepkg.conf (different
  # quoting/line) makes the sed a silent no-op, leaving dead hosts able to
  # hang the build forever (found 2026-08-10 swarm audit; codeberg 504).
  if ! grep -q 'connect-timeout 15' /etc/makepkg.conf; then
    warn "could not patch makepkg DLAGENTS (pattern mismatch?); source fetches have NO timeout"
  fi
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
  cp -a "${dir}/." "${work}/"

  # makepkg refuses to run as root; in the strap.sh (root) path the build must
  # run as the target user, with the build dir owned by that user. The chown
  # MUST come AFTER `cp -a source/. dest`: GNU cp applies the SOURCE
  # directory's ownership/mode to the DESTINATION directory when the source
  # ends in `/.`, so a pre-cp chown is silently overwritten and makepkg then
  # fails with "no write permission to $BUILDDIR" (found 2026-08-10 on the
  # fresh strap.sh VM install; the non-root ./install.sh path was unaffected
  # because there the build dir is already owned by the invoking user).
  if [[ "$(id -u)" -eq 0 ]]; then
    chown -R "${TARGET_USER}:${TARGET_USER}" "${work}"
  fi

  # PKGBUILDs carry real download URLs, so makepkg fetches them normally.
  local build_cmd
  build_cmd="cd '${work}' && makepkg -s --noconfirm"
  if [[ "$(id -u)" -eq 0 ]]; then
    runuser -u "${TARGET_USER}" -- bash -c "${build_cmd}" || { mv "${work}" "${BUILD_BASE}/failed-${recipe}-$(date +%s)" 2>/dev/null || rm -rf "${work}"; return 1; }
  else
    ( cd "${work}" && makepkg -s --noconfirm ) || { mv "${work}" "${BUILD_BASE}/failed-${recipe}-$(date +%s)" 2>/dev/null || rm -rf "${work}"; return 1; }
  fi
  # collect the built artifact; a single sudo installs everything at the end
  local pkg
  pkg="$(find "${work}" -maxdepth 1 -name '*.pkg.tar.*' | head -1)"
  if [[ -z "${pkg}" ]]; then
    mv "${work}" "${BUILD_BASE}/failed-${recipe}-$(date +%s)" 2>/dev/null || rm -rf "${work}"
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

# AUR->AUR dependency bootstrap: vmware-workstation's `makepkg -s` requires
# vmware-keymaps to already be installed (its PKGBUILD does
# `depends+=(vmware-keymaps)`). The old build-all-then-install-all model
# cannot satisfy that, so vmware-keymaps gets its own build + dedicated
# install before the main batch (review 5.5). Only relevant when the host
# stack is actually selected (physical); a vm guest never builds it.
if [[ "${RECIPES[*]}" == *"vmware-workstation"* ]] && [[ -d "${RECIPES_DIR}/vmware-keymaps" ]]; then
  log "Bootstrapping vmware-keymaps (AUR dependency of vmware-workstation)..."
  if install_recipe vmware-keymaps; then
    mapfile -t km_pkgs < <(find "${BUILD_BASE}" -maxdepth 1 -name 'vmware-keymaps*.pkg.tar.*')
    if (( ${#km_pkgs[@]} > 0 )); then
      run pacman -U --noconfirm "${km_pkgs[@]}" || {
        error "could not install bootstrapped vmware-keymaps"
        exit 1
      }
      rm -f "${km_pkgs[@]}"
      log "Installed vmware-keymaps"
    else
      error "vmware-keymaps built no artifact; cannot proceed to vmware-workstation"
      exit 1
    fi
  else
    error "vmware-keymaps bootstrap build failed; vmware-workstation cannot resolve its AUR dependency"
    exit 1
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
  if ! run pacman -U --noconfirm "${pkgs[@]}"; then
    # C-03: a failed final install must FAIL the step, not warn-and-continue;
    # keep the artifacts so the failure is diagnosable.
    error "bulk AUR install failed; artifacts preserved at ${BUILD_BASE}/ for manual diagnosis"
    exit 1
  fi
  # verify every built artifact is actually installed (C-03): pacman -U is
  # transactional, but a failed hook or interrupted transaction can still
  # leave a gap; check each package by name from its own metadata.
  # NOTE: `pacman -Qp <file>` prints "name version" (one line, no label),
  # unlike `pacman -Qi`. The previous awk '/^Name/' matched nothing and made
  # every package report name=unknown (observed 2026-08-08, all 14 AUR
  # targets "not verifiably installed" after a successful pacman -U).
  missing=0
  for p in "${pkgs[@]}"; do
    name=
    name="$(LC_ALL=C pacman -Qp "${p}" 2>/dev/null | awk '{print $1}')"
    if [[ -z "${name}" ]] || ! pacman -Q "${name}" >/dev/null 2>&1; then
      error "AUR package not verifiably installed: ${p} (name=${name:-unknown})"
      missing=$((missing + 1))
    fi
  done
  if (( missing > 0 )); then
    error "${missing} AUR package(s) failed to install; artifacts preserved at ${BUILD_BASE}/"
    exit 1
  fi
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
