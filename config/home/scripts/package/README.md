# package —— Arch 软件包管理 TUI

## 一、是什么

一组基于 fzf 的软件包管理交互工具，覆盖安装、卸载、降级、残留清理，均有实时预览和颜色区分来源。

## 二、有什么作用

| 脚本 | 作用 |
|---|---|
| `pak` | Flatpak 软件包安装 TUI：模糊搜索 + 多选安装，自动标记已安装项，缓存失效时回退实时拉取 |
| `pacr` | 统一卸载 TUI：同屏混合展示 Pacman/AUR 与 Flatpak，多选后分别用 `paru -Rns` / `flatpak uninstall` 卸载 |
| `pacd` | 软件包降级 TUI：模糊搜索已安装包并集成 `downgrade` 回退版本，动态显示真实来源（官方源 / AUR），带高危依赖警告 |
| `pacrrr` | 残留追踪清理 + 卸载：用 strace 动态追踪软件运行时的文件读写，启发式打分排序找出残留配置，确认后清理并卸载软件 |
| `paru-ui` | paru 包管理 UI：官方源 + AUR 统一搜索安装；AUR 包可选 opencode 按 `share/prompts/aur-review.md` 做 PKGBUILD 安全审查后再装 |
