-----------------------
---- LOOK AND FEEL ----
-----------------------

-- Refer to https://wiki.hypr.land/Configuring/Basics/Variables/
hl.config({
	general = {
		gaps_in = 5,
		gaps_out = 20,

		border_size = 2,

		-- 边框色由 DMS 接管（见 conf/appearance 之外的 hyprland.lua 顶部 require("dms.colors")，
		-- Material 配色同 niri）。如需覆盖，在 hyprland.lua 删除该 require 并在此设 col。
		resize_on_border = false,

		-- Please see https://wiki.hypr.land/Configuring/Advanced-and-Cool/Tearing/ before you turn this on
		allow_tearing = false,

		-- 滚动平铺布局（Hyprland 0.51+ 内置，无需插件），对齐 niri 的滚动列模型。
		layout = "scrolling",
	},

	decoration = {
		rounding = 10,
		rounding_power = 2,

		-- Change transparency of focused and unfocused windows
		active_opacity = 1.0,
		inactive_opacity = 1.0,

		shadow = {
			enabled = true,
			range = 4,
			render_power = 3,
			color = 0xee1a1a1a,
		},

		blur = {
			enabled = true,
			size = 3,
			passes = 1,
			vibrancy = 0.1696,
		},
	},

	animations = {
		enabled = true,
	},

	-- 滚动布局设置，对齐 niri（~/.config/niri/dms/layout.kdl）：
	--   explicit_column_widths 对应 niri preset-column-widths（1/3、1/2、2/3、全宽）
	--   column_width 0.5 = 新窗口默认半屏（同 niri default-column-width proportion 0.5）
	--   fullscreen_on_one_column = 单列时占满（近似 niri 单窗口行为）
	--   focus_fit_method 1 = 聚焦时把列滚入视野而非强行居中（同 niri center-focused-column "never"）
	--   wrap_focus/wrap_swapcol = false：到最左/右列后停下，不绕回另一侧（同 niri 默认不 wrap）
	scrolling = {
		fullscreen_on_one_column = true,
		column_width = 0.5,
		focus_fit_method = 1,
		explicit_column_widths = "0.333, 0.5, 0.667, 1.0",
		direction = "right",
		wrap_focus = false,
		wrap_swapcol = false,
	},
})

-- Default curves and animations, see https://wiki.hypr.land/Configuring/Advanced-and-Cool/Animations/
hl.curve("easeOutQuint", { type = "bezier", points = { { 0.23, 1 }, { 0.32, 1 } } })
hl.curve("easeInOutCubic", { type = "bezier", points = { { 0.65, 0.05 }, { 0.36, 1 } } })
hl.curve("linear", { type = "bezier", points = { { 0, 0 }, { 1, 1 } } })
hl.curve("almostLinear", { type = "bezier", points = { { 0.5, 0.5 }, { 0.75, 1 } } })
hl.curve("quick", { type = "bezier", points = { { 0.15, 0 }, { 0.1, 1 } } })

-- Default springs
hl.curve("easy", { type = "spring", mass = 1, stiffness = 71.2633, dampening = 15.8273644 })

hl.animation({ leaf = "global", enabled = true, speed = 10, bezier = "default" })
hl.animation({ leaf = "border", enabled = true, speed = 5.39, bezier = "easeOutQuint" })
hl.animation({ leaf = "windows", enabled = true, speed = 4.79, spring = "easy" })
hl.animation({ leaf = "windowsIn", enabled = true, speed = 4.1, spring = "easy", style = "popin 87%" })
hl.animation({ leaf = "windowsOut", enabled = true, speed = 1.49, bezier = "linear", style = "popin 87%" })
hl.animation({ leaf = "fadeIn", enabled = true, speed = 1.73, bezier = "almostLinear" })
hl.animation({ leaf = "fadeOut", enabled = true, speed = 1.46, bezier = "almostLinear" })
hl.animation({ leaf = "fade", enabled = true, speed = 3.03, bezier = "quick" })
hl.animation({ leaf = "layers", enabled = true, speed = 3.81, bezier = "easeOutQuint" })
hl.animation({ leaf = "layersIn", enabled = true, speed = 4, bezier = "easeOutQuint", style = "fade" })
hl.animation({ leaf = "layersOut", enabled = true, speed = 1.5, bezier = "linear", style = "fade" })
hl.animation({ leaf = "fadeLayersIn", enabled = true, speed = 1.79, bezier = "almostLinear" })
hl.animation({ leaf = "fadeLayersOut", enabled = true, speed = 1.39, bezier = "almostLinear" })
hl.animation({ leaf = "workspaces", enabled = true, speed = 1.94, bezier = "almostLinear", style = "fade" })
hl.animation({ leaf = "workspacesIn", enabled = true, speed = 1.21, bezier = "almostLinear", style = "fade" })
hl.animation({ leaf = "workspacesOut", enabled = true, speed = 1.94, bezier = "almostLinear", style = "fade" })
hl.animation({ leaf = "zoomFactor", enabled = true, speed = 7, bezier = "quick" })

-- See https://wiki.hypr.land/Configuring/Layouts/Dwindle-Layout/ for more
hl.config({
	dwindle = {
		preserve_split = true, -- You probably want this
	},
})

-- See https://wiki.hypr.land/Configuring/Layouts/Master-Layout/ for more
hl.config({
	master = {
		new_status = "master",
	},
})

----------------
----  MISC  ----
----------------

hl.config({
	misc = {
		force_default_wallpaper = -1, -- Set to 0 or 1 to disable the anime mascot wallpapers
		disable_hyprland_logo = false, -- If true disables the random hyprland logo / anime girl background. :(
	},
})

-----------------
----  CURSOR  ----
-----------------

-- 键盘切换焦点后，不要把鼠标指针 warp 到新聚焦的窗口/列（对齐 niri：
-- ~/.config/niri/dms/input.kdl 里 warp-mouse-to-focus 为注释禁用状态）。
-- 滚动布局下频繁用键盘切列，光标乱跳很干扰，故关闭。
hl.config({
	cursor = {
		no_warps = true,
	},
})
