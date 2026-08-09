# Hyprland 会话 DMS 不加载 / 终端闪退 — 宿主修复与诊断清单

> 2026-08-09（Codex R4.12 / R5）。本清单基于只读探查结论：**物理机的既有配置是
> 可工作参照**（stock `start-hyprland` + autostart 的 qs 守卫直接 `dms run -d`，
> 来回切换 DMS 照常、终端正常）；仓库 R4.12 已把 Hyprland 的 DMS 启动**对齐物理机**
> （autostart 直接启动 + qs 守卫，不再依赖 helper/uwsm 链；R5 起 uwsm 已从安装
> 清单移除，Hyprland 会话入口固定为系统 stock `hyprland.desktop`）。宿主当前状态：
> 配置已从备份还原（`~/.config/hypr.bak-20260809-190830`），
> `~/.local/bin/dms-ensure-display`
> 已移除（可选诊断工具，需要时再装）。VM 若仍失败，按本清单会话内取证。

## 一、根因回顾（探查结论）

1. **DMS 不加载**：仓库 R4.7–R4.11 把 Hyprland DMS 启动换成了 uwsm+helper+systemd
   链，该链**从未在真实会话验证过**（VMware 四轮 UNAVAILABLE），VM 里失败；而物理机
   一直用 stock `start-hyprland` + autostart 直接 `dms run -d`（qs 守卫），工作正常。
   R4.12 已把仓库 autostart 对齐物理机。注意：`start-hyprland` 不触达
   `graphical-session.target`，所以 stock 会话里 dms.service 本就是 inactive，
   autostart 的 daemon 启动是唯一 backend——不会双顶栏。
2. **终端闪退**：配置层无关闭 kitty 的 windowrule、fish 无主动退出（与物理机
   keybinds 逐字节核对，唯一差异是仓库多了 Super+Return 同一命令）；放大器是
   kitty.conf 的 `confirm_os_window_close 0`（任何启动失败立即关窗无确认）。头号
   运行时嫌疑是会话 spawn 环境完整性（WAYLAND_DISPLAY/PATH/XDG_RUNTIME_DIR）与
   VM/GPU 下 kitty 后端初始化。**必须真实会话内诊断才能定根因。**

## 二、宿主步骤（对齐物理机；入口固定为 stock hyprland.desktop）

物理机无需 uwsm 即可工作；仓库 R5 已把 uwsm 从安装清单移除，Hyprland 会话
入口固定为系统 stock `hyprland.desktop`（`start-hyprland`），autostart 不依赖
helper/uwsm：

```sh
# 1) 部署当前 hypr 配置（先备份现有配置！会覆盖宿主 ~/.config/hypr）
cp -a ~/.config/hypr ~/.config/hypr.bak-$(date +%Y%m%d)
cp -a <repo>/config/home/.config/hypr/. ~/.config/hypr/

# 2)（可选）诊断工具：把 helper 装到 ~/.local/bin 供手工诊断
install -Dm755 <repo>/config/home/.local/bin/dms-ensure-display ~/.local/bin/dms-ensure-display

# 3) 验证部署的 autostart 已对齐（应看到 qs 守卫 + dms 直接启动行）
grep "dms run -d" ~/.config/hypr/conf/autostart.lua
grep Exec /usr/share/wayland-sessions/hyprland.desktop   # 应为 Exec=/usr/bin/start-hyprland
```

> 也可直接重跑安装器的 `07-config`+`08-services`（both 模式）完成部署与校验
> （08-services 会 fail-closed 校验系统 stock 入口：存在、desktop entry 有效、
> Exec=/usr/bin/start-hyprland；升级主机残留 hyprland-uwsm.desktop 只警告不校验）。

## 三、重登后会话内诊断清单（greeter 菜单选 "Hyprland"，勿选 uwsm-managed 项）

进 Hyprland 后逐项执行并记录：

```sh
# 1) R4.11 持久日志 —— helper 每一步 stderr（最重要）
cat "$XDG_RUNTIME_DIR/dms-ensure.log"

# 2) systemd 侧
systemctl --user status dms.service
journalctl --user -u dms.service -b --no-pager | tail -40

# 3)（可选诊断工具已装时）手工重跑 helper，看三态判定与退出码
"$HOME/.local/bin/dms-ensure-display"; echo "helper rc=$?"

# 4) 终端闪退对照（Super+Return 与 Alt+Enter 同命令；都闪则排除 Alt 截获）
kitty -e fish; echo "kitty rc=$?"
echo "WAYLAND_DISPLAY=$WAYLAND_DISPLAY XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR HYPRLAND_INSTANCE_SIGNATURE=$HYPRLAND_INSTANCE_SIGNATURE"

# 5) Hyprland 配置健康
hyprctl binds -j | head -50
hyprctl configerrors
```

## 四、dms-ensure.log 消息 → 含义 → 处置

R4.12 起 dms-ensure.log 记录的是 autostart DMS 启动命令（qs 守卫 + daemon 启动）
的 stderr，不是 helper 的输出：

| 日志内容 | 含义 | 处置 |
|---|---|---|
| 有 `dms run -d` 相关 stderr（含报错） | autostart 执行了 daemon 启动且失败 | 把报错贴出；查 `dms` 是否在 PATH、journal 中 dms 报错、VM GPU |
| 日志为空/仅有无害行 | qs 已在跑（守卫短路，DMS 已就绪）**或** autostart 钩子未执行 | 顶栏有 → 正常；顶栏无 → 查钩子是否触发（`hyprctl configerrors`、日志时间戳） |
| 无 dms-ensure.log | `dms run -d` 从未执行（守卫命中 qs 或命令未运行） | 同上 |
| （手工 helper 已装时）`plausible/unverifiable/absent` | 三态判定的当前显示 owner 状态 | 按 R4.10 handoff 的三态语义处置；`unverifiable` → 查 marker/`/proc/<pid>/comm` |

## 五、终端闪退的判别结论路径

1. Super+Return 是否同样闪退：是 → 排除 Alt+Enter 宿主截获，锁定 spawn 环境/kitty
   后端；否 → Alt+Enter 被截获（keybinds 已有 Super+Return 备选，可只用 Super+Return）。
2. 手工 `kitty -e fish` 的 rc 与 stderr：非 0 → kitty/fish 启动失败，看具体报错
   （Wayland 连接 / GL 初始化）；0 但窗口消失 → 窗口被合成器/规则关闭（`hyprctl
   configerrors` 与 windowrules 复核）。
3. `WAYLAND_DISPLAY`/`XDG_RUNTIME_DIR` 为空 → spawn 环境问题（物理机 stock 入口
   无此问题；VM 若仍失败，重点查会话 spawn env 导入与 VMware GPU/GL）。
4. 若为 VM（VMware SVGA 3D）→ 按 comprehensive-review 的分层变量法（3D on/off、
   blur on/off）隔离。

## 六、验证完成标准（对应 R4.10 handoff 契约）

- dms.service active（Niri 会话）；Hyprland 会话里 `qs -p /usr/share/quickshell/dms`
  恰好一个、bar 可见；
- `dms ipc call settings focusOrToggle` 可用；Super+Return 打开 kitty；
- `hyprctl binds -j` 含仓库绑定；`hyprctl configerrors` 无错误；
- reload 两次不产生双栏；注销回 Niri 无 daemon-child 残留。
