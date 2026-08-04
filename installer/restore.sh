#!/usr/bin/env bash
# shellcheck shell=bash
# One-click physical restore entry point (tty-safe).
#
# Designed for the operator's own ASUS workstation restore after a manual base
# install (partitioning, base system, GRUB, first boot, network — the project
# boundary). Runs the full nine-stage orchestrated DAG with an upfront plan
# summary and one confirmation, then reports per-stage results.
#
# Safety:
#   - never touches partition/GRUB/kernel/credentials/login-manager;
#   - reads the exact reviewed plan before doing anything (--plan is zero-write);
#   - installs only the build prerequisites that the AUR stages require and that
#     a clean base lacks (base-devel devtools rust curl git);
#   - runs the orchestrated apply with the three explicit confirmations, which
#     the operator grants by the single confirmation prompt below;
#   - any stage failure stops the run; rerun with the same command resumes.
#
# tty compatibility: gsudo's askpass helper falls back to systemd-ask-password
# when fuzzel is not yet installed, so the password prompt works from a plain
# tty with no graphical session.

set -Eeuo pipefail

PROJECT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
readonly PROJECT_DIR
readonly ORCHESTRATOR="${PROJECT_DIR}/installer/full-orchestrator.py"
readonly PROFILE_DEFAULT="asus-amd-nvidia"

PROFILE="${PROFILE_DEFAULT}"
PLAN_ONLY=false
ASSUME_YES=false
SKIP_PREREQS=false

usage() {
  cat <<'EOF_USAGE'
用法: restore.sh [options]

重装 Arch 基础系统并完成手工交接点（分区/GRUB/首次启动/联网）后，
在本机一键恢复完整工作站（九阶段 DAG：官方包 -> archlinuxcn -> AUR ->
配置 -> 系统动作）。

Options:
  -p, --profile NAME   目标 profile（默认 asus-amd-nvidia）
  --plan               只打印安装清单并退出（零写入）
  -y, --assume-yes     跳过清单确认，直接执行（仅用于已审阅过的重跑）
  --skip-prereqs       不自动安装 AUR 构建工具（假定 clean-base 已具备）
  -h, --help           显示本帮助并退出
EOF_USAGE
}

log() { printf '[restore] %s\n' "$*"; }
die() { printf '[restore] 错误: %s\n' "$*" >&2; exit 1; }

parse_args() {
  while (( $# > 0 )); do
    case "$1" in
      -p|--profile) PROFILE="$2"; shift 2 ;;
      --plan) PLAN_ONLY=true; shift ;;
      -y|--assume-yes) ASSUME_YES=true; shift ;;
      --skip-prereqs) SKIP_PREREQS=true; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "未知参数: $1（见 --help）" ;;
    esac
  done
}

# 检查环境前提（只读）
check_prereqs() {
  command -v python3 >/dev/null 2>&1 || die "缺少 python3（Arch 基础安装应已包含）"
  command -v sudo >/dev/null 2>&1 || die "缺少 sudo"
  command -v pacman >/dev/null 2>&1 || die "缺少 pacman（请确认这是 Arch 系统）"
  command -v git >/dev/null 2>&1 || die "缺少 git（请先: sudo pacman -S --needed git）"
  # 网络检查：只读，不修改任何东西
  if ! timeout 8 bash -c 'echo > /dev/tcp/8.8.8.8/53' 2>/dev/null; then
    log "警告: 网络探测失败（8.8.8.8:53）。AUR/archlinuxcn 阶段需要联网。"
    [[ "${ASSUME_YES}" == "true" ]] || die "请先建立可用网络连接（NetworkManager: nmcli device connect <iface>）"
  fi
}

# 检查 root 通道：sudo 是否可用（非交互探测，不弹框）
check_root() {
  if sudo -n true 2>/dev/null; then
    return 0
  fi
  # sudo 需要密码：确认当前 tty 可交互
  if [[ -t 0 ]] && [[ -t 1 ]]; then
    log "需要 root 权限。将提示输入 sudo 密码。"
    return 0
  fi
  die "sudo 需要密码且当前不是交互式 tty；请直接在终端运行（不要用 nohup/后台）。"
}

# 打印安装清单（读 --plan 文本输出，逐行展示）
show_plan() {
  log "读取 profile '${PROFILE}' 的只读安装计划..."
  local plan_out
  plan_out="$("${ORCHESTRATOR}" --profile "${PROFILE}" --plan 2>&1)" || \
    die "生成计划失败（profile '${PROFILE}' 可能不存在或配置有误）"
  printf '%s\n' "${plan_out}" | sed -n '1,60p'
  # 检查是否有 blocker
  if printf '%s\n' "${plan_out}" | grep -qE "Apply blockers: .*=(none|);"; then
    :
  elif printf '%s\n' "${plan_out}" | grep -qE "non-executable-modules=[^;]*[a-z]"; then
    die "计划存在 apply blockers（非可执行模块），不执行。请先检查模块状态。"
  fi
}

confirm_plan() {
  if [[ "${ASSUME_YES}" == "true" ]]; then
    log "已通过 --assume-yes 跳过清单确认。"
    return 0
  fi
  if [[ ! -t 0 ]]; then
    die "需要确认但 stdin 不是 tty；请直接运行，或使用 --assume-yes（仅限已审阅过的重跑）。"
  fi
  printf '\n[restore] 以上是将要执行的内容。输入 yes 继续，或任意其它内容中止: '
  local answer
  read -r answer
  if [[ "${answer}" != "yes" ]]; then
    die "已中止（输入不是 yes）。未做任何更改。"
  fi
}

# 安装 clean-base 缺失的 AUR 构建前提（一次性，幂等）
install_build_prereqs() {
  if [[ "${SKIP_PREREQS}" == "true" ]]; then
    log "已跳过构建工具安装（--skip-prereqs）。"
    return 0
  fi
  log "检查/安装 AUR 构建前提（base-devel devtools rust curl）..."
  local missing=()
  for p in base-devel devtools rust curl; do
    if ! pacman -Q "${p}" >/dev/null 2>&1; then missing+=("${p}"); fi
  done
  if (( ${#missing[@]} == 0 )); then
    log "构建工具已齐备。"
    return 0
  fi
  printf '[restore] 将安装构建前提: %s\n' "${missing[*]}"
  sudo pacman -S --needed --noconfirm "${missing[@]}" || \
    die "构建前提安装失败。请检查网络/镜像后重试。"
  log "构建前提就绪。"
}

# 执行九阶段 DAG
run_dag() {
  log "开始九阶段 DAG apply（profile '${PROFILE}'）..."
  log "命令: full-orchestrator.py --profile ${PROFILE} --mode new --apply --confirm-system-changes --confirm-archlinuxcn --confirm-aur"
  # 直接前台运行；任何阶段失败会非零退出，随后由 run_dag 的调用方报告
  "${ORCHESTRATOR}" --profile "${PROFILE}" --mode new --apply \
    --confirm-system-changes --confirm-archlinuxcn --confirm-aur
}

report_done() {
  cat <<'EOF_DONE'

[restore] 九阶段 DAG 执行完成。

接下来请在本机逐项验收（安装器不会自动完成这些）:
  1. 显示/GPU: 切换 NVIDIA <-> AMD，确认输出正常
  2. 音频: 播放与录音
  3. 蓝牙: 连接设备
  4. 挂起/唤醒
  5. ASUS 控制中心（风扇/性能模式）

若某阶段失败，直接重跑本脚本即可（幂等；同一计划会 resume/rerun）。
EOF_DONE
}

main() {
  parse_args "$@"
  cd "${PROJECT_DIR}"
  check_prereqs
  show_plan
  if [[ "${PLAN_ONLY}" == "true" ]]; then
    log "已按 --plan 只打印清单，未做任何更改。"
    exit 0
  fi
  check_root
  confirm_plan
  install_build_prereqs
  run_dag
  report_done
}

main "$@"
