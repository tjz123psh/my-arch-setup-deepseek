# 项目级指令（AGENTS）

本文件是本工作区对 agent 的最高约束，任何会话都必须遵守，优先级高于一般操作惯例。

## 绝对指令一：原始项目只读，禁止越界修改

- **唯一可写范围**：本工作区 `/home/pang/Projects/my-arch-setup-deepseek/` 之内。
- **禁止跨越工作区修改任何其他项目**，特别是：
  - `/home/pang/Projects/my-arch-setup/` —— 原始未完成项目（my-archlinux-setup），它是本新仓库的设计基底，**只允许只读参考**（查看文档、对比文件、定位差异），绝不写入、不执行其 installer、不修改其 git 状态、不清理其未提交改动；
  - `/home/pang/Projects/` 下的任何其他项目（插件、k12-gmail、MD Reader、md-reader-android、qq-agent-bot、rjsupplicant-gui、SystemMaintenance-tui 等）；
  - 任何位于本工作区之外的路径。
- 涉及路径的操作（编辑、复制、删除、git、构建产物、运行脚本）都必须先确认目标路径在本工作区之内。
- 曾随工作区携带的参考源副本 `/home/pang/Projects/my-arch-setup-deepseek/my-arch-setup/` 已按用户要求删除；以后需要参考时，只读查看 `/home/pang/Projects/my-arch-setup/` 原始项目。

## 项目定位与目标

- 本工作区是一个**新启动的私有项目仓库**：GitHub remote `origin` 为 `git@github.com:tjz123psh/my-arch-setup-deepseek.git`（私有）。
- 开发内容沿原始项目 my-archlinux-setup 的既有设计推进（README、docs/ 与 tests/ 中的约定），但**本仓库的整洁性优先**：不把原始项目的历史遗留（未提交改动、嵌套 `.git`、构建产物）混入本仓库。
- 尚未完成的物理主机部署、模块生产就绪（planning/unavailable 项）、硬件验收等事项，先与用户讨论确认范围，再在本工作区实现与验证。
