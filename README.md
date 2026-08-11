# my-archlinux-setup

面向本人 ASUS AMD + NVIDIA 工作站的 Arch Linux 一键恢复配置：重装 Arch、完成基础
安装（分区/GRUB/首次启动/联网）后，一条命令恢复完整桌面（Niri/Hyprland、软件包、
AUR、个人配置与服务）。

> 增改维护指南见 [`docs/how-to-extend.md`](docs/how-to-extend.md)；产品定位见
> [`docs/project-vision.md`](docs/project-vision.md)。

支持**物理机**（ASUS 完整配置 + VMware host）与**虚拟机**（VMware guest），两机型
除硬件驱动与虚拟化角色外完全一致。验证方案 2026-08-08 起为 VMware。

## 下载与安装

```bash
git clone https://github.com/tjz123psh/my-arch-setup-deepseek.git
cd my-arch-setup-deepseek && ./install.sh   # 或 sudo bash strap.sh（root 自动克隆）
# 非交互示例：./install.sh -d niri -t physical
```

交互流程：选机器类型（物理机/虚拟机）→ 选桌面（Niri / Niri+Hyprland 双会话 / 无）
→ 分步自动安装（断点续传；参数/清单变化拒绝误续传）。

**AUR 双模式**（06 步）：无 `.aur-sources/` 缓存 → **在线**，paru 从 AUR 装最新版
（需网络，版本随上游漂移）；解压了离线缓存 → **离线**，makepkg 构建固定 recipe
（可复现、全离线）。

**离线缓存**（可选，仅无海外网络时用）：GitHub Releases（`aur-cache-*` 标签）按
机器类型下载对应包，解压进仓库目录：

```bash
gh release download --pattern 'aur-sources-physical.tar.gz'   # 物理机（1.6G）；虚拟机换 aur-sources-vm.tar.gz（899M）
tar -xzf aur-sources-physical.tar.gz -C my-arch-setup-deepseek/
```

完整离线安装流程（物理机无海外网络）：[`docs/physical-offline-install.md`](docs/physical-offline-install.md)。

## 安装流程

01 镜像源 → 02 系统基础 → 03 软件包（校验硬交接点）→ 04 显卡驱动（仅物理机）→
05 桌面 → 06 AUR（双模式）→ 07 配置部署 → 08 服务 → 09 系统设置 → 99 清理。
各步细节见 `scripts/`；包数/映射数等以 `./check-extend.sh` reconcile 输出为准。

## 机器类型与模式

两机型共用**同一份**包清单、配置映射、AUR recipe 与服务策略，差异**仅限硬件驱动与
虚拟化角色**：物理机多显卡驱动、vmware-workstation（含 keymaps）、VMware host 服务、
rog 控制配置；虚拟机多 open-vm-tools、vmtoolsd、guest 图形变通。完整差异见
[`docs/comprehensive-review-20260807.md`](docs/comprehensive-review-20260807.md)。

**模式矩阵**：机器类型（`-t vm` / `-t physical`）与 AUR 方式（在线/离线）正交，
共四种模式；**离线模式才有可复现的验收 PASS，在线模式只能验证"能装通"**。

## 项目边界

- 不分区、不格式化、不执行 pacstrap；不接管 GRUB 安装
- 不复制凭据；sudo 授权为最小范围（仅 pacman 免密）
- 登录管理器：greetd（dms-greeter → 按桌面选会话）
- 配置部署前自动备份到 `~/.config-backup-my-arch-*`；拒绝 symlink 越界写入

## 结构

- `install.sh` / `strap.sh`：入口；`scripts/`：01~09 + 99 分步脚本
- `manifests/`：包/配置/AUR 清单（增删包、配置、脚本的入口）
- `config/`：个人配置；`third_party/aur/`：固定 AUR recipe（含审查记录）
- `fetch-aur-sources.sh`：生成离线缓存（`physical|vm` 两档）
- `check-extend.sh`：提交前一键总检（增改门禁，任一节失败禁止提交）
- 详见 [`docs/how-to-extend.md`](docs/how-to-extend.md)

## 物理机部署

archinstall 装好基础（普通用户 + NetworkManager + Wi-Fi；**内核需 `linux-zen` 与
`linux` 并存**，archinstall 默认只装 `linux`）→ clone 或拷 `my-arch-setup.tar`
（无网络见离线指南）→ `./install.sh` 选物理机 → 重启进 niri。
部署后验收：显卡切换、蓝牙、音频、挂起唤醒、ASUS 控制中心、VMware Workstation。

## 验证

- 静态：清单/配置/语法/行为测试全绿（`./check-extend.sh`）。
- 真实验收记录与红线要求见 [`docs/comprehensive-review-20260807.md`](docs/comprehensive-review-20260807.md)；
  Hyprland 会话 DMS 细节见 [`docs/hyprland-dms-host-remediation.md`](docs/hyprland-dms-host-remediation.md)。
- **双模式注意**：在线模式（paru 最新）不可复现；TEST_ID/clean-baseline 语义仅在
  离线模式成立。VMware 验收（VM/仿物理各两轮，同一 payload 四 PASS）完成前不宣称
  "VM 验收完成"。
