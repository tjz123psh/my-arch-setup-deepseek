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
用法: install.sh [options]

一键恢复 Arch 桌面环境（Niri/Hyprland）。交互式选择桌面与机器类型；
可用参数直接指定以跳过交互。

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
  section "选择桌面环境"
  local items=(
    "Niri (推荐)|niri"
    "Hyprland|hyprland"
    "Niri + Hyprland 双会话|both"
    "不装桌面（仅包与配置）|none"
  )
  local fzf_list=() idx=1
  for item in "${items[@]}"; do
    fzf_list+=("${idx}) ${item%%|*}")
    ((idx++))
  done
  local selected
  selected="$(printf '%b\n' "${fzf_list[@]}" | fzf --layout=reverse --border=rounded \
    --header=' 选择桌面 (J/K 移动, Enter 确认) ' \
    --bind 'j:down,k:up,esc:abort,ctrl-c:abort')" || true
  [[ -z "${selected}" ]] && die "已取消"
  local pick="${selected%% )*}"
  DESKTOP_ENV="${items[$((pick - 1))]##*|}"
  log "桌面: ${DESKTOP_ENV}"
}

select_machine() {
  [[ -n "${MACHINE_TYPE}" ]] && return
  section "选择机器类型"
  local items=(
    "物理机 (ASUS, 完整配置)|physical"
    "虚拟机 (轻量配置)|vm"
  )
  local fzf_list=() idx=1
  for item in "${items[@]}"; do
    fzf_list+=("${idx}) ${item%%|*}")
    ((idx++))
  done
  local selected
  selected="$(printf '%b\n' "${fzf_list[@]}" | fzf --layout=reverse --border=rounded \
    --header=' 选择机器类型 (J/K 移动, Enter 确认) ' \
    --bind 'j:down,k:up,esc:abort,ctrl-c:abort')" || true
  [[ -z "${selected}" ]] && die "已取消"
  local pick="${selected%% )*}"
  MACHINE_TYPE="${items[$((pick - 1))]##*|}"
  log "机器: ${MACHINE_TYPE}"
}

build_modules() {
  MODULES=(01-mirror.sh 02-system.sh 03-packages.sh)
  case "${DESKTOP_ENV}" in
    niri) MODULES+=(04-niri.sh) ;;
    hyprland) MODULES+=(04-hyprland.sh) ;;
    both) MODULES+=(04-niri.sh 04-hyprland.sh) ;;
    none) log "不安装桌面环境" ;;
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

  section "Pre-Flight" "系统更新"
  run pacman -Sy --noconfirm archlinux-keyring
  run pacman -Syyu --noconfirm

  local total="${#MODULES[@]}" current=0
  for module in "${MODULES[@]}"; do
    [[ -z "${module}" ]] && continue
    current=$((current + 1))
    local script_path="${SCRIPTS_DIR}/${module}"
    [[ -f "${script_path}" ]] || { warn "缺少脚本: ${module}"; continue; }
    if is_done "${module}"; then
      log "模块 ${module} 已完成，跳过"
      continue
    fi
    section "步骤 ${current}/${total}" "${module}"
    # shellcheck disable=SC1090
    bash "${script_path}"
    local rc=$?
    if (( rc == 0 )); then
      mark_done "${module}"
      success "完成: ${module}"
    else
      error "模块 ${module} 失败 (exit ${rc})；重新运行 install.sh 可续跑"
      exit "${rc}"
    fi
  done

  section "完成"
  success "安装完成，建议重启。"
  echo
  echo -e "${H_YELLOW}>>> 系统需要重启。${NC}"
}

main "$@"
