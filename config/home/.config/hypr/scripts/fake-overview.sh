#!/usr/bin/env bash
# fake-overview —— 无插件的 Hyprland 伪概览
#
# 原理：主力布局是 scrolling（窗口横向滚动，一次只见几列）。触发时临时把布局
# 切成 dwindle，当前工作区的所有窗口会一次性平铺展开＝概览效果；监听到用户
# “点选了另一个窗口”（聚焦切到不同地址）后，自动切回 scrolling。
#
# 再次按键（概览态未消时）＝手动取消，立即切回。
# 纯 hyprctl + socat，零插件、零常驻守护。
#
# 关键点：切到 dwindle 时窗口重排会立即发出 activewindowv2 事件（地址仍是触发
# 前那个窗口），必须忽略这个“自触发”事件——只有聚焦切到不同窗口才还原。
#
# 依赖：hyprctl、socat。改编自 SHORiN-KiWATA/shorin-dms-hyprniri。

set -u

SIG="${HYPRLAND_INSTANCE_SIGNATURE:-default}"
STATE_FILE="/tmp/hypr_fake_overview_state_${SIG}"
SOCKET="${XDG_RUNTIME_DIR}/hypr/${SIG}/.socket2.sock"

# Lua 配置（non-legacy parser）下运行时改布局必须走 hyprctl eval + hl.config，
# 不能用 hyprctl keyword（会报 "keyword can't work with non-legacy parsers"）。
set_layout() {
	hyprctl eval "hl.config({ general = { layout = \"$1\" } })" >/dev/null
}

# 概览期间临时关闭 follow_mouse：否则鼠标划过窗口就切焦点、触发 activewindowv2
# 事件，导致概览一移动鼠标就立刻收起。设 0 后鼠标划过不改焦点，只有真正点击
# 窗口或键盘切焦点才收起。退出时恢复原值。
set_follow_mouse() {
	hyprctl eval "hl.config({ input = { follow_mouse = $1 } })" >/dev/null
}

# ==========================================
# 1. 概览态未消时再次触发 = 手动取消（Toggle）
# ==========================================
if [[ -f "$STATE_FILE" ]]; then
	# shellcheck disable=SC1090
	source "$STATE_FILE"
	set_layout "${SAVED_LAYOUT:-scrolling}"
	set_follow_mouse "${SAVED_FOLLOW_MOUSE:-1}"
	rm -f "$STATE_FILE"
	# 结束上一次触发遗留的监听进程（连同其 socat 子进程）
	if [[ -n "${OLD_SCRIPT_PID:-}" ]]; then
		pkill -P "$OLD_SCRIPT_PID" 2>/dev/null || true
		kill "$OLD_SCRIPT_PID" 2>/dev/null || true
	fi
	exit 0
fi

# ==========================================
# 2. 启动 Fake Overview
# ==========================================
current_layout=$(hyprctl getoption general:layout | awk '/^str:/ {print $2}')

# 已经是 dwindle（本就平铺展开）则无需概览
if [[ "$current_layout" == "dwindle" ]]; then
	exit 0
fi

# 记录触发时的活动窗口地址（去掉 0x 前缀，与事件里的裸 hex 对齐）
orig_addr=$(hyprctl activewindow -j 2>/dev/null | grep -o '"address": "[^"]*"' | head -1 | sed 's/.*"0x\?\([0-9a-fA-F]*\)".*/\1/')

# 记录触发前的 follow_mouse，退出时恢复
orig_follow_mouse=$(hyprctl getoption input:follow_mouse | awk '/^int:/ {print $2}')
orig_follow_mouse=${orig_follow_mouse:-1}

# socat 缺失时降级：只展开、不自动还原，提示用户再按一次即可
if ! command -v socat >/dev/null 2>&1; then
	notify-send -a "Fake Overview" "缺少 socat" "已展开概览，按 Super+D 手动收起" 2>/dev/null || true
	{
		echo "SAVED_LAYOUT=$current_layout"
		echo "SAVED_FOLLOW_MOUSE=$orig_follow_mouse"
		echo "OLD_SCRIPT_PID=$$"
	} >"$STATE_FILE"
	set_follow_mouse 0
	set_layout dwindle
	exit 0
fi

{
	echo "SAVED_LAYOUT=$current_layout"
	echo "SAVED_FOLLOW_MOUSE=$orig_follow_mouse"
	echo "OLD_SCRIPT_PID=$$"
} >"$STATE_FILE"

# 关闭 follow_mouse（鼠标划过不切焦点），再切 dwindle 平铺展开
set_follow_mouse 0
set_layout dwindle

# ==========================================
# 3. 监听事件：用户点选“不同”窗口 / 切显示器后自动还原
# ==========================================
restore() {
	if [[ -f "$STATE_FILE" ]]; then
		set_follow_mouse "$orig_follow_mouse"
		set_layout "$current_layout"
		rm -f "$STATE_FILE"
	fi
}

# socat 用进程替换跑：while-read 能像管道一样正常读到事件（coproc 的 fd 读取
# 在此场景不稳），同时用 $! 拿到 socat PID，配合 EXIT trap 显式 kill。管道
# while-read 在 break 后不会立即让上游 socat 收到 SIGPIPE（要等下次写入），
# 会残留进程；显式 kill 确保每次概览结束都不泄漏 socat。
exec {sock_fd}< <(socat -U - UNIX-CONNECT:"$SOCKET" 2>/dev/null)
socat_pid=$!

cleanup() {
	kill "$socat_pid" 2>/dev/null || true
	exec {sock_fd}<&- 2>/dev/null || true
	# 兜底：脚本异常退出（崩溃/被杀）且 restore 未跑时，state 文件仍在——
	# 此时恢复 follow_mouse 和布局，避免把系统留在 follow_mouse=0 / dwindle 坏状态。
	if [[ -f "$STATE_FILE" ]]; then
		set_follow_mouse "$orig_follow_mouse"
		set_layout "$current_layout"
		rm -f "$STATE_FILE"
	fi
}
trap cleanup EXIT

while read -r line <&"$sock_fd"; do
	case "$line" in
	activewindowv2\>\>*)
		# 事件格式：activewindowv2>>ADDR（裸 hex，无 0x）；无窗口时为空/逗号
		ev_addr="${line#activewindowv2>>}"
		# 只有聚焦切到“不同的、非空”窗口才认为是用户点选 → 还原
		if [[ -n "$ev_addr" && "$ev_addr" != *","* && "$ev_addr" != "$orig_addr" ]]; then
			restore
			break
		fi
		;;
	focusedmon\>\>*)
		# 切换显示器一定是用户主动操作 → 还原
		restore
		break
		;;
	esac
done
