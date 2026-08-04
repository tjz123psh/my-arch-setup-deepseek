# my-archlinux-setup

面向本人 ASUS AMD + NVIDIA 工作站的 Arch Linux 一键恢复配置。

重装 Arch、完成基础安装（分区/GRUB/首次启动/联网）后，一条命令恢复完整桌面
环境（Niri / Hyprland、软件包、AUR、个人配置与系统服务）。

> 本仓库同时支持**物理机**（ASUS 完整配置）与**虚拟机**（轻量配置）两种模式。

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

1. 选择机器类型：物理机（ASUS 完整配置）/ 虚拟机（轻量配置）
2. 选择桌面环境：Niri / Hyprland / 双会话 / 不装桌面
3. 自动执行分步安装（每步记录 `.install_progress`，中断后重跑续传）

## 它做什么

| 步骤 | 内容 |
| --- | --- |
| 01-mirror | 镜像源优化（中国时区自动切阿里云）+ multilib 启用 |
| 02-system | 基础工具（base-devel/git/python）+ 全系统升级 |
| 03-packages | 安装审阅过的软件包清单（物理 171 官方/archlinuxcn + 13 AUR；VM 59 官方/archlinuxcn + 3 AUR） |
| 04-niri/hyprland | 桌面环境（Niri 或 Hyprland） |
| 05-aur | 构建安装固定 AUR recipe（物理 13 个 / VM 3 个，含 paru） |
| 06-config | 部署个人配置映射（物理 171 / VM 36，先备份） |
| 07-services | 启用系统服务（物理机：蓝牙/电源/Docker/libvirt 等） |
| 99-cleanup | 清理缓存与构建目录 |

## 项目边界

- 不分区、不格式化、不执行 pacstrap
- 不接管 GRUB、内核选择、initramfs
- 不复制凭据（SSH/GPG/令牌/密码）
- 不安装登录管理器
- 配置部署前自动备份到 `~/.config-backup-my-arch-*`

## 结构

- `strap.sh`：一键入口（root，自动克隆仓库）
- `install.sh`：主安装器（选择 + 分步执行）
- `scripts/`：分步脚本（00-utils 公共函数 + 01~99 各步骤）
- `config/`：审阅过的个人配置（181 个文件）
- `manifests/`：数据清单（包策略、配置映射、AUR recipe、模块）
- `third_party/aur/`：13 个固定 AUR recipe（含审查记录）
- `tests/`：数据完整性校验

## 验证背景

软件包清单、配置映射与 AUR recipe 均基于真实 ASUS 机器检录，并经过多轮
一次性虚拟机完整安装验证（官方包、archlinuxcn、AUR 构建安装、配置部署、
服务启停均已跑通）。物理机完整部署留待实机验收。
