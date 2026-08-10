# Scripts Index

这个目录保存个人维护脚本。新脚本优先放进明确分类目录，不再直接堆到根目录；命令入口统一放在 `~/.local/bin`，并直接指向分类目录中的真实脚本。

## 目录分类

| 目录 | 内容 | 说明 |
| --- | --- | --- |
| `desktop/` | 桌面环境、窗口管理器、硬件状态入口 | 例如 `niri-keys`、`check-battery` |
| `media/` | 媒体播放、下载、链接处理 | 例如 `b23` |
| `maintenance/` | 系统维护、更新、快照、检查、迁移 | `term-menu`、`sysup`、`clean`、`cache-clean`、`quicksave`、`quickload`、`boot-check`、`checkallupdates`、`gpu-check`、`hw-doctor`、`log-check`、`migration-pack`、`mirror-update`、`pacnew-check`、`recommend-check` |
| `package/` | 包管理 TUI、降级、残留清理、Flatpak/AUR 工具 | 例如 `paru-ui`、`pak`、`pacrrr`、`pacd`、`pacr` |
| `share/prompts/` | 给脚本调用的提示词和共享文档 | 例如 `aur-review.md` |

## 命令入口

`/home/pang/scripts` 根目录不保留脚本入口，避免分类后看起来像重复文件。常用命令由 `~/.local/bin` 软链接到真实脚本：

| 入口 | 实际脚本 |
| --- | --- |
| `~/.local/bin/b23` | `media/b23` |
| `~/.local/bin/check-battery` | `desktop/check-battery` |
| `~/.local/bin/niri-keys` | `desktop/niri-keys` |
| `~/.local/bin/screenshot-sound` | `desktop/screenshot-sound` |
| `~/.local/bin/cache-clean` | `maintenance/cache-clean` |
| `~/.local/bin/pak` | `package/pak` |
| `~/.local/bin/pacd` | `package/pacd` |
| `~/.local/bin/pacr` | `package/pacr` |
| `~/.local/bin/pacrrr` | `package/pacrrr` |
| `~/.local/bin/paru-ui` | `package/paru-ui` |

移动脚本时必须先检查引用：

```bash
rg -n "scripts/|b23|check-battery|niri-keys|sysup|term-menu|paru-ui" \
  ~/.config/fish ~/.config/mpv ~/.bashrc ~/.zshrc ~/.profile ~/.local/bin ~/scripts
find ~/.local/bin -maxdepth 1 -type l -printf '%p -> %l\n'
```

## 高风险脚本

这些脚本会修改系统状态，改动前后必须重点检查确认提示、路径边界和失败回滚：

| 脚本 | 风险点 |
| --- | --- |
| `maintenance/sysup` | 系统升级、AUR、Flatpak、GRUB、镜像源检查 |
| `maintenance/clean` | 删除缓存、孤儿包、日志、回收站、旧快照 |
| `maintenance/cache-clean` | 删除用户级缓存；默认只预览，清理模式需显式选择 |
| `maintenance/mirror-update` | 重写 `/etc/pacman.d/mirrorlist`，依赖备份回滚 |
| `maintenance/quickload` | 恢复 Btrfs 快照，成功后可能重启 |
| `maintenance/quicksave` | 创建或删除 Snapper 快照 |
| `package/pacrrr` | 追踪残留并删除文件，也可卸载软件包 |
| `package/paru-ui` | 安装官方仓库和 AUR 包，AUR 可先走审查 |
| `package/pak` | 安装 Flatpak 应用 |

## 编写规则

- Bash 脚本默认使用 `set -euo pipefail`，数组参数必须保持引用：`"${args[@]}"`。
- 删除文件前必须限制路径范围，并对用户数据、快照、包缓存等操作加二次确认。
- 交互脚本要支持 `-h` 或 `--help`；菜单和预览说明要写真实风险，不写夸张描述。
- 脚本之间互相调用时优先使用同目录解析，避免依赖当前 shell 的 `PATH`。
- 临时文件用 `mktemp` 创建，并用 `trap` 或后台清理逻辑释放。
- 新脚本放入分类目录；如果已有外部入口依赖旧路径，用符号链接或极薄 wrapper 兼容。

## 验证命令

改动脚本后至少执行：

```bash
find ~/scripts -type f -perm -111 -print | sort | xargs -r bash -n
find ~/scripts -type f -perm -111 -print | sort | xargs -r shellcheck -x
find ~/.local/bin -maxdepth 1 -xtype l -print
```

对会写系统的脚本，不要用真实执行流做冒烟测试，优先测 `--help`、`--preview`、只读列表或静态检查。
