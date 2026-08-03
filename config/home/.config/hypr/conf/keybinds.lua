---------------------
---- MY PROGRAMS ----
---------------------

-- Set programs that you use（仅本文件的键位引用，作为局部变量就近定义）
local terminal = "kitty"
local fileManager = "nemo"
local menu = "fuzzel"

---------------------
---- KEYBINDINGS ----
---------------------

local mainMod = "SUPER" -- Sets "Windows" key as main modifier

-- 说明：尽量对齐 niri 的肌肉记忆。
--   Alt        = 焦点移动 / 工作区切换 / 关窗 / 终端（Vim 风格，同 niri）
--   Super(Mod) = DMS 工具 / 缩放 / 显示器 / 系统
-- niri 滚动布局独有的动作（列宽预设、consume/expel、标签化、overview）在 Hyprland
-- 无对应概念，按要求略过。DMS 通过 systemd 用户服务运行，所有 `dms ipc call` 均可用。

-- ===== DMS 工具（Super 键，同 niri） =====
hl.bind(mainMod .. " + Comma", hl.dsp.exec_cmd("dms ipc call settings focusOrToggle")) -- 系统设置
hl.bind(mainMod .. " + M", hl.dsp.exec_cmd("dms ipc call processlist focusOrToggle")) -- 任务管理器
hl.bind(mainMod .. " + N", hl.dsp.exec_cmd("dms ipc call notifications toggle")) -- 通知中心
hl.bind(mainMod .. " + SHIFT + N", hl.dsp.exec_cmd("dms ipc call notepad toggle")) -- 记事本
hl.bind(mainMod .. " + SHIFT + W", hl.dsp.exec_cmd("dms ipc call window-rules toggle")) -- 创建窗口规则
hl.bind(mainMod .. " + V", hl.dsp.exec_cmd("dms ipc call clipboard toggle")) -- 剪贴板
hl.bind(mainMod .. " + Y", hl.dsp.exec_cmd("dms ipc call dankdash wallpaper")) -- 更换壁纸
hl.bind(mainMod .. " + X", hl.dsp.exec_cmd("dms ipc call powermenu toggle")) -- 电源菜单
hl.bind(mainMod .. " + ALT + L", hl.dsp.exec_cmd("dms ipc call lock lock")) -- 锁屏
-- 应用启动器 / 工作区重命名（Ctrl 组合，同 niri；注意会占用终端里的 Ctrl+M=Enter）
-- DMS 在 Hyprland 会话下完全可用，spotlight/fuzzel 两个启动器并存。
hl.bind("CTRL + M", hl.dsp.exec_cmd(menu)) -- fuzzel 应用启动器
hl.bind(mainMod .. " + O", hl.dsp.exec_cmd("dms ipc call spotlight toggle")) -- DMS spotlight 启动器
hl.bind("CTRL + SHIFT + R", hl.dsp.exec_cmd("dms ipc call workspace-rename open")) -- 重命名工作区
hl.bind("CTRL + ALT + Delete", hl.dsp.exec_cmd("dms ipc call processlist focusOrToggle")) -- 任务管理器

-- ===== 应用启动 =====
hl.bind("ALT + Return", hl.dsp.exec_cmd(terminal .. " -e fish")) -- 终端（同 niri Alt+Enter）
hl.bind(mainMod .. " + E", hl.dsp.exec_cmd(fileManager)) -- 文件管理器
hl.bind("ALT + Slash", hl.dsp.exec_cmd(terminal .. " --single-instance --class quickterminal")) -- 浮动终端
hl.bind("ALT + B", hl.dsp.exec_cmd("$HOME/.local/bin/b23")) -- B 站链接播放
-- 屏幕放大镜（Hyprland 原生 cursor:zoom_factor，循环 1x→2x→3x→关）。
-- 不用 wooz：wooz 的 wlr-screencopy 覆盖层在 Hyprland 上缺 damage 追踪，鼠标一动
-- 就把自己反复截进去，产生撕裂/拖影/橡皮擦残影；原生缩放在 GPU 合成阶段完成，干净。
-- niri 侧保留 wooz（在 niri 上正常）。
hl.bind("ALT + A", hl.dsp.exec_cmd("$HOME/scripts/desktop/hypr-magnifier")) -- 屏幕放大镜
-- 录屏菜单（shorin-screenrec-menu，同 niri Alt+F5）：全屏/区域/GIF 三模式，toggle 开始/停止。
hl.bind("ALT + F5", hl.dsp.exec_cmd("$HOME/.local/bin/shorin-screenrec-menu toggle")) -- 录屏菜单
hl.bind(
	mainMod .. " + SHIFT + C",
	hl.dsp.exec_cmd(
		terminal
			.. " --class=term-menu --override initial_window_width=1600 --override initial_window_height=1000 -e $HOME/scripts/maintenance/term-menu"
	)
) -- 维护菜单
-- Super+R：循环切换列宽预设（1/3, 1/2, 2/3, 满宽），同 niri Mod+R switch-preset-column-width。
-- 滚动布局 colresize +conf 按 scrolling.explicit_column_widths 循环。启动器：Ctrl+M（fuzzel）/ Super+O（DMS spotlight）。
hl.bind(mainMod .. " + R", hl.dsp.layout("colresize +conf"))

-- ===== 焦点移动（Alt + Vim/方向键，同 niri） =====
-- 滚动布局：H/L 用 layout("focus l/r") = 列焦点 + 滚入视野（同 niri focus-column-left/right，
-- 带 wrap_focus）；J/K 用通用 focus u/d 在同列多窗口间移动（同 niri focus-window-up/down）。
hl.bind("ALT + H", hl.dsp.layout("focus l"))
hl.bind("ALT + Left", hl.dsp.layout("focus l"))
hl.bind("ALT + J", hl.dsp.focus({ direction = "d" }))
hl.bind("ALT + Down", hl.dsp.focus({ direction = "d" }))
hl.bind("ALT + K", hl.dsp.focus({ direction = "u" }))
hl.bind("ALT + Up", hl.dsp.focus({ direction = "u" }))
hl.bind("ALT + L", hl.dsp.layout("focus r"))
hl.bind("ALT + Right", hl.dsp.layout("focus r"))

-- ===== 移动窗口 / 列（Alt+Shift + Vim/方向键，同 niri） =====
-- 滚动布局：H/L 用 swapcol l/r = 整列左右移动（同 niri move-column-left/right）；
-- J/K 用通用 window.move u/d 在同列内上下移动窗口（同 niri move-window-up/down）。
hl.bind("ALT + SHIFT + H", hl.dsp.layout("swapcol l"))
hl.bind("ALT + SHIFT + Left", hl.dsp.layout("swapcol l"))
hl.bind("ALT + SHIFT + J", hl.dsp.window.move({ direction = "d" }))
hl.bind("ALT + SHIFT + Down", hl.dsp.window.move({ direction = "d" }))
hl.bind("ALT + SHIFT + K", hl.dsp.window.move({ direction = "u" }))
hl.bind("ALT + SHIFT + Up", hl.dsp.window.move({ direction = "u" }))
hl.bind("ALT + SHIFT + L", hl.dsp.layout("swapcol r"))
hl.bind("ALT + SHIFT + Right", hl.dsp.layout("swapcol r"))

-- ===== 窗口切换（Alt+Tab，同 niri） =====
hl.bind("ALT + Tab", hl.dsp.window.cycle_next({ next = true }))
hl.bind("ALT + SHIFT + Tab", hl.dsp.window.cycle_next({ next = false }))

-- ===== 工作区切换（Alt+1~9，同 niri） =====
-- Move active window to workspace with Alt+Shift+[1-9]
for i = 1, 9 do
	hl.bind("ALT + " .. i, hl.dsp.focus({ workspace = i }))
	hl.bind("ALT + SHIFT + " .. i, hl.dsp.window.move({ workspace = i }))
end
-- 工作区上/下导航（Super+I/U 与 PgUp/PgDn，映射到线性上一/下一工作区）
hl.bind(mainMod .. " + I", hl.dsp.focus({ workspace = "e-1" }))
hl.bind(mainMod .. " + Page_Up", hl.dsp.focus({ workspace = "e-1" }))
hl.bind(mainMod .. " + U", hl.dsp.focus({ workspace = "e+1" }))
hl.bind(mainMod .. " + Page_Down", hl.dsp.focus({ workspace = "e+1" }))
-- 将当前窗口移到上/下相邻工作区并跟随（同 niri Super+Ctrl+I/U 与 Up/Down 的
-- move-column-to-workspace-up/down；方向与上面导航一致：I/上=上一个，U/下=下一个）。
-- 注意 Super+Ctrl+H/J/K/L 与 Left/Right 已给显示器焦点，这里只用空闲的 I/U/Up/Down。
hl.bind(mainMod .. " + CTRL + I", hl.dsp.window.move({ workspace = "e-1" }))
hl.bind(mainMod .. " + CTRL + Up", hl.dsp.window.move({ workspace = "e-1" }))
hl.bind(mainMod .. " + CTRL + U", hl.dsp.window.move({ workspace = "e+1" }))
hl.bind(mainMod .. " + CTRL + Down", hl.dsp.window.move({ workspace = "e+1" }))

-- ===== 窗口操作 =====
hl.bind("ALT + Q", hl.dsp.window.close(), { repeating = false }) -- 关闭窗口（同 niri Alt+Q）
-- 强制结束当前聚焦窗口（SIGKILL），对齐 niri Alt+F4 / Alt+Shift+F4。
-- Alt+F4 单杀窗口进程；Alt+Shift+F4 连根拔起整个进程树（会自动重启窗口的程序）。
hl.bind("ALT + F4", hl.dsp.exec_cmd("$HOME/.config/hypr/scripts/hypr-force-kill-window"), { repeating = false })
hl.bind(
	"ALT + SHIFT + F4",
	hl.dsp.exec_cmd("$HOME/.config/hypr/scripts/hypr-force-kill-window -f"),
	{ repeating = false }
)
hl.bind("ALT + F", hl.dsp.window.fullscreen({ mode = "maximized", action = "toggle" })) -- 最大化（保留 gap/栏，同 niri maximize）
hl.bind(mainMod .. " + SHIFT + F", hl.dsp.window.fullscreen({ mode = "fullscreen", action = "toggle" })) -- 真全屏
hl.bind(mainMod .. " + SHIFT + T", hl.dsp.window.float({ action = "toggle" })) -- 切换浮动（同 niri）
hl.bind(mainMod .. " + C", hl.dsp.window.center()) -- 居中窗口（浮动时生效）

-- ===== 滚动布局列操作（对齐 niri 的收放/弹出/居中，scrolling 布局原生） =====
-- Alt+[ / Alt+]：收纳或弹出窗口（同 niri consume-or-expel-window-left/right）。
-- 单窗口时把相邻列的窗口收入本列；本列多窗口时把当前窗口弹到相邻列。
hl.bind("ALT + BracketLeft", hl.dsp.layout("consume_or_expel prev"))
hl.bind("ALT + BracketRight", hl.dsp.layout("consume_or_expel next"))
-- Super+.：把当前窗口弹成独立列（同 niri Super+. expel-window-from-column）。
hl.bind(mainMod .. " + Period", hl.dsp.layout("promote"))
-- Super+Ctrl+C：把当前列滚动居中到视野（同 niri Super+C center-column 的居中意图；
-- Super+C 已给浮动窗口居中，这里用 Super+Ctrl+C 做平铺列居中，避免冲突）。
hl.bind(mainMod .. " + CTRL + C", hl.dsp.layout("fit_into_view"))

-- 特殊工作区（scratchpad，Hyprland 原生便利功能）
hl.bind(mainMod .. " + S", hl.dsp.workspace.toggle_special("magic"))
hl.bind(mainMod .. " + SHIFT + S", hl.dsp.window.move({ workspace = "special:magic" }))

-- ===== 缩放窗口（Super +/-，同 niri 列宽调整的键位习惯） =====
-- Super+-/=：按相对比例调整当前列宽（同 niri set-column-width -10%/+10%）。
-- 滚动布局用 colresize 相对值；Super+Shift+-/= 仍用窗口垂直缩放，用于同列多窗口的高度分配。
hl.bind(mainMod .. " + Minus", hl.dsp.layout("colresize -0.1"))
hl.bind(mainMod .. " + Equal", hl.dsp.layout("colresize +0.1"))
hl.bind(mainMod .. " + SHIFT + Minus", hl.dsp.window.resize({ x = 0, y = -80, relative = true }))
hl.bind(mainMod .. " + SHIFT + Equal", hl.dsp.window.resize({ x = 0, y = 80, relative = true }))

-- ===== 显示器焦点 / 移动（Super+Ctrl 与 Super+Shift+Ctrl，同 niri） =====
hl.bind(mainMod .. " + CTRL + H", hl.dsp.focus({ monitor = "l" }))
hl.bind(mainMod .. " + CTRL + Left", hl.dsp.focus({ monitor = "l" }))
hl.bind(mainMod .. " + CTRL + J", hl.dsp.focus({ monitor = "d" }))
hl.bind(mainMod .. " + CTRL + K", hl.dsp.focus({ monitor = "u" }))
hl.bind(mainMod .. " + CTRL + L", hl.dsp.focus({ monitor = "r" }))
hl.bind(mainMod .. " + CTRL + Right", hl.dsp.focus({ monitor = "r" }))
hl.bind(mainMod .. " + SHIFT + CTRL + H", hl.dsp.window.move({ monitor = "l" }))
hl.bind(mainMod .. " + SHIFT + CTRL + Left", hl.dsp.window.move({ monitor = "l" }))
hl.bind(mainMod .. " + SHIFT + CTRL + J", hl.dsp.window.move({ monitor = "d" }))
hl.bind(mainMod .. " + SHIFT + CTRL + K", hl.dsp.window.move({ monitor = "u" }))
hl.bind(mainMod .. " + SHIFT + CTRL + L", hl.dsp.window.move({ monitor = "r" }))
hl.bind(mainMod .. " + SHIFT + CTRL + Right", hl.dsp.window.move({ monitor = "r" }))

-- ===== 系统 =====
hl.bind(mainMod .. " + SHIFT + E", hl.dsp.exit()) -- 退出 Hyprland（同 niri Mod+Shift+E）
-- 快捷键速查（kitty + fzf 浮动小窗，同 niri Mod+Slash）
hl.bind(mainMod .. " + Slash", hl.dsp.exec_cmd("$HOME/scripts/desktop/hypr-keys")) -- 快捷键速查面板
-- 伪概览（无插件）：临时把 scrolling 切成 dwindle 平铺展开全部窗口，点选窗口后自动切回。
-- 近似 niri 的 Super+D overview（Hyprland 无原生 overview，故用布局切换模拟）。
hl.bind(mainMod .. " + D", hl.dsp.exec_cmd("$HOME/.config/hypr/scripts/fake-overview.sh")) -- 伪概览
-- 关闭显示器（DPMS）。Wiki 建议用 timer 包裹，避免直接 keybind 触发的未定义行为。
hl.bind(mainMod .. " + SHIFT + P", function()
	hl.timer(function()
		hl.dispatch(hl.dsp.dpms({ action = "off" }))
	end, { timeout = 300, type = "oneshot" })
end)

-- ===== 截图（DMS + vellum，均支持 Hyprland） =====
-- 截图前先给 screenshot-sound 守护 "上膛"（创建触发文件），截图完成复制到剪贴板后播放快门声。
-- 用绝对路径调用 arm 子命令：~/.local/bin 不在合成器 spawn PATH 中。
-- 与 niri 一致：仅在真正产生新截图的捕获键上膛（dms region/window/full、vellum region/long）。
local arm_shutter = "$HOME/scripts/desktop/screenshot-sound arm; "
hl.bind("Print", hl.dsp.exec_cmd(arm_shutter .. "dms screenshot region")) -- 框选截图
hl.bind("ALT + Print", hl.dsp.exec_cmd(arm_shutter .. "dms screenshot window")) -- 当前窗口
hl.bind("CTRL + Print", hl.dsp.exec_cmd(arm_shutter .. "dms screenshot full")) -- 整个屏幕
hl.bind(mainMod .. " + Print", hl.dsp.exec_cmd(arm_shutter .. "$HOME/.local/bin/vellumctl region")) -- vellum 框选+工具栏
hl.bind(mainMod .. " + SHIFT + Print", hl.dsp.exec_cmd(arm_shutter .. "$HOME/.local/bin/vellumctl long")) -- vellum 长截图
hl.bind(mainMod .. " + CTRL + Print", hl.dsp.exec_cmd("$HOME/.local/bin/vellumctl pin-last")) -- vellum 钉图

-- ===== 鼠标：Super+左键拖动 / Super+右键缩放 =====
hl.bind(mainMod .. " + mouse:272", hl.dsp.window.drag(), { mouse = true })
hl.bind(mainMod .. " + mouse:273", hl.dsp.window.resize(), { mouse = true })
-- Super+滚轮：左右切换列焦点（同 niri focus-column-left/right）。
-- 用 layout("focus l/r")（滚动布局专用列焦点，带 wrap、能沿列无限滚动），
-- 而非 focus({ direction })——后者是几何方向 movefocus，在滚动布局下会卡在
-- 相邻两个窗口间来回弹，无法沿列滚动。与 Alt+H/L 保持一致。
hl.bind(mainMod .. " + mouse_down", hl.dsp.layout("focus r"))
hl.bind(mainMod .. " + mouse_up", hl.dsp.layout("focus l"))
-- Super+Shift+滚轮：上下切换工作区（同 niri focus-workspace-down/up）
hl.bind(mainMod .. " + SHIFT + mouse_down", hl.dsp.focus({ workspace = "e+1" }))
hl.bind(mainMod .. " + SHIFT + mouse_up", hl.dsp.focus({ workspace = "e-1" }))

-- ===== 媒体 / 亮度键（走 DMS 以保留 OSD，与 niri 一致，锁屏也可用） =====
hl.bind("XF86AudioRaiseVolume", hl.dsp.exec_cmd("dms ipc call audio increment 3"), { locked = true, repeating = true })
hl.bind("XF86AudioLowerVolume", hl.dsp.exec_cmd("dms ipc call audio decrement 3"), { locked = true, repeating = true })
hl.bind("XF86AudioMute", hl.dsp.exec_cmd("dms ipc call audio mute"), { locked = true })
hl.bind("XF86AudioMicMute", hl.dsp.exec_cmd("dms ipc call audio micmute"), { locked = true })
hl.bind(
	"XF86MonBrightnessUp",
	hl.dsp.exec_cmd("dms ipc call brightness increment 5 ''"),
	{ locked = true, repeating = true }
)
hl.bind(
	"XF86MonBrightnessDown",
	hl.dsp.exec_cmd("dms ipc call brightness decrement 5 ''"),
	{ locked = true, repeating = true }
)
-- Ctrl+音量键 → 调整当前媒体播放器音量（mpris），对齐 niri
hl.bind(
	"CTRL + XF86AudioRaiseVolume",
	hl.dsp.exec_cmd("dms ipc call mpris increment 3"),
	{ locked = true, repeating = true }
)
hl.bind(
	"CTRL + XF86AudioLowerVolume",
	hl.dsp.exec_cmd("dms ipc call mpris decrement 3"),
	{ locked = true, repeating = true }
)
hl.bind("XF86AudioNext", hl.dsp.exec_cmd("dms ipc call mpris next"), { locked = true })
hl.bind("XF86AudioPause", hl.dsp.exec_cmd("dms ipc call mpris playPause"), { locked = true })
hl.bind("XF86AudioPlay", hl.dsp.exec_cmd("dms ipc call mpris playPause"), { locked = true })
hl.bind("XF86AudioPrev", hl.dsp.exec_cmd("dms ipc call mpris previous"), { locked = true })
