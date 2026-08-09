-------------------
---- AUTOSTART ----
-------------------

-- See https://wiki.hypr.land/Configuring/Basics/Autostart/

-- Autostart necessary processes (like notifications daemons, status bars, etc.)
-- DMS (DankMaterialShell) 说明（2026-08-09 Codex Round 4）：
--   Hyprland 由 greetd/dms-greeter 会话菜单里的 "Hyprland (uwsm-managed)"
--   系统入口（/usr/share/wayland-sessions/hyprland-uwsm.desktop，
--   Exec=uwsm start -e -D Hyprland hyprland.desktop）启动。UWSM 负责：
--   导入白名单会话环境、等 HYPRLAND_INSTANCE_SIGNATURE、拉起
--   graphical-session.target（dms.service 经 WantedBy 自动启动，退出时经
--   PartOf 停止）、退出时清除 systemd/D-Bus activation 环境。Hyprland
--   0.56.2 自己也维护 systemd+D-Bus 环境（ready 时 import、退出时 unset）。
--   本钩子不再做任何 systemctl import/unset/start——只需兜底拉起非
--   systemd 的辅助进程。dms-greeter 的扫描路径是系统目录 + greeter 缓存
--   （HOME/XDG_DATA_HOME 指向 /var/cache/dms-greeter），不是目标用户的
--   ~/.local/share，因此用户级 desktop 入口方案已废弃。
-- 与 niri 保持一致：U 盘自动挂载托盘。
-- XDG 自启动：由 uwsm 激活 xdg-desktop-autostart.target 拉起
--   ~/.config/autostart 和 /etc/xdg/autostart 里的 .desktop（fcitx5 输入法、
--   blueman 蓝牙托盘、FlClash 代理）。下面手动 exec 用 pgrep 守卫做幂等兜底，
--   避免与残留进程重复（XDG 自启动失败时仍有保障）。只影响 Hyprland 会话。
--   已由 socket/dbus 激活、无需补的：pipewire/wireplumber（音频）、xdg-desktop-portal(-gtk)、
--   gvfs、polkitd（系统级）。图形 polkit 授权 agent 由 DMS（quickshell Polkit）接管。
--   fcitx5 的 IM 环境变量（QT_IM_MODULE/XMODIFIERS）在 /etc/environment 全局生效，仅需起进程。
hl.on("hyprland.start", function()
	-- 会话生命周期由 UWSM 管理（graphical-session.target 拉起/停止 dms），
	-- 这里只兜底非 systemd 的辅助进程。
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
