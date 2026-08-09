-------------------
---- AUTOSTART ----
-------------------

-- See https://wiki.hypr.land/Configuring/Basics/Autostart/

-- Autostart necessary processes (like notifications daemons, status bars, etc.)
-- DMS (DankMaterialShell) 启动：与物理机已验证方式一致（2026-08-09 Codex R4.12）。
--   Hyprland 会话使用系统 stock 入口 /usr/share/wayland-sessions/hyprland.desktop
--   （Exec=/usr/bin/start-hyprland）。start-hyprland 是纯二进制、不触达
--   graphical-session.target，因此 Hyprland 会话里没有 systemd dms.service——
--   DMS 由本钩子在 hyprland.start 首帧用 dms 的 daemon 模式直接启动，
--   以 qs 进程守卫做幂等（守卫通过则跳过，未通过才执行 daemon 启动）：
--     pgrep -f '[q]s -p /usr/share/quickshell/dms' >/dev/null || <daemon 启动>
--   守卫匹配 qs（quickshell UI）而不是 dms backend：同一显示上 qs 已在跑就说明
--   DMS 已就绪，不再重复启动。守卫用字符类 [q]s——执行守卫的 sh 命令行也含
--   该模式串，若直接写 "qs" 会自匹配导致永远"已在跑"而从不启动（物理机实测
--   有效的写法）。
--   为什么不会双顶栏：Hyprland stock 会话里 dms.service 本就是 inactive（没有
--   graphical-session.target），daemon 启动是唯一 backend。uwsm 入口已于
--   2026-08-09（R5）从安装清单移除；若升级主机残留 hyprland-uwsm.desktop，
--   本守卫看到 qs 已在跑也会跳过 daemon 兜底——两条路径互不干扰。Niri 侧不受
--   影响：niri 仍由 systemd 用户服务 dms.service 经 graphical-session.target 启动。
--   诊断：DMS 启动命令的 stderr 追加到 $XDG_RUNTIME_DIR/dms-ensure.log
--   （autostart exec 路径 stdout/stderr 会被重定向到 /dev/null，显式落盘才能
--   看到失败）。~/.local/bin/dms-ensure-display 作为可选诊断工具保留
--   （手工运行可看三态判定与退出码），不再由本钩子调用。
--   dms-greeter 的扫描路径是系统目录 + greeter 缓存（HOME/XDG_DATA_HOME 指向
--   /var/cache/dms-greeter），不是目标用户的 ~/.local/share，因此用户级
--   desktop 入口方案已废弃。
-- 与 niri 保持一致：U 盘自动挂载托盘。
-- XDG 自启动：niri 由 systemd 的 xdg-desktop-autostart.target 拉起；start-hyprland
--   是纯二进制不触达该 target，故下面手动 exec 用 pgrep 守卫做幂等兜底（fcitx5
--   输入法、blueman 蓝牙托盘、FlClash 代理）。只影响 Hyprland 会话，niri 侧不受
--   影响（niri 仍走 systemd 的 xdg-desktop-autostart.target，两条路径互不干扰）。
--   已由 socket/dbus 激活、无需补的：pipewire/wireplumber（音频）、xdg-desktop-portal(-gtk)、
--   gvfs、polkitd（系统级）。图形 polkit 授权 agent 由 DMS（quickshell Polkit）接管。
--   fcitx5 的 IM 环境变量（QT_IM_MODULE/XMODIFIERS）在 /etc/environment 全局生效，仅需起进程。
hl.on("hyprland.start", function()
	-- DMS：qs 进程守卫 + 直接 daemon 启动（物理机已验证方式；说明见文件头）。
	-- stderr 追加到 $XDG_RUNTIME_DIR/dms-ensure.log 便于诊断（无管道，不改退出码）。
	hl.exec_cmd("pgrep -f '[q]s -p /usr/share/quickshell/dms' >/dev/null || dms run -d 2>>${XDG_RUNTIME_DIR:-/tmp}/dms-ensure.log")
	-- 其余辅助进程由 niri 的 systemd XDG 自启动或本钩子兜底（幂等 pgrep 守卫，同 niri）。
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
