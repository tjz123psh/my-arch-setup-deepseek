# desktop —— 桌面环境辅助脚本

## 一、是什么

双窗口管理器（niri 与 Hyprland）共用的桌面辅助脚本集合，覆盖权限、快捷键速查、退出确认、VM 测试模式、截图反馈等日常操作。

## 二、有什么作用

| 脚本 | 作用 |
|---|---|
| `gsudo` | 图形化 sudo：用 fuzzel 弹框输入密码后执行命令（`sudo -A`） |
| `fuzzel-askpass` | gsudo 的 `SUDO_ASKPASS` 助手：fuzzel 弹出掩码密码输入框 |
| `niri-keys` | niri 快捷键速查（解析 keybinds.kdl，kitty + fzf 交互搜索） |
| `hypr-keys` | Hyprland 快捷键速查（读取 keybinds.list 清单） |
| `niri-quit` | niri 退出确认菜单（term-menu 同款 fzf 界面，默认选中「取消」） |
| `hypr-quit` | Hyprland 退出确认菜单（同上；Win+Shift+E 触发，确认后 `hyprctl dispatch 'hl.dsp.exit()'`） |
| `niri-vmtest-gen` | 生成 niri VM 测试配置（快捷键全禁，只留 Win+Shift+D 开关键） |
| `hypr-vmtest-gen` | 生成 Hyprland VM 测试配置（同上） |
| `hypr-vmtest-toggle` | 切换 Hyprland 正常 / VM 测试配置（符号链接 + `hyprctl reload`） |
| `hypr-magnifier` | Hyprland 原生屏幕放大镜（1x → 2x → 3x 循环，不走截屏回环） |
| `niri-touchpad-toggle` | 开关内置触摸板（Fn+F10 / XF86TouchpadToggle；改写 `~/.config/niri/touchpad-state.kdl` 的 `off` 行后重载 niri 配置） |
| `hypr-touchpad-toggle` | 开关内置触摸板（Fn+F10 / XF86TouchpadToggle；`hyprctl eval` 改设备 `enabled`，状态存 `~/.config/hypr/touchpad-state.lua`） |
| `screenshot-sound` | 截图快门音效服务（截图键上膛，剪贴板出现图片时播放快门声） |
| `dms-wait-network` | `dms.service` 的 ExecStartPre：等网络后端抢到 D-Bus 名字再启动 DMS，最多 10s（修控制中心网络列表开机后空白） |

## 三、VM 测试模式（Win+Shift+D）

按 `Win+Shift+D` 进入/退出：进入后 host 快捷键全部禁用（按键透传给 VM），只留同一个键返回。

- **niri**：`Mod+Shift+D` 直接 `niri msg action load-config-file --path` 在
  `config.kdl` / `config.kdl.vmtest` 之间切换。
- **Hyprland**：`~/.config/hypr/hyprland.lua` 是指向 `hyprland.lua.normal`（正常）或
  `hyprland.lua.vmtest`（测试）的符号链接，由 `hypr-vmtest-toggle enter|leave` 原子换链后
  `hyprctl reload` 生效。**改配置请编辑 `hyprland.lua.normal`**（编辑 `hyprland.lua` 会跟随链接写到同一文件）。
- 改过正常配置后，跑一次 `niri-vmtest-gen` / `hypr-vmtest-gen` 刷新测试副本。
  两个生成脚本都带安全网：正常配置结构不符或校验（`niri validate` / `luac -p`）不通过时
  会中止并保留原测试配置，不会写出「测试模式仍加载全部快捷键」的假配置。

## 四、触摸板开关（Fn+F10）

ASUS TUF A15 的 Fn+F10 由 asus-wmi 驱动上报为 `KEY_TOUCHPAD_TOGGLE`（驱动内 `0x6B`），
但 niri 和 Hyprland 都没有对应的内置动作，故各自用脚本实现，绑定名都是 `XF86TouchpadToggle`。

| 会话 | 脚本 | 机制 | 状态存放 |
|---|---|---|---|
| niri | `niri-touchpad-toggle` | 改 `~/.config/niri/touchpad-state.kdl` 的 `off` 行后重载配置（`input.touchpad.off`） | 配置文件本身 |
| Hyprland | `hypr-touchpad-toggle` | `hyprctl eval` 设该设备 `enabled`，不必 reload | `~/.config/hypr/touchpad-state.lua` |

- 两者都是 libinput 层面的挂起（`send-events=disabled`），与 GNOME / KDE 同机制。
- 两个脚本会互相同步状态文件，所以在任一会话切换，另一会话重启后保持一致。
- 都支持 `on` / `off` / `status` 子命令，切换时有桌面通知。
- Hyprland 侧设备名写死在脚本里（`asuf1204:00-2808:0202-touchpad`），可用
  `HYPR_TOUCHPAD_DEVICE` 覆盖；niri 侧只支持 `touchpad` 这一整类设备（niri 尚无按设备配置）。
