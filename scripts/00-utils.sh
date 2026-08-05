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
STATE_FILE="${PROJECT_DIR}/.install_progress"

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

mark_done() {
  local module="$1"
  echo "${module}" >> "${STATE_FILE}"
}

is_done() {
  local module="$1"
  grep -q "^${module}$" "${STATE_FILE}"
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
