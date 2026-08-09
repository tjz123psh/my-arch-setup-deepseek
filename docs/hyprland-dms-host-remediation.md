# Hyprland 会话 DMS 不加载 / 终端闪退 — 宿主修复与诊断清单

> 2026-08-09（Codex R4.11）。本清单基于只读探查结论（宿主保留窗口内无 Hyprland
> 会话痕迹；宿主缺 `uwsm`、`~/.config/hypr` 为 07-26~29 部署的旧版、helper 未部署；
> 仓库 R4.10 设计正确但从未在真实 Hyprland 会话验证过；VMware 四轮 UNAVAILABLE）。
> 仓库侧 R4.11 已把 helper 诊断持久化到 `$XDG_RUNTIME_DIR/dms-ensure.log`，使第一
> 次真实会话的失败不再不可见。

## 一、根因回顾（探查结论）

1. **DMS 不加载**：
   - 宿主未安装 `uwsm` → `hyprland-uwsm.desktop`（`TryExec=uwsm`）不可选 → 只剩
     stock `Hyprland`（`Exec=/usr/bin/start-hyprland`）；
   - `start-hyprland` 不触达 `graphical-session.target` → `dms.service`
     （`WantedBy`+`Requisite=graphical-session.target`）永不自动拉起，
     `systemctl --user start dms.service` 也会因 Requisite 失败；
   - 宿主旧 autostart 用 `pgrep -f '[q]s ...' || dms run -d`（R4.7 否决形式）兜底，
     且仓库 R4.10 helper 未部署到宿主 → 失败完全静默。
2. **终端闪退**：配置层无关闭 kitty 的 windowrule、fish 无主动退出；放大器是
   kitty.conf 的 `confirm_os_window_close 0`（任何启动失败立即关窗无确认）；头号
   运行时嫌疑是 Hyprland spawn 环境完整性（WAYLAND_DISPLAY/PATH/XDG_RUNTIME_DIR）
   与 VM/GPU 下 kitty 后端初始化。**必须真实会话内诊断才能定根因。**

## 二、需授权执行的宿主步骤（仓库边界外，agent 不代执行）

以下命令需要你确认后自行执行（或明确授权 agent 逐条执行）：

```sh
# 1) 安装 uwsm（hyprland 的 UWSM 入口才能用）
sudo pacman -S uwsm            # 或经 gsudo

# 2) 部署当前 hypr 配置（先备份现有配置！会覆盖宿主 ~/.config/hypr）
cp -a ~/.config/hypr ~/.config/hypr.bak-$(date +%Y%m%d)
cp -a <repo>/config/home/.config/hypr/. ~/.config/hypr/

# 3) 部署 helper 到 ~/.local/bin（新增，不覆盖）
install -Dm755 <repo>/config/home/.local/bin/dms-ensure-display ~/.local/bin/dms-ensure-display

# 4) 验证入口可用
test -x /usr/bin/uwsm && echo uwsm-ok
grep TryExec /usr/share/wayland-sessions/hyprland-uwsm.desktop   # 应为 TryExec=uwsm
```

> 也可直接重跑安装器的 `07-config`+`08-services`（both 模式）完成部署与校验
> （08-services 会 fail-closed 校验 uwsm 与系统入口）。

## 三、重登后会话内诊断清单（选 "Hyprland (uwsm-managed)"）

进 Hyprland 后逐项执行并记录：

```sh
# 1) R4.11 持久日志 —— helper 每一步 stderr（最重要）
cat "$XDG_RUNTIME_DIR/dms-ensure.log"

# 2) systemd 侧
systemctl --user status dms.service
journalctl --user -u dms.service -b --no-pager | tail -40

# 3) 手工重跑 helper（看 rc 与 stderr）
"$HOME/.local/bin/dms-ensure-display"; echo "helper rc=$?"

# 4) 终端闪退对照（Super+Return 与 Alt+Enter 同命令；都闪则排除 Alt 截获）
kitty -e fish; echo "kitty rc=$?"
echo "WAYLAND_DISPLAY=$WAYLAND_DISPLAY XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR HYPRLAND_INSTANCE_SIGNATURE=$HYPRLAND_INSTANCE_SIGNATURE"

# 5) Hyprland 配置健康
hyprctl binds -j | head -50
hyprctl configerrors
```

## 四、dms-ensure.log 消息 → 含义 → 处置

| 日志消息 | 含义 | 处置 |
|---|---|---|
| `plausible dms owner already present` | pre-check 已有 owner（含旧会话残留 marker 且 owner 存活） | 若确认是旧会话残留：注销旧会话或清理 `$XDG_RUNTIME_DIR/danklinux-*` 后重登 |
| `unverifiable at PRE-check` | marker 不可读/owner 状态无法查询 | 手工检查 `ls -la $XDG_RUNTIME_DIR/danklinux-*` 与 `/proc/<pid>/comm` |
| `systemctl ... rc=0` + `plausible (post systemd)` | systemd 正常拉起 DMS | 顶栏若仍无 → 查 qs/journal |
| `systemctl ... rc≠0` + `starting direct fallback` | Requisite 失败走了 daemon 兜底 | 确认 uwsm 已装；fallback 后看 `dms run -d` 的 daemon-child 是否存活 |
| `direct fallback failed` | `dms run -d` 失败（rc=5） | 查 dms 是否在 PATH、journal 中 dms 报错 |
| （空日志 / 无 dms-ensure.log） | helper 未执行（命令未找到 / $HOME 未展开） | 确认 `~/.local/bin/dms-ensure-display` 存在且 755、`$HOME` 已设置 |

## 五、终端闪退的判别结论路径

1. Super+Return 是否同样闪退：是 → 排除 Alt+Enter 宿主截获，锁定 spawn 环境/kitty
   后端；否 → Alt+Enter 被截获（keybinds 已有 Super+Return 备选，可只用 Super+Return）。
2. 手工 `kitty -e fish` 的 rc 与 stderr：非 0 → kitty/fish 启动失败，看具体报错
   （Wayland 连接 / GL 初始化）；0 但窗口消失 → 窗口被合成器/规则关闭（`hyprctl
   configerrors` 与 windowrules 复核）。
3. `WAYLAND_DISPLAY`/`XDG_RUNTIME_DIR` 为空 → spawn 环境问题，修 UWSM/环境导入。
4. 若为 VM（VMware SVGA 3D）→ 按 comprehensive-review 的分层变量法（3D on/off、
   blur on/off）隔离。

## 六、验证完成标准（对应 R4.10 handoff 契约）

- dms.service active、`dms run --session` 恰好一个、qs 恰好一个、bar 可见；
- `dms ipc call settings focusOrToggle` 可用；Super+Return 打开 kitty；
- `hyprctl binds -j` 含仓库绑定；`hyprctl configerrors` 无错误；
- reload 两次不产生双栏；注销回 Niri 无 daemon-child 残留。
