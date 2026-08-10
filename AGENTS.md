# 项目级指令（AGENTS）

本文件是本工作区对 agent 的最高约束，任何会话都必须遵守，优先级高于一般操作惯例。

## 绝对指令一：工作区边界，禁止越界修改

- **唯一可写范围**：本工作区 `/home/pang/Projects/my-arch-setup-deepseek/` 之内。
- **禁止跨越工作区修改任何其他项目**，特别是：
  - `/home/pang/Projects/` 下的任何其他项目（my-archlinux-setup、插件、k12-gmail、MD Reader、md-reader-android、qq-agent-bot、rjsupplicant-gui、SystemMaintenance-tui 等）；
  - 任何位于本工作区之外的路径。
- 涉及路径的操作（编辑、复制、删除、git、构建产物、运行脚本）都必须先确认目标路径在本工作区之内。

## 绝对指令二：严格禁止破坏系统

- **严禁破坏宿主或任何测试系统的行为**：不得卸载/降级宿主软件包、不得启停/修改宿主服务、不得改动宿主内核模块（vmmon/vmnet/kvm 等）、不得修改宿主 GRUB/引导、不得改动宿主网络、不得删除/移动宿主虚拟机（KVM domain、qcow2、XML、快照）或 VMware 虚拟磁盘。
- **宿主 KVM/VMware 资产视为用户数据**：即使它们"看起来是项目遗留"，也不得清理、删除或重命名；KVM 历史文档在本仓库内归档到 `docs/archive/`，但绝不触碰宿主实际 VM 文件。
- **工作区外 VM 操作（启动/快照/revert/guest 安装）仅在有用户明确授权时执行**，且只针对用户指定的专用测试 VM；未经指定不得自行选择 VM。授权范围内也禁止 hard stop、删除虚拟磁盘、修改真实 VMX、在命令行/日志/仓库保存 guest 密码。
- **凭据纪律**：不读取、不打印、不记录任何密钥/token/密码值；凭据检查只报告位置、权限与存在性。宿主 Fish 中的凭据赋值文件严禁原样同步进本公开仓库（同步前先轮换或改为 private-env.fish 引用）。
- 测试用 sudo/guest 密码只用于非交互执行，不写入文档、checkpoint、日志或 git 历史。

## 项目定位与目标

- 本工作区是一个**个人专用的 Arch Linux 恢复工具仓库**：GitHub remote `origin` 为 `git@github.com:tjz123psh/my-arch-setup-deepseek.git`（当前为**公开**仓库；若你希望私有，请在 GitHub Settings 中自行修改）。
- 目标：重装 Arch、完成手工基础安装（分区/GRUB/首次启动/联网）后，一条命令恢复 ASUS 工作站的完整桌面环境（Niri/Hyprland、软件包、AUR、个人配置与系统服务）。
- 设计原则：**简单优先、面向个人**。安装器是 strap.sh + install.sh + scripts/ 的分步流程，直接读取 manifests 中精简的清单；不做审阅引擎、不做哈希 pin、不做模块生产就绪分级等工程化机制。
- 数据资产（config/ 配置、third_party/aur/ recipe、manifests 清单）是仓库的核心价值，修改须保持安装器可读。
- **增改门禁**：任何增改提交前必须运行 `./check-extend.sh`（一键总检：bash 语法/shellcheck/清单一致性/配置内容语法/recipe 双向引用/secret scan/README 数字/行为测试），任一节失败即禁止提交。改 manifests schema、config-mappings scope、DESKTOP_ENV 过滤或安装器核心脚本主流程属红线改动，必须 VM 重验并换新 TEST_ID（按 clean-baseline 规则，旧 PASS 自动失效）。
