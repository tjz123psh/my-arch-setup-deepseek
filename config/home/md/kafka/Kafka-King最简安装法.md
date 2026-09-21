# Kafka-King 最简安装法（Arch Linux）

Kafka-King 是开源的 Kafka 桌面客户端（Tauri 打包，界面现代、支持暗色）。官方 Linux 产物是 Ubuntu 的 tar.gz 包，Arch 上要补一个已从官方仓库移除的 webkit2gtk 4.0 才能跑。以下是最简步骤，全部实测可用。

## 1. 下载并解压

```fish
curl -L -o ~/Downloads/Kafka-King-linux.tar.gz \
  https://github.com/Bronya0/Kafka-King/releases/download/v0.46/Kafka-King-v0.46-ubuntu-x64.tar.gz
mkdir -p ~/Applications/Kafka-King
tar -xzf ~/Downloads/Kafka-King-linux.tar.gz -C ~/Applications/Kafka-King/
chmod +x ~/Applications/Kafka-King/Kafka-King
```

> 新版本先看 [releases 页面](https://github.com/Bronya0/Kafka-King/releases) 确认 tag 和文件名，Linux 产物是 `Kafka-King-v<版本>-ubuntu-x64.tar.gz`。

## 2. 为什么需要额外步骤

Kafka-King 的 Linux 版按 **webkit2gtk 4.0 API** 编译（需要 `libwebkit2gtk-4.0.so.37`），而 Arch 官方仓库早已移除 4.0、只剩 `webkit2gtk-4.1`。所以要补：libsoup 2.x（4.0 的运行时依赖）+ 一个 4.0 版本的 webkit2gtk。

## 3. 补依赖（约 5 分钟）

**a) 编译安装 libsoup 2.x（AUR，小包，很快）**

```fish
# 装编译依赖（makepkg 需要 base-devel，一般已装）
~/scripts/desktop/gsudo -- pacman -S --noconfirm samba gtk-doc vala

# 拉 AUR 包编译安装
git clone --depth 1 https://aur.archlinux.org/libsoup.git /tmp/libsoup-aur
cd /tmp/libsoup-aur
makepkg --nocheck --skippgpcheck
~/scripts/desktop/gsudo -- pacman -U --noconfirm libsoup-2.74.3-4-x86_64.pkg.tar.zst
```

**b) 装预编译的 webkit2gtk 4.0（archlinuxcn 仓库的 imgpaste 版）**

```fish
~/scripts/desktop/gsudo -- pacman -S --noconfirm webkit2gtk-imgpaste
```

> 这步是关键捷径：archlinuxcn 有预编译的 webkit2gtk 4.0 二进制，**不用**像 AUR 源码版那样编译 1-3 小时。

**c) 修 libjxl soname 不匹配（当前预编译包按 0.11 编的，系统是 0.12）**

```fish
cd /tmp
curl -sL -o libjxl-old.pkg.tar.zst \
  https://archive.archlinux.org/packages/l/libjxl/libjxl-0.11.2-2-x86_64.pkg.tar.zst
mkdir -p libjxl-old && bsdtar -xf libjxl-old.pkg.tar.zst -C libjxl-old \
  usr/lib/libjxl.so.0.11 usr/lib/libjxl.so.0.11.2 \
  usr/lib/libjxl_cms.so.0.11 usr/lib/libjxl_cms.so.0.11.2 \
  usr/lib/libjxl_threads.so.0.11 usr/lib/libjxl_threads.so.0.11.2
~/scripts/desktop/gsudo -- cp libjxl-old/usr/lib/libjxl*.so.0.11* /usr/lib/
~/scripts/desktop/gsudo -- ldconfig
```

## 4. 验证并启动

```fish
ldd ~/Applications/Kafka-King/Kafka-King | grep "not found"   # 应无输出
~/Applications/Kafka-King/Kafka-King                          # 启动，界面出现即成功
```

首次启动会生成配置 `~/.kafka-king/config.yaml`。添加集群：界面里新建连接，填 `localhost:9092`（对应本机 docker 栈的 broker）。

## 5. 注意（技术债）

- `/usr/lib/libjxl*.so.0.11*` 是从旧包手动提取的，**pacman 不跟踪**。它们与系统 libjxl 0.12 共存、互不影响；要清理直接删掉这些文件即可。
- 上面装的 `libsoup`（2.x）和 `webkit2gtk-imgpaste` 是 AUR/archlinuxcn 包，系统升级后可能与新版依赖再次出现 soname 不匹配（症状：`ldd` 报 `not found`）。重装本文件的 b/c 两步即可修复。
- 如果 archlinuxcn 的 imgpaste 包更新到兼容当前库的版本，第 3-c 步可跳过。

## 6. 备选：完全原生编译（不推荐日常用）

如果不想用预编译包，可编译 AUR 的 `webkit2gtk`（2.50.6，4.0 API）：需要把 PKGBUILD 依赖里的 `libsoup3` 改回 `libsoup`（2.50 这条线就是 libsoup2），然后 `makepkg`，耗时 1-3 小时。装好后就无需第 3-b/c 步。日常使用没必要，除非追求"全源码"洁癖。
