# 项目级指令（AGENTS）

本文件是本工作区对 agent 的最高约束，任何会话都必须遵守，优先级高于一般操作惯例。

## 绝对指令一：工作区边界，禁止越界修改

- **唯一可写范围**：本工作区 `/home/pang/Projects/my-arch-setup-deepseek/` 之内。
- **禁止跨越工作区修改任何其他项目**，特别是：
  - `/home/pang/Projects/` 下的任何其他项目（my-archlinux-setup、插件、k12-gmail、MD Reader、md-reader-android、qq-agent-bot、rjsupplicant-gui、SystemMaintenance-tui 等）；
  - 任何位于本工作区之外的路径。
- 涉及路径的操作（编辑、复制、删除、git、构建产物、运行脚本）都必须先确认目标路径在本工作区之内。

## 项目定位与目标

- 本工作区是一个**个人专用的 Arch Linux 恢复工具仓库**：GitHub remote `origin` 为 `git@github.com:tjz123psh/my-arch-setup-deepseek.git`（当前为**公开**仓库；若你希望私有，请在 GitHub Settings 中自行修改）。
- 目标：重装 Arch、完成手工基础安装（分区/GRUB/首次启动/联网）后，一条命令恢复 ASUS 工作站的完整桌面环境（Niri/Hyprland、软件包、AUR、个人配置与系统服务）。
- 设计原则：**简单优先、面向个人**。安装器是 strap.sh + install.sh + scripts/ 的分步流程，直接读取 manifests 中精简的清单；不做审阅引擎、不做哈希 pin、不做模块生产就绪分级等工程化机制。
- 数据资产（config/ 配置、third_party/aur/ recipe、manifests 清单）是仓库的核心价值，修改须保持安装器可读。
