# 交接文档：`~/scripts/maintenance` 维护脚本

本目录是一套 Arch Linux 终端维护脚本，由 `term-menu`（fzf 主菜单）统一串起。目前有
23 个顶层可执行入口、2 个共享库和 `tests/run` 回归测试入口。脚本不只共享 UI，也共享
配置解析、维护锁、菜单返回约定和退出码语义。

截至 2026-07-28，更新、清理、快照、迁移、异盘备份、恢复、Scrub 和只读诊断已经完成
一轮故障路径审查。本文档给**下次接手的人一套可直接照做的维护方案**；用户使用说明见
`README.md`，真实破坏性验收步骤见 `tests/DESTRUCTIVE-VM.md`。

---

## 一、先读这段：设计铁律（改任何脚本前必须遵守）

1. **所有脚本 `source lib/ui.sh`**。核心视觉：薰衣草(`UI_C_LAVENDER`)圆角框 + 紫(`UI_C_MAUVE`)标题 + Catppuccin 色板。
   徽章统一 `ui_info/ui_ok/ui_warn/ui_err/ui_die`；卡片用 `ui_panel_open/line/kv/stat/raw/close`；横幅 `ui_banner`。
2. **列对齐只用 `ui_pad STR WIDTH`**（按显示列右填充，内部剥 ANSI）。**禁用 `printf %-Ns`**（按字节填充，中文必错位）。
3. **对齐锚点只能用 ASCII 和纯 CJK**（`ui_dwidth` 对二者精确计宽）。**绝不用 Nerd Font 图标做对齐锚点**——
   私有区图标 `ui_dwidth` 按 1 列估算、终端常渲染成 2 列，换字体就错位。这是历史上多个 bug 的共同根因。
4. **命令原始输出（lsblk/nmcli/snapper/reflector 等）一律用 `ui_panel_raw` 包进卡片**，不要裸透传。
5. **修改前先读现场**：该脚本现有函数、文案变量、set 选项、trap。不顺手重构无关代码，不回退用户已有改动。
6. **查询失败不能等同于结果为空**。检查命令失败时必须显示“无法检查”并返回非零；不能写成“未发现问题”。
7. **部分失败不能显示整体成功**。允许继续执行后续步骤，但必须累计失败状态，最终返回非零。禁止用无记录的
   `|| true` 吞掉关键查询、校验、发布、清理和回滚错误。
8. **修改系统状态的入口必须持有共享维护锁**。锁继承只能通过有效 FD 验证，不能只相信环境变量。
9. **菜单 Esc/取消直接回父菜单**。子工具用退出码 `10` 或 `130` 表达返回请求；父菜单不得再显示一次
   “按任意键返回”。真正执行完成或失败的结果页才等待按键。
10. **菜单导航必须连续**。所有 fzf 选择器启用 `--cycle`，上下键可跨越首尾循环；叶子功能结束或取消后，
    父菜单要聚焦刚才执行的条目，不能每次重开都跳回第一项。`term-menu` 的输入来自管道，恢复焦点必须用
    `load:pos(N)`（等待候选列表加载完成），**不能**用 `start:pos(N)`；后者触发得过早，会稳定地回到第一项。
    未经 `choose_menu` 的独立选择器（Scrub 目标/操作、异盘备份定时器、恢复备份集合等）也必须显式保留
    `--cycle` 和“↑↓ 循环移动”的提示。

## 二、必须区分的三类"看起来像裸色"的代码（别误改）

改之前先判断属于哪类，**后两类是正确的，改了会坏**：

| 类型 | 特征 | 处理 |
|---|---|---|
| 真·裸输出 | 脚本自己的日志用 `printf '\033[..'` 或 `%-Ns` | **该改**，换 ui.sh 组件 / `ui_pad` |
| fzf 数据流 | `C_*` 变量喂给 `fzf --ansi`（如 `checkallupdates`） | **保留**，那是数据不是日志 |
| fzf preview | `bash $SELF --preview` 里的 `\033[36m`（如 `migration-pack`/`term-menu` 的 `print_preview`） | **保留**，preview 跑在非 TTY 管道，ui.sh 颜色会自动关，必须用裸 ANSI |

## 三、下次维护标准流程（照做）

### Step 0 — 环境确认
```bash
cd /home/pang/scripts/maintenance
find . -maxdepth 2 -type f -perm -u+x -printf '%P\n' | sort
# term-menu 靠 PATH 和 command -v 定位子命令；PATH 含 $HOME/scripts/maintenance
```

### Step 1 — 全目录健康检查（每次必跑）
```bash
cd /home/pang/scripts/maintenance
find . -maxdepth 2 -type f -perm -u+x -exec bash -n {} +
find . -maxdepth 2 -type f -perm -u+x -exec shellcheck -x {} +
MAINTENANCE_NO_NOTIFY=1 tests/run
git diff --check
```
当前预期：Bash 语法通过、全项目 ShellCheck 无告警、`tests/run` 为 **49/49 通过**、
`git diff --check` 无空白错误。不要把既有告警当作可接受基线；新增或重新出现的告警都要处理。

### Step 2 — 按需求改（改哪个读哪个，遵守第一、二节）

### Step 3 — 验证（按脚本风险选，见第四节）

### Step 4 — 更新本文档的"变更记录"（第六节），写清改了什么、怎么验证的

## 四、验证方法（关键：交互 + sudo 无法在非 TTY 自动跑）

| 脚本类型 | 能自动验证的 | 必须人工在 TTY 跑的 |
|---|---|---|
| 纯只读（check 类、状态查询、列表和预览） | 直接运行并核对输出、严格退出码及查询失败路径 | 需要提权读取时，在真实菜单 TTY 确认只读 sudo 提示 |
| 有隔离桩覆盖的写操作 | `tests/run` 验证命令分发、失败累计、锁、trap、原子发布和回滚 | 在真实 TTY 检查确认词、提示和菜单返回路径 |
| 系统写操作（更新、镜像、清理、缓存、Scrub timer） | 语法、ShellCheck、桩测试 | 由用户在可恢复环境执行完整流程 |
| 高危数据路径（深度清理、快照恢复、HOME 恢复、备份中断） | 静态、桩测试、只读 `--check`/计划模式 | **只在一次性 Btrfs VM 按 `tests/DESTRUCTIVE-VM.md` 演练** |

- 故障注入统一放进 `tests/run`，用临时 HOME、PATH 命令桩和独立状态目录，不依赖真实系统状态。
- 改完清理临时文件。不要在日常系统上代跑升级、删除、恢复、Scrub 等破坏性路径。

## 五、各模块现状速查（下次判断“要不要动”的依据）

- `lib/ui.sh` — UI、显示宽度、确认、共享维护锁、通知和菜单退出码。改动前检查所有调用方。
- `lib/config.sh` / `config.example` — 集中配置解析。只接受白名单 `KEY=VALUE`，不能改成 `source` 用户配置。
- `term-menu` — fzf 主菜单。菜单项、友好名和 preview 要同步；新功能说明应占用右侧预览空间，按“用途、何时用、
  是否改系统、注意事项”写给没有接触过该工具的用户。Esc/取消必须直接回父菜单。
- `checkallupdates` / `sysup` / `post-update-check` — 在线检查、完整升级和升级后只读复核。Pacman 更新不能做单包
  部分升级；仓库、AUR、Flatpak 查询失败必须与“无更新”区分。`sysup` 关键预检、锁和 inhibit 不能绕过。
- `mirror-update` — reflector 生成后先校验再安装；备份多代轮换只匹配本工具严格命名的备份，不能覆盖或删除用户文件。
- `clean` / `cache-clean` — 所有步骤累计失败并最终返回非零。深度清理只自动删除来源可证明的快照/备份；来源不明
  的 Btrfs 子卷只能报告。AUR 缓存路径必须拒绝越界和符号链接。
- `quicksave` / `quickload` — root/home 快照使用批次事务标识；所有 Snapper 数据使用 CSV。默认恢复前探测
  btrfs-assistant，查询失败不得显示为空列表。显式 `--native-root-fallback` 是仅限顶级 `@` 的 root 兜底：
  验证 `subvol=` 启动选择、克隆、保留旧 root、重建新 `/.snapshots` 后重启；`--native-root-rollback latest`
  可换回保留 root，且不依赖 Snapper 列表。恢复、删除和临时挂载的 trap/锁路径属于高风险代码。
- `migration-pack` — v2 使用严格、非可执行的 profile 与先行 `--plan`；默认原样打包完整 `.config`、`.ssh`、
  Projects、Obsidian、指定图片、包/服务清单、用户 unit 定义和系统审查项。`secret` 仅是显式排除内容的例外；默认
  归档含私钥/凭据，必须只放在用户受保护存储。`--home-root` 与 `--metadata-only` 用于异盘备份的冻结 HOME 去重；
  保留 v1 校验兼容，staging、SHA256、所有权标记和原子发布任一失败都必须非零。
- `offsite-backup` — 仅接受不同物理磁盘或远端挂载，从临时只读 HOME 快照归档；集合完整校验后原子发布并更新
  `latest`。临时快照、遗留回收、所有权标记和严格轮换规则不能弱化。
- `backup-restore` — 默认只生成恢复计划；显式 `--apply-home` 才合并 HOME，且保留 rollback。软件包和服务只输出
  清单，不自动安装或启用。
- `offsite-backup-schedule` — systemd user service/timer。目标未挂载时跳过，安装/禁用/回滚失败必须准确返回。
- `btrfs-scrub` / `storage-health` — Scrub 状态与管理、SMART JSON、Btrfs device stats、空间和 timer。只读查询失败
  与“尚无结果”分开；写操作必须确认并持锁。
- `boot-check` / `pacnew-check` / `hw-doctor` / `gpu-check` / `log-check` / `recommend-check` / `check-battery` —
  诊断入口。交互 TTY 可请求只读 sudo；`--strict` 下注意、缺失或查询失败返回非零。GPU 统计必须按实际检查项计数，
  不能显示没有意义的 `0 正常`。
- `tests/run` — 49 个隔离回归场景，覆盖失败查询、更新依赖、锁伪造、Esc 契约、快照事务、迁移/备份原子性、恢复保护、
  清理失败、定时 unit 和严格退出码。v2 还覆盖严格 profile、显式 secret 引用、完整默认内容、独立 v2 恢复计划及
  异盘备份使用冻结 HOME 且不重复 HOME 内容。新增故障修复必须先补可复现测试。

## 六、变更记录（倒序，最新在上）

### 2026-07-29（迁移包 v2）
- 新增严格、非可执行的 v2 profile 和 `migration-pack --plan`；默认完整归档 `.config`、`.ssh`、Projects、Obsidian、
  指定图片、用户 unit、环境文件和命令入口，提供 `migration-profile.example` 供审查后收窄范围。
- v2 生成结构化 `payload/`、`packages/`、`services/`、`system/`、`secrets/references.tsv` 与全量校验和；默认原样保存
  选定内容，`secret` 仅用于明确改为引用的例外。`backup-restore` 同时读取 v1/v2，仍只生成恢复计划。
- `offsite-backup` 将冻结的 HOME snapshot 作为 `--home-root` 传给迁移包，并使用 `--metadata-only` 防止该集合中的
  迁移资料重复归档完整 HOME。回归测试为 49/49，涵盖 profile traversal、完整默认内容、显式 secret、冻结来源和恢复计划。

### 2026-07-28（本轮资源收尾）
- 删除一次性 `maintenance-btrfs-lab` 域、全部快照元数据和两块已注册基础测试盘；仓库 `.vm-fault-bin`、
  本轮 `/tmp` 结果页/日志/锁文件均已删除，用户原有 Arch ISO 保留。虚拟机验收记录改为历史文档。
- 最后约 98 MiB 的 root/libvirt-qemu overlay 与 libvirt 日志已通过系统管理员认证删除；没有遗留
  `maintenance-btrfs-*` 测试盘、VM 定义、快照元数据或本轮 `/tmp` 输出。

### 2026-07-28（真实 Btrfs VM 破坏性验收 + 二次故障修复）
- **真实 root 恢复闭环**：从干净基线创建 root #1 快照并故意修改 `/etc`，在 Btrfs 顶级挂载点将该快照的
  可写克隆换为 `@` 后，按原 GRUB/fstab 重启成功；恢复后标记回到快照内容、后创建文件消失、GRUB 解析通过。
  再将保留的原根换回 `@` 并第二次重启，修改重新出现，恢复根仍保留取证。这是实际 root 子卷恢复与回退，
  不是命令桩。`tests/DESTRUCTIVE-VM.md` 记录 subvolume ID、boot ID 和边界。
- **外部后端状态**：同一来宾的 `btrfs-assistant-bin` 真实返回 SIGSEGV/139；`quickload` 预检如设计般
  停止且不执行恢复。现新增显式 `quickload --native-root-fallback`：仅限 `-c root` 和顶级 `@` 布局，
  从 Snapper root 快照创建新 `@`、保留旧 `@quickload-pre-*`、重启；已在真实 VM 恢复后启动成功。
  它不替代 btrfs-assistant 的 HOME/多子卷恢复，也绝不自动启用，必须由用户显式选择。
- **真实演练完成**：在独立 `vda`/`vdb` Btrfs 虚拟磁盘上实际完成深度清理与 SIGINT 清理、异盘备份三阶段
  中断、timer 挂载/失败路径、HOME 合并恢复/rsync 回滚、迁移包生成与恢复预览、Scrub 和快照恢复失败防护。
  精确证据与其余未验证边界见 `tests/DESTRUCTIVE-VM.md`；不要再把整套演练写成“仅基线”。
- **异盘备份不可写路径**：`mkdir -p "$DEST"` 原先会因 `set -e` 直接输出裸 `Permission denied`；现已把
  新建备份目录失败和写所有权标记失败都转换为受控错误，并在真实来宾与回归夹具中复测，旧 `latest` 不变。
- **迁移包可读性**：缺少可选 fish/opencode 私密文件时不再画成“缺失”错误；改为“来源未配置时正常”，
  仍保留已有但为空/损坏文件的校验失败语义。
- **非交互更新列表**：没有 TTY 时不再运行 fzf 后把 ioctl 错误吞成 0；明确返回 2 并指向 `--refresh`。
  同时检测 `checkupdates` 所需的 `fakeroot`，并将它纳入 `recommend-check`，避免只显示难理解的英文 stderr。
- **Scrub 历史权限**：`storage-health` 复用只读 sudo 查询 `/var/lib/btrfs` 中的 scrub 历史，和 `btrfs-scrub`
  行为一致；普通用户不再把已完成的 scrub 误报成查询失败。新增/更新回归后 `tests/run` 为 **44/44**。

- **原生 root 恢复闭环补强**：原生后端不再错误要求 `btrfs-assistant` 命令存在；拒绝没有可验证
  `subvol=` 启动选择的布局，并在发布成功后正确返回成功而不是无条件 `exit 1`。还修复了 Btrfs 不会
  随父快照带入嵌套 `/.snapshots` 子卷的问题：新 root 会安全重建空的 Snapper 存储。新增
  `--native-root-rollback latest`，保留当前恢复根、换回旧 root；该路径不依赖 Snapper 列表。上述恢复、
  恢复后新建快照、回退和第二次 GRUB 启动已在隔离 VM 实测；当时 `tests/run` 为 **44/44**。
- **本轮复验（21:02–21:04）**：在同一隔离来宾再建 root #2 快照，写入第二次变更后运行原生恢复；
  新 `@` 的 ID 为 268，启动 ID 为 `11cf552f-…`，快照后的变更消失，`/.snapshots` 被验证为子卷，
  并成功创建新的 Snapper 快照。随后用 `--native-root-rollback latest` 回退，启动 ID 变为
  `e3c5ae4f-…`、活动根回到 ID 256、第二次变更恢复出现，恢复根保留为
  `@quickload-rejected-20260728T210441-804`。这还覆盖了原生恢复命令成功返回 0 的 CLI 契约。

### 2026-07-28（完整安全审查与灾难恢复链路）
- **菜单交互与说明**：Esc/取消统一直接回父菜单，不再出现第二次“按任意键返回”；新增 Scrub、存储健康、
  异盘备份、恢复和定时备份的右侧预览改为新手可读说明。boot/pacnew/post-update 在交互终端请求只读 sudo。
- **错误语义**：更新、日志、引导、硬件、推荐、Pacnew、存储状态等查询失败不再误报健康；支持严格模式的检查
  可用于自动化。清理、迁移、镜像、更新、unit 管理和恢复的部分失败会累计并返回非零。
- **锁与更新安全**：修改系统状态的脚本共享 `flock`，继承锁会验证真实 FD，环境变量不能伪造。`sysup` 增加
  关键空间预检、密钥环失败中止和 `systemd-inhibit`，更新缓存刷新失败不再静默。
- **快照与清理安全**：Snapper 全部使用 CSV；root/home 快照带同一批次事务标识。深度清理不自动删除来源不明
  的 Btrfs 子卷，清理后可重新创建快照；AUR 缓存拒绝越界/符号链接，镜像备份只轮换严格命名文件。
- **备份恢复**：新增 `offsite-backup`、`backup-restore` 和 `offsite-backup-schedule`。HOME 从临时只读快照归档；
  staging、校验、所有权标记、严格轮换、`latest` 更新和失败回滚均采用保留旧完整集合的发布顺序。恢复默认只预览，
  显式应用时保留覆盖前 rollback。
- **存储维护**：新增 `btrfs-scrub`、`storage-health` 和更新后的 `post-update-check`；区分未启用 timer、尚无结果和
  查询失败。GPU 检查改为实际健康项统计。
- **工程保障**：新增安全配置解析器、`config.example`、`README.md`、`tests/run` 和
  `tests/DESTRUCTIVE-VM.md`。当时自动验证基线为 42/42；后续真实 VM 验收后已提升至 44/44。
- **故障注入**：覆盖更新查询失败、迁移清单缺失、锁伪造、快照部分失败、恶意/损坏归档、原子发布失败、定时
  unit 回滚和清理部分失败。真实升级、删除、恢复和 Scrub 写操作未在日常系统代跑。

### 本轮（共享 UI 铺满终端）
- 移除 `ui_hr/ui_section` 的 96 列上限和 `_ui_rule_width` 的 100 列上限；共享宽度按实时终端列数计算。
- 横幅、卡片、分节线、结果页头和按键返回页脚会随终端宽度铺满；`UI_EDGE_GAP` 可配置右侧
  自动换行安全区（默认 2 列），极窄终端不会生成超宽规则线。

### 本轮（待更新列表单项更新）
- `checkallupdates` 的 Enter 从“无论选中什么都启动完整 sysup”改为按来源处理：Pacman 条目执行
  `sudo pacman -Syu` 更新全部已配置仓库包，AUR 仅调用 `paru/yay -S -- 当前包`，Flatpak 仅调用
  `flatpak update 当前应用`。
- Pacman 不做危险的单包升级；选中任意 Pacman 项只作为触发入口，实际始终完整升级全部仓库包，
  避免 `checkupdates` 隔离数据库与系统同步数据库混用造成 Arch 部分升级。`Ctrl+U` 仍调用原有 `sysup`。
- fzf 列表增加隐藏的“来源 / 包名 / 展示文本”结构字段，不再从 ANSI 文本猜包名；单项操作完成后
  刷新缓存并返回列表。`term-menu` 预览说明已同步。
- 新增共享 `ui_wait_key` 圆角结果页脚；`checkallupdates` 返回更新列表与 `term-menu` 返回菜单统一使用，
  等待时隐藏光标、按键后恢复，提示文案不再裸输出。
- 已通过 `bash -n`、ShellCheck 和命令分发 mock harness；未代替用户执行真实软件更新。

### 本轮（全目录功能审查）
- **快照恢复准确性**：`quickload` 的交互时间点选择现在同时携带描述和日期；修复多个同名
  `quicksave-sysup` 快照时，选择旧时间却被 `tail -n 1` 换成最新快照的问题。恢复前新增 `restore`
  关键词确认，提权重启后仍携带目标日期；快照列表中文列改用 `ui_pad`。
- **快照删除/权限**：`quicksave --delete` 默认要求输入 `delete`，校验 ID 并正确返回失败码；term-menu
  已做一次确认后通过 `--yes` 避免重复询问。修正删除成功文案的配置名/ID 参数颠倒。自动修复权限不再
  顺手把 `NUMBER_LIMIT` 改成 10、`NUMBER_MIN_AGE` 改成 0。
- **清理安全边界**：普通清理默认确认改为 `[y/N]`；直接执行深度清理也必须输入 `clean all`。
  普通清理不再删除 btrfs-assistant 恢复备份子卷；深度清理的临时 Btrfs 挂载增加 EXIT 清理。
  删除 Snapper 前不再暗改 `ALLOW_GROUPS/SYNC_ACL`；缓存、日志、Flatpak、下载目录、快照失败时不再谎报成功。
- **迁移包原子生成**：先在同目录 staging 完整生成、验证 tar 和 SHA256，再原子替换正式目录；旧包在失败时保留。
  secrets 文件纳入 SHA256SUMS；写入 ownership 标记，拒绝覆盖不属于 migration-pack 的非空目录。
- **诊断准确性**：`boot-check`/`hw-doctor` 修复多挂载点 `findmnt` 参数错误；`hw-doctor` 检查实际
  `display-manager.service`（当前为 greetd），不再硬编码 SDDM；`gpu-check` 在 prime-run 仍只暴露默认 GPU 时告警。
- **镜像校验**：国家验证按 reflector 国家全名或两字母代码精确匹配，不再把任意两字母输入视为有效。

### 本轮（终端效率工具：bat / zoxide / git-delta）
- 新增用户级 `terminal-tools`：`--status` 只读展示，`--enable` 将 bat、zoxide 和 git-delta
  接入交互式 Fish 与 Git，`--disable` 删除**唯一带 maintenance 标记的 Fish 块**并恢复启用前的
  Git 全局原值。它不需要 sudo、不持有系统维护锁，也不会影响 Bash/维护脚本；Fish 的 `cat` 别名只在
  交互会话生效，`command cat` 仍是原生 cat。
- 回退状态仅保存六项 Git 显示设置，路径为
  `~/.local/state/maintenance/terminal-tools-git-before.tsv`，权限 `0600`。`--disable` 会先验证
  文件版本、完整键集、重复项和 Base64 内容，确认状态无损后才改动 Git，避免损坏状态文件造成部分恢复。
  若状态文件不存在，脚本只删自己的 Fish 块，不猜测或覆盖用户 Git 配置。
- `term-menu → 系统检查 → 终端效率工具` 是只读状态页，fzf 预览和 README 都解释三个工具的用途、启用后
  效果与撤销方式；`recommend-check` 也将三个包列为“终端效率（可随时撤销）”推荐项。
- 新增隔离生命周期回归：保留既有 Fish 内容和旧 Git 值、重复启用不重复写块、禁用后精确恢复旧值和移除
  原本不存在的键。当时 `tests/run` 为 45/45。

### 本轮（长时间检查的阶段提示）
- **问题**：`migration-pack --check` 等任务会在 `sha256sum`、`tar --zstd -t`、归档清单逐项核对期间长时间无输出，
  容易被误以为卡死。
- **统一处理**：新增 `ui_working`，在同步且可能耗时的阶段立即打印“正在做什么；请稍候”，不伪造百分比或
  完成时间。迁移包生成/校验、备份恢复预览、异盘备份、日志检查、存储健康、Btrfs Scrub、更新查询和硬件检查
  均已接入；`checkallupdates --refresh` 的机器可读 stdout 保持不受污染。
- **验证**：实际运行 `TERM_MENU_CHILD=1 migration-pack --check`，约 115 秒的校验过程中先后显示
  SHA256 校验与配置归档清单核对阶段，最终成功。新增回归确保这些入口保留阶段提示；当前 `tests/run` 为 **51/51**。

### 本轮（菜单焦点与循环导航复查）
- **焦点恢复根因**：`term-menu` 原来使用 `fzf --bind start:pos(N)`。候选项通过管道送入 fzf 时，
  `start` 事件发生在列表加载前，`pos(N)` 实际没有生效，所以从功能返回后经常又聚焦第一项。改为
  `load:pos(N)`，等待列表加载完成再定位；若动态条目已消失，既有 `menu_start_position` 会安全回退第一项。
- **漏网的循环选择器**：补齐 Btrfs Scrub（目标与操作）、恢复备份集合和定时异盘备份操作的 `--cycle`，
  并把界面提示明确写为“↑↓ 循环移动”。其余通过 `ui_fzf_base` 或 `choose_menu` 的入口也在回归中覆盖。
- **验证**：新回归分别覆盖所有独立 fzf 选择器的 `--cycle`、六个子菜单执行非首项后的焦点保留，以及
  `load:pos(2)` 参数。还用真实 fzf 的伪终端验证了：初始定位到第二项后 Enter 仍选中第二项；第一项按 ↑
  会环绕到最后一项。完整 `MAINTENANCE_NO_NOTIFY=1 tests/run` 现为 **51/51**，全项目 Bash 语法、
  ShellCheck 和 `git diff --check` 通过。

### 本轮（菜单异常退出修复 + 更新结果收束）
- **term-menu 失败不再退窗**：交互式菜单不再启用 `errexit`；所有叶子动作统一经
  `run_leaf_and_pause` 保存退出码。子脚本失败/取消会显示退出码并停在结果页，按键后返回原子菜单。
- **checkallupdates 交接修复**：从待更新列表启动 `sysup` 时捕获其退出码，成功或失败都会先显示明确结果；
  删除不可靠的父进程名猜测。term-menu 通过 `TERM_MENU_CHILD=1` 明确接管暂停，独立窗口则固定等待按键，
  包括“当前没有待更新项目”结果也不会闪退。
- **sysup 收尾增强**：Flatpak 作为附加更新，失败只警告、不再阻断后续 GRUB 和最终总结；
  `quicksave`、`checkallupdates` 优先使用同目录脚本，避免直接运行 `sysup` 时因 PATH 不同静默漏掉；成功结束会显示重启建议。

### 本轮（清理/快照功能性审查 + cache-clean 聚焦 + 迁移 check-battery）
- **clean 功能性 bug 修复**：孤儿包卸载 `$PKG_MNGR -Rns` 是全脚本唯一无失败保护的清理步骤，
  `set -e` 下卸载失败（依赖冲突 / 用户按 n 取消）会中断整个脚本，后续缓存/日志/快照清理全被跳过。
  改为 `if $PKG_MNGR -Rns ...; then ok; else warn(ORPHAN_SKIP); fi`，失败不再中断。已 harness 复现并验证修复。
- **cache-clean 聚焦**：清理模式(`--safe/dev/chrome`)从"全景 dump 所有缓存"改为 `show_targets` 只显示本模式缓存；
  `--list` 概览保持全景三分组。term-menu 对应 4 项 preview 同步（删重复行、Chrome"会清"文案对齐脚本实际清理项）。
- **clean/quicksave 展示层**：clean 快照删除日志 → `_item` + `ui_pad` 对齐；quicksave `-l` → `ui_panel_raw` 卡片。
- **check-battery 迁移**：`~/scripts/desktop` → 本目录，接入 ui.sh 卡片化，修好软链。
- 只读路径已实测；破坏性路径（真实 clean/快照恢复）需本人 TTY 实测。

### 上轮（mirror-update）
- reflector `[INFO]/[WARNING]` 输出卡片化（`_run_reflector` + `ui_panel_raw`），写入改"临时文件→校验→sudo cp"更安全。
- 全脚本徽章化：`[CHECK]/OK/FAIL` + 裸 `H_*` 色 → ui.sh 徽章 + `ui_confirm`。已 TTY 端到端实测 `-c cn` 通过。

### 更早（term-menu UI 重构）
- 结果页圆角头/脚(`run_leaf_header`/`pause_for_menu`)、网络状态表、查看快照表（均 `ui_pad`/`ui_dwidth` 对齐、颜色区分状态不用图标）。
- 迁移工具导航 bug：`migration-pack` 直接叶子 → 标准循环子菜单 `show_migration_menu`。
- sysup 部分升级警告 → 红框卡片；migration-pack 内部 `==>` → 徽章。

## 七、尚未完成与已知边界

- **VM 演练已收尾清理**：一次性 `qemu:///system` 域 `maintenance-btrfs-lab`、全部内部快照元数据、
  两块基础 qcow2 测试盘、四个未注册 overlay 和 libvirt 日志均已于 2026-07-28 删除；仓库测试夹具和
  `/tmp` 输出也已清理。Arch 安装 ISO 和维护源码保留。演练证据（包括 root 原生恢复、Snapper 重建、
  回退与来宾 44/44）保留在 `tests/DESTRUCTIVE-VM.md`，但该域不再可启动；若须重演，应创建新的隔离 VM，
  绝不复用日常系统。
- 已完成真正覆盖 root 子卷并从 GRUB 启动、再回退原根的 VM 演练；但无法用虚拟 virtio 盘证明实机
  NVMe SMART/断电恢复，且来宾 `btrfs-assistant-bin` 当前段错误，自动 `quickload` 仍会安全停止。
- 宿主机的 Docker `FORWARD=DROP` 会覆盖 libvirt NAT；已安装并启用
  `libvirt-docker-forward.service`，只在 `DOCKER-USER` 中维护 `virbr0` 出站和已建立连接返回两条规则。
- 当前机器没有配置 `BACKUP_TARGET`，因此不应安装定时异盘备份 unit；用户先挂载并配置真实异盘目标。
- btrfs-assistant 是外部恢复后端；探测到崩溃、超时或空清单时脚本会在选择快照前停止，但不能在脚本内修复该程序。
- 不把同盘 Snapper 快照称为异盘备份。只有备份集合校验通过并完成一次真实恢复演练后，才能称为已验证灾难恢复副本。
- 若新增脚本：遵守第一节约束，接入共享配置/锁/UI/退出码，补 `tests/run` 故障场景，并更新 README 和本文档。
