#!/usr/bin/env bash
# 06-aur.sh - build and install AUR packages; dual mode:
#   offline (default when .aur-sources/ cache is present): makepkg builds the
#   pinned recipes from third_party/aur/ with SRCDEST pointing at the cache,
#   never touching the network (physical machine with no overseas access).
#   online (git clone install without cache): paru pulls the LATEST versions
#   from the AUR (fresh versions, requires network).
# In both modes the target list comes from the package manifest
# (channel=aur, policy=install); offline pins recipes, online follows AUR HEAD.
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
# is deliberately absent from this list and bootstrapped separately below
# (offline mode) or resolved automatically by paru (online mode).
RECIPES=()
while IFS=$'\t' read -r pkg channel _repo _acq module _restore pol _origin _purpose; do
  [[ -z "${pkg}" || "${pkg}" == "#"* ]] && continue
  [[ "${channel}" == "aur" && "${pol}" == "install" ]] || continue
  module_selected "${pkg}" "${module}" || continue
  RECIPES+=("${pkg}")
done < "${PROJECT_DIR}/manifests/workstation-packages.tsv"
# paru is the AUR helper used in online mode and an install target in offline
# mode; keep it first in the batch so a bare system gets the helper early.

section "Building and installing AUR target packages (${#RECIPES[@]})"

# makepkg's stock DLAGENTS curl has NO timeout: a stalled source host (e.g.
# codeberg for fuzzel-ime-git) hangs the build forever, exactly like the
# pacman libcurl issue fixed in 01-mirror. Add connect/max timeouts so a
# dead host fails the fetch and the recipe retry/failover kicks in instead.
# -sS silences the per-file progress spam while keeping error output.
# Applies to BOTH modes: paru also builds AUR packages via makepkg.
# ALSO: network blips (esp. proxy/overseas links) kill source downloads with
#   curl: (35) TLS connect error / (56) OpenSSL SSL_read: unexpected eof
# The stock DLAGENTS `--retry 3` only retries timeouts + HTTP 408/429/5xx;
# TLS errors (35/56) are NOT transient for curl, so --retry never fires and
# one blip fails the whole AUR stage. --retry-all-errors (curl>=7.71) retries
# those too. Guard on 'retry-all-errors' (not 'connect-timeout 15') so a
# system already patched by an older installer run still gets the upgrade.
if ! grep -q 'retry-all-errors' /etc/makepkg.conf; then
  log "Adding timeouts + retry-all-errors to makepkg download agents..."
  # fresh stock DLAGENTS (no timeout at all) -> replace wholesale
  run bash -c "sed -i 's|/usr/bin/curl -qgb \"\" -fLC - --retry 3 --retry-delay 3|/usr/bin/curl -qgb \"\" -fLC - -sS --connect-timeout 15 --max-time 600 --retry 3 --retry-delay 3 --retry-all-errors|g' /etc/makepkg.conf"
  # older installer patch (timeouts present, --retry-all-errors missing) -> append.
  # Keying on '--retry-delay 3 -o' (the makepkg %o placeholder follows) makes this
  # idempotent: an already-fixed line reads '--retry-delay 3 --retry-all-errors -o'
  # and is NOT matched, so re-running never double-appends.
  run bash -c "sed -i 's|--retry-delay 3 -o|--retry-delay 3 --retry-all-errors -o|g' /etc/makepkg.conf"
  # verify the patch actually landed: a customized makepkg.conf (different
  # quoting/line) makes the sed a silent no-op, leaving dead hosts able to
  # hang the build forever (found 2026-08-10 swarm audit; codeberg 504).
  if ! grep -q 'retry-all-errors' /etc/makepkg.conf; then
    warn "could not patch makepkg DLAGENTS (pattern mismatch?); TLS-blip downloads will NOT be retried"
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

# ---- dual-mode cache probe ----
# .aur-sources/ present AND non-empty -> offline (pinned recipes); absent or
# empty/unreadable -> online (paru latest). Shared by the dispatch below and
# offline_mode so the two checks cannot drift apart.
has_aur_sources() {
  [[ -d "${PROJECT_DIR}/.aur-sources" ]] || return 1
  find "${PROJECT_DIR}/.aur-sources" -mindepth 1 -maxdepth 1 -print -quit | grep -q . || return 1
}

# ---- mode observability: loud banner + persistent log ----
# 安装器全自动运行、输出滚动很快（尤其 online 下载阶段），模式与结果必须一眼
# 可见并可事后查询：模式横幅在分流时打印，验收汇总写入 .install_logs/06-aur.log
# （installer runtime state，已 gitignore，不进仓库）。
AUR_LOG="${PROJECT_DIR}/.install_logs/06-aur.log"

aur_mode_banner() { # aur_mode_banner <MODE> <desc>
  local mode="$1" desc="$2"
  echo
  echo -e "${H_CYAN}================================================================${NC}"
  echo -e "${H_CYAN}  ★ AUR MODE: ${H_YELLOW}${mode}${H_CYAN} ★"
  echo -e "${H_CYAN}  ${desc}${NC}"
  echo -e "${H_CYAN}================================================================${NC}"
}

aur_log() { # aur_log <line>  追加一行到模式日志
  mkdir -p "$(dirname "${AUR_LOG}")"
  echo "[$(date '+%F %T')] $*" >> "${AUR_LOG}"
}

# ---- offline mode: pinned recipes built with makepkg from the source cache ----
offline_mode() {
  # Optional offline AUR source cache: if sources were pre-placed in
  # .aur-sources/ (makepkg SRCDEST layout - git bare mirrors + downloaded
  # files), makepkg uses them and never touches the network. This is how a
  # physical machine with no overseas access still builds every AUR recipe.
  if has_aur_sources; then
    log "Using local AUR source cache: ${PROJECT_DIR}/.aur-sources (offline mode)"
    export SRCDEST="${PROJECT_DIR}/.aur-sources"
    # Build-dependency caches for the Go (greetd-dms-greeter) and Rust (paru)
    # recipes. Offline mode FAILS CLOSED when a required cache is missing:
    # with the PKGBUILD GOMODCACHE override removed (2026-08-12), go would
    # otherwise fall back to proxy.golang.org and hang a no-VPN machine
    # (review major, 2026-08-14). CARGO_NET_OFFLINE makes paru's
    # `cargo fetch --locked` use the cache instead of probing crates.io
    # first (review minor, same date). fetch-aur-sources.sh generates both
    # from the pinned recipe commits and writes a .pin marker, so presence
    # here implies completeness.
    if [[ -d "${PROJECT_DIR}/.aur-sources/go-mod" ]]; then
      export GOMODCACHE="${PROJECT_DIR}/.aur-sources/go-mod"
      export GOPROXY=off
    else
      error "offline AUR cache is missing .aur-sources/go-mod (required by greetd-dms-greeter); re-extract a complete aur-sources-*.tar.gz"
      exit 1
    fi
    if [[ -d "${PROJECT_DIR}/.aur-sources/cargo" ]]; then
      export CARGO_HOME="${PROJECT_DIR}/.aur-sources/cargo"
      export CARGO_NET_OFFLINE=true
    else
      error "offline AUR cache is missing .aur-sources/cargo (required by paru); re-extract a complete aur-sources-*.tar.gz"
      exit 1
    fi
    # strap/root path: a cache extracted as root is unwritable by the
    # runuser build (go needs $GOMODCACHE/cache/lock); hand it to TARGET_USER
    # (review minor, 2026-08-14 - unverified on the strap path).
    if [[ "$(id -u)" -eq 0 ]] && [[ -d "${PROJECT_DIR}/.aur-sources" ]]; then
      chown -R "${TARGET_USER}:${TARGET_USER}" \
        "${PROJECT_DIR}/.aur-sources/go-mod" "${PROJECT_DIR}/.aur-sources/cargo" 2>/dev/null || true
    fi
  fi

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

  local failed=0 recipe
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
    local missing=0 p name
    for p in "${pkgs[@]}"; do
      name=
      name="$(LC_ALL=C pacman -Qp "${p}" 2>/dev/null | awk '{print $1}' || true)"
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
  # 验收汇总（offline/makepkg）：每个 recipe 的已装版本，滚动结束后仍留在屏底
  log "AUR summary (offline/makepkg):"
  local r
  for r in "${RECIPES[@]}"; do
    log "  ${r}: $(pacman -Q "${r}" 2>/dev/null | awk '{print $2}')"
    aur_log "installed ${r} $(pacman -Q "${r}" 2>/dev/null | awk '{print $2}')"
  done
  log "详情已写入 ${AUR_LOG}"
  success "AUR stage complete (offline mode)"
}

# ---- online mode: git clone install with network; paru pulls latest AUR ----
online_mode() {
  log "Online mode: no .aur-sources cache; installing LATEST AUR packages via paru"
  # Bootstrap paru: archlinuxcn pacman package first (03 already configured
  # the repo); fall back to building the pinned recipe with makepkg.
  if ! command -v paru >/dev/null 2>&1; then
    if ! run pacman -S --needed --noconfirm paru; then
      log "archlinuxcn paru unavailable; building pinned paru recipe..."
      ensure_rust
      install_recipe paru || {
        error "paru bootstrap build failed; cannot install AUR packages in online mode"
        exit 1
      }
      mapfile -t paru_pkgs < <(find "${BUILD_BASE}" -maxdepth 1 -name 'paru*.pkg.tar.*')
      if (( ${#paru_pkgs[@]} > 0 )); then
        run pacman -U --noconfirm "${paru_pkgs[@]}" || {
          error "paru bootstrap install failed"
          exit 1
        }
        rm -f "${paru_pkgs[@]}"
      fi
    fi
  fi
  command -v paru >/dev/null 2>&1 || {
    error "paru unavailable; cannot install AUR packages in online mode"
    exit 1
  }

  # Targets: manifest AUR install rows, minus paru itself (just bootstrapped).
  # vmware-keymaps is NOT in RECIPES and paru resolves it automatically as an
  # AUR dependency of vmware-workstation.
  local -a targets=()
  local recipe
  for recipe in "${RECIPES[@]}"; do
    [[ "${recipe}" == "paru" ]] && continue
    targets+=("${recipe}")
  done

  if (( ${#targets[@]} == 0 )); then
    warn "no AUR targets selected (manifest empty or all filtered); skipping online AUR stage"
    success "AUR stage complete (online mode, no targets)"
    exit 0
  fi

  log "paru -S latest: ${targets[*]}"
  # --noconfirm skips prompts, --skipreview skips the PKGBUILD review prompt.
  # paru builds as the invoking user and uses sudo for pacman steps (covered
  # by the scoped NOPASSWD drop-in configured earlier).
  local q=""
  local t
  for t in "${targets[@]}"; do
    q+="$(printf '%q ' "${t}")"
  done
  # Network blips (proxy/overseas TLS drops, git clone resets) fail the whole
  # paru batch with nothing installed. Retry the batch (max 3): packages that
  # already succeeded are skipped by paru as up-to-date, so re-running is
  # idempotent; a genuinely broken PKGBUILD still fails out after 3 attempts.
  local attempt=1 max=3 paru_ok=0
  while true; do
    paru_ok=0
    if [[ "$(id -u)" -eq 0 ]]; then
      runuser -u "${TARGET_USER}" -- bash -lc "paru -S --noconfirm --skipreview ${q}" && paru_ok=1
    else
      paru -S --noconfirm --skipreview "${targets[@]}" && paru_ok=1
    fi
    if (( paru_ok == 1 )); then
      break
    fi
    if (( attempt >= max )); then
      error "paru install failed after ${max} attempts (online mode); rerun install.sh to retry"
      exit 1
    fi
    warn "paru install failed (attempt ${attempt}/${max}); transient network? retrying in 5s"
    aur_log "paru attempt ${attempt} failed; retrying"
    sleep 5
    attempt=$((attempt + 1))
  done

  # Acceptance (same exact-name discipline as C-03): every target must be
  # installed; paru follows AUR HEAD so a renamed upstream package fails here
  # (fail-closed) instead of silently passing.
  local installed missing=0 t
  installed="$(pacman -Qq)" || {
    error "could not query the installed package database; refusing online acceptance"
    exit 1
  }
  for t in "${targets[@]}"; do
    if ! grep -Fx "${t}" >/dev/null <<<"${installed}"; then
      error "AUR package not installed after online stage: ${t}"
      missing=$((missing + 1))
    fi
  done
  if (( missing > 0 )); then
    error "${missing} AUR package(s) missing after online paru install"
    exit 1
  fi
  # 验收汇总（online/paru）：模式 + paru 版本 + 每个目标包的已装版本
  log "AUR summary (online/paru):"
  log "  paru: $(paru --version 2>/dev/null | head -1)"
  aur_log "paru $(paru --version 2>/dev/null | head -1)"
  local s
  for s in "${targets[@]}"; do
    log "  ${s}: $(pacman -Q "${s}" 2>/dev/null | awk '{print $2}')"
    aur_log "installed ${s} $(pacman -Q "${s}" 2>/dev/null | awk '{print $2}')"
  done
  log "详情已写入 ${AUR_LOG}"
  success "Installed ${#targets[@]} latest AUR packages via paru (online mode)"
}

# ---- mode dispatch: source cache present -> offline makepkg; else online paru ----
if has_aur_sources; then
  aur_mode_banner "OFFLINE — makepkg pinned recipes" "using .aur-sources/ cache + third_party/aur pinned PKGBUILDs; fully offline"
  aur_log "mode=offline targets=${#RECIPES[@]}"
  offline_mode
else
  if [[ -d "${PROJECT_DIR}/.aur-sources" ]]; then
    warn ".aur-sources/ 目录存在但为空或不可读——走在线模式（paru 拉最新）；若机器无海外网络请检查缓存是否解压完整"
  fi
  aur_mode_banner "ONLINE — paru latest from AUR" "no .aur-sources/ cache (git clone install); paru pulls LATEST versions; needs network"
  aur_log "mode=online targets=${#RECIPES[@]}"
  online_mode
fi
