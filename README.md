# my-archlinux-setup

面向本人 ASUS AMD + NVIDIA 工作站的 Arch Linux 一键恢复配置。

重装 Arch、完成基础安装（分区/GRUB/首次启动/联网）后，一条命令恢复完整桌面
环境（Niri / Hyprland、软件包、AUR、个人配置与系统服务）。

> 产品定位与已确认的产品决策见 [`docs/project-vision.md`](docs/project-vision.md)。
> 以后要加软件包/配置/服务/脚本？见 [`docs/how-to-extend.md`](docs/how-to-extend.md)（增改维护指南）。

> 本仓库支持**物理机**（ASUS 完整配置 + VMware Workstation host）与**虚拟机**
> （VMware guest）两种模式：除硬件驱动与虚拟化角色（host 栈 vs guest 栈）外，
> 软件包、配置、服务完全一致。全部差异点见
> [机器类型颗粒度](#机器类型颗粒度vm-vs-物理机)。
> 项目验证方案 2026-08-08 起为 **VMware**（KVM 已从恢复 payload 移除，历史记录
> 归档于 `docs/archive/kvm-20260808/`）。

## 下载与安装

**代码包**（安装器 + 配置 + 脚本，不含 AUR 缓存，解包约 99M / tar.gz 约 78M）：
- 网页下载：仓库页面 Code → **Download ZIP**（永远是当前最新）
- 或命令行：`git clone https://github.com/tjz123psh/my-arch-setup-deepseek.git`

> **AUR 安装双模式**（06 步）：无 `.aur-sources/` 缓存（git clone / ZIP 直接装）
> → **在线模式**，安装器用 paru 从 AUR 装**最新版**（需网络，版本随上游漂移）；
> 解压了离线缓存 → **离线模式**，makepkg 构建**固定 recipe**（版本可复现、全离线）。

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

1. 选择机器类型：物理机（ASUS 完整配置 + VMware host）/ 虚拟机（VMware guest，除硬件驱动与虚拟化角色外全量一致，详见[颗粒度对照](#机器类型颗粒度vm-vs-物理机)）
2. 选择桌面环境：Niri / Niri + Hyprland（双会话）/ 不装桌面（纯 Hyprland 独立入口已移除，Hyprland 仅在双会话模式下从 greetd 会话菜单选择）
3. 自动执行分步安装（每步记录 `.install_progress` 且绑定安装上下文，中断后重跑续传；参数/清单变化时拒绝误续传）

全新基础系统若尚未安装 `fzf`，安装器会直接使用内置的编号提示；这是预期的首次运行路径，不会在镜像配置前提前执行 pacman。`fzf` 会在后续软件包阶段按清单安装。

## 它做什么

| 步骤 | 内容 |
| --- | --- |
| 01-mirror | 镜像源优化（8 个国内镜像：阿里/中科大/清华/腾讯/华为/网易/兰大/浙大）+ multilib 启用 |
| 02-system | 基础工具（base-devel/git/python）+ 全系统升级 |
| 03-packages | 校验 12 项硬交接点前置（base/grub/内核/initramfs/文件系统/网络，缺失即中止；可补装工具包已并入安装清单）→ 安装软件包清单（安装项 = pacman（含 archlinuxcn）+ AUR，数量随清单变化、以 `./check-extend.sh` reconcile 输出为准；按机器角色与桌面选择过滤模块；驱动包由 04-drivers 专责；会显式迁移旧 flclash-bin / clash-verge-rev-bin） |
| 04-drivers | **先装显卡驱动**（物理机：AMD + NVIDIA + ASUS 控制，required 失败即中止；VM 跳过） |
|  05-niri/hyprland | 桌面环境（Niri 或 Niri+Hyprland 双会话，驱动之后） |
| 06-aur | AUR 安装双模式：**在线**（无 `.aur-sources/` 缓存，git clone 场景）用 paru 从 AUR 装**最新版**（`--noconfirm --skipreview` 全自动，装后按清单精确验收）；**离线**（解压了缓存）用 makepkg 构建固定 recipe（`SRCDEST` 指向缓存全离线，bulk `pacman -U` 单 sudo 安装；vmware-keymaps 依赖仅 physical 时先 bootstrap）。目标数与 recipe 树数随清单变化、以 `./check-extend.sh` reconcile 输出为准；含 paru/greetd-dms-greeter/vmware-workstation；最终安装失败保留产物并中止） |
| 07-config | 部署个人配置映射（映射数随清单变化、以 `./check-extend.sh` reconcile 输出为准；先备份；拒绝跟随 symlink 写入 HOME 外；与包同一模块过滤） |
| 08-services | 启用服务：greetd 登录（`--command niri` 只选择渲染登录界面的 greeter compositor，**不决定用户默认会话**；目标会话由会话菜单与 remembered session 决定，Hyprland 用系统 stock 入口 `hyprland.desktop`（`start-hyprland`，R5 对齐物理机；uwsm/`hyprland-uwsm.desktop` 已从安装清单移除），cleanup 后按 target XDG_DATA_HOME/XDG_DATA_DIRS 校验实际解析的 `hyprland.desktop`，用户/local override 存在则 fail-closed）+ 用户服务（dms/dsearch；`DESKTOP_ENV=none` 时跳过桌面链并收敛 disable greetd/dms/dsearch，含 postcondition 校验）+ 旧 Round-2/3 残留迁移清理（逐级 lstat 路径安全、仅精确哈希项目文件备份删除——唯一备份、root/strap 下递归 chown 中间目录、任何 ownership 失败不删原文件；R2 watcher/drop-in 检测警告）+ 蓝牙/电源/Docker + **VMware host 服务（物理机）/ open-vm-tools（VM）** + GRUB 主题 + paru.conf |
| 09-settings | 系统设置：locale（zh_CN）/时区（上海）/主机名/zram + fish 登录 shell + snapper 快照配置 + 录屏引擎（两机型统一 wf-recorder：默认轻档 preset=fast/crf=18；**物理机安装时 VAAPI 探测通过则自动预置 h264_vaapi**（GPU 编码，qp=18 恒定质量、零 CPU、144Hz 不掉帧），VM/仿物理保持 libx264；libx264 时画质菜单可切 3 档；wl-screenrec-git 已自 archlinuxcn 下架且 ffmpeg9 ABI 不兼容）+ nomacs/PNG MIME 验收 |
| 99-cleanup | 清理缓存与构建目录，恢复 sudo 默认权限 |

## 机器类型颗粒度（VM vs 物理机）

两种模式共用**同一份**包清单、配置映射、AUR recipe 与服务策略，差异**仅限硬件驱动与虚拟化角色**。下表是全部差异点（代码位置），其余一切两机型一致。

| # | 差异项 | 物理机 `-t physical` | 虚拟机 `-t vm` | 代码位置 |
|---|---|---|---|---|
| 1 | 显卡驱动安装 | ✅ 执行（AMD iGPU + NVIDIA dGPU + ASUS 控制，required 失败中止） | ⏭️ 跳过（无真实 GPU） | 04-drivers.sh |
| 2 | 硬件驱动包（graphics-*/hardware-tools/asus-hardware 模块） | 由 04-drivers 安装 | 不安装 | 03-packages / module_selected |
| 3 | VMware host 栈包（vmware-workstation） | ✅ 安装（AUR；vmware-keymaps 依赖先 bootstrap） | ❌ 不构建不安装 | 06-aur.sh（按 module_selected 过滤） |
| 4 | VMware guest 工具（open-vm-tools） | ❌ 不安装 | ✅ 安装 | 03-packages（vmware-guest 模块） |
| 5 | AUR 目标数（随清单变化，以 reconcile 输出为准） | physical = VM + 1（含 vmware-workstation；另 bootstrap vmware-keymaps） | VM = physical − 1（无 vmware-workstation/keymaps） | 06-aur.sh（module_selected 过滤） |
| 6 | 硬件配置（rog-control-center.cfg） | ✅ 部署 | ❌ 跳过 | 07-config（ctx=config） |
| 7 | VMware host 服务（vmware-networks / vmware-usbarbitrator）+ DKMS vmmon 检查 | ✅ 启用，DKMS 缺失 required 失败 | ❌ 不启用 | 08-services.sh |
| 8 | VMware guest 服务（vmtoolsd） | ❌ 不启用 | ✅ 启用（required） | 08-services.sh |
| 9 | ~~录屏引擎预设~~（已无差异：2026-08-09 两机型统一 `wf-recorder`；`wl-screenrec-git` 自 archlinuxcn 下架且 ffmpeg9 ABI 不兼容） | `wf-recorder`（CPU） | `wf-recorder`（CPU） | 09-settings.sh |
| 10 | VMware guest 图形变通（上游 Hyprland#7658：aquamarine 无法导入 mesa/vmwgfx dma-buf，GL 客户端 `wl_surface.attach: invalid arguments` 崩溃；`LIBGL_ALWAYS_SOFTWARE=1` 使客户端走 llvmpipe/wl_shm 可导入） | ❌ 不写入（保留硬件 GL） | ✅ 仅 VMware guest 写入 `/etc/environment`（`systemd-detect-virt == vmware` 时，物理机/其他虚拟化不写） | 09-settings.sh + 00-utils（is_vmware_guest / apply_vmware_graphics_workaround） |

**完全一致的部分**（不做任何区分）：

- 包清单主体（除上表 2–5 的虚拟化/硬件模块外）
- 配置映射（同一 `physical-v1` 全量映射；VM 不部署的仅上表第 6 项）
- 镜像源配置（01-mirror：同一 CN 8 镜像列表，清华首位，前 3 探活任一可达即写；反射/离线回退逻辑两机型一致）
- 服务与定时器：bluetooth / power-profiles / docker / NetworkManager / grub-btrfsd / timesyncd、paccache / snapper-cleanup / snapper-timeline / btrfs-scrub
- greetd 登录（dms-greeter 默认 niri；both 模式会话菜单可切 Hyprland）
- snapper root+home 快照初始化、fish 登录 shell、GRUB 主题、locale/时区/zram、nomacs PNG MIME 验收

**仿物理测试 profile**（`-t physical --test-profile physical-sim-vmware`）：仅允许在 VMware guest 内使用（`systemd-detect-virt` 必须为 `vmware`，否则中止）；走完整 physical 包/配置/AUR 分支，但 host-only 动作（host 网络、USB arbitration、硬件模式切换）记录为 `NOT_APPLICABLE_SIMULATED`，不实际执行。此 profile 不能替代真实物理机验收。

**模式矩阵（机器类型 × 安装方式）**：机器类型（`-t vm` / `-t physical`）与 AUR 安装方式（在线 paru / 离线 makepkg）是两个正交维度，组合出四种模式：

| 模式 | 机器类型 | 06-aur 分流 | AUR 目标 | 构建方式 |
| --- | --- | --- | --- | --- |
| VM + 在线 | `-t vm` | ONLINE | VM 清单（不含 vmware-workstation） | paru 拉最新（需网络，版本随上游漂移） |
| VM + 离线 | `-t vm` | OFFLINE | 同上 | makepkg 固定 recipe（全离线，可复现） |
| 物理机 + 在线 | `-t physical` | ONLINE | 物理机清单（含 vmware-workstation） | paru 拉最新 |
| 物理机 + 离线 | `-t physical` | OFFLINE | 同上，另 bootstrap vmware-keymaps | makepkg 固定 recipe |

- 机器类型由 `-t` 参数决定（`module_selected()` 过滤 AUR 目标），安装方式由是否存在 `.aur-sources/` 缓存决定（`has_aur_sources()` 分流），**互不耦合**。
- 可复现性：**离线模式**（固定 recipe）才有"同一 payload"的可复现 PASS；**在线模式**（paru 最新）只能验证"能装通"，不计可复现 PASS（见[验证背景](#验证背景)）。
- 仿物理 profile 是第五种测试形态：在 VM 内跑物理机分支（`MACHINE_TYPE=physical`），用于 VM 中验证物理机路径，与四象限正交。

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
- `config/`：审阅过的个人配置（.config 映射 + md 知识库 + Pictures + scripts + 字体 + /etc 配置；文件数随同步变化、以 `./check-extend.sh` 输出为准）
- `manifests/`：数据清单（包策略、配置映射、AUR recipe）
- `third_party/aur/`：固定 AUR recipe 树（数量随清单变化、以 `./check-extend.sh` reconcile 输出为准；vmware-keymaps 是 vmware-workstation 的构建依赖，含审查记录）
- `fetch-aur-sources.sh`：在有海外网络的机器上生成 AUR 离线缓存（→ `~/Downloads/aur-sources/`）
- `sync-scripts.sh`：同步本机 `~/scripts` 到 `config/home/scripts/` 并自动补映射
- `sync-config-mappings.sh`：为 `config/home` 新增文件自动生成 `config-mappings.tsv` 行（module 继承、幂等、按执行位定 mode；`config/etc` 不走映射）
- `check-extend.sh`：提交前一键总检（增改门禁：bash 语法/shellcheck/清单一致性/配置内容语法（含 QML 结构配平）/recipe 双向引用/secret scan/README 数字/行为测试套件 + 宿主部署漂移提示；默认按改动范围自动选快慢——只改数据/文档快速 8 节，改脚本/测试全量 13 节，`--fast`/`--full` 强制，`--deploy` 闸门通过后同步到宿主；任一失败节禁止提交）
- `tests/`：数据完整性、FlClash 迁移契约、安装器行为测试（模块矩阵/进度绑定/symlink 安全/失败传播）、配置语法校验（validate-config-syntax.sh）与错误注入自证（check-extend-test.sh）

## 物理机部署

重装 Arch（archinstall）并完成手工交接点（分区/GRUB/首次启动/联网）后：

1. 用 archinstall 创建普通用户并启用 NetworkManager、连上 Wi-Fi
   **（内核：03-packages 硬性前置要求 `linux-zen` 与 `linux` 并存——archinstall
   默认只装 `linux`，需在 archinstall 的 kernel 选项里同时选 linux-zen，或装完补
   `pacman -S linux-zen && grub-mkconfig -o /boot/grub/grub.cfg`；12 项前置清单见
   `manifests/workstation-packages.tsv` 的 `verify` 行，2026-08-10 全新 VM 安装实测）**
2. `git clone https://github.com/tjz123psh/my-arch-setup-deepseek.git`
   （无海外网络 clone 不通时，用 U 盘拷贝 `my-arch-setup.tar`，见
   [`docs/physical-offline-install.md`](docs/physical-offline-install.md)）
3. `cd my-arch-setup-deepseek && ./install.sh`
4. 选"物理机"，安装器自动：驱动（AMD+NVIDIA+ASUS 控制，先于桌面）→ 桌面
   → AUR 目标（含 VMware Workstation；vmware-keymaps 依赖先行构建）→ 配置 → 服务 → 系统设置
5. 装完重启，登录 greetd（dms-greeter）进入 niri

部署后验收：显卡切换（`supergfxctl -m Hybrid` 重启生效）、蓝牙、音频、
挂起唤醒、ASUS 控制中心、VMware Workstation（`vmrun list`/`vmware-networks` 服务、
DKMS 的 vmmon/vmnet）。clash-verge-rev 只安装不启服务（配置私有，手动配置）。

## 验证背景

> 双模式注意：**在线模式**（paru 装最新版）安装结果随上游漂移、**不可复现**；
> TEST_ID/clean-baseline 的"同一最终 payload"验收语义仅在**离线模式**（固定 recipe）
> 下成立。VM 验收请以离线模式为准；在线模式只验证"能装通"，不产生可复现 PASS。

软件包清单、配置映射与 AUR recipe 均基于真实 ASUS 机器检录；静态清单、配置
映射、Niri 语法和 Hyprland fragments 已复核，目标行为测试也已运行。仓库的
`hyprland.lua`（含 `conf/` 分片）已在本机真实宿主上通过 `Hyprland --verify-config`
（显式 `-c` 与默认发现均 rc=0，见 `tests/session-lifecycle-test.sh` I 区）。这只
证明配置可被 Hyprland 解析。**2026-08-10 已在测试 VM 上补齐真实运行时验收**
（见 `docs/comprehensive-review-20260807.md` 0.4 节）：从 clean 基线完成
`-t vm` 与 `-t physical --test-profile physical-sim-vmware` 两轮真实安装并自动
重启，装好的系统里以 stock 入口登录 Hyprland 验证了 DMS 栏
（`hyprctl layers` 的 `dms:bar` 层）、kitty/nemo 窗口映射，以及 VMware guest
图形变通（`LIBGL_ALWAYS_SOFTWARE=1`）生效；期间发现并修复 5 个 strap.sh
（root）路径缺陷（parse_args `-y` 死循环 / AUR chown 顺序 / sudoers drop-in /
config 目录属主 / VMware dma-buf 变通）。旧 KVM 批次记录
属于历史证据，不替代当前 VMware 验收。

**Hyprland 会话内 DMS 启动：与物理机已验证方式一致（2026-08-09，Codex R4.12）。**
Hyprland 会话使用系统 stock 入口 `/usr/share/wayland-sessions/hyprland.desktop`
（`Exec=/usr/bin/start-hyprland`）。`start-hyprland` 不触达
`graphical-session.target`，因此 Hyprland 会话里没有 systemd dms.service——
DMS 由 autostart 的 `hyprland.start` 首帧钩子直接启动，以 qs 进程守卫做幂等：

```
hl.exec_cmd("pgrep -f '[q]s -p /usr/share/quickshell/dms' >/dev/null || dms run -d 2>>${XDG_RUNTIME_DIR:-/tmp}/dms-ensure.log")
```

守卫匹配 qs（quickshell UI）而非 dms backend，并用字符类 `[q]s` 避免守卫自身
命令行自匹配（物理机实测有效的写法）。为什么不会双顶栏：stock 会话里
dms.service 本就是 inactive（无 graphical-session.target），daemon 启动是唯一
backend；即使升级主机残留 uwsm 入口（systemd 拉起 dms），守卫看到 qs 已在跑也会
跳过 daemon 兜底。Niri 侧不变：仍由 systemd dms.service 经
`graphical-session.target` 启动。诊断：DMS 启动命令的 stderr 追加到
`$XDG_RUNTIME_DIR/dms-ensure.log`（autostart exec 路径 stdout/stderr 被重定向
到 /dev/null，显式落盘才能看到失败）。`~/.local/bin/dms-ensure-display` 作为
可选诊断工具保留（手工运行可看三态判定与退出码），不再由 autostart 调用。
注意：`hyprland.start` 只在首帧触发一次，reload 不重触发。合成测试不等于真实
DMS bar/IPC 已验证；真实 VMware 中的同显示单实例、跨 Niri→Hyprland 注销/登录、
reload（仅验证 reload 不产生双栏）与退出清理仍待验收，不得声称 VM 已修复。
宿主修复与真实会话内诊断步骤见
[`docs/hyprland-dms-host-remediation.md`](docs/hyprland-dms-host-remediation.md)。

截至 2026-08-08，操作者报告物理机实战部署已完成；本轮只读复核了仓库与宿主
已安装包/服务状态，未再次改动物理机。VMware guest 的 VM 模式与仿物理模式
各两轮仍是独立完成门槛，必须按 `docs/comprehensive-review-20260807.md`
的 `TEST_ID`/clean-baseline 规则记录，未取得四个同一最终 payload 的 PASS 前，
不得把项目写成“VM 验收完成”。
