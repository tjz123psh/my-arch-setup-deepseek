# my-arch-setup-deepseek

面向本人 ASUS AMD + NVIDIA 工作站的 Arch Linux 一键恢复配置：重装 Arch、完成基础
安装后，一条命令恢复完整桌面（Niri/Hyprland、软件包、AUR、个人配置与服务）。
支持物理机（ASUS + VMware host）与虚拟机（VMware guest），两机型除硬件驱动与
虚拟化角色外完全一致。

## 在线安装（可直连 GitHub）

```bash
git clone https://github.com/tjz123psh/my-arch-setup-deepseek.git
cd my-arch-setup-deepseek && ./install.sh    # 或 sudo bash strap.sh（root 自动克隆）
```

交互：选机器类型（物理机/虚拟机）→ 选桌面（Niri / Niri+Hyprland / 无）→ 自动分步
安装（断点续传）。AUR 双模式：无缓存 → **在线**（paru 装最新版）；解压离线缓存 →
**离线**（makepkg 固定 recipe，可复现）。

> **基础安装硬前置（03 步逐条硬校验，缺一即中止）**：`linux` 与 `linux-zen` 必须并存
> （archinstall 默认只装一个内核；补装：`pacman -S linux-zen && grub-mkconfig -o /boot/grub/grub.cfg`），
> 另需 `base bash btrfs-progs coreutils gawk grub mkinitcpio networkmanager sed sudo`（共 12 项；
> 详见 [`docs/physical-offline-install.md`](docs/physical-offline-install.md)）。

> **国内网络注意（在线模式）**：构建 Go 写的 AUR 包（`greetd-dms-greeter-git`、`snapd-xdg-open-git`、
> `wooz-git` 等）会走 `GOPROXY`。默认 `proxy.golang.org` 在国内会卡死在依赖下载（2026-09-17 VM 实测超时），
> 因此 payload 会部署 `~/.config/go/env`（`GOPROXY=https://goproxy.cn,direct`）；已有自定义设置请先备份。
> `06-aur` 在线模式还会**自检**：默认代理不可达时自动切到可达镜像（goproxy.cn → goproxy.io → 阿里云），
> 并写回目标用户的 `~/.config/go/env`；若镜像也不可达且本轮有 Go 目标，则**快速失败并给出可执行提示**，
> 不会再无声卡死。已经卡住的现场补救：`go env -w GOPROXY=https://goproxy.cn,direct` 后重跑 `./install.sh`（断点续传）。

## 离线安装（无海外网络）

从 [GitHub Releases](https://github.com/tjz123psh/my-arch-setup-deepseek/releases)
下载两个文件到 U 盘 / 共享文件夹：

| 文件 | 内容 |
|---|---|
| `my-arch-setup.tar` | 仓库代码（安装器，约 80M） |
| `aur-sources-physical.tar.gz` / `aur-sources-vm.tar.gz` | AUR 离线缓存，按机器类型选（tar.gz 约 1.5G / 约 825M；解压后的 `.aur-sources/` 约 1.7G / 964M） |

```bash
tar -xf my-arch-setup.tar -C ~/                        # 得到 ~/my-arch-setup-deepseek/
tar -xzf aur-sources-vm.tar.gz -C ~/my-arch-setup-deepseek/   # 得到 .aur-sources/（物理机换 physical 包）
cd ~/my-arch-setup-deepseek && ./install.sh
```

完整步骤与注意事项（挂载/验证要点/常见坑）：
[`docs/physical-offline-install.md`](docs/physical-offline-install.md)。

## 安装后清理（可选）

进桌面检查无误后，运行 `./cleanup-after-install.sh` 清理安装残留（pacman/cargo/go
构建缓存、离线源缓存，可释放数 GB）；脚本会先列出清单并确认，删除后不可恢复。

## 手工准备项（不在自动恢复范围内）

- **目标用户名为 `pang`**：`config/` 里有 41 个文件硬编码 `/home/pang`（`~/.config` 与
  `~/.local` 下 26 个：niri 键位与 `spawn-at-startup`、截图脚本、fish 的
  `fish_add_path`、七个 systemd user 单元、`ai.vellum.desktop`、fuzzel 的 `include=`、
  gtk bookmarks 等；另有 `scripts/` 5 个、`md/` 10 个），安装器
  **不会**重写这些路径。换用户名安装不会报错，但会得到半可用的桌面；确需换名时装完自行
  `grep -rl /home/pang ~/.config ~/.local/share/applications` 逐一修正。
- **`spring` CLI**（只有 nvim 的 Spring Boot 向导调用）：仓库不分发。需要时把发行包解到
  `~/.local/share/spring/<版本>/`，再建包装器 `~/.local/bin/spring`（`#!/bin/sh` +
  `exec "$HOME/.local/share/spring/<版本>/bin/spring" "$@"`）。

## 其他

- 增改包/配置/脚本：走 `manifests/` 清单 + `./check-extend.sh` 门禁，
  见 [`docs/how-to-extend.md`](docs/how-to-extend.md)
- 验收记录与红线要求：见 [`docs/comprehensive-review-20260807.md`](docs/comprehensive-review-20260807.md)
