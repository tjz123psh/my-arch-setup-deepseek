# Btrfs 快照与滚挂恢复流程

本文记录当前系统的 Snapper / grub-btrfs / quicksave / quickload 使用方式。重点是滚挂后如何从 GRUB 快照启动，并把系统正式恢复到可用状态。

> 当前物理机状态：`root -> /` 和 `home -> /home` 两个 Snapper 配置已创建；`snapper-timeline.timer`、`snapper-cleanup.timer`、`grub-btrfsd.service` 已启用并运行；GRUB 快照菜单文件位于 `/boot/grub/grub-btrfs.cfg`。当前 `/boot` 权限较严格，普通用户读取 GRUB 文件可能失败，涉及 `/boot/grub/*` 的检查以 `sudo` 结果为准。

## 1. 当前结构

当前 Btrfs 子卷分为两部分：

```text
/      -> root 配置 -> @
/home  -> home 配置 -> @home
```

这意味着：

- root 快照保护系统目录，例如 `/etc`、`/usr`、`/var`。
- home 快照保护用户目录，例如 `/home/pang`、浏览器数据、配置文件、下载文件。
- 完整恢复需要同时恢复 root 和 home。

检查配置：

```bash
snapper list-configs
snapper -c root list
snapper -c home list
```

## 2. 手动创建快照

普通使用直接运行：

```bash
quicksave
```

当前系统有 `root` 和 `home` 两个 Snapper 配置，所以 `quicksave` 会同时创建：

```text
root -> /
home -> /home
```

升级或大改配置前建议手动创建一次：

```bash
quicksave -d before-change
```

查看快照：

```bash
quicksave -l
quickload -la
```

## 3. 自动快照

自动快照由 `snapper-timeline.timer` 触发：

```bash
systemctl list-timers 'snapper*' --all
systemctl cat snapper-timeline.timer
```

当前频率设置为：

```ini
OnCalendar=*-*-01/2 04:00:00
```

含义：每月从 1 号开始，每隔 2 天的 04:00 创建一次 timeline 快照。

两个配置都开启了自动快照：

```bash
snapper -c root get-config | rg 'SUBVOLUME|TIMELINE_CREATE|TIMELINE_LIMIT'
snapper -c home get-config | rg 'SUBVOLUME|TIMELINE_CREATE|TIMELINE_LIMIT'
```

自动清理由 `snapper-cleanup.timer` 负责：

```bash
systemctl is-enabled snapper-cleanup.timer
systemctl is-active snapper-cleanup.timer
```

如果未开启：

```bash
sudo systemctl enable --now snapper-cleanup.timer
```

## 4. GRUB 快照菜单

GRUB 中的 `Arch Linux snapshots` 只显示 root 快照。它用于从某个系统快照启动，不会显示 home 快照。

原因是 `/home` 快照不能单独启动系统，只有 root 快照里包含启动系统需要的 `/boot`、`/etc`、`/usr` 等内容。

GRUB 菜单不是实时读取 `snapper list`，而是读取生成文件：

```text
/boot/grub/grub-btrfs.cfg
```

如果 GRUB 里看到的是旧快照，通常是 `grub-btrfsd.service` 没有运行或菜单未刷新。

刷新一次：

```bash
sudo grub-mkconfig -o /boot/grub/grub.cfg
```

启用自动刷新：

```bash
sudo systemctl enable --now grub-btrfsd.service
```

检查：

```bash
systemctl status grub-btrfsd.service
sudo rg 'snapshots|quicksave|timeline|post-migration' /boot/grub/grub-btrfs.cfg
```

## 5. 滚挂后的恢复流程

### 5.1 从 GRUB 启动旧快照

开机进入 GRUB，选择：

```text
Arch Linux snapshots
```

选择一个滚挂前的 root 快照启动。

注意：这一步只是“临时从快照启动”，不是永久回档。

### 5.2 登录快照系统

如果能进桌面，打开终端。

如果进不了桌面，按 `Ctrl+Alt+F2` 或 `Ctrl+Alt+F3` 进入 TTY 登录。

确认当前是否从快照启动：

```bash
findmnt -no SOURCE /
```

如果看到类似：

```text
/dev/sda2[/@/.snapshots/15/snapshot]
```

说明当前正在快照系统里。

### 5.3 执行正式回档

优先使用：

```bash
quickload
```

推荐选择：

```text
全系统恢复
```

这会同时恢复：

```text
root -> /
home -> /home
```

如果只想恢复系统、不动用户目录，选择：

```text
仅恢复系统目录 (root)
```

如果只想恢复用户目录，选择：

```text
仅恢复用户目录 (home)
```

恢复成功后脚本会自动重启。

### 5.4 回到正常系统后检查

确认已经回到正常子卷，而不是仍在快照里：

```bash
findmnt -no SOURCE /
findmnt -no SOURCE /home
```

正常应类似：

```text
/dev/sda2[/@]
/dev/sda2[/@home]
```

再检查快照配置：

```bash
snapper list-configs
snapper -c root list
snapper -c home list
```

## 6. quickload 失败时的手动检查

`quickload` 使用 `btrfs-assistant` 执行实际回档。命令行检查时建议使用无图形环境，避免 Wayland / Qt 环境干扰：

```bash
sudo env -u DISPLAY -u WAYLAND_DISPLAY -u XDG_RUNTIME_DIR btrfs-assistant -l
```

输出类似：

```text
1  @      15  ...  @/.snapshots/15/snapshot
2  @home   3  ...  @home/.snapshots/3/snapshot
```

如果要手动恢复某个条目：

```bash
sudo env -u DISPLAY -u WAYLAND_DISPLAY -u XDG_RUNTIME_DIR btrfs-assistant -r 编号
```

完整恢复通常需要分别恢复 `@` 和 `@home` 对应的快照编号，然后重启。

## 7. 常见误区

### GRUB 里看不到 home 快照

正常。GRUB 只负责从 root 快照启动系统，home 快照不能启动系统。

### 从 GRUB 进快照后文件恢复了，但重启又没了

正常。GRUB 启动快照只是临时进入快照，不是永久回档。必须进入快照后再执行 `quickload`。

### 恢复 root 后 `/home/pang` 文件没变

如果只恢复 root，`/home` 不会改变。要恢复用户目录，需要选择 `全系统恢复` 或 `仅恢复用户目录 (home)`。

### GRUB 里显示旧快照

刷新 GRUB 配置，并确保 `grub-btrfsd.service` 运行：

```bash
sudo grub-mkconfig -o /boot/grub/grub.cfg
sudo systemctl enable --now grub-btrfsd.service
```
