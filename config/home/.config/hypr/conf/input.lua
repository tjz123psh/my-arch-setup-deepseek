---------------
---- INPUT ----
---------------

-- 输入手感对齐 niri（见 ~/.config/niri/dms/input.kdl）
hl.config({
	input = {
		kb_layout = "us",
		kb_variant = "",
		kb_model = "",
		kb_options = "",
		kb_rules = "",

		follow_mouse = 1,

		-- Super+滚轮触发 focus l/r 让列横向滚动，但光标屏幕位置不动（no_warps）。
		-- mouse_refocus 默认 true 时，滚动后另一窗口移到光标下，同一滚轮指针事件会
		-- 立即把焦点抢回光标下的窗口，导致焦点在两列间来回弹。设 false 后只有光标
		-- 真正跨越窗口边界才切焦点，滚轮沿列滚动不再被打断。
		mouse_refocus = false,

		-- niri: repeat-delay 200 / repeat-rate 50（更快的按键重复）
		repeat_delay = 200,
		repeat_rate = 50,

		-- niri: 启动时开 numlock
		numlock_by_default = true,

		-- niri: accel-profile "flat" / accel-speed 0.0（触摸板为主，无鼠标加速）
		accel_profile = "flat",
		sensitivity = 0, -- -1.0 - 1.0，0 = 不修改

		touchpad = {
			-- niri: tap（轻点点击）+ natural-scroll
			tap_to_click = true,
			natural_scroll = true,
		},
	},
})

hl.gesture({
	fingers = 3,
	direction = "horizontal",
	action = "workspace",
})

-- 外接鼠标单独设加速，对齐 niri（~/.config/niri/dms/input.kdl 的 mouse 段：
-- accel-profile "flat" / accel-speed 0.3）。设备名由 `hyprctl devices` 得到。
-- 笔记本自带触控设备（asuf1204:...-mouse / -touchpad）不在此列，沿用上面
-- input 段的全局 flat / 0 设置。
-- See https://wiki.hypr.land/Configuring/Advanced-and-Cool/Devices/ for more
hl.device({
	name = "hfd-atk-a87pro-mouse",
	accel_profile = "flat",
	sensitivity = 0.3,
})
-- YJX 无线游戏鼠标：USB 重新枚举时上报的 product string 会变，Hyprland 归一化出
-- 两种设备名（有线/USB 模式 yjx-chip-usb-gaming-mouse，2.4G 无线模式
-- yjx-chip-2.4g-gaming-mouse）。两个都配上，掉线重连后无论以哪种方式枚举都能命中。
hl.device({
	name = "yjx-chip-usb-gaming-mouse",
	accel_profile = "flat",
	sensitivity = 0.3,
})
hl.device({
	name = "yjx-chip-2.4g-gaming-mouse",
	accel_profile = "flat",
	sensitivity = 0.3,
})
