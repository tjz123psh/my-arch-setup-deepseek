#!/usr/bin/env bash
# 启动 DeepSeek Harness (dsh) Web UI 并在浏览器打开。
# 若端口已有 dsh 在运行则直接打开浏览器，否则后台启动并等待就绪。
#
# 关页面即停：启动服务后由 dsh-web-watchdog.sh 守候——浏览器页面全部关闭后，
# 连接数归零持续 IDLE_SEC 秒就自动停掉服务（默认 120 秒）。
# 临时保留服务（例如让 agent 用 API 驱动）：touch ~/.dsh/keepalive
#
# 用法:
#   dsh-web.sh              # 启动/打开 dsh Web UI
#   dsh-web.sh --stop       # 停止 dsh web 与看门狗
#   dsh-web.sh --status     # 查看服务/看门狗/客户端连接状态
#   dsh-web.sh --help       # 显示帮助
#
# 环境变量:
#   DSH_WEB_PORT        监听端口（默认 3080）
#   DSH_WEB_IDLE_SEC    关页面后自动停止的宽限秒数（默认 120，最小 5）
set -euo pipefail

DSH_BIN="$HOME/.npm-global/bin/dsh"
PORT="${DSH_WEB_PORT:-3080}"
LOG_FILE="$HOME/.dsh/web.log"
URL="http://127.0.0.1:$PORT"
TIMEOUT_SEC=30

# 看门狗与启动器同目录：按自身位置解析，整目录再移动也不会断链
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
WATCHDOG="$SCRIPT_DIR/dsh-web-watchdog.sh"
WATCHDOG_LOG="$HOME/.dsh/watchdog.log"
WATCHDOG_PIDFILE="$HOME/.dsh/dsh-web-watchdog.pid"
KEEPALIVE="$HOME/.dsh/keepalive"
IDLE_SEC="${DSH_WEB_IDLE_SEC:-120}"

usage() {
  cat <<EOF
Usage: dsh-web.sh [options]

Options:
  -h, --help    显示帮助并退出
  --stop        停止正在运行的 dsh web（含看门狗）
  --status      显示服务、看门狗与客户端连接状态

行为:
  启动后由看门狗守候：所有浏览器页面关闭后，连接数归零持续 ${IDLE_SEC} 秒
  自动停止服务。要临时保留（例如让 agent 用 API 驱动），执行：
      touch $KEEPALIVE      # 暂停自动停止
      rm $KEEPALIVE         # 恢复自动停止

环境变量:
  DSH_WEB_PORT       监听端口（默认 3080）
  DSH_WEB_IDLE_SEC   自动停止宽限秒数（默认 120）
EOF
}

require_deps() {
  local missing=()
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  if (( ${#missing[@]} > 0 )); then
    printf '错误: 缺少依赖: %s\n' "${missing[*]}" >&2
    exit 127
  fi
}

port_open() {
  curl -s -o /dev/null --max-time 2 "$URL/" 2>/dev/null
}

# 监听 $PORT 的进程 pid（看门狗需要它来数连接/精确停止）。
# 注意：`set -e` 下 `x=$(管道)` 的失败会直接结束脚本，而"端口没人监听"是正常
# 情形，所以这里必须吞掉管道退出码（否则 --stop 在无服务时会静默退出）。
dsh_pid_on_port() {
  local out=""
  out=$(ss -tlnp 2>/dev/null | grep -F ":$PORT " | grep -oE 'pid=[0-9]+' | head -1 | cut -d= -f2) || true
  printf '%s' "$out"
  return 0
}

# dsh >= 0.1.2 有 browser-trust 门：无 cookie 时裸 URL 首开会 401 回
# "dsh web authentication required; reopen the URL printed by dsh web"。
# 启动日志里带 ?token= 的那条才是首开通行证（访问一次签发 30 天持久 cookie，
# 签名密钥存于 credentials，跨重启有效）。URL 行要等插件树装载完，
# 可能晚于端口就绪，故带轮询等待。
auth_url_from_log() {
  local retries=$(( ${1:-0} )) line=""
  while :; do
    line=$(grep -aoE "dsh web: http://[^ ]+token=[A-Za-z0-9_-]+" "$LOG_FILE" 2>/dev/null | tail -1) || line=""
    if [[ -n "$line" || $retries -eq 0 ]]; then break; fi
    retries=$((retries - 1)); sleep 1
  done
  line=${line#dsh web: }
  printf '%s' "$line"
}

# --- 看门狗管理 ---------------------------------------------------------
# pidfile 内容: "<看门狗 pid> <被守候的 dsh pid>"

watchdog_is_current() {
  local want="$1" wpid tpid
  [[ -f "$WATCHDOG_PIDFILE" ]] || return 1
  read -r wpid tpid <"$WATCHDOG_PIDFILE" 2>/dev/null || return 1
  [[ -n "${wpid:-}" && -n "${tpid:-}" ]] || return 1
  kill -0 "$wpid" 2>/dev/null || return 1
  [[ "$tpid" == "$want" ]] || return 1
  return 0
}

stop_watchdog() {
  local wpid=""
  [[ -f "$WATCHDOG_PIDFILE" ]] || return 0
  read -r wpid _ <"$WATCHDOG_PIDFILE" 2>/dev/null || true
  if [[ -n "${wpid:-}" ]] && kill -0 "$wpid" 2>/dev/null; then
    kill -TERM "$wpid" 2>/dev/null || true
    echo "已停止看门狗 (pid=$wpid)"
  fi
  rm -f "$WATCHDOG_PIDFILE"
  return 0
}

# 确保有且只有一个守候当前 dsh 的看门狗。dsh 被插件市场重启过（pid 变了、
# 看门狗没了）时，再次运行本脚本即可重新武装。
ensure_watchdog() {
  local dpid="${1:-}"
  if [[ -z "$dpid" ]]; then
    echo "警告: 取不到 $PORT 上的 dsh pid，未启动看门狗（关页面不会自动停止）" >&2
    return 0
  fi
  if watchdog_is_current "$dpid"; then
    return 0
  fi
  stop_watchdog >/dev/null 2>&1 || true
  if [[ ! -x "$WATCHDOG" ]]; then
    echo "警告: 缺少可执行的 $WATCHDOG，未启动看门狗（关页面不会自动停止）" >&2
    return 0
  fi
  setsid nohup "$WATCHDOG" \
    --pid "$dpid" --port "$PORT" --idle-sec "$IDLE_SEC" \
    --log "$WATCHDOG_LOG" --keepalive "$KEEPALIVE" --pidfile "$WATCHDOG_PIDFILE" \
    >/dev/null 2>&1 < /dev/null &
  disown 2>/dev/null || true
  if [[ -e "$KEEPALIVE" ]]; then
    echo "看门狗已启动（注意: $KEEPALIVE 存在，自动停止当前处于暂停状态）"
  else
    echo "看门狗已启动: 页面全部关闭后 $IDLE_SEC 秒自动停止（保留请 touch $KEEPALIVE）"
  fi
}

stop_dsh() {
  stop_watchdog
  local dpid
  dpid=$(dsh_pid_on_port)
  if [[ -n "$dpid" ]] && kill -0 "$dpid" 2>/dev/null; then
    kill -TERM "$dpid" 2>/dev/null || true
    echo "已停止 dsh web (pid=$dpid)"
  elif pkill -f "$DSH_BIN web" 2>/dev/null; then
    echo "已停止 dsh web"
  else
    echo "没有正在运行的 dsh web"
    return 0
  fi
  # 等端口真正释放（最多 5s）：紧接 --stop 后的启动会先探测端口，
  # 若旧进程未退净会被误判"已在运行"而跳过启动。
  local i
  for ((i = 0; i < 10; i++)); do
    port_open || return 0
    sleep 0.5
  done
  echo "警告: 端口 $PORT 仍在监听，进程可能未完全退出" >&2
  return 0
}

show_status() {
  local dpid wpid tpid n
  dpid=$(dsh_pid_on_port)
  if [[ -z "$dpid" ]]; then
    echo "服务: 未运行（端口 $PORT 无监听）"
  else
    echo "服务: 运行中 pid=$dpid  $URL"
    n=$(ss -tnp 2>/dev/null | awk -v tgt="pid=$dpid," -v p=":$PORT" \
      '$1 == "ESTAB" && $4 ~ (p "$") && index($0, tgt) > 0 { c++ } END { print c + 0 }')
    echo "客户端连接: $n 条"
  fi
  if [[ -f "$WATCHDOG_PIDFILE" ]]; then
    local idle_shown="$IDLE_SEC"
    read -r wpid tpid idle_shown <"$WATCHDOG_PIDFILE" 2>/dev/null || true
    if [[ -n "${wpid:-}" ]] && kill -0 "$wpid" 2>/dev/null; then
      echo "看门狗: 运行中 pid=$wpid 守候 dsh pid=${tpid:-?} 宽限 ${idle_shown:-$IDLE_SEC}s 日志 $WATCHDOG_LOG"
    else
      echo "看门狗: 未运行（残留 pidfile）"
    fi
  else
    echo "看门狗: 未运行"
  fi
  [[ -e "$KEEPALIVE" ]] && echo "豁免: $KEEPALIVE 存在 → 自动停止已暂停"
  return 0
}

# dsh 被重装/升级后，npm 会覆盖启动提速补丁（改的是第三方依赖
# dsh-client-modules 的两处热点函数写法）。这里在起新实例前自动补一次，
# 免去手工记忆：幂等，已打过时只做一次 grep（~ms）。
# 失败**绝不阻断启动**——最坏只是启动慢约 2.3s。
ensure_speedup_patch() {
  local patcher="$SCRIPT_DIR/patch-upstream-client-modules-speedup.sh"
  [[ -f "$patcher" ]] || return 0
  local out
  if ! out=$(bash "$patcher" 2>&1); then
    echo "警告: 启动提速补丁应用失败（不影响启动，最坏启动慢约 2.3s）:" >&2
    printf '%s\n' "$out" | tail -3 >&2
    return 0
  fi
  if [[ "$out" != *"已经是打过补丁的状态"* ]]; then
    echo "已自动重跑启动提速补丁（检测到 dsh 被重装过）"
  fi
  return 0
}

main() {
  require_deps curl xdg-open ss
  if [[ ! -x "$DSH_BIN" ]]; then
    printf '错误: 找不到 dsh: %s\n' "$DSH_BIN" >&2
    exit 1
  fi

  if port_open; then
    echo "dsh web 已在运行: $URL"
    # 已有实例时也要保证看门狗在位（市场重启会带走它）
    ensure_watchdog "$(dsh_pid_on_port)"
    local open_url
    open_url=$(auth_url_from_log 0)
    if [[ -n "$open_url" ]]; then
      echo "打开通行 URL: $open_url"
      xdg-open "$open_url"
    else
      echo "提示: 未从日志取到 token，若页面要求 authentication required，请打开: grep 'dsh web:' '$LOG_FILE' | tail -1"
      xdg-open "$URL"
    fi
    exit 0
  fi

  echo "正在启动 dsh web ..."
  ensure_speedup_patch
  mkdir -p "$(dirname "$LOG_FILE")"
  # 必须 --no-open：dsh 自身会调 xdg-open 开一次浏览器，脚本就绪后再开一次会变双标签。
  # 由脚本统一负责打开，保证每次调用只出一个标签页。
  nohup "$DSH_BIN" web --no-open --port "$PORT" >"$LOG_FILE" 2>&1 &
  disown

  local i dpid open_url
  for ((i = 0; i < TIMEOUT_SEC; i++)); do
    if port_open; then
      echo "dsh web 已就绪: $URL（日志: $LOG_FILE）"
      dpid=$(dsh_pid_on_port)
      ensure_watchdog "$dpid"
      # 优先打开带 token 的 URL（首开过闸）；等 20s 拿不到就退回裸 URL（旧版 dsh 无门禁）。
      # token 行要等插件树装载完才打印，端口就绪时常还没出现——8s 偏紧，实测会退回裸
      # URL 并让页面显示 authentication required，故放宽到 20s（仍可能晚于端口，属正常）。
      open_url=$(auth_url_from_log 20)
      [[ -z "$open_url" ]] && open_url="$URL"
      if [[ "$open_url" == "$URL" ]]; then
        echo "提示: 20s 内未取到 token，先开裸 URL；若页面要求 authentication required，请重跑本脚本或执行: grep 'dsh web:' '$LOG_FILE' | tail -1" >&2
      fi
      echo "打开通行 URL: $open_url"
      xdg-open "$open_url"
      exit 0
    fi
    sleep 1
  done

  printf '错误: %s 秒内端口 %s 未就绪，请查看日志: %s\n' "$TIMEOUT_SEC" "$PORT" "$LOG_FILE" >&2
  exit 1
}

# --- 参数解析 ---
ACTION=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --stop) ACTION="stop" ;;
    --status) ACTION="status" ;;
    *) printf '错误: 未知参数: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

case "$ACTION" in
  stop) stop_dsh; exit $? ;;
  status) show_status; exit $? ;;
  *) main ;;
esac