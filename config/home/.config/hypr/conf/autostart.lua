-------------------
---- AUTOSTART ----
-------------------

-- See https://wiki.hypr.land/Configuring/Basics/Autostart/

-- Autostart necessary processes (like notifications daemons, status bars, etc.)
-- DMS (DankMaterialShell) 启动：一次性首帧调用下的按显示 best-effort 单
-- owner 选择（2026-08-09 Codex Round 4.10；弱一次性首帧契约）。
--   Hyprland 由 greetd/dms-greeter 会话菜单里的 "Hyprland (uwsm-managed)"
--   系统入口（/usr/share/wayland-sessions/hyprland-uwsm.desktop，
--   Exec=uwsm start -e -D Hyprland hyprland.desktop）启动。UWSM 负责导入
--   白名单会话环境、等待 HYPRLAND_INSTANCE_SIGNATURE、管理
--   graphical-session.target（dms.service 经 WantedBy 启动、退出时经 PartOf
--   停止）、退出时清除 systemd/D-Bus activation 环境。Hyprland 0.56.2 自己
--   也维护 systemd+D-Bus 环境（ready 时 import、退出时 unset；该导入是异步
--   启动的，第一帧时不能无证据声称已完成）。注意：第一帧时
--   graphical-session.target 可能已经 active，也可能仍在 queued/activating
--   （wayland-session-waitenv 在它之前等待 WAYLAND_DISPLAY 与
--   HYPRLAND_INSTANCE_SIGNATURE），不能假设它必然已经 active。
--   实测 DMS 自身不保证全局单实例：宿主曾同时存在 systemd backend 与一个
--   额外 daemon backend，屏幕上出现两条完全相同顶栏。systemd 的 user 域
--   start 是用户全局的（rc=0 只代表"某个"实例已 active/已启动，不代表当前
--   显示有可用 backend）；按进程名查找 dms 进程也是显示盲的——另一个显示
--   的 backend 会错误地抑制当前显示的启动。因此 DMS 启动决策必须按当前
--   WAYLAND_DISPLAY 逐个验证（基于 DMS 1.5.3 的 danklinux-*.session/.pid
--   runtime marker 契约），owner 语义是"每个显示至多一个"，而不是"整个
--   用户只能有一个"。全部逻辑在单一顺序执行的 helper 里：
--     $HOME/.local/bin/dms-ensure-display（POSIX sh）
--   helper 依次：当前显示 pre-check（已有 plausible owner 就直接返回，不再
--   请求 systemd；pre-check 为 unverifiable 时同样直接返回 rc=4，绝不盲目
--   启动第二 owner）→ 导入会话环境 → 请求 systemd 启动 dms.service（幂等，
--   rc 仅记录不作数）→ 当前显示 post-check → 仅当当前显示确实 absent/stale
--   （没有 matching marker，或 owner 已死/明确不是 dms）时才执行 dms daemon
--   兜底。hyprland.start 只在首帧触发一次，reload 不重触发 helper；flock 只
--   防重叠执行期间的双兜底，不承诺任意顺序手工重复调用永远只发一次请求
--   （daemon 返回与 marker 发布之间仍有窗口）。第一帧时 systemd 的 job 可能
--   仍在途，helper 在 systemctl 返回后仍按当前显示验证，不把 systemctl 的
--   用户全局成功当作当前会话成功。helper 只判定 "plausible owner"（matching
--   marker + owner 存活且名为 dms；/proc 查询失败保持真实 rc，绝不折叠成
--   plausible 或 absent），不声称 bar/IPC 已就绪——真实 bar/IPC readiness 由
--   VMware 验收。helper 的诊断走 stderr：autostart exec 路径下 stdout/stderr
--   被重定向到 /dev/null，不保证持久可见；VM 诊断以 systemctl/journal 和手工
--   运行 helper 为准。dms-greeter 的扫描路径是系统目录 + greeter 缓存
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
	-- DMS best-effort 单 owner 选择（按当前显示，Plausible owner 判定）：
	-- systemd dms.service 是首选 owner；helper 先 pre-check 当前显示（已有
	-- plausible owner 或状态 unverifiable 都直接返回，不再请求 systemd），
	-- 再 import + systemctl + post-check，
	-- 只有当前显示确实 absent/stale 时才 daemon 兜底。整条链在 helper 内顺序
	-- 执行（同一 exec_cmd，不能拆成两个异步 exec），也不得做显示盲的进程
	-- 查找判断。hyprland.start 只在首帧触发一次，reload 不重触发。
	-- 诊断持久化：autostart exec 路径下 stdout/stderr 被重定向到 /dev/null，
	-- 因此把 helper 的 stderr 追加到 $XDG_RUNTIME_DIR/dms-ensure.log（无管道，
	-- 不改 helper 退出码语义），第一次真实会话的 DMS 失败不再不可见。
	hl.exec_cmd("$HOME/.local/bin/dms-ensure-display 2>>${XDG_RUNTIME_DIR:-/tmp}/dms-ensure.log")
	-- 其余辅助进程由 UWSM 的 graphical-session.target 链或 XDG 自启动负责，
	-- 这里只兜底非 systemd 的辅助进程（幂等 pgrep 守卫，同 niri）。
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
