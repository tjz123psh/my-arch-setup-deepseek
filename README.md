# my-archlinux-setup

面向本人 ASUS AMD + NVIDIA 工作站的 Arch Linux 一键恢复配置。

重装 Arch、完成基础安装（分区/GRUB/首次启动/联网）后，一条命令恢复完整桌面
环境（Niri / Hyprland、软件包、AUR、个人配置与系统服务）。

> 产品定位与已确认的产品决策见 [`docs/project-vision.md`](docs/project-vision.md)。
> 以后要加软件包/配置/服务/脚本？见 [`docs/how-to-extend.md`](docs/how-to-extend.md)（增改维护指南）。

> 本仓库支持**物理机**（ASUS 完整配置 + VMware Workstation host）与**虚拟机**
> （VMware guest）两种模式：除硬件驱动（04-drivers 仅物理机执行）、虚拟化角色
> 包（host 栈 vs guest 栈）与少量环境适配外，软件包、配置、服务完全一致。
> 项目验证方案 2026-08-08 起为 **VMware**（KVM 已从恢复 payload 移除，历史记录
> 归档于 `docs/archive/kvm-20260808/`）。

## 下载与安装

**代码包**（安装器 + 配置 + 脚本，不含 AUR 缓存，解包约 99M / tar.gz 约 78M）：
- 网页下载：仓库页面 Code → **Download ZIP**（永远是当前最新）
- 或命令行：`git clone https://github.com/tjz123psh/my-arch-setup-deepseek.git`

**AUR 离线缓存**（可选，仅无海外网络时用，约 1G）：存放在仓库的
[GitHub Releases](https://github.com/tjz123psh/my-arch-setup-deepseek/releases)
（`aur-cache-*` 标签），**不在 git clone 里**，需要时单独下载：
```bash
gh release download --pattern 'aur-sources.tar.gz'   # 或在网页点 Releases 下载
# 解压进仓库目录（缓存不联网构建 AUR）：
tar -xzf aur-sources.tar.gz -C my-arch-setup-deepseek/
```

**离线安装完整流程**（物理机无海外网络）：见
[`docs/physical-offline-install.md`](docs/physical-offline-install.md)。

## 使用

```bash
# 方式一：克隆后运行（推荐，可先查看内容）
git clone https://github.com/tjz123psh/my-arch-setup-deepseek.git
cd my-arch-setup-deepseek
./install.sh

# 方式二：strap 入口（自动克隆并执行）
sudo bash strap.sh

# 非交互指定参数
./install.sh -d niri -t physical
# 仿物理测试 profile（VMware guest 内走 physical 分支，硬件效果标记模拟）
./install.sh -d both -t physical --test-profile physical-sim-vmware
```

交互流程：

1. 选择机器类型：物理机（ASUS 完整配置 + VMware host）/ 虚拟机（VMware guest，除硬件驱动及少量环境适配外全量一致）
2. 选择桌面环境：Niri / Hyprland / 双会话 / 不装桌面
3. 自动执行分步安装（每步记录 `.install_progress` 且绑定安装上下文，中断后重跑续传；参数/清单变化时拒绝误续传）

## 它做什么

| 步骤 | 内容 |
| --- | --- |
| 01-mirror | 镜像源优化（8 个国内镜像：阿里/中科大/清华/腾讯/华为/网易/兰大/浙大）+ multilib 启用 |
| 02-system | 基础工具（base-devel/git/python）+ 全系统升级 |
| 03-packages | 校验 12 项硬交接点前置（base/grub/内核/initramfs/文件系统/网络，缺失即中止；可补装工具包已并入安装清单）→ 安装软件包清单（191 安装 = 176 官方/archlinuxcn + 15 AUR；按机器角色与桌面选择过滤模块；驱动包由 04-drivers 专责） |
| 04-drivers | **先装显卡驱动**（物理机：AMD + NVIDIA + ASUS 控制，required 失败即中止；VM 跳过） |
| 05-niri/hyprland | 桌面环境（Niri 或 Hyprland，驱动之后） |
| 06-aur | 构建安装固定 AUR recipe（15 个目标 + vmware-keymaps 依赖先装，共 16 recipe；含 paru/greetd-dms-greeter/vmware-workstation；有 `.aur-sources/` 离线缓存时全离线构建；最终安装失败保留产物并中止） |
| 07-config | 部署个人配置映射（231 映射，先备份；拒绝跟随 symlink 写入 HOME 外；与包同一模块过滤） |
| 08-services | 启用服务：greetd 登录（按桌面选择 dms-greeter→niri/hyprland）+ 用户服务（dms/dsearch）+ 蓝牙/电源/Docker + **VMware host 服务（物理机）/ open-vm-tools（VM）** + GRUB 主题 + paru.conf |
| 09-settings | 系统设置：locale（zh_CN）/时区（上海）/主机名/zram + fish 登录 shell + snapper 快照配置 + 录屏引擎（VM=wf-recorder，物理=wl-screenrec）+ nomacs/PNG MIME 验收 |
| 99-cleanup | 清理缓存与构建目录，恢复 sudo 默认权限 |

## 项目边界

- 不分区、不格式化、不执行 pacstrap
- 不接管 GRUB 安装（grub-install）、内核选择、initramfs（GRUB 主题例外：安装器部署主题 + 设置 GRUB_THEME + 自动 grub-mkconfig 使主题生效）
- 不复制凭据（SSH/GPG/令牌/密码）；安装期间 sudo 授权为最小范围（仅 pacman 免密，EXIT trap 保证清理）
- 登录管理器：安装并启用 greetd（dms-greeter → 按桌面选择会话）
- 配置部署前自动备份到 `~/.config-backup-my-arch-*`；拒绝跟随 symlink 覆盖 HOME 外文件

## 结构

- `strap.sh`：一键入口（root，自动克隆仓库）
- `install.sh`：主安装器（选择 + 分步执行；支持 `--test-profile physical-sim-vmware`）
- `scripts/`：分步脚本（00-utils 公共函数 + 01~09 步骤 + 99 清理）
- `config/`：审阅过的个人配置（330 个文件：.config 映射 + md 知识库 + Pictures + scripts + 字体 + /etc 配置）
- `manifests/`：数据清单（包策略、配置映射、AUR recipe）
- `third_party/aur/`：16 个固定 AUR recipe（含审查记录）
- `fetch-aur-sources.sh`：在有海外网络的机器上生成 AUR 离线缓存（→ `~/Downloads/aur-sources/`）
- `sync-scripts.sh`：同步本机 `~/scripts` 到 `config/home/scripts/` 并自动补映射
- `tests/`：数据完整性校验 + 安装器行为测试（模块矩阵/进度绑定/symlink 安全/失败传播）

## 物理机部署

重装 Arch（archinstall）并完成手工交接点（分区/GRUB/首次启动/联网）后：

1. 用 archinstall 创建普通用户并启用 NetworkManager、连上 Wi-Fi
2. `git clone https://github.com/tjz123psh/my-arch-setup-deepseek.git`
   （无海外网络 clone 不通时，用 U 盘拷贝 `my-arch-setup.tar`，见
   [`docs/physical-offline-install.md`](docs/physical-offline-install.md)）
3. `cd my-arch-setup-deepseek && ./install.sh`
4. 选"物理机"，安装器自动：驱动（AMD+NVIDIA+ASUS 控制，先于桌面）→ 桌面
   → 15 个 AUR（含 VMware Workstation + vmware-keymaps 依赖）→ 配置 → 服务 → 系统设置
5. 装完重启，登录 greetd（dms-greeter）进入 niri

部署后验收：显卡切换（`supergfxctl -m Hybrid` 重启生效）、蓝牙、音频、
挂起唤醒、ASUS 控制中心、VMware Workstation（`vmrun list`/`vmware-networks` 服务、
DKMS 的 vmmon/vmnet）。clash-verge 只安装不启服务（配置私有，手动配置）。

## 验证背景

软件包清单、配置映射与 AUR recipe 均基于真实 ASUS 机器检录，并经过多轮
一次性虚拟机完整安装验证（官方包、archlinuxcn、AUR 构建安装、配置部署、
服务启停均已跑通）。vm 与 physical 两种模式均做过全新重装闭环验证
（batch18/20/21），physical 模式在 VM 内验证驱动/服务路径 10/10。
2026-08-08 起验证方案迁移到 **VMware**：目标为 VM 模式 + 仿物理模式
（`--test-profile physical-sim-vmware`）各两轮独立 clean-baseline 验收（见
`docs/comprehensive-review-20260807.md` 第 12 章）。物理机完整部署留待实机验收。
