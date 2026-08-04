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
STATE_FILE="${BASE_DIR}/.install_progress"

# shellcheck source=scripts/00-utils.sh
source "${SCRIPTS_DIR}/00-utils.sh"

DESKTOP_ENV="${DESKTOP_ENV:-}"
MACHINE_TYPE="${MACHINE_TYPE:-}"
OPTIONAL_MODULES=()
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
  local items=(
    "Niri (recommended)|niri"
    "Hyprland|hyprland"
    "Niri + Hyprland (both)|both"
    "No desktop (packages and config only)|none"
  )
  local fzf_list=() idx=1
  for item in "${items[@]}"; do
    fzf_list+=("${idx}) ${item%%|*}")
    ((idx++))
  done
  local selected
  selected="$(printf '%b\n' "${fzf_list[@]}" | fzf --layout=reverse --border=rounded \
    --header=' Select desktop (J/K move, Enter confirm) ' \
    --bind 'j:down,k:up,esc:abort,ctrl-c:abort')" || true
  [[ -z "${selected}" ]] && die "Cancelled"
  local pick="${selected%% )*}"
  DESKTOP_ENV="${items[$((pick - 1))]##*|}"
  log "Desktop: ${DESKTOP_ENV}"
}

select_machine() {
  [[ -n "${MACHINE_TYPE}" ]] && return
  section "Select machine type"
  local items=(
    "Physical machine (ASUS, full config)|physical"
    "Virtual machine (light config)|vm"
  )
  local fzf_list=() idx=1
  for item in "${items[@]}"; do
    fzf_list+=("${idx}) ${item%%|*}")
    ((idx++))
  done
  local selected
  selected="$(printf '%b\n' "${fzf_list[@]}" | fzf --layout=reverse --border=rounded \
    --header=' Select machine type (J/K move, Enter confirm) ' \
    --bind 'j:down,k:up,esc:abort,ctrl-c:abort')" || true
  [[ -z "${selected}" ]] && die "Cancelled"
  local pick="${selected%% )*}"
  MACHINE_TYPE="${items[$((pick - 1))]##*|}"
  log "Machine: ${MACHINE_TYPE}"
}

build_modules() {
  MODULES=(01-mirror.sh 02-system.sh 03-packages.sh)
  case "${DESKTOP_ENV}" in
    niri) MODULES+=(04-niri.sh) ;;
    hyprland) MODULES+=(04-hyprland.sh) ;;
    both) MODULES+=(04-niri.sh 04-hyprland.sh) ;;
    none) log "Skipping desktop environment" ;;
  esac
  MODULES+=(05-aur.sh 06-config.sh 07-services.sh 99-cleanup.sh)
}

main() {
  parse_args "$@"
  check_root
  ensure_fzf_ui
  select_machine
  select_desktop
  build_modules
  sys_dashboard

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
