# 一次性 Btrfs 虚拟机破坏性演练

以下步骤只能在可丢弃的虚拟机中运行，不能在日常系统或唯一备份上执行。测试前创建
可回滚的 libvirt 内部或外部快照，并确保测试磁盘与宿主机真实数据无共享写路径。

## 本机实验环境（历史记录，2026-07-28）

这台一次性实验 VM 已在验收完成后**解除定义并删除已注册的两块 qcow2 测试盘**；内部
快照随域元数据一并删除。下文保留的是已完成演练的证据，不是可继续启动的环境，也不能再执行
其中旧的 `virsh snapshot-list maintenance-btrfs-lab` 命令。

- 原实验域：`maintenance-btrfs-lab`（`qemu:///system`），配置为 4 vCPU、8 GiB 内存、
  24 GiB Btrfs 系统盘和 12 GiB 独立 Btrfs 备份盘。
- 来宾使用 UEFI Arch Linux，`vda2` 为 Btrfs `@`/`@home`，`vdb` 挂载到 `/srv/offsite`。
  来宾脚本目录为 `/home/pang/scripts/maintenance`。
- Arch 安装 ISO 是用户原有安装介质，**没有删除**；以后若需重新演练，应新建一台完全隔离的 VM，
  从本文件的历史场景重新执行，不能把旧测试状态当作备份。
- 本轮源码和当时来宾均已运行 `MAINTENANCE_NO_NOTIFY=1 tests/run`，结果为 **44/44 通过**。

> 清理状态：域定义、快照元数据、两块测试盘、未注册 overlay、libvirt 日志、仓库测试夹具和
> `/tmp` 测试输出均已删除。用户原有 Arch 安装 ISO 被明确保留。

## 已完成的真实演练（2026-07-28）

以下操作确实发生在这台隔离来宾的两块虚拟 Btrfs 磁盘上，而不是只靠命令桩。
退出码、`latest` 链接、挂载/锁状态及归档校验均已在现场复核。

### 深度清理与快照：通过

- 创建了名称仿 btrfs-assistant、但没有可信来源标记的顶级测试子卷；`clean all` 没有删除它。
- 创建 root/home 测试快照并保留 Before 节点；正常 quicksave 快照被清理后，重新创建 root/home 快照成功。
- 用独立进程组在清理过程中发送 `SIGINT`：命令以中断状态退出，临时顶级挂载、临时目录和维护锁都已释放。
- 这验证了脚本的 trap/锁释放路径；不代表可以在日常系统跳过确认或备份。

### 异盘备份、中断与发布：通过

- 在 `/srv/offsite` 的独立 `vdb` 上生成至少两套真实 `offsite-backup` 集合，`--check` 通过。
- 分别在 HOME 归档、SHA256 校验、`latest` 发布阶段注入中断/失败；每次旧 `latest` 保持不变，
  新集合不发布，隐藏 staging 和临时 HOME Snapper 快照均被清理，旧集合仍可校验。
- user timer 在目标未挂载时按条件跳过；重新挂载后实际生成新集合。目标不可写时会失败并保留旧 `latest`。
- 已额外覆盖两种不可写路径：已有备份目录无法写标记、以及无法新建本机备份目录；二者均输出受控中文错误，
  不再裸露 shell 的 `Permission denied`。

### 恢复与迁移包：通过（HOME 合并）

- 对真实异盘集合和独立迁移包都运行了 `backup-restore` 预览；只生成计划，不修改 HOME。
- 真实 `--apply-home --yes` 恢复后，归档内修改的文件恢复；归档外新增文件保留；覆盖前文件位于 rollback 目录。
- 注入 `rsync` 中途失败时返回非零，已产生的 rollback 保留、staging 清理、维护锁释放。
- 在 `vdb` 上真实生成了独立 `migration-pack`；归档、清单内容、SHA256SUMS 和所有权标记验证通过，
  其恢复计划包含 6 个预览文件。未配置 fish/opencode 私密文件会显示为“未包含且正常”，不再误显示“缺失”。

### 真实 root 子卷恢复、GRUB 启动与回退：通过

- 从 `clean-install-20260728` 重开后，在 `/etc` 写入 `snapshot-state` 标记，使用 `quicksave` 创建
  root #1；随后改为 `post-snapshot-mutation` 并新建只存在于恢复后的变更文件。
- 来宾中的 `btrfs-assistant-bin` 实际会段错误（`btrfs-assistant -l` 返回 139），普通 `quickload`
  预检按设计停止，未执行恢复。随后实际执行
  `quickload -n -c root -d native-fallback-integration-20260728 --native-root-fallback`：它验证
  `/dev/vda2[/@]` 与 `subvol=/@`，将 root #1 克隆为新 `@`，旧根保留为
  `@quickload-pre-20260728T204542-617`，然后从原 GRUB 配置重启。
- 重启后活动根为 `/dev/vda2[/@]`、subvolume ID 264；标记回到 `snapshot-state`，后创建文件不存在。
  同时验证新 `/.snapshots` 是 Btrfs 子卷（ID 265），`snapper -c root list` 正常，且 `quicksave` 能创建
  新快照 #1。这覆盖了嵌套 `/.snapshots` 不会随 root 子卷快照自动带入这一隐藏边界。
- 接着在这个恢复后的 root 上实际运行 `quickload -n -c root --native-root-rollback latest`；即使此前
  曾模拟 Snapper 列表不可用，回退路径只验证顶级子卷，不依赖 Snapper 枚举。它保留恢复根为
  `@quickload-rejected-20260728T204625-690`，换回旧根后第二次从 GRUB 启动成功。
  活动根重新是 ID 256，`post-snapshot-mutation` 和后创建文件重新出现；两次恢复/回退启动的 boot ID
  均不同。此前的恢复根仍可供取证。
- 本轮复验（21:02–21:04）又从回退后的旧 root 创建 root #2，写入第二次变更后执行原生恢复：新
  `@` 的 ID 为 268、启动 ID 为 `11cf552f-4817-4626-b897-f5165ead31e3`，第二次变更消失，且
  `/.snapshots` 通过 `btrfs subvolume show`，恢复后 `quicksave` 成功新建快照。再用
  `--native-root-rollback latest` 回退后，启动 ID 变为 `e3c5ae4f-3f25-4c60-ab12-f234aebcab74`，
  活动根重回 ID 256、第二次变更重新出现，恢复根保留为
  `@quickload-rejected-20260728T210441-804`。
- 因此已验证：外部 btrfs-assistant 失败会安全停止、原生 root 恢复可实际启动、恢复后 Snapper 可再次
  建立快照，以及受控回退可实际启动；不是命令桩或临时挂载测试。

### Scrub 与存储状态：通过

- 已实际启用 root 与 `/srv/offsite` 的每月 `btrfs-scrub@*.timer`，并完成两块虚拟盘的 scrub。
- `btrfs scrub status -R`、Btrfs device stats 和 `btrfs-scrub --status --strict` 均为零错误并成功返回。
- 修复并实测普通用户读取 `/var/lib/btrfs` 历史结果时自动使用只读 sudo；`storage-health` 也复用该权限，
  不再把成功 scrub 误报为查询失败。
- 虚拟 `virtio` 磁盘不提供 SMART 是实验环境限制：`storage-health --strict` 因两条 SMART 注意返回 1，
  Btrfs/Scrub 部分仍为健康；这不是物理 NVMe 检测结论。

### 只读检查与更新查询：通过

- `post-update-check --strict` 在来宾中为 8 正常、0 注意、0 缺失。
- 非 TTY 调用 `checkallupdates` 现在明确返回 2 并提示使用 `--refresh`，不再把 fzf 的
  `inappropriate ioctl for device` 当作成功。
- 真实 `--refresh` 最初发现来宾缺少 `fakeroot`（`checkupdates` 的实际可选依赖）；已添加明确诊断、
  将它纳入 `recommend-check`，并仅在来宾安装该 0.08 MiB 依赖后复测成功。
- `boot-check` 在虚拟 UEFI 环境会提示 bootctl/fallback loader 与 os-prober；`gpu-check` 会提示 virtio
  显卡缺少 Mesa/Vulkan 工具。这些是最小虚拟机环境差异，不应直接复制为日常实机故障。

## 仍需单独演练的边界

1. **真实硬件故障**：虚拟磁盘不能验证 NVMe SMART、温度、介质错误和断电后的物理一致性；实机仍需要
   定期 scrub、SMART 与一块独立物理备份盘。
2. **完整在线系统升级**：本来宾没有 paru/yay，`sysup` 会按设计拒绝缺少 AUR 助手；其成功、密钥环失败、
   Flatpak 失败、GRUB 与更新后检查的控制流已由 `tests/run` 夹具覆盖。若要跑真实事务，先从干净快照启动，
   安装并审查 AUR helper，再运行 `sysup --yes`。
3. **外置盘拔插/文件系统损坏**：已验证未挂载和不可写目标，未模拟硬件拔除或损坏的 Btrfs；这类试验只能在
   额外可丢弃介质上进行。
4. **btrfs-assistant 本体**：当前来宾的包在任何 `-l`/`-r` 前都会段错误；`quickload` 已安全拒绝继续，
   但要用它完成自动恢复，仍需修复或替换该外部恢复后端，不能把手工 Btrfs 演练当作该程序已经可用。

## 后续如需重新演练

1. 新建独立、可丢弃的 UEFI Arch Btrfs VM；系统盘和异盘目标都不能映射宿主用户数据。
2. 在首次写入前创建新的关机快照；运行 `MAINTENANCE_NO_NOTIFY=1 tests/run`，并保存
   `findmnt`、`btrfs subvolume list`、备份 SHA256 和启动 ID。
3. 任何破坏性验证失败，都销毁该新 VM 并从新快照开始；不要在日常系统、唯一备份或本文件所记的
   已删除实验域上补测。

## 清理完成状态

本轮一次性 VM 的域、快照元数据、基础盘、未注册 overlay、日志、仓库测试夹具和临时输出均已删除；
未删除维护脚本源码或 `/home/pang/Public/镜像文件/archlinux-2026.07.01-x86_64.iso`。
