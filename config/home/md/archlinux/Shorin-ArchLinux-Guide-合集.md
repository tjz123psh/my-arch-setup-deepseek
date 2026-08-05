# 目录


- [安装ArchLinux](#安装archlinux)
- [手动安装省流版](#手动安装省流版)
- [安装任意Linux系统的前期准备工作](#安装任意linux系统的前期准备工作)
- [安装桌面环境前的准备](#安装桌面环境前的准备)
- [快照和系统维护](#快照和系统维护)
- [安装桌面环境或窗口管理器](#安装桌面环境或窗口管理器)
- [一键配置桌面环境](#一键配置桌面环境)
- [安装GNOME](#安装gnome)
- [安装KDE](#安装kde)
- [安装Niri](#安装niri)
- [安装Hyprland](#安装hyprland)
- [安装Labwc](#安装labwc)
- [安装Wayfire](#安装wayfire)
- [安装mangowc](#安装mangowc)
- [显卡驱动和硬件编解码](#显卡驱动和硬件编解码)
- [中文输入法](#中文输入法)
- [软件安装相关](#软件安装相关)
- [我的GNOME自定义设置](#我的gnome自定义设置)
- [我的KDE自定义设置](#我的kde自定义设置)
- [终端美化](#终端美化)
- [grub美化](#grub美化)
- [显卡切换](#显卡切换)
- [热切换显卡直通](#热切换显卡直通)
- [虚拟机](#虚拟机)
- [KVM虚拟机](#kvm虚拟机)
- [玩游戏](#玩游戏)
- [性能优化](#性能优化)
- [小技巧](#小技巧)
- [干净删除Linux](#干净删除linux)
- [issues](#issues)
- [附录](#附录)
- [常见争议澄清](#常见争议澄清)
- [交流群](#交流群)
- [Linuxmint入门](#linuxmint入门)
- [CachyOS](#cachyos)
- [Arch部署Astrbot](#arch部署astrbot)
- [代理](#代理)
- [nixos](#nixos)
- [ShorinNiri功能介绍](#shorinniri功能介绍)
- [shorinos](#shorinos)
- [维护AUR包](#维护aur包)

---

# 安装ArchLinux

视频教程：[【从「Linux Mint 入门」到「Arch Linux 安装详解」桌面端 Linux 入门的最佳路径】](https://www.bilibili.com/video/BV19DBqB4EY4/)

新手建议先手动安装，把其他安装方式当作重装系统的便利工具，否则日后出现问题自己不会解决。如果手动安装太难，就先使用开箱即用的 Arch，比如 CachyOS。

## 重要概念讲解

太长不看的总结：ESP（启动分区）的挂载点通常是 `/boot`，但是为了使用 Btrfs 快照功能将其挂载到了 `/efi`。GRUB 安装路径从默认的 `/boot/grub` 移动到了 `/efi/grub`。

- **Linux 目录结构**：Linux 的目录是由 `/` 开头的树状结构，`/` 被称为根目录。
- **挂载**：把硬盘分区对应到某个目录。
- **挂载点**：假设把 `/dev/nvme0n1` 挂载到 `/home`，则称 `/dev/nvme0n1` 的挂载点为 `/home`。
- **文件系统**：本文使用 Btrfs 文件系统，最大的特点是快照（存档和回档）。
- **Bootloader 引导程序**：用来引导系统启动。GRUB 最为常用。
- **EFI 系统分区（ESP）**：存放 `.efi` 文件，主板读取后加载系统内核以启动系统。

### ESP 挂载点

常用挂载点为 `/boot`、`/boot/efi` 和 `/efi`。

- `/boot` 是最典型挂载点，但多内核情况下需要 1G~2G 空间。
- ESP 是 FAT 文件系统，无法被 Btrfs 快照记录和恢复，所以使用 Btrfs 时 ESP 不能挂载到 `/boot`。为了避免内核版本不一致导致无法启动，使用 Btrfs 时 ESP 的挂载点应为 `/boot/efi` 或 `/efi`。推荐挂载点为 `/efi`（扁平布局更简洁）。

## 安装方案简述

Win + Linux 双系统；分区时创建独立于 Windows 的启动分区（ESP）并挂载到 `/efi`，剩余所有空间创建为一个大分区；文件系统使用 Btrfs，创建 `@` 和 `@home` 子卷；Bootloader 使用 GRUB 并装进 ESP；Swap 使用 ZRAM 配合硬盘 Swap；联网工具使用 NetworkManager。

## 手动安装

### 可选：调大字体

```bash
setfont ter-v32n
# 或者
setfont -d
```

### 确认是 UEFI 固件

```bash
cat /sys/firmware/efi/fw_platform_size
```

输出 `64` → 64 位 x64 UEFI；`32` → 32 位 UEFI；`No such file or directory` → BIOS（本文只涉及 x64 UEFI）。

### 连接网络

```bash
ip a           # 查看网络连接信息
ping bilibili.com  # 确认网络正常
```

使用 `iwctl` 连接 Wi-Fi：

```bash
iwctl
device list                       # 列出设备
station wlan0 scan                # 扫描网络
station wlan0 get-networks        # 列出所有 Wi-Fi
station wlan0 connect 【WiFi名】  # 连接（不能有中文）
exit
```

### 确认开启了 NTP

```bash
timedatectl               # 确认 NTP service: active
timedatectl set-ntp true  # 手动开启
```

### Reflector 自动设置镜像源

```bash
reflector -p https -a 12 -c cn --v --sort rate --save /etc/pacman.d/mirrorlist
pacman -Sy
```

### 硬盘分区

```bash
lsblk -pf       # 查看当前分区情况
cfdisk /dev/nvme0n1  # 选择要使用的硬盘进行分区
```

1. 新硬盘选 GPT
2. **EFI 分区**：选中空闲空间 → New 创建 512MB 分区 → Type 选 EFI System
3. **根分区**：其余全部分到一个分区，类型 `linux filesystem`
4. `Write` 保存，`yes` 确认，`Quit` 退出

### 格式化分区

```bash
mkfs.fat -F 32 /dev/nvme0n1p1    # 格式化 EFI 分区
mkfs.btrfs /dev/nvme0n1p2        # 格式化 Btrfs 根分区（加 -f 强制）
```

### 创建 Btrfs 子卷

```bash
mount -t btrfs /dev/nvme0n1p2 /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@swap   # 内存≥16G 且不需要休眠则跳过
umount /mnt
```

### 正式挂载

```bash
mount -t btrfs -o subvol=/@,compress=zstd /dev/nvme0n1p2 /mnt
mount --mkdir -t btrfs -o subvol=/@home,compress=zstd /dev/nvme0n1p2 /mnt/home
mount --mkdir -t btrfs -o subvol=/@swap,compress=zstd /dev/nvme0n1p2 /mnt/swap  # 可选
mount --mkdir /dev/nvme0n1p1 /mnt/efi
df -h  # 复查
```

### 安装系统

```bash
pacstrap -K /mnt base base-devel linux linux-firmware btrfs-progs networkmanager vim sudo amd-ucode
```

> Intel CPU 用户安装 `intel-ucode`；marvell 无线网卡额外安装 `linux-firmware-marvell`。

### 可选：Swap 交换空间

```bash
btrfs filesystem mkswapfile --size 64g --uuid clear /mnt/swap/swapfile
swapon /mnt/swap/swapfile
```

Swap 大小参考：

| 内存(GB) | 不需休眠 | 需休眠 |
|----------|---------|--------|
| 16       | 4       | 20     |
| 32       | 6       | 38     |
| 64       | 8       | 72     |

### 生成 fstab

```bash
genfstab -U /mnt > /mnt/etc/fstab
```

### 更换根目录

```bash
arch-chroot /mnt
```

### 设置时间和时区

```bash
timedatectl set-timezone Asia/Shanghai
hwclock --systohc
```

### 本地化设置

```bash
vim /etc/locale.gen
# 取消 en_US.UTF-8 UTF-8 和 zh_CN.UTF-8 UTF-8 的注释
locale-gen
vim /etc/locale.conf
# 写入 LANG=en_US.UTF-8
```

### 设置主机名

```bash
vim /etc/hostname
# 写入主机名，如 archlinux
```

### 设置 root 密码

```bash
passwd
```

### 安装引导程序

```bash
pacman -S grub efibootmgr os-prober exfat-utils  # 不配双系统可不装 os-prober 和 exfat-utils
grub-install --target=x86_64-efi --efi-directory=/efi --boot-directory=/efi --bootloader-id=ARCH
```

编辑 `/etc/default/grub`：

- `GRUB_DEFAULT=0` 改为 `=saved`，取消 `GRUB_SAVEDEFAULT=true` 注释（启动项记忆）
- 去掉 `quiet`，设置 `loglevel=5`（显示开机日志）
- 添加 `nowatchdog` 和 `modprobe.blacklist=sp5100_tco`（Intel 换 `iTCO_wdt`）
- 取消 `GRUB_DISABLE_OS_PROBER=false` 注释（双系统）

```bash
ln -sf /efi/grub /boot/grub
grub-mkconfig -o /boot/grub/grub.cfg
```

### ZRAM（未配置 Swap 时必配）

```bash
pacman -S zram-generator
vim /etc/systemd/zram-generator.conf
```

写入：

```ini
[zram0]
zram-size = ram
compression-algorithm = zstd
```

在 `/etc/default/grub` 的 `GRUB_CMDLINE_LINUX_DEFAULT` 中添加 `zswap.enabled=0`，然后重新生成：

```bash
grub-mkconfig -o /boot/grub/grub.cfg
```

### 启用网络服务

```bash
systemctl enable NetworkManager
```

### 退出并重启

```bash
exit
reboot
```

拔掉 U 盘，选择 BIOS 启动项，登录 root 账户，用 `nmtui` 连接 Wi-Fi。

## 脚本安装（archinstall）

### 开启 archinstall

```bash
archinstall
```

### 关键配置项

1. **Mirrors and repositories** → Select regions（选所在地区）→ 激活 `multilib`
2. **Disk configuration** → 手动分区：
   - 创建 512MB FAT32 分区，挂载 `/efi`，设置 bootable + ESP
   - 剩余空间用 Btrfs，开启压缩，创建 `@`（挂载 `/`）和 `@home`（挂载 `/home`）子卷
3. **Bootloader** → GRUB
4. **Kernels** → linux 或 linux-zen
5. **Authentication** → 设置 root 密码，创建普通用户并赋予 sudo
6. **Profile** → Minimal（最小化安装）
7. **Applications** → Audio: pipewire，Bluetooth: Yes
8. **Network configuration** → NetworkManager（iwd backend）
9. **Timezone** → 搜索 Shanghai
10. **Install** → 开始安装

### 脚本安装后的双系统配置

安装完成后选 `chroot`，然后：

```bash
pacman -S os-prober exfat-utils
vim /etc/default/grub
# 取消 GRUB_DISABLE_OS_PROBER=false 注释
# GRUB_DEFAULT=0 → =saved，取消 GRUB_SAVEDEFAULT=true 注释
# 去掉 quiet，设置 loglevel=5
# 添加 nowatchdog + modprobe.blacklist=sp5100_tco
grub-mkconfig -o /efi/grub/grub.cfg
ln -sf /efi/grub /boot/grub
exit
reboot
```

## AI 助手安装

在 Live 环境中可用 OpenCode 进行自动安装：

```bash
pacman -Sy opencode
```

提示词示例：

```
We are in the archiso live. First, increase the cowspace size. Then install archlinux following the guide from github.com/SHORiN-KiWATA/wiki.
BTRFS + GRUB
root passwd: shorin
normal username: shorin, passwd: shorin
setup dual boot
ESP mount to /efi
GRUB install into /efi
link /efi/grub to /boot/grub
setup snapper
CN locale
```

---

# 手动安装省流版

这篇文章是方便快速查阅用的，不是给新手看的。

- 调大字体

    ```bash
    setfont ter-v32n
    ```

- 确认 UEFI

    ```bash
    cat /sys/firmware/efi/fw_platform_size
    ```

- 联网

    ```bash
    iwctl
    station wlan0 scan # 扫描网络
    station wlan0 get-networks # 列出所有扫描的 WiFi
    station wlan0 connect 【此处是你的 WiFi 名字（不能是中文）】
    ```

    ```bash
    ip a # 查看网络连接信息
    ping bilibili.com # 确认网络正常
    ```

- 镜像源

    ```bash
    reflector -p https -a 12 -c cn --v --sort rate --save /etc/pacman.d/mirrorlist
    ```

- 分区

    ```bash
    lsblk
    ```

    ```bash
    cfdisk /dev/nvme0n1 # 选择自己要使用的硬盘进行分区
    ```

- 格式化

    ```bash
    mkfs.fat -F 32 ESP设备名
    mkfs.btrfs (-f可选) 根分区设备名
    ```

- btrfs 子卷

    ```bash
    mount -t btrfs 根分区设备名 /mnt

    btrfs subvolume create /mnt/@
    btrfs subvolume create /mnt/@home
    btrfs subvolume create /mnt/@swap # 不需要休眠到硬盘功能的话跳过这个

    umount /mnt
    ```

- 挂载

    ```bash
    mount -t btrfs -o subvol=/@,compress=zstd 根分区设备名 /mnt
    mount --mkdir -t btrfs -o subvol=/@home,compress=zstd 根分区设备名 /mnt/home
    mount --mkdir -t btrfs -o subvol=/@swap,compress=zstd 根分区设备名 /mnt/swap
    mount --mkdir ESP设备名 /mnt/efi
    ```

- 安装系统

    ```bash
    pacstrap -K /mnt base linux linux-firmware btrfs-progs \
                     base-devel networkmanager vim sudo amd-ucode
    ```

- swap 文件

    ```bash
    btrfs filesystem mkswapfile --size 64g --uuid clear /mnt/swap/swapfile

    swapon /mnt/swap/swapfile
    ```

    | 内存(GB) | 不需要休眠(GB) | 需要休眠（GB） | 不建议超过（GB） |
    | -------- | -------------- | -------------- | ---------------- |
    | 4        | 4              | 6              | 8                |
    | 5        | 2              | 7              | 10               |
    | 6        | 2              | 8              | 12               |
    | 8        | 3              | 11             | 16               |
    | 12       | 3              | 15             | 24               |
    | 16       | 4              | 20             | 32               |
    | 24       | 5              | 29             | 48               |
    | 32       | 6              | 38             | 64               |
    | 64       | 8              | 72             | 128              |

- fstab

    ```bash
    genfstab -U /mnt > /mnt/etc/fstab
    ```

- chroot

    ```bash
    arch-chroot /mnt
    ```

- 时区

    ```bash
    timedatectl set-timezone Asia/Shanghai

    hwclock --systohc
    ```

- 本地化

    ```bash
    vim /etc/locale.gen
    > en_US.UTF-8 UTF-8
    > zh_CN.UTF-8 UTF-8

    locale-gen

    vim /etc/locale.conf
    > LANG=en_US.UTF-8
    ```

- 主机名

    ```bash
    vim /etc/hostname
    > archlinux
    ```

- root 密码

    ```bash
    passwd
    > 盲输密码
    ```

- 引导

    ```bash
    pacman -S grub efibootmgr os-prober exfat-utils

    grub-install --target=x86_64-efi --efi-directory=/efi --boot-directory=/efi --bootloader-id=arch

    vim /etc/default/grub
    > GRUB_DEFAULT=saved, GRUB_SAVEDEFAULT=true
    > GRUB_CMDLINE_LINUX_DEFAULT="loglevel=5 nowatchdog modprobe.blacklist=sp5100_tco/iTCO_wdt"

    # btrfs 特殊存根处理
    findmnt / -n -o UUID

    vim /efi/grub/grub.cfg
    > search --fs-uuid --no-floppy  --set=root 你的Btrfs分区UUID
    > configfile /@/boot/grub/grub.cfg

    mkdir -p /boot/grub

    grub-mkconfig -o /boot/grub/grub.cfg
    ```

- zram

    ```bash
    pacman -S zram-generator

    vim  /etc/systemd/zram-generator.conf
    > [zram0]
    > zram-size = ram
    > compression-algorithm = zstd

    vim /etc/default/grub
    > GRUB_CMDLINE_LINUX_DEFAULT="... zswap.enabled=0 ... "
    ```

- NetworkManager

    ```bash
    pacman -S iwd

    mkdir -p /etc/NetworkManager/conf.d
    vim /etc/NetworkManager/conf.d/iwd.conf
    > [device]
    > wifi.backend=iwd

    systemctl enable NetworkManager
    ```

- 重启

    ```bash
    exit

    reboot
    ```

---

# 安装任意Linux系统的前期准备工作

>整个 Wiki 假定了你拥有一个 Windows 系统，如果你不想双系统，自行跳过 Windows 相关的内容。

## 下载 ISO

去想要安装的 Linux 系统的官网下载 ISO（系统镜像）文件。官网下载慢的话可以找一找你所在地区的镜像站，主流 Linux 发行版通常会在下载页面提供镜像站相关链接。

- [Arch Linux](https://archlinux.org/download/)
- [Linux Mint](https://linuxmint.com/download.php)
- [CachyOS](https://cachyos.org/download/)

## 制作系统盘

**⚠️警告：注意备份重要数据⚠️**

- 方法一：Ventoy

    [Ventoy/Ventoy: A new bootable USB solution.](https://www.ventoy.net/cn/index.html)

    Ventoy 制作的系统盘可以存放多个系统镜像，推荐。

- 方法二：压缩卷（没有 U 盘使用这个方法）

    1. Windows 系统内 `Win+X` 键，选择磁盘管理。找到想安装 Arch Linux 的位置，右键选择压缩卷，空出磁盘空间。

    2. 右击空出的空间选择新增简单卷，大小设置为 4096MB（足够装下 ISO 里面的文件就行），盘符随意，格式化选择 FAT32。

    3. 双击打开 ISO，把里面的内容粘贴进刚刚新建的盘符里。

## Windows 下的准备工作

如果你要安装双系统，以下工作是必须的。

1. 解决安装 Linux 后 Windows 时间错乱

    >[双系统时间同步-CSDN 博客](https://blog.csdn.net/zhouchen1998/article/details/108893660) | [系统时间 - Arch Linux 中文维基](https://wiki.archlinuxcn.org/wiki/%E7%B3%BB%E7%BB%9F%E6%97%B6%E9%97%B4)

    Linux 把主板时间改成标准 UTC 时间，然后根据系统设置的时区对 UTC 时间进行加减后显示出来。Windows 直接读取主板时间显示出来，所以此时你 Windows 显示的时间就变成了 UTC 时间，表面上看就像是 Windows 时间错乱了。Windows 下管理员身份打开 PowerShell 运行：

    ```powershell
    Reg add HKLM\SYSTEM\CurrentControlSet\Control\TimeZoneInformation /v RealTimeIsUniversal /t REG_DWORD /d 1
    ```

    <details close><summary>命令解释</summary>

    >`Reg add` 添加一个注册表项目

    >`HKLM\SYSTEM\CurrentControlSet\Control\TimeZoneInformation` 是路径

    >`/v RealTimeIsUniversal` `/v` 指定项目名称

    >`/t REG_DWORD` `/t` 指定数据类型为 REG_DWORD（32 位无符号整数）

    >`/d 1` `/d` 指定具体的值，1 代表启用

    上面这条命令修改注册表，让 Windows 采用和 Linux 相同的策略，默认主板时间为 UTC，根据系统设置的时区进行相应的加减后再显示。
    </details>

    另一种方法是让 Linux 使用本地时间 `timedatectl set-local-rtc 1`，我没试过，说不定会在日志、定时任务之类的地方出问题。由于我主要使用 Linux，所以使用上面的方法。

2. 关闭快速启动

    搜索 `电源` --> `选择电源计划` --> `选择电源按钮的功能` --> `更改当前不可用的设置` --> 确认关闭了 `快速启动`

3. 关闭 BitLocker

    系统设置里搜索到后关闭。BitLocker 加密会阻碍 Linux 访问硬盘。

4. 预留硬盘空间

    右键 Windows logo 打开磁盘管理。右键你要使用的硬盘分区，通过压缩卷腾出给 Linux 空间。

## BIOS 设置

重启电脑进入 BIOS。不同的机器进 BIOS 方法不同，现代电脑通常是 `Esc`、`F2`、`F7`、`Delete`，如果不行的话查找一下自己主板进 BIOS 的方法。

1. 关闭安全启动（Secure Boot）

    > 部分发行版已支持安全启动，可以查阅官方文档。

    重启电脑进入 BIOS 关闭安全启动。

2. 关闭 TPM

    开启 TPM 可能会在 Linux 下出现异常。
3. 调整启动项顺序

    启动项第一个设置成刚刚制作的系统盘。

4. 保存并退出

    通常是 `F10` 键

## 下一节：[Arch Linux 安装教程](安装ArchLinux) | [Linux Mint 入门指南](./Linuxmint入门) | [CachyOS 入门指南](./CachyOS)

---

# 安装桌面环境前的准备

目录：

- [设置全局默认文本编辑器](#设置全局默认文本编辑器)
- [创建普通用户](#创建普通用户)
- [开启32位源](#开启32位源)
- [archlinuxcn源](#archlinuxcn源)
- [AUR助手](#aur助手)
- [字体](#字体)
- [音视频固件和服务](#音视频固件和服务)
- [性能模式切换](#性能模式切换)
- [蓝牙](#蓝牙)
- [flatpak软件](#flatpak软件)
  - [可选：休眠到硬盘](#可选休眠到硬盘)
- [重启电脑生效](#重启电脑生效)
- [下一节：显卡驱动和硬件编解码](#下一节显卡驱动和硬件编解码)

---

我想要安装完所有桌面环境通用的基础配置，然后创建一个 `before desktop` 快照当作存档点，方便更换或者尝试不同的桌面环境。

## 设置全局默认文本编辑器

通过 `EDITOR` 环境变量设置默认编辑器。如果不设置的话有些程序会默认调用 `vi` 编辑器。Arch 默认是没有安装 `vi` 的，会报错。

```
sudo vim /etc/environment
```

```
EDITOR=vim

# 如果你使用neovim的话填入nvim，nano填入nano
```

由于是全局变量，需要 `exit` 注销后重新登录才能生效。

```
exit
```

## 创建普通用户

很多软件会拒绝在 root 权限下运行，所以普通用户是必须的。

1. 新建用户

   ```
   useradd -mG wheel 你的用户名
   ```

   >`-m` 代表创建用户的时候创建 `home` 目录。

   >`-G` 代表设置组。

2. 设置密码

   ```
   passwd 你的用户名
   ```

3. 编辑权限

   ```
   visudo
   ```

   搜索 `wheel`，取消注释。

   ```
   %wheel ALL=(ALL:ALL) ALL
   ```

4. 退出 root 使用普通用户登录

   ```
   exit
   ```

   接下来需要管理员权限运行的命令要加上 `sudo`。

## 开启32位源

32 位源建议开启，Steam 需要，Wine 运行 exe 也需要。

1. 编辑 pacman 配置文件

   ```
   sudo vim /etc/pacman.conf
   ```

   去掉 `[multilib]` 两行的注释。

   ```
   [multilib]
   Include = /etc/pacman.d/mirrorlist
   ```

2. 同步数据库

   ```
   sudo pacman -Syu
   ```

## archlinuxcn源

archlinuxcn 源是由 archlinuxcn 维护的软件仓库，可以丰富我们安装软件的手段。

1. 编辑 pacman 配置文件添加 archlinuxcn 源

   ```
   sudo vim /etc/pacman.conf
   ```

2. 文件底部写入

   ```
   [archlinuxcn]
   Server = https://mirrors.ustc.edu.cn/archlinuxcn/$arch
   Server = https://mirrors.tuna.tsinghua.edu.cn/archlinuxcn/$arch
   Server = https://mirrors.hit.edu.cn/archlinuxcn/$arch
   Server = https://repo.huaweicloud.com/archlinuxcn/$arch
   ```

   不用全写，一般用 ustc（中科大）和 tuna（清华）即可。如果你在海外的话可以直接使用 CN 源官方：

   ```
   Server = https://repo.archlinuxcn.org/$arch
   ```

3. 同步数据库并安装 archlinuxcn 密钥

   ```
   sudo pacman -Syu archlinuxcn-keyring
   ```

## AUR助手

AUR 是 Arch 最强大的软件仓库。AUR 助手可以方便从 AUR 安装软件。archlinuxcn 上有编译好的版本，可以从 archlinuxcn 安装。

```
sudo pacman -S --needed base-devel yay paru
```

`base-devel` 是编译软件时必须的。`yay` 和 `paru` 都是常用的助手，任选其一，也可以都装，用 yay 安装失败的包可以换另外一个试试。

## 字体

通常安装以下字体包：

```
sudo pacman -S noto-fonts noto-fonts-cjk noto-fonts-emoji ttf-jetbrains-mono-nerd
```

>`noto-fonts` 包含大部分外文字体。

>`noto-fonts-cjk` 包含了中日韩字体，不正确设置系统字体的话会出现中文以日文的字体显示之类问题。有关 fontconfig 的内容可以看[附录-字体设置](附录#字体设置)。

>`noto-fonts-emoji` emoji 表情。

>`ttf-jetbrains-mono-nerd` 最常用的等宽字体，用于终端字体显示。`nerd` 代表包含了字符字体。

如果你有自己喜欢的字体，可以自行安装。例如我觉得 noto 字体空间占用大，所以只会安装下面这些：

```
sudo pacman -S adobe-source-han-sans-cn-fonts ttf-liberation noto-fonts-emoji ttf-jetbrains-mono-nerd
```

## 音视频固件和服务

让音频设备和屏幕分享正常工作。

1. 可选：安装音视频固件

   ```
   sudo pacman -S --needed sof-firmware alsa-ucm-conf alsa-firmware
   ```

   >`sof-firmware` 为现代音视频设备提供固件，通常装这个就可以了。

   >`alsa-ucm-conf` 提供必要的配置文件。

   >`alsa-firmware` 为不常见或者较旧的设备提供固件。

2. 安装音视频服务

   ```
   sudo pacman -S --needed pipewire wireplumber pipewire-pulse pipewire-alsa pipewire-jack
   ```

   >`pipewire` 是由 Red Hat 主导开发的现代音视频服务。

   >`wireplumber` 会智能管理 pipewire。

   >`pipewire-pulse`、`pipewire-alsa`、`pipewire-jack` 分别为 PulseAudio、ALSA、JACK 提供兼容。

3. 启用服务

   ```
   systemctl --user enable --now pipewire pipewire-pulse wireplumber
   ```

## 性能模式切换

`power-profiles-daemon` 是各个桌面环境通用的性能模式切换服务，有三个档位，performance 性能、balance 平衡、powersave 节电。

1. 安装

   ```
   sudo pacman -S power-profiles-daemon
   ```

2. 启动服务

   ```
   sudo systemctl enable --now power-profiles-daemon
   ```

>这个易用而且足够，不建议使用 `tlp` 或者 `auto-cpufreq`，功耗上不会有明显区别。如果想折腾的话可以看[附录-tlp相关](附录#tlp相关)。

## 蓝牙

1. 安装

   ```
   sudo pacman -S --needed bluez
   ```

2. 启动服务

   ```
   sudo systemctl enable --now bluetooth
   ```

## flatpak软件

flatpak 是全发行版通用的打包方式，依赖和插件比较多的软件 flatpak 版本通常更好用，比如 OBS 和 EasyEffects。如果 AUR 和仓库的软件都不太正常，也可以尝试 flatpak 版本。

1. 安装 `flatpak`

   ```
   sudo pacman -S flatpak
   ```

2. 可选：更换国内源

   - 上交大

      ```
      sudo flatpak remote-modify flathub --url=https://mirror.sjtu.edu.cn/flathub
      ```

   - 中科大

      ```
      sudo flatpak remote-modify flathub --url=https://mirrors.ustc.edu.cn/flathub
      ```

### 可选：休眠到硬盘

[ArchWiki Power management/Suspend and hibernate](https://wiki.archlinux.org/title/Power_management/Suspend_and_hibernate)

如果需要休眠到硬盘功能，且之前设置了硬盘 swap 的话。

查看 `/etc/mkinitcpio.conf` 这个文件的 `HOOKS` 部分：

```
grep ^HOOKS /etc/mkinitcpio.conf
```

>`grep ^HOOKS` 筛选以 `HOOKS` 开头的行。

- 如果是 `HOOKS(base systemd ...)` 的话无须手动配置。

- 如果是 `HOOKS(base udev ...)` 的话：

   1. 添加 hook

      ```
      sudo vim /etc/mkinitcpio.conf
      ```

      在 `HOOKS()` 内添加 `resume`，注意需要添加在 `udev` 的后面。

   2. 重新生成 initramfs

      ```
      sudo mkinitcpio -P
      ```

   3. 重启电脑

      ```
      reboot
      ```

   4. 使用命令进行休眠

      ```
      systemctl hibernate
      ```

## 重启电脑生效

```
reboot
```

## 下一节：[显卡驱动和硬件编解码](显卡驱动和硬件编解码)

---

# 快照和系统维护

目录

- [snapper](快照和系统维护#snapper)
- [回档方法](快照和系统维护#回档方法)
- [滚挂和良好的系统使用习惯](快照和系统维护#关于滚挂和良好的系统使用习惯)
- [downgrade 回退更新](快照和系统维护#扩展内容downgrade)
- [拓展：手动快照回档](快照和系统维护#拓展内容手动快照回档)

现在我们已经完成了安装桌面环境前的所有准备工作，为了方便尝试不同的桌面，可以创建一个快照当作存档点，想玩别的随时回档。另外，**养成习惯，每次做自己不了解的事情之前都存个档**，如果出了问题或者后悔了可以恢复到快照时的状态。

## snapper

openSUSE 开发的快照软件，超级好用。

1. 安装

   ```bash
   sudo pacman -S snapper btrfs-assistant grub-btrfs inotify-tools
   ```

   `snapper` 是主程序；

   `btrfs-assistant` 是 GUI（图形化交互界面），同时提供了几个简单的命令，进一步简化快照回档需要的操作。我们还没有安装桌面环境，但是肯定会用到，先装上。

   `grub-btrfs inotify-tools` 在创建快照的时候自动在 GRUB 菜单里添加快照启动项。

   可选：`snap-pac` 利用钩子在进行 pacman 命令的时候自动创建快照。

2. 重启电脑用新的 initramfs 进入系统

   ```bash
   reboot
   ```

3. 激活快照启动项服务

   如果你是通过 `/efi/grub/grub.cfg` 存根读取 `/boot/grub/grub.cfg` 的方式配置的 GRUB 引导，需要进行额外操作，看：[附录：Grub在btrfs文件系统的最佳配置方法](附录#grub在btrfs文件系统的最佳配置方法)。

   ```bash
   sudo systemctl enable --now grub-btrfsd
   ```

4. 创建快照配置

   ```bash
   sudo snapper -c root create-config /
   ```

   `-c root` 指定要使用的配置，由于该配置不存在，所以 `create-config` 创建，快照范围是 `/`。

   然后用同样的方式创建 home 的配置：

   ```bash
   sudo snapper -c home create-config /home
   ```

5. 设置合理的快照策略

   - 获取当前设置

      ```bash
      sudo snapper -c root get-config
      ```

   - 修改设置

      可以使用 `set-config` 选项，但是一个个设置太麻烦了，建议直接编辑文件。

      ```bash
      sudo vim /etc/snapper/configs/root
      ```

      以下是我的设置：

      `ALLOW_GROUPS="wheel"` 允许 wheel 组的用户无须 `sudo` 就可以操作快照。

      `NUMBER_LIMIT="10"` 设置最多保存 10 个快照，超出后会按照时间顺序删除旧快照。

      `TIMELINE_LIMIT_HOURLY="3"` 每隔一小时创建的快照保存 3 个。

      `TIMELINE_LIMIT_DAILY="1"` 每日快照保存 1 个。

      其他的 `TIMELINE_LIMIT` 数量都设置为 0。这样就仅保存三个小时前的状态和昨天的状态。

      接着对 home 的快照配置进行一样的修改。

      ```bash
      sudo vim /etc/snapper/configs/home
      ```

6. 开启按时间自动创建快照和自动清理

   ```bash
   sudo systemctl enable --now snapper-timeline.timer
   sudo systemctl enable --now snapper-cleanup.timer
   ```

7. 创建快照

   分别创建 home 和 root 的快照。

   ```bash
   snapper -c root create -d "before desktop"
   snapper -c home create -d "before desktop"
   ```

   `create` 创建快照，`-d (description)` 添加自定义描述。我们这里是安装桌面之前，所以描述为 before desktop。

8. 生成 GRUB 菜单入口

   要至少运行一次 `grub-mkconfig` 生成 GRUB 菜单的快照启动项入口：

   ```bash
   sudo grub-mkconfig -o /boot/grub/grub.cfg
   ```

现在就配置好快照啦。`reboot` 重启可以看到快照启动项。

### 回档方法

- btrfs-assistant 命令行（推荐）

   0. 切换至 root

      以普通用户 `sudo` 运行可能会出现环境问题，建议切换到 root。

      ```bash
      su -
      ```

   1. 确认要使用的快照的 **snapper 序号**

      ```bash
      snapper -c root list
      ```

      可以使用 `grep` 筛选快照。

      ```bash
      snapper -c root list | grep "Before"
      ```

      假设我要用的快照的 snapper 序号是 `11`。

      ![](pictures/snap/snapperlist.png)

   2. 用 snapper 序号找到对应的 **btrfs-assistant 序号**

      ```bash
      btrfs-assistant -l
      ```

      在下图这个例子中，snapper 序号为 `11` 的 root 快照对应着 btrfs-assistant 的序号 `1`。

      ![](pictures/snap/btrfs-assistant.png)

      注意一个细节，这条命令会把 home 和 root 的快照排在同一个列表里。图中 snapper 序号为 `11` 的 home 快照对应着 btrfs-assistant 序号 `6`（这意味着 btrfs-assistant 序号 1~5 是 root 快照，6 往后是 home 快照）。

   3. 回档

      ```bash
      btrfs-assistant -r 1
      ```

      这里的数字是要使用的快照的 **btrfs-assistant 序号**。

- btrfs-assistant 图形界面

   <details close><summary>此时还没有安装桌面环境，你可以后续回来看</summary>

   >如果你要从命令行打开 btrfs-assistant，必须使用 `btrfs-assistant-launcher`，仅使用 `btrfs-assistant` 命令的话不会调用 polkit 提权。

   1. 创建配置

      打开 btrfs assistant，切换到 `snapper settings` 页面。我们创建子卷的时候至少创建了一个 `@` 子卷和一个 `@home` 子卷，所以需要两个 `config（配置）`。

      - root 根目录快照

         点击 `new config` 新建配置，`config name` 写 `root`，`backup path` 选择 `/`，然后点击 `save` 保存。

         接着进行一些按照时间自动生成快照的设置。`systemd unit settings` 里面有三个服务。`timeline` 是按照时间计划自动创建快照；`cleanup` 是快照数量达到 `number` 设定的数量上限之后自动清理快照；`boot` 是每次开机自动创建快照。按需设置，设置完记得点 `apply`。

      - home 目录快照

         按照同样的方法创建一个 home 目录的配置。

   2. 创建快照

      到 `snapper` 页面，`select config` 选择配置，要创建 root 子卷的快照就选择刚刚创建的名为 `root` 的配置。点击 `new` 创建快照，`description` 是快照的自定义文字描述（注释）。

   3. 使用快照进行恢复

      `snapper` 页面 --> `Browse/restore` 页面

      `select target` 选择想恢复的子卷，再选择想使用的快照，点击 `restore`，此时会自动帮你创建一个额外的子卷用来备份当前的数据然后弹出一个确认窗口让你填写这个子卷的名字（可以空着不填写）。

   4. 使用快照进行全盘恢复

      因为 `@` 子卷和 `@home` 子卷在创建的时候是平级的，所以虽然 root 目录包含了 home 目录，但是创建 `@` 子卷的快照时不会包含 `@home` 子卷里的内容。这样的子卷布局叫作 `扁平布局`。因此，需要分别创建 `@` 和 `@home` 的快照，然后分别恢复。

   </details>


- 从 GRUB 菜单的快照启动项进入系统

   无法正常进入系统时使用该方法。用 btrfs-assistant 回档，GUI 或者命令行都可以。记得用 root 身份登录。

- snapper 命令行

   >Arch 的子卷布局不支持 `snapper rollback` 命令，只能使用 `undochange` 命令回档。

   >⚠️注意⚠️：官方文档不建议用 undochange 回档 root，这部分内容知道一下就行。

   1. 列出可用快照

      ```bash
      snapper -c root list
      ```

      找到自己想使用的快照的数字序号。

   2. undochange 回档

      ```bash
      sudo snapper -c root undochange 1..0
      ```

      这里的 `1..0`，`1` 是你要使用的快照的序号，`0` 代表当前状态。

      这条命令会对比两者的区别，对当前状态进行修改，无须重启，重新登录即可生效。

### 遇到异常

   <details><summary>从快照启动项进入系统后 snapper list 没能列出快照</summary>
   因为现在处在快照子卷里而不是原本的 `@` 子卷里。之前创建的快照都在 `@` 子卷里，挂载之后才能读取到。

   1. 确认根分区设备名

      （回忆一下手动安装 Arch 时的挂载操作）

      ```bash
      lsblk -p
      ```

      或者

      ```bash
      findmnt /
      ```

   2. 挂载根

      ```bash
      mount -t btrfs /dev/nvme0n1p2 /mnt
      ```

      此时 `/mnt` 对应的是 `/`，`cd` 进入 `/mnt` 会看到系统的 `@`。也可以选择加上 `-o subvol=/@` 挂载 `/@` 而不是 `/`，这种情况下 `/mnt` 对应的是 `@`。

   3. 指定根进行读取

      我们的子卷存放在 `@` 里面，列出快照时指定读取 `@`：

      ```bash
      snapper --no-dbus --root /mnt/@ -c root list
      ```

      `--root` 选项指定根，此选项只能在 `--no-dbus` 下生效。

      可以使用 `grep` 筛选自己需要的快照：

      ```bash
      snapper --no-dbus --root /mnt/@ -c root list | grep "Before Desktop Environments"
      ```

      记住快照序号，使用 btrfs-assistant 的命令行工具回档即可，方法上面已经介绍了。
   </details>

   <details><summary>无法从快照启动项进入系统</summary>
   很大概率是因为快照是只读的导致显示管理器无法正常运行，你的启动日志会卡在 `Graphical ....`。

   - 解决方法一：切换到别的 TTY 用命令行恢复

      `Ctrl+Alt+F2~F8` 切换到非图形界面的 TTY，用命令行进行恢复。恢复完成后可以把显示管理器换掉，已知 `sddm` 会出现此问题而 `plasmalogin` 不会。

   - 解决方法二：让快照可读（不推荐）

      需要确认 initramfs 类型。

      ```bash
      grep "^HOOKS" /etc/mkinitcpio.conf
      ```

      这条命令 `grep` 筛选出文件中由 `HOOKS` 开头的行。

      确认 `HOOKS=(...)` 里是 `systemd` 还是 `udev`。

    - 如果是 `systemd`

         `grub-btrfsd` 没有提供 systemd 单元，不能用此方法。

    - 如果是 `udev`

      可以设置 overlayfs 让快照可读。

      1. 设置覆盖文件系统（overlayfs）

         设置一个 overlayfs 在内存中创建一个临时可写的类似 live-cd 的环境，否则可能无法正常从快照启动项进入系统。

      2. 编辑 `/etc/mkinitcpio.conf`

         ```bash
         sudo vim /etc/mkinitcpio.conf
         ```

      3. 在 HOOKS 里添加 `grub-btrfs-overlayfs`

         ```bash
         HOOKS= ( ...... grub-btrfs-overlayfs )
         ```

      4. 重新生成 initramfs

         ```bash
         sudo mkinitcpio -P
         ```

      5. 重启电脑
   </details>

### 拓展内容：手动快照回档

<details><summary>如果以上内容都没能让你正常回档，还可以使用 btrfs 命令手动回档。</summary>

1. 确认根分区设备名

   ```bash
   findmnt /
   ```

   输出类似：

   ```text
   TARGET SOURCE          FSTYPE OPTIONS
   /      /dev/nvme0n1p2[/@]
                        btrfs  rw,relatime,compress=zstd:3,ssd,discard=async,space_cache=v2,subvolid=256,
   ```

   `/dev/nvme0n1p2` 是我的根分区。

2. 挂载顶级卷

   我们运行的系统是在子卷里面的。想对子卷进行操作，要先挂载 `/`。

   ```bash
   sudo mount -t btrfs -o subvolid=5 /dev/nvme0n1p2 /mnt
   ```

   `subvolid=5` 指定顶级卷；`/dev/nvme0n1p2` 更换为你实际的根分区设备名；挂载到了 `/mnt` 目录。

3. 进入目录

   ```bash
   cd /mnt
   ```

   此时 `ls` 命令可以看到 `@` 和 `@home` 之类的子卷。

4. 备份 `@` 子卷

   ```bash
   mv @ @_bak1
   ```

   这条命令移动 `@` 并重命名为 `@_bak1`。

5. 回档

   我们的快照文件通常存放在 `@/.snapshots` 目录下，`@` 变成了 `@_bak1`，所以现在快照文件在 `@_bak1/.snapshots` 里面。

   ```bash
   btrfs subvolume snapshot @_bak1/.snapshots/1/snapshot @
   ```

   这条命令把 `@_bak1/.snapshots` 目录下序号为 `1` 的快照变成了新的 `@`。现在如果重启电脑，就会进入新的 `@` 里。

6. 移动快照文件

   之前创建的快照仍在 `@_bak1/.snapshots` 里，需要把它移动到新的 `@` 里。

   要先删除新的 `@` 里的 `.snapshots`：

   ```bash
   rmdir @/.snapshots
   ```

   然后移动 `@_bak1` 里的 `.snapshots`。

   ```bash
   mv @_bak1/.snapshots @/.snapshots
   ```

7. 删除 `@_bak1`

   如果想删除备份快照，需要先把里面的子卷删除。

   ```bash
   btrfs subvolume list -o @_bak1
   ```

   删掉所有 `@_bak1` 开头的子卷，然后才能删掉 `@_bak1`。

   ```bash
   btrfs subvolume delete -R @_bak1
   ```
   > `-R(--recursive)` 递归删除子卷里的子卷。

8. 重启电脑

   ```bash
   reboot
   ```
</details>

## timeshift

[建议用snapper](附录#timeshift)

## 关于滚挂和良好的系统使用习惯

- 滚挂

  Arch Linux 是滚动发行版。滚动是英文直译，原词是 rolling，指一种推送更新的方式，只要有新版本就会推送，由用户管理更新。对应的另一种更新方式是定期更新一个大版本，例如 Fedora 是六个月一更新，由发行方管理更新。滚挂，指的是滚动更新的发行版因为更新导致系统异常。不用担心，只要学习一下正确的更新方式和快照的使用方法就不用担心滚挂问题。

- 良好的使用习惯

  使用时谨记以下几点：

  1. 别第一时间更新

      如果更新会导致系统异常，社区一定会传出消息，要等一手。

  2. 不要太久不更新

      滚动发行版的软件，尤其是 AUR 上的软件通常会适配最新版本的依赖，隔个一年半载，软件都更了好几个大版本了，你还不更新的话会导致无法使用新安装的软件。

  3. 不要部分更新

      一定要一次性更新所有软件，否则容易出现依赖问题。密钥是唯一可以单独更新的东西。

  4. 密钥单独更新

      当待更新软件列表出现了 `keyring` 的时候，一定要先 `-Sy` 单独更新，然后再 `-Syu` 更新整个系统。

  5. 做不了解的事情要小心

      系统损坏的原因往往是用户自己的不当操作，明白自己的行为会造成怎样的后果，做不了解的事情前创建快照。

## 拓展内容：downgrade

有时候更新完之后可能反而不好用，这时就要使用 downgrade 退回之前的版本。

⚠️警告⚠️：降级到太老的版本可能会出现依赖问题，千万不要降级关键依赖。

- 安装
   ```bash
   yay -S downgrade
   ```

- 使用方法：

   ```bash
   sudo downgrade 要回退的软件包
   ```

   比如如果我要回退 `ghostty`：

   ```bash
   sudo downgrade ghostty
   ```

## ⚠️现在你学会了快照的使用方法，接下来请自行判断要不要创建快照⚠️

万事俱备，接下来选择自己喜欢的桌面环境吧。记住，你随时可以回档到这个时间点，所以不用犹豫，想尝试就装上试试。

## 下一节：[安装桌面环境或窗口管理器](安装桌面环境或窗口管理器)

---

# 安装桌面环境或窗口管理器

> 注：本教程完全拥抱代表 Linux 未来的 Wayland 协议。传统的 X11 窗口管理器（如 `i3wm`、`dwm`）不在本教程推荐之列。

## 主要分类

- Desktop Environment 桌面环境

   简称 DE。这是传统意义上的桌面环境，提供 Windows 和 macOS 那样完整的桌面体验。

   代表：GNOME、KDE Plasma

- Window Manager 窗口管理器

   Wayland 下叫 Wayland Compositor（Wayland 合成器），为了方便以下统称 WM。只提供基础的窗口绘制、布局、动画效果等功能。以键盘和终端操作为主。大多数 WM 默认使用自动平铺（后文称`平铺式窗口管理器`），窗口会按照预设的逻辑自动调整大小，不同的 WM 的布局逻辑略有不同。现代的 WM 都同时支持平铺式和传统桌面那样的堆叠式。平铺式窗口管理器常常会导致软件的弹出窗口出现异常，兼容性不如堆叠式。

   代表：Hyprland、Niri、Sway

没有头绪的话建议从桌面环境上手，GNOME 和 KDE 二选一就行。桌面环境和 WM 可以同时安装，不会搞乱桌面，再不济还可以快照回档，放心尝试！

### 选择GNOME还是KDE Plasma？

>KDE Plasma 预览图

![](./pictures/kde-showcase.png)

>GNOME 预览图

![](./pictures/gnome-showcase.png)


两句总结它们的优缺点：KDE 功能众多且实用，但是初见会觉得杂乱无章。GNOME 很精简，但是精简过头变得太过简陋。

- 操作逻辑

   通常认为 GNOME 的默认设置更符合 macOS 的直觉，KDE 的默认设置更符合 Windows 的直觉。但是 GNOME 和 KDE 都高度可自定义，因此无论 KDE 还是 GNOME 都可以通过一些额外的设置做到 Windows 或者 macOS 的操作逻辑。区别在于 KDE 的设置里已经集成了大量自定义选项，而 GNOME 需要安装第三方扩展。

- 外观和自定义

   KDE 生态的软件主要使用 Qt，而 GNOME 主要使用 GTK，所以外观上会有区别，通常认为 GTK 的外观更加简洁。KDE 的系统设置里集成了相当多自定义相关的选项，所以比起 GNOME，KDE 自定义起来更方便、更灵活。GNOME 的自定义完全基于社区扩展，而扩展通常会在 GNOME 大版本更新后大面积失效，所以稳定性一般。

- 自带功能

   KDE Plasma 桌面环境自带的无级缩放、外屏亮度调节、概览中键关闭窗口、高级网络配置、平铺布局等功能都相当好用。GNOME 以精简为核心设计理念，所以默认没有这些功能。虽然可以通过额外安装扩展和软件达成类似的效果，但稳定性不如 KDE 自带。

听上去 GNOME 不如 KDE？因为 GNOME 的优点同时也是缺点。GNOME 不会在系统设置里塞满不知道什么时候能用上的选项，不会给你繁杂的快捷键设置，不会给软件加上一大堆按钮和丑陋的工具栏。没有桌面快捷方式干扰你欣赏壁纸，没有杂乱的任务栏分散你的注意力。软件永远只满足核心功能，除此之外的东西都是"多余"。设计之独特，只有用过才知道适不适合。

现在你了解了两者的区别，[GNOME](安装GNOME)和[KDE](安装KDE)之间选择一个安装吧。如果还是犹豫不知道选哪个的话就选 KDE Plasma。

### 选择什么 WM？

- Niri

   > 入门窗口管理器的首选

   现代滚动（scrolling）平铺式窗口管理器。特点是可横向无限延伸的滚动布局和围绕该布局进行的一系列逻辑自洽的设计。动画干练流畅，社区活跃，配置难度简单，对新手相当友好。入门窗口管理器的首选。

- Hyprland

   > 好看

   现代平铺式窗口管理器，默认布局是 `dwindle`，支持切换多种平铺布局（`dwindle`、`master`、`scrolling`）。动画丰富且高度可自定义，社区活跃，软件兼容优秀，配置难度普通。适合用不惯 Niri 或者想要深度美化桌面的人。

- Sway

   > 轻量平铺，极速响应

   平铺式窗口管理器。无动画，精简、稳定、极速，轻量化的首选。

- Labwc

   > 轻量堆叠

   堆叠式窗口管理器。没有动画，超级轻量，适合想给老电脑配轻量桌面且不喜欢自动平铺的用户使用。缺点是配置使用 XML，写起来难度较高。

我使用的是 Niri，学会一个 WM 就能知道其他 WM 如何使用，在一个 WM 上积累的配置可以轻易转移到别的 WM，所以不用太在意 WM 选择。目如果对其他 WM 有兴趣的话可以看这个项目：[awesome-wayland](https://github.com/rcalixte/awesome-wayland)。

### 点击跳转：[Niri](安装Niri)

> 因 Hyprland 频繁破坏性更新，我已移除 Hyprland 入门相关内容。

---

# 一键配置桌面环境

[跳转脚本仓库](https://github.com/SHORiN-KiWATA/shorin-arch-setup)

[视频链接](https://www.bilibili.com/video/BV1Q12tBEE8e/?share_source=copy_web)

---

 目录

- [预览图片](#预览图片)
  - [KDE Plasma](#kde-plasma)
  - [GNOME](#gnome)
  - [Shorin-Niri](#shorin-niri)
    - [Shorin's Niri 功能介绍](#shorins-niri-功能介绍)
  - [Quickshell](#quickshell)
- [安装各桌面后的系统资源占用对比](#安装各桌面后的系统资源占用对比)
- [脚本使用方法](#脚本使用方法)
- [注意事项](#注意事项)
- [关于配置更新](#关于配置更新)
- [你可能想进行的修改](#你可能想进行的修改)
- [项目引用](#项目引用)
- [常用软件列表](#常用软件列表)

---

我的一键配置脚本做好啦。功能是用我的配置文件为刚刚安装好的 Arch Linux 系统一键完成基础配置，一键安装桌面环境。

## 预览图片

### KDE Plasma

- ![](pictures/KDE-preview.png)

---

### GNOME

- ![](pictures/GNOME-preview.png)

---

### Shorin-Niri

- ![](pictures/waybar-top.png)

- ![](pictures/waybar-bottom-niri.png)

#### [Shorin's Niri 功能介绍](ShorinNiri功能介绍)

---

### Quickshell

- [Noctalia](https://noctalia.dev/)

    ![](pictures/noctalia-preview.png)

- [illogical-impulse (end4)](https://github.com/end-4/dots-hyprland)

    ![](pictures/illogical-impulse.png)

- [DankMaterialShell (DMS)](https://github.com/AvengeMedia/DankMaterialShell)

    ![](pictures/DankMaterialShell.png)

- [Caelestia](https://github.com/caelestia-dots/shell)

    ![](pictures/Caelestia-preview.png)

- [iNiR](https://github.com/snowarch/iNiR)

    ![](pictures/iNiR-preview.png)

    ![](pictures/iNiR-preview2.png)


## 安装各桌面后的系统资源占用对比

> 仅供参考

![](pictures/resource.png)

## 脚本使用方法

1. 安装一个 btrfs 文件系统的 Arch Linux 系统。

    不需要任何准备工作。刚刚安装好的 Arch 就可以运行脚本。

2. 在任意终端或者 TTY 运行以下命令：

    ```bash
    curl -L shorin.xyz/archsetup | bash
    ```
    有两个需要做出选择的菜单，第一个让你选要装的桌面环境，第二个菜单可以自选部分模块。

    <details close><summary>[展开/收起] 自选模块详细介绍</summary>

   - IWD Wifi Backend

        如果你安装了 NetworkManager，这一项会将 WiFi 后端从 `wpa_supplicant` 修改为 `iwd`。以获得更稳定、轻量、快速的 WiFi 体验。

   - Windows Linux Dualboot Setup 双系统配置

        如果你的电脑上同时安装了 Windows 和 Linux，并且引导加载程序使用的是 GRUB，会自动帮你配置双系统的引导。

   - Hardware Drivers 硬件驱动

        这一项会使用 `chwd-arch-git` 这个包安装上 `chwd`，运行 `chwd -a` 命令自动安装你的硬件需要的驱动。

   - Grub Themes GRUB 主题美化

        如果你使用的是 GRUB，会出现一些可选的 GRUB 主题。

   - Common Apps 常用软件

        启用这一步会在安装完桌面之后安装我推荐的常用软件，可以通过 TUI 列表挑选你要安装的。对某些软件会进行我预先设计的初始化，例如，选择安装 virt-manager 会装上一整套的 KVM/QEMU 虚拟机、选择安装 firefox 会使用我设计的布局配置并安装去广告扩展、选择安装 Wine 会初始化 Wine 并修复字体问题等......

    </details>


3. 阅读教程文件

    安装完成后 home 目录下或者桌面上会有一个教程文件，请一定阅读。

- 如果出现网络问题可以配置代理：[透明代理](代理)

- 如果打开桌面时报错卡死请检查你的显卡驱动，虚拟机场景请检查 3D 加速是否启用，`Ctrl+Alt+F2~F8` 可以切换到别的终端操作系统。

- 如果安装失败或者后悔了

  - 可以直接重新运行脚本

  - 还可以使用快照回档

      `/usr/local/bin` 中安装了 `shorin-undochange` 和 `shorin-de-undochange` 两个命令用来回档。

      ```bash
      # 切换为 root
      su -

      # 回到对应的时间点
      # 安装前
      shorin-undochange

      # 安装桌面前
      shorin-de-undochange
      ```

      或者使用命令行恢复，具体可以看：[快照的使用方法](快照和系统维护)

## 注意事项

- Shanghai 时区会询问要不要刷新镜像源（默认不刷新）。还会询问用哪个 flatpak 源，默认是上交大。

- 如果安装的是窗口管理器且没有安装过显示管理器，会询问是否配置显示管理器。

- GRUB 存根配置

    如果满足 btrfs + ESP 挂载点不是 /boot + GRUB 安装在 ESP 里这三个条件，脚本会自动将 `esp/grub/grub.cfg` 调整为读取 `/boot/grub/grub.cfg` 的存根，在启动时自动将 `/boot/grub/grub.cfg` 的内容嵌套进 `esp/grub/grub.cfg` 中。这一配置的目的是让 grub.cfg 能被 btrfs 回档，避免回档后启动流程和系统不符导致系统挂掉。如果你想更新 GRUB 请一定将结果输出到 `/boot/grub/grub.cfg`，不要覆盖掉 ESP 里的 grub.cfg。

## 关于配置更新

仅 Shorin Niri 和 Shorin DMS Niri 支持更新。安装后会有对应的 `shorinniri` 命令和 `shorindms` 命令用于管理配置，详情看命令的帮助信息。

## 你可能想进行的修改

- 移除 ly 显示管理器

    ```bash
    # 关闭服务
    systemctl disable ly@tty1

    # 删除包
    paru -Rns ly

    # 重启
    reboot
    ```

- 全局默认编辑器

    ```bash
    sudo vim /etc/environment
    ```

- 修改或者移除 GRUB 主题

    GRUB 主题文件存放在 `/usr/share/grub/themes`。运行 `sudo shorin change-grub-theme` 可以修改主题。

- 移除 GRUB 菜单的重启和关机选项

    删除自定义 GRUB 配置文件：

    ```bash
    sudo rm /etc/grub.d/99_custom
    ```

- 护眼模式

    想取消的话删除或注释 Niri 配置文件中的 wlsunset 相关内容即可。

    想自定义色温或者经纬度的话修改 `.local/bin/toggle-wlsunset` 文件。

- 移除 VS Code 的 matugen 主题

    注释掉 `~/.config/matugen/config.toml` 中关于 VS Code 的内容。

    然后删除 `.config/Code/User/settings.json`。

- 移除日语输入法

    我安装了 fcitx5-mozc 日语输入法，如果你不需要的话可以打开 Fcitx5 配置程序删除。删除包使用此命令：

    ```bash
    yay -Rns fcitx5-mozc
    ```

- 更换图标主题

    图标主题由 matugen 脚本基于 Adwaita 生成，要禁用才能更换自己想要的图标主题。

    shorin-niri/hyprland 和 dms 编辑 `~/.config/matugen/config.toml`。noctalia 编辑 `~/.config/noctalia/user-templates.toml`，注释掉 gtk-folder 相关的配置。

- 终端字体太大

    编辑 `.config/kitty/kitty.conf`。

- GNOME 扩展设置

    看[我的 GNOME 自定义设置-扩展](我的GNOME自定义设置#功能性扩展)。

- 更换 awww 为 swaybg 节省内存

    1. `pkill awww` 关闭 awww。

    2. `sudo pacman -S swaybg` 安装 swaybg。

    3. 编辑 `.config/niri/config.kdl`。

        取消 `workspace-shadow{}` 里面 `off` 的注释。再取消 `layout {}` 里面 `background-color "transparent"` 的注释。

        再删除或者注释掉以下三行内容：

        ```text
        // 桌面壁纸的守护进程
        spawn-at-startup "awww-daemon"
        // 总览界面背景壁纸的守护进程
        spawn-sh-at-startup "awww-daemon -n overview"
        // 有聚焦窗口时桌面自动模糊的脚本
        spawn-at-startup "~/.config/scripts/niri_auto_blur_bg.sh"
        ```

        再新写入一行 `spawn-at-startup "waypaper" "--restore"`。

    4. 配置 waypaper

        `vim .config/waypaper/config.ini`

        删除 `post_command` 后面调用的脚本，只留下 `post_command = $HOME/.config/scripts/matugen-update.sh $wallpaper`

        最后打开 waypaper，z 键调出 UI，把 awww 换成 swaybg，切换一张自己喜欢的壁纸。

- 删除大写锁定的 OSD 显示

    也可以节省内存。

    ```bash
    systemctl disable --now swayosd-libinput-backend.service
    ```

    再删除或注释 `.config/niri/config.kdl` 中 `swayosd-server` 的自动启动。

    再删除或注释 `.config/matugen/config.toml` 中的 swayosd 相关内容。

## 项目引用

- GRUB 主题

    [CyberGRUB-2077](https://github.com/adnksharp/CyberGRUB-2077)

    [mimegrub](https://github.com/Lxtharia/minegrub-theme)

    [Crossgrub](https://github.com/krypciak/crossgrub)

    [OldBIOS](https://github.com/Blaysht/grub_bios_theme)

    [Blue Screen of Life](https://github.com/harishnkr/bsol)

- waybar

    [mechabar](https://github.com/sejjy/mechabar)

## 常用软件列表

这里是所有的常用软件，GUI 是图形化交互软件，TUI 是基于终端的交互软件。如果你有不需要的可以自己 `yay -Rns 包名` 删除。如果有残留的快捷方式可以查看 `~/.local/share/applications` 或者 `/usr/share/applications` 目录删除对应的 .desktop 文件。

<details close><summary>常用软件列表</summary>

- 互联网与社交

    | 软件包                      | 说明                        |
    | :-------------------------- | :-------------------------- |
    | `firefox` `python-pywalfox` | 火狐浏览器和主题同步        |
    | `linuxqq-appimage`          | (AUR) QQ                    |
    | `wechat-appimage`           | (AUR) 微信                  |
    | `flclash-bin`               | (AUR) 网络代理工具          |
    | `localsend`                 | 局域网传输神器              |
    | `nm-connection-editor`      | 高级网络配置管理            |
    | `transmission-gtk`          | 种子下载器                  |
    | `video-downloader`          | (AUR) 视频下载器 (B站/油管) |

- 游戏 (Gaming)

    | 软件包                      | 说明                            |
    | :-------------------------- | :------------------------------ |
    | `steam`                     | 游戏平台                        |
    | `lutris`                    | Wine 前缀和游戏库管理           |
    | `heroic-games-launcher-bin` | Epic/GOG 游戏管理               |
    | `protonplus`                | Proton 版本管理                 |
    | `mangohud`                  | 游戏性能监控浮层（Afterburner） |
    | `mangojuice-bin`            | (AUR) Mangohud 配置 GUI         |
    | `gamescope`                 | 游戏窗口合成器                  |
    | `lsfg-vk-bin`               | (AUR) 小黄鸭游戏补帧工具        |
    | `wine`                      | 运行 Windows 程序               |

- 生产力与多媒体

    | 软件包                                           | 说明                              |
    | :----------------------------------------------- | :-------------------------------- |
    | `visual-studio-code-bin`                         | (AUR) VS Code 代码编辑器          |
    | `neovim`                                         | 现代化的 Vim 终端编辑器           |
    | `lazyvim`                                        | 优秀的 Neovim 预设配置            |
    | `opencode`                                       | 开源 AI 助手                      |
    | `mpv`                                            | 视频播放器                        |
    | `imv`                                            | 图片查看工具                      |
    | `obs-studio`                                     | 推流与录屏                        |
    | `upscaler`                                       | 图片无损放大 GUI                  |
    | `virt-manager` `qemu-full` `swtpm` `virt-viewer` | KVM 虚拟机管理                    |
    | `com.github.wwmm.easyeffects`                    | （flatpak）音频特效 (降噪/均衡器) |

- 系统工具

    | 软件包                          | 说明                             |
    | :------------------------------ | :------------------------------- |
    | `nmtui`                         | TUI 网络连接配置工具             |
    | `mission-center`                | 系统监视器 (Win11 风格)          |
    | `btop`                          | TUI 系统监视器                   |
    | `gdu`                           | TUI 磁盘占用分析工具             |
    | `baobab`                        | GUI 磁盘占用分析工具             |
    | `gparted`                       | 磁盘管理工具                     |
    | `gnome-font-viewer`             | 字体管理器                       |
    | `thunar`                        | GUI 文档管理器                   |
    | `yazi`                          | TUI 文档管理器                   |
    | `fcitx5-mozc`                   | 日语输入法                       |
    | `rime-wubi`                     | 五笔输入法                       |
    | `lact`                          | GPU 控制工具                     |
    | `pavucontrol`                   | 音频配置 GUI                     |
    | `flatseal`                      | Flatpak 权限管理                 |
    | `it.mijorus.gearlever`          | （flatpak）AppImage 管理器       |
    | `io.github.fabrialberio.pinapp` | （flatpak）.desktop 文件编辑工具  |
    | `bazaar`                        | flatpak 软件商城                 |
    | `gnome-clocks` `gnome-calendar` | 时钟和日历                       |
    | `file-roller`                   | 压缩解压缩                       |

</details>

---

# 安装GNOME

目录

- [安装基础组件](安装GNOME#1-安装)
- [配置 GDM 服务](安装GNOME#2-临时开启gdm)
- [网络工具 (nm-connection-editor)](安装GNOME#安装高级网络配置工具nm-connection-editor)
- [分数缩放与 VRR](安装GNOME#可变刷新率和分数缩放)
- [修改默认终端](安装GNOME#修改gnome默认终端)
- [生成 Home 目录](安装GNOME#生成home下目录如果没有的话)

---

[ArchWiki GNOME](https://wiki.archlinux.org/title/GNOME)

这个部分是安装 GNOME，以及一些最基本的配置。

1. 安装

   ```
   pacman -S gnome-shell gdm ghostty gnome-control-center bazaar flatpak file-roller nautilus-python firefox
   ```

   >`gnome-shell` 最小化安装 GNOME；

   >`gdm` 是显示管理器（GNOME Display Manager）；

   >`ghostty` 是一个可高度自定义，主打无缝融入任何环境的终端模拟器（terminal emulator）。当然，如果你需要可以自行更换；

   >`gnome-control-center` 是设置中心；

   >`bazaar` 是软件商城；

   >`nautilus-python` 开启 ghostty 在文档管理器右键从此处打开终端的功能，对于其他终端，还需要 `nautilus-open-any-terminal`；

   >`flatpak` 是 flatpak 软件，这是一种全发行版通用的软件打包形式，软件沙盒运行；

   >`file-roller` 是和 GNOME 的文档管理器集成的压缩解压缩工具；

   >`firefox` 是 Linux 上最好用的浏览器。

2. 临时开启 gdm

   ```
   systemctl start gdm
   ```

3. 登录普通用户账号

4. 设置 gdm 开机自启

   正常开启桌面后打开 ghostty 设置 gdm。

   ```
   sudo systemctl enable gdm
   ```

### 安装高级网络配置工具 nm-connection-editor

```
sudo pacman -S --needed nm-connection-editor dnsmasq
```

### 可变刷新率和分数缩放

商店安装 Refine 修改。

```
flatpak install flathub page.tesk.Refine
```

### 修改 GNOME 默认终端

- 方法一：dconf-editor

  ```
  sudo pacman -S dconf-editor
  ```

  org.gnome.desktop.applications.terminal 里的 exec 取消"使用默认值"，自定义值填 ghostty，exec-arg 同理，自定义值改成 -e。这么写是因为别的程序调用 ghostty 运行命令时需要通过 -e 参数把命令传给 ghostty。

- 方法二：gsettings 命令

  ```
  gsettings set org.gnome.desktop.default-applications.terminal exec 'ghostty'
  gsettings set org.gnome.desktop.default-applications.terminal exec-arg '-e'
  ```

两个方法效果是一样的，可以运行这段命令查看是否修改成功：

```
gsettings get org.gnome.desktop.default-applications.terminal exec
gsettings get org.gnome.desktop.default-applications.terminal exec-arg
```

输出应该为：

```
'ghostty'
'-e'
```

### 生成 home 下目录（如果没有的话）

```
sudo pacman -S --needed xdg-user-dirs

LANG=en_US.UTF-8 xdg-user-dirs-update --force
```

### 修改系统语言为中文

打开 Settings，System --> Region & Language。

### 接下来你自己根据需求决定安装什么软件，进行什么配置。当然，你也可以选择参考我的

## 下一节：[软件安装相关](软件安装相关)

---

# 安装KDE

[KDE - ArchWiki](https://wiki.archlinux.org/title/KDE)

1. 安装

   ```bash
   sudo pacman -S plasma-meta konsole dolphin flatpak-kcm kate firefox qt6-multimedia-ffmpeg
   ```

   >`plasma-meta` 但是 KDE 自带的东西都很实用，装 meta 包就可以了。

   >`konsole` 是 KDE 标配终端仿真器。

   >`dolphin` 是 KDE 标配文档管理器。

   >`flatpak-kcm` 通过系统设置管理 Flatpak 应用的权限。

   >`kate` 是标配文本编辑器。

   >`firefox` 是 Linux 上最好用的浏览器。

   >`qt6-multimedia-ffmpeg` 多媒体相关依赖。

2. 开启显示管理器

   ```bash
   sudo systemctl start plasmalogin
   ```

   自 6.5 版本开始，plasma 同时提供 `sddm` 和 `plasmalogin`，推荐使用 `plasmalogin`。

3. 登录普通用户

4. 设置开机自启

   成功开启桌面后打开 konsole 设置显示管理器开机自启。

   ```bash
   sudo systemctl enable plasmalogin
   ```

### 设置系统语言

- 系统设置 > Region & Language > Language 边上的 Modify > 点击 Add More 添加简体中文 > 移动到 English 上方。

- 如果是 archinstall 安装，需要进行如下操作：

   1. ```bash
      sudo vim /etc/locale.gen
      ```

   2. 左斜杠键搜索，取消 `zh_CN.UTF-8` 的注释。

   3. ```bash
      sudo locale-gen
      ```

   4. 登出。

### 生成 home 下目录（如果没有的话）

```bash
LANG=en_US.UTF-8 xdg-user-dirs-update --force
```

这段命令将强制生成英文的 home 下常用目录，方便终端中使用。如果你已经存在中文的 home 下常用目录请运行这段命令后删除中文的。

### 接下来你自己根据需求决定安装什么软件，进行什么配置。当然，你也可以选择参考我的

## 下一节：[软件安装相关](软件安装相关)

---

# 安装Niri

- [这是你在这篇文章之后能够获得的 Niri 环境](#这是你在这篇文章之后能够获得的niri环境)
- [什么是 Niri？](#什么是niri)
- [可选：更换 shell 为 fish](#可选更换shell为fish)
- [安装](#安装)
- [显示器配置](#显示器配置)
- [关闭鼠标加速](#关闭鼠标加速)
- [重要程序](#重要程序)
- [修改系统语言为中文](#修改系统语言为中文)
- [安装中文输入法](#安装中文输入法)
- [配置图形化文档管理器](#配置图形化文档管理器)
  - [Nautilus](#nautilus)
  - [可选：Thunar](#可选thunar)
- [锁屏](#锁屏)
- [自动熄屏锁屏睡眠](#自动熄屏锁屏睡眠)
- [蓝牙](#蓝牙)
- [剪贴板](#剪贴板)
  - [Clipse](#clipse)
  - [Cliphist](#cliphist)
- [截图](#截图)
  - [编辑截图](#编辑截图)
- [屏幕分享](#屏幕分享)
- [软件商城](#软件商城)
- [Alt+Tab 切换窗口](#alttab切换窗口)
- [笔记本屏幕亮度调节](#笔记本屏幕亮度调节)
- [壁纸切换](#壁纸切换)
- [面板（任务栏）](#面板任务栏)
- [可选：大写锁定显示](#可选大写锁定显示)
- [可选：自动登录](#可选自动登录)
- [Reference](#reference)
---

## 这是你在这篇文章之后能够获得的 Niri 环境

![](pictures/waybar-bottom-niri.png)

视频教程（旧版）：[「Niri 入门指南 2025」颠覆传统桌面体验，最适合新手的窗口管理器](https://www.bilibili.com/video/BV1fgUEBMEMZ/?share_source=copy_web&vd_source=1c6a132d86487c8c4a29c7ff5cd8ac50)

如果你想用我的配置文件一键安装 Niri，看：<https://github.com/SHORiN-KiWATA/shorin-arch-setup>

由于 Niri 很特别，所以简单介绍一下。

## 什么是 Niri？

Niri 官方的 demo 视频用几分钟简单地演示了 Niri 的特性，绝对值得一看：[Niri 演示视频](https://github.com/YaLTeR/niri)

Niri 的一切都是围绕 scrolling layout 滚动布局设计的。Niri 的特点：

1. 无限卷轴式平铺

    传统桌面不论是 Windows、Mac、KDE、GNOME、Hyprland、Sway，它们的工作区都只有一个屏幕的大小，新开的窗口会挤占其他窗口的空间。而 Niri 的工作区可以横向无限延伸，像是一个无限长的"卷轴"。

2. 垂直工作区切换

    顾名思义，工作区切换是垂直的而不是常见的水平切换。

3. 动态工作区数量增减

4. Column 合并

    可以将窗口合并到同一列，甚至可以开启标签页，这让 Niri 可以同时做到 master 布局、网格布局和标签页布局。

5. 其他细节设计

    比如 overview、快捷键教程、舒适的默认配置等等。

这些结合起来组成了极其舒适的桌面体验。

## 可选：更换 shell 为 fish

[FishShell](https://fishshell.com/)

由于会频繁用到命令行，有一个便利的 shell 会方便很多。

```bash
sudo pacman -S fish
```

运行 `fish` 命令即可打开 fish。

## 安装

[Niri-Getting-Started](https://yalter.github.io/niri/Getting-Started.html)

1. 安装

    ```bash
    sudo pacman -S niri xwayland-satellite xdg-desktop-portal-gnome fuzzel alacritty firefox
    # alacritty 可以换成你喜欢的终端仿真器，例如 Kitty / Foot / Ghostty
    ```

    出现选项选择 `pipewire-jack`。

    >`niri` 本体；

    >`xwayland-satellite` 提供 Xwayland 功能，Xwayland 是在 Wayland 上运行 X11 软件的兼容环境；

    >`xdg-desktop-portal-gnome` 是 Niri 推荐使用的桌面门户，提供文件选择、屏幕分享等功能；

    >`fuzzel` 是 Niri 默认的程序启动器；

    >`alacritty` 是 Niri 默认的终端仿真器；

    >`firefox` 是 Linux 上好用的浏览器；

2. 第一次运行（此时会生成配置文件）

    运行 `niri-session` 打开 Niri 会话。如果有显示管理器的话在显示管理器切换会话。

3. 可选：修改默认终端

    如果你使用的不是 `alacritty` 可以编辑配置文件修改按键打开的终端。

    `Super+Shift+E` 退出 Niri，用你喜欢的软件编辑 Niri 的配置文件：

    ```bash
    vim ~/.config/niri/config.kdl
    ```

    PS：没有特指的话后面所有"编辑配置文件"指的都是这个文件。

    `/` 键，搜索 `alacritty`，找到下面这行内容：

    ```text
    Mod+T hotkey-overlay-title="Open a Terminal: alacritty" { spawn "alacritty"; }
    ```

    >`hotkey-overlay-title="Open a Terminal: alacritty"` 设置 `Super+Shift+/` 打开的界面里的显示内容。改成 `=null` 可以隐藏。

    把 `spawn "alacritty"` 改成 `spawn "kitty" "-e" "fish"`

    - 关于 Niri 设置自定义快捷键

        当命令由多个部分组成时有两种写法。一种是 `spawn`，需要把命令分段写在多个引号里；

        ```text
        spawn "kitty" "-e" "fish"
        ```

        另一种是 `spawn-sh`，命令不用分段，直接写在一个引号里；

        ```text
        spawn-sh "kitty -e fish"
        ```

        `-sh` 的写法更方便，但是会有额外的性能开销，命令很长懒得分段或者命令中有 shell 符号时（如 `||`）使用 `-sh`。


4. 基础使用方法

    > `Super` 键就是 `Win` 键。

    `Super+Shift+/` 打开重要快捷键教程

    `Super+T` 打开终端

    `Super+D` 打开应用启动器

    `Super+U/I` 上下切换工作区

    知道这些就可以开始使用 Niri 啦，详细的按键教程可以后续看 `快捷键教程菜单` 和配置文件。

## 显示器配置

[niri_wiki_outputs](https://github.com/YaLTeR/niri/wiki/Configuration:-Outputs)

0. 可选：GUI

    ```bash
    sudo pacman -S wdisplays
    ```

    `wdisplays` 用于临时修改显示设置，无法保存到 Niri 文件。

1. 运行命令获取显示器信息

    ```bash
    niri msg outputs
    ```

    ```text
    Output "BOE NE156QHM-NY1 Unknown" (eDP-1)
      Current mode: 2560x1440 @ 165.000 Hz (preferred)
      Variable refresh rate: supported, disabled
      Physical size: 340x190 mm
      Logical position: 0, 0
      Logical size: 1920x1080
      Scale: 1.3333333333333333
      Transform: normal
      Available modes:
        2560x1440@165.000 (current, preferred)
        2560x1440@60.000 (preferred)
    ……………………
    Output "Shenzhen KTC Technology Group H27T22C 0x00000001" (DP-2)
      Current mode: 2560x1440 @ 180.000 Hz
      Variable refresh rate: supported, disabled
      Physical size: 600x330 mm
      Logical position: 1925, 0
      Logical size: 2560x1440
      Scale: 1
      Transform: normal
      Available modes:
        2560x1440@59.951 (preferred)
        2560x1440@180.000 (current)
        2560x1440@164.999
    ………………
    ```

    记住 `eDP-1` 和 `DP-2` 这部分名称，然后在 `available modes` 里找到自己需要的模式，格式为 `分辨率@刷新率`。

2. 配置文件内修改 ``output{}``

    左斜杠搜索 `output` 在示例配置下面自己写一个

    ```text
    output "eDP-1"{
     //分辨率和刷新率
     mode "2560x1440@165"
     //缩放倍率
     scale 1.33
     //位置，x=0 y=0 代表最左上角
     position x=0 y=0
     //启动时聚焦此显示器
     focus-at-startup
     //取消下面这行的注释设置可变刷新率
     //variable-refresh-rate
     //取消下面这行的注释可以设置旋转，参数有：90, 180, 270, flipped（水平翻转）, flipped-90（水平翻转后旋转）, flipped-180 and flipped-270
     //transform "90"

    }
    ```

3. 多显示器的情况

    需要给每一个显示器都配置一个 `output{}`，通过 `DP-2` 这样的名称指定该配置生效的显示器。

    显示器的位置关系需要一些计算，根据你的显示器的摆放位置，把最左边或者最左上角的显示器的位置设置为 `position x=0 y=0`，然后以此为原点设置其他显示器的位置。

    我的 `eDP-1` 显示器位置是 ``x=0 y=0`` 在最左上角，我想把 DP-2 显示器放在它的右边，那就要更改 `x=0` 的值。eDP-1 的分辨率是 2560x1440，1.33 缩放，那横向像素就是 `2560/1.33=1924.81203008`，约等于 `1925`。那我 DP-2 的位置就应该设置为 ``x=1925 y=0``。以此类推，想放在下面就修改 y 轴的值，设置了旋转的话计算的时候横竖的值也要对应旋转。

    ```text
     output "DP-2"{
     mode "2560x1440@180"
     scale 1
     position x=1925 y=0
    }
    ```

## 关闭鼠标加速

[niri_wiki_input](https://github.com/YaLTeR/niri/wiki/Configuration:-Input)

找到 `input{mouse{}}`，取消 `accel-profile "flat"` 的注释。

```text
mouse {
    //取消下面这行注释修改鼠标速度，正数加快，负数减慢
    //accel-speed -0.2
    //鼠标加速是默认开启的，设置这一行可以关闭鼠标加速度
    accel-profile "flat"
    //滚轮滚动速度，如果是负号的话会变更方向
    //scroll-factor horizontal=2.0 vertical=-1.0
}
```

## 重要程序

[Niri-List-of-Important_Software](https://yalter.github.io/niri/Important-Software.html)

[Niri-XWayland](https://yalter.github.io/niri/Xwayland.html)

1. 安装

    ```bash
    sudo pacman -S libnotify mako polkit-gnome
    ```

    >`mako` 精简好用的通知服务。

    >`polkit-gnome` 需要管理员权限的软件会通过 polkit 询问权限，没有 polkit 的话就无法启动，例如 `btrfs-assistant`。

2. 设置重要程序在 Niri 启动时自动启动

    Niri 会话是作为 systemd 服务启动的，所以可以用 systemd 启动那些重要程序，但是修改 Niri 配置文件会更方便。

    ```bash
    vim ~/.config/niri/config.kdl
    ```

    搜索 `spawn-at-startup`，在合适的地方写入：

    ```text
    spawn-at-startup "/usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1"

    spawn-at-startup "mako"
    ```

3. 现在启动

    ```bash
    /usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1 & disown
    ```

    ```bash
    mako & disown
    ```

    >`&` 代表在终端后台运行。

    >`disown` 命令从终端解绑程序。

- 编辑 mako 的配置文件设置通知的显示时长

    ```bash
    # 创建目录
    mkdir -p ~/.config/mako
    # 编辑文件
    vim ~/.config/mako/config
    ```

    ```text
    default-timeout=8000
    border-radius=8
    ```

    ```bash
    # 重新加载配置
    makoctl reload
    ```

## 修改系统语言为中文

利用配置文件提供的环境变量功能设置系统语言。

```text
environment {
    LANG "zh_CN.UTF-8"
    LC_CTYPE "en_US.UTF-8"
}
```

用 `LANG` 变量设置本地化使用中文。再把 `LC_CTYPE` 设置为英文解决输入法漏字的异常。

>已知问题：`LC_CTYPE` 为英文导致 Steam 无法输入中文，可以 `yay -S pins-git` 安装 `pins` 编辑 Steam 的 .desktop 文件，在 `Exec=` 的开头添加 `env LC_CTYPE=zh_CN.UTF-8` 以中文启动 Steam。

- 如果是 archinstall 安装的系统，需要额外进行如下操作：

  1. ```bash
     sudo vim /etc/locale.gen
     ```

  2. 左斜杠键搜索，取消 `zh_CN.UTF-8` 的注释

  3. ```bash
     sudo locale-gen
     ```

  4. 登出

## 安装中文输入法

0. 需要[添加 archlinuxcn](安装桌面环境前的准备#AUR助手)

1. 安装

    看中文输入法一节：[中文输入法](中文输入法)

2. 设置环境变量

    在 Niri 配置文件的 `environment{}` 里面写入 `XMODIFIERS "@im=fcitx"` 即可

3. 现在启动

    ```bash
    fcitx5 -d
    ```

4. 自动启动

    ```text
    spawn-at-startup "fcitx5" "-d"
    ```

5. 可选：设置开关输入法的快捷键

    ```text
    Mod+F1 {spawn-sh "pkill fcitx5 || fcitx5";}
    ```
    >输入法卡住的时候可以快捷重启（输入法为什么会卡住你别问）

## 配置图形化文档管理器

### Nautilus

安装 `xdg-desktop-portal-gnome` 会把 `nautilus` 作为依赖装上，这是 GNOME 桌面环境的文档管理器。使用这条命令补全它的功能：

```bash
sudo pacman -S ffmpegthumbnailer gvfs-smb nautilus-open-any-terminal file-roller gnome-keyring gst-plugins-base gst-plugins-good gst-libav icoextract python-pillow
```
<details close><summary>[展开]软件包的介绍</summary>

>`ffmpegthumbnailer` 视频预览。

>`gvfs-smb` 检查可挂载的外部设备，访问 smb 分享等功能。

>`nautilus-open-any-terminal` 右键从此处打开终端。

>`file-roller` 提供压缩解压缩功能。

>`gnome-keyring` 提供密码保存功能。第一次保存密码会让你设置 keyring 的密码，可以空着。

>`gst-plugins-base gst-plugins-good gst-libav` 这些让你可以预览视频信息。

>`icoextract` `python-pillow` exe 缩略图。

>可选：

>`nautilus-image-converter` 右键方便调整图片大小或者旋转。

>`libheif webp-pixbuf-loader libopenraw gst-plugins-bad gst-plugins-ugly` 提供更多视频、图片格式支持。

>`gnome-font-viewer` 字体缩略图和字体管理。

</details>

- 更改默认终端为 Kitty（你使用的终端）

    安装 `xdg-terminal-exec`，这个包需要从 AUR 安装：

    ```bash
    yay -S xdg-terminal-exec
    ```

    编辑 `~/.config/xdg-terminals.list` 设置 Kitty 为第一优先级：

    ```bash
    echo "kitty.desktop" > ~/.config/xdg-terminals.list
    ```

    >此处的 `kitty.desktop` 应为你使用的终端的实际 `.desktop` 文件名称。

    如果需要多个终端的话就按照优先级顺序从上到下写多行。

- 设置 Nautilus `右键从此处打开 Kitty`

    使用 dbus 设置 dconf。

    ```bash
    gsettings set com.github.stunkymonkey.nautilus-open-any-terminal terminal kitty
    ```

- 设置右键从此处打开 Kitty 的 shell 为 fish

    从 Nautilus 右键打开 Kitty 默认是 bash，可以编辑 Kitty 的配置文件设置默认使用 fish：

    ```bash
    vim ~/.config/kitty/kitty.conf
    ```

    写入

    ```text
    shell fish
    ```

    美化 Kitty 的部分在这里：[Kitty 美化](终端美化#Kitty美化)

- 设置打开文档管理器的快捷键

    ```bash
    vim ~/.config/niri/config.kdl
    ```

    找到 `binds{}`，在里面新建：

    ```text
    Mod+E { spawn "nautilus";}
    ```

- Issue: 如果 Nautilus 启动慢

    如果你是带 N 卡的双显卡配置，大概率是因为 GTK4 使用的新的渲染器和 N 卡驱动工具之间有一些兼容性问题，解决办法是用以下环境变量启动 Nautilus，让它使用旧的渲染器：

    >编辑 .desktop 文件推荐从 AUR 安装 pins：`yay -S pins-git`

    ```bash
    env GSK_RENDERER=gl nautilus
    ```

### 可选：Thunar

[Xfce4-Projects](https://www.xfce.org/projects)

如果你不想用 Nautilus，我推荐使用 `xdg-desktop-portal-gtk` 的 Thunar，功能强大，高度可自定义，且内存占用仅 50MB。

```bash
sudo pacman -S --needed xdg-desktop-portal-gtk thunar tumbler ffmpegthumbnailer poppler-glib gvfs-smb file-roller thunar-archive-plugin gnome-keyring thunar-volman gvfs-mtp gvfs-gphoto2 webp-pixbuf-loader icoextract python-pillow
```

<details close><summary>[展开]软件包介绍</summary>

>`xdg-desktop-portal-gtk` 是 GTK 的 xdg 桌面门户。

>`tumbler` 提供图片预览功能。

>`ffmpegthumbnailer` 视频预览。

>`poppler-glib` PDF 预览。

>`gvfs-smb` 检查可挂载的外部设备，访问 smb 分享等功能。

>`file-roller` 提供压缩解压缩功能。

>`thunar-archive-plugin` 在 Thunar 的右键菜单添加压缩解压缩选项。

>`gnome-keyring` 提供密码保存功能。第一次保存密码会让你设置 keyring 的密码，可以空着。

>`thunar-volman` 自动管理移动硬盘等设备。

>`gvfs-mtp` 连接手机。

>`gvfs-gphoto2` 连相机。

>`webp-pixbuf-loader` webp 缩略图。

>`icoextract` `python-pillow` exe 缩略图。

</details>

预览远程服务器上的图片要调整首选项中的 `缩略图` 为 `总是`。

- 清理没什么用的侧边栏书签

    在侧边栏的空白处右键

- 右键从此处打开终端

    Thunar 提供了强大的自定义右键功能。点击左上角 `编辑` > `配置自定义动作` > 选中 `open in terminal here` > 点击小齿轮 > 命令改成 `kitty`。

- 配置使用 Thunar 进行文件选取

    Niri 默认使用 GNOME 的桌面门户进行文件选取，需要调整为 GTK 配合 Thunar 使用：

    ```bash
    mkdir -p ~/.config/xdg-desktop-portal/
    vim ~/.config/xdg-desktop-portal/niri-portals.conf
    ```

    ```ini
    [preferred]
    default=gnome;gtk;
    org.freedesktop.impl.portal.FileChooser=gtk
    ```

    >`default=gnome;gtk;` 设置默认门户是 GNOME，回退门户是 GTK。这会让除文件选取以外的功能都使用 GNOME 门户，如 `屏幕分享`。

    >`org.freedesktop.impl.portal.FileChooser=gtk` 设置文件选择用 GTK。

    >如果你使用的是 KDE 的 dolphin，可以把 gtk 改成 KDE。

- Issue: 如果使用 dolphin 没有默认应用菜单

    ```bash
    sudo pacman -S archlinux-xdg-menu
    ```

    编辑 Niri 的环境变量

    ```text
    XDG_MENU_PREFIX "arch-"
    ```

## 锁屏

Niri 默认配置文件里使用了 `swaylock`。

1. 安装

    ```bash
    yay -S swaylock-effects
    ```
    >这是带美观效果的 `swaylock`

2. 创建目录并编辑配置文件

    ```bash
    mkdir -p ~/.config/swaylock
    vim ~/.config/swaylock/config
    ```

    ```text
    screenshots
    clock
    indicator
    indicator-radius=200
    indicator-thickness=15
    effect-blur=10x5
    font=Noto Sans CJK SC
    ```

    从上到下分别是：

    ```text
    用桌面当背景
    显示时钟
    显示圆环
    圆环大小
    圆环粗细
    背景模糊
    字体（如果不设置这一项并且你没有设置 fontconfig 的话中文会乱码，具体使用什么字体取决于你安装了哪个字体。可以使用 gnome-font-viewer 查看）
    ```

Niri 默认设置了一个 `Mod+Alt+L` 锁屏的快捷键，如果要修改可以在配置文件搜索 `swaylock`。

## 自动熄屏锁屏睡眠

使用 `swayidle`

1. 安装

    ```bash
    sudo pacman -S swayidle
    ```

2. 创建 `swayidle` 脚本

    >虽然 Niri 的 wiki 说可以使用 systemd，但是为了方便移植，我使用脚本。

    ```bash
    mkdir -p ~/.config/niri/scripts
    vim ~/.config/niri/scripts/swayidle.sh
    ```

    ```bash
    #!/usr/bin/env bash

    # 5 分钟锁屏，10 分钟熄屏，20 分钟睡眠
    # swaylock -f 是前台运行 swaylock，如果不加的话后续的 timeout 命令会不生效

    swayidle -w \
        timeout 300  'swaylock -f' \
        timeout 600  'niri msg action power-off-monitors' \
        resume       'niri msg action power-on-monitors' \
        timeout 1200 'systemctl suspend' \
    ```
    > 因兼容性问题，此处会报错 `Failed to parse get BlockInhibited property: Invalid argument`。属于正常情况，不影响脚本功能。

    添加可执行权限

    ```bash
    chmod +x ~/.config/niri/scripts/swayidle.sh
    ```

    现在开启

    ```bash
    bash ~/.config/niri/scripts/swayidle.sh & disown
    ```

    设置自动启动

    ```text
    spawn-at-startup "~/.config/niri/scripts/swayidle.sh"
    ```

## 蓝牙

[ArchWiki Bluetooth](https://wiki.archlinux.org/title/Bluetooth)

这里使用 `bluetui`。

```bash
sudo pacman -S --needed bluez bluetui
```

```bash
sudo systemctl enable --now bluetooth
```

`bluetui` 可以打开终端交互界面

## 剪贴板

你有两个选择，一个开箱即用，一个需要更有趣，但是要自己配置。

- [Clipse](#clipse)
- [Cliphist](#cliphist)

### Clipse

1. 安装

    ```bash
    yay -S wl-clipboard clipse clipse-gui
    ```
    > `wl-clipboard` Wayland 合成器的标配剪贴板工具。

    > `clipse` 是一个 TUI 剪贴板程序。

    > `clipse-gui` 是基于 GTK 的图形界面。

2. 自动启动

    ```text
    spawn-at-startup "clipse" "--listen"
    ```

3. 现在启动

    ```bash
    clipse --listen
    ```

4. 设置打开 `clipse-gui` 的快捷键

    ```text
    Mod+Alt+V {spawn "clipse-gui";}
    ```

5. 以浮动模式打开 `clipse-gui`

    ```bash
    niri msg pick-window
    ```

    点选 clipse-gui 的窗口获取窗口信息，主要使用 `title` 或者 `app-id` 指定窗口。然后编辑 Niri 的配置文件搜索 `window-rule`，在合适的位置自己写一个窗口规则的代码块。

    >或者搜 `open-floating`，Niri 的默认配置里有一个被 `/-` 注释掉的示例配置。

    ```text
    window-rule {
        //match app-id 用 appid 指定窗口规则生效的窗口
        match app-id="clipse-gui"

        //规则是以浮动模式打开窗口
        open-floating true
    }
    ```

6. 禁用选取后自动粘贴

    clipse-gui 的配置文件里写入 `enter_to_paste = False` 可以禁用复制即粘贴，但是似乎没有生效。解决办法是把 `paste_simulation_cmd_wayland=` 里的命令改成 true。

    ```text
    paste_simulation_cmd_wayland = true
    ```

- Clipse 的 TUI

    刚才介绍了，Clipse 是一个 TUI，你可以直接在终端运行 `clipse` 命令打开 TUI 界面。如果你要使用 TUI 的话以下是示例配置：

    ```text
    Mod+Alt+V {spawn-sh "kitty --class clipse -e clipse";}
    ```

    ```text
    window-rule {
        match app-id="clipse"
        open-floating true
    }
    ```

### Cliphist

Cliphist 是一个剪贴板历史 CLI（命令行工具），我们可以基于这个工具自定义属于自己的图形界面。

1. 安装

    ```bash
    sudo pacman -S cliphist wl-clipboard
    ```

    >`wl-clipboard` 是 Wayland 合成器标配剪贴板工具。

    >`cliphist` 提供剪贴板历史记录功能。

2. 现在启动

    ```bash
    wl-paste --watch cliphist store & disown
    ```

    原理是开启 `wl-paste --watch` 监测剪贴板变化。每一次出现新条目时自动运行 `cliphist store` 保存到 cliphist 的历史记录里。

    cliphist 保存的剪贴板历史可以通过 `cliphist list` 查看。

    `cliphist decode` 通过传入的 cliphist **列表序号**解码真实的数据，这个数据存放在 `.cache/cliphist/db`

3. 设置守护进程自动启动

    ```text
    spawn-at-startup "wl-paste" "--watch" "cliphist" "store"
    ```

- 小游戏

    这里我们可以玩一些小游戏。安装 `fzf`，这是一个模糊搜索、TUI 菜单程序。

    ```bash
    sudo pacman -S fzf
    ```

    复制点东西，运行：

    ```bash
    cliphist list | fzf
    ```

    这条命令把 cliphist 的列表数据传给了 fzf，你会得到一个可供选择的剪贴板历史菜单。回车任意选择一项，终端就会打印出 `1    这是我的剪贴板历史` 格式的内容，这是 cliphist 的列表数据格式。

    再试着运行以下命令：

    ```bash
    cliphist list | fzf | cliphist decode
    ```

    通过 `decode`，可以将列表数据转换为原本的剪贴板内容并打印在终端（注意，这不是简单的去掉序号，图片数据经过 `decode` 会从纯文字变成二进制数据）。

    接下来再试试运行这段命令：

    ```bash
    cliphist list | fzf | cliphist decode | wl-copy
    ```

    >`wl-copy` 将数据写入当前剪贴板。

    至此，一个简易的剪贴板 TUI 就做好了，我觉得这很有趣，分享给你。这个小游戏里我们使用 `fzf` 处理数据，还可以使用别的东西，比如类似 `fuzzel` 的菜单程序，万变不离其宗，原理都是一样的。

    ```text
    cliphist | fuzzel -d | cliphist decode | wl-copy
    ```

4. 安装 TUI

    我做的 TUI，使用 `kitty icat` 进行图片预览，原理就是刚刚小游戏中的原理，占用仅 7MB。

    <https://github.com/SHORiN-KiWATA/cliphist-tui>

    ```bash
    yay -S cliphist-tui-git
    ```

    运行 `cliphist-tui` 命令就能打开

    记得设置 TUI 的快捷键：

    ```text
    Mod+Alt+V {spawn-sh "kitty --single-instance --class cliphist-tui -e cliphist-tui";}

    // 因为这是一个 bash 脚本，所以快捷键命令会长一些
    // --single-instance 避免每次开 Kitty 都新开进程导致不必要的内存占用
    // --class 指定要打开的 Kitty 的 app-id
    // -e 指定打开时自动运行的命令
    ```

    以浮动模式打开：

    ```text
    window-rule{
        //用 app-id 指定窗口
     match app-id="cliphist-tui"
        // 默认长宽

    default-column-width { fixed 625; }
        default-window-height { fixed 700; }
     //以浮动模式打开
        open-floating true
     //默认打开位置，这里的 x 和 y 是偏移量。这里的例子是在顶部中心打开，y 轴向下 18 个逻辑像素
        default-floating-position x=0 y=18 relative-to="top"
    }
    ```

## 截图

Niri 自带了截图功能，不仅可以截区域，还可以截取窗口或者全屏，很好用。在配置文件搜索 `screenshot` 可以找到键位。`screenshot-path` 可以设置壁纸保存的位置和文件名模板。



### 编辑截图

>有一个新项目叫 [mark-shot](https://github.com/jswysnemc/mark-shot)，感兴趣的可以尝试，开箱即用，功能非常全面。

我使用 `satty`

```bash
sudo pacman -S satty
```

- 设置 satty 的复制命令为 `wl-copy`

    ```bash
    mkdir -p ~/.config/satty
    vim ~/.config/satty/config.toml
    ```

    ```toml
    [general]
    copy-command = "wl-copy"
    focus-toggles-toolbars= true
    actions-on-right-click = ["save-to-clipboard"]
    [font]
    family = "Noto Sans"
    style = "Regular"
    fallback = [
        "Noto Sans CJK SC",
        "Noto Sans CJK JP",
        "Noto Sans CJK TC",
        "Noto Sans CJK KR"
    ]
    ```

    >`focus-toggles-toolbars= true` 设置自动隐藏工具栏。

    >`actions-on-right-click = ["save-to-clipboard"]` 设置右键复制到剪贴板。

    >`[font]` 这块的设置中文字体可以让 satty 支持输入中文。

- 设置编辑截图的快捷键

    Niri 截图的命令行工具暂时不支持把图片的数据传给别的软件，但截图数据会自动保存到剪贴板，我们可以从剪贴板获取图片数据。

    ```text
    Mod+Shift+S {spawn-sh "wl-paste | satty -f -";}
    ```

    先用 Niri 的截图工具截图（不论全屏、选择区域、聚焦窗口截图都可以），然后按下这个快捷键手动让 satty 读取剪贴板里的那张截图。最可控，最简单，无额外性能开销。

## 屏幕分享

录屏推荐使用 obs 或者 kooha。想要最好的录屏效果可以了解一下 `wf-recorder` 或 `wl-screenrec`，`wl-screenrec` 性能更好。

Niri 通过 GNOME 的 xdg 桌面门户进行屏幕分享，我们已经安装了，此时应该已经可以用了。如果无法使用的话设置：

```text
spawn-sh-at-startup "dbus-update-activation-environment --systemd WAYLAND_DISPLAY XDG_CURRENT_DESKTOP=niri & /usr/lib/xdg-desktop-portal-gnome"
```

>通过 `WAYLAND_DISPLAY` 和 `XDG_CURRENT_DESKTOP=niri` 这两个变量让 dbus 和 systemd 知道我的当前 Wayland 会话是哪个，桌面环境是什么。然后确保启动 GNOME 的桌面门户提供屏幕分享功能。设置完之后要重启 Niri。

## 软件商城

```bash
sudo pacman -S bazaar
```

## Alt+Tab 切换窗口

Niri 自带

<https://github.com/YaLTeR/niri/wiki/Configuration:-Recent-Windows>

以下是一个示例配置

```text
// 带缩略图的 Alt+Tab 切换窗口功能（但是我设置的是 Super+Tab，更符合逻辑）
recent-windows {
    // 取消 //off 的注释可以禁用
    // off
    debounce-ms 750
    open-delay-ms 150

    highlight {
        active-color "#999999ff"
        urgent-color "#ff9999ff"
        // 缩略图背景内间距
        padding 30
        // 缩略图的背景圆角
        corner-radius 12
    }

	//设置缩略图大小
    previews {
        max-height 480
        max-scale 0.2
    }

    binds {
        // scope 可以设置显示的窗口是当前工作区的、还是当前显示器的、或者显示全部窗口
        Mod+Tab         { next-window scope="workspace"; }
        Mod+Shift+Tab   { previous-window scope="workspace"; }
        // grave 是波浪键，显示当前应用的所有窗口
        Mod+grave       { next-window     filter="app-id"; }
        Mod+Shift+grave { previous-window filter="app-id"; }
    }
}
```

## 笔记本屏幕亮度调节

笔记本用户装这个包之后可以用笔记本键盘的快捷键调节屏幕亮度

```bash
sudo pacman -S brightnessctl
```

## 壁纸切换

使用 `awww` 和 `waypaper`。

1. 安装

    ```bash
    yay -S awww waypaper
    ```

2. 打开 waypaper 切换壁纸

3. 设置 `awww-daemon` 自动启动

    ```text
    spawn-at-startup "awww-daemon"
    ```

4. 设置快捷键

    ```text
    Mod+Alt+W {spawn "waypaper";}
    ```

5. 设置窗口规则

    打开 waypaper 窗口，运行：

    ```bash
    niri msg pick-window
    ```

    选择 waypaper 窗口获取窗口信息，然后在 Niri 的配置文件里面设置窗口规则

    ```text
    window-rule {

        match app-id="waypaper"

        open-floating true
    }
    ```

## 面板（任务栏）

[Github-Wiki-Waybar](https://github.com/Alexays/Waybar/wiki)

初学使用 waybar 即可

1. 安装

    ```bash
    sudo pacman -S waybar ttf-jetbrains-mono-nerd otf-font-awesome
    ```

    >`ttf-jetbrains-mono-nerd` 提供图标文字。

    >`otf-font-awesome` 是 waybar 的基础字体包依赖。

2. 现在启动

    ```bash
    waybar & disown
    ```

3. 开机自启

    编辑 Niri 的配置文件

    ```bash
    vim ~/.config/niri/config.kdl
    ```

    ```text
    spawn-at-startup "waybar"
    ```

4. 设置重启 waybar 的快捷键

    后续自定义 waybar 需要频繁更新 waybar 配置，所以设置一个重启 waybar 的快捷键。

    ```bash
    vim ~/.config/niri/config.kdl
    ```

    找到快捷键的部分，新增以下内容

    ```text
     Mod+F12 {spawn-sh "pkill waybar || true && waybar";}
    ```

    >`Mod+F12` 设置具体的快捷键为 Mod+F12。

    >`{spawn-sh "";}` 设置具体命令，与 `spawn` 不同，`spawn-sh` 可以在引号里写入完整的命令，而 `spawn` 要把命令拆开放在多个引号里。

    >`pkill waybar` 按照进程名字关闭 waybar。

    >`||` 如果左边的命令运行失败则运行右边的命令。

    >`true` 输出一个运行成功的信号。

    >`&&` 如果运行成功则运行下一条命令。

    >`waybar` 开启 waybar。

    这段命令的完整意思是：尝试 `pkill waybar` 杀死 waybar 进程，成功则运行 `waybar` 开启 waybar，失败（waybar 尚未启动的情况下 pkill 会运行失败）则运行 `true` 发送成功信号触发 `waybar` 命令开启 waybar。

### 使用我的配置

我之前直播重装 Niri 的时候新配置了一个类似 Windows 11 布局的 waybar，可以基于壁纸自动更改颜色，有兴趣的可以使用。

1. 安装依赖

    ```bash
    yay -S --needed cava grim slurp hyprpicker ddcutil-service wl-longshot-git shorin-contrib-git shorin-screenrec-menu-git wf-recorder wl-screenrec
    ```

    >`grim` 截图工具。

    >`slurp` 选取区域工具。

    >`hyprpicker` 提取屏幕颜色。

    >`ddcutil-service` ddc 调节外接屏幕亮度。

    >`wl-longshot-git` 截图模块的长截图功能。

    >`shorin-contrib-git` 更新模块、常用命令等功能。

    >`shorin-screenrec-menu-git` `wf-recorder` `wl-screenrec` 录屏模块。

    - ddcutil 安装和使用方法

         [我的 GNOME 自定义设置#调节外接屏幕亮度](我的GNOME自定义设置#调节外接屏幕亮度)

        需要添加组然后重启

        ```bash
        sudo gpasswd -a $USER i2c
        reboot
        ```

2. 下载我的仓库

    ```bash
    git clone https://github.com/SHORiN-KiWATA/shorin-niri.git
    ```

    找到 `dotfiles/.config/waybar-niri-LikeWin11` 文件夹，复制到 `~/.config/` 目录下，把文件夹重命名为 `waybar`，然后重启 waybar 就可以啦。

#### 根据壁纸自动更改 waybar 颜色

使用 matugen 根据壁纸生成颜色，让 waybar 自动变更颜色。

1. 安装 matugen

    ```bash
    yay -S matugen
    ```

2. 创建需要的目录和配置文件

    ```bash
    mkdir -p ~/.config/matugen
    mkdir -p ~/.config/matugen/templates
    ```

3. 复制颜色模板

    找到我文档里的 `dotfiles/.config/matugen/templates/` 目录，把 `colors.css` 文件复制粘贴到 `~/.config/matugen/templates` 目录里。

4. 编辑 matugen 配置文件

    ```bash
    vim ~/.config/matugen/config.toml
    ```

    写入如下内容：

    ```toml
    [config.wallpaper]
    command = "awww"

    [templates.waybar]
    input_path = '~/.config/matugen/templates/colors.css'
    output_path = '~/.config/waybar/colors.css'
    ```

5. 编辑 waypaper 的配置文件

    ```bash
    vim ~/.config/waypaper/config.ini
    ```

    把 `post_command` 改成：

    ```ini
    post_command = matugen image $wallpaper --source-color-index 0
    ```
    >`--source-color-index` 是新版 matugen 的选项，可以在多个 `source color` 中进行选择。

6. 使用 waypaper 切换壁纸

## Niri 配置文件修改

1. 全局窗口规则

    搜索 `geometry-corner-radius`，会搜到一个被注释掉的 window-rule，这是 Niri 默认配置配置文件自带的全局生效的窗口规则。删除前面的 `/-` 取消注释：

    ```text
    window-rule {
        //圆角
        geometry-corner-radius 8
        //剪掉圆角外的窗口内容
        clip-to-geometry true
        //透明度
        opacity 0.99
        //禁止边框画到窗口后面
        draw-border-with-background false
    }
    ```

2. 边框

    `focus-ring` 可以调整窗口的边框。

3. 隐藏窗口的标题栏

    ```text
    prefer-no-csd
    ```

4. 聚焦跟随鼠标

    搜索 `focus-follows-mouse`

5. 切换聚焦自动移动鼠标到聚焦窗口上

    搜索 `warp-mouse-to-focus`

6. 切换光标主题

    强烈推荐 breeze 光标主题
    ```bash
    sudo pacman -S breeze-cursors
    ```
    在合适的位置写入：

    ```text
    cursor {
        //鼠标的光标主题
        xcursor-theme "breeze_cursors"

        //大小
        xcursor-size 30

        //闲置 15s 自动隐藏光标
        hide-after-inactive-ms 15000

    }
    ```

## 设置 overview 背景壁纸

Mod+O 键打开的 Overview 的背景现在是灰色的，我们来设置壁纸。

任意壁纸程序都可以，这里以 awww 为例。

1. 启用壁纸程序

    awww 可以同时运行多个不同 namespace 的守护进程，所以我们可以创建一个专门用于 overview 壁纸的 awww 守护进程。

    ```bash
    awww-daemon -n overview
    ```

2. 获取 layer 的 namespace

    ```bash
    niri msg layers
    ```

    会找到 `awww-daemonoverview` 这个 layer

3. Niri 配置文件里设置 layer 规则

    通过 `place-within-backdrop true` 这个规则把刚刚运行的壁纸程序放进 overview

    ```text
    layer-rule{
        match namespace="awww-daemonoverview"
        place-within-backdrop true
    }
    ```

4. 设置一个喜欢的壁纸

    需要用 `-n` 选项指定 overview 的 awww 守护进程

    ```bash
    awww img 你喜欢的壁纸.png -n overview
    ```

然后你就可以发挥想象力了。比如利用 `imagemagick` 提供的 `magick` 命令自动把当前壁纸处理成模糊暗色版本放进 overview 之类的。

## 窗口模糊-Blur

>Niri 自 26.04 版本开始支持 Blur 效果。

编辑 Niri 配置文件

```bash
vim ~/.config/niri/config.kdl
```

以下是我的推荐配置：

```text
// --- NIRI BLUR START ---
// 顶层的 blur 配置，细节调整 blur 的效果
blur {
    passes 3
    offset 3
    noise 0.02
    saturation 1.5
}
// 全局窗口规则。让所有普通窗口以 xray 的形式显示 blur。xray 仅渲染一次模糊版本的背景，然后将其以类似"壁纸"的形式显示在窗口后面，不是实时渲染模糊，所以完全没有性能消耗。
window-rule {
    background-effect {
        xray true
        blur true
    }
}
// 浮动窗口禁用 xray 可以实时渲染模糊效果但是性能消耗高，开启 xray 会穿过浮动窗口底下的窗口直接透视到桌面。看个人喜好选择禁用与否吧。
window-rule {
    match is-floating=true
    background-effect {
        xray true
        blur true
    }
}
// fuzzel 专属的 layer 规则
layer-rule {
    match namespace="^launcher$"
    geometry-corner-radius 8
    background-effect {
        xray false
        blur true
    }
}
// --- NIRI BLUR END ---
```

## 可选：大写锁定显示

- swayosd

    ```bash
    sudo pacman -S swayosd
    ```

    开启监控输入的后端

    ```bash
    sudo systemctl enable --now swayosd-libinput-backend.service
    ```

    设置自动启动

    ```text
    spawn-at-startup "swayosd-server"
    ```

## 可选：自动登录

配置完的效果是进入 TTY1 自动登录，然后自动打开 Niri 会话。完全不用输密码，不用输命令。适合单用户单桌面会话的情况。如果你想要有一个登录界面方便管理多用户，看[ArchWiki Display Manager](https://wiki.archlinux.org/title/Display_manager)。


[ArchWiki getty](https://wiki.archlinux.org/title/Getty)

- 自动登录 TTY

  ```bash
  sudo mkdir -p /etc/systemd/system/getty@tty1.service.d/
  ```

  ```bash
  sudo vim /etc/systemd/system/getty@tty1.service.d/autologin.conf
  ```

  ```ini
  [Service]
  ExecStart=
  ExecStart=-/sbin/agetty --noreset --noclear --autologin shorin - ${TERM}
  ```

  `shorin` 改成要自动登录的账户的用户名

- 自动启动 Niri

  [Autostarting Niri without a DM](https://www.reddit.com/r/niri/comments/1kdgc08/autostarting_niri_without_a_dm/)

  ```bash
  mkdir -p ~/.config/systemd/user
  ```

  ```bash
  vim ~/.config/systemd/user/niri-autostart.service
  ```

  ```ini
  [Service]
  ExecStart=/usr/bin/niri-session

  [Install]
  WantedBy=default.target
  ```

  ```bash
  systemctl --user enable niri-autostart.service
  ```

- 重启电脑

## Reference

其他更详细的配置内容可以查阅[Niri 的官方文档](https://niri-wm.github.io/niri/)。

接下来你可以按照自己的需求决定安装什么软件。当然，你也可以选择参考我的

下一节：[软件安装相关](软件安装相关)

---

# 安装Hyprland

目录

- [⚠️这一章内容已经严重过时](#️这一章内容已经严重过时)
  - [可选：更换 shell 为 fish](#可选更换shell为fish)
  - [安装 hyprland](#安装hyprland)
  - [修改系统语言](#修改系统语言)
  - [显示器设置](#显示器设置)
  - [禁用鼠标加速](#禁用鼠标加速)
  - [触摸板自然滚动](#触摸板自然滚动)
  - [xwayland 缩放问题](#xwayland缩放问题)
  - [安装必要软件](#安装必要软件)
  - [GUI 文档管理器](#gui文档管理器)
    - [右键从此处打开终端](#右键从此处打开终端)
    - [更改默认终端为 kitty](#更改默认终端为kitty)
    - [生成 home 目录下的目录](#生成home目录下的目录)
  - [桌面套件](#桌面套件)
    - [程序启动器](#程序启动器)
  - [蓝牙](#蓝牙)
  - [锁屏](#锁屏)
  - [剪贴板](#剪贴板)
  - [截图](#截图)
  - [中文输入法](#中文输入法)
  - [flatpak](#flatpak)
  - [下一节：软件安装相关](#下一节软件安装相关)

# ⚠️这一章内容已经严重过时

hyprland 从 0.55 版本开始用 lua 替代原本的 hyprlang 作为配置文件的语言，配置流程不变，但配置的具体写法已经完全不同，我还没更新。

---
这部分是在 tty 从零开始安装一个**功能完备**的 hyprland，以方便为主而不是以符合 WM 的理念为主，如果已经安装了其他桌面环境的话有些流程会略有不同。


## 可选：更换 shell 为 fish

[FishShell](https://fishshell.com/)

由于要频繁用到终端，安装 fish 更加便利。

安装：

```
sudo pacman -S fish
```

运行 fish 命令就可以打开 fish 了。

如果想在打开终端的时候自动进入 fish 的话可以设置类似 `kitty -e fish` `ghostty -e fish` 这样的快捷键。

## 安装 hyprland

[Hyprland-Installation](https://wiki.hypr.land/Getting-Started/Installation/)

```
sudo pacman -S hyprland kitty firefox
```
>`hyprland` 本体。

>`kitty` 是 hyprland 默认的终端仿真器，如果你已经安装了别的桌面环境可以不装 `kitty`。

>`firefox` 是 Linux 最好用的浏览器。

- 基础使用方法

   tty 运行 `start-hyprland` 命令打开会话，或者在显示管理器切换为 hyprland 会话。super+Q 打开 kitty；super+C 关闭窗口。

   虽然 hyprland 新版本增加了引导程序，但是为了学会使用 WM，这里依旧手动配置。

- 修改默认终端

   1. 运行一次 `start-hyprland` 生成默认配置文件。

   2. super+M 退出 hyprland。

   3. 编辑配置文件

      ```
      vim ~/.config/hypr/hyprland.conf
      ```
      把 `$terminal= kitty` 的 `kitty` 改成你使用的终端。

- 设置 kitty 默认 shell 为 fish

   ```
   mkdir -p ~/.config/kitty/kitty.conf
   vim ~/.config/kitty/kitty.conf
   ```

   ```
   shell fish
   ```

   美化 kitty 的部分在这里：[kitty 美化](终端美化#Kitty美化)

## 修改系统语言

利用配置文件提供的环境变量功能设置 LANG 系统语言。设置时一定要让 LC_CTYPE 为英文，否则中文输入法会出现异常。

配置文件顶端写入：

```
env = LANG,zh_CN.UTF-8
env = LC_CTYPE,en_US.UTF-8
```
重新开启 hyprland 即可。

- 如果是 archinstall 安装，需要进行如下操作：

  1. ```
     sudo vim /etc/locale.gen
     ```

   2. 左斜杠键搜索，取消 `zh_CN.UTF-8` 的注释。

  3. ```
     sudo locale-gen
     ```

   4. 登出。

## 显示器设置

[Hyprland-Monitors](https://wiki.hypr.land/Configuring/Monitors/)

```
hyprctl monitors all
```
假设是 eDP-1，分辨率 2k，刷新率 165：
```
vim ~/.config/hypr/hyprland.conf
```
```
monitor=eDP-1,2560x1440@165,0x0,1.6
```
从左到右分别是"显示器，分辨率@刷新率，位置，缩放"。

如果是多显示器的话，把最左上角的显示器的位置设置为 0x0。假设 eDP-1 在最左上角，我第二个显示器想放在 eDP-1 的右边，就计算一下 x 的值，2560/1.6=1600，第二个显示器位置的 x 值就是 1600。y 同理。

```
monitor=DP-2,2560x1440@180,1600x0,1
```

## 禁用鼠标加速

[Hyprland-Input](https://wiki.hypr.land/Configuring/Variables/#input)

```
vim ~/.config/hypr/hyprland.conf
```

修改 `input{}`，写入 `accel_profile = flat`：

```
input{
    accel_profile = flat
}
```

## 触摸板自然滚动

`natural_scroll=false` 的 `false` 改成 `true`。

## xwayland 缩放问题

[Hyprland-XWayland](https://wiki.hypr.land/Configuring/XWayland/)

xwayland 软件在 hyprland 会像素化，需要在 hyprland 配置文件新增 `xwayland{}`，填入 `force_zero_scaling=true`。

```
xwayland{
	force_zero_scaling=true
}
```
然后可以使用软件自己的缩放功能。

或者使用 `xrdb`：

```
sudo pacman -S xorg-xrdb
```
```
echo "Xft.dpi: 140" | xrdb -merge
```
但是 xrdb 的效果并不好。

## 安装必要软件

[Hyprland-Must-have](https://wiki.hypr.land/Useful-Utilities/Must-have/)

[ArchWiki XDG Desktop Portal](https://wiki.archlinux.org/title/XDG_Desktop_Portal)

1. 安装

    ```
    sudo pacman -S libnotify xdg-desktop-portal-hyprland hyprpolkitagent qt5-wayland qt6-wayland
    ```

    `libnotify` 是通知相关的库。

    `xdg-desktop-portal-hyprland` `xdg-desktop-portal-gtk` 提供屏幕分享、全局快捷键、选取文件等功能。如果你已经安装了桌面环境这里装只装 hyprland 的 portal 就可以了。

    `hyprpolkitagent` 软件会通过这个软件询问管理员权限。

    `qt5-wayland qt6-wayland` Qt wayland 库。

2. 配置重要程序开机自启

    ```
    vim ~/.config/hypr/hyprland.conf
    ```

    搜索 `exec-once`。在合适的地方写入：

    ```
    exec-once = mako
    exec-once = /usr/lib/hyprpolkitagent/hyprpolkitagent
    ```

    super+M 退出 hyprland，重新打开。

## GUI 文档管理器

[Xfce4-Projects](https://www.xfce.org/projects)

最适合 `xdg-desktop-portal-gtk` 的文档管理器是 thunar，内存占用极低，仅 50MB。

```
sudo pacman -S xdg-desktop-portal-gtk thunar tumbler ffmpegthumbnailer poppler-glib gvfs-smb file-roller thunar-archive-plugin  gnome-keyring
```

出选项的话选 `pipewire-jack`。

>`tumbler` 提供图片预览功能。

>`ffmpegthumbnailer` 视频预览。

>`poppler-glib` PDF 预览。

>`gvfs-smb` 检查可挂载的外部设备，访问 smb 分享等功能。

>`file-roller` 提供压缩解压缩功能。

>`thunar-archive-plugin` 在 thunar 的右键菜单添加压缩解压缩选项。

>`gnome-keyring` 提供密码保存功能。第一次保存密码会让你设置 keyring 的密码，可以空着。

>`icoextract` exe 缩略图。

更多 thunar 的额外功能可以看[ArchWiki 的 thunar 页面](https://wiki.archlinux.org/title/Thunar)。

- 设置快捷键

   ```
   vim ~/.config/hypr/hyprland.conf
   ```
   搜索 `dolphin`，改成 `thunar`。默认快捷键是 mainMod+E。


### 右键从此处打开终端

点击左上角编辑 > 配置自定义动作 > 选中 open in terminal here > 点击小齿轮 > 命令改成 `kitty`。

### 更改默认终端为 kitty


安装 `xdg-terminal-exec`：

```
yay -S xdg-terminal-exec
```

编辑 `~/.config/xdg-terminals.list`：

```
echo "kitty.desktop" > ~/.config/xdg-terminals.list
```
如果有多个终端的话就按照顺序写多行。

### 生成 home 目录下的目录

[ArchWiki XDG user directories](https://wiki.archlinux.org/title/XDG_user_directories)

```
sudo pacman -S xdg-user-dirs
LANGUAGE=en_US.UTF-8 xdg-user-dirs-update --force
```

>`LANG=en_US.UTF-8` 会生成英文的目录，方便终端中使用。

>`--force` 如果你已经有了中文的目录，这个选项会强制覆盖。

## 桌面套件

推荐使用 quickshell，dms。

```
yay -S dms-shell
```

在 hyprland 配置文件中设置自动启动：

```
exec-once = dms run
```

### 程序启动器

把配置文件中的 `hyprlauncher` 改成 `dms ipc call launcher toggle`。

## 蓝牙

[ArchWiki Bluetooth](https://wiki.archlinux.org/title/Bluetooth)

```
sudo pacman -S --needed bluez
```
```
sudo systemctl enable --now bluetooth
```

## 锁屏

设置快捷键：

```
bind = $mainMod, L, exec, dms ipc call lock lock
```

## 剪贴板

```
sudo pacman -S wl-clipboard cliphist
```

## 截图

```
yay -S satty slurp grim
```
- 截图仅保存到剪贴板：

  ```
  bind = $mainMod, A, exec, grim -g "$(slurp)" - | wl-copy
  ```

- 编辑截图

  ```
  bind = $mainMod, A, exec, grim -g "$(slurp)" - | satty -f -
  ```

- 设置 satty 以浮动模式打开

   打开 satty 窗口后

   ```
   hyprctl clients
   ```
   ```
   windowrule {
   	# 这个窗口规则的名字
   	name = satty
   	# 应用的窗口
   	match:class = com.gabm.satty
   	# 浮动
   	float = yes
   }
   ```
- 设置 satty 的复制命令为 `wl-copy`

   ```
   mkdir -p ~/.config/satty
   vim ~/.config/satty/config.toml
   ```

   ```
   [general]
   copy-command = "wl-copy"
   focus-toggles-toolbars= true
   actions-on-right-click = ["save-to-clipboard"]
   ```

## 中文输入法

0. 需要[添加 archlinuxcn](安装桌面环境前的准备#AUR助手)。

1. 安装

   看中文输入法一节：[中文输入法](中文输入法)

2. 环境变量

   ```
   env = XMODIFIERS,@im=fcitx
   ```

3. 现在启动

   ```
   fcitx5 -d
   ```

4. 自动启动

   ```
   exec-once = fcitx5 -d
   ```

## flatpak

在[安装桌面环境前的准备](安装桌面环境前的准备)一节中我们已经配置了 flatpak，可以安装一个 GUI。

```
sudo pacman -S bazaar
```

## 下一节：[软件安装相关](软件安装相关)

---

# 安装Labwc

Labwc 是一个堆叠式（stacking）窗口管理器，同时支持四角平铺和工作区切换，足以对付大多数使用场景，并且完全符合 Windows 的布局逻辑。

Labwc 功能齐全的同时做到了极度轻量，堆叠式意味着它没有自动平铺的性能消耗，所以它比 sway、river、dwl 等一众轻量的平铺式窗口管理器都要轻量，是老电脑的最佳选择。

为了轻量，配置的时候会尽量避免持久运行的程序，尽量使用 TUI，尽量使用内存和 CPU 占用低的程序。

[官方入门教程](https://labwc.github.io/getting-started.html)


## 安装

```bash
sudo pacman -S labwc foot fuzzel
```
`foot` `fuzzel` 可以换成你喜欢的终端和启动器。

## 创建配置文件

```bash
mkdir -p ~/.config/labwc

# 环境变量配置文件
touch ~/.config/labwc/environment

# labwc 配置文件（快捷键、布局等）
touch ~/.config/labwc/rc.xml

# 自动启动配置文件
touch ~/.config/labwc/autostart
```

每一次修改以上文件都要 `labwc --reconfigure` 应用更改。修改了 `autostart` `environment` 的话要重启 Labwc。

## 显示器设置

- 临时修改

    临时调整的话有一个很方便的 GUI 叫 `wdisplays`，它没法持久生效。

    ```bash
    sudo pacman -S wdisplays
    ```

- 持久保存

    使用 `wlr-randr`，在 `autostart` 里配置开启 Labwc 时自动调整分辨率的命令就可以做到持久保存。

    ```bash
    sudo pacman -S wlr-randr
    ```
    运行 `wlr-randr` 找到自己需要的显示器接口名称和 mode，然后用以下命令调整分辨率：

    ```bash
    wlr-randr --output 【显示器接口名称】 --mode 宽x高@刷新率
    ```
    示例：

    ```bash
    wlr-randr --output eDP-1 --mode 2560x1440@165
    ```

## 自动启动软件

使用的脚本位于 `~/.config/labwc/autostart`。

示例：

```bash
waybar &

wl-paste --watch cliphist store &

```

每条自动启动后面一定要加 `&` 让那条命令在后台运行。

## 家目录下常用目录

```bash
sudo pacman -S xdg-user-dirs
```
强制生成英文的常用目录：

```bash
LANG=en_US.UTF-8 xdg-user-dirs-update --force
```

## 修改语言为中文

编辑 `environment` 文件：

```bash
vim  ~/.config/labwc/environment
```

```bash
LANGUAGE=zh_CN.UTF-8
LANG=zh_CN.UTF-8
```

需要重启 Labwc。

## 快捷键

以下是一个 `rc.xml` 文件的示例。`<keyboard></keyboard>` 中间设置快捷键绑定。

```xml
<?xml version="1.0" ?>
<labwc_config>

  <keyboard>
    <default />
    <!-- The W- prefix refers to the Super key -->
    <keybind key="W-b">
      <action name="Execute" command="firefox" />
    </keybind>
    <keybind key="W-z">
      <action name="Execute" command="fuzzel" />
    </keybind>
  </keyboard>

</labwc_config>

```

## 剪贴板

推荐 `wl-clipboard` 配 `cliphist`，GUI 用 `cliphist-tui-git`。

```bash
yay -S wl-clipboard cliphist cliphist-tui-git
```
在 `autostart` 里写：

```bash
wl-paste --watch cliphist store &
```
然后设置一个打开剪贴板的快捷键：

```xml
<keybind key="W-A-v">
    <action name="Execute" command="foot cliphist-tui" />
</keybind>
```

## 通知程序

使用 `mako`。

1. 安装

    ```bash
    sudo pacman -S mako
    ```

2. 自动启动

    在 `autostart` 里新建一行写上 `mako &`。

3. 配置

    示例配置：
    ```ini
    border-size=2
    icons=1
    anchor=top-right
    default-timeout=8000
    margin=10
    padding=10
    font=adwaita sans regular 11
    history=1
    max-visible=20
    max-history=100
    ```

## 任务栏

使用 `waybar`。

```bash
sudo pacman -S waybar
```

`autostart` 里写 `waybar &`。

## 网络和蓝牙

NetworkManager 使用 `nmtui`，iwd 用 `impala`。无需额外程序。蓝牙使用 `bluetui`。想要系统托盘的话安装 `network-manager-applet` 和 `blueman`，在 `autostart` 里设置 `nm-applet` 和 `blueman-applet` 自动启动。


## 截图

使用 `grim` `slurp`，用 `satty` 编辑。

1. 安装

    ```bash
    sudo pacman -S grim slurp satty
    ```
2. 修改 satty 配置

    位于 `~/.config/satty/config.toml`。

    示例：

    ```ini
    [general]
    copy-command = "wl-copy"
    focus-toggles-toolbars= true
    initial-tool = "brush"
    zoom-factor=1.1

    [font]
    family = "Roboto"
    style = "Regular"
    fallback = [
        "Noto Sans CJK SC",
        "Noto Sans CJK JP",
        "Noto Sans CJK TC",
        "Noto Sans CJK KR"
    ]
    ```

3. 创建截图脚本

    xml 里直接写命令不太方便，可以在 `~/.config/labwc/scripts` 里创建脚本。

    ```bash
    mkdir -p ~/.config/labwc/scripts

    vim ~/.config/labwc/scripts/screenshot
    ```
    写入：

    ```bash
    #!/bin/bash

    case "$1" in
        select)
            # 框选截图 -> 复制到剪贴板
            grim -g "$(slurp)" - | wl-copy
            ;;
        edit)
            # 框选截图 -> 打开 satty 编辑器 (可以在编辑器里保存或复制)
            grim -g "$(slurp)" - | satty -f -
            ;;
    esac

    ```
    给执行权限：
    ```bash
    chmod +x ~/.config/labwc/scripts/screenshot
    ```

4. 设置快捷键

    ```xml
    <keybind key="W-A-a">
        <action name="Execute" command="~/.config/labwc/scripts/screenshot select" />
    </keybind>
    <keybind key="W-S-s">
        <action name="Execute" command="~/.config/labwc/scripts/screenshot edit" />
    </keybind>
    ```

## 图形化文档管理器

使用 `thunar`。

```bash
sudo pacman -S --needed xdg-desktop-portal-gtk thunar tumbler ffmpegthumbnailer poppler-glib gvfs-smb file-roller thunar-archive-plugin gnome-keyring thunar-volman gvfs-mtp gvfs-gphoto2 webp-pixbuf-loader icoextract
```

>`xdg-desktop-portal-gtk` 是 GTK 的 xdg 桌面门户。

>`tumbler` 提供图片预览功能。

>`ffmpegthumbnailer` 视频预览。

>`poppler-glib` PDF 预览。

>`gvfs-smb` 检查可挂载的外部设备，访问 smb 分享等功能。

>`file-roller` 提供压缩解压缩功能。

>`thunar-archive-plugin` 在 thunar 的右键菜单添加压缩解压缩选项。

>`gnome-keyring` 提供密码保存功能。第一次保存密码会让你设置 keyring 的密码，可以空着。

>`thunar-volman` 自动管理移动硬盘等设备。

>`gvfs-mtp` 连接手机。

>`gvfs-gphoto2` 连相机。

>`webp-pixbuf-loader` webp 缩略图。

>`icoextract` exe 缩略图。


- 右键从此处打开

    左上角编辑配置自定动作，把 open terminal here 的命令改成 `foot`（你的终端）。

- 默认终端

    ```bash
    yay -S xdg-terminal-exec

    echo "foot.desktop" >> ~/.config/xdg-terminals.list
    ```
    这里的 `foot.desktop` 应是你实际的终端的 .desktop 文件。


## 录屏

录屏推荐使用 `wf-recorder` 和 `wl-screenrec`。

obs 录屏需要配置门户：

```bash
sudo pacman -S xdg-desktop-portal-wlr

vim ~/.config/labwc/environment
```
```ini
XDG_CURRENT_DESKTOP=labwc:wlroots
```
重启 Labwc 之后就可以在 obs 看到屏幕采集选项了。

## 鼠标主题

推荐 `breeze-cursors`。

```bash
sudo pacman -S breeze-cursors
```
在 `environment` 里写上：

```ini
XCURSOR_THEME=breeze_cursors
XCURSOR_SIZE=30
```

## 中文输入法

1. 安装

    看[ShorinWiki 中文输入法](中文输入法)。

2. 配置

    在 `environment` 里写上：

    ```ini
    XMODIFIERS=@im=fcitx
    LC_CTYPE=en_US.UTF-8
    ```

## 壁纸

推荐使用 `swaybg`，GUI 使用 `waypaper`。

```bash
sudo pacman -S swaybg waypaper
```
然后在 `autostart` 写上：

```bash
waypaper --restore
```
之后用 waypaper 切换壁纸就行了。

---

# 安装Wayfire


```bash
yay -S wayfire
```

```bash
mkdir -p ~/.config/wayfire
curl -L -o ~/.config/wayfire/wayfire.ini https://raw.githubusercontent.com/WayfireWM/wayfire/refs/heads/master/wayfire.ini
```

平面旋转：Super+Ctrl+左键

3D 旋转：Super+Shift+左键

---

# 安装mangowc

目录

- [Mangowc简介](安装Mangowc#什么是mangowc)
- [安装Fish](安装Mangowc#可选安装fish)
- [AUR助手](安装Mangowc#安装aur助手)
- [安装Mangowc](安装Mangowc#安装mangowc)
- [配置文件](安装Mangowc#移动配置文件)
- [自启动脚本](安装Mangowc#创建程序自动启动脚本)
- [显示器配置](安装Mangowc#显示器配置)
- [鼠标设置](安装Mangowc#禁用鼠标加速)
- [触摸板设置](安装Mangowc#触摸板自然滚动)
- [基础组件](安装Mangowc#重要程序)
- [文件管理器](安装Mangowc#gui文档管理器)
- [锁屏设置](安装Mangowc#锁屏)
- [电源管理](安装Mangowc#自动锁屏熄屏休眠)
- [Waybar面板](安装Mangowc#任务栏waybar)
- [面板组件](安装Mangowc#任务栏组件)
- [剪贴板](安装Mangowc#剪贴板)
- [壁纸管理](安装Mangowc#壁纸切换)
- [截图录屏](安装Mangowc#截图和录屏)
- [系统语言](安装Mangowc#修改系统语言为中文)
- [窗口规则](安装Mangowc#窗口规则修复)

---

# ⚠️警告⚠️：这篇文章已经严重过时，很久不用mangowc了

本文从tty开始安装mangowc

## 什么是mangowc？

<https://github.com/DreamMaoMao/mangowc>

mangowc基于dwl开发，兼顾了轻量、动画、软件兼容，最大的特点是多布局切换。可以自由切换master、网格、滚动等布局。

- mangowc的"致命"问题

    1. 某些游戏在窗口的大小发生变化后会运行异常，包括不限于掉帧、卡顿、卡死，极其影响游戏体验。

    2. 不支持触屏和数位板

## 可选：安装fish

需要频繁用到终端，安装个fish会方便很多

```
sudo pacman -S fish
```

运行fish命令即可打开fish。如果之后想在打开终端的时候自动进入fish的话可以设置类似`kitty -e fish` `ghostty -e fish`这样的快捷键。

## [安装aur助手](yay-AUR助手)

mangowc在aur里，所以需要先安装aur助手（点击超链接可以跳转安装aur助手页面）。

## 安装mangowc

1. 安装

    ```
    yay -S mangowc-git rofi foot firefox
    ```

    没有特殊需求的话安装的时候出选项选`pipewire-jack`，字体选`noto-fonts`，其他一路回车
    `rofi`应用启动菜单
    `foot`终端
    `firefox`浏览器

2. 启动

    使用`mango`命令启动

## 默认配置文件

```
mkdir -p ~/.config/mango
cp /etc/mango/config.conf ~/.config/mango/config.conf
```

默认`alt+回车`打开`foot`，`ctrl+shift+加减号`可以缩放`foot`；`alt+空格`打开`rofi`；`alt+q`关闭窗口；`super+r`重新加载配置。

## 创建程序自动启动脚本

mangowc可以在配置里通过`exec-once`设置软件自动启动，也可以使用autostart.sh脚本，wiki似乎推荐使用脚本。

1. 创建自动程序脚本

    ```
    touch ~/.config/mango/autostart.sh
    ```

2. 添加可执行权限

    ```
    chmod +x ~/.config/mango/autostart.sh
    ```

## 显示器配置

1. 使用`wlr-randr`获取显示器信息

    ```
    sudo pacman -S wlr-randr
    ```

    ```
    wlr-randr
    ```

    记住`eDP-1`这样的接口名称，然后在mode里找到自己需要的分辨率和刷新率

2. 编辑配置文件

    ```
    vim ~/.config/mango/config.conf
    ```

    按两下g键盘跳转到文件顶部，按shift+o键在当前行的上方新建一行。

    格式：

    ```
    monitorrule=接口名称,mfact,nmaster,平铺布局,旋转,缩放,x轴,y轴,横向分辨率,竖向分辨率,刷新率
    ```

    `mfact`和`nmaster`是master布局相关的设置，`mfact`是主要区域的大小，`nmaster`是主要区域内窗口数量。

    示例：

    ```
    monitorrule=eDP-1,0.55,1,tile,0,1,0,0,2880,1800,120
    ```

    `eDP-1`是名称；0.55设置master布局主要区域大小，1设置主要区域内窗口数量为1，tile设置平铺布局（这些设置貌似都不生效，维持默认，在别的地方改就行）；0设置没有旋转；1设置缩放；0,0设置位置；2880,1800设置分辨率；120设置刷新率。

    设置完成后esc退出编辑模式，:w保存，然后使用快捷键刷新配置。

- 熄屏显示器

    使用wlr-dpms

    ```
    yay -S wlr-dpms
    ```

    获取显示器名字

    ```
    wlr-dpms query
    ```

    切换开关

    ```
    wlr-dpms eDP-1

    wlr-dpms on eDP-1

    wlr-dpms off eDP-1
    ```

- 禁用显示器

    使用wlr-randr

    ```
    wlr-randr --output eDP-1 --toggle
    ```

## 禁用鼠标加速

左斜杠搜索mouse。`accel_profile=1`可以关闭鼠标/触摸板加速，`accel_speed`可以设置鼠标/触摸板速度。

设置完成后需要重新开启一次mangowc。

## 触摸板自然滚动

`touchpad_natural_scrolling`的值为1可以设置自然滚动。

## 重要程序

1. 安装

    ```
    sudo pacman -S xorg-xwayland libnotify mako polkit-gnome 
    ```

    `xorg-xwayland`提供xwayland功能

    `libnotify`是通知相关的库

    `mako`提供通知功能

    `polkit-gnome`让软件能够询问管理员权限

2. 设置自动启动

    ```
    vim ~/.config/mango/autostart.sh
    ```

    写入

    ```
    #!/bin/bash

    # 通知程序
    mako & 

    # 权限询问
    /usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1 & 
    ```

3. 重启mangowc

## GUI文档管理器

[Xfce4-Projects](https://www.xfce.org/projects)

可以按照你的喜好安装文档管理器和对应的xdg桌面门户，比如dolphin对应xdg-desktop-portal-kde，nautilus对应xdg-desktop-portal-gnome。我比较喜欢thunar。

```
sudo pacman -S xdg-desktop-portal-gtk thunar tumbler ffmpegthumbnailer poppler-glib gvfs-smb file-roller thunar-archive-plugin gnome-keyring icoextract
```

出选项的话选`pipewire-jack`

`xdg-desktop-portal-gtk`提供文件选取等功能

`tumbler`提供图片预览功能

`ffmpegthumbnailer`视频预览

`poppler-glib`pdf预览

`gvfs-smb` 检查可挂载的外部设备，访问smb分享等功能

`file-roller` 提供压缩解压缩功能

`thunar-archive-plugin`在thunar的右键菜单添加压缩解压缩选项

`gnome-keyring`提供密码保存功能。第一次保存密码会让你设置keyring的密码，可以空着。

`icoextract`exe缩略图

其他thunar的额外功能可以看[archwiki的thunar页面](https://wiki.archlinux.org/title/Thunar)

- 设置快捷键

   ```
   vim ~/.config/mango/config.conf
   ```

   左斜杠搜索bind，在合适的写入以下内容设置一个打开thunar的快捷键（如果你用的是我的配置文件的话已经配置好了）

   ```
   bind=SUPER,e,spawn,thunar
   ```

### 右键从此处打开终端

点击左上角编辑（edit） > 配置自定义动作（configure custom actions） > 选中open in terminal here > 点击小齿轮 > 命令改成`kitty -e fish`

### 更改默认终端为kitty

安装`xdg-terminal-exec`

```
yay -S xdg-terminal-exec
```

编辑`~/.config/xdg-terminals.list`

```
echo "kitty.desktop" > ~/.config/xdg-terminals.list
```

如果有多个终端的话就按照顺序写多行。

### 生成home目录下的目录

[Archwiki-XDG-user-directories](https://wiki.archlinux.org/title/XDG_user_directories)

```
sudo pacman -S xdg-user-dirs
xdg-user-dirs-update
```

## 锁屏

hyprland的部分使用了hyprlock，这里也可以使用hyprlock，为了新鲜感我装个swaylock-effects

1. 安装

    ```
    yay -S swaylock-effects
    ```

2. 创建配置文件

    ```
    mkdir -p ~/.config/swaylock
    touch ~/.config/swaylock/config
    ```

3. 编辑配置文件

    ```
    vim ~/.config/swaylock/config
    ```

    写入：

    ```
    screenshots
    clock
    indicator
    indicator-radius=200
    indicator-thickness=15
    effect-blur=10x5
    ```

    `screenshots`让锁屏显示桌面

    `effect-blur=10x5`设置模糊

    `indicator`显示屏幕中间显示一个圆环

    `clock`显示时钟

    `indicator-radius=200`圆环大小

    `indicator-thickness=15`圆环粗细

    更详细的配置可以看官方文档[swaylock-effects](https://github.com/mortie/swaylock-effects)

4. 设置快捷键

    ```
    vim ~/.config/mango/config.conf
    ```

    我设置了super+alt+L锁屏

    ```
    bind=SUPER+ALT,L,spawn,swaylock
    ```

    保存后重新加载一次mango的配置，我设置的快捷键是super+f1，默认是super+r

## 自动锁屏/熄屏/休眠

hypridle的配置更加简单所以继续用hypridle

1. 安装

    ```
    sudo pacman -S hypridle brightnessctl
    ```

2. 配置文件

    ```
    mkdir -p ~/.config/hypr
    vim ~/.config/hypr/hypridle.conf
    ```

    [复制wiki底下的示例配置](https://wiki.hypr.land/Hypr-Ecosystem/hypridle/)

    把`lock_cmd`里的hyprlock改成swaylock

    再把所有的`hyprctl dispatch dpms off`改成`wlr-dpms off`

    所有的`hyprctl dispatch dpms on`改成`wlr-dpms on`

3. 设置自动启动

    ```
    vim ~/.config/mango/autostart.sh
    ```

    ```
    hypridle & 
    ```

4. 现在启动

    ```
    hypridle & disown
    ```

## 任务栏waybar

1. 安装

    ```
    sudo pacman -S waybar ttf-jetbrains-mono-nerd otf-font-awesome
    ```

2. 下载默认配置

    [在这里下载默认的waybar配置](https://github.com/Alexays/Waybar/tree/master/resources)，分别是config.jsonc、style.css，还有custom_modules目录里的power_menu.xml。把这三个文件剪贴到`~/.config/waybar`目录。

3. 修改默认配置

    在配置文件的底部，把shutdown改成poweroff。

    然后[在这里复制](https://github.com/DreamMaoMao/mangowc/wiki#config)或者在下面复制mangowcwiki里的waybar模块配置，粘贴到config.jsonc文件末尾最后一个大括号的上面，注意在原先的倒数第二个大括号后面加上逗号。

    ```
    "ext/workspaces": {
    "format": "{icon}",
    "ignore-hidden": true,
    "on-click": "activate",
    "on-click-right": "deactivate",
    "sort-by-id": true,
    },
    "dwl/tags": {
      "num-tags":9,
    },
    "dwl/window": {
      "format": "[{layout}]{title}"
    },
    ```

    然后把文件开头modules-left里面的"sway/workspaces"改成"ext/workspaces"，把"sway/window"改成"dwl/window"。

4. 修改字体

    打开style.css

    在`font-family:`的部分添加`JetBrainsMono NFP,`，修改后是这样的：

    ```
    font-family: JetBrainsMono NFP, FontAwesome, Roboto ......;
    ```

5. 现在启动waybar

    ```
    waybar & disown
    ```

6. 设置重启waybar的快捷键

    ```
    vim ~/.config/mango/config.conf
    ```

    左斜杠搜索bind，在合适的位置新建（我的配置文件里已经有了，super+f2键重启waybar）：

    ```
    bind=SUPER,F2,spawn_shell,pkill waybar || true && waybar
    ```

7. 自动启动

    需要编辑autostart.sh

    ```
    vim ~/.config/mango/autostart.sh
    ```

    新增：

    ```
    waybar &
    ```

## 任务栏组件

- 网络

    1. 安装

    ```
    sudo pacman -S --needed networkmanager network-manager-applet dnsmasq
    ```

    `networkmanager``network-manager-applet`提供联网功能和网络组件

    `dnsmasq`高级网络配置工具需要

    1. 现在启动

    ```
    nm-applet & disown
    ```

    可以看到waybar的托盘里出现网络组件
    3. 自动启动

    需要编辑autostart.sh

    ```
    vim ~/.config/mango/autostart.sh
    ```

    新增：

    ```
    nm-applet &
    ```

    1. 浮动模式打开
    `nm-connection-editor`打开高级网络配置工具，然后`mmsg -w`获取appid

    编辑配置文件新增窗口规则

    ```
    windowrule=isfloating:1,appid:nm-connection-editor
    ```

- 蓝牙

    1. 安装

    ```
    sudo pacman -S --needed bluez blueman
    ```

    ```
    sudo systemctl enable --now bluetooth
    ```

    `blueman-manager`启动gui。

    1. 现在启动

    ```
    blueman-applet & disown
    ```

    可以看到waybar的托盘里出现蓝牙组件

    1. 自动启动

    ```
    vim ~/.config/mango/autostart.sh
    ```

    新增：

    ```
    blueman-applet &
    ```

    1. 浮动模式打开

    ```
    windowrule=isfloating:1,appid:blueman-manager
    ```

- 性能模式切换

    ```
    sudo pacman -S power-profiles-daemon
    ```

    ```
    sudo systemctl enable --now power-profiles-daemon 
    ```

    安装完成后使用快捷键重启waybar，或者终端运行`pkill waybar && waybar`重启waybar。

## 剪贴板

使用开箱即用的copyq

1. 安装

    ```
    sudo pacman -S copyq
    ```

2. 现在启动

    ```
    copyq & disown 
    ```

    可以看到任务栏托盘出现一把小剪刀，左键可以打开剪贴板。
3. 自动启动

    ```
    vim ~/.config/mango/autostart.sh
    ```

    ```
    copyq &
    ```

4. 设置快捷键

    ```
    vim ~/.config/mango/config.conf
    ```

    ```
    bind=SUPER+ALT,v,spawn,copyq toggle
    ```

    我的配置里已经有了。
5. 以浮动窗口打开

    终端运行`mmsg -w`命令，然后打开copyq，聚焦之后可以在终端的输出里找到copyq的appid和title。

    ```
    vim ~/.config/mango/config.conf
    ```

    按shift+g键到文件底部，新增：

    ```
    windowrule=isfloating:1,width:500,height:500,appid:com.github.hluk.copyq
    ```

    这段配置设置一个新的窗口规则，具体内容为：浮动窗口、宽500、高500，然后用appid指定规则应用的窗口为copyq。

    保存后刷新一次mango，我设置的快捷键是super+f1，默认是super+r。

## 壁纸切换

1. 安装

    ```
    yay -S awww waypaper-git
    ```

    `awww`提供带动画的壁纸切换功能

    `waypaper`是gui

2. 设置自动启动

    ```
    vim ~/.config/mango/autostart.sh
    ```

    新增

    ```
    awww-daemon &
    ```

3. 使用waypaper切换壁纸
    可以从菜单启动waypaper，或者运行`waypaper`命令启动

4. 设置快捷键

    我的配置里设置的是super+alt+w

    ```
    bind=SUPER+ALT,W,spawn,waypaper
    ```

5. 浮动窗口模式打开

    `mmsg -w`获取窗口信息，然后新增一个窗口规则：

    ```
    windowrule=isfloating:1,appid:waypaper
    ```

    保存后重新加载一次mango的配置

## 截图和录屏

- 依赖

    ```
    sudo pacman -S --needed xdg-desktop-portal-wlr xdg-desktop-portal-hyprland grim slurp wl-clipboard
    ```

    ps：wiki说只要装wlr的xdp就好了，但是我发现必须装上hyprland的xdp才能解决无法录制高帧率视频的问题。

    ```
    vim ~/.config/mango/autostart.sh
    ```

    ```
    dbus-update-activation-environment --systemd WAYLAND_DISPLAY XDG_CURRENT_DESKTOP=wlroots

    /usr/lib/xdg-desktop-portal-wlr &
    ```

    ```
    reboot
    ```

- 截图

    1. 安装

        推荐使用gradia

        ```
        yay -S gradia
        ```

        ```
        gradia --screenshot
        ```

    2. 禁用slurp的blur效果

        获取layer名称

        ```
        mmsg -e
        ```

        编辑配置文件设置layer规则

        ```
        vim ~/.config/mango/config.conf
        ```

        ```
        layerrule=layer_name:selection,noblur:1
        ```

        保存后重载mango。

    3. 以浮动模式打开gradia

        获取窗口信息

        ```
        mmsg -w
        ```

        ```
        windowrule=isfloating:1,appid:be.alexandervanhee.gradia
        ```

        保存后重载mango

    4. 设置快捷键

        我的配置里是super+shift+S

        ```
        bind=SUPER+SHIFT,s,spawn,gradia --screenshot
        ```

    5. 拓展内容

        很多时候我们只是想快速截个图保存到剪贴板，所以每次截图完都会打开编辑工具可能有点不方便。为此，可以直接使用grim+slurp+wl-clipboard做到基本的截图功能

        ```
        sudo pacman -S wl-clipboard
        ```

        运行这段命令截图：

        ```
        grim -g "$(slurp)" - | wl-copy
        ```

        打开copyq剪贴板就能看到截图保存到了剪贴板。

        可以设置一个快捷键，我的配置里是super+alt+a

        ```
        bind=SUPER+ALT,a,spawn_shell,grim -g "$(slurp)" - | wl-copy
        ```

- 录屏

    推荐使用kooha和obs

    ```
    yay -S kooha
    ```

## 修改系统语言为中文

利用wm的配置文件设置系统语言。

设置时一定要让`LANG`为英文，否则中文输入法会出现异常，然后通过`LC_MESSAGES`变量设置主要界面的语言为中文。

```
vim ~/.config/mango/config.conf
```

```
env=LC_MESSAGES,zh_CN.UTF-8
```

- 如果是archinstall安装，需要进行如下操作：

  1. ```
     sudo vim /etc/locale.gen 
     ```

  2. 左斜杠键搜索，取消`zh_CN.UTF-8`的注释

  3. ```
     sudo locale-gen
     ```

  4. 登出

重启mango

## 窗口规则修复

在我的配置文件的底部设置了一些窗口规则，修复了一些不合适的窗口动画和窗口效果。

## 其他重要的通用配置

- [中文输入法](中文输入法)

## 下一节：[软件安装相关](软件安装相关)

---

# 显卡驱动和硬件编解码

以 N 卡 RTX4060 和 AMD 780M 核显为例。


### chwd

利用 chwd 可以自动安装驱动。

```bash
yay -S chwd-arch-git
```
安装完整后运行 `chwd -a` 自动安装驱动。

- 其他命令

  `chwd --list` 可以列出可用的配置，每一个配置代表了一系列驱动包和后续修改。

  `chwd -r 配置名称` 删除已经安装的配置。

  更多选项可以用 `chwd -h` 查看。

### 安装显卡驱动

- NVIDIA

  在 [CodeNames · freedesktop.org](https://nouveau.freedesktop.org/CodeNames.html) 这个页面搜索自己的显卡，看看对应的 family 是什么。然后在 [NVIDIA - ArchWiki](https://wiki.archlinux.org/title/NVIDIA) 这个页面查找对应的包名。nv160family（差不多 16 系）往后的显卡用 `nvidia-open`，7 系到 10 系的 N 卡从 AUR 安装 580xx 版本的驱动 `nvidia-580xx-dkms`。不同的内核对应的包的后缀不同，像 `linux-zen` 这样的自定义内核要装 `-dkms` 后缀的。不过，考虑到日后更新的稳定性，强烈推荐无论使用什么内核，都统一使用 `-dkms` 版本的驱动包，它会在内核更新时自动重新编译驱动。除了驱动包，还要安装 `nvidia-utils` 工具集，对应的 580xx 版本驱动对应的工具集包在 AUR 上：`nvidia-580xx-utils`，其他显卡按照 ArchWiki 的表格以此类推。
  
  >`nvidia-open` 是内核模块开源的驱动，不是完全的开源驱动。

  - 检查头文件

    DKMS 编译内核模块需要内核的头文件。

    ```bash
    sudo pacman -S --needed linux-headers
    ```

    >`linux` 替换为自己的内核，比如 zen 内核的头文件包名是 `linux-zen-headers`。

  - 安装驱动

    ```bash
    sudo pacman -S nvidia-open-dkms nvidia-utils lib32-nvidia-utils
    ```

- AMD

  [AMDGPU - ArchWiki](https://wiki.archlinux.org/title/AMDGPU)

  A 卡不需要自己安装驱动，已经由 `linux-firmware` 和 `mesa` 提供。可以安装一下 Vulkan 驱动。

  ```bash
  sudo pacman -S --needed mesa lib32-mesa xf86-video-amdgpu vulkan-radeon lib32-vulkan-radeon
  ```

- Intel

  [Intel graphics - ArchWiki](https://wiki.archlinux.org/title/Intel_graphics)

  ```bash
  sudo pacman -S --needed mesa lib32-mesa vulkan-intel lib32-vulkan-intel
  ```

### 硬件编解码

[archwiki_硬件视频加速](https://wiki.archlinux.org/title/Hardware_video_acceleration)

- NVIDIA

    由 `nvidia-utils` 和 `libva-nvidia-driver` 提供。

    ```bash
    sudo pacman -S libva-nvidia-driver
    ```

    还可以把替换为 `nvidia-vaapi-driver`，按 ArchWiki 的说法，这个包的功耗会更低（注意，这个包在 archlinuxcn 里）。

- AMD

  自带。

- Intel

  Broadwell 往后的 Intel 显卡装 `intel-media-driver`，旧的装 `libva-intel-driver`。具体看 ArchWiki。

### 重启激活显卡驱动

  ```bash
  reboot
  ```

- 可选：验证硬件编解码

    ```bash
    sudo pacman -S libva-utils
    ```

    使用 libva-utils 提供的 vainfo 进行验证。

    ```bash
    vainfo
    ```

    多显卡用户可以使用 LIBVA_DRIVER_NAME 环境变量指定要使用的显卡：

    ```bash
    LIBVA_DRIVER_NAME=nvidia vainfo
    ```

### 可选：OpenCL 驱动

[archwiki General-purpose computing on graphics processing units](https://wiki.archlinux.org/title/General-purpose_computing_on_graphics_processing_units#Runtime)

- NVIDIA

  主要是 `opencl-nvidia` `lib32-opencl-nvidia` 这两个包。580xx 和 470xx 的用户安装对应的版本，例如：`opencl-nvidia-580xx` `lib32-opencl-nvidia-580xx`。

- AMD/Intel

  ```bash
  sudo pacman -S opencl-mesa lib32-opencl-mesa
  ```

## 笔记本显卡切换

[显卡切换](显卡切换)在 Wayland 下不完善，属于次要内容，有需求的可以跳转。

## 下一节：[快照和系统维护](快照和系统维护)

---

# 中文输入法

目录

- [fcitx5-rime](中文输入法#fcitx5)
- [ibus-rime](中文输入法#ibus)
- [输入法异常的解决办法](中文输入法#输入法异常的解决办法)

---

常用的输入法框架有 Fcitx5 和 IBus，Fcitx5 更现代，功能更多，建议使用。不同桌面配置方法会略有不同，注意区分。

## fcitx5

1. 安装基础框架

    ```bash
    sudo pacman -S fcitx5-im

    # fcitx5-im 包含了 fcitx5 的基本包
    ```

2. 安装中文输入方案

    你可以**自己选择要安装的输入方案**，因为我使用全拼，所以本文主要是全拼方案的教程。

    - 中文输入合集 `fcitx5-chinese-addons`

      这里面包含了所有常用的中文输入方案（拼音、五笔、双拼等等）。安装简单，但是输入效果一般，不推荐使用。

      ```bash
      sudo pacman -S fcitx5-chinese-addons
      ```

    - RIME 中州韵引擎+雾凇拼音

      现有两大方案，万象和雾凇。万象的全拼分词效果很差，所以全拼用户强烈推荐使用雾凇，双拼用户推荐使用万象。（PS：如果出现锁英文的异常，按右 Shift 也许可以解决）

      1. 安装 RIME（中州韵）+雾凇拼音

          ```bash
          sudo pacman -S fcitx5-rime rime-ice-git
          ```

            >`fcitx5-rime` 是输入法引擎。

            >`rime-ice-git` 雾凇输入方案，这个包需要从 AUR 或者 archlinuxcn 安装。

            >其他方案：`rime-wanxiang-pinyin` 万象拼音（这个包在 archlinuxcn 上）；`rime-wanxiang-flypy` 万象小鹤双拼（archlinuxcn 源）；`fcitx5-mozc` 日语输入法；`rime-wubi` 五笔输入法。

          现在打开 `fcitx5-configtool` 就可以添加 `rime（中州韵）` 到输入法列表中了，添加完成后重启输入法会自动初始化。默认的输入方案是繁体的 `明月拼音`，按下 F4 可以打开设置菜单调整为简体。下面我们编辑配置配置文件将默认输入方案改成雾凇拼音。

      2. 编辑配置文件启用 RIME 雾凇拼音

            ```bash
            mkdir -p ~/.local/share/fcitx5/rime
            vim ~/.local/share/fcitx5/rime/default.custom.yaml
            ```

            >第一行命令 `mkdir -p` 检查文件夹是否存在，不存在的话创建。第二行编辑配置文件。

             写入以下内容设置 RIME 的默认方案为雾凇拼音：

            ```yaml
            patch:
              # 这里的 rime_ice_suggestion 为雾凇方案的默认预设
              __include: rime_ice_suggestion:/
            ```
            重启输入法之后默认输入方案就变成雾凇拼音了。

      3. 可选：F4 在多个输入方案间切换

            用 `ls /usr/share/rime-data/*.schema.yaml` 命令可以看到当前所有可用的输入方案，去掉文件名的 `.schema.yaml` 就是 `schema` 名，写进 `default.custom.yaml` 后可以在 F4 菜单里切换不同的输入方案，以下是示例（注意缩进，RIME 的配置文件对缩进很严格）：

            ```yaml
            patch:
              schema_list:
                - schema: luna_pinyin_simp
                - schema: rime_ice
                - schema: wanxiang
                - schema: double_pinyin_flypy
                - schema: wubi86
                - schema: bopomofo
            ```
            > `luna_pinyin_simp` 是 RIME 自带的明月拼音；`wanxiang` 是万象拼音；`double_pinyin_flypy` 是小鹤双拼（由 `rime-ice-git` 提供）；`bopomofo` 是注音输入法。

      4. 可选：配置输入法模型

            推荐给雾凇拼音接入万象的语法模型，可以提高长句联想效果。你可以现在尝试打 `苍茫的天涯是我的爱`，大概率会打出 `苍茫的填鸭式我的爱`，如果配置了语法模型就可以解决这个问题。

            1. 安装模型

               可以直接从 AUR 或者 archlinuxcn 安装：
               ```bash
               yay -S rime-wanxiang-gram-zh-hans
               ```
               >或者从 GitHub 手动下载：[点击此处下载模型](https://github.com/amzxyz/RIME-LMDG/releases/download/LTS/wanxiang-lts-zh-hans.gram)，下载完成后把模型放在 `~/.local/share/fcitx5/rime/`。

            2. 编辑雾凇拼音的配置文件

               ```bash
               vim ~/.local/share/fcitx5/rime/rime_ice.custom.yaml
               ```

               写入：

               ```yaml
               patch:
                 "grammar/language": wanxiang-lts-zh-hans
               ```

            3. 重新启动输入法

               现在再打 `苍茫的天涯是我的爱` 试试。

      5. 可选：[接入LLM大模型进行云拼音](https://github.com/SHORiN-KiWATA/rime-llm-translator)

            这是我自己的项目，功能是给 RIME 输入法接入大模型进行拼音联想。把拼音传给大模型，让大模型猜出正确的句子，一键安装，TUI 图形化界面修改配置，感兴趣的可以试试。

3. 配置环境变量

   ```bash
   sudo vim /etc/environment
   ```

   不同的桌面设置方法不同。

   - GNOME 的话写入：

     ```text
     XIM="fcitx"
     GTK_IM_MODULE=fcitx
     QT_IM_MODULE=fcitx
     XMODIFIERS=@im=fcitx
     ```

     >`GTK_IM_MODULE=fcitx QT_IM_MODULE=fcitx XMODIFIERS=@im=fcitx` 这三个是最主要的环境变量。

     >`XIM="fcitx"` 是因为我在微信的某个版本出现输入法无法使用的情况，设置这个解决了。

      如果出现吞字问题可以尝试用 `XDG_CURRENT_DESKTOP=GNOME` 环境变量解决。

   - KDE/Wayland 合成器的话写入：

     ```text
     XMODIFIERS=@im=fcitx
     ```

   - Wayland 合成器

      在配置文件里设置环境变量，例如：

      - Niri

        ```text
        environment {
              XMODIFIERS "@im=fcitx"
        }
        ```

      - Hyprland

        ```text
        env = XMODIFIERS,@im=fcitx
        ```

4. 调整系统设置

   - GNOME 的话

      1. 打开 Fcitx5 配置添加 RIME。

      2. 安装扩展

          商店搜索 extension，安装蓝色的 extensionmanager，然后在扩展商店安装 [input method panel](https://extensions.gnome.org/extension/261/kimpanel/) 扩展。

   - KDE 的话

     1. 打开 `系统设置` > `键盘` > `虚拟键盘`，选择 `fcitx5 wayland 启动器`，记得 `应用`。
     2. `系统设置` > `语言和时间` > `输入法`，添加 `rime（中州韵）`。`配置全局选项` 可以设置切换输入法的快捷键。`配置附加选项` 可以进行一些自定义设置。

   - Wayland 合成器的话

     1. 打开 `fcitx5配置` 进行设置。

     2. 在合成器配置文件里设置自动启动 Fcitx5。

        - Niri

          ```text
          spawn-at-startup "fcitx5"
          ```
        - Hyprland

          ```text
          exec-once = fcitx5
          ```

5. 可选：美化

   浏览器搜索 fcitx5 themes，下载自己喜欢的主题放到 `~/.local/share/fcitx5/themes` 目录下。在 `fcitx5配置` 里的 `经典用户界面` 里进行设置。

6. 干净删除 Fcitx5

   1. 删除包

      ```bash
      sudo pacman -Rns fcitx5-im fcitx5-rime rime-ice-git
      ```
      > `fcitx5-im fcitx5-rime rime-ice-git` 应为你实际使用的包的名字。

   2. 删除配置文件

      ```bash
      rm -rfv ~/.config/fcitx5 ~/.local/share/fcitx5
      ```

   3. 清理之前配置的环境变量。

### RIME 自定义词库

RIME 的词库是离线的，无法打出热词，这个时候就需要自定义词库。如果你觉得默认的联想不适合你的使用场景，也可以自定义词库。具体方法如下，了解方法之后你甚至可以给 AI 提供素材，根据你的使用场景创建专属于你自己的自定义词库。

1. 在 `~/.local/share/fcitx5/rime` 目录下新建 `custom_phrase.txt`。

    ```bash
    vim ~/.local/share/fcitx5/rime/custom_phrase.txt
    ```
2. 按照这个格式写入自定义词库：`词语<TAB>ciyu<TAB><可选设置权重>`

    > `<TAB>` 代表制表符（Tab 键）分割，不能使用空格；`ciyu` 是具体单词或者短语的拼音；`<可选设置权重>` 代表该词在候选列表中的排序高低，数字越大越高。

    以下是一个示例配置：

    ```text
    # encoding: utf-8
    # 注释以 # 开头
    异环	yihuan	100
    异幻  yihuan  99
    腾讯	tx
    梦里不知身是客，一晌贪欢	shangmengtanhuan
    ```
3. 重启输入法

    ```bash
    fcitx5 -r
    ```

效果如图

  - 权重排序

    ![](./pictures/ime/quanzhong.png)

  - 自定义短语

    ![](./pictures/ime/custom_phrase.png)


### KDE/Wayland 合成器用户接着看[输入法异常的解决办法](#输入法异常的解决办法)

## ibus

KDE/Wayland 合成器用 Fcitx5 就可以。GNOME 和 IBus 兼容性更好，如果有需要可以更换。

因为是次要内容所以放在附录了，[点击此处跳转](附录#ibus)。

## 输入法异常的解决办法

- 修改 locale 解决大部分问题

可以运行 `locale` 命令查看当前的 locale 环境变量都是什么。

```bash
locale
```

`LC_CTYPE` 环境变量设置为 `zh_CN.UTF-8` 时会导致输入法出现漏字现象，把它改成英文（⚠️注意：此变量为英文时可能会导致 Steam 等应用完全不能使用中文输入法，遇到的话单独设置 `LC_CTYPE` 为中文就行。）

在自己桌面环境对应的设置 locale 或者环境变量的地方修改 locale。我们可以把 `LANG` 设置为中文，单独设置 `LC_CTYPE` 为英文。也可以把 `LANG` 设置为英文，用 `LC_MESSAGES` 设置界面为中文。

```text
LANG=zh_CN.UTF-8
LC_CTYPE=en_US.UTF-8
```

或者

```text
LANG=en_US.UTF-8
LC_MESSAGES=zh_CN.UTF-8
# 想让时间以中文显示要设置 LC_TIME 为中文
```

>不知道写在哪就写在 `/etc/environment`。

如果你在某些软件完全无法使用输入法的话，需要设置额外的环境变量或者启动参数，继续往下看。

### 从快捷方式打开的话（.desktop）

编辑软件对应的 .desktop 文件，修改 `Exec=` 后面的命令。这些文件存放在 `/usr/share/applications` 和 `~/.local/share/applications`。不要直接修改 `/usr/share/applications` 里的文件，复制一份到用户空间再改。

- 对于 Qt 和 GTK 应用

  ```text
  Exec= env GTK_IM_MODULE=fcitx QT_IM_MODULE=fcitx
  ```

  > `env` 设置启动时的环境变量。

- 对于 Chromium 和 Electron 应用

  以 QQ 为例，在 `linuxqq 【此处】%U` 添加命令行参数：

  ```text
  --ozone-platform=wayland
  ```

  不行的话设置：

  ```text
  --enable-features=UseOzonePlatform --ozone-platform=wayland --enable-wayland-ime
  ```

  示例：

  ```text
  Exec=env DESKTOPINTEGRATION=false /usr/bin/linuxqq --no-sandbox --ozone-platform=wayland %U
  ```

### 从终端命令打开的话

上面的设置只对快捷方式打开生效，从终端用命令打开的话不一定生效。解决办法是编辑 Shell 的配置文件单独设置 alias。

- Zsh/Bash

  编辑 home 目录下的 `.zshrc` 或 `.bashrc` 文件，根据使用的 Shell 而定。

  - Qt 或 GTK 应用（以 Typora 为例）

    ```bash
    alias typora='GTK_IM_MODULE=fcitx QT_IM_MODULE=fcitx typora'
    ```

  - Chromium 和 Electron 应用（以 VS Code 为例）

    ```bash
    alias code='code --enable-features=UseOzonePlatform --ozone-platform=wayland --enable-wayland-ime'
    ```

- Fish

  Fish 的话有两种方法，一种是 `abbr`，另一种是 `function`。

  - abbr

    abbr 是自动替换命令。

    ```fish
    abbr typora 'GTK_IM_MODULE=fcitx QT_IM_MODULE=fcitx typora'
    ```

    ```fish
    abbr code 'code --ozone-platform=wayland'
    ```

  - function

    function 更改命令的功能。

    ```fish
    function typora
     env GTK_IM_MODULE=fcitx QT_IM_MODULE=fcitx typora $argv
    end
    ```

    ```fish
    function code --description '启动code'
     exec code --ozone-platform=wayland $argv
    end
    ```

    > `function` 是函数，`typora` 是要运行的命令，`--description ''` 是描述，中间是这个命令的具体内容 `exec` 是运行后退出终端，如果要保持终端开启的话把 `exec` 换成 `command`，`$argv` 传递 `typora` 命令后的选项和参数（有些应用不需要），`end` 结尾。

### 其他方法

[librime 补丁](https://github.com/busyoGG/librime-patch)这里有一个修复补丁的项目，我没试过，有兴趣的可以自己试试。

## 下一节：[软件安装相关](软件安装相关)

---

# 软件安装相关

1. [如何安装软件](#如何安装软件)
2. [我使用的软件](#我使用的软件)
   - [pacman](#pacman)
   - [AUR](#aur)
   - [Flatpak](#flatpak)
3. [视频播放器开启硬件编解码](#视频播放器开启硬件编解码)
4. [GNOME如何编辑截图](#GNOME如何编辑截图)
5. [AppImage使用方法](#如何使用AppImage)
6. [隐藏不必要的快捷方式](#隐藏不必要的快捷方式)
7. [星火应用商店](#星火应用商店)

## 如何安装软件

安装软件主要分四种方式：

1. `pacman` 从官方仓库和 archlinuxcn 安装软件。

2. `yay` 或者 `paru` 从 AUR（Arch Linux 用户仓库）安装软件。

   AUR 很方便，但要注意辨识它是否安全。千万不要使用来源不明、不再维护、无人使用的 AUR 包。

3. `flatpak` 从 [flathub](https://flathub.org/en) 或指定的 flathub 源下载。需要 GUI 可以安装 `bazaar`。

4. 应用官网下载 AppImage 包直接运行。

   AppImage 和 flatpak 类似，也是所有发行版通用的打包方式，可以理解为免安装便携版。使用方法看本文的[如何使用 AppImage](#如何使用AppImage)。

建议优先级：官方 pacman >> 经过验证的 flatpak > 用户仓库（AUR、CN 源等） > 官网下载

## 我使用的软件

以下是我会安装的软件，以及我认为好用的一些软件，你可以按照你的需求来。

根据使用的桌面环境进行跳转：

### pacman

- [GNOME](#gnome)
- [KDE](#kde)


#### GNOME

```bash
sudo pacman -S --needed mission-center gnome-logs gnome-text-editor gparted dosfstools exfat-utils f2fs-tools udftools xfsprogs gnome-font-viewer gnome-clocks gnome-weather gnome-calculator loupe snapshot baobab celluloid fragments file-roller foliate firefox gst-plugin-pipewire gst-plugins-good pacman-contrib papers easyeffects
```

`mission-center` 类似 Win11 的任务管理器，强烈推荐。

`gnome-logs` 方便查看系统日志。

`gnome-text-editor` GNOME 标配记事本。

`gparted` 磁盘管理工具，可以调节分区大小和格式化分区等等。

`dosfstools exfat-utils f2fs-tools udftools xfsprogs` 补全 gparted 的功能。

`gnome-font-viewer` 方便安装和查看字体。

`gnome-clocks` 时钟工具，可以设置闹钟和计时。

`gnome-weather` 天气，设置地区之后可以在系统托盘里显示天气，安装扩展后可以在时间边上显示天气组件。

`gnome-calculator` 计算器。

`loupe` 图片查看工具。

`snapshot` 相机，摄像头。

`baobab` 磁盘使用情况分析工具。

`celluloid` 是基于 mpv 的视频播放器。

`fragments` 是符合 GNOME 设计理念的种子下载器。

`foliate` 电子书阅读器。

`firefox` Linux 上性能表现最佳的浏览器，需要别的可以商店自行搜索安装。

`gst-plugin-pipewire gst-plugins-good` 激活 GNOME 截图工具自带的录屏。

`pacman-contrib` 提供 pacman 的一些额外功能，比如 `checkupdates` 用来检查更新。

`papers` PDF 阅读器。

`easyeffects` 设置麦克风降噪、混响、音响音效之类的。

#### KDE

```bash
sudo pacman -S --needed mission-center firefox ark gwenview kcalc kate pacman-contrib partitionmanager dosfstools exfat-utils f2fs-tools udftools xfsprogs filelight haruna ksystemlog easyeffects
```

`mission-center` 类 Win11 任务管理器。

`firefox` 浏览器。

`ark` KDE 标配解压缩工具。

`gwenview` 图片编辑查看工具。

`kcalc` 计算器。

`pacman-contrib` 提供 pacman 的一些额外功能，比如 `checkupdates` 用来检查更新。

`partitionmanager` 磁盘管理器。

`dosfstools exfat-utils f2fs-tools udftools xfsprogs` 是对 gparted 功能的补全。

`filelight` 磁盘使用情况分析工具。

`haruna` 是基于 mpv 的视频播放器。

`ksystemlog` 用来查看系统日志。

`easyeffects` 设置麦克风降噪、混响、音响音效之类的。

### AUR

yay 安装软件会询问是否要清理构建文件、显示包差异，通常不用理会直接回车就行。

```bash
yay -S linuxqq-appimage wechat-appimage wps-office-cn wps-office-mui-zh-cn typora-free
```

`linuxqq-appimage` AppImage 版的 QQ。

`wechat-appimage` AppImage 版的微信。

`wps-office-cn` WPS 办公，其实我比较喜欢 onlyoffice。

`wps-office-mui-zh-cn` WPS 的中文语言包。

`typora-free` Typora 的免费版，Markdown 编辑器。

`pacseek` 曾用于可视化搜索官方源和 AUR 软件包；当前已有 `paru-ui`、`pak`、`pacr`、`pacd` 等脚本和直接命令行工作流，不再默认推荐安装。

### Flatpak

```bash
flatpak install flathub io.github.Predidit.Kazumi io.gitlab.theevilskeleton.Upscaler com.github.unrud.VideoDownloader io.github.ilya_zlobintsev.LACT com.geeks3d.furmark io.github.flattool.Warehouse com.github.tchx84.Flatseal com.dec05eba.gpu_screen_recorder
```

`kazumi` 追番。

`upscaler` 图片超分。

`video downloader` 下载 YouTube/Bilibili 144p～8K 视频。

`LACT` 显卡超频、限制功率、风扇控制等等。

`furmark` 显卡烤鸡。

`Warehouse` 用来管理 flatpak 的源、软件、属性、用户数据之类的。

`Flatseal` 管理 flatpak 应用的权限、环境变量之类的。

`gpu_screen_recorder` 类似 NVIDIA App 的录屏软件。

### 其他好用的软件

```text
gnome-calendar 日历
gnome-music 本地音乐播放器
decibels 显示波形的音频播放器
curtail 压缩图片大小
switcheroo 变更图片格式
komikku 看漫画
secrets 本地加密保存账号密码
wordbook 英英词典
shortware 收听电台
localsend 局域网传输文件
handbrake 视频转码
footage 简单的视频剪辑、压制软件
gdu 终端磁盘空间查看器
```

## GNOME如何编辑截图

gradia 可以用来编辑截图。

```bash
flatpak install be.alexandervanhee.gradia
```

在系统设置 > 键盘 > 查看自定义快捷键，设置一个自定义的截图快捷键，命令填入：

```bash
flatpak run be.alexandervanhee.gradia --screenshot=INTERACTIVE
```

## 视频播放器开启硬件编解码

#### GNOME

- 方法一：配置文件

  1. 编辑 mpv 配置文件（记得打开一次 mpv 生成目录）。

  ```bash
  vim ~/.config/mpv/config
  ```

  写入：

  ```text
  hwdec=auto-safe
  ```

  2. celluloid 首选项的配置文件页面，激活"加载 mpv 配置文件"，手动指定一下路径。

- 方法二：celluloid 首选项

  在首选项的杂项页面写入：

  ```text
  hwdec=yes
  ```

#### KDE

haruna 会自动开启。

## 如何使用AppImage

需要安装 `fuse3` 和 `fuse2`，通常已经安装好了。文件下载下来之后右键属性设置可执行权限之后即可运行，或者使用命令：

```bash
chmod +x ~/path/to/files.appimage
```

感兴趣的可以使用这条命令把 AppImage 解压出来看看里面都有什么：

```bash
/path/to/files.appimage --appimage-extract
```

会出现一个 squashfs-root 文件夹，里面就是解压出来的文件。

### 把AppImage集成到系统

- gear lever

  flathub 下载：

  ```bash
  flatpak install flathub it.mijorus.gearlever
  ```

  或者 AUR 下载：

  ```bash
  yay -S gearlever
  ```

  由于 AppImage 的安装涉及到解压和打包，所以用 gearlever 打开较大的 AppImage 会有一点慢，稍等一会就会出现启动或者集成到系统的选项了。卸载也是用这个软件。

[appimagehub](https://www.appimagehub.com/browse?ord=latest) 这个网址有很多有趣的 AppImage 应用，有兴趣的可以搜索玩玩看。

## 隐藏不必要的快捷方式

原理：修改软件的 .desktop 文件添加 `NoDisplay=true` 就能隐藏。这个文件通常存放在 `/usr/share/applications` 或者 `~/.local/share/applications`。手动修改的话要复制到 `~/.local/share/applications` 再改。

- 方法一：pinapp

  从应用商店搜索 pinapp 安装 pins，图标是个图钉钉在蓝色的板子上。

  也可以用命令安装，更方便：

  ```bash
  flatpak install flathub io.github.fabrialberio.pinapp
  ```

  选择想隐藏的图标激活 invisible 即可。

- 方法二：menulibre

  使用 pacman 安装：

  ```bash
  sudo pacman -S menulibre
  ```

  选择想隐藏的图标激活 invisible，然后保存即可。

- GNOME 的方法三：apphider 扩展

  商店搜索 extension，安装扩展管理器。然后安装 apphider 扩展，可以右键隐藏概览里的快捷方式。

## 星火应用商店

[Spark Store](https://www.spark-app.store/)

因为特殊国情，星火商店安装的软件可能比 AUR 的更好用。得益于开发者的努力，现在只需要一条简单的命令就能装上星火商店啦：

```bash
yay -S spark-store
```

## 专业软件平替

## 修图

photopea

canva

gimp

krita

## 视频剪辑

达芬奇

```bash
yay -S davinci-resolve

# 要去官网自己下载 Linux 版本的包，放在 .cache/yay/davinci-resolve 里面
```

kdenlive

shotcut

以及各类线上剪辑网站，比如 flixier。

其他领域的不了解。

### [我的GNOME自定义设置](我的GNOME自定义设置)

### [我的KDE自定义设置](我的KDE自定义设置)

---

# 我的GNOME自定义设置

目录

- [快捷键设置](GNOME配置#快捷键)
- [功能性扩展](GNOME配置#功能性扩展)
- [其他有用扩展](GNOME配置#其他有用的扩展)
- [美化用扩展](GNOME配置#美化用扩展)
- [实现Windows布局](GNOME配置#实现windows布局)
- [调节外接屏幕亮度](GNOME配置#调节外接屏幕亮度)
- [光标主题](GNOME配置#光标主题)
- [GNOME主题](GNOME配置#gnome主题)
- [导出快捷键](GNOME配置#导出gnome快捷键)
---


## 快捷键

- 可选：交换大写锁定键和 ESC 键

  安装 gnome-tweaks：

  ```bash
  sudo pacman -S gnome-tweaks
  ```

  在键盘 → 其他布局里面交换 CAPSLOCK 和 ESC 键。



设置 > 键盘 > 查看自定义快捷键

- 导航

```text
Super+Ctrl+Q/E # 将窗口左右移动工作区
Super+Shift+Q/E # 移动到左/右工作区
ps：GNOME 默认 Super+滚轮上下可以左右切换工作区
Alt+Tab # 切换窗口
Super+Tab # 切换应用程序
Alt+` # 在应用程序的窗口之间切换窗口
Super+H # 隐藏所有窗口
```

- 截图

```text
Super+Alt+A # 交互式截图
Super+Ctrl+A # 对窗口进行截图
Super+Ctrl+Shift+A # 截图（全屏截图）
```

- 无障碍

```text
屏幕阅读 禁用
Alt+Super+0 # 开关屏幕缩放
```

- 窗口

```text
Super+Q # 关闭窗口
Super+F # 切换最大化
Super+Alt+F # 切换全屏
```

- 系统

```text
Ctrl+Super+S # 打开快速设置菜单
Super+G # 显示全部应用
```

- 自定义快捷键<快捷键>   <命令>

```text
Super+B   firefox
Super+T   ghostty
Super+`    missioncenter
Super+E   nautilus
Super+Shift+S   flatpak run be.alexandervanhee.gradia --screenshot=INTERACTIVE
Super+M gnome-text-editor
Ctrl+Alt+S gnome-control-center
```

## 功能性扩展

#### ⚠️ 警告：扩展在 GNOME 桌面环境大版本更新的时候大概率会大面积失效，如果出现 GNOME 桌面环境的大版本更新，一定要先关闭所有扩展，谨慎行事。

（9月23日 GNOME 更新了 49 版本，部分扩展尚未更新。）

- 从商店安装蓝色的扩展管理器

```bash
flatpak install flathub com.mattjakeman.ExtensionManager
```

或者可以安装浏览器集成扩展 [firefox-gnome-shell-extension-integration](https://addons.mozilla.org/en-US/firefox/addon/gnome-shell-integration/)，然后安装 `chrome-gnome-shell`。

```bash
yay -S chrome-gnome-shell
```

这样就可以直接在 https://extensions.gnome.org/ 这个网站通过开关安装扩展了。

- AppIndicator and KStatusNotifierItem Support

  面板上显示后台应用。

- caffeine

  防止熄屏。

- lock keys

  装 kazimieras.vaina 的那个。OSD 显示大写锁定和小键盘锁定。设置里把指示器风格改成 show/hide cap-locks only。

- Fuzzy Application Search

  模糊搜索。

- steal my focus window

  如果打开窗口时窗口已经被打开则置顶。

- tiling shell

  窗口平铺，tilingshell 是用布局平铺，记得自定义快捷键，我快捷键是 Super+W/A/S/D 对应上下左右移动窗口，Super+Alt+W/A/S/D 对应上下左右扩展窗口，Super+Z 取消平铺，Super+C 把窗口移动到屏幕中心。

- tiling assistant

  这个扩展提供最基础的四角平铺和上下左右半屏平铺功能。设置里取消激活 popup，gaps 和 tiling shell 调成一样的，禁用 keybinds 里 general 一项的第 1/2/4 项，仅保留 restore window size。

- 可选：forge

  如果你更喜欢 sway/hyprland 那样的自动平铺功能，可以安装 forge。我没有深入用过这个扩展，说不定会和 tiling shell 和 tiling assistant 冲突，所以自己探索吧。

- color picker

  获取屏幕上的颜色，对自定义非常有用。

- Arch Linux Updates Indicator

  在面板上显示一个和 Arch 更新相关的图标。要安装 pacman-contrib。设置取消始终显示，高级设置里命令改成：

  ```bash
  ghostty -e sudo pacman -Syu
  ```

- quick settings tweaks

  让右上角的快速设置面板变得更合理。包括把通知从时间面板移动到快速设置面板，缩小时间面板的占地面积，免打扰模式开关按钮移动到快速设置面板，允许调整单个应用的声音大小等等。

  扩展设置的 menu 页面的两项可以激活，第一项让声音调整菜单以悬浮的方式显示出来，第二项给这个功能增加动画，很酷。

- clipboard indicator

  剪贴板历史。设置里设置 Super+V 切换菜单。

可选：使用鼠标的用户建议安装的扩展

- quick close in overview

  在概览里面不用点窗口右上角的叉关闭窗口了，而是使用鼠标中键。

- Top Panel Workspace Scroll

  在顶部面板上滚动滚轮切换工作区。

- dash to dock

  把概览里的快捷栏放到桌面上（如果要用 Windows 布局的话不要装这个）。

其他有用扩展见[其他有用的扩展](#其他有用的扩展)和[实现 Windows 布局](#实现windows布局)。

#### 其他有用的扩展

- desktop widgets（desktop clock）

  在桌面上显示一个时钟组件。

- lock screen background

  更换锁屏背景（默认锁屏是模糊，会透出桌面壁纸，已经很好看了，所以这个意义不大）。

- vitals

  右上角显示当前资源使用情况。

- emoji copy

  快捷复制 emoji，很有趣。

- burn my windows

  应用开启和打开的动画。

- hide activities button

  隐藏左上角的 activities 按钮。

- Quick Settings Audio Panel

  让你快捷地在右上角的面板里调整每个软件、网页的音频。quick settings tweaks 扩展包含了这个功能，如果安装了就不要装这个啦。

- battery time

  显示电量剩余可用时间。

- custom reboot

  可以快捷重启到别的系统。设置里选择使用 GRUB，然后在快捷设置菜单里 reload 和 enable。（GRUB 放在 btrfs 的话没法使用这个）

- search light

  可以在桌面直接调出搜索，不用进 overview 才能搜索了。

## 美化用扩展

- blur my shell

  透明度美化。

- hide top bar

  隐藏面板（panel，顶部的那个面板，Win 叫任务栏），和 app icons taskbar / dash to panel 之类的扩展冲突。设置里激活 sensitivity 的第一个。intellihide 取消激活第二项。

- user themes

  管理主题。

- logo menu

  在面板显示一个 logo，好玩。设置里更换 GNOME extension 为 extension manager；终端换 ghostty；systemmonitor 换 missioncenter；取消激活 show activities button。

- desktop cube

  桌面端用户强烈推荐。把工作区切换从平铺变成一个可以旋转的方块的面。设置的 overview 里把透明度（opacity）都改成 50%，超级酷！

- rounded window corners reborn

  让所有窗口变成圆角。这个扩展是真神。设置里取消激活 skip libadwaita applications，然后把 corner radius 改成 14，这样就和 GNOME 的圆角没区别了。

## 实现Windows布局

可以通过扩展把 GNOME 变成 Windows 布局。

1. 安装扩展

   - app icons taskbar

     实现 Windows 那样的任务栏。和 hide top bar、dash to dock 冲突。如果关闭了在所有显示器上显示就无法智能隐藏，原因不明。

   - desktop icons ng

     实现 Windows 那样的桌面快捷方式。如果快捷方式打了个叉让你设置执行权限的话在终端去到 ~/Desktop 目录，然后运行这个命令设置相关元数据。这是 GNOME 的一个安全措施。

     ```bash
     gio set ~/Desktop/*.desktop "metadata::trusted" true
     ```

   - 可选：arcmenu

     这是功能强大的开始菜单扩展。需要 pacman 安装 gnome-menus。

   - 可选：just perfection

     功能强大的自定义扩展，可以设置 GNOME 各个元素的开关。不过根据 GNOME 版本的不同能设置的选项会有所不同，稳定性堪忧。

   - 可选：用 dash to panel 替换 app icons taskbar

     dash to panel 设置更简单，但没有 app icons taskbar 好看。

2. 修改扩展的设置

   - app icons taskbar

     settings 页面里：

     激活 hide dash in overview（隐藏概览里的快捷栏）。

     app icons position in panel（软件图标在面板上的位置）改成 center。

     激活 show all apps button（显示所有软件按钮），位置选 right（右边）。

     icon size（图标大小）和 padding（间距）按需调整。

     panel 里激活 intellihide（智能隐藏），设置里把 only focused window（仅选中的窗口）改成 all windows（所有窗口）。

     panel location（面板位置）选 bottom（底部）。

     panel height（面板高度）调整到合适的数值。

     取消激活 show activities button（显示活动按钮）。

     show weather near clock（在时钟旁显示天气）选 right（右边）。

     clock position in panel（时钟在面板中的位置）改成 right。

     这样布局就和 Win11 一模一样了。

   - desktop icons ng

     取消激活显示个人文件夹、回收站图标。

## 调节外接屏幕亮度

[ddcutil-service](https://github.com/digitaltrails/ddcutil-service)

GNOME 默认没法调节外接屏幕亮度，通过 ddcutil + 扩展可以进行调节。

```bash
yay -S ddcutil-service
```

```bash
sudo gpasswd -a $USER i2c
```

安装扩展 [Control monitor brightness and volume with ddcutil](https://extensions.gnome.org/extension/6325/control-monitor-brightness-and-volume-with-ddcutil/)

```bash
reboot
```

### ddcutil使用方法

获取显示器信息：

```bash
ddcutil detect
```

示例输出：

```text
Display 1
   I2C bus:  /dev/i2c-14
   DRM_connector:           card1-DP-2
   EDID synopsis:
      Mfg id:               SKG - UNK
      Model:                H27T22C
      Product code:         10099  (0x2773)
      Serial number:
      Binary serial number: 1 (0x00000001)
      Manufacture year:     2024,  Week: 46
   VCP version:         2.1
```

注意第一行的 Display 1。

获取当前亮度：

```bash
ddcutil --display 1 getvcp 10
```

加减亮度：

```bash
ddcutil --display 1 setvcp 10 + 5
ddcutil --display 1 setvcp 10 -- 5
```

输出应该为：

```text
'ghostty'
'-e'
```

## 光标主题

主题下载网站 https://www.gnome-look.org/browse?cat=107&ord=latest

将下载的 .tar.gz 文件里面的文件夹放到 `~/.local/share/icons/` 目录下，没有 icons 文件夹的话自己创建一个。

## gnome主题

GNOME 的默认主题已经相当漂亮，如果有修改主题的需要的话去这个网站：

https://www.gnome-look.org/browse?cat=134&ord=latest

通常下载页面都有指引，文件路径是 `~/.themes/`，放进去之后在 user themes 扩展的设置里面改可以改主题。

主题主要分 gtk-3、gtk-4 和 gnome-shell。user themes 扩展和 gnome-tweaks 之类的软件修改 gnome-shell 比较方便。修改 gtk-3 主题的话建议用 nwg-look，gtk-4 的文件自己复制粘贴到 `~/.config/gtk-4.0/`。

## 下一节：[终端美化](终端美化)


## 导出gnome快捷键

用 `dconf dump 路径` 命令导出 dconf 配置到文件。用 `dconf load 路径` 命令导入。快捷键的配置可以使用 `dconf-editor` 查找。

---

# 我的KDE自定义设置

目录

- [桌面编辑](KDE配置#桌面编辑)
  - [桌面鼠标功能](KDE配置#桌面鼠标功能)
  - [桌面组件](KDE配置#桌面组件)
  - [桌面面板(任务栏)](KDE配置#桌面面板任务栏)
- [截图软件设置](KDE配置#截图软件设置)
- [系统设置](KDE配置#系统设置)
  - [快捷键](KDE配置#快捷键)
  - [无障碍辅助](KDE配置#无障碍辅助)
  - [窗口管理](KDE配置#窗口管理)
  - [窗口行为](KDE配置#窗口行为)
  - [桌面特效](KDE配置#桌面特效)
  - [虚拟桌面](KDE配置#虚拟桌面)
- [主题美化](KDE配置#主题美化)
  - [更换桌面壁纸](KDE配置#更换桌面壁纸)
  - [更换锁屏壁纸](KDE配置#更换锁屏壁纸)
  - [文字和字体](KDE配置#文字和字体)
  - [全局主题](KDE配置#全局主题)
- [用户头像](KDE配置#用户头像)
---

## 这是我的 KDE

![](pictures/KDE-preview.png)

## 桌面编辑

### 桌面鼠标功能

右键桌面 > 桌面和壁纸 > 鼠标操作 > 添加操作

1. 中键 程序启动器
2. 垂直滚动滚轮 切换桌面

### 桌面组件

#### wallpaper effects

这个组件可以在聚焦窗口时模糊桌面。

右键进入编辑模式 > 左上角添加组件 > 获取新挂件 > 下载 Plasma 挂件 > 搜索安装 wallpaper effects，或者从 AUR 安装：

```bash
yay -S plasma6-applets-wallpaper-effects
```

添加到桌面后进行配置：blur radius 改成 30；pixelate effect 的 enable 改成 never；grain 改成 never；color effects 改成 never；激活 rounded corners，radius 改成 15。

#### Adaptifier

更新相关的桌面组件。

#### kdeconnect

```bash
sudo pacman -S kdeconnect
```

可以和手机传输文件，共享剪贴板。手机也需要下载 KDE Connect。

### 桌面面板（任务栏）

右键任务栏（KDE 里叫面板），显示面板配置。设置为半透明；悬浮改成仅小程序；显示隐藏改成避开窗口；删除工作区、显示桌面相关组件；添加两个间隔，把开始菜单和软件移动到中心。

#### 右下角组件

点击时间左边的上箭头，在弹出来的窗口的右上角开启系统托盘设置，项目里面按需设置。我会设置电量和电池总是显示，蓝牙总是隐藏。

## 截图软件设置

打开 spectacle 的设置。

常规页面勾选"保存文件到默认文件夹"，再点击这行字下面的框，选择复制到剪贴板。

## 系统设置

### 快捷键

系统设置 > 输入和输出 > 键盘 > 快捷键

- 应用程序

  KRunner: Meta+Z

  浏览器：Meta+B

  系统设置：启动：Ctrl+Alt+S

  新增：任务中心（missioncenter）：Meta+Esc

  Konsole 终端：Meta+T


- 窗口管理：

  磁贴编辑开关：Meta+F9

  关闭窗口：Meta+Q

  强制终止窗口：Meta+Ctrl+Q

  全屏显示窗口：Meta+Alt+F

  显示隐藏桌面总览：Meta

  移动窗口到中央：Meta+C

  暂时显示桌面：Meta+M

  自定义快速铺放窗口到上下左右：Meta+W/A/S/D

  然后打开磁贴编辑器编辑一个自己喜欢的布局。

  最大化窗口：Meta+F

  最小化窗口：Meta+H

- Plasma 工作空间

  激活应用程序启动器：Alt

  显示活动切换器：Meta+Tab

### 无障碍辅助

"抖动后放大光标"调到最大（不是）

### 窗口管理

系统设置 > 窗口和应用 > 窗口管理

### 窗口行为

标题栏操作

鼠标滚轮：移动到上个/下个桌面

### 桌面特效

- 窗口惯性晃动

  激活窗口惯性晃动，启用高级设置，调整效果到自己喜欢的程度。我的设置是 25、70、15。

- geometry change

  点击获取新效果，这个要加载很久很久。下载 geometry change，或者从 AUR 安装。从 AUR 安装的话需要重新打开系统设置。

  ```bash
  yay -S kwin-effects-geometry-change
  ```

  这可以给窗口的快捷键平铺添加动画。动画速度设置为 500ms。

- 窗口透明度

  激活窗口透明度，按照喜好设置。

- 窗口背景虚化和背景对比度

  按需设置。

- rounded corners（圆角）

  ```bash
  yay -S kwin-effect-rounded-corners-git
  ```

  ```bash
  reboot
  ```

  - 圆角页面

    圆角半径都改为 15，取消激活平铺时禁用圆角。

  - 轮廓

    主轮廓的活动窗口轮廓粗细改成 2，激活使用装饰色：高亮；非活动窗口的粗细改成 0；

    次轮廓的活动窗口轮廓粗细改成 1，激活使用装饰色：高亮；非活动窗口的粗细改成 0；

    取消激活平铺时禁用轮廓。

### 虚拟桌面

按需增加，激活切换时显示屏幕提示，改成 500ms。

## 主题美化

### 更换桌面壁纸

系统设置 > 外观和样式 > 壁纸

按需选择壁纸类型。

这里有一个小技巧，如果你按住左键把一张图片从 Dolphin 拖放到桌面上，会跳出来一个菜单。

### 更换锁屏壁纸

系统设置 > 安全和隐私 > 锁屏 > 配置外观

按需选择壁纸类型。

### 文字和字体

系统设置 > 外观和样式 > 文字和字体

我喜欢用 Adwaita 字体，大小 11pt。

### 全局主题

我觉得 Breeze 已经挺漂亮了，就不下载第三方主题了。

系统设置 > 外观和样式 > 颜色和主题

- 颜色

  Breeze 微风经典

  基于壁纸获取强调色，或者选择自定义强调色，从壁纸上提取一个合适的颜色。

- 应用程序外观样式

  选择默认的 Breeze 微风，点击右下角的画笔配置，菜单透明度往左 2 格。

- Plasma 外观和样式

  Breeze 微风深色

- 窗口装饰元素

  Breeze 微风。点击右下角的笔，设置按钮大小。配置标题栏按钮，按需调整。

- 光标

  Breeze 微风深色，大小 30。
- SDDM 主题

  Breeze

- 登录屏幕

  换一个壁纸。

## 用户头像

系统设置 > 系统 > 用户

更换一个自己喜欢的头像。

## 下一节：[终端美化](终端美化)

---

# 终端美化

目录

- [更换shell](终端美化#更换shell)
  - [fish](终端美化#fish)
  - [zsh](终端美化#zsh)
- [shell提示符美化-starship](终端美化#starship提示符美化)
- [Ghostty美化](终端美化#ghostty美化)
- [Konsole美化](终端美化#konsole美化)
- [Kitty美化](终端美化#kitty美化)

---

## Shell美化

### 更换shell

#### fish

Fish 提供了开箱即用的方便功能。

1. 安装 Fish。

   ```bash
   sudo pacman -S fish
   ```

2. 编辑配置文件去掉默认的启动文字。

   ```bash
   vim ~/.config/fish/config.fish
   ```

   写入：

   ```text
   set fish_greeting ""
   ```

- 使用方法

   用编辑 .desktop 文件，用类似 `ghostty -e fish` `kitty -e fish` 这样的方式打开终端。或者打开终端后手动运行一次 Fish。

#### zsh

1. ```bash
   sudo pacman -S zsh
   ```

2. ```bash
   chsh -s /usr/bin/zsh
   ```

3. 语法检查、自动补全、Tab 选择、历史记录。

   ```bash
   sudo pacman -S zsh-syntax-highlighting zsh-autosuggestions zsh-completions
   ```

   ```bash
   vim ~/.zshrc
   ```

   写入：

   ```bash
   # 设置历史记录文件的路径
   HISTFILE=~/.zsh_history

   # 设置在会话（内存）中和历史文件中保存的条数，建议设置得大一些
   HISTSIZE=1000
   SAVEHIST=1000

   # 忽略重复的命令，连续输入多次的相同命令只记一次
   setopt HIST_IGNORE_DUPS

   # 忽略以空格开头的命令（用于临时执行一些你不想保存的敏感命令）
   setopt HIST_IGNORE_SPACE

   # 在多个终端之间实时共享历史记录
   # 这是实现多终端同步最关键的选项
   setopt SHARE_HISTORY

   # 让新的历史记录追加到文件，而不是覆盖
   setopt APPEND_HISTORY
   # 在历史记录中记录命令的执行开始时间和持续时间
   setopt EXTENDED_HISTORY

   # 自动补全
   source /usr/share/zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh
   ZSH_AUTOSUGGEST_STRATEGY=(history completion)

   # 语法检查
   source /usr/share/zsh/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh

   # 开启 tab 上下左右选择补全
   zstyle ':completion:*' menu select
   autoload -Uz compinit
   compinit
   ```

4. 重启终端。

### starship提示符美化

[Starship](https://starship.rs/)

1. 安装 Nerd 字体和 Starship。

   ```bash
   sudo pacman -S ttf-jetbrains-mono-nerd starship
   ```

2. 编辑配置文件激活 Starship。

   - Fish

     ```bash
     vim ~/.config/fish/config.fish
     ```

     ```text
     starship init fish | source
     ```

   - Zsh

     ```bash
     vim ~/.zshrc
     ```

     ```text
     eval "$(starship init zsh)"
     ```

3. <https://starship.rs/presets/>

   到这个网站下载一个自己喜欢的预设主题，重命名为 `starship.toml`，放到 `~/.config`，或者你有兴趣的话也可以自己做一个。

4. 重启终端。

## Ghostty美化

1. 下载 [Catppuccin](https://github.com/catppuccin/ghostty?tab=readme-ov-file) 颜色配置，或者找一个你喜欢的，粘贴到 `~/.config/ghostty/themes/`。

2. 修改 `~/.config/ghostty/config` 配置文件，例如下载的是 frappe 的话：

   ```text
   theme = catppuccin-frappe.conf

   # 隐藏标题栏
   window-decoration = none

   # 设置透明度
   background-opacity=0.8

   # 设置字体和字体大小
   font-family = "Adwaita Mono"
   font-size = 15

   # 设置左右边距
   window-padding-x=10
   # 设置上下边距
   window-padding-y=10
   ```

3. 重启终端。

## Konsole美化

1. 菜单 > 设置 > 显示工具栏 > 去掉两个勾选。

2. 右键 > 菜单 > 设置 > 配置 Konsole。

   常规页面里激活"移除窗口标题和框架"。

   配置方案里新建一个配置方案；外观里点击"获取新方案"：下载一个自己喜欢的，我使用 Catppuccin Frappe。选中喜欢的配色方案后点击编辑设置 20% 透明度；设置字体为 Adwaita Mono（一个你喜欢的 Mono 等宽字体），大小 15pt；"其他"页面里设置边距，取消激活调整大小后显示终端大小提示。

   滚动里隐藏滚动条，取消激活高亮显示刚刚进入视图的行。确认。

   选中刚刚创建的配置方案设置为默认。

   确认。

   重启终端。

## Kitty美化

网上下载自己喜欢的颜色配置文件 <https://github.com/catppuccin/kitty>

我以 Catppuccin Frappe 为例，下载 frappe.conf，复制到 `~/.config/kitty/themes` 目录下。

编辑 Kitty 的配置文件：

```bash
vim ~/.config/kitty/kitty.conf
```

```text
# 导入颜色文件
include themes/frappe.conf
# 设置左右边距
window_padding_width 5
# 隐藏标题栏
hide_window_decorations yes
# 背景透明度
background_opacity 0.8
# 字体
font_family Adwaita Mono
# 字体大小
font_size 15
# 不要记住窗口大小（yes no）
remember_window_size no
# 关闭窗口时不要询问是否关闭
confirm_os_window_close 0
# 设置默认的 shell 为 fish
shell /usr/bin/fish
```

## 下一节：[grub美化](grub美化)

---

# grub美化

1. 网上下载 GRUB 主题放到 `/efi/grub/themes`。

    其他可能会用到的路径有 `/usr/share/grub/themes/` 和 `/boot/grub/themes`。

2. 编辑 GRUB 源文件

    ```bash
    vim /etc/default/grub
    ```
    - 主题路径
        `GRUB_THEME="/path/to/theme.txt"`

    - 分辨率
        `GRUB_GFXMODE=2560x1440,1920x1080,auto`

3. 生成 GRUB 的配置文件

    ```bash
    grub-mkconfig -o /efi/grub/grub.cfg
    ```

我喜欢的主题：

[CyberGRUB-2077](https://github.com/adnksharp/CyberGRUB-2077)

[Crossgrub](https://github.com/krypciak/crossgrub)

这个 repo 有一些别人收集的主题：

https://github.com/Jacksaur/Gorgeous-GRUB

## 下一节：[显卡切换](显卡切换)

---

# 显卡切换

## 混合模式下用独显运行

- PRIME

    ```bash
    sudo pacman -S nvidia-prime
    ```

    使用 `prime-run` 命令使用独显运行软件：

    ```bash
    prime-run firefox
    ```

- switcheroo-control

    GNOME 装这个可以右键桌面快捷方式选择使用独显运行。

    ```bash
    sudo pacman -S switcheroo-control
    ```

    ```bash
    sudo systemctl enable --now switcheroo-control
    ```

- KDE 桌面可以直接开始菜单右键编辑应用程序在高级页面设置用独显运行。

## 显卡切换

目前**在 Wayland 没有完善的显卡切换**，只能做到从混合模式切换到核显模式。独显直连需要手动进 BIOS 调整。

以下是两个我试过的工具，建议安装时处在混合模式。从混合切到独显直连大概率会失败，谨慎操作。

- supergfxctl

    ASUS 华硕用户可以用 supergfxctl。

    [Linux for ROG Notebooks](https://asus-linux.org/)

    ```bash
    yay -S supergfxctl
    ```

    ```bash
    sudo systemctl enable --now supergfxd
    ```

    GNOME 从扩展里下载 GPU supergfxctl switch。

    KDE 从 AUR 安装这个 `plasma6-applets-supergfxctl`：

    ```bash
    yay -S plasma6-applets-supergfxctl
    ```

- envycontrol

    [GitHub - bayasdev/envycontrol: Easy GPU switching for Nvidia Optimus laptops under Linux](https://github.com/bayasdev/envycontrol)

    ```bash
    yay -S envycontrol
    ```

    GNOME 装扩展 GPU Profile Selector。

    KDE 在桌面右键进入编辑模式，挂件商店里下载 Optimus GPU Switcher。

## 下一节：[虚拟机](虚拟机)

---

# 热切换显卡直通


注意，这是我的情况下运行的命令，你要按照自己的实际情况进行修改。

## 开启显卡直通

1. 确保开启混合模式，显示器画面由核显输出。


2. 确定 NVIDIA 的 DRM 文件名

    ```bash
    ls -l /sys/class/drm/card*/device/driver
    ls -l /sys/class/drm/render*/device/driver
    ```

    > `-l` 显示更多信息

    > `drm` 是 Linux 内核的一个子系统，负责显卡的调度。

    示例输出：

    ![](pictures/gpupassthrough/drmname.png)

    在上面这个例子里可以确定 N 卡是 `card0` 和 `renderD129`。

3. 确认 N 卡上的所有进程

    用以下命令确认正在使用 N 卡的进程（此处的 `card0` `renderD129` 应为你实际的 DRM 文件名）。

    ```bash
    sudo fuser -v /dev/nvidia*
    sudo fuser -v /dev/dri/card0
    sudo fuser -v /dev/dri/renderD129
    ```
    > `fuser` 显示正在使用这个文件的进程。

    > `-v` 显示更多信息。

   - 在 Niri 配置文件里忽略 N 卡的 DRM

        如果你是 Niri，即使以核显运行 Niri，也可能在 N 卡的进程中出现一个 niri，需要编辑配置文件让 Niri 忽略 N 卡。

        1. 确认显卡文件的绝对路径

            虽然可以直接使用 `card0` `renderD129` 指定显卡，但是这个东西是动态分配的，重启后可能会变化，我们需要一个不会变的。

            运行这段命令确认 N 卡的 PCI 路径：
            ```bash
            ls -l /dev/dri/by-path/
            ```
            > `/dev/dri/by-path/` 这是物理硬件路径。

            示例输出：
            ```text
            ls -l /dev/dri/by-path/
            lrwxrwxrwx - root 30 3月  17:09  pci-0000:01:00.0-card -> ../card0
            lrwxrwxrwx - root 30 3月  17:09  pci-0000:01:00.0-render -> ../renderD129
            lrwxrwxrwx - root 30 3月  17:09  pci-0000:66:00.0-card -> ../card1
            lrwxrwxrwx - root 30 3月  17:09  pci-0000:66:00.0-render -> ../renderD128
            ```
            > 你可以注意到这些都是指向 DRM 的链接。

            `pci-0000:01:00.0-card`，`pci-0000:01:00.0-render` 这两串对应主板物理插槽的 PCI 地址就是我们需要的东西。加上前面的 `/dev/dri/by-path/` 就是显卡的绝对物理硬件路径。

        2. 编辑 Niri 的配置文件

            ```text
            debug {
                ignore-drm-device "/dev/dri/by-path/pci-0000:01:00.0-card"
                ignore-drm-device "/dev/dri/by-path/pci-0000:01:00.0-render"
            }
            ```

            > 如果配置 ignore 之后显卡还是出现在了 N 卡进程里，可以尝试加上 `render-drm-device` 指定 Niri 使用的 render。

            > `render-drm-device "/dev/dri/by-path/pci-0000:66:00.0-render"`

        3. 重启 Niri


4. 杀死进程（⚠️警告⚠️ 仔细看一下有哪些进程，如果有桌面环境可能需要别的处理）

    ```bash
    sudo fuser -k -9 /dev/nvidia*
    ```

    > `-k` 关闭正在使用这个文件的进程。

    > `-9` 强制终止。

    > `nvidia*` 星号是一个通配符，代表所有前面带 nvidia 字符的文件。

5. 移除 NVIDIA 的所有模块

    ```bash
    sudo rmmod nvidia_drm
    sudo rmmod nvidia_modeset
    sudo rmmod nvidia_uvm
    sudo rmmod nvidia
    ```

6. 解绑驱动

    1. 确认和 N 卡同 IOMMU 组的 PCI 地址

        ```bash
        for d in /sys/kernel/iommu_groups/*/devices/*; do
            n=${d#*/iommu_groups/*}; n=${n%%/*}
            printf 'IOMMU Group %s ' "$n"
            lspci -D -nns "${d##*/}"
        done
        ```
        示例输出：

        ![](pictures/gpupassthrough/iommu.png)
        需要记录和显卡在同一个 `IOMMU Groups` 的设备的这部分 `0000:01:00.0` `0000:01:00.1`。


    2. 查询驱动

        我们未必知道和 N 卡同组的其他东西的驱动是什么，需要查一下：

        ```bash
        lspci -Dk
        ```

        > `-k` 显示内核驱动信息。

        > `-D` 显示 domain。
        示例输出：

        ![](pictures/gpupassthrough/drivers.png)

        `Kernel driver in use` 后面的 `snd_hda_intel` `nvidia` 就是正在使用的驱动。

    3. 从驱动解绑（此处的 `0000:01:00.0` 部分应为你实际的 PCI 地址，`nvidia` `snd_hda_intel` 应为你实际的驱动名）

    ```bash
    # 这里也许会报错，因为前面已经 rmmod nvidia 之后可能已经解绑了。
    echo "0000:01:00.0" | sudo tee /sys/bus/pci/drivers/nvidia/unbind

    # 解绑音频模块驱动
    echo "0000:01:00.1" | sudo tee /sys/bus/pci/drivers/snd_hda_intel/unbind
    ```

    > `tee` 将标准输入复制到文件。使用 `sudo tee` 而不是重定向符 `>` 是因为重定向符由当前 shell 运行，没有 root 权限处理 `/sys` 里的文件。

7. 让 VFIO 接管

    ```bash
    # 加载 VFIO 模块
    sudo modprobe vfio-pci

    # 覆盖驱动为 VFIO
    echo "vfio-pci" | sudo tee /sys/bus/pci/devices/0000:01:00.0/driver_override
    echo "vfio-pci" | sudo tee /sys/bus/pci/devices/0000:01:00.1/driver_override

    # 重新扫描设备绑定 VFIO
    echo "0000:01:00.0" | sudo tee /sys/bus/pci/drivers_probe
    echo "0000:01:00.1" | sudo tee /sys/bus/pci/drivers_probe
    ```

    此时显卡就应该给 VFIO 了，可以用下面这条命令确认：
    ```bash
    lspci -k | grep -A 2 -i nvidia
    ```

## 热切换内存大页

默认的内存大页是 2MB，如果你的内存足够多，可以试试使用 1GB 的大页。

### 2MB

1. 释放缓存，清理内存碎片

    ```bash
    sudo sync
    echo 3 | sudo tee /proc/sys/vm/drop_caches
    echo 1 | sudo tee /proc/sys/vm/compact_memory
    ```

2. 分配内存大页（把 8192 换成你实际需要的大页数量）

    ```bash
    sysctl -w vm.nr_hugepages=8192
    ```

    确认是否成功：
    ```bash
    cat /proc/sys/vm/nr_hugepages
    ```

### 1GB

1. 释放缓存，清理内存碎片

    ```bash
    sync
    echo 3 | sudo tee /proc/sys/vm/drop_caches
    echo 1 | sudo tee /proc/sys/vm/compact_memory
    ```
2. 分配内存大页（把 16 换成你实际需要的大页数量）

    ```bash
    echo 16 | sudo tee /sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages
    ```

    确认是否成功：
    ```bash
    cat /sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages
    ```

3. 修改虚拟机 XML

    2MB 的时候写的是 `<hugepages>`，1GB 的话要加上 `<page size="1048576" unit="KiB"/>`。

   ```xml
    <memoryBacking>
        <hugepages>
            <page size="1048576" unit="KiB"/>
        </hugepages>
    </memoryBacking>
   ```

## 关闭显卡直通

关闭比开启简单得多。

1. 确认显卡直通虚拟机已经关闭

    一定要关，不然可能会卡死。

2. 解绑 VFIO

    ```bash
    # 移除驱动覆盖
    echo "" | sudo tee /sys/bus/pci/devices/0000:01:00.0/driver_override
    echo "" | sudo tee /sys/bus/pci/devices/0000:01:00.1/driver_override

    # 解绑 VFIO
    echo "0000:01:00.0" | sudo tee /sys/bus/pci/drivers/vfio-pci/unbind
    echo "0000:01:00.1" | sudo tee /sys/bus/pci/drivers/vfio-pci/unbind
    ```

3. 重新加载 NVIDIA 模块

    ```bash
    sudo modprobe nvidia
    sudo modprobe nvidia_drm
    sudo modprobe nvidia_modeset
    sudo modprobe nvidia_uvm
    ```
4. 重新检测，激活显卡

    ```bash
    echo "0000:01:00.0" | sudo tee /sys/bus/pci/drivers_probe
    echo "0000:01:00.1" | sudo tee /sys/bus/pci/drivers_probe
    ```

5. 释放内存大页

   - 2MB

        ```bash
        sysctl -w vm.nr_hugepages=0
        ```
        确认：

        ```bash
        cat /proc/sys/vm/nr_hugepages
        ```
   - 1GB

        ```bash
        echo 0 | sudo tee /sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages
        ```
        确认：
        ```bash
        cat /sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages
        ```

---

# 虚拟机

目录

- [VMware](虚拟机#vmware)
- [Winboat-安装最简单的win虚拟机](虚拟机#winboat)
- [VirtualBox](虚拟机#virtualbox)
- [Distrobox](虚拟机#distrobox)

---

## VMware

1. 安装缺少的依赖

   ```bash
   yay -S vmware-keymaps
   ```

2. 安装本体

   ```bash
   yay -S vmware-workstation
   ```

3. 开启服务

   ```bash
   sudo systemctl enable --now vmware-networks.service
   sudo systemctl enable --now vmware-usbarbitrator.service
   ```

4. 重启电脑

### 卸载 VMware

   ```bash
   sudo systemctl disable --now vmware-networks.service
   sudo systemctl disable --now vmware-usbarbitrator.service
   yay -Rns vmware-workstation vmware-keymaps
   ```

## Docker

1. 安装

   ```bash
   sudo pacman -S docker docker-compose
   ```

2. 开启服务

   ```bash
   sudo systemctl enable --now docker.service
   ```
3. 添加用户组

   ```bash
   sudo usermod -aG docker $USER
   ```

4. 重启电脑

### winboat

[winboat](https://github.com/TibixDev/winboat)

以 Docker 容器为基础的 Windows 虚拟机，RDP（远程桌面协议）连接，自动化配置 winapps，可以与 Linux 无缝集成，但 beta 版无缝集成的效果不是很好。只是用 Windows 虚拟机做轻量的活的话可以用这个，安装很简单，缺点是资源占用比 KVM/QEMU 虚拟机要高一些。

0. 安装并启用 Docker

1. 安装

   ```bash
   yay -S --needed freerdp winboat-bin
   ```

2. 开启 iptables 功能

   ```bash
   echo -e "ip_tables\niptable_nat" | sudo tee /etc/modules-load.d/iptables.conf
   ```

3. 重启电脑

   ```bash
   reboot
   ```

#### 卸载 winboat

1. 软件内关闭 Windows 后在 configuration 页面选择 reset winboat & remove vm。

2. 删除 winboat

   ```bash
   yay -Rns winboat-bin
   ```

3. 清理残留文件

   ```bash
   sudo rm -rfv /var/lib/docker /etc/docker ~/.docker /var/run/docker ~/.winboat ~/.config/winboat
   ```

4. 重启电脑

   ```bash
   reboot
   ```

## VirtualBox

<https://wiki.archlinux.org/title/VirtualBox>

```bash
sudo pacman -S virtualbox virtualbox-host-dkms
```

不同内核需要安装的包不一样，Linux 内核是 virtualbox-host-modules-arch，其他的看 wiki。

### 卸载 VirtualBox

```bash
sudo pacman -Rns virtualbox virtualbox-host-dkms
rm -rfv ~/.config/VirtualBox/ ~/VirtualBox\ VMs/
```

## distrobox

[distrobox.it](https://distrobox.it/)

我愿称其为"Linux Subsystem for Linux"。可以利用容器创建一个跟主机 Linux 深度集成、共享显卡的 Linux 子系统。比如你想用的软件只提供 DEB 包，那就可以创建一个 Debian 系发行版的盒子安装。比如我最近想用达芬奇剪视频，但是在 Arch 上安装达芬奇需要处理很多依赖和兼容问题，那我可以安装一个 Red Hat 系发行版的盒子专门装达芬奇。

distrobox 是一个在 Linux 上无缝运行其他 Linux 发行版的项目，使用 Podman、Docker 或者 lilipod 创建容器。有了这个项目就可以安装别的发行版的包了。建议使用 Podman，这个更轻量化更简洁。

```bash
sudo pacman -S distrobox podman
```

选项选 crun，Podman 和 crun 都是红帽主导开发的比 Docker 和 runc 更新更简洁的程序。

### 创建容器

Podman 兼容 Docker 镜像，可以去 Docker Hub 上搜索镜像对应的字符。

比如说我想装一个 Debian Stable：

```bash
distrobox create -n debian -i debian:stable
```

```bash
# distrobox create 创建容器
# -n 指定容器名
# -i 指定镜像
```

默认会共享主机的 home 目录，使用 --home（简写是 -H）给容器指定单独的目录存放 home 目录下的文件，避免搞乱本机的 home 目录。

```bash
distrobox create -n debian -i debian:stable --home ~/Distroboxhome/debian
```

加上 --nvidia 可以共享本机的 N 卡驱动：

```bash
distrobox create -n debian -i debian:stable --home ~/Distroboxhome/debian --nvidia
```

创建之后应用程序里会出现快捷方式，也可以在命令行用 distrobox enter 命令进入。第一次会安装各种基本包。

```bash
distrobox enter debian
```

创建容器时下载下来的镜像会存放在 `/home/shorin/.local/share/containers/storage` 目录下。

#### 常用的发行版

- Debian Stable

  ```bash
  distrobox create -n debian -i debian:stable --home ~/Distroboxhome/debian
  ```

- Arch Linux

  ```bash
  distrobox create -n arch -i archlinux:latest --home ~/Distroboxhome/arch
  ```

- Fedora

  ```bash
  distrobox create -n fedora -i fedora:latest --home ~/Distroboxhome/fedora
  ```

### 在主机创建容器内程序的快捷方式

用 distrobox-export --app 命令在主机 `~/.local/share/applications` 目录下创建对应程序的 .desktop 文件，比如我安装了星火应用商店：

```bash
distrobox-export --app spark-store
```

想删除的话加上 --delete：

```bash
distrobox-export --app spark-store --delete
```

删除容器的时候也会连着这个快捷方式一起删除。

### 删除容器

使用 distrobox rm 命令：

```bash
distrobox rm debian
```

然后手动删除 home 目录下的残留。

### GUI

安装 BoxBuddy：

- AUR

   ```bash
   yay -S boxbuddy
   ```

- flathub

   ```bash
   flatpak install flathub io.github.dvlv.boxbuddyrs
   ```

## PowerUser进阶用户

如果你需要更深入、性能更强大、功能更多的虚拟机，那就得利用 Linux 内核中的 KVM（Kernel-based Virtual Machine 基于内核的虚拟机）技术了。

## 下一节：[KVM虚拟机](KVM虚拟机)

---

# KVM虚拟机

目录

- [嵌套虚拟化](KVM虚拟机#嵌套虚拟化)
- [桥接网络](KVM虚拟机#配置桥接网络)
- [Win11 虚拟机](KVM虚拟机#安装-win11-虚拟机)
    - [文件共享](KVM虚拟机#文件分享)
- [远程桌面](KVM虚拟机#远程桌面)
    - [Parsec](KVM虚拟机#parsec)
    - [Sunshine+Moonlight](KVM虚拟机#sunshinemoonlight)
- [显卡直通](KVM虚拟机#显卡直通)
    - [Looking Glass](KVM虚拟机#looking-glass)

# KVM/QEMU 虚拟机

1. 安装 QEMU，图形界面，TPM，网络组件

   ```bash
   sudo pacman -S qemu-full virt-manager swtpm dnsmasq
   ```

2. 开启 libvirtd 系统服务

   ```bash
   sudo systemctl enable --now libvirtd
   ```

3. 开启 NAT default 网络

   ```bash
   sudo virsh net-start default
   sudo virsh net-autostart default
   ```

4. 添加组权限 需要登出

   ```bash
   sudo usermod -a -G libvirt $(whoami)
   ```

5. 启动 virt-manager 虚拟机管理程序

有一个注意点，virt-manager 默认的连接是系统范围的，如果需要用户范围的话需要左上角新增一个用户会话连接。

## 嵌套虚拟化

Intel 的话用 kvm_intel

- 临时生效

```bash
modprobe kvm_amd nested=1
```

- 永久生效

  1. 编辑配置文件

  ```bash
  sudo vim /etc/modprobe.d/kvm_amd.conf
  ```

  写入

  ```bash
  options kvm_amd nested=1
  ```

  2. 重新生成 initramfs

  ```bash
  sudo mkinitcpio -P
  ```

  3. 重启电脑

## 配置桥接网络

无线网卡无法配置桥接。

1. 启动高级网络配置工具（KDE 进设置里的 WiFi 和网络）

2. 运行：

   ```bash
   nm-connection-editor
   ```

3. 添加虚拟网桥，接口填 bridge0

4. 添加网桥连接，选择以太网，选择网络设备

5. 保存后将网络连接改为刚才创建的以太网网桥连接

## 安装 Win11 虚拟机

[手把手教你给笔记本重装系统（Windows篇）_哔哩哔哩_bilibili](https://www.bilibili.com/video/BV16h4y1B7md/?spm_id_from=333.337.search-card.all.click)

1. 任选一个网站下载镜像

   - [HelloWindows.cn - 精校 完整 极致 Windows系统下载仓储站](https://hellowindows.cn/)

   - [下载 Windows 11](https://www.microsoft.com/zh-cn/software-download/windows11)

   - 可选：Win11 IoT LTS 镜像

     ```text
     https://go.microsoft.com/fwlink/?linkid=2270353&clcid=0x409&culture=en-us&country=us
     ```

2. 下载 VirtIO 驱动镜像

   [Index of /groups/virt/virtio-win/direct-downloads/archive-virtio](https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/?C=M;O=A)

   点击 last modified，然后下载最新版本

3. [「Archlinux究极指南」从手动安装到显卡直通](https://www.bilibili.com/video/BV1L2gxzVEgs/?spm_id_from=333.1387.homepage.video_card.click&vd_source=65a8f230813d56660e48ae1afdfa4182)按照视频里 KVM 虚拟机的部分安装。或者参照这篇教程[winapps/docs/libvirt.md at main · winapps-org/winapps](https://github.com/winapps-org/winapps/blob/main/docs/libvirt.md)

### 跳过联网

确保机器**没有连接到网络**，按下 Shift+F10，鼠标点击选中弹出来的 CMD 窗口，运行：

```batch
oobe\bypassnro
```

### 文件分享

主要有 SMB 和 VirtIO-FS 两种，VirtIO-FS 的性能更好，但是因为是本机传输，所以 SMB 也不差。

- VirtIO-FS

   [如何在 Linux 主机和 KVM 中的 Windows 客户机之间共享文件夹 | Linux 中国 - 知乎](https://zhuanlan.zhihu.com/p/645234144)

   1. 确认开启共享内存
   2. 打开文件管理器，复制要共享的文件夹的路径
   3. 在虚拟机管理器内添加共享文件夹，粘贴刚才复制的路径，取个名字
   4. Win11 虚拟机内安装 WinFSP
      https://winfsp.dev/rel/
   5. 搜索 service（服务），启用 VirtIO-FS Service，设置为自动

- SMB

   1. 安装 Samba

      ```bash
      sudo pacman -S samba 
      ```
   2. 新建共享配置

      ```bash
      sudo vim /etc/samba/smb.conf
      ```
      ```ini
      [global]
      workgroup = WORKGROUP
      server string = MyArch
      security = user
      map to guest = bad user
      # 优化虚拟机访问性能
      socket options = TCP_NODELAY IPTOS_LOWDELAY SO_RCVBUF=131072 SO_SNDBUF=131072
      
      [Share]
      path = /你的/arch/共享文件夹路径
      valid users = 你的用户名
      read only = no
      browsable = yes
      ```
   3. 设置 SMB 密码

      `shorin` 替换为你的用户名
      ```bash
      sudo smbpasswd -a shorin
      ```

   4. 启用服务

      ```bash
      systemctl enable --now smb nmb
      ```
   
   5. 在虚拟机里确认虚拟机网关地址

      CMD 运行 `ipconfig` 命令，一般是 `192.168.122.1`

   6. 在虚拟机里连接 SMB

      打开 Win 的文档管理器，在地址栏输入 `\\192.168.122.1`，回车后会弹出密码框。

## 远程桌面

### Parsec

1. Win 虚拟机上浏览器搜索安装

2. Linux 上安装

   ```bash
   yay -S parsec-bin
   ```

3. 两个系统都开启，登录相同账号


### Sunshine+Moonlight

[GitHub - LizardByte/Sunshine: Self-hosted game stream host for Moonlight.](https://github.com/LizardByte/Sunshine)

1. 虚拟机 Win11 内安装 Sunshine

   https://github.com/LizardByte/Sunshine

   启动后右下角托盘右键 Sunshine 的图标打开 Web 网页，设置账号密码并登录。

2. 虚拟机内安装虚拟显示器

   https://github.com/VirtualDrivers/Virtual-Display-Driver

3. Linux 安装 Moonlight

   ```bash
   sudo pacman -S moonlight-qt
   ```

4. Linux 启动 Moonlight 后会搜索到 Win11 内的 Sunshine，点击连接会出现 PIN 码，在 Win11 的 Sunshine Web 页面设置 PIN 码添加设备就可以了。

## 显卡直通

分为冷切换和[热切换](#热切换)两种。需要有两个显卡。
>显卡直通完毕之后需要删除原本的 VirtIO、QXL 之类的显卡，然后配置任意远程桌面。

在开始配置之前，要确认开启 IOMMU（命令有输出说明开启）：

```bash
sudo dmesg | grep -e DMAR -e IOMMU
```

现代设备通常都支持 IOMMU 且默认开启，BIOS 里的选项通常为 `Intel VT-d`、`AMD-V` 或者 `IOMMU`。如果没有的话搜索一下自己的 CPU 和主板型号看看是否支持。


### 冷切换

[PCI passthrough via OVMF - ArchWiki](https://wiki.archlinux.org/title/PCI_passthrough_via_OVMF)


1. 获取显卡的硬件 ID，显卡所在 group 的所有设备的 ID 都记下

   ```bash
   for d in /sys/kernel/iommu_groups/*/devices/*; do 
       n=${d#*/iommu_groups/*}; n=${n%%/*}
       printf 'IOMMU Group %s ' "$n"
       lspci -nns "${d##*/}"
   done
   ```

2. 隔离 GPU

   ```bash
   sudo vim /etc/modprobe.d/vfio.conf
   ```

   写入

   ```bash
   options vfio-pci ids=10de:28e0,10de:22be （硬件ID与硬件ID之间用英文逗号隔开）
   ```

3. 编辑内核参数让 VFIO-PCI 抢先加载

   1. ```bash
      sudo vim /etc/mkinitcpio.conf
      ```

   2. `MODULES=（）` 里面写入 `vfio_pci vfio vfio_iommu_type1`

      ```bash
      MODULES=(... vfio_pci vfio vfio_iommu_type1  ...)
      ```

      `HOOKS=()` 里面确认有 `modconf`

      ```bash
      HOOKS=(... modconf ...)
      ```

4. 重新生成 initramfs

   ```bash
   sudo mkinitcpio -P
   ```

5. 安装和配置 OVMF

   ```bash
   sudo pacman -S --needed edk2-ovmf
   ```

   编辑配置文件

   ```bash
   sudo vim /etc/libvirt/qemu.conf
   ```

   搜索 nvram，在合适的地方写入：

   ```text
   nvram = [
   	"/usr/share/ovmf/x64/OVMF_CODE.fd:/usr/share/ovmf/x64/OVMF_VARS.fd"
   ]
   ```

6. 重启电脑

   记得把显示器插到核显输出的口上。

7. virt-manager 的虚拟机页面内添加设备

   PCI Host Device 里找到要直通的显卡（只直通显卡，不要直通类似 audio 的东西，可能会 43 报错，安装完驱动之后再直通 audio），然后 USB Host Device 里面把鼠标键盘也直通进去。

8. 开启 Win11 虚拟机，下载 NVIDIA App 安装驱动

9. 关闭虚拟机，虚拟机设置里显卡改成 None

#### 取消冷切换显卡直通

1. ```bash
   sudo vim /etc/modprobe.d/vfio.conf
   ```

   注释掉里面的东西

2. 重新生成 initramfs

   ```bash
   sudo mkinitcpio -P
   ```

3. ```bash
   reboot
   ```

### 热切换

热切换属进阶内容，看：[ShorinWiki_热切换显卡直通](热切换显卡直通)

## Looking Glass

> 参考：[Installation — Looking Glass B7 documentation](https://looking-glass.io/docs/B7/install/) | [PCI passthrough via OVMF - ArchWiki](https://wiki.archlinux.org/title/PCI_passthrough_via_OVMF)

Looking Glass 通过共享内存实现屏幕分享，专为显卡直通虚拟机设计。Win 虚拟机内需要安装虚拟显示器：[Virtual-Display-Driver](https://github.com/VirtualDrivers/Virtual-Display-Driver)

1. `groups` 命令确认自己在 KVM 组

   不在的话添加，注销才能生效

   ```bash
   sudo gpasswd -a $USER kvm 
   ```

2. 计算需要的内存大小
   
   ![](pictures/lookingglass.png)
   
   计算结果以2的n次幂向上取整。
   
3. 共享内存配置

   分 KVMFR 内核模块和标准共享内存两种方式。

   - 方法一：KVMFR（推荐）
   
     > 参考：[IVSHMEM with the KVMFR module ](https://looking-glass.io/docs/B7/ivshmem_kvmfr/)
   
     KVMFR 内核模块方式的 Looking Glass 性能更好，但是不能用 VirtIO-FS 进行文件共享，需要使用 SMB，这个取舍是值得的。
   
     1. 安装模块
   
        请确保已经安装了你使用的内核的头文件。
   
        ```bash
        yay -S --needed linux-headers looking-glass-module-dkms-git
        ```
   
     2. 加载模块并配置权限
   
        ```bash
        sudo vim /etc/modprobe.d/kvmfr.conf
        ```
   
        > 把此处的 `128` 改成你实际需要的大小
   
        ```text
        options kvmfr static_size_mb=128
        ```
   
        用 systemd 加载：
   
        ```bash
        sudo vim /etc/modules-load.d/kvmfr.conf
        ```
   
        ```text
        # KVMFR Looking Glass module
        kvmfr
        ```
   
        设置权限：
   
        ```bash
        sudo vim /etc/udev/rules.d/99-kvmfr.rules
        ```
   
        ```text
        SUBSYSTEM=="kvmfr", OWNER="shorin", GROUP="kvm", MODE="0660"
        ```
   
        > 记得把 `shorin` 改成你的用户名
   
        然后编辑 QEMU 的 cgroup 设备权限：
   
        ```bash
        sudo vim /etc/libvirt/qemu.conf
        ```

        搜索 `cgroup_device_acl`，取消注释后加上 `/dev/kvmfr0`，注意逗号。
   
        ```text
        cgroup_device_acl =[
            "/dev/null", "/dev/full", "/dev/zero",
            "/dev/random", "/dev/urandom",
            "/dev/ptmx", "/dev/kvm", "/dev/kqemu",
            "/dev/rtc","/dev/hpet", "/dev/vfio/vfio",
            "/dev/kvmfr0"
        ]
        ```
   
        - 可选：配置 AppArmor 权限
   
            如果你使用了 AppArmor 的话
            
            ```bash
            sudo vim /etc/apparmor.d/local/abstractions/libvirt-qemu
            ```
            
            ```text
            # Looking Glass
            /dev/kvmfr0 rw,
            ```
            
            
   
     3. 重启电脑
   
        重启后 `sudo dmesg | grep kvmfr` 应该能看到 `kvmfr: creating 1 static devices`。
   
        用 `ls -l /dev/kvmfr0` 应该可以看到文件权限是 `shorin kvm`
   
   - 方法二：shmem 标准共享内存（配置了 KVMFR 的跳过这一节）
   
     > 参考：[IVSHMEM with standard shared memory](https://looking-glass.io/docs/B7/ivshmem_shm/)
   
     如果你一定要用 VirtIO-FS，可以通过 shmem 配置 Looking Glass
   
     1. 设置共享内存设备对应的文件的规则
     
         ```bash
         sudo vim /etc/tmpfiles.d/10-looking-glass.conf
         ```
   
     	写入（`shorin` 改为自己的用户名）：
     
         ```text
         f /dev/shm/looking-glass 0660 shorin kvm -
         ```
   
         >`f` 代表文件规则
   
         >`/dev/shm/looking-glass` 是共享内存文件的路径
   
         >`0660` 设置所有者和所属组的读写权限
   
         >`shorin` 设置所有者
   
         >`kvm` 设置所属组
   
         >`-` 代表保留时间永久，不进行清理
     
     2. 无须重启，现在手动创建文件
     
        ```bash
        sudo systemd-tmpfiles --create /etc/tmpfiles.d/10-looking-glass.conf
        ```

4. 虚拟机配置

   打开 virt-manager，点击编辑 > 首选项，勾选启用 XML 编辑。现在要把刚刚创建的共享内存加进虚拟机，并配置鼠标键盘音频剪贴板同步什么的。

   1. 添加设备

      - 如果使用 KVMFR 的话

        XML 最顶部应该有一行 `<domain type='kvm'>` 加上 namespace

        ```xml
        <domain type='kvm' xmlns:qemu='http://libvirt.org/schemas/domain/qemu/1.0'>
        ```

        然后在最底部 `</domain>` 上面一行插入

        ```xml
        <qemu:commandline>
          <qemu:arg value="-device"/>
          <qemu:arg value="{'driver':'ivshmem-plain','id':'shmem0','memdev':'looking-glass'}"/>
          <qemu:arg value="-object"/>
          <qemu:arg value="{'qom-type':'memory-backend-file','id':'looking-glass','mem-path':'/dev/kvmfr0','size':134217728,'share':true}"/>
        </qemu:commandline>
        ```

        > 把 `'size':134217728` 的数值改成你实际的数值，计算方法是：`你之前计算出来的内存（MB）*1024*1024`。

      - 如果使用 shmem 的话

        找到 XML 底部的 `</devices>`，在 `</devices>` 的上面一行添加，size 记得改成自己需要的，就像这样：

        ```xml
        <devices>
            ...
          <shmem name='looking-glass'>
            <model type='ivshmem-plain'/>
            <size unit='M'>64</size> 
          </shmem>
        </devices>
        ```
       
   2. 设置 SPICE 协议
   
       确认有 SPICE 显示协议，显卡设置为 None
   
      1. 键鼠传输
   
         添加 VirtIO 键盘和 VirtIO 鼠标（要在 XML 里面更改 `bus="ps2"` 为 `bus="virtio"`）
   
      2. 剪贴板同步
   
         确认有信道 (SPICE)，没有的话添加，设备类型为 SPICE
   
      3. 声音传输
   
         确认有声卡 ich9，点击概况，去到 XML 底部，在里面找到下面这段，确认 `type` 为 `spice`
   
         ```xml
         <audio id='1' type='spice'/>
         ```
   
5. 安装 Looking Glass 服务端

   [Looking Glass - Download Looking Glass](https://looking-glass.io/downloads)

   浏览器搜索 Looking Glass，点击 Download，下载 Bleeding-Edge 的 Windows Host Binary，解压后双击 exe 安装

6. Linux 安装客户端

   服务端和客户端的版本要匹配，最容易出错的就是这个地方。Bleeding-Edge 对应 `-git` 包

   ```bash
   yay -S looking-glass-git
   ```

7. Linux 打开 Looking Glass 即可连接

8. 关闭虚拟机。克隆虚拟机之后使用克隆机而不是初号机，避免日后需要重新配置

#### 使用技巧

具体可以看这个页面：https://looking-glass.io/docs/B6-rc1/usage/

开启 Looking Glass 后使用 Scroll Lock 键有很多功能，包括最重要的键鼠捕获。长按会显示可用功能的列表。如果你的键盘没有 Scroll Lock 键，可以修改配置文件更改。

```bash
 vim ~/.config/looking-glass/client.ini
```

 写入： 

 ```ini
[input]
escapeKey=KEY_F9
 ```

把 F9 换成自己想要的键，可用的键可以在终端输入 looking-glass-client -m KEY 查看

我是用桌面环境的快捷键切换全屏和窗口的，你也可以选择设置以全屏模式开启，还是刚才那个配置文件，写入：

```ini
[win]
fullScreen = yes 
```

## KVM 虚拟机性能优化和伪装

优化后可以做到原生九成五的性能。

### 禁用 memballoon

[libvirt/QEMU Installation — Looking Glass B7 documentation](https://looking-glass.io/docs/B7/install_libvirt/#memballoon)

memballoon 的目的是提高内存的利用率，但是由于它会不停地"取走"和"归还"虚拟机内存，导致显卡直通时虚拟机内存性能极差。

将虚拟机 XML 里面的 memballoon 改为 none，这将显著提高 low 帧。

```xml
<memballoon model="none"/>
```

### 内存大页

[KVM - Arch Linux 中文维基](https://wiki.archlinuxcn.org/wiki/KVM#%E5%BC%80%E5%90%AF%E5%86%85%E5%AD%98%E5%A4%A7%E9%A1%B5)

可以大幅提高内存性能。用 Minecraft 实测帧数提升了 20%。注意，设置大页的那部分内存本机无法使用。

内存大页默认是 2MB，如果你内存够大的话可以试试 1GB 大页

#### 2MB

1. 计算大页大小

   内存（GB）* 1024 / 2 = 需要的大小

   比如 16GB 内存就是 16*1024/2=8192，wiki 建议略大一些，那就 8200。

   我通常给虚拟机分 24GB 内存，24*1024/2=12288，略大一些就是 12300。

2. 编辑虚拟机 XML

   在 virt-manager 的首选项里开启 XML 编辑，找到 `<memoryBacking>` 并添加 `<hugepages/>`

   ```xml
     <memoryBacking>
       <hugepages/>
     </memoryBacking>
   ```

3. 永久生效

   记得把数字改成自己需要的

   ```bash
   sudo vim /etc/sysctl.d/40-hugepage.conf
   ```

   ```text
   vm.nr_hugepages = 8800
   ```

4. reboot

5. 虚拟机开启后查看大页使用情况

   ```bash
   grep HugePages /proc/meminfo
   ```

- 取消大页

   ```bash
   sudo rm /etc/sysctl.d/40-hugepage.conf
   ```

   ```bash
   reboot
   ```

#### 1GB

1. 编辑启动参数

   ```bash
   sudo vim /etc/default/grub
   ```
   在内核参数（就是 `loglevel=5` 的地方）写：

   ```text
   default_hugepagesz=1G hugepagesz=1G hugepages=16
   ```
   此处的 16 是你实际要使用的大页数量

   编辑 `/etc/default/grub` 后记得更新 `grub.cfg`

   ```bash
   sudo grub-mkconfig -o /boot/grub/grub.cfg
   ```
2. 编辑虚拟机 XML

   ```xml
   <memoryBacking>
      <hugepages>
         <page size='1048576' unit='KiB'/>
      </hugepages>
   </memoryBacking>
   ```

这样就可以了。

- 查看大页使用情况：

   ```bash
   # 查看成功分配到了多少个 1GB 大页
   cat /sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages
   
   # 查看有多少个正在被虚拟机使用
   cat /sys/kernel/mm/hugepages/hugepages-1048576kB/resv_hugepages
   ```

### CPU Pinning

>这部分可能有些复杂，不明白的话可以装个本地的 agent，比如 opencode，让 AI 帮你配置。

[PCI passthrough via OVMF - ArchWiki](https://wiki.archlinux.org/title/PCI_passthrough_via_OVMF#CPU_pinning)

主要目的是提升 CPU 缓存性能。避免虚拟机 CPU 线程对应的物理 CPU 线程变化导致缓存性能下降。

通常在 virt-manager 里手动设置 CPU 拓扑为 1 插槽，核心数和线程数跟自己的 CPU 对应就够用了，如果要极致的优化继续往下看。

1. 查看物理 CPU 拓扑

   ```bash
   lscpu -e
   ```

   主要看 3 项，CPU 是线程，CORE 是物理核心，L1d:L1i:L2:L3 是缓存。如果开启了超线程，会出现一个 CORE 对应两个 CPU 的情况。究竟该 pin 哪些 CPU 需要看缓存。

   看一个例子：

   ```text
     CPU    NODE     SOCKET    CORE L1d:L1i:L2:L3 ONLINE    MAXMHZ   MINMHZ       MHZ
     0    0      0    0 0:0:0:0           是 5263.0610 402.7860 4687.7769
     1    0      0    1 1:1:1:0           是 5263.0610 402.7860 4687.6860
     2    0      0    2 2:2:2:0           是 5263.0610 402.7860 4688.5659
     3    0      0    3 3:3:3:0           是 5263.0610 402.7860 4688.6870
     4    0      0    4 4:4:4:0           是 5263.0610 402.7860 4688.7310
     5    0      0    5 5:5:5:0           是 5263.0610 402.7860 4689.5552
     6    0      0    6 6:6:6:0           是 5263.0610 402.7860 4689.2202
     7    0      0    7 7:7:7:0           是 5263.0610 402.7860 4689.5889
     8    0      0    0 0:0:0:0           是 5263.0610 402.7860 4688.2788
     9    0      0    1 1:1:1:0           是 5263.0610 402.7860 2361.5911
     10    0      0    2 2:2:2:0           是 5263.0610 402.7860 4688.4370
     11    0      0    3 3:3:3:0           是 5263.0610 402.7860 4688.4502
     12    0      0    4 4:4:4:0           是 5263.0610 402.7860 4688.4072
     13    0      0    5 5:5:5:0           是 5263.0610 402.7860 4688.2578
     14    0      0    6 6:6:6:0           是 5263.0610 402.7860 4688.2778
     15    0      0    7 7:7:7:0           是 5263.0610 402.7860 4688.3350
   ```

   这个例子里所有核心共享 L3 缓存，所以无法优化 L3 缓存性能。但是可以优化 L1 和 L2。比如 CORE0 对应 CPU0 和 CPU8，CPU0 和 CPU8 共享同一个 L1/L2 缓存，如果仅 pin CPU0 就会导致运行到 CPU8 的缓存里，导致缓存性能下降，所以必须同时 pin CPU0 和 CPU8

2. 修改 XML，在 `<vcpu placement="static">16</vcpu>` 下方插入

   ```xml
     <iothreads>2</iothreads>
     <cputune>
       <vcpupin vcpu="0" cpuset="2"/>
       <vcpupin vcpu="1" cpuset="10"/>
       <vcpupin vcpu="2" cpuset="3"/>
       <vcpupin vcpu="3" cpuset="11"/>
       <vcpupin vcpu="4" cpuset="4"/>
       <vcpupin vcpu="5" cpuset="12"/>
       <vcpupin vcpu="6" cpuset="5"/>
       <vcpupin vcpu="7" cpuset="13"/>
       <vcpupin vcpu="8" cpuset="6"/>
       <vcpupin vcpu="9" cpuset="14"/>
       <vcpupin vcpu="10" cpuset="7"/>
       <vcpupin vcpu="11" cpuset="15"/>
       <emulatorpin cpuset="0,8,1,9"/>
       <iothreadpin iothread="1" cpuset="0,8,1,9"/>
       <iothreadpin iothread="2" cpuset="0,8,1,9"/>
     </cputune>
   ```

     `<iothreads>2</iothreads>` 设置 IO 线程

   `<vcpupin vcpu="0" cpuset="2"/>` 虚拟机有几个线程就写几行 vcpu，0 算第一个。cpuset 指定 vcpu 对应的主机 CPU 线程，也就是 `lscpu -e` 输出结果里的 CPU 那一列。比如举例的这段的意思是 vcpu0 对应本机的 CPU2

   `<emulatorpin cpuset="0,1,8,9"/>` 这一段设置专门用来处理虚拟机相关工作的 CPU。

   `<iothreadpin iothread="1" cpuset="0,1,8,9"/>` 指定专门用来做 IO 相关工作的 CPU。    

3. 禁用大部分 timer，以减少虚拟机空闲时的 CPU 占用

   ```xml
   <clock offset='localtime'>
     <timer name='rtc' present='no' tickpolicy='catchup'/>
     <timer name='pit' present='no' tickpolicy='delay'/>
     <timer name='hpet' present='no'/>
     <timer name='kvmclock' present='no'/>
     <timer name='hypervclock' present='yes'/>
   </clock>
   ```

4. 启用 Hyper-V Enlightenments

   ```xml
   <hyperv>
   <relaxed state='on'/>
   <vapic state='on'/>
   <spinlocks state='on' retries='8191'/>
   <vpindex state='on'/>
   <synic state='on'/>
   <stimer state='on'>
   <direct state='on'/>
   </stimer>
   <reset state='on'/>
   <frequencies state='on'/>
   <reenlightenment state='on'/>
   <tlbflush state='on'/>
   <ipi state='on'/>
   </hyperv> 
   ```

   让 KVM "伪装"成 Hyper-V，以"欺骗" Windows 开启高性能模式，大幅提升 Windows 虚拟机的运行性能、降低 CPU 消耗，并改善其稳定性

### 伪装虚拟机

这部分内容也许过时了。

[How to play PUBG (with BattleEye) on a Windows VM : r/VFIO](https://www.reddit.com/r/VFIO/comments/18p8hkf/how_to_play_pubg_with_battleeye_on_a_windows_vm/)

为了避免被反作弊程序检测到虚拟机，需要修改 XML 伪装虚拟机。

#### ⚠️警告：进入虚拟机的反作弊之间的猫鼠游戏意味着你做好了被封号的觉悟 

#### ⚠️警告：每进行一步都要确认虚拟机能正常运行再进行下一步

1. 可选：使用 SATA 硬盘和 e1000 网卡

2. 在 `</hyperv>` 下面一行插入：

   ```xml
   <kvm>
   <hidden state="on"/>
   </kvm> 
   ```

3. 在 `<os firmware="efi">` 上面一行插入，这是伪装 BIOS。然后复制 XML 顶部的 UUID，替换下面这段里的【这里要粘贴自己虚拟机的 UUID】。里面的 name 信息可以按需修改。

   ```xml
   <sysinfo type="smbios">
   <bios>
   <entry name="vendor">American Megatrends International, LLC.</entry>
   <entry name="version">F21</entry>
   <entry name="date">10/01/2024</entry>
   </bios>
   <system>
   <entry name="manufacturer">Gigabyte Technology Co., Ltd.</entry>
   <entry name="product">X670E AORUS MASTER</entry>
   <entry name="version">1.0</entry>
   <entry name="serial">12345678</entry>
   <entry name="uuid">【这里要粘贴自己虚拟机的uuid】</entry>
   <entry name="sku">GBX670EAM</entry>
   <entry name="family">X670E MB</entry>
   </system>
   </sysinfo> 
   ```

4. 禁用 migratable

   ```xml
   <cpu mode="host-passthrough" check="none" migratable="off">  
   ```

 migratable 是为服务器集群准备的"搬家"功能，关闭。

5. 在 `<topology sockets="1" dies="1" clusters="1" cores="8" threads="2"/>` 下面一行插入（**这里仅适用于 AMD 处理器，由于我没有 Intel 处理器所以没法测试适用于 Intel 的配置，可以问一问 AI**）

   禁用 CPU 的 AES 指令集可以规避绝大多数反作弊检测

   ```xml
      <cache mode="passthrough"/>
      <feature policy="require" name="hypervisor"/> 
      <feature policy="disable" name="aes"/>
   ```

6. 时钟，找到 clock offset 那段修改，时区可以按需修改，不改也没事。

   ```xml
   <clock offset="timezone" timezone="Asia/Japan">
      <timer name="rtc" present="no" tickpolicy="catchup"/>
      <timer name="pit" tickpolicy="discard"/>
      <timer name="hpet" present="no"/>
      <timer name="kvmclock" present="no"/>
      <timer name="hypervclock" present="yes"/>
      <timer name="tsc" present="yes" mode="native"/>
   </clock>
   ```

## 下一节：[玩游戏](玩游戏)

---

---

# 玩游戏

目录

- [小黄鸭补帧](玩游戏#小黄鸭补帧)
- [Steam](玩游戏#steam)
- [Minecraft](玩游戏#minecraft)
- [Lutris-wine兼容层运行游戏](玩游戏#wine兼容层运行)
- [Waydroid-安卓手游](玩游戏#安卓手游)
- [显卡直通虚拟机玩游戏](玩游戏#用显卡直通玩游戏)

---

这里有这部分内容的视频教程：[「Linux游戏指南」关于Linux玩游戏的一切](https://www.bilibili.com/video/BV1zyttzPEmp/?share_source=copy_web&vd_source=1c6a132d86487c8c4a29c7ff5cd8ac50)

## 如何确认一款游戏能不能玩

想确认一款游戏能不能在 Linux 上玩，可以参考以下网站的信息：

- [ProtonDB Steam游戏兼容数据库](https://www.protondb.com/)
- [Can I Play on Linux 我能在Linux上玩吗？](https://caniplayonlinux.com/)
- [Are We Anti-Cheat Yet？我们过反作弊了吗？](https://areweanticheatyet.com/)

## Steam

[Proton (软件) - 维基百科，自由的百科全书](https://zh.wikipedia.org/wiki/Proton_(%E8%BB%9F%E9%AB%94))

[Steam - ArchWiki](https://wiki.archlinux.org/title/Steam)

1. 安装 steam

    ```bash
    sudo pacman -S steam
    ```

2. 禁用 btrfs 写时复制

    禁用游戏存放目录的 btrfs 的写时复制（CoW），否则会下载速度异常。默认目录是 `~/.local/share/Steam/`，通常禁用 `steamapps` 目录的 CoW 就行了。

    ```bash
    sudo chattr +C ~/.local/share/Steam/steamapps
    ```

- 卸载 steam

  ```bash
  sudo pacman -R steam
  sudo rm -rfv ~/.steam ~/.local/share/Steam
  ```

## Minecraft

从 AUR 安装启动器，推荐使用 xmcl、Prism Launcher、hmcl。

## Wine兼容层运行

Wine 是在 Linux 下运行 Windows 程序的兼容层，Proton 是 Steam 的母公司 V 社基于 Wine 开发的专门用来玩游戏的兼容层。原理是把 Windows 程序发出的请求翻译成 Linux 系统下的等效请求。通常使用最新的 Wine 或者 Proton 版本即可，或者使用 [GE-proton](https://github.com/GloriousEggroll/proton-ge-custom)，这是 GE 大佬修改的 Proton。另外还有基于 [proton-cachyos](https://github.com/CachyOS/proton-cachyos) 制作，专门为二游进行优化的 [DW-Proton](https://dawn.wine/dawn-winery/dwproton)。

Wine、Proton 这些兼容层有一大特点叫 prefix，相当于一个虚拟的 C 盘环境，程序的所有操作都在这个 prefix 中进行，完全不会影响到主机的 Linux。当你想卸载软件的时候，可以直接把这个 prefix 扬了，相当于用删除 C 盘的方式卸载软件，相当干净。为了更好地利用 prefix 的优势，可以选择给每个应用单独创建一个 prefix，但用命令行创建会相当繁琐，于是就有了专门用来管理 prefix 的工具。

### Lutris

[Download Lutris](https://lutris.net/downloads)

Lutris 是一个专为玩游戏设计的管理工具，可以完全取代 Steam 的"添加非 Steam 游戏"功能。当然也可以用来管理普通软件。

1. 安装

    ```bash
    sudo pacman -S lutris
    ```

    第一次打开会自动下载各种需要的组件，点击左上角的加号可以看到主要功能。
2. 下载 ge-proton

    右上角三道杠进入 `首选项`，进入 `update` 页面，点击 `下载 xxxxx`（大概是这个名字），此时下载最新版本的 ge-proton。

3. 设置 Wine 默认使用 GE-Proton

    主页面，单击左下角 Wine 右边的齿轮。设置 Wine 默认使用 ge-proton。

- 卸载 lutris

  ```bash
  sudo pacman -Rns lutris
  ```

  ```bash
  sudo rm -rfv ~/.config/lutris  ~/.local/share/lutris
  ```

#### 可选：ProtonPlus

```bash
yay -S protonplus
```

这是一个专门管理不同版本的 Proton 的软件。

#### 可选：类似微星小飞机的帧数、资源监控软件

  ```bash
  yay -S gamescope mangohud mangojuice
  ```

gamescope 是一个专门用来玩游戏的合成器。mangohud 是类似微星小飞机的监控软件，mangojuice 用来配置 mangohud。

- mangohud 使用方法

  mangojuice 设置要显示的项目，然后在 lutris 右键想要监控的软件 > 系统选项 > Display > 激活显示帧率（MangoHud）。Steam 的话设置启动参数 `mangohud %command%`。

### 如果要玩Epic的游戏

```bash
yay -S heroic-games-launcher
```

## 用显卡直通玩游戏

经过前面显卡直通的操作，我已经有了一台 4060 显卡的 Win11，并且配置了 looking glass，理论上所有 Win11 能干的事情我都能在这台虚拟机上干。具体的就不用再往下说了吧🤓☝️

## 小黄鸭补帧

<https://github.com/PancakeTAS/lsfg-vk>

视频教程：[90s 学会在 Linux 用小黄鸭补帧](https://www.bilibili.com/video/BV1zrXzBGEAi/?share_source=copy_web&vd_source=1c6a132d86487c8c4a29c7ff5cd8ac50)

需要先下载 Steam 正版的小黄鸭。也许盗版也可以，有兴趣的可以自己试试，手动指定一下 lossless.dll 的路径说不定能运行。

- 从 yay 安装 lsfg-vk

```bash
yay -S lsfg-vk-bin
```

### 使用方法

具体的使用方法可以去看官方文档 [Home · PancakeTAS/lsfg-vk Wiki](https://github.com/PancakeTAS/lsfg-vk/wiki)。

我只演示一个方法。

打开 `lsfg-vk-ui`，新建一个 profile，任意取一个名字（profile name）。常见用途有两个，看视频和玩游戏。

1. 看视频

   mpv 的兼容性最好。打开终端，使用 `LSFG_PROCESS` 变量指定 profile。比如：

   ```bash
   LSFG_PROCESS="miyu" mpv /home/shorin/Videos/test.mkv
   ```

2. 玩游戏

   Steam 右键想要运行的游戏，启动参数填入刚刚的变量 `LSFG_PROCESS="miyu"`，比如：

   ```bash
   LSFG_PROCESS="miyu" %command%
   ```

3. 其他

   同理，lutris 之类的也可以像 Steam 那样设置启动参数。可以在终端输入 `LSFG_PROCESS="miyu" 程序启动命令` 尝试对任意程序开启补帧，但是不一定生效。

lsfg 一旦生效，就可以修改 profile，实时更改补帧倍率。

## 安卓手游

### Waydroid

[Install Instructions | Waydroid](https://docs.waydro.id/usage/install-on-desktops)

[Waydroid - Arch Linux 中文维基](https://wiki.archlinuxcn.org/wiki/Waydroid)

安卓系统也是 Linux 内核，那 Linux 发行版自然也能运行安卓，并且性能还是接近原生的。Waydroid 是 Linux 上的安卓容器，相当于一个完整的安卓系统。

1. 安装

    ```bash
    yay -S waydroid
    ```

    可选：从 archlinuxcn 安装 waydroid-image（要求添加 CN 仓库，按照流程，在本文档的 yay 安装部分已经添加）。

    ```bash
    sudo pacman -S waydroid-image
    ```

2. 初始化

    ```bash
    sudo waydroid init
    ```

3. 启动服务

    ```bash
    sudo systemctl enable --now waydroid-container
    ```

4. 安装 ARM 转译

    [GitHub - casualsnek/waydroid_script: Python Script to add OpenGapps, Magisk, libhoudini translation library and libndk translation library to waydroid !](https://github.com/casualsnek/waydroid_script)

    我们的 CPU 架构是 x86_64，要运行 ARM 应用需要安装 ARM 转译，AMD 装 libndk，Intel 装 libhoudini。

    ```bash
    git clone https://github.com/casualsnek/waydroid_script
    cd waydroid_script
    python3 -m venv venv
    venv/bin/pip install -r requirements.txt
    sudo venv/bin/python3 main.py
    ```

    按照窗口的指引进行安装。

5. 开启会话

    ```bash
    waydroid session start
    ```

   然后应该就能在桌面看到一大堆图标了。

6. 可选：软件默认是全屏打开，可以设置窗口化打开软件，F11 切换全屏和窗口化。

    ```bash
    waydroid prop set persist.waydroid.multi_windows true
    ```

    然后用命令重启会话，这一步会隐藏桌面的 Waydroid 图标，可以设置显示。如果开启不了的话可以 stop 之后再尝试用桌面快捷方式开启。

    ```bash
    waydroid session stop
    waydroid session start
    ```

- 安装软件

  ```bash
  waydroid app install /apk/的/路径
  ```

#### 安装谷歌框架

依旧是使用这个脚本安装 gapps [casualsnek/waydroid_script: Python Script to add OpenGapps, Magisk, libhoudini translation library and libndk translation library to waydroid !](https://github.com/casualsnek/waydroid_script)，安装完成后用以下命令获取设备 ID。

[Google Play Certification | Waydroid](https://docs.waydro.id/faq/google-play-certification)

```bash
sudo waydroid shell -- sh -c "sqlite3 /data/data/*/*/gservices.db 'select * from main where name = \"android_id\";'"
```

复制 ID 之后去这个网站注册设备：

<https://www.google.com/android/uncertified>

然后重启会话：

```bash
waydroid session stop
```

#### 软件渲染

N 卡用户用不了 Waydroid，可以用软件渲染，但是性能很差，勉强玩 2D 游戏。

1. 编辑配置文件

    ```bash
    sudo vim /var/lib/waydroid/waydroid.cfg
    ```

    ```ini
    [properties]
    ro.hardware.gralloc=default
    ro.hardware.egl=swiftshader
    ```

2. 本地更新应用一下更改后的配置

    ```bash
    sudo waydroid upgrade --offline
    ```

3. 重启服务

    ```bash
    systemctl restart waydroid-container
    ```

#### 卸载Waydroid

```bash
waydroid session stop
```

```bash
sudo systemctl disable --now waydroid-container.service
```

```bash
yay -Rns waydroid
```

如果下载了 waydroid-image 的话需要用 yay 一并卸载。

卸载完后清理残留文件：

```bash
sudo rm -rf /var/lib/waydroid ~/.local/share/waydroid ~/.local/share/applications/waydroid*
```

## 下一节：[性能优化](性能优化)

---

# 性能优化

目录

- [N卡动态功耗调节](性能优化#n卡动态功耗调节)
- [显卡超频和定频降压](性能优化#lact进行显卡offset)
- [preload-提高应用启动速度](性能优化#preload)
- [替换zen内核](性能优化#安装zen内核)

---

## N卡动态功耗调节

```bash
sudo systemctl enable --now nvidia-powerd.service
```

## LACT进行显卡offset

使用软件商城安装的 lact 即可。

## 交换空间和zram

参考资料：

[Zram vs zswap vs swap? : r/archlinux](https://www.reddit.com/r/archlinux/comments/1ivwv1l/zram_vs_zswap_vs_swap/)

[Zswap vs zram in 2023, what's the actual practical difference? : r/linux](https://www.reddit.com/r/linux/comments/11dkhz7/zswap_vs_zram_in_2023)

[linux - ZRAM vs ZSWAP for lower end hardware? - Super User](https://superuser.com/questions/1727160/zram-vs-zswap-for-lower-end-hardware)

简单来说，硬盘 swap 交换空间会频繁的读写硬盘，导致硬盘寿命下降。故使用内存作为交换空间。有两种方法，zswap 和 zram。

zswap 依托于 swap 运行，是硬盘 swap 的缓存，还是会有硬盘读写，虽然可以关闭 zswap 的写回，但 zram 更加优雅、简洁。

zram 是把内存的一部分动态地作为 swap 交换空间，和硬盘 swap 一样都是 swap 设备。zram 占满前完全不会有硬盘 swap 的读写。

### 不需要睡眠的话删除硬盘swap后开启zram

1. 关闭 swap

    ```bash
    sudo swapoff /swap/swapfile
    ```

2. 删除 swap 文件

    ```bash
    sudo rm /swap/swapfile
    ```

3. 编辑 fstab

    ```bash
    sudo vim /etc/fstab
    ```

注释掉 swap 相关的内容。

### zram内存压缩

1. 安装 zram-generator

    ```bash
    sudo pacman -S zram-generator
    ```

2. 编辑配置文件

    ```bash
    sudo vim  /etc/systemd/zram-generator.conf
    ```

    ```ini
    [zram0]
    zram-size = ram
    compression-algorithm = zstd
    ```

    `zram-size` 设置最多存储多少数据，注意这里设置的是压缩之前的大小。

    `compression-algorithm` 这一行设置使用 zstd 算法。

3. 禁用 zswap

    ```bash
    sudo vim /etc/default/grub
    ```

    ```text
    # 在 GRUB_CMDLINE_LINUX_DEFAULT="" 里写入 zswap.enabled=0

    GRUB_CMDLINE_LINUX_DEFAULT="... zswap.enabled=0 ... "
    ```

4. 重新生成 GRUB 的配置文件

    ```bash
    sudo grub-mkconfig -o /efi/grub/grub.cfg
    ```

5. reboot

6. 验证 zswap 是否关闭

    ```bash
    sudo grep -R . /sys/kernel/debug/zswap/
    ```

7. 验证 zram 是否开启

    ```bash
    sudo zramctl
    或者
    swapon
    ```

## 安装zen内核

ps：会导致功耗略微增加。

1. 安装内核和头文件

    ```bash
    sudo pacman -S linux-zen linux-zen-headers
    ```

2. 可选：安装 DKMS 显卡驱动

    如果你是 N 卡且之前安装的是 nvidia-open 而不是 -dkms 后缀的驱动包的话需要换成 -dkms 后缀的驱动包。

    ```bash
    sudo pacman -S nvidia-open-dkms
    ```

3. 重新生成 GRUB

    ```bash
    sudo grub-mkconfig -o /boot/grub/grub.cfg
    ```

4. 重启

    ```bash
    reboot
    ```

    第一次启动时可能要在 GRUB 的 Arch advance 启动项里选择 zen 内核的启动项。

## 下一节：[小技巧](小技巧)

---

---

# 小技巧

## 小技巧

- Super+左键按住窗口的任意位置移动窗口。

- GNOME 桌面，Super+中键可以调整窗口大小，Ctrl+C 复制文件后 Ctrl+M 可以粘贴一个链接，Super+滚轮切换工作区。

- KDE 桌面，Super+右键可以调整窗口大小，Ctrl+Super+滚轮可以缩放，Super+Alt+滚轮切换工作区。

- time 命令可以计算一个程序启动的时间。

  示例：

  ```bash
  time firefox
  ```

- 默认右键是没有新建文件选项的，要在 ~/Templates 目录里面创建自己想要的模板之后才能右击新建文件。

---

## 更高效地使用终端

我也是初学者，如果有什么建议欢迎提出。

### 终端文本阅读器

我最近在看《Linux/Unix 大学教程》，在里面知道了 less 工具，顺便一提这本书对新手太友好了，强烈推荐，可以当小说看。主要用途是在终端文本阅读器，注意不是编辑器是阅读器。终端运行命令通常会一次性输出所有内容，阅读起来相当麻烦，这个时候就可以用管道符把输出给到 less 进行阅读。

less 每次只显示一页内容，空格下一页，b 键上一页，q 键退出，左斜杠键搜索，g 键跳转第一行，Shift+G 跳转最后一行，-N 显示行号，-S 禁止换行，更深入的使用可以自行搜索。

```bash
sudo pacman -S less
```

#### 使用方法

- 打开一个文件

  ```bash
  less /path/to/file
  ```

- 阅读终端输出

  比如运行一个输出很长很长的命令，然后用 less 阅读输出结果：

  ```bash
  find /usr | less
  ```

### 切换目录

`cd /目标/目录/位置` 可以切换目录。

`cd ~` 或者 `cd` 可以快速回家。

`cd -` 可以回到上一次切换到的目录。

`cd ..` 可以返回上级目录。

但是这每次都要输入完整的路径，虽然有 Tab 自动补全，但依旧麻烦，于是就有了 zoxide。

#### zoxide

[zoxide](https://github.com/ajeetdsouza/zoxide)

```bash
sudo pacman -S zoxide
```

- Fish

  ```bash
  echo 'zoxide init fish --cmd cd | source' >> ~/.config/fish/config.fish
  ```

  echo 命令将后面的内容打印到终端，'' 单引号是字符串，>> 双大于号代表把输出内容追加到右边的文件的末尾，config.fish 是 Fish 的配置文件。这样可以在 Fish 激活 zoxide，并通过 --cmd cd 选项把默认的 z 命令改成 cd。

- Zsh

  ```bash
  echo 'eval "$(zoxide init zsh --cmd cd)"' >> ~/.zshrc
  ```

 使用方法和 cd 相同，需要使用一段时间训练它。

```bash
zoxide query -l -s
```

这条命令可以显示当前记录的目录和对应的频率。`zoxide edit` 可以手动修改数据库中的目录频率或者删除。`zoxide remove /path/to/path` 可以删除数据中的某个目录。

原本如果我想切换到一个很深的目录需要 `~/Documents/gitrepo/Archlinux-GNOME-KDE-InstallationGuide-ShorinArchExperience/dotfiles/` cd 后面跟上这么长。但是现在我只需要输入完整的路径切换过一次之后，`cd dotfiles` 就能切换到刚刚那个目录。如果我有两个包含 dotfiles 的目录，那我只需要加上一个中间结点就可以了，比如 `cd arch dotfiles`。

##### fzf

fuzzy finder，这个工具可以使用 `fzf` 命令对当前目录下所有文件当中进行模糊搜索。

```bash
sudo pacman -S fzf
```

配合 zoxide 使用，可以用 `cdi` 命令在 zoxide 记录的目录进行模糊搜索。Ctrl+P 向上滚动，Ctrl+N 向下滚动。也可以 `cd 目录名` 然后按 Tab，开启一个模糊搜索的面板。

### 终端文档管理器

#### yazi

[Install Yazi](https://yazi-rs.github.io/docs/installation)

```bash
sudo pacman -S --needed yazi ffmpeg 7zip jq poppler fd ripgrep fzf zoxide resvg imagemagick
```

使用方法：[Quick Start](https://yazi-rs.github.io/docs/quick-start)

## vim配置

```text
~/.vimrc
```
```vim
"显示行号
set number
"语法高亮
syntax on
"显示相对行号
set relativenumber
"高亮当前行
set cursorline
```

## 下一节：[干净删除Linux](干净删除Linux)

---

# 干净删除Linux


- 和 Windows 共用 EFI 分区时

  [(重制)彻底删除Linux卸载后的无用引导项_哔哩哔哩_bilibili](https://www.bilibili.com/video/BV14p4y1n7rJ/?spm_id_from=333.1387.favlist.content.click)

  1. Win+X 选择磁盘管理，找到 EFI 在磁盘几的第几个分区，通常是磁盘 0 的第一个分区。

  2. Win+R 输入 `diskpart` 回车

    ```bash
    select disk 0       # 选择 EFI 分区所在磁盘
    select partition 1  # 选择 EFI 分区
    assign letter p     # 分配一个盘符
    ```

  3. 管理员运行记事本。

  4. Ctrl+S 打开保存窗口。

  5. 选择 P 盘，删除里面的 Linux 启动相关文件（通常有一个和 Linux 启动项名称相同的文件夹）。

  6. diskpart 里移除盘符

    ```bash
    remove letter p
    ```

- 单独 EFI 分区时

  [windows10删除EFI分区(绝对安全)-CSDN博客](https://blog.csdn.net/sinat_29957455/article/details/88726797)

  - 方法一：[图吧工具箱官方网站 - DIY爱好者的必备工具合集](https://www.tbtool.cn/)

    下载图吧工具箱，在磁盘工具里双击打开 DiskGenius，右键 Linux 对应分区删除，然后左上角保存。

  - 方法二：Windows 自带工具

    1. 使用 diskpart 选中 Linux 的 EFI 分区后在终端运行：

    ```bash
    SET ID=ebd0a0a2-b9e5-4433-87c0-68b6b72699c7
    ```

    2. 使用磁盘管理右键分区删除。

- 删除 NVRAM 入口

  使用 BOOTICE 这个软件的 UEFI 功能。在 UEFI 启动序列中删除你要删除的系统启动项。

## 最后：[issues](issues)和[附录](附录)
---

---

# issues

这里是我遇到的问题以及对应的解决方案。

- [efibootmgr里面有超级多启动项](#efibootmgr里面有超级多启动项)
- [KDE开机会卡住，必须重启sddm才好](#kde开机会卡住必须重启sddm才好)
- [磁盘占用异常](#磁盘占用异常)
- [提示没有编解码器](#提示没有编解码器)
- [Nautilus无法访问SMB共享](#nautilus无法访问smb共享)
- [域名解析出现暂时性错误](#域名解析出现暂时性错误)
- [扩展Windows的EFI分区空间](#扩展windows的efi分区空间)
- [grub卡顿](#grub卡顿)
- [virsh不显示虚拟机加上sudo后显示](#virsh不显示虚拟机加上sudo后显示)
- [GNOME混合模式独显占用异常](#gnome混合模式独显占用异常)
- [fuzzel无法打开终端程序](#fuzzel无法打开终端程序)
- [thunar的压缩解压缩软件不生效](#thunar-的压缩解压缩软件不生效)
- [Nautilus等GTK4应用启动慢](#nautilus等gtk4应用启动慢)
- [gnome的设置中心无法在窗口管理器打开](#gnome的设置中心无法在窗口管理器打开)
- [软件缩放问题](#软件缩放问题)
- [btrfs-assistant没有同步matugen主题](#btrfs-assistant没有同步matugen主题)
- [GTK4软件无法即时切换主题](#gtk4软件无法即时切换主题)
- [QQ用Wayland运行时剪贴板异常](#qq用wayland运行时剪贴板异常)
- [quickshell图标缺失](#quickshell图标缺失)
- [NetworkManager切换到IWD后端后使用impala联网提示operation aborted](#networkmanager切换到iwd后端后使用impala联网提示operation-aborted)
- [OBS导致显卡占用飙升进而导致游戏帧数大幅下降](#obs导致显卡占用飙升进而导致游戏帧数大幅下降)
- [天选4锐龙版2023使用Niri关闭屏幕后会自己亮屏](#天选4锐龙版2023使用niri关闭屏幕后会自己亮屏)

## efibootmgr里面有超级多启动项

这是之前其他系统和网络设备的残留的 NVRAM。用 efibootmgr 清理。

用这条命令列出所有的启动项：

```bash
sudo efibootmgr -v
```

找到无用的项目对应的编号删除：

```bash
sudo efibootmgr -b 0001 -B
```

此处的 0001 是编号。

## KDE开机会卡住，必须重启sddm才好

显卡驱动没加载完 SDDM 就加载导致的卡死。让 SDDM 晚点加载就可以解决。

```bash
sudo systemctl edit sddm.service
```

```ini
[Service]
ExecStartPre=/bin/sleep 2
```

```bash
sudo systemctl daemon-reload
```

或者试试参考这个 issue：[24#issue](https://github.com/SHORiN-KiWATA/ShorinArchExperience-ArchlinuxGuide/issues/24#issue-3745629323)

## 磁盘占用异常

明明没有多少文件，磁盘占用却很高。可以试试删除 btrfs 快照。

## 提示没有编解码器

安装的时候应该自带了编解码器，可能是删除别的软件时不小心连带着删掉了，重新安装即可：

```bash
sudo pacman -S gst-plugins-good gst-libav libde265
```

## Nautilus无法访问SMB共享

如果你的路由器或者别的设备开启了 SMB 文件共享，安装 gvfs-smb 可以使你在 Nautilus 访问那些文件。

```bash
sudo pacman -S gvfs-smb
```

## 域名解析出现暂时性错误

[解决 Ubuntu 系统中 "Temporary Failure in Name Resolution" 错误-CSDN博客](https://blog.csdn.net/qq_15603633/article/details/141032652)

```bash
sudo vim /etc/resolv.conf
```

内容修改为：

```text
nameserver 8.8.8.8
nameserver 8.8.4.4
```

## 扩展Windows的EFI分区空间

NIUBI Partition Editor free edition 使用这个工具。

## grub卡顿

N 卡的锅，没辙。

## virsh不显示虚拟机加上sudo后显示

因为虚拟机被创建在系统范围的 QEMU 连接里了。

```bash
sudo vim /etc/environment
```

写入：

```text
VIRSH_DEFAULT_CONNECT_URI=qemu:///system
```

## GNOME混合模式独显占用异常

```bash
sudo pacman -S vulkan-mesa-layers
```

## fuzzel无法打开终端程序

```bash
vim .config/fuzzel/fuzzel.ini
```

```ini
terminal=kitty -e
```

## thunar的压缩解压缩软件不生效

配置自定义动作：

- 解压到此处

   ```bash
   file-roller --extract-here %F
   ```

   出现条件勾选除了目录之外的，然后文件类型填写：

   ```text
   *.zip;*.tar;*.tar.gz;*.tgz;*.tar.bz;*.tbz;*.tar.bz2;*.tbz2;*.tar.Z;*.taz;*.tar.xz;*.tar.lz;*.tlz;*.tar.lzo;*.tzo;*.tar.lzma;*.7z;*.rar;*.cbr;*.cab;*.arj;*.cpio;*.deb;*.rpm;*.xar;*.jar;*.war;*.ear;*.iso;*.lha;*.lzh;*.alz;*.ace;*.zoo;*.cbz;*.gz;*.bz;*.bz2;*.xz;*.Z;*.lz;*.lzo;*.lzma;*.zst;*.br;*.lrz;*.rzip
   ```

- 创建压缩包

   ```bash
   file-roller --add %F
   ```

   出现条件勾选所有。

## Nautilus等GTK4应用启动慢

因为 GTK4 使用了新的渲染器，而新的渲染器和 N 卡的 'nvidia-utils' 产生了兼容性问题，设置环境变量使用旧的 GL 渲染器可以解决。

```bash
env GSK_RENDERER=gl nautilus
```

也可以在 `/etc/environment` 设置全局环境变量或者在 `~/.config/environment.d/myenv.conf` 设置用户空间的环境变量（需要重新登录）。

窗口管理器可以在配置文件里修改环境变量。

- Niri

   ```text
   environment {
      GSK_RENDERER "gl"
   }
   ```

## gnome的设置中心无法在窗口管理器打开

因为 gnome-control-center 只能在 GNOME 桌面环境打开：

```bash
env XDG_CURRENT_DESKTOP=gnome gnome-control-center
```

## 软件缩放问题

详情看这个网址：<https://wiki.archlinuxcn.org/wiki/HiDPI#GTK+_2>

[archwiki_hdpi](https://wiki.archlinux.org/title/HiDPI)

最常见的 Fcitx5 候选框过小问题也可以使用这个方法。

1. 安装 xorg-xrdb

   ```bash
   sudo pacman -S xorg-xrdb
   ```

2. 计算 DPI

   用标准 DPI 乘屏幕缩放，标准 DPI 通常是 96。1.5 倍缩放就是：96x1.5=144。

3. xrdb 调整缩放

   - 命令

      ```bash
      echo "Xft.dpi: 144" | xrdb -merge
      ```

      运行这个只是临时生效，想永久生效的话可以设置此命令自动启动。

   - 配置文件

      `~/.Xresources` 里写入：Xft.dpi: 144。

## btrfs-assistant没有同步matugen主题

因为是以 root 运行的，root 用户有自己的配置文件夹。

```bash
sudo ln -sf $HOME/.config/qt5ct /root/.config/qt5ct
sudo ln -sf $HOME/.config/qt6ct /root/.config/qt6ct
sudo ln -sf $HOME/.config/kdeglobals /root/.config/kdeglobals
```

## GTK4软件无法即时切换主题

可以通过切换暗色浅色的方式做到即时切换：

```bash
gsettings set org.gnome.desktop.interface color-scheme "prefer-light" && gsettings set org.gnome.desktop.interface color-scheme "prefer-dark"
```

## QQ用Wayland运行时剪贴板异常

因为此时 QQ 无法使用 Wayland 剪贴板，且因为是 Wayland 运行，无法触发 Wayland 和 XWayland 的剪贴板同步功能。

尝试以下操作：

1. QQ 里复制点东西。

2. 终端打印 X11 剪贴板里的内容。

   - 文字

      ```bash
      xclip -o -sel clip

      # xclip 管理 X11 剪贴板的 CLI
      # -o（output） 输出剪贴板数据
      # -sel（selection）选择要使用的剪贴板，不指定的话默认是鼠标中键的缓冲区。
      # clip（clipboard）代表 Ctrl+C/V 的那个剪贴板
      ```

      此时会输出复制的文字。

   - 图片

      ```bash
      xclip -selection clipboard -t image/png -o

      # 输出系统剪贴板数据
      # -t 指定数据类型
      # xclip 没有 wl-paste 智能，不指定类型为图片的话输出图片数据会报错
      ```

      此时会输出复制的图片的二进制数据。

   - 查看类型

      ```bash
      xclip -selection clipboard -t TARGETS -o
      ```

3. 把刚刚打印的东西传给 Wayland 剪贴板。

   wl-copy 会自动检测类型，所以通常不需要手动指定数据类型。

   ```bash
   xclip -o -sel clip | wl-copy
   ```

   ```bash
   xclip -selection clipboard -t image/png -o | wl-copy
   ```

   此时你会发现 QQ 复制的内容出现在了 Wayland 的剪贴板里。

以上就是原理。只要在检测到 X11 剪贴板发生变化的时候自动完成以上操作就解决了 QQ 的剪贴板问题。

## quickshell图标缺失

添加环境变量：

- Niri

   ```text
   environment{
      QS_ICON_THEME "Adwaita"
   }
   ```

## NetworkManager切换到IWD后端后使用impala联网提示operation aborted

删除 `/etc/NetworkManager/system-connections` 下记忆的 WiFi，重启服务之后即可联网。

```bash
sudo rm -rf /etc/NetworkManager/system-connections/*
sudo systemctl restart NetworkManager
```

## OBS导致显卡占用飙升进而导致游戏帧数大幅下降

游戏帧数大幅下降的根本原因是显卡占用过高导致画面输出堵塞。

有以下几个原因（以 780M 核显为例）：

- 第三方插件

   例如 NDI（`distroav`），这类插件即使不激活，仅仅只是安装上，在开启 OBS 之后就会导致显卡占用增加。

- 屏幕采集（13%）

   OBS 的屏幕采集极其吃显卡性能，你可以测试一下，开关屏幕采集，观察显卡占用的变化。窗口采集（5%）的占用要远远少于显示器采集。

- OBS 的预览画面（5%）

   OBS 的预览画面也相当吃显卡资源。

- OBS 本身

   如果 OBS 的窗口开在前台，就会占用大量显卡资源，必须放在后台。

所以 OBS 的正确使用方法是，用窗口采集获取画面，确认排版没有问题后关闭预览，然后把 OBS 的窗口关到后台。

## 天选4锐龙版2023使用Niri关闭屏幕后会自己亮屏

是没能正确识别主板的传感器轮询导致该轮询被视为了一次未知的按键输入，代码 `240/0xf0`。

如果你的情况和我相同，可以尝试屏蔽此按键：

```bash
sudo vim /etc/libinput/local-overrides.quirks
```
```text
[Asus WMI Hotkeys Ignore Phantom]
MatchName=*Asus WMI hotkeys*
AttrEventCode=-EV_KEY:0xf0;
```
重启后可以解决问题。

---

# 附录

这部分是一些有用但是被我弃用的东西，以及一些参考。

- [pacman 常用命令](#pacman常用命令)
- [timeshift](#timeshift)
- [ulauncher](#ulauncher)
  - [ulauncher 扩展](#ulauncher扩展)
  - [ulauncher 主题美化](#ulauncher主题美化)
- [Steam 子卷](#steam子卷)
- [IBus](#ibus)
- [rEFInd](#refind)
- [用 archinstall 安装 GNOME 后的一些清理](#用archinstall安装gnome后的一些清理)
- [TLP 相关](#tlp相关)
- [ananicy-cpp 资源调用优化](#ananicy-cpp资源调用优化)
- [更换 CachyOS 源](#更换cachyos源)
- [Zen 浏览器](#zen浏览器)
- [更改 TTY 字体大小](#更改tty字体大小)
- [Wayland compositor 剪贴板](#wayland-compositor-剪贴板)
- [wf-recorder](#wf-recorder)
- [让 Flatpak 应用 GTK 主题](#让flatpak应用gtk主题)
- [限制 AMD CPU 功耗](#限制amdcpu功耗)
- [Snapper 命令行快照回滚](#snapper命令行快照回滚)
- [B 站 5000 粉不到开播](#b站5000粉不到开播)
- [字体设置](#字体设置)
- [tuigreet](#tuigreet)
- [ly 显示管理器](#ly显示管理器)
- [GRUB 在 Btrfs 文件系统的最佳配置方法](#grub在btrfs文件系统的最佳配置方法)
- [opencode 使用本地 Ollama 或 LM Studio 模型](#opencode使用本地ollama或lmstudio模型)
- [内存大页 1G 和 2MB 切换的问题](#内存大页1g和2mb切换的问题)
- [辨别软件是运行在 Xwayland 还是 Wayland](#辨别软件是运行在xwayland还是wayland)
- [Btrfs 扩容和缩小](#btrfs扩容和缩小)
- [Vim/Neovim 切换模式时自动切换中文输入法](#vimneovim切换模式时自动切换中文输入法)
- [`niri-shorin-fork-git`](#niri-shorin-fork-git)

## pacman 常用命令

可以安装 pacman 的 GUI。

```bash
sudo pacman -S pamac
```

常用命令：

- 下载包但不安装

```bash
sudo pacman -Sw
```

- 删除包，同时删除不再被其他包需要的依赖

```bash
sudo pacman -Rns
```

- 查询包

```bash
sudo pacman -Ss
```

- 列出所有已安装的包

```bash
sudo pacman -Qe
```

- 列出所有已安装的依赖

```bash
sudo pacman -Qd
```

- 清理包缓存

```bash
sudo pacman -Sc
```

- 列出孤立依赖包

```bash
sudo pacman -Qdt
```

- 清理孤立依赖包

```bash
sudo pacman -Rns $(pacman -Qdtq)
```

- 无视依赖关系强制删除某个包

```bash
sudo pacman -Rdd
```

## timeshift

```bash
sudo pacman -S timeshift
```

```bash
sudo systemctl enable --now cronie.service
```

自动生成快照启动项

```bash
sudo pacman -S grub-btrfs inotify-tools
```

```bash
sudo systemctl enable --now grub-btrfsd.service
```

修改服务配置

```bash
sudo systemctl edit grub-btrfsd.service
```

```toml
[Service]
ExecStart=
ExecStart=/usr/bin/grub-btrfsd --syslog --timeshift-auto
```

重启服务

```bash
sudo systemctl daemon-reload
sudo systemctl restart grub-btrfsd.service
```

## ulauncher

ulauncher 是一个启动器，支持模糊搜索，用 GTK 编写，支持 Python 脚本

```bash
yay -S ulauncher
```

然后设置一个自定义快捷键，命令写 ulauncher-toggle，如果使用 GNOME 的 rounded corner 扩展记得添加 ulauncher 进黑名单。

ulauncher 最好用的是它的扩展功能，安装非常方便。打开设置进 extensions 页面，点击左侧的 discover extensions 就可以找到。

### ulauncher 扩展

我安装的扩展：

[flathub manager](https://github.com/damian-ds7/ulauncher-flathub-manager) 可以从 ulauncher 管理 Flatpak 软件

[emoji](https://github.com/Ulauncher/ulauncher-emoji) 可以快捷复制 emoji

[process murderer](https://github.com/isacikgoz/ukill)可以快捷杀死进程

[youtube search](https://github.com/NastuzziSamy/ulauncher-youtube-search)快捷从 youtube 搜索内容

[github search](https://github.com/SHORiN-KiWATA/ShorinArchExperience-ArchlinuxGuide/blob/main/github.com/Glovecc/ulauncher-github-search)快捷从 github 搜索内容

[appimage launcher](https://github.com/atorresg/appimagelauncher)快捷打开指定目录里的 appimage 文件（记得在设置里指定存放 appimage 的路径，需要使用从/开始的绝对路径）

### ulauncher 主题美化

浏览器搜索 ulauncher theme，存放路径在~/.config/ulauncher/user-themes

[这个主题应该是最适合 GNOME 默认主题的](https://github.com/aceydot/ulauncher-theme-gnome)

## Steam 子卷

我不想快照复制 Steam 游戏，因为这会占用大量的硬盘空间，可以创建一个和@home 平级的@steamgames 子卷让创建@home 快照的时候排除 Steam 的游戏。

1. 挂载根分区硬盘到/mnt 下任意位置

```bash
   sudo mount --mkdir -o subvolid=5 /dev/nvme1n1p2 /mnt/btrfs_root #记得替换为自己对应的硬盘名称
   ```

2. 创建@steamgames 子卷

```bash
   sudo btrfs subvolume create /mnt/btrfs_root/@steamgames
   ```

3. 禁用子卷的写时复制

```bash
   sudo chattr +C /mnt/btrfs_root/@steamgames
   ```

4. 取消挂载

```bash
   sudo umount /mnt/btrfs_root
   ```

5. 移动并备份现有 steamapps 文件夹

```bash
   mv ~/.local/share/Steam/steamapps ~/.local/share/Steam/steamapps.bak
   ```

6. 创建新的 steamapps 文件夹作为挂载点

```bash
   mkdir -p ~/.local/share/Steam/steamapps
   ```

7. 配置 fstab 文件

```bash
   sudo vim /etc/fstab
   ```

8. 复制粘贴 fstab 里面根分区的那一行

```ini
   # /dev/nvme1n1p2
   UUID=92a83c41-105d-4983-9536-2492d024bb52       /               btrfs           rw,relatime,compress=zstd:3,ssd,discard=async,space_cache=v2,subvol=/@  0 0
   ```

   粘贴到底部，把 / 修改为 steamapps 的路径 `/home/shorin/.local/share/Steam/steamapps`，把 subvol=/@ 改成 subvol=/@steamgames。修改后是这样的：

```ini
   # steamgames subvolume
   UUID=92a83c41-105d-4983-9536-2492d024bb52       /home/shorin/.local/share/Steam/steamapps     btrfs           rw,relatime,compress=zstd:3,ssd,discard=async,space_cache=v2,subvol=/@steamgames  0 0
   ```

9. 刷新 systemd 缓存

```bash
   sudo systemctl daemon-reload
   ```

10. 手动挂载 fstab 新条目

```bash
    sudo mount -a
    ```

11. 修改权限（记得替换成自己的用户名）

```bash
    sudo chown shorin ~/.local/share/Steam/steamapps/
    ```

12. 把刚刚备份的文件移回原位

```bash
    mv ~/.local/share/Steam/steamapps.bak/* ~/.local/share/Steam/steamapps/
    ```

13. 清理残留

```bash
    rm -r ~/.local/share/Steam/steamapps.bak
    ```

现在创建 home 目录的快照就不会记录 Steam 的游戏库了。对 Lutris 也可以进行同样的操作。如果被识别成外部设备出现在文档管理器的挂载列表里面，就在 fstab 的那一连串逗号隔开的参数里添加 `x-gvfs-hide`。

## IBus

参考：[Rime - Arch Linux 中文维基](https://wiki.archlinuxcn.org/zh-hant/Rime) | [可选配置（基础篇） | archlinux 简明指南](https://arch.icekylin.online/guide/advanced/optional-cfg-1#%F0%9F%8D%80%EF%B8%8F-%E8%BE%93%E5%85%A5%E6%B3%95) | [RIME · GitHub](https://github.com/rime)

已知问题：amber-ce（后面星火应用商店的部分会用到）里安装的 Qt 应用无法使用 IBus 输入法

1. 安装 IBus-rime

```bash
sudo pacman -S ibus ibus-rime rime-ice-pinyin-git
yay -S ibus-mozc
```

```text
ibus是ibus输入法的基本包
ibus-rime是中州韵
rime-ice是雾凇拼音输入法方案，实测比万象拼音方案好用
ibus-mozc是日语输入法
```

1. 在 GNOME 的设置中心 > 键盘 > 添加输入源 > 汉语，里面找到 rime 添加，如果没有的话登出一次

2. 编辑配置文件设置 rime 的输入法方案为 ice 雾凇拼音

```bash
   vim ~/.config/ibus/rime/default.custom.yaml
   ```

   如果没有文件夹的话自己创建。`mkdir ~/.config/ibus/rime/` 创建文件夹，`touch default.custom.yaml` 创建文件。写入以下内容：

```yaml
   patch:
     # 这里的 rime_ice_suggestion 为雾凇方案的默认预设
     __include: rime_ice_suggestion:/
   ```

   默认使用 super+空格切换输入法，可以在设置里修改。第一次切换至 rime 输入法需要等待部署完成。

3. 安装扩展自定义 IBus

   商店搜索 extension 安装蓝色的扩展管理器，或者用命令安装

```bash
   flatpak install flathub com.mattjakeman.ExtensionManager
   ```

   安装两个扩展：

   - IBus tweaker

     设置里激活"隐藏页按钮"

   - Customize IBus

     需要登出一次

     设置里，常规页面取消"候选框调页按钮"。主题页面可导入 css 自定义主题，[GitHub - openSUSE/IBus-Theme-Hub: This is the hub for IBus theme that can be used by Customize IBus GNOME Shell Extension.(可被自定义 IBus GNOME Shell 扩展使用的 IBus 主题集合)](https://github.com/openSUSE/IBus-Theme-Hub)，这个网站有一些预设主题。背景页面可以自定义背景（这个无敌了，什么美化都比不过一张合适的自定义背景）。其他的选项就自己探索吧。

- 删除 IBus 输入法

1. 系统设置>键盘 移除输入源

2. 删除包

```bash
   yay -Rns ibus-mozc ibus ibus-rime rime-ice-pinyin-git
   ```

3. 删除残留

```bash
   sudo rm -rfv ~/.config/ibus /usr/share/rime-data
   ```

4. 登出

## rEFInd

```bash
sudo pacman -S refind
```

```bash
refind-install
```

- 启动项记忆

  编辑 ESP 里的 refind.conf 文件

```bash
  sudo vim /efi/EFI/refind/refind.conf
  ```

  写入 `default_selection +`，意思是记住启动项选择。也可以 `"+,vmlinuz"` 设置优先级。

- 手动启动项

  设置 `menuentry{}`。

  ```ini
  menuentry "Arch Linux" {
   icon /EFI/refind/icons/os_arch.png
   volume ****************
   loader /@/boot/vmlinuz-linux-zen
   initrd /@/boot/initramfs-linux-zen.img
   options "root=UUID=54f285eb-8140-48df-81f8-2b03cb976fc0 rw rootflags=subvol=@ zswap.enabled=0 rootfstype=btrfs loglevel=5"
   enabled
  }
  ```

  `icon` 设置图标路径，路径从 ESP 的根目录开始而不是从 Linux 的根目录开始。

  `volume` 设置分区，不能用 UUID，要用 PARTUUID，使用 `sudo blkid` 获取。

  `loader` 指定内核路径。

  `initrd` 指定 initramfs 和 ucode 的路径。

  `options ""` 指定启动项参数。

  `enabled` 表示启用这个 entry，`disabled` 是禁用。

- 美化

  在/EFI/EFI/rEFInd/目录下新建一个 themes 文件夹

```bash
  sudo mkdir -p /efi/EFI/refind/themes
  ```

  然后浏览器搜索自己喜欢的 `git clone` 下来放到到刚刚创建的文件夹里

  然后编辑配置文件

```bash
  sudo vim /efi/EFI/refind/refind.conf
  ```

  ```ini
  include themes/**********/theme.conf
  ```

- 隐藏启动项

  可以在 rEFInd 的引导界面按 `delete` 键隐藏启动项。

  或者编辑配置文件用 `dont_scan_dirs=` 指定要排除的目录。

```ini
  dont_scan_dirs=/@/boot,EFI/****
  ```

## 用 archinstall 安装 GNOME 后的一些清理

```bash
sudo pacman -R gnome-contacts gnome-maps gnome-music totem gnome-characters gnome-connections evince gnome-logs malcontent gnome-system-monitor gnome-console gnome-tour yelp simple-scan htop sushi gnome-user-docs epiphany
```

## TLP 相关

（power-profiles-daemon 已经足够了，故弃用）

```bash
sudo pacman -S tlp tlp-rdw
```

```bash
yay -S tlpui
```

设置方法参考官方文档[Settings — TLP 1.8.0 documentation](https://linrunner.de/tlp/settings/index.html)

这里给一个现代电脑的通用设置：

  ```ini
processor 选项卡中

CPU DRIVER OPMODE
AC active
BAT active

CPU SCALING GOVERNOR
AC schedutil
BAT powersave

CPU ENERGY PERF POLICY
AC balance_performance
BAT power

CPU BOOST
AC on
BAT off

PLATFORM PROFILE
AC balanced
BAT low-power

MEM SLEEP
BAT deep
```

- 开启服务

```shell
sudo systemctl enable --now tlp
```

## ananicy-cpp 资源调用优化

影响 Steam 下载速度，弃用

```bash
yay -S ananicy-cpp cachyos-ananicy-rules-git
sudo systemctl enable --now ananicy-cpp.service
```

## 更换 CachyOS 源

[Optimized Repositories | CachyOS](https://wiki.cachyos.org/features/optimized_repos/)

（因严重软件安装异常问题弃用）

如果你渴望极致的性能优化，可以使用 CachyOS 的源。

ps：谨慎更换 CachyOS 的内核 `linux-cachyos`，内核恐慌（kernel panic）的概率会很大。

- 安装

```bash
  curl https://mirror.cachyos.org/cachyos-repo.tar.xz -o cachyos-repo.tar.xz
  tar xvf cachyos-repo.tar.xz && cd cachyos-repo
  sudo ./cachyos-repo.sh
  ```

- 重启电脑

- 移除

```bash
  curl https://mirror.cachyos.org/cachyos-repo.tar.xz -o cachyos-repo.tar.xz
  tar xvf cachyos-repo.tar.xz
  cd cachyos-repo
  sudo ./cachyos-repo.sh --remove
  ```

- 重启电脑

## Zen 浏览器

```bash
yay -S zen-browser zen-browser-i18n-zh-cn
```

## 更改 TTY 字体大小

```bash
sudo pacman -S terminus-font
```

```bash
ls /usr/share/kbd/consolefonts
```
```bash
sudo setfont ter-v32n
```

- 永久生效

```bash
sudoedit /etc/vconsole.conf
```

```ini
FONT=ter-v32n
```

```bash
sudo systemctl restart systemd-vconsole-setup
```

## Wayland compositor 剪贴板

```bash
yay -S clipse clipse-gui
```

## wf-recorder

```bash
sudo pacman -S wf-recorder
```

示例：

```bash
wf-recorder -c h264_vaapi -d /dev/dri/renderD128 --audio --file=test.mp4 -F scale_vaapi=format=nv12:out_range=full:out_color_primaries=bt709
```

## 让 Flatpak 应用 GTK 主题

```bash
flatpak override --user --filesystem=~/.themes
flatpak override --user --filesystem=xdg-config/gtk-4.0
flatpak override --user --env=GTK_THEME=adw-gtk3-dark
```

## 限制 AMD CPU 功耗

`ryzenadj`

## Snapper 命令行快照回滚

据官方文档说，可能会导致系统异常，但我没遇到过。

- 使用快照进行恢复

      `1..0`这里的`1`是要使用的快照的序号。`0`代表当前状态，快照会比对两者之间的差别然后撤销所有的更改。

```bash
      snapper -c root undochange 1..0
      ```

```bash
      reboot
      ```

## B 站 5000 粉不到开播

安装这个油猴脚本，然后在直播间开播，获取到推流码之后用 OBS 开播

[B 站推流码获取工具](https://greasyfork.org/zh-CN/scripts/536798-b%E7%AB%99%E6%8E%A8%E6%B5%81%E7%A0%81%E8%8E%B7%E5%8F%96%E5%B7%A5%E5%85%B7)

## 字体设置

[ArchWiki fontconfig](https://wiki.archlinux.org/title/Font_configuration)

字体主要分三类：

1. 非衬线字体（sans-serif）

   主要用于界面文字之类的场景。

2. 等宽字体（monospace）

   主要用于编程开发、终端之类的场景。

3. 衬线字体（serif）

   主要用于文书编辑之类的场景。

以下是一个 fontconfig 的示例，设置了三种字体类型具体使用哪些字体，可以解决大多数字体异常。fontconfig 的位置在`~/.config/fontconfig/fonts.conf`，编辑配置文件后还需要运行`fc-cache -fv`刷新字体缓存。

PS：这里示例中的 serif 衬线字体使用的是 sans-serif 非衬线字体的字体。因为真正用到 serif 的时候通常会手动选择（比如使用 WPS 进行文档编辑的时候），serif 使用 sans-serif 的字体可以避免某些网站（例如 bilibili 直播）将本该是非衬线字体的内容显示为衬线字体导致大幅影响阅读体验。

```xml
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
<fontconfig>

    <match target="font">
        <edit name="antialias" mode="assign"><bool>true</bool></edit>
        <edit name="hinting" mode="assign"><bool>true</bool></edit>
        <edit name="hintstyle" mode="assign"><const>hintslight</const></edit>
        <edit name="rgba" mode="assign"><const>rgb</const></edit>
        <edit name="lcdfilter" mode="assign"><const>lcddefault</const></edit>
    </match>

    <alias>
        <family>sans-serif</family>
        <prefer>
            <family>Noto Sans</family>
            <family>Noto Sans CJK SC</family>
            <family>Adwaita Sans</family>
        </prefer>
    </alias>

    <alias>
        <family>serif</family>
        <prefer>
            <family>Noto Sans</family>
            <family>Noto Sans CJK SC</family>
            <family>Adwaita Sans</family>
        </prefer>
    </alias>

    <alias>
        <family>monospace</family>
        <prefer>
            <family>JetBrains Mono</family>
            <family>JetBrains Maple Mono</family>
            <family>Adwaita Mono</family>
        </prefer>
    </alias>

</fontconfig>


```

## tuigreet

极速，基于 greetd 的纯 TTY tui 显示管理器（如果进入 tuigreet 之后还有日志输出会导致 tuigreet 的 tui 错位）。

1. 安装

```bash
    sudo pacman -S --noconfirm --needed greetd greetd-tuigreet
    ```

2. 简单配置

```bash
    sudo vim /etc/greetd/config.toml
    ```

```toml
    [terminal]
    # 绑定到 TTY1
    vt = 1

    [default_session]
    # 使用 tuigreet 作为前端
    # 自动扫描 /usr/share/wayland-sessions/，支持时间显示、密码星号、记住上次选择
    command = "tuigreet --time --user-menu --remember --remember-user-session --asterisks"
    user = "greeter"
    ```

3. 启用 greetd

```bash
    systemctl enable greetd
    ```

## ly 显示管理器

1. 安装

```bash
    sudo pacman -S ly
    ```

2. 启用

    这里的 TTY1 可以是任意 TTY

```bash
    systemctl enable ly@tty1
    ```

3. 简单配置

    有一个很酷的代码雨动画背景可以开。

```bash
    sudo vim /etc/ly/config.ini
    ```

     ```ini
     其他内容...

    animation = matrix

    其他内容...

    ```

## GRUB 在 Btrfs 文件系统的最佳配置方法

原理：GRUB 装进 ESP，`grub.cfg`生成在`/boot/grub`。编辑 ESP 里的`grub.cfg`让其在启动时读取`/boot/grub/grub.cfg`。这样`/boot/grub/grub.cfg`可以被快照回档，`esp/grub/grubenv`因为在 ESP 的 FAT 文件系统上，在系统初期也可以被写入。

1. 删除链接

    如果你的`/boot/grub`是指向 ESP 里的 GRUB 的链接，请删除后创建真实的目录。

```bash
    sudo rm -rf /boot/grub

    sudo mkdir -p /boot/grub
    ```

2. 查找根分区的 UUID

```bash
    findmnt / -n -o UUID
    ```

    >`findmnt /`列出跟根目录挂载信息

    >`-n`隐藏标题

    >`-o UUID`只输出 UUID

3. 编辑存根

```bash
    sudo vim /efi/grub/grub.cfg
    ```
    >手动输入 UUID 有点折磨，可以运行 `sudo findmnt / -n -o UUID > /efi/grub/grub.cfg` 把 UUID 直接覆盖写入 ESP 中的 `grub.cfg`

    此处的`/efi`应为你实际的 ESP 位置。

    删除所有内容，只需要写以下内容：

```ini
    # 设置 root 环境变量为实际的根分区设备
    search --fs-uuid --no-floppy  --set=root 你的 Btrfs 分区 UUID

    # 读取根分区中的 grub.cfg 文件
    configfile /@/boot/grub/grub.cfg
    ```

    >`search --fs-uuid <你的Btrfs分区UUID>`通过 uuid 搜索分区。

    >`--no-floppy`跳过软盘设备。

    >`--set=root`将搜索到的第一个设备设置为`root`。

    `root`是 GRUB 的环境变量之一，默认值是 GRUB 所在的设备。我的 GRUB 安装在了 ESP，那`root`的值就是 ESP 的设备名。我们为了 Btrfs 回档要把 GRUB.cfg 存在 Btrfs 文件系统里，所以要手动指定 root 的值为 Btrfs 文件系统所在的设备。

    `configfile`读取配置文件。`/@/boot/grub/grub.cfg`是配置文件目录，不指定设备的话默认在`root`环境变量指定的设备上查找此目录。

4. 配置快照启动项 grub-Btrfs

    >安装了 `grub-btrfs` 快照启动项功能的情况下才需要进行这步的编辑。

    `grub-btrfs.cfg`是快照启动项的配置文件。GRUB 寻找此文件时查的目录由`prefix`变量指定，这个变量代表的是 GRUB 的安装位置。我的 GRUB 安装在 ESP，所以`prefix`的值是`/efi/grub`，也就是说 GRUB 查找快照启动项的配置文件时的完整路径是`/efi/grub/grub-btrfs.cfg`。但是快照启动项的配置文件默认被生成到`/boot/grub/grub-btrfs.cfg`而不是`/efi/grub/grub-btrfs.cfg`，所以我们要修改`grub-btrfs`的配置文件指定 GRUB 在`/boot/grub`里寻找快照启动项的配置文件。

```bash
    sudo vim /etc/default/grub-btrfs/config
    ```

    找到下面这段内容：

     ```ini
     # GRUB_BTRFS_GBTRFS_SEARCH_DIRNAME="\${prefix}"
    ```

    改成：

```ini
    GRUB_BTRFS_GBTRFS_SEARCH_DIRNAME="/@/boot/grub"
    ```

    注意，`/@`必须是你实际的根子卷。

5. 生成`grub.cfg`

```bash
    sudo grub-mkconfig -o /boot/grub/grub.cfg
    ```

大功告成。现在对启动流程来说至关重要的`grub.cfg`就在快照的范围里啦，回档的时候引导也会跟着一起回档，除非 Btrfs 文件系统本身坏掉，否则系统 99.9%的情况下都不会再挂啦。

## opencode 使用本地 Ollama 或 LM Studio 模型

```bash
vim ~/.config/opencode/opencode.json
```

```json
{
  "$schema": "https://opencode.ai/config.json",
  "provider": {
    "ollama-lan": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "Ollama (LAN)",
      "options": {
        "baseURL": "http://192.168.0.13:11434/v1",
	"apiKey": "ollama"
      },
      "models": {
        "qwen3-coder-next:q4_K_M": {
          "name": "Qwen3 Coder Next"
        }
      }
    },
    "lmstudio-lan": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "LM Studio (LAN)",
      "options": {
        "baseURL": "http://192.168.0.13:1234/v1"
      },
      "models": {
        "qwen3-coder-next": {
          "name": "Qwen3 Coder Next"
        }
      }
    }
  }
}
```
## 内存大页 1G 和 2MB 切换的问题

内存大页的默认目录位置是`/dev/hugepages`，这个挂载点是在系统初始化的时候自动挂载上的，默认单页大小是 2MB，可以通过启动参数调整默认的页大小。

```ini
default_hugepagesz=1G hugepagesz=1G hugepages=16
```
> `default_hugepagesz=1G` 设置没有指定内存大页大小时的默认大小

> `hugepagesz=1G` 在开机时初始化 1GB 内存大页的管理机制

> `hugepages=16` 是需要的内存大页的数量

问题在于`/dev/hugepages`不可能同时是 2MB 又是 1GB，所以需要自定义内存大页目录，将 2M 和 1G 分别存储在不同的目录，做到同时使用。

编辑`/etc/fstab`

```ini
hugetlbfs_2M /dev/hugepages_2M hugetlbfs pagesize=2M,mode=1777 0 0
hugetlbfs_1G /dev/hugepages_1G hugetlbfs pagesize=1G,mode=1777 0 0
```

>`hugetlbfs_2M`只是一个名字；`/dev/hugepages_2M`挂载点；`hugetlbfs`指定文件系统是内存大页；`pagesize=2M`指定大页大小；`mode=1777`权限，

这样就同时存在 1G 和 2M 的内存大页系统，可以同时申请，同时使用。`/dev/hugepages`由系统管理，我们只动自己自定义的，于是避免了切换时会产生的各种问题。

`/sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages`是操作 1G 大页数量的接口。把`1048576`改成`2048`就是操作 2M 大页数量的接口。和`sysfs`这个关键词有关，我没学过 Linux，不懂。


## 辨别软件是运行在 Xwayland 还是 Wayland

可以使用`xorg-xeyes`或者`xorg-xlsclients`。

用`xeyes`的话，打开之后在窗口移动鼠标，如果眼睛在动就是 Xwayland，不动就是 Wayland。

用`xlsclients`的话，在输出列表里的就是 Xwayland，不在的就是 Wayland。

## Btrfs 扩容和缩小

>扩容可以在系统运行的时候进行

在进行扩容和缩容操作之前要先明确一个概念：块设备。`lsblk -p`列出的每一个`/dev`开头的分区都是一个块设备，文件系统只认块设备，不看这个块设备是在你的硬盘 1 上还是在硬盘 2 上又或者在你的移动 U 盘上。

分两种情况：`调整大小（resize）`和`添加（add）`

- resize

    如果是单个硬盘上的连续空间，使用此方法（单个硬盘但是空间不连续，可以使用 GParted 移动分区）。

    原理是先调整物理分区大小，再调整 Btrfs 文件系统大小。

    1. cfdisk 调整物理分区大小

```bash
        sudo cfdisk /dev/nvme0n1
        ```
        > /dev/nvme0n1 替换为你实际的块设备名称

        选中`更改尺寸 resize`扩容分区（直接回车会自动合并连续的空闲空间）；然后选择`写入 Write`，输入`yes`，回车保存更改；`退出 Quit`退出 cfdisk。

    2. 调整 Btrfs 文件系统大小

        >`btrfs`命令由`btrfs-progs`提供

```bash
        sudo btrfs filesystem resize max /
        ```
        >`filesystem resize`调整文件系统大小

        >`max /` 将根目录所在文件系统扩容至最大物理硬盘空间

    3. 确认

```bash
        df -h /
        ```
        通过大小那一列可以看到扩容成功。

    - 减少硬盘空间

        缩小的话只需要将过程反过来，先缩小文件系统大小再缩小分区大小。

        先用`df -h /`确认可用空间；然后用`btrfs`调整大小：

```bash
        sudo btrfs filesystem resize -10G /
        ```
        >`resize -10G /` 将文件系统缩小了 10G。

        >这里还可以指定缩小到多少 G，例如缩小到 50G 就是 `resize 50 /`。

        现在用 `df -h /` 就可以看到大小变小了，记住这个数值后用 `cfdisk` 的 resize 功能缩小分区大小就行。

- add

    如果是多个硬盘上的块设备，使用此方法（未分配空间需要先新建为块设备）。

    原理是将新的块设备加入当前文件系统，Btrfs 文件系统会智能在多个块设备之间存储数据。

    1. 添加块设备

```bash
        sudo btrfs device add /dev/vda2 /
        ```
        >`/dev/vda2`替换为你实际用来扩容的新块设备名称

        >`device add /dev/vda2 /`添加`/dev/vda2`到根目录所在文件系统

    2. 确认

```bash
        df -h /
        ```
        可以看到空间已经变大。
```bash
        btrfs filesystem show /
        ```
        可以看到该文件系统下有多个块设备。

    - 减少硬盘空间

        把新增的块设备移除即可（要确保移除之后的剩余空间足够存下两个块设备上已有的数据）：

```bash
        sudo btrfs device remove /dev/vda2 /
        ```
        现在再用`btrfs filesystem show /`，输出结果里就没有那个设备了。

- swap 分区（交换分区）

    跨多个设备的文件系统不能使用交换文件，如果你配置了交换文件的话必须更换为交换分区，方法如下：

    1. 删除 swapfile

        `swapoff`命令关闭现有的交换文件，然后编辑`/etc/fstab`删除交换文件的自动挂载，再用`rm`命令删除交换文件。

    2. 腾出空间

        用上面缩容的方法腾出一块空间用作交换分区。

    3. 格式化

        使用`cfdisk`把腾出的空间新建为块设备，`type`选择`Linux Swap`。然后用`mkswap`命令格式化。

    4. 启用和自动挂载


        使用 `swapon` 命令现在启用交换分区。然后使用 `lsblk -f` 获取 swap 分区的 UUID；编辑 `/etc/fstab` 加上如下内容：

```ini
        UUID=你的 swap 分区的 UUID  none  swap  defaults 0 0
        ```

- 在跨设备的情况下缩容

```bash
    sudo btrfs filesystem show /
    ```
    示例输出：
```yaml
    Label: none  uuid: 7f989f8d-d2ce-4c91-9cf3-db687089ce4e
	Total devices 2 FS bytes used 629.31GiB
	devid    1 size 879.00GiB used 514.02GiB path /dev/nvme0n1p2
	devid    2 size 931.51GiB used 486.00GiB path /dev/nvme1n1
    ```
    记录自己要缩小的硬盘的`devid`，在上面的示例输出中我想要缩容的`/dev/nvme0n1`的`devid`是 1。

    用`devid`指定设备，其他的就和单设备缩容差不多了：
```bash
    sudo btrfs filesystem resize 1:-75G /

    cfdisk /dev/nvme0n1
    > resize
    > 879G
    > write
    > yes
    > exit。

    sudo btrfs filesystem resize 1:max /
    # 我前面预留了一些空间，所以这里再 max 一次补全
    ```

## Vim/Neovim 切换模式时自动切换中文输入法

- Vim

    在`.vimrc`写入

```vim
    " === fcitx5 状态切换与恢复 ===
    let g:fcitx_state = 1
    autocmd InsertLeave * let g:fcitx_state = system("fcitx5-remote")[0] | call job_start("fcitx5-remote -c")
    autocmd InsertEnter * if g:fcitx_state == '2' | call job_start("fcitx5-remote -o") | endif
    autocmd VimEnter * call job_start("fcitx5-remote -c")

    ```

- 在`~/.config/nvim/init.lua`写入

    ```lua
    -- fcitx5 状态切换与恢复
    local fcitx_st = ""
    vim.api.nvim_create_autocmd("InsertLeave", { callback = function() fcitx_st = vim.fn.system("fcitx5-remote"); vim.fn.jobstart("fcitx5-remote -c") end })
    vim.api.nvim_create_autocmd("InsertEnter", { callback = function() if fcitx_st:match("2") then vim.fn.jobstart("fcitx5-remote -o") end end })
    vim.api.nvim_create_autocmd("VimEnter", { callback = function() vim.fn.jobstart("fcitx5-remote -c") end })

    ```

## `niri-shorin-fork-git`

这是我的 niri 分支。

新增了以下几个功能：

- 晃动鼠标放大

    ```ini
    cursor {
        shake-to-enlarge {
            //off
            grow
            grow-speed 0.01
            threshold 2000
            hold-duration-ms 1500
            zoom-factor 5
        }
    }
    ```

- 屏幕放大

    ```ini
    magnifier {
        // off
        zoom-factor 3
        //track-cursor false
        //scale-cursor false
    }

    binds{
        Mod+Alt+WheelScrollUp   { adjust-magnifier-zoom 0.2; }
        Mod+Alt+WheelScrollDown { adjust-magnifier-zoom -0.2; }
        Mod+Shift+Z         { toggle-magnifier; }
    }
    ```

- 网格概览

    ```ini
    grid-overview {
        gap 16
        padding {
            left 64
            right 64
            top 48
            bottom 48
        }
        grid-all-monitors true
    }

    binds {
        Mod hotkey-overlay-title="切换网格总览界面 toggle grid overview" repeat=false { toggle-grid-overview; }
    }
    ```

- 截图支持 stdout

```bash
    niri msg action screenshot --stdout
    ```

- 支持单独给 mod 键绑定功能

```ini
    Mod hotkey-overlay-title="切换网格总览界面 toggle grid overview" repeat=false { toggle-grid-overview; }
    ```

-  热角

    ```ini
    gesture {

        hot-corners {
            bottom-left { grid-overview }
        }
    }
    ```
- 窗口规则

    ```ini
    window-rule {

        match is-floating=true
        ignore-grid-overview true
    }
    ```
- grid 和 overview 打开后中键直接关闭窗口。
- grid 和 overview 中 hjkl 切换聚焦，聚焦窗口在边缘时依旧往边缘切换聚焦会切换工作区。

---

# 常见争议澄清

此文章用于澄清 Linux 社区一些造成误会和争议的问题。

## Ubuntu 用 APT 安装 Firefox 会变成 Snap 包

>[Seeding the official Firefox snap in Ubuntu Desktop](https://discourse.ubuntu.com/t/feature-freeze-exception-seeding-the-official-firefox-snap-in-ubuntu-desktop/24210)

>[Chromium in Ubuntu – deb to snap transition](https://snapcraft.io/blog/chromium-in-ubuntu-deb-to-snap-transition)

>[LinuxMint Monthly News – May 2020](https://blog.linuxmint.com/?p=3906)

Firefox 被更换为 Snap 的决策是由 Mozilla 主动发起的，是与 Canonical 合作的结果，目的是减少维护时间、更方便更新、更好的多平台支持等。

>但是更久之前，Ubuntu 因为自身的原因主动将 apt 的 Chromium 更换为 snap 包，争议之大，直接导致 LinuxMint 默认阻止 Snap 被安装。

---

# 交流群


你可能在使用中会遇到问题想要寻求帮助，或者想加个交流群以便在遇到问题的时候寻求帮助。以下是步骤：

1. 学习如何提问

    [提问的智慧](https://github.com/ryanhanwu/How-To-Ask-Questions-The-Smart-Way/tree/main?tab=readme-ov-file)

2. 加群

    [archlinuxcn交流群](https://wiki.archlinuxcn.org/wiki/Project:Arch_Linux_%E4%B8%AD%E6%96%87%E7%A4%BE%E5%8C%BA%E4%BA%A4%E6%B5%81%E7%BE%A4%E6%8C%87%E5%BC%95)

    我的 Arch QQ 交流群：130515298

---

# Linuxmint入门

Linux Mint 是最适合新手的发行版。本文是安装 Linux Mint 之后必要的基本配置。

[点击跳转视频教程](https://www.bilibili.com/video/BV19DBqB4EY4/?vd_source=65a8f230813d56660e48ae1afdfa4182#reply115786966372305)

[更详细的日常使用参考视频](https://www.bilibili.com/video/BV1YvenzUEFf/?spm_id_from=333.1387.upload.video_card.click)

## 镜像源和系统更新

首先在欢迎程序点击 `第一步` --> `更新管理器` --> `确定`。

会提示切换到本地镜像，点击 `主要` 和 `基础` 边上的链接，稍微等待一会，测速完成后选择最快的镜像源。

选择完成后点击右下角 `更新APT缓存` --> `应用更新` --> `安装更新`。

## 安装驱动

在欢迎程序打开驱动管理器安装驱动。第一次打开需要加载一会，耐心等待吧。

## 中文输入法

1. 打开系统设置，点击 `输入法` --> `简体中文` --> `安装`。

2. 切换顶部的 `输入法框架` 为 `fcitx`。

3. 注销重新登录。

默认的切换快捷键是 `Ctrl+空格`。

## 软件安装

有几种方法：

1. 软件管理器安装。

2. 软件管理器安装 flatpak 包。

    flatpak 是众多发行版通用的打包方式。打开软件管理器，点击右上角三条横杠 --> `首选项` --> `显示未经验证的 flatpak 软件`，这样可以显示出更多常用软件。

3. 网上下载 DEB 包双击安装。

    DEB 包就有点类似 Windows 里的 .exe 或 .msi 安装包。

4. 网上下载 AppImage 包。

    下载之后需要右键设置 `以可执行程序启动`。AppImage 可以类比为绿色免安装版。

5. 命令行安装。

    - 搜索

        `sudo apt search 关键词`

    - 安装

        `sudo apt install 包名`

    - 卸载

        `sudo apt remove 包名`

`sudo` 命令以管理员权限运行命令，需要输入密码，输入密码的过程不显示。

`apt` 是 Debian 系发行版的包管理器。

后面的 `search` `install` `remove` 都是 `apt` 的选项，更多选项可以通过 `apt -h` 查看，看不懂英文可以 AI 翻译。

---

# CachyOS


CachyOS 是当下最火热的性能特化的 Arch 衍生发行版，本文介绍安装 CachyOS 的方法和一些必要的配置。

CachyOS 分为掌机版（Handheld Edition）和桌面版（Desktop Edition），本文基于桌面版。

## 安装 CachyOS

进入 Live 环境之后打开 CachyOS hello 窗口，点击 launch installer 开启安装程序。

1. 语言

    ![](pictures/cachyos/language.png)

    这里设置的是安装程序的显示语言和之后系统的本地化，请选择英文。系统本地化等装完系统进桌面环境之后再设置为中文，否则使用终端和中文输入法会不方便。

2. 时区

    ![](pictures/cachyos/timezone.png)

    中国对应的时区是 Asia/Shanghai。

3. 键盘布局

    ![](pictures/cachyos/keyboard-layout.png)

    选 US 或者 Chinese 都可以。

4. Bootloader 引导加载程序

    ![](pictures/cachyos/bootloader.png)

    如果你不知道选哪个请选择 GRUB。

5. 分区

    ![](pictures/cachyos/partition.png)

    这一步是重点，根据需求选择。

    - install alongside （并存）

        如果你是一个盘装 Win + Cachy 双系统，进 Live 环境前没有事先腾出硬盘空间，且 Win 的 EFI 分区大于 512MB，选择这一项。

    - replace a partition （替代一个分区）

        如果你是一个盘装 Win + Cachy 双系统，进 Live 环境前事先腾出了硬盘空间，且 Win 的 EFI 分区大于 512MB，选择这一项。

    - erase disk （抹掉磁盘）

        如果你使用一整个硬盘安装 Cachy，选择这一项。

    - manual partitioning（手动分区）

        如果以上都不满足，选这一项。

6. 手动分区

    分出两个分区，一个启动分区，一个根分区。

    - 选择空闲空间，点击 create 创建。

        ![](pictures/cachyos/partition2.png)

    - 新建启动分区

        CachyOS 要求启动分区 Size（大小）至少为 `512MB`，FileSystem（文件系统）为 `fat32`，MountPoint（挂载点）为 `/boot/efi`，Flags（标记）为 `boot`。

        ![](pictures/cachyos/partition3.png)

    - 新建根分区

        剩下的空闲空间都是根分区，文件系统推荐 `btrfs`，挂载点为 `/`。

        ![](pictures/cachyos/partition4.png)

7. 桌面环境

    如果没有特殊需求，选择 `Plasma Desktop`。

    ![](pictures/cachyos/desktop.png)

8. 选择要安装的包

    没有特殊需求默认即可，需要打印机驱动的勾选带 print 字样的选项。

9. 普通用户

    很多软件拒绝在 root 权限运行，普通用户是必须的。

    ![](pictures/cachyos/user.png)

到这一步安装就算是完成了。CachyOS 会自动处理好必要的软件源和驱动，开箱即用。

## 必要的配置

安装完成后重启进入系统，登入普通账户。有一些必要的基本配置需要完成。

### 更新系统

在 CachyOS hello 点击 `Apps Tweaks`，激活 `Cachy Update enabled`，这是任务栏上的更新模块；然后再点击 `System Update` 确保系统在最新状态。

### 双系统引导

1. 允许搜索其他系统

    按下 `Ctrl+Alt+T` 打开 Konsole 终端。运行如下命令：

    ```bash
    kate /etc/default/grub
    ```

    删除倒数第三行开头代表注释的井号：

    ```text
    GRUB_DISABLE_OS_PROBER=false
    ```

    按下 `Ctrl+S` 保存，输入密码。

2. 生成 grub.cfg

    接着在终端运行：

    ```bash
    sudo grub-mkconfig -o /boot/grub/grub.cfg
    ```

### 更改系统语言为中文

左下角打开系统设置，在 `Region & Language` 里把语言改成简体中文，点击右下角 `Apply` 应用，重启之后系统语言就变成中文了。

### 安装中文输入法

1. 安装必要的包

    ```bash
    sudo pacman -S fcitx5-im fcitx5-chinese-addons

    # fcitx5-im 是基础包
    # fcitx5-chinese-addons 包含了绝大多数中文输入方案
    ```

2. 系统设置

    在 `输入和输出 --> 键盘 --> 虚拟键盘` 里激活 `Fcitx5 Wayland 启动器`，右下角应用，此时应该就可以使用输入法了，默认切换快捷键是 `Ctrl+空格`。

    再编辑环境变量让 XWayland 应用也能使用输入法：

    ```bash
    kate /etc/environment
    ```

    ```text
    XMODIFIERS=@im=fcitx
    ```

3. 修改 LC_CTYPE

    LC_CTYPE 是系统本地化相关的环境变量，为中文时会导致输入法出现漏字问题。

    ```bash
    kate ~/.config/plasma-localerc

    # ~/.config/plasma-localerc 这个文件是 Plasma 语言设置相关的文件
    ```

    在 `[Formats]` 里面添加一行：

    ```text
    LC_CTYPE=en_US.UTF-8
    ```

4. 注销重新登录

    在开始菜单点击 `会话 --> 注销`，重新登录即可。

更多输入法信息看：

- [ShorinWiki_中文输入法](中文输入法)
- [ArchWiki_Fcitx5](https://wiki.archlinux.org/title/Fcitx5)
- [ArchWiki_输入法](https://wiki.archlinuxcn.org/wiki/%E8%BE%93%E5%85%A5%E6%B3%95)

### 快照

快照代表着存档和回档，这是 btrfs 的一大主要功能。CachyOS 预装了 `snapper` 和 `btrfs-assistant`。具体的使用方法看：[ShorinWiki_快照和系统维护](快照和系统维护)

### 软件安装

看 [ShorinWiki_软件安装相关](软件安装相关)。

至此，一个功能可供日常使用的 CachyOS 环境搭建完成。

---

# Arch部署Astrbot


本文在 Arch Linux 部署本地 AstrBot AI Agent 并接入 QQ。

## 启动 AstrBot

>参考资料：[AstrBot 官方文档](https://astrbot.app/)

1. 安装 `uv`

    ```bash
    sudo pacman -S uv
    ```
2. 用 `uv` 安装 `astrbot`

    ```bash
    uv tool install astrbot
    ```
    >`astrbot` 相关文件会被安装到 `~/.local/share/uv/tools/astrbot`，通过链接的方式在 `~/.local/bin` 存放了一个 `astrbot` 可执行文件。

3. 初始化并启动

    在你觉得合适的地方创建一个用于存放 AstrBot 数据的目录，进入那个目录后再初始化 AstrBot（不要直接在 `~` 代表的 home 目录下初始化，会浑身难受）。

    ```bash
    # 创建目录
    mkdir -p ~/Documents/Astrbot
    # 进入目录
    cd ~/Documents/Astrbot
    # 初始化
    astrbot init
    # 启动
    astrbot run
    # 以后再次启动前记得先切换到这个目录
    ```

4. 访问 WebUI

    你会在 `astrbot run` 的输出里看到如下内容：

    ![](pictures/astrbot/astrbot-run.png)

    在浏览器输入图中的任意地址访问 WebUI。例如本地访问时使用的 `http://localhost:6185`，推荐将地址添加进收藏夹。

5. 登录和修改账号密码

    访问 WebUI 后登录默认账号。

    ```text
    用户名：astrbot
    密码：astrbot
    ```

    然后会弹出 AstrBot 仪表盘提示更改用户名和密码，修改后重新登录。

    ![](pictures/astrbot/passwd.png)

AstrBot 的启动到此结束，下一步需要创建机器人，本文只介绍 NapCat 一种。

## 创建机器人

> 参考资料：[AstrBotDocs_OneBot v11](https://docs.astrbot.app/platform/aiocqhttp.html) | [NapCat 官方文档](https://napneko.github.io/)

1. 安装依赖和 NapCat

    ```bash
    sudo pacman -S xorg-server-xvfb
    ```

    NapCat 使用 AppImage 版本可能更方便一些，[下载地址在这](https://github.com/NapNeko/NapCatAppImageBuild/releases)。x86_64 架构下载 `-amd64.AppImage` 版本。

    ![](pictures/astrbot/download-napcat.png)

2. 启动 NapCat

    在你觉得合适的地方创建一个用于存放 NapCat 数据的目录，将下载下来的 AppImage 移动到新建的目录下。为了方便使用，可以给 AppImage 重命名为 `napcat`，然后右键添加执行权限，或者使用命令：

    ```bash
    chmod +x napcat
    ```
    在当前目录打开终端后启动 AppImage：

    ```bash
    ./napcat
    ```
3. 登录

    注意如下输出：

    ![](pictures/astrbot/run-napcat.png)

    记录访问 WebUI 的地址。然后扫码登录你的小号 QQ，或者新建一个 QQ 号当作机器人。后续可以用以下方式快速登录：

    ```bash
    ./napcat --no-sandbox -q 你的qq号
    ```

    >日后如果 token 找不到了可以在 `config/webui.json` 中找到。

4. 新建 Websocket 客户端

    在 WebUI 点进 `网络配置` --> `新建` --> `Websocket 客户端`

    ![](pictures/astrbot/napcat-websocket.png)

    按照下图进行配置：

    ![](pictures/astrbot/napcat-websocket4.png)

    激活 `启用`，`名称` 按需填写，`URL` 填写 `ws://localhost:6199/ws`。

5. 把 NapCat 接入 AstrBot

    回到 AstrBot 的 WebUI，添加消息平台类别为 `OneBot v11` 机器人。

    ![](pictures/astrbot/newabot.png)

    ![](pictures/astrbot/setnewbot.png)

    稍作等待之后应该会出现已连接的日志：

    ![](pictures/astrbot/suclog.png)

现在我们需要对机器人做最后的配置。

- 如果 AppImage 版本失败了，可以尝试 AUR 包：

    ```bash
    yay -S xorg-server-xvfb napcatqq-git linuxqq
    ```
    ```bash
    xvfb-run -a linuxqq --no-sandbox
    ```

## 设置模型提供源

1. 添加对话模型

    ![](pictures/astrbot/addmodel.png)

    ![](pictures/astrbot/setllm.png)

    这一步结束之后就可以在 QQ 里像跟好友聊天一样跟刚刚登录 NapCat 的那个账号聊天啦。

<details><summary><h3>[展开/收起]如果你不知道怎么获取 Api_Key，不知道怎么本地部署 AI 的话</h3></summary>

## 获取 ApiKey

在想用的模型后面加上 api 关键词就可以找到对应模型的 API 平台，例如 `deepseek api 平台`。通常通过 `登录账号` --> `设置付款方式` --> `创建 Api Key` 这几个步骤之后就可以获取到 API。

![](pictures/astrbot/deepseekapi.png)

然后在 AstrBot 的提供商源的 `新增` 列表里选择对应提供商的选项即可。如果没有对应选项的话就选择 `Open AI Compatible`，然后去查你用的 AI 的 API 文档，他们会提供兼容 OpenAI 的 `base_url` 给你，替换掉 `Open AI Compatible` 配置页面里的 `API Base URL` 即可。

![](pictures/astrbot/deepseek2.png)

![](pictures/astrbot/deepseek3.png)

![](pictures/astrbot/deepseek4.png)

## 本地部署 AI

本地部署的话推荐使用 [LM Studio](https://lmstudio.ai/)，简单快捷，开箱即用。

```bash
paru -S lmstudio-bin
```

按照自己的硬件配置下载合适的模型。

![](pictures/astrbot/lmstudio.png)

lmstudio 会贴心地提示你能不能使用。

![](pictures/astrbot/lmstudio2.png)

下载完成后要进入 LM Studio 的 server 页面启动服务器，记住 LM Studio 使用的是 `1234` 端口。

![](pictures/astrbot/lmstudio3.png)

然后在 AstrBot 里添加 lmstudio，启用模型。

![](pictures/astrbot/lmstudio4.png)


</details>

## 基本配置

![](pictures/astrbot/astrbot-menu.png)

修改配置之后记得右下角保存。

- AI 配置

    现在我们来做一些基本设置。先看 AI 配置页面。

    - 默认对话模型

        在 `模型` 板块设置 `默认对话模型`。

        ![](pictures/astrbot/astrbot-config1.png)

    - 人格

        在 `人格` 板块设置最基本的角色设定和提示词。

        ![](pictures/astrbot/renge0.png)

        ![](pictures/astrbot/renge1.png)

        ![](pictures/astrbot/renge2.png)

    - 网页搜索

        如果你没有自己的 API 的话可以试试 [Tavily](https://www.tavily.com/) 的免费 API。

    - 使用电脑能力

        这一项之后还需要在 `平台配置` 页面设置 `管理员 ID` 才能让 AI 使用电脑。

        ![](pictures/astrbot/local.png)


    - 其他配置

        推荐激活 `流式输出`、`用户识别`、`显示群名称`。

        ![](pictures/astrbot/otherconfig.png)

- 平台配置

    - 基本

      - 管理员 ID

          给机器人发消息：`/sid`。然后机器人会回复你 `UMO` 和 `UID`。在 `管理员 ID` 的地方点击 `添加更多`，把 `UID` 加进去。

          ![](pictures/astrbot/uid.png)

          ![](pictures/astrbot/uid2.png)

          这样 AI 就可以操作你的电脑了。

      - 白名单

        如果你想要 AI 在群里只回复你的消息的话可以把 `UMO` 加进 `白名单 ID 列表` 里。

        ![](pictures/astrbot/baimindan.png)

    - 内容安全

        推荐设置一些额外安全屏蔽词。

        ![](pictures/astrbot/safe1.png)

        ![](pictures/astrbot/safe2.png)

- 扩展功能

    还可以在扩展功能里开启一些让 AI 更 `真` 的功能。

    ![](pictures/astrbot/extraconfig.png)


至此，享受吧！

别的玩法交给你自己研究啦~


## 网络搜索

在 AstrBot 的配置页面可以设置通过 API 使用网络搜索服务提供商的付费服务，以下这两个每个月有 1000 免费额度。

- [Firecrawl](https://www.firecrawl.dev/)
- [Tavily](https://www.tavily.com/)

### searxng

免费额度不够用但是又不想花钱的话可以本地部署一个 [searxng](https://github.com/searxng/searxng)。

推荐使用 Docker Compose 部署，Arch 安装 Docker 看：[虚拟机_docker](./虚拟机.md#docker)

1. 创建存放 searxng 的目录

    >随便一个你喜欢的地方。
    ```bash
    mkdir -p ~/Documents/searxng
    ```
2. 进入目录

    ```bash
    cd ~/Documents/searxng
    ```
3. 下载配置

    ```bash
    curl -fsSL \
    -O https://raw.githubusercontent.com/searxng/searxng/master/container/docker-compose.yml \
    -O https://raw.githubusercontent.com/searxng/searxng/master/container/.env.example

    # 复制 .env 文件（如果你需要开放外部网络访问或者编辑端口的话修改这个文件）
    cp -i .env.example .env
    ```
4. 启动

    ```bash
    docker compose up -d
    ```

- 其他命令

    ```bash
    # 关闭
    docker compose down

    # 更新(要先关闭)
    docker compose pull

    # 查看
    docker compose ps
    ```

5. 使用

    默认端口为 8080，可以访问 `http://localhost:8080` 进行使用，设置界面可以设置具体的搜索引擎、隐私安全等内容。

6. 接入 AI

    安装 opencode，随便找个 AI 让你写个 searxng 的插件，提供给 LLM 自动调用的工具就可以了。

---

# 代理


![](pictures/有时候需要绕一些远路.png)

如果你使用 Linux 遇到了网络问题，可以配置代理。代理链接自己找。本文只推荐 GUI 程序，不涉及纯命令环境下的代理配置。

- [flclash（英文字母小写 L）](代理#flclash)

- [daed](代理#daed)

推荐使用 `flclash`。

## 测试代理是否生效

配置完代理后一定要测试是否生效。

```bash
curl -I www.google.com
```

返回由 `HTTP ... OK` 开头的一大串内容就是成功了。

## 安装临时图形环境

如果你目前没有桌面，可以安装一个临时的图形化环境运行接下来介绍的软件，我推荐使用 labwc。如果你已经有桌面了（任意桌面都可以），不需要这一步。

1. 安装 labwc

    ```bash
    sudo pacman -S labwc kitty
    ```

    labwc 是一个堆叠式窗口管理器，Kitty 是我使用的终端。会问你装哪个字体，回车默认就行。

2. 启动 labwc

    ```bash
    labwc
    ```

    labwc 打开之后是纯黑的，正常点击桌面选择 `terminal` 或者按下 `Super（Win 键）+ 回车键` 就能打开终端，选 `exit` 可以退出 labwc。

- 卸载 labwc

    要做的事情结束之后想删除这个临时图形环境可以使用这条命令：

    ```bash
    sudo pacman -Rns labwc
    ```

## flclash

flclash 支持随壁纸更换颜色，强推！

1. [添加 archlinuxcn](安装桌面环境前的准备#archlinuxcn源)

2. 安装

    ```bash
    pacman -S flclash
    ```

3. 启动

    ```bash
    flclash
    ```

4. 主页开启 TUN（虚拟网卡）

5. 导入链接

6. 右下角启动代理

7. 测试是否生效。

## daed

1. [添加 archlinuxcn](安装桌面环境前的准备#archlinuxcn源)


2. 安装

    ```bash
    yay -S daed
    ```

3. 启动

    ```bash
    sudo systemctl start daed
    ```

4. WebUI

    daed 的面板以 WebUI 方式提供。

    打开浏览器，访问 `localhost:2023` 即可进入 WebUI。导入订阅之后把订阅从右侧拖到左侧的群组。

5. 用其他设备访问 WebUI

    运行 `ip a` 命令获取本机 IP 地址。然后打开手机浏览器，在处于同一局域网的情况下访问以下地址：

    ```text
    你的 IP 地址:2023
    ```

    假设我的 IP 地址是 192.168.0.155，那就用手机浏览器访问 `192.168.0.155:2023`。

6. 开启 TUN 虚拟网卡

7. 测试是否生效。

## 不推荐使用的代理软件

<details><summary>[展开/收起]</summary>

### clash-verge-rev

0. [需要先添加 archlinuxcn](安装桌面环境前的准备#archlinuxcn源)

1. 安装

    ```bash
    pacman -S clash-verge-rev
    ```

    clash-verge 是基于 mihomo 内核和 Tauri 的面板软件。

2. 启动

    ```bash
    clash-verge
    ```

3. 启动 TUN 模式（虚拟网卡模式）

    如果出现 TUN 无法安装的情况，可以切换到 root 身份后打开 clash-verge。

    ```bash
    su -

    clash-verge
    ```

    还可以 `Ctrl+Alt+F2~F8` 切换到另一个 TTY 用 root 身份登录后启动 labwc，这样就是 root 身份开启的图形化环境了。

    如果启用 TUN 之后没有生效，可以尝试进入设置页面点击 Clash 内核边上的齿轮，切换成 mihomo alpha 内核，重启内核。

4. 记得导入链接和启动代理。

5. 测试是否生效。

</details>

---

# nixos

## 安装

-   切换到root用户

    ```
    sudo -i
    ```

-   分区/格式化/挂载和arch是一样的

-   生成基础配置

    ```
    nixos-generate-config --root /mnt
    ```

    会在`/mnt/etc/nixos/`下生成`configuration.nix`和`hardware-configuration.nix`

-   创建flake

    ```
    cd /mnt/etc/nixos
    touch flake.nix home.nix
    ```

## references

[https://nixos-cn.org/](https://nixos-cn.org/)

---

# ShorinNiri功能介绍

- [快捷键](#快捷键)
- [壁纸和模糊](#壁纸和模糊)
- [输入法](#输入法)
- [剪贴板](#剪贴板)
- [任务栏](#任务栏)
  - [任务栏模块功能介绍（从左到右）](#任务栏模块功能介绍从左到右)
- [锁屏](#锁屏)
- [截图和录屏](#截图和录屏)
- [Alt+Tab 跳转窗口](#alttab-跳转窗口)
- [终端仿真器和 Shell](#终端仿真器和-shell)
- [文档管理器](#文档管理器)
- [显示管理器（登录界面）](#显示管理器登录界面)
- [常用命令](#常用命令)

## 快捷键

对窗口管理器来说，称手的快捷键至关重要。你可以学习我的快捷键，或者设计自己的。

`Super+Shift+/` 打开按键教程，基于 fzf，可以模糊搜索。

![](pictures/shorin-niri/niri-binds.gif)

所有快捷键可以在 `.config/niri/binds.kdl` 查看，有详细的中文注释。

最常用的：

|  快捷键   |      功能      |
| :-------: | :------------: |
|  super+Z  |   软件启动器   |
|  super+Q  |    关闭窗口    |
|  super+T  |      终端      |
| super+G/O |  overview概览  |
| super+H/L | 向左右切换聚焦 |
| super/u/i |  切换工作区    |

快捷键看着多，但是都有迹可循。桌面快捷键大部分以 `Mod 键`，也就是 `Win 键` 开头，配合三套上下左右。

1. 方向键
2. vimkey（hjkl对应左下上右）
3. 游戏方向键（wasd）

加上 `Ctrl` 就是和窗口相关，通常是移动窗口；加上 `Shift` 就是切换功能或者和显示器相关；加上 `Alt` 通常和软件相关。如果是 `Mod+F1~12` 就是特殊功能。

## 壁纸和模糊

壁纸功能的核心是 waypaper 和 awww。壁纸默认存放路径为 `~/Pictures/Wallpapers`。

- 壁纸切换

  `Super+Alt+W` 或者右键点击任务栏上的取色器模块打开 waypaper 切换壁纸。waypaper 的配置文件在 `~/.config/waypaper/`。waypaper 里按下 Z 键可以切换简洁模式（简洁模式默认开启）。

  ![](pictures/shorin-niri/waypaper.gif)

  还可以使用 `Mod+F10` 快捷键随机切换壁纸。
  
- 随机下载动漫壁纸并切换

  使用 `Mod+Shift+F10` 可以随机从网上下载动漫壁纸并切换。随机下载的壁纸会保存到壁纸目录下的 `api-random-download` 目录。
  
  此功能的脚本在 `~/.config/scripts/random-anime-wallpaper.sh`。脚本开头的 `KEEP_COUNT=40` 设置了最多保存多少张壁纸，默认是 40。超过后会自动按照时间顺序删除，所以如果你随机到了喜欢的壁纸记得从 `api-random-download` 目录取出来。

- 桌面自动模糊脚本（已经弃用）

  通过脚本在聚焦时自动切换壁纸为当前壁纸的模糊版本。第一次打开 Niri 会通过 ImageMagick 生成模糊壁纸，CPU 会起飞一会。Niri 已支持窗口模糊，故弃用。如果你不想用测试分支的 Niri，一定要用这个的话可以编辑 `~/.config/niri/config.kdl` 取消下图中 spawn... 那行开头代表注释的 `//`：

  ![](pictures/shorin-niri/niri-auto-blur-bg.png)
  
  脚本路径：`~/.config/scripts/niri_auto_blur_bg.sh`

  缓存文件路径：`~/.cache/blur-wallpapers/`

- overview概览背景壁纸

  切换壁纸时通过 waypaper 配置文件中的 `post_command` 功能自动运行 `~/.config/scripts/niri_set_overview_blur_dark_bg.sh` 脚本设置 overview 背景为当前壁纸的暗色模糊版本。

  缓存文件位置：`~/.cache/blur-wallpapers/`

  ![](pictures/shorin-niri/auto-blur-overview.gif)

- 主题颜色切换

  更换壁纸时调用 `.config/scripts/matugen-update.sh` 生成主题。使用 Matugen 提取壁纸主要色生成所有需要的主题颜色。Matugen 的配置文件在 `~/.config/matugen/`，模板在 `~/.config/matugen/templates/`，你可以自行添加或修改模板。
  
  - 更换颜色模式

    中间任务栏上的取色器模块或者快捷键 `Super+Alt+T/M` 可以打开 Matugen 配置菜单。可以切换浅色、暗色和各种不同的颜色生成方案。自 Matugen 4.0 开始增加了 `随机主色` 和 `固定第一主色` 两个模式。固定第一主色模式使用 `matugen --source-color-index 0` 强制使用第一主色。随机主色模式会在 Matugen 提供的多个主色之间轮换。这个配置菜单脚本的路径在 `~/.config/scripts/matugen-select-type.sh`。

    ![](pictures/shorin-niri/matugen-select-type.png)

## 输入法

输入法使用 Fcitx5 + RIME，默认输入方案是雾凇拼音，接入了万象语法模型和 `rime-llm-translator`，`Super+空格` 切换输入法。第一次启动输入法可能会卡死，用 `Mod+F1` 可以开关输入法进程。

- 输入法配置

  切换到 RIME 输入法引擎后按下 `F4` 可以打开 RIME 输入法菜单，如果你的 Shorin-Niri 是包括常用软件的完整安装的话里面会包含主流的五笔86、明月拼音、小鹤双拼和注音输入方案。
  
  ![](pictures/shorin-niri/rime-f4.png)

  配置 Fcitx5 可以使用 `fcitx5-configtool`，程序菜单中叫 `Fcitx5 配置`。

  ![](pictures/shorin-niri/fcitx5-configtool.png)

- `rime-llm-translator`

  [详情点击此处跳转仓库](https://github.com/SHORiN-KiWATA/rime-llm-translator)

  给 RIME 输入法接入大模型进行云拼音联想，支持 TUI 图形化配置。输入时按下 `vv` 使用此功能。运行 `rime-llm-config` 可以打开 TUI 进行配置。

  
更多输入法信息看 [ShorinWiki_中文输入法](中文输入法)。

## 剪贴板

[SHORiN-KiWATA/cliphist-tui](https://github.com/SHORiN-KiWATA/cliphist-tui)

剪贴板使用自制的 `cliphist-tui` TUI 剪贴板，后端是 `wl-clipboard` 和 `cliphist`。`Mod+Alt+V` 打开剪贴板。

## 任务栏

任务栏是 Waybar。我制作了两个预设，`Super+F2` 是顶部 Waybar，灵感来自 [mechabar](https://github.com/sejjy/mechabar)。`Super+F3` 是底部 Waybar，仿照 Win11 的任务栏布局。还可以用 `Super+F4` 关闭任务栏，`Super+Shift+F4` 隐藏任务栏。

顶部 Waybar 的配置文件在 `~/.config/waybar/`，底部 Waybar 的配置文件在 `~/.config/waybar-niri-Win11Like/`。编辑 `config.jsonc` 可以设置模块的开关、任务栏在哪些显示器上显示等内容。`modules.jsonc` 里是具体的模块功能。`style.css` 设置了 Waybar 的外观样式。`colors.css` 是由 Matugen 根据模板生成的颜色文件。

鼠标悬停在每个模块上可以显示模块的作用。

### 任务栏模块功能介绍（从左到右）

- 工作区切换模块 对应 `config.jsonc` 里的 `niri/workspaces`

  左键可以切换工作区，因为 Niri 的工作区是动态增删的，所以使用图标区分而不是数字。

  ![](pictures/shorin-niri/waybar/workspace.png)

- 应用模块 `cffi/niri-taskbar`

  用于显示已经开启的应用，此功能由第三方的 `waybar-niri-taskbar` 提供。

  ![](pictures/shorin-niri/waybar/taskbar.png)

- 应用title名称模块 `niri/window`

  用于显示当前聚焦窗口的 title 名称，这个名称可以在设置窗口规则时使用。

  ![](pictures/shorin-niri/waybar/window.png)

- 常用命令模块 `custom/actions`

  包含了大部分常用命令。

  ![](pictures/shorin-niri/waybar/actions.png)

  ![](pictures/shorin-niri/waybar/actions-menu.png)

- 录屏模块 `custom/wfrec`

  支持 wl-screenrec 后端和 wf-recorder 后端的方便录屏模块，尤其录制 GIF 的功能相当好用，支持基本录制设置。简单录屏一般用这个，复杂的工程会用 OBS Studio。
  
  此脚本由 `shorin-contrib-git` AUR 包提供，运行 `shorin screenrec` 命令开启。录制文件存放于 `~/Videos/shorin-screenrec/`。

  ![](pictures/shorin-niri/waybar/wfrec.png)

  ![](pictures/shorin-niri/waybar/wfrec-settings.png)

- 截图模块 `custom/screenshot`

  截图保存目录：`~/Pictures/Screenshots/`

  左键使用 `grim` 和 `slurp` 简单截图，仅进入剪贴板。

  ![](pictures/shorin-niri/waybar/screenshot-left.gif)
  
  右键打开截图菜单（`~/.config/waybar/scripts/power-screenshot.sh`），支持一系列设置。可以从 Niri 和 `grim` 两种后端之间切换，还可以设置是否编辑，编辑使用 `satty` 或者 `swappy`（新版本 Shorin-Niri 已经移除了 `swappy`，要使用的话得自己装）。
  
  ![](pictures/shorin-niri/waybar/screenshot-right.gif)

  中键可以长截图，详情看：[SHORiN-KiWATA/wl-longshot](https://github.com/SHORiN-KiWATA/wl-longshot)

- 剪贴板模块 `custom/clipboard`

  左键可以打开剪贴板。

- idle模块 `idle_inhibitor`

  眼睛图标是激活，眼睛被划了一道线是禁用。如果使用了类似 swayidle 或者 hypridle 的程序，激活这个模块可以禁止熄屏。

- 取色器模块 `custom/colorpicker`

  左键可以提取颜色复制到剪贴板。右键可以打开 waypaper 切换壁纸。中键可以打开 Matugen 配置菜单。

- 性能模式模块 `power-profiles-daemon`

  后端是 `power-profiles-daemon`。左键可以在省电（叶子）、平衡（太极）和性能（闪电）三种性能模式之间切换。

- 启动器模块 `custom/applauncher`

  用于显示 Logo。左键可以打开 fuzzel 程序启动器，右键可以打开终端。

- 时间模块 `clock`

  悬浮可以显示日期。左键打开 `gnome-clocks`。右键打开 `gnome-calendar`。

- 音频可视化模块 `custom/cava`

  此音频可视化模块脚本位于 `~/.config/waybar/scripts/cava.sh`。后端使用 cava。

- 更新模块 `custom/updates`

  `~/.config/waybar/scripts/check-updates.sh`，显示待更新的 pacman 和 AUR 软件。左键可以调用 `shorin sysup` 更新系统，右键可以调用 `shorin checkallupdates` 显示所有待更新的项目。

  ![](pictures/shorin-niri/waybar/checkallupadtes.gif)

- 后台应用模块 `tray`

- 亮度模块 `group/ddcutil`

  ![](pictures/shorin-niri/waybar/ddcutil.png)

  这是一个合集模块。月亮是笔记本内屏亮度调节，三个太阳是使用 ddcutil 调节外接屏幕亮度，没有做成滑块是因为会导致笔记本内屏卡死。如果切换外屏亮度的功能没有生效可以确认 `modules.jsonc` 里此模块的显示器是否正确指定。
  
  右键大太阳还可以开关护眼模式（晚上的时候才有护眼效果）。护眼模式的设置在 `~/.local/bin/toggle-wlsunset`，可以设置地理位置和色温。

- 隐私模块 `privacy`

  ![](pictures/shorin-niri/waybar/privacy.png)

  如果有软件正在使用桌面门户进行屏幕分享，这个模块才会出现。

- 音频模块 `group/audio`

  ![](pictures/shorin-niri/waybar/audio.png)

  这是个合集模块。通过滑块调整系统音量，滚轮调整麦克风音量。左键静音，右键关闭麦克风。中键打开 `pavucontrol` 面板。

- 蓝牙模块 `bluetooth`

  左键可以打开连接蓝牙的 TUI（`bluetui`），右键禁用/启用蓝牙设备。

  ![](pictures/shorin-niri/waybar/bluetui.png)

  `S 键` 搜索，`回车` 连接

- 网络模块 `network`

  左键可以打开 `impala` 连接 Wi-Fi，右键可以打开 `nm-connection-editor` 进行高级网络配置。

  ![](pictures/shorin-niri/waybar/impala.png)

  `S 键` 扫描网络。`Tab 键` 切换板块。`回车` 连接。

  如果 impala 无法正常使用可以运行 `nmtui` 命令打开 nmtui 进行联网。

## 锁屏

锁屏使用 `hyprlock`，配置文件存放在 `~/.config/niri/hyprlock.conf`，放在 Niri 的目录下是为了避免和 Hyprland 共存时产生配置文件冲突。

`Mod+Alt+L` 锁屏。

我移除了类似 `swayidle` 之类自动锁屏熄屏休眠的程序，如果你想暂时离开或者节省电量，可以使用 `Super+Alt+P`，会自动关闭屏幕并锁屏和休眠。

## 截图和录屏

截图使用 Niri 自带的截图。编辑截图使用 `satty`。编辑截图功能的使用方式是截图后再按下编辑截图快捷键（默认是 `Mod+Shift+S`）读取剪贴板中刚刚截的那张图进行编辑。

Satty 的配置文件在 `~/.config/satty/`。截图保存位置可以通过 Niri 配置文件 `~/.config/niri/config.kdl` 中的 `screenshot-path` 设置，默认在 `~/Pictures/Screenshots/Niri-screenshots/`。

录屏使用任务栏的录屏模块和 OBS Studio。Niri 的录屏需要 `xdg-desktop-portal-gnome` 桌面门户，如果 OBS 没有出现 `屏幕采集（PipeWire）` 选项的话请检查该门户是否正常工作。

## Alt+Tab 跳转窗口

- Niri 自带的 recent-window

  `Super+Tab` 进行有缩略图的窗口跳转。`Super+波浪键` 仅仅在当前应用的窗口之间跳转。

- fuzzel 菜单

  `Alt+Tab` 打开窗口跳转菜单。支持输入窗口名称搜索后直接跳转，效率极高。`Ctrl+J/K` 选择，`回车` 或 `Ctrl+L` 跳转，`Ctrl+H` 关闭窗口。

## 终端仿真器和 Shell

终端使用 Kitty，配置文件在 `~/.config/kitty/kitty.conf`。

提示符美化使用 Starship，配置文件在 `~/.config/starship.toml`。这个文件由 Matugen 生成，模板位于 `~/.config/matugen/templates/starship-colors.toml`。如果你要更改 Starship 配置，应该更改 Matugen 模板，否则变更壁纸后会被覆盖。或者你可以注释掉 `~/.config/matugen/config.toml` 中 Starship 相关的内容禁用它的 Matugen 同步。

Shell 使用 Fish，配置文件在 `~/.config/fish/`，其下的 `config.fish` 文件和 `function` 目录里的文件定义了所有的功能。

- `f`命令

  这是我自制的二次元老婆生成器，用 `fastfetch` 显示系统信息的同时随机下载二次元图片替代掉原本的 Arch logo。

  脚本位置：`~/.config/scripts/fastfetch-random-wife.sh`

  缓存位置：`~/.cache/fastfetch_waifu`

- `ls`

  查看目录的功能使用 `eza`。

- `cd`

  切换目录功能使用 `zoxide`，只要切换过一次目录，就只需要输入路径中的关键词，不需要输入完整目录了。
  
## 文档管理器

主要使用 Thunar。`Mod+E` 打开。我制作了一些好用的自定义功能：

- 右键视频显示多媒体信息

- 右键视频转 GIF

- 右键图片转 PNG

- 把复制的文件粘贴为链接（`Ctrl+Shift+V`）

- 粘贴剪贴板图片为文件（`Ctrl+Alt+V`）

- 右键从此处打开 VS Code

- 右键获取文件所有权

可以在 Thunar 的左上角点击 `编辑` --> `配置自定义动作`

> btw，我保留了 `右键从此处打开终端` 是英文 `Open Terminal Here` 的设计。

除了 Thunar，Nautilus 也作为 `xdg-desktop-portal-gnome` 的依赖被安装了，在软件菜单里叫文档，图标是个蓝色的柜子。我还安装了 Yazi 作为终端文档管理器，方便在终端管理文件。

## 显示管理器（登录界面）

显示管理器使用轻量快速的 Ly，纯 TUI 界面，同时支持简单的背景动画，用于管理多用户登录和多桌面环境切换。Ly 的配置文件在 `/etc/ly/config.ini`。

## 常用命令

大部分常用命令由 `shorin-contrib-git` AUR 包提供，运行 `shorin` 命令可以看到所有可用的命令和简介，我在安装时已经用 `shorin link` 命令将它们链接到了 `~/.local/bin` 下，使用时可以不加 `shorin` 作为父命令。

- `shorinniri`
  
  `init` 初始化
  
  `remove` 移除 Shorin-Niri

  `update` 更新

  `protect <文件路径>` 更新时保护文件

- `quicksave`

  快速存档（`Mod+F5`）。可以通过 `-d` 选项指定快照的描述。`-h` 查看更多用法。

  如果你要做不了解或者有风险的事情，请一定先存档。

- `quickload`

  快速读档（`Mod+F8`）。`-h` 查看用法。

- `mirror-update`

  使用 `reflector` 更新 pacman 的镜像源。

- `sysup`

  更新系统。请使用此命令更新系统而不是直接使用 `pacman -Syu`。

- `clean`

  清理系统。自动清理孤立软件包、清理软件包缓存、清理过于老旧的系统日志、清空回收站和缩略图、清理 flatpak 残留等等。

  `clean all` 可以删除所有现有的快照，深度清理系统。

- `pac`

  TUI 安装软件。

- `pacr`

  对应 `pac`，用于卸载软件。

- `pacd`

  对应 `pac`，用于降级软件。需要 `downgrade`。

- `pacrrr`

  卸载软件前先追踪软件残留文件，用于避免软件在 home 目录下残留文件。需要 `strace`。

- `pak`

  TUI 安装 Flatpak 软件。

- `pakr`

  卸载 Flatpak 软件。

- `sudo change-grub-theme`

  可以更换 GRUB 主题。只要主题文件存放在 `/usr/share/grub/themes` 里，就可以检测到。

  使用旧脚本安装的用户可以 `curl -L shorin.xyz/change-grub-theme | sudo bash` 安装这个脚本。

---

# shorinos

## 软件源

- 创建库

    准备好所有编译好的软件包之后，使用 `repo-add` 命令自动读取软件包中的元数据生成 `<源名称>.db.tar.zst`，同时读取文件路径生成 `<源名称>.files.tar.zst`，这是文件本体，为了让 pacman 读取到，需要创建链接或者复制一份，去掉 `.tar.zst` 后缀，最终会有四个文件：`<源名称>.db` `<源名称>.db.tar.zst` `<源名称>.files` `<源名称>.files.tar.zst`。

    示例：

    ```
    repo-add shorin-arch.db.tar.zst shorin-contrib-git-r70.ac80b05-1-any.pkg.tar.zst
    ```
    > 这条命令将 `shorin-contrib-git` 这个包添加到了源里

    生成的文件如下：

    ```
     ls -l 
    lrwxrwxrwx    - shorin 19 6月  21:37 shorin-arch.db -> shorin-arch.db.tar.zst
    .rw-r--r--  718 shorin 19 6月  21:37 shorin-arch.db.tar.zst
    lrwxrwxrwx    - shorin 19 6月  21:37 shorin-arch.files -> shorin-arch.files.tar.zst
    .rw-r--r--  966 shorin 19 6月  21:37 shorin-arch.files.tar.zst
    .rwxr-xr-x 105k shorin 19 6月  20:45 shorin-contrib-git-r70.ac80b05-1-any.pkg.tar.zst
    ```

- 存放和配置

    云存储的 `Public Access` 绑定到 `repo.shorin.xyz`，然后存放上述四个文件和软件包，存放时的目录结构，决定了填入 `pacman.conf` 的链接。例如 `/archlinux/x86_64`，之后填写 `pacman.conf` 的链接就是 `repo.shorin.xyz/archlinux/$arch`。如果源存储在本地目录，那么在填写的时候就是 `file:///path/to/archlinux/$arch` ，注意权限问题。

    >$arch 会自动变成架构，如 `x86_64`，所以软件包实际的存放路径是 `repo.shorin.xyz/archlinux/x86_64/软件包.pkg.tar.zst`

    示例 `pacman.conf` 配置：
    ```
    [shorin-arch]
    SigLevel = Optional TrustAll
    Server = https://repo.shorin.xyz/archlinux/$arch
    ```
    
    >`SigLevel = Optional TrustAll` 代表了不进行验证

- GPG 签名


    `pacman.conf` 中应该默认写了一行 `SigLevel = Required DatabaseOptional`，代表源需要进行安全验证。我们使用 GPG（GNU Privacy Guard）进行此操作。密钥分为私钥和公钥，私钥被密码保护。我们要使用私钥给软件包签名，然后将公钥发布给使用我们源的人，他们在安装包的时候会匹配公钥和软件包上的私钥签名，如果不匹配则验证失败，软件无法安装。

    - 创建密钥对

        ```
        gpg --full-generate-key
        ```
        过程中会让你进行一些选择。`密钥对类型` 选择 `(1) RSA 和 RSA`； `RSA长度` 输入 `4096` 获得最大安全性；`密钥有效期` 按需，`0` 代表永不过期；接下来 `用户标示` 要求填写 `姓名` `邮箱` `对密钥的注释`；最后输入英文字母 `o` 确认，此时会弹出窗口让你设置 `私钥的密码`，此密码用于解码私钥。  

        示例输出：

        ```
        pub   rsa4096 2026-06-19 [SC]
            8ED9ABE61CDBAABAC4B6A694C9218E60C13B4BA8
        uid                      shorinkiwata (shorin-arch) <example@email.com>
        sub   rsa4096 2026-06-19 [E]
        ```
        
        这一串内容 `8ED9ABE61CDBAABAC4B6A694C9218E60C13B4BA8` 就是密钥的 ID，代表了这个密钥。

    - 发布公钥

        ```
        gpg --armor --export 8ED9ABE61CDBAABAC4B6A694C9218E60C13B4BA8 > shorin-arch.pub
        ```
        >`--armor` 创建 ASCII 字符封装的输出
        >`--export <密钥 ID >` 导出该 ID 代表的密钥
        >`> shorin-arch.pub` 将命令输出写入 `shorin-arch.pub` 这个文件

        示例输出：

        ```
        -----BEGIN PGP PUBLIC KEY BLOCK-----

        mQINBGo1PFwBEADQGkd6BB0L/xQh9v8UnP8L0c1ct0kC4OjvISVJIrKdA50xorOq
        4hu8lMHDoD/ep/KVjO339ROYXZ6e9L1ZGrAsIJHrv3xK8cDaOAMwudnS3osQ2gTT
        VAAV1KadFwzlAKPC0tdtn+aGW0Ny0EB6hPDdmsJcIOBw7ZkBjhXQZWI3oFr6sAoM
        N8Ey+Cia1WrmE8Pq3j0fzerSIayuQmWM10KT6sAdn2wyDZyGJA8Aq79PhLbsGi/Z
        Qd2vdHhIdiA1sX9gJjC7r/Q9k7AEraw9KLqHz9ntXStUyDbUMwC3vy+oN+tejMlh
        ePcFsgLXk2nBfx3djvE59vDXShZCrtR6ODfkKxoHfrZADZL7UljzTdl2bDkwM1Vm
        Jb1FSr4itIgtRhhWc2rcUJcYGeEKhMUS0vwM04a1oz4+1/UGu6HktIjzTlJW77dd
        mEl5jaO/+3GeDmvlV4l7QWtmjHwwytbhNzx3c5H93SwQHwFMpxLsWT7ftwrbEG2M
        i4BQVxQ47aCfxITfQF8KNcEGrP18lcxtOIZ208W9HndntQOfEybFvGP9KgGEPAcM
        0aeIF/Zcpw8mwZGCUSPbRgK2U/7+4uD5LMyD/R3MbIdDayh9zpttSozCEgIZSSbw
        uuQyxvayUdpvsPhnzVX7cEaibqi8YnGVmXqG3bQ+f7j2HsXfMN8WYt98JQARAQAB
        tC9zaG9yaW5raXdhdGEgKHNob3Jpbi1hcmNoKSA8ZmNsNzA5QG91dGxvb2suY29t
        PokCTgQTAQoAOBYhBI7Zq+Yc26q6xLamlMkhjmDBO0uoBQJqNTxcAhsDBQsJCAcC
        BhUKCQgLAgQWAgMBAh4BAheAAAoJEMkhjmDBO0uoqyMP/2UOLixN0sQ4GtG+RD6x
        P5YoWEFHp/yoGuFjCPmL56Q3atntJyHIHZkYqvC8h9Miai2roHkZNh6xpBX3Bi1L
        n/Mt9BQHP/tcDKCWysTNr1q04idzc4J60u2PHd0LFqsP2cIG4lIjJ6MwwHzx4A/5
        ddcQNyaVrLsIMKhdJnaC+Rvm8QrVciFcM8Fl43VfLXzh2qKIEzkkSAmAPcyyVt44
        VOYgoLgJo5yJhLcGjttZsWpEIlenSN8oSbBPVkuUNP/8dXhz4nQmx7yJndpphA6j
        7oev9Wj5zMx3Gn1ZCfnzSJx+4Ng+VZOCZ2/SCko0n7+C54gPan6hoHRBgvj6V3xZ
        ReAqJsa/TnnTcgausLHfK7BMN5tdtIHXLWZBb5XwSkd7JfiBJ7cuMxDg5hyp/PGh
        Xq3DvKCASt7BtEcZhi+JjHxdoCjVKo4KFVH7ZFkkz/o8c95pBLv0o7Py9pbvQ5ML
        hl/XSufBi5GsBqENM6h7lgFt4GWXFjQxAiu+P8nMmcvRVLqlkP9yR1SOxdI4/zZu
        ri7gXXc0J6Jh6QCc3FT7PMSZVXcq1+bi2Cn+SS/Pk8GceAsGwmVj7q1MG6Uq7wPi
        Z/eStCrMp4bE5D4pEwR0ugvzbZI3JV7lJuXAY8v0Si/W+e6/QfWMhubUd+18bxcm
        SA24CstuBV/Qaz2ibJXzKGq+uQINBGo1PFwBEADCF7Dmdq4D4tK2kSvjYA1btnKe
        eqpHLk+mghu4AUCszEKwpmpCN1hFzstdYEaVVMlYpO9Vp7ezOkuHoDpdemRa8sBcY
        82ddaV0xgtO7fV4gAicvfVb915SC9s/+K+bfMBAQDLswaYDLcouZzsH14Tn8e3ti
        +EqYyeoAiG97eCp7Nc40T+cMjw78O/d2eHGl+ensZmVP5UHIDOlegr7XGR6AOi3K
        7DliJDvqIHIgPjotHLJgduoEuJNx0FZd0Zb3HaFG5rmRuPCF6VfdayIE9bFYTSjR
        UiAr2BMUXoO3NHVUtBJFSfBWlu1l9uTwnJ22lJbx3XRpmpVUqERLPyqWCahWxzCe
        WHlf84nNf6dmDytcWGH32QoTZtU0nnEEkZdZluIO9NQecLDZURnHZ5niDS0nTjaB
        IWbjUjVXKKeKPCHbG8uKOuSEoCOsk/A4i7X5TBkGxsuFQIl58555Q1328FJKSrH7
        16i/p9bnI5X5J61GN2Xri3weIYroY7x0cM2tCzhkIHxjY++Qcwvh+emu3HqmX/UI
        4RNFNkUw0DqORgeRqOCAWb5Wk9duLbbsXqemGKbeeblPRDHLw53dOXugj8qVU1fU
        SyOmJuxddWqtfPFjJCDOSbpJW1vAIGXpqPXnKICbqnD5hwlrP6x1KZqrDvLf2tqf
        w0LJ5zgRmd9ZCS7uYwARAQABiQI2BBgBCgAgFiEEjtmr5hzbqrrEtqaUySGOYME7
        S6gFAmo1PFwCGwwACgkQySGOYME7S6jHJhAAvZZwt2GQkk8KejGmaXZPUzABwKkf
        9eMURz3xJ8BH4YzAbZFFimsZlv81FtEacL2DzBM3ywLEQCq4KcM/o9ZGMawX76aV
        c02lw5AtuEOPe2WaXnpZvuSDzlhmqBeNLIexFBBNjNj2HbI1jeosNqXA8GdCg+fZ
        6E3d3GSx/J3D/txBKjNLTvuo19aWfqCc09lja8fw5JYUBFQH8eNf0m/LwcDmlhcS
        ui9zUNNecz9uwWs/Gx9EP2IWnYzZErN8oH9TC4L+RQeXqXN6uOytadsBXCvzw5K7
        FfhtMDzGgS4UI4U6R1x9LcdTeO2MUAE9qSa9zWZxBw2tp+dhcD9GFL7i1JOZRFV1
        TzK7hdYcu9cO/LPgiE/bo+vYEIgUNi8JpY3MnySDFoiXUE6KlW5SVScPVwMwwPpe
        gCgdH58OMxeumML7ubwPzlkljOyNlKRKgP9B5S9SJQpasUbU5YH1z1LmXXCkrTgX
        ZHYIlW2csHGtu+ssvw+aOJtPCy8EqYi/MRPZrsH950kxMcyB03KqXa+aAOKYPfga
        c67QdJoPVkPn5AvEG6bpAd7CzwiizezmxzcdahfpvirvtuqSvlLNMSA3n2D3QmrI
        SG0xv8RRNxSpVgLfrvYImCkl4Yk5bzepGM83MNp3QGYT3zi4D4xOAVhcs1+v+e6M
        YWFSPCUmvxNLRPo=
        =50Ly
        -----END PGP PUBLIC KEY BLOCK-----
        ```

    - 签名数据库和软件包

        在 `repo-add` 时添加 `--sign --key <密钥 ID >` 选项对生成的数据文件进行签名

        ```
         repo-add --sign --key 8ED9ABE61CDBAABAC4B6A694C9218E60C13B4BA8 shorin-arch.db.tar.zst shorin-contrib-git-r70.ac8
        0b05-1-any.pkg.tar.zst
        ==> 正在将shorin-arch.db.tar.zst提取到临时位置…
        ==> 正在将shorin-arch.files.tar.zst提取到临时位置…
        ==> 正在添加软件包 'shorin-contrib-git-r70.ac80b05-1-any.pkg.tar.zst'
        ==> 警告： 已存在条目 'shorin-contrib-git-r70.ac80b05-1'
        -> 正在计算校验值...
        -> 正在删除现有的条目 'shorin-contrib-git-r70.ac80b05-1'...
        -> 正在创建 'desc' 数据库条目...
        -> 正在创建 'files' 数据库条目...
        ==> 正在生成更新的数据库文件 'shorin-arch.db.tar.zst'
        ==> 正在签名数据库 'shorin-arch.db.tar.zst'...
        -> 已创建签名文件 'shorin-arch.db.tar.zst.sig'
        ==> 正在签名数据库 'shorin-arch.files.tar.zst'...
        -> 已创建签名文件 'shorin-arch.files.tar.zst.sig'
        ```

        除了要对数据库文件签名，还要对软件包签名
    
        ```
        gpg --detach-sign --no-armor shorin-contrib-git-r70.ac80b05-1-any.pkg.tar.zst
        ```
        
        >`--detach-sign` 分离式签名，会额外生成 `.sig` 后缀的文件
        
        >`--no-armor` 不使用 ASCII 字符封装

        现在你的目录看上去会是这样：

        ```
         ls -la
        Permissions Size User   Date Modified Name
        lrwxrwxrwx     - shorin 19 6月  22:13  shorin-arch.db -> shorin-arch.db.tar.zst
        lrwxrwxrwx     - shorin 19 6月  22:13 󱧃 shorin-arch.db.sig -> shorin-arch.db.tar.zst.sig
        .rw-r--r--   717 shorin 19 6月  22:13  shorin-arch.db.tar.zst
        .rw-r--r--   566 shorin 19 6月  22:13 󱧃 shorin-arch.db.tar.zst.sig
        lrwxrwxrwx     - shorin 19 6月  22:13  shorin-arch.files -> shorin-arch.files.tar.zst
        lrwxrwxrwx     - shorin 19 6月  22:13 󱧃 shorin-arch.files.sig -> shorin-arch.files.tar.zst.sig
        .rw-r--r--   966 shorin 19 6月  22:13  shorin-arch.files.tar.zst
        .rw-r--r--   566 shorin 19 6月  22:13 󱧃 shorin-arch.files.tar.zst.sig
        .rwxr-xr-x  105k shorin 19 6月  20:45  shorin-contrib-git-r70.ac80b05-1-any.pkg.tar.zst
        .rw-r--r--   566 shorin 19 6月  22:14 󱧃 shorin-contrib-git-r70.ac80b05-1-any.pkg.tar.zst.sig
        ```
        现在需要上传签名后的文件

    - 发布公钥

        把之前生成的公钥也上传到库里，例如 `repo.shorin.xyz/archlinux/shorin-arch.pub`

    - 导入公钥

        使用源的用户要导入公钥。

        ```
        curl -sO https://repo.shorin.xyz/archlinux/shorin-arch.pub
        sudo pacman-key --add shorin-arch.pub
        sudo pacman-key --lsign-key 8ED9ABE61CDBAABAC4B6A694C9218E60C13B4BA8
        ```
        >先用 `curl` 下载公钥，`-s` 静默拉取，`-O（大写字母O）` 使用服务器上的原始文件名作为本地文件名，默认保存位置在当前目录下；
        
        >然后 `pacman-key --add <公钥文件>`；再用 `--lsign-key (local sign key) <UID>`选项

        >可以使用 `gpg --show-keys shorin-arch.pub` 查看公钥的 ID

        上面这个命令会留下一个 `shorin-arch.pub` 文件，可以通过管道符解决这个问题：

        ```
        curl -s https://repo.shorin.xyz/archlinux/shorin-arch.pub | sudo pacman-key --add -
        sudo pacman-key --lsign-key 8ED9ABE61CDBAABAC4B6A694C9218E60C13B4BA8
        ```
        >`--add` 后面的 `-` 代表读取从管道传入的数据

    - 备份密钥对

        > `321备份` 原则，3份数据，2种存储介质，1个异地

        导出私钥

        ```
        gpg --export-secret-keys --armor 8ED9ABE61CDBAABAC4B6A694C9218E60C13B4BA8 > shorin-arch-private-key.asc
        ```

        导出公钥

        ```
        gpg --export --armor 8ED9ABE61CDBAABAC4B6A694C9218E60C13B4BA8 > shorin-arch-public-key.asc
        ```

        复制 `.rev` 文件（吊销凭证），需要彻底吊销密钥的时候就使用该文件

        ```
        cp ~/.gnupg/openpgp-revocs.d/8ED9ABE61CDBAABAC4B6A694C9218E60C13B4BA8.rev ./shorin-arch-revocation.rev
        ```

        导入备份

        ```
        gpg --import <文件名>
        ```

## 自动化

---

# 维护AUR包

建立并推送：

```bash
git clone ssh://aur@aur.archlinux.org/shorin-dms-niri-meta.git
cd shorin-dms-niri-meta
```

```bash
makepkg --printsrcinfo > .SRCINFO
```

```bash
git add PKGBUILD .SRCINFO
git commit -m "Initial commit: Add meta package"
git push
```
