------------------
---- MONITORS ----
------------------

-- See https://wiki.hypr.land/Configuring/Basics/Monitors/
-- scale 显式设为 1，对齐 niri（~/.config/niri/dms/outputs.kdl 的 eDP-1 scale 1）。
-- Hyprland 的 "auto" 会给 1920x1080 算出 1.5 倍缩放，导致整体界面比 niri 大一圈。
hl.monitor({
	output = "",
	mode = "preferred",
	position = "auto",
	scale = 1,
})
