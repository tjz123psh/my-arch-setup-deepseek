# my-archlinux-setup

面向本人 ASUS AMD + NVIDIA 工作站的 Arch Linux 一键恢复配置：重装 Arch、完成基础
安装后，一条命令恢复完整桌面（Niri/Hyprland、软件包、AUR、个人配置与服务）。

支持**物理机**（ASUS + VMware host）与**虚拟机**（VMware guest），两机型除硬件驱动
与虚拟化角色外完全一致。验证方案 2026-08-08 起为 VMware。

## 使用

```bash
git clone https://github.com/tjz123psh/my-arch-setup-deepseek.git
cd my-arch-setup-deepseek && ./install.sh    # 或 sudo bash strap.sh
./install.sh -d niri -t physical             # 非交互示例
```

交互：选机器类型（物理机/虚拟机）→ 选桌面（Niri / Niri+Hyprland / 无）→ 自动分步
安装（断点续传）。

**AUR 双模式**：无 `.aur-sources/` 缓存 → **在线**（paru 装最新版，需网络，不可复现）；
解压离线缓存 → **离线**（makepkg 固定 recipe，可复现、全离线）。

**离线安装**（无海外网络）：GitHub Releases 下载对应机型缓存包（`aur-sources-physical`
/ `aur-sources-vm`）解压进仓库，完整步骤见
[`docs/physical-offline-install.md`](docs/physical-offline-install.md)。

## 说明

- **机器类型**：两机型共用同一份包/配置/服务，差异仅限硬件驱动与虚拟化角色
  （物理机：显卡驱动、vmware-workstation、VMware host 服务；虚拟机：open-vm-tools、
  vmtoolsd、guest 图形变通）。模式矩阵 = 机器类型 × 在线/离线，共四种。
- **边界**：不分区/不 pacstrap/不接管 GRUB；不复制凭据；配置部署前自动备份。
- **增改**（包/配置/脚本）：走 `manifests/` 清单 + `./check-extend.sh` 门禁，
  详见 [`docs/how-to-extend.md`](docs/how-to-extend.md)。
- **验收**：离线模式才有可复现 PASS；VMware 四轮验收完成前不宣称"VM 验收完成"，
  记录见 [`docs/comprehensive-review-20260807.md`](docs/comprehensive-review-20260807.md)。
