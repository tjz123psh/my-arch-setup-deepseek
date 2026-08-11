# 离线安装指南（无海外网络）

适用：重装 Arch（archinstall 完成分区/GRUB/联网）后，**无海外网络**（GitHub/codeberg
直连不通）环境离线恢复。镜像走国内源，AUR 全离线构建。

## 需要的两个文件（拷进 U 盘 / 共享文件夹）

| 文件 | 内容 | 大小 |
|---|---|---|
| `my-arch-setup.tar` | 仓库代码（安装器 + 配置 + 清单 + AUR recipe） | 78M |
| `aur-sources-physical.tar.gz`（物理机）/ `aur-sources-vm.tar.gz`（虚拟机） | AUR 离线缓存（全部源码 + 构建依赖，解压为 `.aur-sources/`） | 1.6G / 899M |

获取：
- 仓库：`cd ~/Projects && tar --exclude='.git' --exclude='.aur-sources' --exclude='artifacts' --exclude='.install_logs' --exclude='.ai' -czf my-arch-setup.tar my-arch-setup-deepseek`
- 缓存：`./fetch-aur-sources.sh physical|vm` 生成，或从 GitHub Releases（`aur-cache-*`）下载对应机型包

## 目标机安装（tty）

```bash
# ① 挂载 U 盘或共享文件夹（VMware hgfs 示例）
sudo mkdir -p /mnt/hgfs && sudo vmhgfs-fuse .host:/ /mnt/hgfs -o allow_other

# ② 解包仓库 → ~/my-arch-setup-deepseek/
tar -xf /mnt/hgfs/test/my-arch-setup.tar -C ~/

# ③ 解压缓存进仓库 → .aur-sources/（触发 06 离线模式）
tar -xzf /mnt/hgfs/test/aur-sources-physical.tar.gz -C ~/my-arch-setup-deepseek/

# ④ 确认缓存就位
ls -d ~/my-arch-setup-deepseek/.aur-sources

# ⑤ 联网（仅国内镜像即可）+ 安装
curl -m 5 -s -o /dev/null -w "%{http_code}\n" https://mirrors.aliyun.com   # 期望 200
cd ~/my-arch-setup-deepseek && ./install.sh -d both -t physical    # 虚拟机用 -t vm
```

## 验证离线模式生效（06-aur 阶段）

- 横幅：`★ AUR MODE: OFFLINE — makepkg pinned recipes ★`
- 日志：`Using local AUR source cache: ... (offline mode)`，makepkg 构建、无 `Downloading`
- 装完：`cat ~/my-arch-setup-deepseek/.install_logs/06-aur.log` 应显示 `mode=offline`

## 注意事项

- **archinstall 基础安装时内核需 `linux-zen` 与 `linux` 并存**（默认只装 `linux`，03 硬性前置要求；可装完补 `pacman -S linux-zen && grub-mkconfig -o /boot/grub/grub.cfg`）
- **打包结构**：仓库 tar 必须带顶层目录（`my-arch-setup-deepseek/`）；缓存 tar 顶层必须是
  `.aur-sources/`。否则解压散文件、离线模式不触发（06 会走在线 paru）
- 全程一次 sudo 密码（安装器最小授权，装完自动恢复）
- 某 AUR 构建失败自动重试一次；仍失败报错退出，网络恢复后重跑 `./install.sh` 续传
- 旧系统 `flclash-bin` 由 03 显式迁移到 archlinuxcn/flclash
- `strap.sh` 依赖 GitHub 直连，无海外网络时用本指南的 U 盘/共享方式
