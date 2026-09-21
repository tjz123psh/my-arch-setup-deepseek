# Zed 编辑器（汉化版 ZedG）安装与使用说明

> 记录日期：2026-08-16 · 系统：Arch Linux x86_64
>
> 本机**只装汉化版 ZedG**（来自 [x6nux/zed-globalization](https://github.com/x6nux/zed-globalization)），不装官方原版：汉化版本身就是一个完整的 Zed 编辑器（界面中文），官方版还要多占约 335M 磁盘，没有必要。

---

## 1. 安装了什么

| 项目 | 汉化版 ZedG |
|------|-------------|
| 来源 | GitHub Release 预编译包 |
| 版本 | v1.15.0（基于同版本 Zed） |
| 界面语言 | 中文 |
| 启动命令 | `zedg` |
| 桌面入口 | zedg.desktop |
| 磁盘占用 | 约 418M |

> 注意：官方 Arch 包的启动命令是 `zeditor`（真实二进制位于 `/usr/lib/zed/zed-editor`），汉化版是 `zedg`。本机只装了汉化版，终端启动直接输 `zedg`。

---

## 2. 安装步骤（手动）

```bash
# 1. 下载（版本号去 Releases 页面看最新 tag）
cd /tmp
curl -fsSLO https://github.com/x6nux/zed-globalization/releases/download/v1.15.0/zedg-zh-cn-linux-x86_64-v1.15.0.tar.gz
curl -fsSLO https://github.com/x6nux/zed-globalization/releases/download/v1.15.0/sha256sums.txt

# 2. 校验 sha256（v1.15.0 的值为 b9d798e1f8e659d54a0df43d0914221f8b4e0a5ff854ed1e51b0aedcad1215d1）
grep zedg-zh-cn-linux-x86_64 sha256sums.txt
sha256sum -c <(grep zedg-zh-cn-linux-x86_64 sha256sums.txt)

# 3. 解压到系统根目录（包内布局是 ./usr/...，对应 /，与 deb 安装位置一致）
sudo tar -xzf zedg-zh-cn-linux-x86_64-v1.15.0.tar.gz -C /

# 4. 刷新桌面缓存（让启动器/图标生效）
sudo update-desktop-database /usr/share/applications
sudo gtk-update-icon-cache -f /usr/share/icons/hicolor
```

安装的文件：

```
/usr/bin/zedg                                  # 启动命令（436M 完整二进制）
/usr/libexec/zedg                              # 辅助执行文件
/usr/share/applications/zedg.desktop           # 桌面入口
/usr/share/icons/hicolor/512x512/apps/zedg.png
/usr/share/icons/hicolor/1024x1024/apps/zedg.png
```

> 提示：下载中断可以用 `curl -fSL -C -` 断点续传（本机 2026-08-16 装 v1.15.0 时中断过一次，续传成功）。

---

## 3. 验证

```bash
zedg --help   # 输出用法说明（无 --version 参数）
```

---

## 4. 更新

ZedG 的 GitHub Actions 流水线会自动扫描 Zed 上游新版本 → 翻译 → 构建 → 发布，通常**当天或隔天**发布同版本号（历史记录显示延迟 0–1 天），不会落后，但**已安装的 Linux 版不会自动更新**，需要手动：

```bash
# 以升级到 vX.Y.Z 为例（替换版本号）
cd /tmp
curl -fsSLO https://github.com/x6nux/zed-globalization/releases/download/vX.Y.Z/zedg-zh-cn-linux-x86_64-vX.Y.Z.tar.gz
curl -fsSLO https://github.com/x6nux/zed-globalization/releases/download/vX.Y.Z/sha256sums.txt
sha256sum -c <(grep zedg-zh-cn-linux-x86_64 sha256sums.txt)
sudo tar -xzf zedg-zh-cn-linux-x86_64-vX.Y.Z.tar.gz -C /
sudo update-desktop-database /usr/share/applications
sudo gtk-update-icon-cache -f /usr/share/icons/hicolor
```

---

## 5. 卸载

```bash
sudo rm /usr/bin/zedg /usr/libexec/zedg
sudo rm /usr/share/applications/zedg.desktop
sudo rm /usr/share/icons/hicolor/512x512/apps/zedg.png
sudo rm /usr/share/icons/hicolor/1024x1024/apps/zedg.png
sudo update-desktop-database /usr/share/applications
```

---

## 6. 说明事项

- **不装官方原版**：汉化版 ZedG 本身就是一个完整的 Zed 编辑器（界面中文），官方 Arch 包启动命令是 `zeditor`，占约 335M，本机不需要。
- **汉化版无自动更新**：Linux tar.gz 安装方式没有自动更新机制（README 仅对 macOS Homebrew 和 Windows Scoop 提供自动更新）。
- **其它平台**：仓库同时发布 deb / rpm / macOS dmg / Windows 包，Linux 下 tar.gz 与 deb 安装效果相同（同为 `/usr/bin/zedg` 等位置）。
