# shellcheck shell=bash disable=SC2034,SC2059,SC2317
# ==============================================================================
# ui.sh — 维护脚本统一 UI 库
# ------------------------------------------------------------------------------
# 作用：为 ~/scripts/maintenance 下所有脚本提供统一的颜色、日志、分节、
#       确认提示和 fzf 外观。所有脚本 source 本文件后使用其函数与变量。
#
# 用法：
#   UI_LIB="$(dirname "$(readlink -f "$0")")/lib/ui.sh"
#   # shellcheck source=lib/ui.sh
#   . "$UI_LIB"
#
# 设计约定：
#   - 纯中文界面。
#   - 本库不设置 set -e/-u，避免污染调用方；调用方自行决定 set 选项。
#   - 颜色在非 TTY（管道/重定向）时自动关闭，避免转义码污染日志与文件。
#   - fzf preview 子进程通过 UI_FORCE_COLOR=1 强制上色（因 preview 的
#     stdout 是管道，默认会被判定为非 TTY）。
#   - 日志标签统一为 [消息] [成功] [注意] [错误]，均为两个汉字，视觉等宽，
#     天然对齐，无需 printf 宽度填充。
# ==============================================================================

# 防止重复 source
if [[ -n "${_UI_SH_LOADED:-}" ]]; then
  return 0 2>/dev/null || true
fi
_UI_SH_LOADED=1

# 宽度计算依赖按"字符"迭代：cron/systemd/ssh 下常见 LC_ALL=C/POSIX，那时
# ${s:i:1} 按字节切分，中文会被算成 3 列。必要时用 C.UTF-8 覆盖（仅函数内）。
_UI_NEEDS_UTF8=0
case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
  *UTF-8*|*utf8*|*UTF8*) ;;
  *)
    if LC_ALL=C.UTF-8 locale charmap 2>/dev/null | grep -q UTF-8; then
      _UI_NEEDS_UTF8=1
    fi
    ;;
esac

# ------------------------------------------------------------------------------
# 颜色决策：UI_FORCE_COLOR > NO_COLOR > TTY 检测
# ------------------------------------------------------------------------------
_ui_use_color() {
  # UI_FORCE_COLOR=1/true/yes 强制上色，=0/false/no 明确关闭；
  # 旧实现只看"非空"，于是 UI_FORCE_COLOR=0 反而会强制上色。
  case "${UI_FORCE_COLOR:-}" in
    1|true|yes) return 0 ;;
    0|false|no) return 1 ;;
  esac
  if [[ -n "${NO_COLOR:-}" ]]; then
    return 1
  fi
  [[ -t 1 ]]
}

if _ui_use_color; then
  UI_RESET=$'\033[0m'
  UI_BOLD=$'\033[1m'
  UI_DIM=$'\033[2m'
  UI_RED=$'\033[31m'
  UI_GREEN=$'\033[32m'
  UI_YELLOW=$'\033[33m'
  UI_BLUE=$'\033[34m'
  UI_MAGENTA=$'\033[35m'
  UI_CYAN=$'\033[36m'
  # 24 位真彩：蓝紫渐变主色，与 term-menu 玻璃拟态呼应
  UI_C_SAPPHIRE=$'\033[38;2;116;199;236m'  # #74c7ec 天蓝（输入区色阶）
  UI_C_BLUE=$'\033[38;2;137;180;250m'      # #89b4fa 蓝（列表色阶）
  UI_C_LAVENDER=$'\033[38;2;180;190;254m'  # #b4befe 薰衣草（主边框）
  UI_C_MAUVE=$'\033[38;2;203;166;247m'     # #cba6f7 紫（强调/标题）
  UI_C_PINK=$'\033[38;2;245;194;231m'      # #f5c2e7 粉（页脚色阶）
  UI_C_SKY=$'\033[38;2;137;220;235m'       # #89dceb 青
  UI_C_TEXT=$'\033[38;2;205;214;244m'      # #cdd6f4 正文
  UI_C_SUBTLE=$'\033[38;2;166;173;200m'    # #a6adc8 次要文本
  UI_C_GREEN=$'\033[38;2;166;227;161m'     # #a6e3a1
  UI_C_YELLOW=$'\033[38;2;249;226;175m'    # #f9e2af
  UI_C_RED=$'\033[38;2;243;139;168m'       # #f38ba8
  # 状态徽章图标（Nerd Font）
  UI_ICON_OK=$'\uf058'      # nf-fa-check_circle
  UI_ICON_WARN=$'\uf071'    # nf-fa-exclamation_triangle
  UI_ICON_MISS=$'\uf056'    # nf-fa-minus_circle
  UI_ICON_ERR=$'\uf057'     # nf-fa-times_circle
  UI_ICON_INFO=$'\uf05a'    # nf-fa-info_circle
else
  UI_RESET=''
  UI_BOLD=''
  UI_DIM=''
  UI_RED=''
  UI_GREEN=''
  UI_YELLOW=''
  UI_BLUE=''
  UI_MAGENTA=''
  UI_CYAN=''
  UI_C_SAPPHIRE=''
  UI_C_BLUE=''
  UI_C_LAVENDER=''
  UI_C_MAUVE=''
  UI_C_PINK=''
  UI_C_SKY=''
  UI_C_TEXT=''
  UI_C_SUBTLE=''
  UI_C_GREEN=''
  UI_C_YELLOW=''
  UI_C_RED=''
  UI_ICON_OK='[成功]'
  UI_ICON_WARN='[注意]'
  UI_ICON_MISS='[缺失]'
  UI_ICON_ERR='[错误]'
  UI_ICON_INFO='[消息]'
fi

# 经典别名：兼容大量使用简单色名的脚本，减少改动面。
NC="$UI_RESET"
BOLD="$UI_BOLD"
DIM="$UI_DIM"
RED="$UI_RED"
GREEN="$UI_GREEN"
YELLOW="$UI_YELLOW"
BLUE="$UI_BLUE"
CYAN="$UI_CYAN"

# ------------------------------------------------------------------------------
# sudo 保活
#   ui_sudo_keepalive_start ["提示文案"]  校验管理员权限并启动后台保活
#   ui_sudo_keepalive_stop                停止保活（幂等）
# 原来 sysup 和 clean 各写一份，细节已经不一致：clean 会在保活子进程里关掉
# 维护锁描述符，sysup 不会——那会让退出后的孤儿 sleep 继续持锁。这里以正确的
# 那一份为准统一。调用方需要把 ui_sudo_keepalive_stop 接进自己的 trap 链。
# ------------------------------------------------------------------------------
UI_SUDO_KEEPALIVE_PID=""

ui_sudo_keepalive_start() {
  local prompt="${1:-}"

  [[ -z "$UI_SUDO_KEEPALIVE_PID" ]] || return 0
  command -v sudo >/dev/null 2>&1 || return 127
  [[ -z "$prompt" ]] || ui_info "%s" "$prompt"
  sudo -v || return 1
  # 主进程被 SIGKILL 时 EXIT trap 跑不到，保活子进程必须自己发现父进程消失后退出；
  # 否则会变成永久孤儿，每 60 秒继续 sudo -n true。
  local keepalive_parent="${BASHPID:-$$}"
  (
    # 后台保活绝不能继承维护锁，否则主脚本退出后孤儿 sleep 会继续持锁，
    # 导致紧接着运行 quicksave 被误判为“另一项维护正在运行”。
    if [[ "${UI_MAINTENANCE_LOCK_FD:-}" =~ ^[0-9]+$ ]]; then
      exec {UI_MAINTENANCE_LOCK_FD}>&-
    fi
    while true; do
      kill -0 "$keepalive_parent" 2>/dev/null || exit 0
      # 凭据已过期就没必要继续保活。
      sudo -n true 2>/dev/null || exit 0
      sleep 60
    done
  ) </dev/null >/dev/null 2>&1 &
  UI_SUDO_KEEPALIVE_PID=$!
}

ui_sudo_keepalive_stop() {
  [[ -n "$UI_SUDO_KEEPALIVE_PID" ]] || return 0
  pkill -TERM -P "$UI_SUDO_KEEPALIVE_PID" 2>/dev/null || true
  kill "$UI_SUDO_KEEPALIVE_PID" 2>/dev/null || true
  wait "$UI_SUDO_KEEPALIVE_PID" 2>/dev/null || true
  UI_SUDO_KEEPALIVE_PID=""
}

# ------------------------------------------------------------------------------
# 临时文件登记与清理
#   ui_tmp_register 路径...  登记本进程创建的临时文件/目录
#   ui_tmp_discard  路径...  立即删除并从登记表移除（正常路径用）
#   ui_tmp_cleanup           删除全部登记项，幂等；只在登记它们的进程里生效
#
# 调用方要自己把 ui_tmp_cleanup 接进 trap 链，例如：
#   trap 'ui_tmp_cleanup' EXIT
# 注意：命令替换是子 shell，在里面登记不会传回父 shell，必须在父 shell 登记：
#   f="$(mktemp)"; ui_tmp_register "$f"
# ------------------------------------------------------------------------------
UI_TMP_PATHS=()
UI_TMP_OWNER_PID="${BASHPID:-$$}"

ui_tmp_register() {
  (( $# > 0 )) || return 0
  UI_TMP_PATHS+=("$@")
}

ui_tmp_discard() {
  local path target keep=()

  (( $# > 0 )) || return 0
  for target in "$@"; do
    rm -rf -- "$target" 2>/dev/null || true
  done
  for path in ${UI_TMP_PATHS[@]+"${UI_TMP_PATHS[@]}"}; do
    for target in "$@"; do
      [[ "$path" == "$target" ]] && continue 2
    done
    keep+=("$path")
  done
  UI_TMP_PATHS=(${keep[@]+"${keep[@]}"})
}

ui_tmp_cleanup() {
  # 子 shell 不能替父进程清理：并行任务里删掉同伴的文件是灾难。
  [[ "${BASHPID:-$$}" == "$UI_TMP_OWNER_PID" ]] || return 0
  (( ${#UI_TMP_PATHS[@]} > 0 )) || return 0
  rm -rf -- "${UI_TMP_PATHS[@]}" 2>/dev/null || true
  UI_TMP_PATHS=()
}

# ------------------------------------------------------------------------------
# 日志函数
#   第一个参数是 printf 格式串，其余作为参数。
#   消息里出现"裸 %"（例如"已完成 100%"）时 printf 会把它当格式符：文本被截断，
#   而且在 set -e 的调用方里会直接中止整个脚本。这里先判断格式串是否安全，
#   不安全就按纯文本输出，避免文案或用户数据把脚本打挂。
#   ui_info/ui_ok/ui_warn/ui_err 打印到 stdout；ui_die 打印后 exit 1。
# ------------------------------------------------------------------------------
# 徽章前缀：TTY 下为「图标 」（图标后一个空格），非 TTY 下为「[标签] 」。
# 图标本身占 2 列，故 TTY 分支统一补 1 空格，视觉与文字标签「[xx] 」对齐。
# 纯 Bash 判断格式串是否只含合法转换（含宽度/精度/%%），不额外 fork。
_ui_fmt_is_safe() {
  local s="$1"
  while [[ "$s" =~ %[-+\ #0-9.]*[sdqbioxXeEfgGc%] ]]; do
    s="${s/"${BASH_REMATCH[0]}"/}"
  done
  [[ "$s" != *%* ]]
}

_ui_log() { # $1=颜色 $2=图标，其后为 格式串 [参数...]
  local color="$1" icon="$2" fmt
  shift 2
  fmt="${1:-}"
  shift 2>/dev/null || true
  if _ui_fmt_is_safe "$fmt"; then
    printf "${color}${icon}${UI_RESET} ${fmt}\n" "$@"
  elif (( $# > 0 )); then
    printf "%s%s%s %s %s\n" "$color" "$icon" "$UI_RESET" "$fmt" "$*"
  else
    printf "%s%s%s %s\n" "$color" "$icon" "$UI_RESET" "$fmt"
  fi
}

ui_info() { _ui_log "$UI_C_SAPPHIRE" "$UI_ICON_INFO" "$@"; }
# 在可能持续数秒至数分钟的同步操作前调用。它不是百分比进度条，
# 但会立即告诉用户当前卡在哪个阶段，避免空白终端看起来像已卡死。
ui_working() { local text="${1:-}"; ui_info "%s；请稍候…" "${text:-正在处理}"; }
ui_ok()   { _ui_log "$UI_C_GREEN" "$UI_ICON_OK" "$@"; }
ui_warn() { _ui_log "$UI_C_YELLOW" "$UI_ICON_WARN" "$@"; }
ui_err()  { _ui_log "$UI_C_RED" "$UI_ICON_ERR" "$@" >&2; }
ui_die()  { ui_err "$@"; exit 1; }

# 缺失/未检出项，用于检查类脚本
ui_miss() { _ui_log "$UI_C_YELLOW" "$UI_ICON_MISS" "$@"; }

# ------------------------------------------------------------------------------
# 跨维护脚本互斥锁。sudo/pkexec 后沿用原始用户 UID，受控子脚本可继承
# 已加锁的描述符，避免 sysup -> quicksave 这类嵌套调用把自己挡住。
# ------------------------------------------------------------------------------
ui_maintenance_lock_acquire() {
  local operation="${1:-系统维护}"
  local lock_uid lock_file lock_home lock_dir inherited_target expected_target

  lock_uid="${SUDO_UID:-${PKEXEC_UID:-}}"
  # root 直接运行（root shell / systemd / 不带 sudo 前缀）时没有 SUDO_UID：若按
  # id -u 取 0，root 与普通用户会各持一把锁、互不排斥（README 承诺的"同一把
  # flock"就不成立）。这里尽量找出真正的操作者，找不到才退回当前 uid。
  if [[ ! "$lock_uid" =~ ^[0-9]+$ ]]; then
    if [[ "$(id -u)" -eq 0 ]]; then
      if [[ -n "${SUDO_USER:-}" ]]; then
        lock_uid="$(id -u "$SUDO_USER" 2>/dev/null || true)"
      fi
      if [[ ! "$lock_uid" =~ ^[0-9]+$ ]] && command -v logname >/dev/null 2>&1; then
        local tty_user
        tty_user="$(logname 2>/dev/null || true)"
        if [[ -n "$tty_user" ]]; then
          lock_uid="$(id -u "$tty_user" 2>/dev/null || true)"
        fi
      fi
    fi
    [[ "$lock_uid" =~ ^[0-9]+$ ]] || lock_uid="$(id -u)"
  fi
  # 不能把可由普通用户创建的锁文件放在 sticky /tmp：root 经 sudo 重新执行时，
  # Linux 的 fs.protected_regular 会拒绝带 O_CREAT 的追加打开，导致高风险恢复
  # 在真正提权后反而无法取得同一把锁。默认改放到原用户 HOME 的缓存目录；
  # sudo/root 与原用户均能安全打开，显式 MAINTENANCE_LOCK_FILE 仍供测试/调用方使用。
  if [[ -n "${MAINTENANCE_LOCK_FILE:-}" ]]; then
    lock_file="$MAINTENANCE_LOCK_FILE"
  else
    lock_home="$HOME"
    if command -v getent >/dev/null 2>&1; then
      local owner_home
      owner_home="$(getent passwd "$lock_uid" 2>/dev/null | awk -F: 'NR == 1 {print $6}')"
      if [[ -n "$owner_home" && -d "$owner_home" ]]; then
        lock_home="$owner_home"
      fi
    fi
    [[ -n "$lock_home" && -d "$lock_home" ]] || lock_home="$HOME"
    lock_dir="$lock_home/.cache/maintenance"
    lock_file="$lock_dir/maintenance-${lock_uid}.lock"
    if ! mkdir -p "$lock_dir"; then
      ui_err "无法创建维护锁目录：%s" "$lock_dir"
      return 73
    fi
    # root 先跑会在用户目录里留下 root:root 的目录/文件，之后普通用户打开会
    # EACCES（退出码 73）。尽力把属主与权限校正回锁属主。
    if [[ "$(id -u)" -eq 0 && "$lock_uid" != "0" ]]; then
      chown "$lock_uid" "$lock_dir" 2>/dev/null || true
    fi
    chmod 700 "$lock_dir" 2>/dev/null || true
  fi

  if [[ "${MAINTENANCE_LOCK_HELD:-0}" == "1" \
        && "${UI_MAINTENANCE_LOCK_FD:-}" =~ ^[0-9]+$ \
        && -e "/proc/$$/fd/${UI_MAINTENANCE_LOCK_FD}" ]]; then
    inherited_target="$(readlink -f "/proc/$$/fd/${UI_MAINTENANCE_LOCK_FD}" 2>/dev/null || true)"
    expected_target="$(readlink -f "$lock_file" 2>/dev/null || true)"
    if [[ -n "$expected_target" && "$inherited_target" == "$expected_target" ]] \
        && flock -n "$UI_MAINTENANCE_LOCK_FD" 2>/dev/null; then
      return 0
    fi
    unset UI_MAINTENANCE_LOCK_FD MAINTENANCE_LOCK_HELD
  fi
  if ! command -v flock >/dev/null 2>&1; then
    ui_err "缺少 flock（util-linux），无法安全执行%s。" "$operation"
    return 127
  fi

  if ! exec {UI_MAINTENANCE_LOCK_FD}>>"$lock_file"; then
    ui_err "无法打开维护锁：%s" "$lock_file"
    return 73
  fi
  # 锁文件本身也必须属于锁属主且不可被他人改写。
  if [[ "$(id -u)" -eq 0 && "$lock_uid" != "0" ]]; then
    chown "$lock_uid" "$lock_file" 2>/dev/null || true
  fi
  chmod 600 "$lock_file" 2>/dev/null || true
  if ! flock -n "$UI_MAINTENANCE_LOCK_FD"; then
    exec {UI_MAINTENANCE_LOCK_FD}>&-
    unset UI_MAINTENANCE_LOCK_FD
    ui_warn "另一项系统维护正在运行，已取消%s。" "$operation"
    return 75
  fi

  UI_MAINTENANCE_LOCK_OWNED=1
  export UI_MAINTENANCE_LOCK_FD MAINTENANCE_LOCK_HELD=1
}

ui_maintenance_lock_release() {
  if [[ "${UI_MAINTENANCE_LOCK_OWNED:-0}" == "1" \
        && "${UI_MAINTENANCE_LOCK_FD:-}" =~ ^[0-9]+$ ]]; then
    flock -u "$UI_MAINTENANCE_LOCK_FD" 2>/dev/null || true
    exec {UI_MAINTENANCE_LOCK_FD}>&-
  fi
  unset UI_MAINTENANCE_LOCK_FD UI_MAINTENANCE_LOCK_OWNED MAINTENANCE_LOCK_HELD
}

# ------------------------------------------------------------------------------
# 终端宽度助手
# ------------------------------------------------------------------------------
# 终端列数：进程内缓存一次 tput 结果（子 shell 会继承父进程已填好的缓存，
# 因此同一次运行里的多次卡片渲染只 fork 一次 tput）。
_UI_COLS_CACHE=""
UI_COLS_RESULT=80
_ui_cols_calc() {
  if [[ "$_UI_COLS_CACHE" =~ ^[0-9]+$ ]]; then
    UI_COLS_RESULT="$_UI_COLS_CACHE"
    return 0
  fi
  local c
  c="$(tput cols 2>/dev/null || true)"
  if [[ ! "$c" =~ ^[0-9]+$ ]]; then
    c=80
  fi
  _UI_COLS_CACHE="$c"
  UI_COLS_RESULT="$c"
}

ui_cols() {
  _ui_cols_calc
  printf '%s' "$UI_COLS_RESULT"
}

# 共享内容宽度：按实时终端列数计算，不设桌面端最大宽度。
# UI_EDGE_GAP 可调整右侧安全区（默认 2 列，用于避免终端自动换行）。
# 极窄终端下绝不返回比当前终端更大的值。
# 结果同时写入 UI_RULE_WIDTH_RESULT：脚本内部的卡片渲染直接读它，
# 不再为每张卡片各开一个子 shell 去取一次宽度。
UI_RULE_WIDTH_RESULT=78
_ui_rule_width_get() {
  local cols gap w
  _ui_cols_calc
  cols="$UI_COLS_RESULT"
  gap="${UI_EDGE_GAP:-2}"
  [[ "$gap" =~ ^[0-9]+$ ]] || gap=2
  (( gap >= cols )) && gap=0
  w=$(( cols - gap ))
  (( w < 1 )) && w=1
  (( w > cols )) && w=$cols
  UI_RULE_WIDTH_RESULT="$w"
}

_ui_rule_width() {
  _ui_rule_width_get
  printf '%s' "$UI_RULE_WIDTH_RESULT"
}

# ------------------------------------------------------------------------------
# 分隔线：ui_hr [宽度]
#   不传宽度时按共享内容宽度铺满；显式宽度也不会超过终端内容宽度。
# ------------------------------------------------------------------------------
ui_hr() {
  local width="${1:-}"
  local i max_width
  _ui_rule_width_get
  max_width="$UI_RULE_WIDTH_RESULT"
  if [[ -z "$width" ]]; then
    width=$max_width
  fi
  if [[ ! "$width" =~ ^[0-9]+$ ]]; then width=$max_width; fi
  if (( width < 1 )); then width=1; fi
  if (( width > max_width )); then width=$max_width; fi
  printf "${UI_DIM}"
  for ((i = 0; i < width; i++)); do printf '─'; done
  printf "${UI_RESET}\n"
}

# ------------------------------------------------------------------------------
# 分节标题：ui_section "标题"
#   统一为轻量 box-drawing，与主菜单 term-menu 视觉呼应。
#     ╭─ 标题 ─────────────
# ------------------------------------------------------------------------------
ui_section() {
  local title="$1"
  local width fill i title_w
  _ui_rule_width_get
  width="$UI_RULE_WIDTH_RESULT"

  # 标题宽度按显示列精确计算（CJK/emoji 计 2 列），不再用字节差估算并 fork wc。
  _ui_dwidth_calc "$title"
  title_w="$UI_DWIDTH_RESULT"

  # "╭─ " = 3 列，标题右侧留 1 空格
  fill=$(( width - 4 - title_w ))
  if (( fill < 0 )); then fill=0; fi

  printf "\n${UI_C_LAVENDER}╭─ ${UI_C_MAUVE}${UI_BOLD}%s${UI_RESET} ${UI_C_LAVENDER}" "$title"
  for ((i = 0; i < fill; i++)); do printf '─'; done
  printf "${UI_RESET}\n"
}

# 子分节：ui_subsection "标题"  →  ├─ 标题
ui_subsection() {
  printf "${UI_C_LAVENDER}├─${UI_RESET} ${UI_C_MAUVE}${UI_BOLD}%s${UI_RESET}\n" "$1"
}

# ==============================================================================
# 卡片面板组件（v2）
# ------------------------------------------------------------------------------
# 设计：左轨（│）卡片 + 圆角首尾，替代旧的“只有顶边、右侧散开”的线性日志。
#   - ui_banner       脚本标题横幅（重规则线）
#   - ui_panel_open   卡片开头  ╭─  标题 ────
#   - ui_panel_close  卡片结尾  ╰──────────
#   - ui_panel_line   卡片正文行 │  文本
#   - ui_panel_blank  卡片空行   │
#   - ui_panel_kv     对齐键值行 │  键(18列)  值  备注
#   - ui_panel_stat   徽章状态行 │  ✓ 文本   （并计入汇总）
#   - ui_panel_raw    把命令原始输出整理进卡片（读 stdin，展开 Tab）
#   - ui_tally_reset / ui_tally_summary  结果统计与汇总条
#   - ui_wait_key     圆角居中的“按任意键”结果页脚
#
# 宽度处理：ui_dwidth 正确计算显示宽度（剥离 ANSI、CJK 计 2 列），
#   解决旧脚本 %-28s 对中文错位的根因。左轨卡片正文不封右边框，
#   因此不依赖 Nerd Font 图标的单/双宽，天然稳健。
# ==============================================================================

# ------------------------------------------------------------------------------
# ui_dwidth STR  → 打印 STR 的终端显示宽度
#   剥离 ANSI CSI 序列；CJK/全角/emoji 计 2 列，组合记号计 0 列，其余 1 列。
#   自解码 UTF-8，仅依赖 awk，无外部依赖。
# ------------------------------------------------------------------------------
# 纯 Bash 实现：printf %d 取码点 + 关联数组记忆化，避免每次调用都 fork 一个 awk。
# 旧实现每次调用约 2.4ms，「查看快照」整屏 38 行 × 5 列要 190 次 fork（0.64 秒）。
# 必须用 -gA：lib 可能被"函数内部的 source"加载（例如测试夹具），普通 declare
# 会退化成该函数的局部变量，函数返回后数组消失，随后 ${arr[$key]} 会被当成算术
# 下标并对中文字符串报"算术语法错误"，进而让调用方静默中断。
_UI_DWIDTH_CACHE_DECLARED=1
declare -gA _UI_DWIDTH_CACHE=()
UI_DWIDTH_RESULT=0
UI_STRIP_RESULT=""

# 是否为纯 ASCII 可打印串（按字节判断，故临时切到 C locale）
_ui_is_ascii() {
  local LC_ALL=C
  [[ "$1" != *[!\ -~]* ]]
}

# 剥离 ANSI CSI 序列，结果写入 UI_STRIP_RESULT（按字节处理，多字节内容原样保留）
_ui_strip_ansi() {
  local LC_ALL=C
  local s="$1" out="" head tail params

  while [[ "$s" == *$'\e'* ]]; do
    head="${s%%$'\e'*}"
    tail="${s#*$'\e'}"
    if [[ "$tail" == '['* ]]; then
      tail="${tail#\[}"
      params="${tail%%[@-~]*}"
      if [[ "$params" == "$tail" ]]; then
        tail=""
      else
        tail="${tail:${#params}+1}"
      fi
    fi
    out+="$head"
    s="$tail"
  done
  UI_STRIP_RESULT="$out$s"
}

# 计算显示宽度，结果写入 UI_DWIDTH_RESULT（不经子 shell，缓存才留得住）
_ui_dwidth_calc() {
  local key="${1:-}" cached s w=0 n i ch code

  # 兜底：若缓存数组不是"关联数组"（历史加载路径导致），重新声明为全局关联数组。
  if [[ -z "${_UI_DWIDTH_CACHE_DECLARED:-}" ]]; then
    _UI_DWIDTH_CACHE_DECLARED=1
    declare -gA _UI_DWIDTH_CACHE=()
  fi

  # 非 UTF-8 环境（LC_ALL=C/POSIX）下 ${s:i:1} 会按字节切分，中文会被算成 3 列；
  # 这里在本函数内临时强制 C.UTF-8，只影响宽度计算，不改调用方的 locale。
  if (( _UI_NEEDS_UTF8 == 1 )); then
    local LC_ALL=C.UTF-8
  fi

  # 空串直接为 0：关联数组不接受空下标。
  if [[ -z "$key" ]]; then
    UI_DWIDTH_RESULT=0
    return 0
  fi
  cached="${_UI_DWIDTH_CACHE[$key]:-}"
  if [[ -n "$cached" ]]; then
    UI_DWIDTH_RESULT="$cached"
    return 0
  fi

  if [[ "$key" == *$'\e'* ]]; then
    _ui_strip_ansi "$key"
    s="$UI_STRIP_RESULT"
  else
    s="$key"
  fi

  if _ui_is_ascii "$s"; then
    w=${#s}
  else
    n=${#s}
    for ((i = 0; i < n; i++)); do
      ch="${s:i:1}"
      printf -v code '%d' "'$ch"
      if (( code == 0 || (code >= 0x300 && code <= 0x36F) )); then
        continue
      fi
      if (( (code >= 0x1100 && code <= 0x115F) || (code >= 0x2E80 && code <= 0x303E) ||
            (code >= 0x3041 && code <= 0x33FF) || (code >= 0x3400 && code <= 0x4DBF) ||
            (code >= 0x4E00 && code <= 0x9FFF) || (code >= 0xA000 && code <= 0xA4CF) ||
            (code >= 0xAC00 && code <= 0xD7A3) || (code >= 0xF900 && code <= 0xFAFF) ||
            (code >= 0xFE30 && code <= 0xFE4F) || (code >= 0xFF00 && code <= 0xFF60) ||
            (code >= 0xFFE0 && code <= 0xFFE6) || (code >= 0x1F300 && code <= 0x1FAFF) ||
            (code >= 0x20000 && code <= 0x3FFFD) )); then
        w=$(( w + 2 ))
      else
        w=$(( w + 1 ))
      fi
    done
  fi

  _UI_DWIDTH_CACHE["$key"]="$w"
  UI_DWIDTH_RESULT="$w"
}

ui_dwidth() {
  _ui_dwidth_calc "${1:-}"
  printf '%s\n' "$UI_DWIDTH_RESULT"
}

# ------------------------------------------------------------------------------
# ui_wrap WIDTH  → 读 stdin，按 WIDTH 显示列自动换行后写 stdout
#   词感知：ASCII 单词（字母/数字/标点连写）整体不拆，避免 fzf 的字符级
#           换行把 root/home 断成 roo↳t。CJK 逐字可断。
#   ANSI CSI 序列计 0 列并随后续文本移动，颜色不丢。
#   仅用于 fzf preview 等固定宽度场景；正文卡片走左轨不需要它。
# ------------------------------------------------------------------------------
ui_wrap() {
  local width="${1:-80}"
  [[ "$width" =~ ^[0-9]+$ ]] || width=80
  (( width < 8 )) && width=8
  LC_ALL=C awk -v W="$width" '
    function cw(cp) {
      if (cp == 0) return 0
      if (cp >= 0x300 && cp <= 0x36F) return 0
      if ((cp>=0x1100&&cp<=0x115F)||(cp>=0x2E80&&cp<=0x303E)||(cp>=0x3041&&cp<=0x33FF)||\
          (cp>=0x3400&&cp<=0x4DBF)||(cp>=0x4E00&&cp<=0x9FFF)||(cp>=0xA000&&cp<=0xA4CF)||\
          (cp>=0xAC00&&cp<=0xD7A3)||(cp>=0xF900&&cp<=0xFAFF)||(cp>=0xFE30&&cp<=0xFE4F)||\
          (cp>=0xFF00&&cp<=0xFF60)||(cp>=0xFFE0&&cp<=0xFFE6)||(cp>=0x1F300&&cp<=0x1FAFF)||\
          (cp>=0x20000&&cp<=0x3FFFD)) return 2
      return 1
    }
    function codepoint(s,   L,b0) {
      L=length(s); b0=ord[substr(s,1,1)]
      if (L==1) return b0
      if (L==2) return (b0-0xC0)*64 + (ord[substr(s,2,1)]-128)
      if (L==3) return (b0-0xE0)*4096 + (ord[substr(s,2,1)]-128)*64 + (ord[substr(s,3,1)]-128)
      if (L==4) return (b0-0xF0)*262144 + (ord[substr(s,2,1)]-128)*4096 + (ord[substr(s,3,1)]-128)*64 + (ord[substr(s,4,1)]-128)
      return b0
    }
    function emit() { print line; line=""; linew=0 }
    function flush_word() {
      if (word=="") return
      if (linew>0 && linew+wordw>W) emit()
      line=line word; linew+=wordw; word=""; wordw=0
    }
    BEGIN { for (i=0;i<256;i++) ord[sprintf("%c",i)]=i }
    {
      n=length($0); i=1; word=""; wordw=0; line=""; linew=0
      while (i<=n) {
        c=substr($0,i,1); b=ord[c]
        if (b==27) {                       # ANSI CSI，0 宽，随词移动
          seq=c; i++
          if (i<=n) { seq=seq substr($0,i,1); i++ }
          while (i<=n) { cc=substr($0,i,1); seq=seq cc; i++; if (ord[cc]>=0x40 && ord[cc]<=0x7E) break }
          word=word seq; continue
        }
        if (b==32) {                       # 空格：断词机会
          flush_word()
          if (linew>0) { if (linew+1>W) emit(); else { line=line " "; linew++ } }
          i++; continue
        }
        if (b<0x80)        clen=1
        else if (b<0xE0)   clen=2
        else if (b<0xF0)   clen=3
        else               clen=4
        ch=substr($0,i,clen); i+=clen
        w=cw(codepoint(ch))
        if (w==2) {                        # CJK/全角：逐字可断
          flush_word()
          if (linew>0 && linew+2>W) emit()
          line=line ch; linew+=2
        } else {
          word=word ch; wordw+=w
        }
      }
      flush_word()
      if (linew>0 || $0=="") emit()
    }
  '
}

# ui_pad STR WIDTH  → STR 右侧补空格至 WIDTH 显示列（不截断），用于列对齐
# ui_pad STR WIDTH  → STR 右侧补空格至 WIDTH 显示列（不截断），用于列对齐
ui_pad() {
  local s="${1:-}" width="${2:-0}" pad

  _ui_dwidth_calc "$s"
  pad=$(( width - UI_DWIDTH_RESULT ))
  (( pad < 0 )) && pad=0
  printf '%s%*s' "$s" "$pad" ''
}

# ------------------------------------------------------------------------------
# ui_banner "标题" ["副标题"]  → 脚本顶部标题横幅
# ------------------------------------------------------------------------------
ui_banner() {
  local title="$1" sub="${2:-}" w i
  _ui_rule_width_get
  w="$UI_RULE_WIDTH_RESULT"
  printf '\n'
  printf "${UI_C_MAUVE}"; for ((i = 0; i < w; i++)); do printf '━'; done; printf "${UI_RESET}\n"
  if [[ -n "$sub" ]]; then
    printf "  ${UI_C_MAUVE}${UI_BOLD}%s${UI_RESET}   ${UI_C_SUBTLE}%s${UI_RESET}\n" "$title" "$sub"
  else
    printf "  ${UI_C_MAUVE}${UI_BOLD}%s${UI_RESET}\n" "$title"
  fi
  printf "${UI_C_MAUVE}"; for ((i = 0; i < w; i++)); do printf '━'; done; printf "${UI_RESET}\n"
}

# ui_panel_open "标题" ["图标"]  → 卡片开头
ui_panel_open() {
  local title="$1" icon="${2:-}" w tw head used fill i
  _ui_rule_width_get
  w="$UI_RULE_WIDTH_RESULT"
  if [[ -n "$icon" ]]; then head="$icon  $title"; else head="$title"; fi
  tw="$(ui_dwidth "$head")"
  printf "\n${UI_C_LAVENDER}╭─ ${UI_C_MAUVE}${UI_BOLD}%s${UI_RESET} ${UI_C_LAVENDER}" "$head"
  used=$(( 4 + tw ))
  fill=$(( w - used ))
  (( fill < 0 )) && fill=0
  for ((i = 0; i < fill; i++)); do printf '─'; done
  printf "${UI_RESET}\n"
}

# ui_panel_close  → 卡片结尾
ui_panel_close() {
  local w i
  _ui_rule_width_get
  w="$UI_RULE_WIDTH_RESULT"
  printf "${UI_C_LAVENDER}╰"
  for ((i = 0; i < w - 1; i++)); do printf '─'; done
  printf "${UI_RESET}\n"
}

# ui_panel_line "文本..."  → 卡片正文行（左轨 + 内容，内容可自带颜色）
ui_panel_line() {
  printf "${UI_C_LAVENDER}│${UI_RESET}  %s\n" "$*"
}

# ui_panel_blank  → 卡片空行
ui_panel_blank() {
  printf "${UI_C_LAVENDER}│${UI_RESET}\n"
}

# ui_panel_kv "键" "值" ["备注"]  → 键列对齐 18 显示列
ui_panel_kv() {
  local key="$1" val="${2:-}" note="${3:-}" padded
  padded="$(ui_pad "$key" 18)"
  if [[ -n "$note" ]]; then
    printf "${UI_C_LAVENDER}│${UI_RESET}  ${UI_C_SKY}%s${UI_RESET}  %s  ${UI_DIM}%s${UI_RESET}\n" "$padded" "$val" "$note"
  else
    printf "${UI_C_LAVENDER}│${UI_RESET}  ${UI_C_SKY}%s${UI_RESET}  %s\n" "$padded" "$val"
  fi
}

# ui_panel_stat STATUS "文本"  → 徽章状态行，STATUS ∈ ok|warn|miss|err|info
#   同时累计 UI_N_OK / UI_N_WARN / UI_N_MISS / UI_N_ERR，供 ui_tally_summary 使用。
#   err 是"查询失败/无法检查"，必须与"缺失（确实没有）"分开统计：旧实现把
#   err 计进 UI_N_MISS，汇总行会把查询失败显示成"缺失"，违背"失败≠缺失"的约定。
ui_panel_stat() {
  local status="$1" text="${2:-}" icon color
  case "$status" in
    ok)   icon="$UI_ICON_OK";   color="$UI_C_GREEN";    UI_N_OK=$(( ${UI_N_OK:-0} + 1 )) ;;
    warn) icon="$UI_ICON_WARN"; color="$UI_C_YELLOW";   UI_N_WARN=$(( ${UI_N_WARN:-0} + 1 )) ;;
    miss) icon="$UI_ICON_MISS"; color="$UI_C_YELLOW";   UI_N_MISS=$(( ${UI_N_MISS:-0} + 1 )) ;;
    err)  icon="$UI_ICON_ERR";  color="$UI_C_RED";      UI_N_ERR=$(( ${UI_N_ERR:-0} + 1 )) ;;
    *)    icon="$UI_ICON_INFO"; color="$UI_C_SAPPHIRE" ;;
  esac
  printf "${UI_C_LAVENDER}│${UI_RESET}  ${color}%s${UI_RESET} %s\n" "$icon" "$text"
}

# ui_panel_raw  → 读 stdin，把命令原始输出整理进卡片（展开 Tab，左轨缩进）
ui_panel_raw() {
  local line
  { if command -v expand >/dev/null 2>&1; then expand; else cat; fi; } |
    while IFS= read -r line || [[ -n "$line" ]]; do
      printf "${UI_C_LAVENDER}│${UI_RESET}  %s\n" "$line"
    done
}

# 结果统计
ui_tally_reset() { UI_N_OK=0; UI_N_WARN=0; UI_N_MISS=0; UI_N_ERR=0; }
ui_tally_summary() {
  printf "\n  ${UI_C_GREEN}${UI_ICON_OK}${UI_RESET} %s 正常     ${UI_C_YELLOW}${UI_ICON_WARN}${UI_RESET} %s 注意     ${UI_C_YELLOW}${UI_ICON_MISS}${UI_RESET} %s 缺失     ${UI_C_RED}${UI_ICON_ERR}${UI_RESET} %s 查询失败\n" \
    "${UI_N_OK:-0}" "${UI_N_WARN:-0}" "${UI_N_MISS:-0}" "${UI_N_ERR:-0}"
}

# 检查脚本自动化状态：普通交互保持 0；--strict 下有警告或缺失即返回 1。
ui_tally_status() {
  local strict="${1:-0}"
  if [[ "$strict" == "1" ]] && (( ${UI_N_WARN:-0} > 0 || ${UI_N_MISS:-0} > 0 || ${UI_N_ERR:-0} > 0 )); then
    return 1
  fi
  return 0
}

# ------------------------------------------------------------------------------
# 确认提示
#   ui_confirm "提示文字" [默认]
#     默认为 y（回车即确认），传 "n" 则默认拒绝。
#     返回 0=确认，1=拒绝。
# ------------------------------------------------------------------------------
ui_confirm() {
  local prompt="$1"
  local default="${2:-y}"
  local hint answer
  if [[ "$default" == "y" ]]; then hint="[Y/n]"; else hint="[y/N]"; fi
  printf "${UI_YELLOW}%s${UI_RESET} %s " "$prompt" "$hint"
  # EOF / 读错误必须视为"未确认"：旧实现把它当成回车，于是 </dev/null 或管道
  # 结束时会用默认值回答，默认 y 的高风险提示就被自动同意了。
  if ! read -r answer; then
    printf '\n' >&2
    return 1
  fi
  answer="${answer:-$default}"
  [[ "$answer" =~ ^[yY]$ ]]
}

# ------------------------------------------------------------------------------
# 关键词确认：ui_confirm_word "提示文字" "关键词"
#   必须完整输入关键词才返回 0，用于高风险操作（如 delete、clean all）。
# ------------------------------------------------------------------------------
ui_confirm_word() {
  local prompt="$1"
  local word="$2"
  local answer
  printf "${UI_YELLOW}%s${UI_RESET} 输入 ${UI_RED}%s${UI_RESET} 确认: " "$prompt" "$word"
  read -r answer || true
  [[ "$answer" == "$word" ]]
}

# ------------------------------------------------------------------------------
# 圆角结果页脚：ui_wait_key [提示文字]
#   仅在 stdin 是 TTY 时展示并等待；纯 CJK/ASCII 文案可保持可靠居中。
# ------------------------------------------------------------------------------
ui_wait_key() {
  local hint="${1:-按任意键继续}" w hint_w left right i

  [[ -t 0 ]] || return 0

  _ui_rule_width_get
  w="$UI_RULE_WIDTH_RESULT"
  hint_w="$(ui_dwidth "$hint")"
  left=$(( (w - 2 - hint_w) / 2 ))
  (( left < 0 )) && left=0
  right=$(( w - 2 - left - hint_w ))
  (( right < 0 )) && right=0

  printf "\n${UI_C_LAVENDER}╭"
  for ((i = 0; i < w - 2; i++)); do printf '─'; done
  printf "╮${UI_RESET}\n"

  printf "${UI_C_LAVENDER}│${UI_RESET}"
  for ((i = 0; i < left; i++)); do printf ' '; done
  printf "${UI_C_PINK}${UI_BOLD}%s${UI_RESET}" "$hint"
  for ((i = 0; i < right; i++)); do printf ' '; done
  printf "${UI_C_LAVENDER}│${UI_RESET}\n"

  printf "${UI_C_LAVENDER}╰"
  for ((i = 0; i < w - 2; i++)); do printf '─'; done
  printf "╯${UI_RESET}\n"

  if [[ -t 1 ]]; then
    tput civis 2>/dev/null || true
  fi
  IFS= read -r -s -n 1 || true
  if [[ -t 1 ]]; then
    tput cnorm 2>/dev/null || true
  fi
}

# ------------------------------------------------------------------------------
# fzf 统一配色（Catppuccin Mocha，蓝→紫渐变边框），供 --color= 使用。
#   各边框用不同色阶营造“蓝紫渐变”观感：
#   sapphire → blue → lavender → mauve → pink，从输入区到页脚由冷到暖。
#   选中行用 --highlight-line + bg+ 表现玻璃拟态高亮条。
# ------------------------------------------------------------------------------
ui_fzf_colors() {
  printf '%s' \
'fg:#cdd6f4,bg:-1,gutter:-1,'\
'hl:#cba6f7,fg+:#f5e0dc,bg+:#313244,hl+:#f5c2e7,'\
'prompt:#89b4fa,pointer:#f5c2e7,marker:#a6e3a1,spinner:#cba6f7,info:#6c7086,'\
'border:#b4befe,label:#cba6f7,'\
'preview-fg:#cdd6f4,preview-border:#cba6f7,preview-label:#cba6f7,'\
'list-border:#89b4fa,list-label:#89b4fa,'\
'input-border:#74c7ec,input-label:#74c7ec,'\
'header:#a6adc8,header-border:#89dceb,header-label:#89dceb,'\
'footer:#a6adc8,footer-border:#f5c2e7,footer-label:#f5c2e7'
}

# ------------------------------------------------------------------------------
# fzf 统一基础参数：ui_fzf_base "边框标题"
#   输出一组标准参数（每行一个），调用方用 mapfile 读入数组后展开：
#     mapfile -t _opts < <(ui_fzf_base " 标题 ")
#     fzf "${_opts[@]}" --preview=... < input
#   统一：rounded 边框 + 标题、reverse 布局、▶/✓ 指针、隐藏 info、
#         无分隔线、Catppuccin 配色、统一 header。
# ------------------------------------------------------------------------------
ui_fzf_base() {
  local label="${1:-}"
  printf '%s\n' \
    "--layout=reverse" \
    "--border=rounded" \
    "--border-label=${label}" \
    "--prompt=选择 > " \
    "--pointer=▶" \
    "--marker=✓" \
    "--info=hidden" \
    "--cycle" \
    "--no-separator" \
    "--header=Enter 执行 · ↑↓ 循环移动 · Esc 返回/退出" \
    "--color=$(ui_fzf_colors)"
}

# preview 内的键值行：ui_kv "键" "值"
#   在 fzf preview（非 TTY）中也要有色，调用方需以 UI_FORCE_COLOR=1 进入。
ui_kv() {
  printf "${UI_CYAN}%s${UI_RESET}  %s\n" "$1" "$2"
}

# ------------------------------------------------------------------------------
# 实时状态栏：ui_status_line
#   输出单行 CPU / RAM / Disk / Net 摘要，供 fzf --footer 使用。
#   纯文本 + Nerd Font 图标，不含 ANSI（footer 由 fzf 统一着色）。
#   数据来源均为只读、快速：/proc/loadavg、/proc/meminfo、df、ip route。
# ------------------------------------------------------------------------------
ui_status_line() {
  local load mem_line mem_used_gib mem_total_gib
  local disk iface

  # CPU：1 分钟平均负载
  read -r load _ < /proc/loadavg 2>/dev/null || load="?"

  # RAM：已用 / 总量（GiB，一位小数）。纯 Bash 定点换算，不再为两个数字 fork 两次 awk。
  if [[ -r /proc/meminfo ]]; then
    local kb_total=0 kb_avail=0 k v
    while read -r k v _; do
      case "$k" in
        MemTotal:) kb_total=$v ;;
        MemAvailable:) kb_avail=$v ;;
      esac
    done < /proc/meminfo
    if (( kb_total > 0 )); then
      local total_tenths used_tenths
      total_tenths=$(( (kb_total * 10 + 524288) / 1048576 ))
      used_tenths=$(( ((kb_total - kb_avail) * 10 + 524288) / 1048576 ))
      (( used_tenths < 0 )) && used_tenths=0
      mem_line="$(( used_tenths / 10 )).$(( used_tenths % 10 ))/$(( total_tenths / 10 )).$(( total_tenths % 10 ))G"
    else
      mem_line="?"
    fi
  else
    mem_line="?"
  fi

  # Disk：根分区使用率（Bash 解析 df 输出，省掉 tail / tr 两个进程）
  disk=""
  while IFS= read -r line; do
    [[ "$line" == *% ]] && disk="$line"
  done < <(df --output=pcent / 2>/dev/null)
  disk="${disk//[ %]/}"
  [[ -n "$disk" ]] && disk="${disk}%" || disk="?"

  # Net：默认路由网卡（Bash 解析 ip 输出，省掉 awk）
  iface=""
  local route_line route_parts i
  route_line="$(ip route show default 2>/dev/null)" || route_line=""
  route_line="${route_line%%$'\n'*}"
  IFS=' ' read -r -a route_parts <<< "$route_line"
  for ((i = 0; i < ${#route_parts[@]}; i++)); do
    if [[ "${route_parts[i]}" == "dev" && $(( i + 1 )) -lt ${#route_parts[@]} ]]; then
      iface="${route_parts[i + 1]}"
      break
    fi
  done
  [[ -n "$iface" ]] || iface="离线"

  # 时钟：bash 内建 printf 直接格式化时间，省掉 date 进程。
  local clock
  printf -v clock '%(%H:%M)T' -1 2>/dev/null || clock="--:--"

  # 图标：nf-oct-cpu / nf-fa-memory / nf-fa-hdd_o / nf-md-lan
  printf ' %s  %s   %s   %s   %s' "$load" "$mem_line" "$disk" "$iface" "$clock"
}
