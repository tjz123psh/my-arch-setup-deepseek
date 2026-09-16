#!/usr/bin/env bash
# dsh-web-watchdog.sh — 页面关闭后自动停止 dsh web。
#
# 由 dsh-web.sh 在服务就绪后派生（脱离终端）。工作机制：
#   1. 每 INTERVAL 秒数一次「本地端口是 <port> 且属于 dsh 进程」的 ESTAB 连接；
#   2. **至少见过一个客户端之后才「武装」**——dsh 就绪到浏览器连上之间有一段
#      零连接的窗口，没有这一步会自杀；
#   3. 武装后连接数持续为 0 达到 --idle-sec 秒 → SIGTERM 掉 dsh；
#   4. 豁免：<keepalive> 文件存在时计时暂停（任何时刻 touch 都生效）。
#
# 安全设计：只在**确定数到 0** 时才计时。ss 缺失/执行失败一律视为「未知」，
# 只重置计时并记一笔日志，绝不据此关闭服务。
#
# 用法:
#   dsh-web-watchdog.sh --pid <dsh-pid> [--port 3080] [--idle-sec 120] \
#                       [--log <file>] [--keepalive <file>]
set -uo pipefail

TARGET=""
PORT="3080"
IDLE_SEC="120"
LOG="$HOME/.dsh/watchdog.log"
KEEPALIVE="$HOME/.dsh/keepalive"
PIDFILE="$HOME/.dsh/dsh-web-watchdog.pid"
INTERVAL=5

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pid)        TARGET="${2:-}";    shift 2 ;;
    --port)       PORT="${2:-}";      shift 2 ;;
    --idle-sec)   IDLE_SEC="${2:-}";  shift 2 ;;
    --log)        LOG="${2:-}";       shift 2 ;;
    --keepalive)  KEEPALIVE="${2:-}"; shift 2 ;;
    --pidfile)    PIDFILE="${2:-}";   shift 2 ;;
    *)            shift ;;
  esac
done

log() {
  printf '%s [watchdog] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOG" 2>/dev/null || true
}

if [[ -z "$TARGET" || ! "$TARGET" =~ ^[0-9]+$ ]]; then
  log "缺少或非法的 --pid，退出"
  exit 2
fi
if ! [[ "$IDLE_SEC" =~ ^[0-9]+$ ]] || (( IDLE_SEC < 5 )); then
  log "非法 --idle-sec=$IDLE_SEC，回退 120"
  IDLE_SEC=120
fi
if ! command -v ss >/dev/null 2>&1; then
  log "找不到 ss（iproute2），不武装以免误关服务，退出"
  exit 3
fi

mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
# 去重：同一目标已有存活看门狗时本次退出。图标连点、或"升级脚本 + 启动器"在同一秒并发派生，
# 会起两份守候同一 pid 的看门狗（2026-09-15 16:54:40 实测两份），pidfile 被后写者覆盖。
if [[ -f "$PIDFILE" ]]; then
  read -r _wp _wt _wi <"$PIDFILE" 2>/dev/null || true
  if [[ -n "${_wp:-}" && "${_wp}" != "$$" && "${_wt:-}" == "$TARGET" ]] && kill -0 "$_wp" 2>/dev/null; then
    log "已有看门狗 pid=$_wp 在守候 pid=$TARGET，本次退出（避免重复派生）"
    exit 0
  fi
fi
printf '%s %s %s\n' "$$" "$TARGET" "$IDLE_SEC" >"$PIDFILE" 2>/dev/null || true
log "启动 pid=$$ 目标=$TARGET 端口=$PORT 宽限=${IDLE_SEC}s 间隔=${INTERVAL}s"

# 返回「本地端口是 PORT 且归属 TARGET」的 ESTAB 连接数；失败返回非 0。
client_count() {
  local out
  out=$(ss -tnp 2>/dev/null) || return 1
  printf '%s\n' "$out" | awk -v tgt="pid=$TARGET," -v p=":$PORT" '
    $1 == "ESTAB" && $4 ~ (p "$") && index($0, tgt) > 0 { c++ }
    END { print c + 0 }'
  return 0
}

# 目标还在监听 PORT 吗（目标进程没了或端口没了都算服务已消失）
service_alive() {
  kill -0 "$TARGET" 2>/dev/null || return 1
  ss -tln 2>/dev/null | awk -v p=":$PORT" '$4 ~ (p "$") { found = 1 } END { exit found ? 0 : 1 }'
}

cleanup() { rm -f "$PIDFILE" 2>/dev/null || true; }
trap cleanup EXIT

armed=0
idle=0
paused_logged=0
unknown_logged=0

while :; do
  if ! service_alive; then
    log "目标 $TARGET 已退出或 $PORT 不再监听，看门狗结束"
    exit 0
  fi

  # 始终观察客户端并武装——豁免只影响「是否执行关闭」。若豁免期间跳过计数，
  # 解除豁免后就永远等不到武装，会出现「豁免解除却永不自动关闭」的不对称。
  if ! n=$(client_count); then
    if (( unknown_logged == 0 )); then
      log "ss 执行失败，无法判断客户端数；暂停计时（不会据此关闭）"
      unknown_logged=1
    fi
    idle=0
    sleep "$INTERVAL"
    continue
  fi
  unknown_logged=0

  if (( n > 0 )); then
    if (( armed == 0 )); then
      log "已武装：见到 $n 条客户端连接"
      armed=1
    fi
    idle=0
  elif (( armed )); then
    idle=$(( idle + INTERVAL ))
  fi

  if [[ -e "$KEEPALIVE" ]]; then
    if (( paused_logged == 0 )); then
      log "检测到 $KEEPALIVE：自动关闭暂停（仍在观察客户端）"
      paused_logged=1
    fi
    idle=0
  else
    if (( paused_logged )); then
      log "$KEEPALIVE 已移除：恢复自动关闭"
      paused_logged=0
    fi
    if (( armed )) && (( idle >= IDLE_SEC )); then
      log "连接数为 0 已持续 ${idle}s（阈值 ${IDLE_SEC}s），停止 dsh pid=$TARGET"
      kill -TERM "$TARGET" 2>/dev/null || true
      for _ in $(seq 1 30); do
        kill -0 "$TARGET" 2>/dev/null || break
        sleep 0.5
      done
      if kill -0 "$TARGET" 2>/dev/null; then
        log "已发 SIGTERM 但进程仍在（15s），不再补刀，交给人处理"
      else
        log "dsh 已退出，看门狗结束"
      fi
      exit 0
    fi
  fi

  sleep "$INTERVAL"
done