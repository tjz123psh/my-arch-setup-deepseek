# my-archlinux-setup

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

## 离线安装（无海外网络）

从 [GitHub Releases](https://github.com/tjz123psh/my-arch-setup-deepseek/releases)
下载两个文件到 U 盘 / 共享文件夹：

| 文件 | 内容 |
|---|---|
| `my-arch-setup.tar` | 仓库代码（安装器，78M） |
| `aur-sources-physical.tar.gz` / `aur-sources-vm.tar.gz` | AUR 离线缓存，按机器类型选（1.6G / 899M） |

```bash
tar -xf my-arch-setup.tar -C ~/                        # 得到 ~/my-arch-setup-deepseek/
tar -xzf aur-sources-vm.tar.gz -C ~/my-arch-setup-deepseek/   # 得到 .aur-sources/（物理机换 physical 包）
cd ~/my-arch-setup-deepseek && ./install.sh
```

完整步骤与注意事项（挂载/验证要点/常见坑）：
[`docs/physical-offline-install.md`](docs/physical-offline-install.md)。

## 其他

- 增改包/配置/脚本：走 `manifests/` 清单 + `./check-extend.sh` 门禁，
  见 [`docs/how-to-extend.md`](docs/how-to-extend.md)
- 验收记录与红线要求：见 [`docs/comprehensive-review-20260807.md`](docs/comprehensive-review-20260807.md)
