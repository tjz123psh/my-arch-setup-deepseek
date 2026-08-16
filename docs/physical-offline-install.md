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
