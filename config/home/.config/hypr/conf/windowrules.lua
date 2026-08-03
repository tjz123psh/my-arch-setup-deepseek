--------------------------------
---- WINDOWS AND WORKSPACES ----
--------------------------------

-- See https://wiki.hypr.land/Configuring/Basics/Window-Rules/
-- and https://wiki.hypr.land/Configuring/Basics/Workspace-Rules/

-- Example window rules that are useful

local suppressMaximizeRule = hl.window_rule({
	-- Ignore maximize requests from all apps. You'll probably like this.
	name = "suppress-maximize-events",
	match = { class = ".*" },

	suppress_event = "maximize",
})
-- suppressMaximizeRule:set_enabled(false)
local _ = suppressMaximizeRule

hl.window_rule({
	-- Fix some dragging issues with XWayland
	name = "fix-xwayland-drags",
	match = {
		class = "^$",
		title = "^$",
		xwayland = true,
		float = true,
		fullscreen = false,
		pin = false,
	},

	no_focus = true,
})

-- Hyprland-run windowrule
hl.window_rule({
	name = "move-hyprland-run",
	match = { class = "hyprland-run" },

	move = "20 monitor_h-120",
	float = true,
})

-- ===== 对齐 niri 的浮动窗口规则（见 ~/.config/niri/dms/windowrules.kdl） =====
-- niri 用 app-id 精确匹配；Hyprland 的 match.class 是正则，这里锚定 ^...$ 并转义点号，
-- 语义与 niri 一致。niri 只控制列宽（高度 auto），Hyprland 的 size 需同时给宽高，
-- 故对仅限宽的窗口补一个合理高度。

-- 维护菜单：大号浮动终端（1600x1000，同 niri term-menu）
hl.window_rule({
	name = "float-term-menu",
	match = { class = "^term-menu$" },
	float = true,
	size = { 1600, 1000 },
})

-- 浮动终端：小窗口浮动，不干扰布局（同 niri quickterminal，宽约 800）
hl.window_rule({
	name = "float-quickterminal",
	match = { class = "^quickterminal$" },
	float = true,
	size = { 800, 500 },
})

-- QuickShell / DMS 面板类窗口浮动（同 niri）
hl.window_rule({
	name = "float-quickshell",
	match = { class = "^org\\.quickshell$" },
	float = true,
})
hl.window_rule({
	name = "float-dms",
	match = { class = "^com\\.danklinux\\.dms$" },
	float = true,
})

-- vellum 钉图窗口：浮动 + 无边框（同 niri ai.vellum.pin 的去边框/焦点环；
-- Hyprland 无独立 no_border 效果，用 border_size = 0）
hl.window_rule({
	name = "float-vellum-pin",
	match = { class = "^ai\\.vellum\\.pin$" },
	float = true,
	border_size = 0,
})

-- vellum OCR / 翻译结果小窗：浮动，宽约 560（同 niri ai.vellum.result）
hl.window_rule({
	name = "float-vellum-result",
	match = { class = "^ai\\.vellum\\.result$" },
	float = true,
	size = { 560, 400 },
})

-- 计算器 / 蓝牙管理器等小工具窗口浮动（同 niri）
hl.window_rule({
	name = "float-small-tools",
	match = { class = "^(org\\.gnome\\.Calculator|gnome-calculator|galculator|blueman-manager)$" },
	float = true,
})

-- 快捷键速查面板：浮动 700x500（同 niri niri-keys 窗口）
hl.window_rule({
	name = "float-hypr-keys",
	match = { class = "^hypr-keys$" },
	float = true,
	size = { 700, 500 },
})
