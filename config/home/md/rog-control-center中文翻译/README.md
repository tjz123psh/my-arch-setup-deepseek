# rog-control-center 中文翻译

## 背景

rog-control-center 是 ASUS ROG 笔记本控制工具（asusctl）的 GUI，基于 Slint UI 框架，使用 gettext i18n 做国际化。

官方仓库有上游 zh_CN PO 文件（2024-06-09），但版本落后，缺少大量新增字符串的翻译。本补丁基于上游 PO 合并了全部新增条目，并修正了 Slint 运行时查找所需的 `msgctxt` 上下文映射。

## 已知限制

1. **GPU 模式下拉选项**（集成/极致/混合）：Rust 代码 `setup_gpu.rs` 用 `SharedString::from("Integrated")` 硬编码后通过 `set_gpu_modes_choises()` 覆盖了 Slint 的 `@tr()` 翻译结果，MO 文件无法修复。需要改源码重建。
2. **About 页面**：所有字符串硬编码英文，没有使用 `@tr()`，MO 文件无法覆盖。属于上游 bug。

## 文件说明

| 文件 | 用途 |
|------|------|
| `rog-control-center.mo` | 编译好的 gettext 翻译文件（180 条） |
| `rog-control-center.desktop` | 带 `RUST_TRANSLATIONS=1` 的 desktop 启动文件 |

## 安装步骤（重装系统后）

```bash
# 1. 安装 rog-control-center
sudo pacman -S rog-control-center

# 2. 复制 MO 翻译文件
sudo cp rog-control-center.mo /usr/share/locale/zh_CN/LC_MESSAGES/

# 3. 修改 desktop 文件，添加 RUST_TRANSLATIONS 环境变量
#    （每次 pacman -S 升级后都需重新执行此步）
sudo sed -i 's|^Exec=|Exec=env RUST_TRANSLATIONS=1 |' /usr/share/applications/rog-control-center.desktop
```

## 关键技术细节

- **必须设置 `RUST_TRANSLATIONS=1`**：不设的话 Slint 会尝试从编译时路径加载 MO（不存在），翻译完全不生效。
- **Slint 自动添加组件名作为 msgctxt**：例如 `@tr("Armoury settings")` 在 `PageSystem` 组件内，运行时查找 key 是 `PageSystem\x04Armoury settings`，PO 文件中必须用 `msgctxt "PageSystem"` 包裹。
- **应用单实例**：旧进程如果没有 `RUST_TRANSLATIONS=1`，会阻止新进程启动。杀旧进程后才能用新配置启动。

## 重新编译（可选，修复 GPU 模式下拉）

如果需要翻译 GPU 模式下拉选项，需要改源码重建：

```bash
# 从 AUR 克隆
paru --getpkgbuild rog-control-center
cd rog-control-center

# 在 prepare() 中加入 sed 补丁
# sed -i \
#   -e 's/SharedString::from("Integrated")/SharedString::from("\u96c6\u6210")/' \
#   -e 's/SharedString::from("Ultimate")/SharedString::from("\u6781\u81f4")/' \
#   -e 's/SharedString::from("Hybrid")/SharedString::from("\u6df7\u5408")/' \
#   rog-control-center/src/ui/setup_gpu.rs

makepkg -si
```

编译约需 15-20 分钟（Rust 796 个 crate）。
