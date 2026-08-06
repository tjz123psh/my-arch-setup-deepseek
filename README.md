# my-archlinux-setup

面向本人 ASUS AMD + NVIDIA 工作站的 Arch Linux 一键恢复配置。

重装 Arch、完成基础安装（分区/GRUB/首次启动/联网）后，一条命令恢复完整桌面
环境（Niri / Hyprland、软件包、AUR、个人配置与系统服务）。

> 产品定位与已确认的产品决策见 [`docs/project-vision.md`](docs/project-vision.md)。

> 本仓库同时支持**物理机**（ASUS 完整配置）与**虚拟机**（除显卡驱动外全量一致）两种模式。

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
```

交互流程：

1. 选择机器类型：物理机（ASUS 完整配置）/ 虚拟机（除显卡驱动外全量）
2. 选择桌面环境：Niri / Hyprland / 双会话 / 不装桌面
3. 自动执行分步安装（每步记录 `.install_progress`，中断后重跑续传）

## 它做什么

| 步骤 | 内容 |
| --- | --- |
| 01-mirror | 镜像源优化（阿里/中科大/清华多镜像）+ multilib 启用 |
| 02-system | 基础工具（base-devel/git/python）+ 全系统升级 |
| 03-packages | 安装软件包清单（物理与 VM 一致：173 官方/archlinuxcn + 14 AUR，按桌面选择过滤 wm 专用包；驱动包由 04-drivers 专责） |
| 04-drivers | **先装显卡驱动**（物理机：AMD + NVIDIA + ASUS 控制；VM 跳过） |
| 05-niri/hyprland | 桌面环境（Niri 或 Hyprland，驱动之后） |
| 06-aur | 构建安装固定 AUR recipe（14 个，全部自动下载，含 paru/greetd-dms-greeter） |
| 07-config | 部署个人配置映射（物理与 VM 一致 225 映射，先备份） |
| 08-services | 启用服务：greetd 登录（dms-greeter→niri）+ 蓝牙/电源/Docker/libvirt 等（物理与 VM 一致） |
| 09-settings | 系统设置：locale（zh_CN）/时区（上海）/主机名/zram |
| 99-cleanup | 清理缓存与构建目录 |

## 项目边界

- 不分区、不格式化、不执行 pacstrap
- 不接管 GRUB 安装（grub-install）、内核选择、initramfs（GRUB 主题例外：安装器部署主题 + 设置 GRUB_THEME + 自动 grub-mkconfig 使主题生效）
- 不复制凭据（SSH/GPG/令牌/密码）
- 登录管理器：安装并启用 greetd（dms-greeter → niri 会话）
- 配置部署前自动备份到 `~/.config-backup-my-arch-*`

## 结构

- `strap.sh`：一键入口（root，自动克隆仓库）
- `install.sh`：主安装器（选择 + 分步执行）
- `scripts/`：分步脚本（00-utils 公共函数 + 01~09 步骤 + 99 清理）
- `config/`：审阅过的个人配置（325 个文件：.config 映射 + md 知识库 + Pictures + /etc 配置）
- `manifests/`：数据清单（包策略、配置映射、AUR recipe）
- `third_party/aur/`：14 个固定 AUR recipe（含审查记录）
- `tests/`：数据完整性校验

## 物理机部署

重装 Arch（archinstall）并完成手工交接点（分区/GRUB/首次启动/联网）后：

1. 用 archinstall 创建普通用户并启用 NetworkManager、连上 Wi-Fi
2. `git clone https://github.com/tjz123psh/my-arch-setup-deepseek.git`
3. `cd my-arch-setup-deepseek && ./install.sh`
4. 选"物理机"，安装器自动：驱动（AMD+NVIDIA+ASUS 控制，先于桌面）→ 桌面
   → 14 个 AUR → 配置 → 服务 → 系统设置
5. 装完重启，登录 greetd（dms-greeter）进入 niri

部署后验收：显卡切换（`supergfxctl -m Hybrid` 重启生效）、蓝牙、音频、
挂起唤醒、ASUS 控制中心。clash-verge 只安装不启服务（配置私有，手动配置）。

## 验证背景

软件包清单、配置映射与 AUR recipe 均基于真实 ASUS 机器检录，并经过多轮
一次性虚拟机完整安装验证（官方包、archlinuxcn、AUR 构建安装、配置部署、
服务启停均已跑通）。物理机完整部署留待实机验收。
