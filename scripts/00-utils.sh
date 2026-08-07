#!/usr/bin/env bash
# 00-utils.sh - shared helpers for the step scripts.
# Sourced by install.sh; expected to run as a normal user with sudo prompts.

set -Eeuo pipefail

# --- colors (plain text; disabled when not a tty) ---
if [[ -t 1 ]]; then
  H_RED=$'\e[31m'; H_GREEN=$'\e[32m'; H_YELLOW=$'\e[33m'
  H_CYAN=$'\e[36m'; BOLD=$'\e[1m'; DIM=$'\e[2m'; NC=$'\e[0m'
else
  H_RED=""; H_GREEN=""; H_YELLOW=""; H_CYAN=""; BOLD=""; DIM=""; NC=""
fi

# --- state ---
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly PROJECT_DIR

# --- progress state with install context (review H-02) ---
# The resume file binds machine/desktop/user/commit/manifest hashes so a
# stale progress file from a different install configuration can never
# resume-skip modules. Context mismatch => refuse to resume (the operator
# must clear .install_progress explicitly to start fresh).
PROGRESS_CONTEXT_FILE="${PROJECT_DIR}/.install_progress"

progress_context() {
  local commit="dirty"
  if command -v git >/dev/null 2>&1 && git -C "${PROJECT_DIR}" rev-parse HEAD >/dev/null 2>&1; then
    commit="$(git -C "${PROJECT_DIR}" rev-parse --short HEAD 2>/dev/null || echo dirty)"
    if [[ -n "$(git -C "${PROJECT_DIR}" diff --stat 2>/dev/null | tail -1)" ]]; then
      commit="${commit}+dirty"
    fi
  fi
  local ph="-" mh="-" rh="-"
  [[ -f "${PROJECT_DIR}/manifests/workstation-packages.tsv" ]] && ph="$(sha256sum "${PROJECT_DIR}/manifests/workstation-packages.tsv" | cut -c1-12)"
  [[ -f "${PROJECT_DIR}/manifests/config-mappings.tsv" ]] && mh="$(sha256sum "${PROJECT_DIR}/manifests/config-mappings.tsv" | cut -c1-12)"
  [[ -f "${PROJECT_DIR}/manifests/aur-recipes.tsv" ]] && rh="$(sha256sum "${PROJECT_DIR}/manifests/aur-recipes.tsv" | cut -c1-12)"
  printf 'desktop=%s machine=%s user=%s commit=%s packages=%s mappings=%s recipes=%s' \
    "${DESKTOP_ENV:-none}" "${MACHINE_TYPE:-physical}" "${TARGET_USER:-}" "${commit}" "${ph}" "${mh}" "${rh}"
}

setup_progress() {
  local ctx
  ctx="$(progress_context)"
  if [[ -f "${PROGRESS_CONTEXT_FILE}" ]]; then
    local header
    header="$(head -1 "${PROGRESS_CONTEXT_FILE}")"
    if [[ "${header}" != "# context: ${ctx}" ]]; then
      error "Existing progress file does not match this install context:"
      error "  expected: # context: ${ctx}"
      error "  found:    ${header}"
      error "Refusing to resume; remove ${PROGRESS_CONTEXT_FILE} to start fresh."
      exit 1
    fi
    log "Progress file matches install context; resuming."
  else
    printf '# context: %s\n' "${ctx}" > "${PROGRESS_CONTEXT_FILE}"
  fi
}

mark_done() {
  local module="$1"
  echo "${module}" >> "${PROGRESS_CONTEXT_FILE}"
}

is_done() {
  local module="$1"
  grep -q "^${module}$" "${PROGRESS_CONTEXT_FILE}"
}

# --- target user resolution ---
# The installer may run as root (strap.sh path) or as the desktop user.
# Config deployment and user services must target the real desktop user's
# HOME, never /root. TARGET_USER/TARGET_HOME resolve that user.
if [[ "$(id -u)" -eq 0 ]]; then
  if [[ -n "${SUDO_USER:-}" ]]; then
    TARGET_USER="${SUDO_USER}"
  else
    # first real (uid>=1000) login user
    TARGET_USER="$(awk -F: '$3>=1000 && $7!~/nologin|false/{print $1; exit}' /etc/passwd)"
  fi
  [[ -n "${TARGET_USER:-}" ]] || TARGET_USER="root"
  TARGET_HOME="$(getent passwd "${TARGET_USER}" | cut -d: -f6)"
else
  TARGET_USER="${USER:-$(id -un)}"
  TARGET_HOME="${HOME}"
fi
readonly TARGET_USER TARGET_HOME

log()    { echo -e "  ${DIM}->${NC} $*"; }
section(){ echo; echo -e "${H_CYAN}===[ $* ]${NC}"; }
success(){ echo -e "  ${H_GREEN}✔${NC} $*"; }
warn()   { echo -e "  ${H_YELLOW}!${NC} $*"; }
error()  { echo -e "  ${H_RED}✘${NC} $*" >&2; }

die() { error "$*"; exit 1; }

check_root() {
  # We run as a normal user; all privileged steps go through sudo -A-style
  # prompts. This is a no-op here but kept for symmetry with the entry point.
  true
}

# run a command with sudo, prompting for password when needed
run() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

ensure_fzf() {
  if ! command -v fzf >/dev/null 2>&1; then
    log "installing fzf for the selection menu..."
    # Sync the package database first: on a fresh install the local db is
    # stale and the mirror has already pruned the old fzf version, which
    # would otherwise 404 on every mirror.
    run pacman -Sy --noconfirm || die "pacman -Sy failed; cannot install fzf"
    run pacman -S --noconfirm --needed fzf
  fi
}

# --- module selection (shared by 03-packages.sh and 07-config.sh) ---
# One selection function drives BOTH package install and config deployment so
# a desktop/machine role can never be half-installed (review H-07).
#
# Machine-role modules follow MACHINE_TYPE (vmware-host on physical,
# vmware-guest on vm); hardware modules (graphics-*/hardware-tools/
# asus-hardware) are installed ONLY by the dedicated 04-drivers step
# (physical) and therefore excluded from the general package/config path on
# both machine types; desktop modules follow DESKTOP_ENV
# (niri|hyprland|both|none).
module_selected() {
  local pkg="$1" module="$2"
  case "${module}" in
    virtualization-vmware-host)
      [[ "${MACHINE_TYPE}" == "physical" ]] || return 1 ;;
    virtualization-vmware-guest)
      [[ "${MACHINE_TYPE}" == "vm" ]] || return 1 ;;
    graphics-amd|graphics-nvidia|hardware-tools|asus-hardware)
      return 1 ;;
  esac
  case "${DESKTOP_ENV:-both}" in
    niri)     [[ "${module}" == "wm-hyprland" ]] && return 1 ;;
    hyprland) [[ "${module}" == "wm-niri" ]] && return 1 ;;
    none)     [[ "${module}" == "wm-niri" || "${module}" == "wm-hyprland" ]] && return 1 ;;
    *) : ;; # both (or unknown): install everything, like before
  esac
  return 0
}

# --- diagnostics panel (plain text) ---
sys_dashboard() {
  section "System"
  echo "  Kernel   : $(uname -r)"
  echo "  User     : $(whoami)"
  echo "  Desktop  : ${DESKTOP_ENV:-none}"
  echo "  Machine  : ${MACHINE_TYPE:-physical}"
  echo "  Modules  : ${#MODULES[@]} step(s) selected"
}
