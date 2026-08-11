# my-archlinux-setup

面向本人 ASUS AMD + NVIDIA 工作站的 Arch Linux 一键恢复配置。

重装 Arch、完成基础安装（分区/GRUB/首次启动/联网）后，一条命令恢复完整桌面
环境（Niri / Hyprland、软件包、AUR、个人配置与系统服务）。

> 产品定位见 [`docs/project-vision.md`](docs/project-vision.md)；增改维护指南见
> [`docs/how-to-extend.md`](docs/how-to-extend.md)。

支持**物理机**（ASUS 完整配置 + VMware Workstation host）与**虚拟机**（VMware guest）：
除硬件驱动与虚拟化角色外，软件包、配置、服务完全一致（差异点见
[颗粒度表](#机器类型颗粒度vm-vs-物理机)）。项目验证方案 2026-08-08 起为 VMware
（KVM 历史归档于 `docs/archive/kvm-20260808/`）。

## 下载与安装

**代码包**（不含 AUR 缓存，解包约 100M / tar.gz 约 78M）：
- 网页下载：仓库页面 Code → **Download ZIP**
- 命令行：`git clone https://github.com/tjz123psh/my-arch-setup-deepseek.git`

**AUR 安装双模式**（06 步）：无 `.aur-sources/` 缓存 → **在线**，安装器用 paru
从 AUR 装**最新版**（需网络，版本随上游漂移）；解压了离线缓存 → **离线**，makepkg
构建**固定 recipe**（版本可复现、全离线）。

**AUR 离线缓存**（可选，仅无海外网络时用）：按机器类型选对应包，存放在 GitHub
Releases（`aur-cache-*` 标签），**不在 git clone 里**：
- `aur-sources-physical.tar.gz`（物理机，含 vmware-workstation，约 1.6G）
- `aur-sources-vm.tar.gz`（虚拟机，无 vmware，约 900M）

```bash
# 按机器类型下载对应包（或在网页 Releases 点对应资产）：
gh release download --pattern 'aur-sources-physical.tar.gz'   # 物理机
tar -xzf aur-sources-physical.tar.gz -C my-arch-setup-deepseek/
# 虚拟机把包名换成 aur-sources-vm.tar.gz 即可
```

**离线安装完整流程**（物理机无海外网络）：见
[`docs/physical-offline-install.md`](docs/physical-offline-install.md)。

## 使用

```bash
# 方式一：克隆后运行（推荐）
git clone https://github.com/tjz123psh/my-arch-setup-deepseek.git
cd my-arch-setup-deepseek && ./install.sh

# 方式二：strap 入口（root，自动克隆并执行）
sudo bash strap.sh

# 非交互指定参数
./install.sh -d niri -t physical
# 仿物理测试 profile（VMware guest 内走 physical 分支，硬件效果标记模拟）
./install.sh -d both -t physical --test-profile physical-sim-vmware
```

交互流程：选机器类型（物理机/虚拟机）→ 选桌面环境（Niri / Niri+Hyprland 双会话 / 无桌面）
→ 分步自动安装（每步记录 `.install_progress`，中断重跑续传；参数/清单变化拒绝误续传）。
全新基础系统未装 `fzf` 时使用内置编号提示，`fzf` 在软件包阶段按清单安装。

## 它做什么

| 步骤 | 内容 |
| --- | --- |
| 01-mirror | 国内镜像优化（8 个）+ multilib 启用 |
| 02-system | 基础工具 + 全系统升级 |
| 03-packages | 校验硬交接点（base/grub/内核/initramfs/文件系统/网络，缺失即中止）→ 安装软件包清单（pacman + archlinuxcn + AUR，数量以 `./check-extend.sh` reconcile 输出为准；按机型/桌面过滤模块；迁移旧 flclash-bin / clash-verge-rev-bin） |
| 04-drivers | **先装显卡驱动**（物理机：AMD + NVIDIA + ASUS，required 失败中止；VM 跳过） |
| 05-niri/hyprland | 桌面环境（驱动之后） |
| 06-aur | AUR 包安装（双模式见上；目标数随清单变化，以 reconcile 输出为准；最终安装失败保留产物并中止） |
| 07-config | 部署个人配置映射（先备份；拒绝 symlink 写 HOME 外；与包同模块过滤） |
| 08-services | 服务：greetd 登录、dms/dsearch 用户服务、蓝牙/电源/Docker、VMware host 服务（物理机）/ open-vm-tools（VM）、GRUB 主题、paru.conf |
| 09-settings | locale/时区/主机名/zram + fish 登录 shell + snapper 快照 + 录屏（两机型统一 wf-recorder）+ nomacs/PNG MIME 验收 |
| 99-cleanup | 清理缓存与构建目录，恢复 sudo 默认权限 |

## 机器类型颗粒度（VM vs 物理机）

共用**同一份**包清单、配置映射、AUR recipe 与服务策略，差异仅限硬件驱动与虚拟化角色：

| # | 差异项 | 物理机 `-t physical` | 虚拟机 `-t vm` |
| --- | --- | --- | --- |
| 1 | 显卡驱动安装 | ✅ 执行（AMD + NVIDIA + ASUS，required 失败中止） | ⏭️ 跳过 |
| 2 | 硬件驱动包 | 由 04-drivers 安装 | 不安装 |
| 3 | vmware-workstation（+ vmware-keymaps bootstrap） | ✅ AUR 安装 | ❌ 不构建 |
| 4 | open-vm-tools | ❌ | ✅ 安装 |
| 5 | AUR 目标数（随清单变化） | physical = VM + 1 | VM = physical − 1 |
| 6 | rog-control-center.cfg | ✅ 部署 | ❌ 跳过 |
| 7 | VMware host 服务 + DKMS vmmon 检查 | ✅（DKMS 缺失 required 失败） | ❌ |
| 8 | vmtoolsd | ❌ | ✅（required） |
| 9 | 录屏引擎 | 两机型统一 wf-recorder | 同左 |
| 10 | VMware guest 图形变通（`LIBGL_ALWAYS_SOFTWARE=1`） | ❌ | ✅ 仅 VMware guest |

**完全一致**：包清单主体、配置映射（同一 `physical-v1` 全量）、镜像源、服务与定时器
（bluetooth/power-profiles/docker/NetworkManager/grub-btrfsd/timesyncd、paccache/
snapper/btrfs-scrub）、greetd 登录、snapper 快照、fish、GRUB 主题、locale/时区/zram。

**模式矩阵（机器类型 × 安装方式）**：机器类型（`-t`）与 AUR 安装方式（缓存有无）是
正交维度，组合出四种模式：

| 模式 | 06-aur 分流 | 构建方式 |
| --- | --- | --- |
| 物理机 + 在线 / VM + 在线 | ONLINE | paru 拉最新（需网络，不可复现） |
| 物理机 + 离线 / VM + 离线 | OFFLINE | makepkg 固定 recipe（可复现） |

可复现性：**离线模式**才有"同一 payload"的可复现 PASS；**在线模式**只能验证
"能装通"（见[验证背景](#验证背景)）。

**仿物理测试 profile**（`-t physical --test-profile physical-sim-vmware`）：仅限
VMware guest 内使用（`systemd-detect-virt` 必须为 vmware），走完整 physical 分支，
host-only 动作标记 `NOT_APPLICABLE_SIMULATED`；不能替代真实物理机验收。

## 项目边界

- 不分区、不格式化、不执行 pacstrap
- 不接管 GRUB 安装（grub-install）、内核选择、initramfs（GRUB 主题例外）
- 不复制凭据（SSH/GPG/令牌/密码）；sudo 授权为最小范围（仅 pacman 免密，EXIT trap 清理）
- 登录管理器：安装并启用 greetd（dms-greeter → 按桌面选择会话）
- 配置部署前自动备份到 `~/.config-backup-my-arch-*`；拒绝 symlink 覆盖 HOME 外文件

## 结构

- `strap.sh` / `install.sh`：入口（root 自动克隆 / 主安装器，支持 `--test-profile`）
- `scripts/`：分步脚本（00-utils 公共函数 + 01~09 步骤 + 99 清理）
- `config/`：个人配置（.config 映射 + md 知识库 + Pictures + scripts + 字体 + /etc）
- `manifests/`：数据清单（包策略、配置映射、AUR recipe）——增删包/配置/脚本的入口
- `third_party/aur/`：固定 AUR recipe 树（含审查记录）
- `fetch-aur-sources.sh`：在有海外网络的机器上生成 AUR 离线缓存（→ `~/Downloads/aur-sources/`）
- `sync-scripts.sh` / `sync-config-mappings.sh`：宿主 → 仓库同步工具（自动补映射）
- `check-extend.sh`：提交前一键总检（增改门禁：bash 语法/shellcheck/清单一致性/配置语法/
  recipe 双向引用/secret scan/README 数字/行为测试；只改数据文档自动快速 8 节，改脚本全量
  13 节；任一节失败禁止提交）
- `tests/`：清单完整性、迁移契约、安装器行为、配置语法、门禁自证等测试套件

## 物理机部署

重装 Arch（archinstall）并完成手工交接点（分区/GRUB/首次启动/联网）后：

1. archinstall 创建普通用户并启用 NetworkManager、连上 Wi-Fi
   **（内核：需同时装 `linux-zen` 与 `linux`——archinstall 默认只装 `linux`，或装完补
   `pacman -S linux-zen && grub-mkconfig -o /boot/grub/grub.cfg`；verify 前置清单见
   `manifests/workstation-packages.tsv` 的 `verify` 行）**
2. `git clone https://github.com/tjz123psh/my-arch-setup-deepseek.git`
   （无海外网络时用 U 盘拷贝 `my-arch-setup.tar`，见
   [`docs/physical-offline-install.md`](docs/physical-offline-install.md)）
3. `cd my-arch-setup-deepseek && ./install.sh`，选"物理机"
4. 安装器自动：驱动（先于桌面）→ 桌面 → AUR → 配置 → 服务 → 系统设置
5. 重启，登录 greetd（dms-greeter）进入 niri

部署后验收：显卡切换（`supergfxctl -m Hybrid`）、蓝牙、音频、挂起唤醒、ASUS 控制中心、
VMware Workstation（`vmrun list` / `vmware-networks` / DKMS vmmon/vmnet）。
clash-verge-rev 只安装不启服务（配置私有，手动配置）。

## 验证背景

> **双模式注意**：在线模式（paru 最新）安装结果随上游漂移、**不可复现**；
> TEST_ID/clean-baseline 的"同一最终 payload"验收语义仅在**离线模式**（固定 recipe）
> 下成立。VM 验收以离线模式为准；在线模式只验证"能装通"。

- 静态验证：清单、配置映射、Niri/Hyprland 语法、行为测试均已复核（`./check-extend.sh` 全绿）。
- 真实运行时验收记录（VMware clean-baseline 安装、DMS/Hyprland 会话验证）见
  [`docs/comprehensive-review-20260807.md`](docs/comprehensive-review-20260807.md)；
  Hyprland 会话 DMS 启动细节与诊断见
  [`docs/hyprland-dms-host-remediation.md`](docs/hyprland-dms-host-remediation.md)。
- 验收门槛：VMware guest 的 VM 模式与仿物理模式各需两轮（同一最终 payload 四个 PASS），
  按 TEST_ID/clean-baseline 规则记录；未取得前不得宣称"VM 验收完成"。
