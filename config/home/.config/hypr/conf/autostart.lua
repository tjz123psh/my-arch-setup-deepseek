-------------------
---- AUTOSTART ----
-------------------

-- See https://wiki.hypr.land/Configuring/Basics/Autostart/

-- Autostart necessary processes (like notifications daemons, status bars, etc.)
-- DMS (DankMaterialShell) 说明（2026-08-08 整改，review 6.2/6.3）：
--   niri 会话由 systemd 用户服务 dms.service（WantedBy=graphical-session.target）拉起 DMS。
--   之前 Hyprland 用 `dms run -d` 直接绕过 systemd 启动 DMS，绕开了 dms.service 的
--   restart/状态/日志管理和 graphical-session.target 生命周期。现在改为：
--     1) dbus-update-activation-environment --systemd --all 把 Wayland/XDG 环境导入
--        systemd 用户环境（dms.service 才能拿到 WAYLAND_DISPLAY 等）；
--     2) systemctl --user start hyprland-session.target，该 target Wants=
--        graphical-session.target + xdg-desktop-autostart.target，从而由 dms.service
--        （带 Restart=on-failure）统一管理 DMS 生命周期，与 niri 会话完全一致。
--   退出 Hyprland（登出）时 systemd --user 实例随 greetd 会话结束而停止，DMS 随之停止。
-- 与 niri 保持一致：U 盘自动挂载托盘。
-- XDG 自启动：hyprland-session.target Wants=xdg-desktop-autostart.target，登录时自动
--   拉起 ~/.config/autostart 和 /etc/xdg/autostart 里的 .desktop（fcitx5 输入法、
--   blueman 蓝牙托盘、FlClash 代理）。下面手动 exec 用 pgrep 守卫做幂等兜底，
--   避免与残留进程重复（XDG 自启动失败时仍有保障）。只影响 Hyprland 会话。
--   已由 socket/dbus 激活、无需补的：pipewire/wireplumber（音频）、xdg-desktop-portal(-gtk)、
--   gvfs、polkitd（系统级）。图形 polkit 授权 agent 由 DMS（quickshell Polkit）接管。
--   fcitx5 的 IM 环境变量（QT_IM_MODULE/XMODIFIERS）在 /etc/environment 全局生效，仅需起进程。
hl.on("hyprland.start", function()
	-- 环境导入 + systemd 会话生命周期：DMS 由 dms.service 管理（见上）。
	hl.exec_cmd("dbus-update-activation-environment --systemd --all")
	hl.exec_cmd("systemctl --user start hyprland-session.target")
	-- U 盘自动挂载托盘（同 niri config.kdl 的 spawn-at-startup "udiskie" "-t"）
	hl.exec_cmd("pgrep -x udiskie >/dev/null || udiskie -t")
	-- 输入法（IM 变量走 /etc/environment，这里只保证进程起来）
	hl.exec_cmd("pgrep -x fcitx5 >/dev/null || fcitx5 -d")
	-- 蓝牙托盘
	hl.exec_cmd("pgrep -x blueman-applet >/dev/null || blueman-applet")
	-- FlClash 代理（由 archlinuxcn 的 flclash 提供 /usr/bin/flclash）
	hl.exec_cmd("pgrep -x FlClash >/dev/null || flclash")
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
