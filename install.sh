#!/usr/bin/env bash
# install.sh - main installer.
#
#   select desktop -> select machine type -> diagnostics -> update
#   -> stepwise modules (resume via .install_progress) -> done
#
# Runs as a normal user; privileged steps prompt for sudo when needed.

set -Eeuo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="${BASE_DIR}/scripts"

# shellcheck source=scripts/00-utils.sh
source "${SCRIPTS_DIR}/00-utils.sh"

DESKTOP_ENV="${DESKTOP_ENV:-}"
MACHINE_TYPE="${MACHINE_TYPE:-}"
MODULES=()

usage() {
  cat <<'EOF'
Usage: install.sh [options]

One-click Arch desktop restore (Niri/Hyprland). Interactively select desktop and machine type;
flags can specify them directly to skip the prompts.

Options:
  -d, --desktop niri|hyprland|both|none
  -t, --machine vm|physical
  -h, --help
EOF
}

parse_args() {
  while (( $# > 0 )); do
    case "$1" in
      -d|--desktop)
        case "$2" in
          niri|hyprland|both|none) DESKTOP_ENV="$2" ;;
          *) die "invalid --desktop value: $2 (niri|hyprland|both|none)" ;;
        esac
        shift 2 ;;
      -t|--machine)
        case "$2" in
          vm|physical) MACHINE_TYPE="$2" ;;
          *) die "invalid --machine value: $2 (vm|physical)" ;;
        esac
        shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown argument: $1 (see --help)" ;;
    esac
  done
}

ensure_fzf_ui() {
  # fzf is only needed for interactive selection
  if [[ -z "${DESKTOP_ENV}" || -z "${MACHINE_TYPE}" ]]; then
    ensure_fzf
  fi
}

select_desktop() {
  [[ -n "${DESKTOP_ENV}" ]] && return
  section "Select desktop environment"
  local selected
  selected="$(printf 'Niri (recommended)\nHyprland\nNiri + Hyprland (both)\nNo desktop (packages and config only)\n' \
    | fzf --layout=reverse --border=rounded \
        --header=' Select desktop (J/K move, Enter confirm) ' \
        --bind 'j:down,k:up,esc:abort,ctrl-c:abort')" || true
  [[ -z "${selected}" ]] && die "Cancelled"
  case "${selected}" in
    *"Hyprland (both)"*) DESKTOP_ENV="both" ;;
    *Hyprland*) DESKTOP_ENV="hyprland" ;;
    *"No desktop"*) DESKTOP_ENV="none" ;;
    *) DESKTOP_ENV="niri" ;;
  esac
  log "Desktop: ${DESKTOP_ENV}"
}

select_machine() {
  [[ -n "${MACHINE_TYPE}" ]] && return
  section "Select machine type"
  local selected
  selected="$(printf 'Physical machine (ASUS, full config)\nVirtual machine (light config)\n' \
    | fzf --layout=reverse --border=rounded \
        --header=' Select machine type (J/K move, Enter confirm) ' \
        --bind 'j:down,k:up,esc:abort,ctrl-c:abort')" || true
  [[ -z "${selected}" ]] && die "Cancelled"
  case "${selected}" in
    *"Virtual machine"*) MACHINE_TYPE="vm" ;;
    *) MACHINE_TYPE="physical" ;;
  esac
  log "Machine: ${MACHINE_TYPE}"
}

build_modules() {
  MODULES=(01-mirror.sh 02-system.sh 03-packages.sh)
  # drivers before desktop (physical only; the script itself skips on vm)
  MODULES+=(04-drivers.sh)
  case "${DESKTOP_ENV}" in
    niri) MODULES+=(05-niri.sh) ;;
    hyprland) MODULES+=(05-hyprland.sh) ;;
    both) MODULES+=(05-niri.sh 05-hyprland.sh) ;;
    none) log "Skipping desktop environment" ;;
  esac
  MODULES+=(06-aur.sh 07-config.sh 08-services.sh 09-settings.sh 99-cleanup.sh)
}

main() {
  parse_args "$@"
  check_root
  ensure_fzf_ui
  select_machine
  select_desktop
  build_modules
  sys_dashboard

  # Module scripts run as child processes; export the selections so they
  # can read MACHINE_TYPE/DESKTOP_ENV without re-prompting.
  export MACHINE_TYPE DESKTOP_ENV

  section "Pre-Flight" "System update"
  run pacman -Sy --noconfirm archlinux-keyring
  run pacman -Syyu --noconfirm

  local total="${#MODULES[@]}" current=0
  for module in "${MODULES[@]}"; do
    [[ -z "${module}" ]] && continue
    current=$((current + 1))
    local script_path="${SCRIPTS_DIR}/${module}"
    [[ -f "${script_path}" ]] || { warn "Missing script: ${module}"; continue; }
    if is_done "${module}"; then
      log "Module ${module} already done, skipping"
      continue
    fi
    section "Step ${current}/${total}" "${module}"
    # shellcheck disable=SC1090
    bash "${script_path}"
    local rc=$?
    if (( rc == 0 )); then
      mark_done "${module}"
      success "Done: ${module}"
    else
      error "Module ${module} failed (exit ${rc}); rerun install.sh to resume"
      exit "${rc}"
    fi
  done

  section "Done"
  success "Installation complete. A reboot is recommended."
  echo
  echo -e "${H_YELLOW}>>> A system reboot is required.${NC}"
}

main "$@"
