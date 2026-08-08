# 下载模式实验 checkpoint

更新时间：2026-08-08

## 当前目标

在不改主安装器、不改宿主系统、不操作 VM 的前提下，确认安装下载慢点，并形成可审查的候选下载模式。

## 已完成证据

- pacman native/Xfer 本地仓库对照：native p=3/5 并发 3；Xfer p=3/5 并发 1；
- native stall：服务器 12 秒零字节，约 10 秒非零低速超时；
- 官方/archlinuxcn HEAD、256 KiB 与 1 MiB Range 只读探测；
- 原子下载故障注入：20/20 PASS，两轮重复；
- AUR 独立 source 队列模型：jobs=3 最大并发 3，约 2.7x（仅模型）；
- 现有 cache helper 静态审计：`defects_confirmed`，不是健康 PASS；
- 主项目行为测试 36/36、清单对账、FlClash、Neovim：PASS；
- lab gitleaks：PASS；全仓 Bash syntax：PASS。

## 失败/不可用/未执行

- 独立 reviewer 多次等待超时后关闭：`UNAVAILABLE`；
- ShellCheck 主工作树仍非全绿，至少存在 `shorin-screenrec-menu` 的 SC1087；
- 真实目标网络 `pacman -Sw`、真实 AUR 全链路、VMware 大文件恢复、VM/仿物理/物理实战：本实验未执行；
- 主安装器没有合并任何下载补丁。

## 安全状态

- 宿主 `/etc/pacman.conf` 仍为 native downloader，`ParallelDownloads=5`、无 active XferCommand；
- 未安装/删除包，未改服务/GRUB/网络/内核模块；
- 未启动/停止/快照/revert/修改/删除任何 KVM 或 VMware 资产；
- 没有读取、存储或输出凭据值。

## 下一动作（需要用户批准）

先向用户展示第一小步 dry-run：仅停止 `scripts/01-mirror.sh` 默认写入 XferCommand，并补相应回归；不得顺便修改同步、AUR、服务或宿主配置。用户明确批准前保持只读。

完整依据：`FINAL.md`。下一模型提示词：`NEXT-STEP-PROMPT.txt`。
