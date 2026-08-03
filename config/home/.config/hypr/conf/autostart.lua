-------------------
---- AUTOSTART ----
-------------------

-- See https://wiki.hypr.land/Configuring/Basics/Autostart/

-- Autostart necessary processes (like notifications daemons, status bars, etc.)
-- DMS (DankMaterialShell) 说明：
--   niri 会话由 systemd 用户服务 dms.service（WantedBy=graphical-session.target）拉起 DMS。
--   但 Hyprland 的 start-hyprland 不触达 graphical-session.target，dms.service 不会自启，
--   所以这里显式用 `dms run -d`（daemon 模式）在 Hyprland 会话内启动 DMS。
--   这只影响 Hyprland 会话；niri 侧的 systemd 自启动机制完全不受影响（两条路径互不干扰，
--   且不会在同一会话里重复启动——Hyprland 会话下 dms.service 本就是 inactive）。
--   启动后状态栏/通知/壁纸/所有 `dms ipc call` 键位与 niri 一致。
-- 与 niri 保持一致：U 盘自动挂载托盘。
-- XDG 自启动补齐：
--   niri.service 带 Wants=xdg-desktop-autostart.target，登录时自动拉起 ~/.config/autostart
--   和 /etc/xdg/autostart 里的 .desktop（fcitx5 输入法、blueman 蓝牙托盘、FlClash 代理）。
--   start-hyprland 是纯二进制、不触达该 target，故这些在 Hyprland 会话不会自启，这里手动补。
--   全部用 pgrep 守卫做幂等，避免与残留进程重复。只影响 Hyprland 会话，niri 侧不受影响：
--   niri 仍走 systemd 的 xdg-desktop-autostart.target，两条路径互不干扰。
--   已由 socket/dbus 激活、无需补的：pipewire/wireplumber（音频）、xdg-desktop-portal(-gtk)、
--   gvfs、polkitd（系统级）。图形 polkit 授权 agent 由 DMS（quickshell Polkit）接管。
--   fcitx5 的 IM 环境变量（QT_IM_MODULE/XMODIFIERS）在 /etc/environment 全局生效，仅需起进程。
hl.on("hyprland.start", function()
	-- 幂等守卫：仅当对应进程未在跑时才启动。exec_cmd 自身已通过 /bin/sh -c 执行，
	-- 故不再嵌套 sh -c（嵌套 + 转义双引号会导致解析失败）。
	-- DMS：pgrep -f 匹配完整命令行，但执行守卫的 sh 进程命令行里也含该字符串，会
	-- 自匹配导致永远"已在跑"而从不启动。用字符类 [q]s 让正则仍匹配 qs 开头的真实
	-- 进程，但模式串本身不含 "qs" 字面量，从而不匹配守卫命令自身。
	hl.exec_cmd("pgrep -f '[q]s -p /usr/share/quickshell/dms' >/dev/null || dms run -d")
	-- U 盘自动挂载托盘（同 niri config.kdl 的 spawn-at-startup "udiskie" "-t"）
	hl.exec_cmd("pgrep -x udiskie >/dev/null || udiskie -t")
	-- 输入法（IM 变量走 /etc/environment，这里只保证进程起来）
	hl.exec_cmd("pgrep -x fcitx5 >/dev/null || fcitx5 -d")
	-- 蓝牙托盘
	hl.exec_cmd("pgrep -x blueman-applet >/dev/null || blueman-applet")
	-- FlClash 代理（可执行在 /usr/lib/flclash/FlClash）
	hl.exec_cmd("pgrep -x FlClash >/dev/null || /usr/lib/flclash/FlClash")
	-- 截图音效守护：监听剪贴板，配合截图键的 `screenshot-sound arm` 上膛播放快门声（同 niri）。
	-- 脚本内部用 flock 保证单实例，直接启动即可；不要再加 pgrep 守卫，
	-- 因为守卫命令行自身含 "screenshot-sound" 字样会被 pgrep 自匹配，导致永不启动。
	hl.exec_cmd("$HOME/scripts/desktop/screenshot-sound")
end)

-------------------------------
---- ENVIRONMENT VARIABLES ----
-------------------------------

-- See https://wiki.hypr.land/Configuring/Advanced-and-Cool/Environment-variables/

hl.env("XCURSOR_SIZE", "24")
hl.env("HYPRCURSOR_SIZE", "24")
-- 与 niri 一致：GTK 走 OpenGL 渲染器，规避双显卡下 GTK 应用启动慢
hl.env("GSK_RENDERER", "gl")
-- 与 niri environment{} 一致：启用 opencode 内置 websearch 工具（Exa AI，免费无需 key）
hl.env("OPENCODE_ENABLE_EXA", "1")
