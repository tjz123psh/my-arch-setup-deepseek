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
- 缓存：`./fetch-aur-sources.sh physical|vm` 生成，或从 GitHub Releases 下载
  `aur-sources-physical.tar.gz` / `aur-sources-vm.tar.gz`（按机器类型选）

## 目标机安装（tty）

```bash
# ① 挂载 U 盘（base tty 手动挂载；桌面环境已自动挂载到 /run/media/... 可跳过本步）
sudo mkdir -p /mnt/usb
sudo mount /dev/sda1 /mnt/usb          # 设备名按实际 lsblk 结果改（sda1/sdb1...）
ls /mnt/usb/arch/                      # 应看到 my-arch-setup.tar 和缓存包
USB=/mnt/usb/arch
# VMware 共享文件夹（hgfs）替代：
#   sudo mkdir -p /mnt/hgfs && sudo vmhgfs-fuse .host:/ /mnt/hgfs -o allow_other
#   USB=/mnt/hgfs/test

# ② 解包仓库 → ~/my-arch-setup-deepseek/
tar -xf "$USB/my-arch-setup.tar" -C ~/

# ③ 解压缓存进仓库 → .aur-sources/（触发 06 离线模式）
tar -xzf "$USB/aur-sources-physical.tar.gz" -C ~/my-arch-setup-deepseek/

# ④ 确认缓存就位
ls -d ~/my-arch-setup-deepseek/.aur-sources

# ⑤ 联网（仅国内镜像即可）+ 安装
curl -m 5 -s -o /dev/null -w "%{http_code}\n" https://mirrors.aliyun.com   # 期望 200 或 3xx（301 是正常跳转，有响应即说明已联网）
cd ~/my-arch-setup-deepseek && ./install.sh -d both -t physical    # 虚拟机用 -t vm
```

## 验证离线模式生效（06-aur 阶段）

- 横幅：`★ AUR MODE: OFFLINE — makepkg pinned recipes ★`
- 日志：`Using local AUR source cache: ... (offline mode)`，makepkg 构建、无 `Downloading`
- 装完：`cat ~/my-arch-setup-deepseek/.install_logs/06-aur.log` 应显示 `mode=offline`

## 注意事项

- **基础安装前置（03 步逐条 `pacman -Q` 硬校验，缺一即中止）**：
  `base bash btrfs-progs coreutils gawk grub linux linux-zen mkinitcpio networkmanager sed sudo`。
  其中 `linux-zen` 最容易漏（archinstall 默认只装 `linux`），补装：
  `pacman -S linux-zen && grub-mkconfig -o /boot/grub/grub.cfg`；非 btrfs 根或不用 GRUB 的基线
  也会分别因缺 `btrfs-progs`/`grub` 被拦下。
- **打包结构**：仓库 tar 必须带顶层目录（`my-arch-setup-deepseek/`）；缓存 tar 顶层必须是
  `.aur-sources/`。否则解压散文件、离线模式不触发（06 会走在线 paru）
- **磁盘空间（重要）**：离线 AUR 阶段要解包全部源码、构建 10+ 个包、再一次性安装
  （chrome/QQ/微信/Obsidian 解包后合计 ~2.5G），需要 `.aur-sources` 体积 + **~3G** 余量。
  预检就是按这个公式算的（`06-aur` 开工前打印，2026-09-18 实测数字）：
  **物理缓存 1.7G → 要求 `~4783MB`**（公式 = cache_mb + 3072，cache_mb 取 `du -sm .aur-sources`；2026-09-18 实测 1711 → 4783）、**vm 缓存 964M → 要求 `~4036MB`**（964 + 3072）；
  不足则 fail-closed 并给出三条清理命令。伪物理机轮实测：装完 04 驱动后只剩 4126MB 被拦下，
  释放到 5059MB 才放行——**物理机请在公式之上再留余量，驱动安装本身就要 1G 上下**；
  19G 这种小盘还要盯"缓存 + 构建产物 + 已装桌面"的峰值（实测安装阶段最低仅剩 2.7G）。
  实测坑（2026-09-18，19G 根分区）：全桌面已装 + 3.4G pacman 缓存 + btrfs/snapper 快照时爆盘，
  失败形式是**误导性的** `error: could not extract /usr/bin/opencode (Write failed)` +
  `failed to commit transaction`。手动腾空间：`sudo pacman -Sc`（或
  `sudo rm -rf /var/cache/pacman/pkg/*`，注意 `/var/cache/pacman/pkg` 可能是独立 btrfs 子卷）、
  删掉解压后的 `aur-sources-*.tar.gz`、`sudo snapper list` 后删掉旧快照。
- **缓存 tar 解压后可删**（physical 省 1.6G、vm 省 900M），离线模式只认 `.aur-sources/` 目录。
  缓存里还带 `.aur-sources/manifest.sha256`（`fetch-aur-sources.sh` 生成）：它会被写进
  `.install_progress` 的续跑上下文，换缓存后旧进度不会被误用（续跑会提示删掉
  `.install_progress` 重来）
- 全程一次 sudo 密码（安装器最小授权，装完自动恢复）
- 某 AUR 构建失败自动重试一次；仍失败报错退出，网络恢复后重跑 `./install.sh` 续传
- 旧系统 `flclash-bin` 由 03 显式迁移到 archlinuxcn/flclash
- `strap.sh` 依赖 GitHub 直连，无海外网络时用本指南的 U 盘/共享方式
- **装错分支的补救**：若误用 `-t vm` 装了物理机（缺显卡驱动/vmware-workstation/rog
  配置），**无需重装系统**——`rm -f .install_progress && ./install.sh -d both -t physical`
  重跑即可补齐（已装包自动跳过）；装完需清理 vm 残留：`pacman -R open-vm-tools` +
  `systemctl disable --now vmtoolsd vmware-vmblock-fuse` + 清依赖孤儿。注意重跑
  physical 分支需要 physical 缓存（vm 缓存缺 vmware-workstation 源码）。
- **重跑安装器前先退出桌面（注销到 tty）**：07-config 用 `cp` 覆盖部署，运行中的
  二进制（vellum 等）报 ETXTBSY"文本文件忙"导致部署失败；退出桌面后再跑最干净。

## 验证记录

### 2026-08-13 物理机 U 盘物料验证（宿主实测）

实际插入 U 盘（ntfs，卷标"新加卷"，sda1 未挂载状态）验证：

- 挂载：`udisksctl mount -b /dev/sda1` → `/run/media/pang/新加卷`（用户态免密，
  桌面环境自动挂载路径；base tty 手动挂载见上文 `sudo mount /dev/sda1 /mnt/usb`）
- 物料：`my-arch-setup.tar`（78M）+ `aur-sources-physical.tar.gz`（1.6G）均在 `arch/`
- 结构核对（关键）：代码包 `tar -tzf` 顶层为 `my-arch-setup-deepseek/`（带顶层目录，
  解压到 ~/ 不会散文件）；缓存包顶层为 `.aur-sources/`（06-aur `has_aur_sources()`
  检测条件满足 → 触发离线模式，不会误走在线 paru）

结论：U 盘两个包结构与解压路径均正确，可直接按上文"目标机安装（tty）"流程使用。

### 2026-08-12 伪物理机离线验证（physical-sim-vmware + 压缩包挂载法）

在 VMware guest（3.8G 内存 / 19G 磁盘）内以 `-t physical --test-profile
physical-sim-vmware` 模拟物理机离线安装。**注意：本次在已装过完整系统的
VM 上重跑**——官方包/驱动/桌面全部"已是最新跳过"，验证重点是 06-aur 离线
模式与 AUR 构建链路；干净 base 首次安装的官方包全量耗时不在本次范围（参考
2026-08-11 VM 离线干净安装约 1 小时量级）：

1. 挂载共享文件夹（`vmhgfs-fuse .host:/ /mnt/hgfs -o allow_other`），解压
   `my-arch-setup.tar` 与 `aur-sources-physical.tar.gz`（顶层 `.aur-sources/`）
2. `./install.sh -d both -t physical --test-profile physical-sim-vmware`
3. 结果：11 步全绿；`06-aur.log` 首行 `mode=offline targets=12`；12 个 AUR
   目标全部构建安装（含 `vmware-workstation 26H1-3` 的 bundle + 8 个 ISO +
   DKMS 模块）；makepkg 全程"找到 xxx"、**零网络下载**（sha256 全部通过）；
   bulk `pacman -U` 11 包成功；04/08/09 物理分支生效且硬件专属效果标
   `NOT_APPLICABLE_SIMULATED`；07-config 部署 253 文件
4. 对照：同 profile 在线安装（无 `.aur-sources/` → paru 拉最新）12/12 成功，
   `mode=online` 正常

结论：压缩包挂载离线安装法的**离线模式触发与 AUR 构建链路**在物理机分支下
正确性验证通过；干净物理机首次安装请预留 30-60 分钟（官方包全量 + AUR 冷
构建，无 ccache/构建缓存）。

### 2026-08-12 严格验证（干净 base 恢复快照，physical-sim-vmware）

从干净 Arch base 快照（仅 base + openssh）恢复后，同一测试 VM 依次完成两轮
完整安装（均为 `-d both -t physical --test-profile physical-sim-vmware`）：

- **离线（压缩包挂载法）**：hgfs 挂载 → 解压 `my-arch-setup.tar` +
  `aur-sources-physical.tar.gz` → 安装。11 步全绿；`06-aur.log`
  `mode=offline targets=12`；12 个 AUR 目标全部构建安装（vmware-workstation
  26H1-3 含 DKMS），makepkg 零网络下载（sha256 全过）。中途 04-drivers 曾因
  清华镜像超时（`Operation too slow`）失败一次——安装器按"required 失败即
  中止"正确退出，重跑 `install.sh` 断点续传成功（02/03 跳过，04 起重跑）。
- **在线**：恢复同一快照 → 解压代码（无缓存）→ 安装。`mode=online targets=12`，
  paru 拉最新 12/12（google-chrome 151.0.7922.108、opencode-bin 1.18.11 等
  较离线固定 recipe 新，符合预期）；vmware-workstation 26H1-3 经 paru 构建。
- 两轮 07-config 均部署 253 文件、08-services/09-settings 正常；`docker.service`
  在 VM 内 enable 失败为 warn 继续（VM 无嵌套虚拟化，物理机无此问题）。
- tty 会话下安装结束后提示 `Reboot now? [Y/n]` 等待确认（正常交互行为）。

结论：**物理机分支的离线（挂载法）与在线安装均在干净 base 上完整跑通**，
两种模式各自 12/12 成功，无回归。

### 2026-08-15 修复回归验证（干净 base，physical-sim-vmware + vm）

针对 2026-08-14 物理机离线安装失败（greetd 的 go 构建无 VPN 下从网络拉依赖）
的修复后回归，同一 VM 依次跑两轮完整安装（修复后代码 + 重新生成的缓存，
go-mod 含 `.pin=f353eaf…` 与 recipe 固定 commit 绑定）：

- **伪物理机（physical-sim-vmware）**：`mode=offline targets=12`，12/12 构建
  安装（含 vmware-workstation 26H1-3 DKMS、**greetd-dms-greeter r23.gf353eaf
  从 go 缓存构建、零网络下载**）；07 部署 253 文件；08 physical 分支
  `NOT_APPLICABLE_SIMULATED` 跳过 DKMS 段（modprobe 修复在真实 host 另验：
  `modprobe -n vmmon vmnet` OK）。
- **VM（-t vm）**：`mode=offline targets=11`，11/11 构建安装（vmware-workstation
  正确排除）；07 部署 252 文件（rog-control-center.cfg 门控行正确跳过）；08 vm
  分支 vmtoolsd/vmware-vmblock-fuse 启用成功。
- 两轮均 11/11 步全绿；06-aur 缺 go-mod/cargo 缓存时 fail-closed（GOPROXY=off
  / CARGO_NET_OFFLINE），缓存生成机（fetch-aur-sources.sh）无 go/cargo 时显式
  失败。

结论：离线缓存 go-mod 缺口与 vmmon DKMS 误报已修复，物理机离线安装的
greetd 下载问题不再复现。

### 2026-09-18 最终 payload 复验（physical-sim-vmware + vm，同一 payload）

用发布资产 `my-arch-setup.tar`（TEST_ID `2aa6bae1c532e3bc`）在 19G VM 上复验：

- **伪物理机（physical-sim-vmware + 物理缓存 1.7G）**：01-05 全绿（04 真实安装 71 个驱动包：
  nvidia-open-dkms 615.71.09 + lib32-nvidia-utils 栈，DKMS 为 linux/linux-zen 两个内核构建）；
  第 7 步首轮被空间预检 fail-closed 拦下（`4126MB available, ~4783MB needed`），腾空间后续跑
  `5059MB available` 放行；14 个 recipe 全部从物理缓存离线构建——含 `vmware-keymaps 1.0-3`
  （8 个 ISO + bundle 校验通过）与 `vmware-workstation 26H1-3`（装后 mkinitcpio 重建镜像）——
  `✔ Installed 12 AUR packages`；07 `CONFIG_RESULT deployed=289 skipped=0`；08 物理宿主服务
  按设计标 `NOT_APPLICABLE_SIMULATED`；09 物理分支在 guest 内正确回退 libx264；11 步全绿
  `EXIT=0`。
- **vm（vm 缓存 964M）**：`mode=offline targets=12`，12/12 离线构建安装，`EXIT=0`。
- 离线 pin 命中（dbx-bin 0.6.4-1、obsidian-bin 1.13.7-1、google-chrome 153.0.8010.47-1、
  greetd-dms-greeter-git 1:1.6.2.r0.g0175be5-1 等）；07 部署：物理轮 `deployed=289`，vm 轮 `deployed=288 skipped=1`（唯一的 asus-hardware 行 rog-control-center.cfg 被 module 门控跳过）。
- 限制：这两轮都是"已装系统的修复式重跑"（真实构建 + 安装，离线路径全覆盖）；
  **同一 TEST_ID 的干净 base 四轮验收（VM-R1/R2 + PHY-R1/R2）仍待另行执行**。
### 2026-09-18 审计修复后复验（vm 干净基线 + 续跑；含 locale bug 修复）

审计修复批次 0/1/4 + 2/3 + locale 修复后的复验（vm 缓存，`-d both -t vm`）：

- **干净基线轮**（快照 `Snapshot 1`，201 包；会话 `LANG` 未设 → C 排序）：
  `Base preconditions: 12/12 present`、`AUR MODE: OFFLINE`（12 个目标 + `snapd-xdg-open-git`
  前置，全部 makepkg 离线构建）、`07 CONFIG_RESULT deployed=288 skipped=0`、
  空间预检 `17258MB available (need ~4038MB)`、11 步全绿 **`EXIT=0`**。
- **续跑轮**（同 payload；安装后 `09-settings` 已写入 locale，新会话为 `LANG=zh_CN.UTF-8`）：
  11 个模块全部 `already done, skipping`、**`EXIT=0`**。
- 另在已装系统上跑过一轮完整修复式重跑（`LC_ALL=C`）：`EXIT=0`、`deployed=288`。

**本轮复验发现并修复的真问题**：续跑上下文哈希用了裸 `sort -z`，排序受 locale 影响
（`config/` 有 61 个非 ASCII 文件名；`third_party` 路径也会因标点排序规则变序），于是
“干净轮（C 排序）→ 装完后 locale 已设置（zh_CN.UTF-8）→ 续跑被误判上下文不匹配而拒绝”。
实测：`LC_ALL=C` → `config=bf582008188f aur=77f2bc400d02`；`zh_CN.UTF-8` →
`config=6f220fa8ab98 aur=6e7c56ed5277`。修复：三处 `sort` 前固定 `LC_ALL=C`
（`fetch-aur-sources.sh` 早已如此）；修复后两轮哈希一致、续跑恢复正常。

证据：`.ai/vm-logs-20260918/`（`install-clean-1.log` 干净轮、`install-clean-2.log` 续跑轮、
`install-vm-A.log` 修复式重跑、`install-vm-b23-r2.log` 修复前的失败样本）。

限制：本轮仍是 **vm** 单一机型 + `-d both`；修复后的 payload **尚未**再跑物理/伪物理轮
（04-drivers 的 71 个驱动包与物理宿主分支未覆盖，但本批改动未触碰 04-drivers）。
### 2026-09-18 同一 payload 的全机型 / 全桌面变体复验

补齐上一节未覆盖的机型与桌面变体（全部离线缓存轮，同一 payload，含批次 0–4 与 locale 修复）：

| 轮次 | 命令 | 结果 |
|---|---|---|
| vm 干净基线 | `-d both -t vm`（快照 `Snapshot 1`，201 包） | `EXIT=0`、11 步、`Base preconditions 12/12`、离线 AUR 12 目标、`deployed=288` |
| vm 续跑 | 同上（装完后 09-settings 已写入 locale） | `EXIT=0`、11 个模块 `already done, skipping` |
| 伪物理机干净基线 | `-d both -t physical --test-profile physical-sim-vmware` | `EXIT=0`、11 步、04-drivers 真实安装 GPU/平台驱动（nvidia-open-dkms DKMS）、`NOT_APPLICABLE_SIMULATED`×4、离线 15 次构建 / `Installed 18 AUR packages`、`deployed=289`、空间预检 `14100MB available (need ~4785MB)` |
| niri 变体 | `-d niri -t vm` | `EXIT=0`、**10 步**、`deployed=270`、`socat` 由 daily-apps 装上（本批修复点） |
| none 变体 | `-d none -t vm` | `EXIT=0`、**9 步**、`deployed=254` |

部署计数与代码一致：`07-config.sh` 的 `module_selected()` 在三种桌面上分别应得
`288 / 270 / 254` —— 正好是当时的 `mappings=289` 减去机型行（`asus-hardware` 1 行）与桌面行
（`wm-hyprland` 18 行、`wm-niri` 16 行），实测三轮完全吻合。
> **计数注**：上表为 2026-09-18 实测值（mappings=289）。此后两批同步使配置面变大：
> 2026-09-21 `~/md` 知识库同步后 291，同日追加触摸板配置、脚本、包清单与排除清单后为 302
> （install 200→206、total 220→226）。同口径的干净轮部署数相应为 `301 / 282 / 265`
> （2026-09-23 实测，见下节）；上表各轮的 `EXIT=0` 与步骤结论不变，但那批验收对应的是
> 289 时期的 payload。

证据：`.ai/vm-logs-20260918/`（`install-clean-1/2`、`install-vm-A`、`install-vm-b23-r2`（修复前失败样本）、
`install-phy`、`install-niri`、`install-none`）。


### 2026-09-23 复验（mappings=302：P1-6 符号链接补齐 + `.timer` 枚举 + 6 个新包）

针对 2026-09-21/22 两批 payload 变更（`~/md` 知识库同步、6 个 pacman 包、触摸板开关、
`excluded.tsv`、`07-config` P1-6 从 3 条补到 7 条、`08-services` 补 `.timer` 枚举）
在干净基线（`Snapshot 1`，201 包）上重跑三档桌面，全部**在线模式**（无 `.aur-sources`，
经宿主 Clash 反向隧道）：

| 轮次 | 命令 | 结果 |
|---|---|---|
| vm 干净基线 | `-d both -t vm` | `EXIT=0`、11 步、`Base preconditions 12/12`、`deployed=301 skipped=0` |
| niri 变体 | `-d niri -t vm` | `EXIT=0`、10 步、`deployed=282 skipped=0` |
| none 变体 | `-d none -t vm` | `EXIT=0`、9 步、`deployed=265 skipped=0` |

计数与代码一致：`302 − 1（asus-hardware）= 301`、`− 19（wm-hyprland）= 282`、
`− 17（wm-niri）= 265`。本批新增两个 `wm-*` 行（`touchpad-state.lua` → `wm-hyprland`、
`touchpad-state.kdl` → `wm-niri`）使两模块各 +1 行，所以同口径部署数由 289 时期的
`288 / 270 / 254` 变为 `301 / 282 / 265`。

**本轮重点验证（逐条实测）**：

- `07-config` P1-6 的 7 条 `~/.local/bin` 符号链接全部创建（`niri-keys`/`hypr-keys`/`b23`/
  `gsudo`/`fuzzel-askpass`/`niri-touchpad-toggle`/`hypr-touchpad-toggle`）；heredoc 里的
  `#` 注释行未被当成条目（假警告 0 条）。
- `08-services` 枚举 `.timer`：`obsidian-sync.timer` 由「不会被启用」变为 `enabled`；
  无 `[Install]` 的 `obsidian-sync.service` 被正确识别为 timer 驱动（记 log 而非 warn）。
- 6 个新包全部安装：`linux-lts-headers`/`net-tools`/`python`/`rclone`/`wireless-regdb`/`xdotool`。
- 新 payload 文件全部落位：`anyrouter-proxy.{service,mjs}`、`obsidian-sync.{service,timer}`、
  `dbx-handler.desktop`、`dsh.desktop`、`touchpad-state.kdl`、`touchpad-state.lua`。
- 模块门控：niri 轮有 `touchpad-state.kdl`、无 `touchpad-state.lua` 且无 `~/.config/hypr`；
  none 轮 `~/.config/{niri,hypr}` 均缺失、`~/.local/bin` **0 个符号链接**（P1-6 按设计跳过）、
  用户单元不启用（`obsidian-sync.timer` = `disabled`）。
- `niri validate` 通过（含新收录的 `include "touchpad-state.kdl"`）。

证据：`.ai/vm-logs-20260923/`（`install-vm-both-20260923.log` 250K、
`install-vm-none-20260923.log` 241K）。niri 轮的完整日志在归档前被 `Snapshot 1` 回滚清除，
仅保留上述结果行与实测结论（下次先归档再回滚）。

未覆盖：伪物理机轮（`--test-profile physical-sim-vmware`）与续跑轮本批未重跑；
`04-drivers` 与续跑逻辑本批未改动。

### 2026-09-18 在线模式轮（同一 payload，经宿主代理）

干净基线（`Snapshot 1`）上、经宿主 Clash 代理（guest 内反向 SSH 隧道 `-R 7890` +
`https_proxy/http_proxy/all_proxy`）跑 `-d both -t vm`（**不带** `.aur-sources`）：
`★ AUR MODE: ONLINE — paru latest from AUR ★`、`EXIT=0`、11 步、`deployed=288`。

- paru `-S` 目标 **11 个** = 清单 12 个 AUR install 行 − 单独引导构建的 `paru`；
  与离线轮同口径（离线 13 次构建 = paru + 1 个前置依赖 + 11 个目标）。
- 版本走 AUR HEAD，与离线 pin 不同（`dbx-bin 0.6.16-1` vs pin `0.6.4-1`；
  `obsidian-bin 1.13.7-2` vs pin `1.13.7-1`；`greetd-dms-greeter-git 1:1.6.2.r3.gc792f1e-1`
  vs pin `…g0175be5`）—— 与「在线装最新 / 离线装 pin」的双模式语义一致。
- 08-services 输出已记录的已知提示：在线模式下 `uwsm` 会被依赖带进来，因此
  `hyprland-uwsm.desktop` 会出现在会话菜单、但不在受验证链里（按既有决定不修，仅记录；
  greeter 中请选普通 `Hyprland` 入口）。

证据：`.ai/vm-logs-20260918/install-online.log` 与 `online-summary.txt`。
至此验证矩阵（vm 干净 / vm 续跑 / 修复式重跑 / PHY-sim 干净 / niri / none / 在线）全部 `EXIT=0`。
