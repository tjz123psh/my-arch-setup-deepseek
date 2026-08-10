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
| `hypr-quit` | Hyprland 退出确认菜单（同上，确认后 `hyprctl dispatch exit`） |
| `niri-vmtest-gen` | 生成 niri VM 测试配置（快捷键全禁，只留 Win+Shift+D 开关键） |
| `hypr-vmtest-gen` | 生成 Hyprland VM 测试配置（同上） |
| `hypr-vmtest-toggle` | 切换 Hyprland 正常 / VM 测试配置（符号链接 + `hyprctl reload`） |
| `hypr-magnifier` | Hyprland 原生屏幕放大镜（1x → 2x → 3x 循环，不走截屏回环） |
| `screenshot-sound` | 截图快门音效服务（截图键上膛，剪贴板出现图片时播放快门声） |
