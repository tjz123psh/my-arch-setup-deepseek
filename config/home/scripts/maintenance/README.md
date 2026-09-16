# Arch Linux 系统维护脚本

这是一组面向 Arch Linux、Btrfs/Snapper 和 systemd 的终端维护工具。统一入口是：

```bash
term-menu
```

修改系统状态的脚本共享同一把 `flock` 维护锁；锁文件放在操作者 HOME 的
`~/.cache/maintenance/`，经 `sudo` 运行时沿用原用户，root 直接运行时也会尽量识别
真正的操作者，避免"root 一把、用户一把"而互不排斥。

检查类脚本遵循同一条约定：**「无法检查」不等于「健康」**。查询失败（工具报错、权限
不足、超时）一律返回非零并在输出里写明原因，绝不静默成 `0`；「确实没有/缺失」用缺失
文案，只有 `--strict` 才影响退出码。「发现问题」「确实缺失」「查询失败」在汇总行分开
统计（正常 / 注意 / 缺失 / 查询失败）。

## 主要功能

- 更新：`checkallupdates`、`sysup`、`mirror-update`
- 清理：`clean`、`cache-clean`
- 快照：`quicksave`、`quickload`、菜单内查看/删除
- 检查：`hw-doctor`、`storage-health`、`btrfs-scrub`、`gpu-check`、
  `check-battery`、`boot-check`、`pacnew-check`、`log-check`、`terminal-tools`
- 迁移：`migration-pack`、`offsite-backup`、`backup-restore`

## 待更新列表与刷新

`checkallupdates` 并行查询 Pacman、AUR 和 Flatpak，缓存有效期 1 小时：

- 打开列表**不阻塞**。缓存过期时先显示上一次的结果，刷新在后台进行，完成后原地替换；
  列表边框标签实时显示数据时间：`待更新列表 · 12 分钟前` / `· 正在刷新` / `· 刚刚更新`。
- `Ctrl+R` 强制刷新全部来源。刷新期间旧列表保持可见，不会闪成空白。
- 每个来源单独计时和记录状态。某个来源查询失败（例如离线时的 Flatpak）不会连累另外两个
  来源被反复重查，下次只补查失败的那个。
- 每个来源的查询都有超时（默认 90 秒），超时会指明是哪个来源、可能的原因，不会无限挂起。
- 在列表里更新单个 AUR/Flatpak 应用或整组 Pacman 包之后，只重查受影响的来源。
- 刷新期间被 Esc、Ctrl+C 或关窗中断时，会收掉后台查询进程并清理临时文件；已经查完的
  来源仍然会正常落盘、并立刻打上自己的时间戳，不会白跑。
- **刷新失败不会被说成成功**：来源状态只有在数据落盘成功后才写 `ok`；某一来源失败时
  保留它上一次成功列表（不会用空文件覆盖），失败轮次不打最新时间戳、`--refresh` 返回非 0。
- 等待另一轮刷新的锁超时（`UPDATE_LOCK_WAIT`）时**取消本次刷新并明确提示**，不会无视锁
  并发查询、互相覆盖缓存。
- `log-check` 默认只打印到终端、不写文件；需要留档时用 `log-check --save[=路径]` 生成
  Markdown 报告。

机器可读入口（供自动化和 fzf 使用，不需要交互终端）：

```bash
checkallupdates --refresh        # 刷新全部来源并输出机器字段列表
checkallupdates --refresh-stale  # 只刷新已经过期的来源
```

超时可在 `~/.config/maintenance/config` 里调整：`UPDATE_QUERY_TIMEOUT`（单个来源的查询
超时秒数，默认 90）、`UPDATE_LOCK_WAIT`（等待另一个刷新完成的上限秒数，默认 300）。
临时排障也可用环境变量 `CHECKALLUPDATES_QUERY_TIMEOUT` / `CHECKALLUPDATES_LOCK_WAIT` 覆盖。

## 系统升级与镜像源

`sysup` 的顺序是：显示 Arch 新闻 → 你确认 → 才请求管理员权限 → 取得维护锁后依次执行
快照、镜像源检查、数据库与密钥环、软件包升级、Flatpak、GRUB、更新后检查（共 7 步）。
在确认前取消不会要求输入密码。新闻抓取同时限制连接时间和总时长，源不通时转为
"是否忽略新闻强制更新"，不会一直挂着。

`mirror-update` 调用 reflector 时带并发测速和连接/下载超时，避免一批慢镜像把刷新拖成
几分钟；线程数由配置项 `MIRROR_THREADS` 控制（默认 5，上限 32），也可用同名环境变量临时覆盖。

## 快照与恢复

`quicksave` 会给所有 Snapper 配置（通常是 root 和 home）创建**同一批次**的快照，批次 ID
写在 `maintenance_batch` userdata 里；`quickload` 依靠它成套恢复。`sysup` 在升级前会自动
创建一套描述为 `quicksave-sysup` 的快照。

恢复目标的选择规则：

- 不带 `-d` 时，`quickload` 选择**最新的**可恢复快照：多个配置一起恢复时取最新的一套
  完整批次，单个配置则取该配置最新的快照。旧实现是"按描述猜"，会选中最后一个描述叫
  `quicksave` 的快照，于是 `sysup` 建的 `quicksave-sysup` 永远选不中，默认恢复可能把系统
  退回好几天前。
- 确认页会列出**每个配置的快照 ID、时间、描述和批次**，确认词仍是 `restore`；不看清楚
  恢复到哪一个时间点就无法继续。
- 恢复成功后有 5 秒可中断的重启倒计时，Ctrl+C 可以留在当前系统先检查；自动重启失败会
  明确报错，不再被静默吞掉。
- 仍可用 `-d`、`--snapshot-date`、`--snapshot-batch` 精确指定，或在菜单里用「选择快照」
  逐条挑选。

删除与清理的护栏：

- 菜单里的「删除快照」如果选中的快照属于某个批次、而另一侧还在，会明确提示"删掉这一半
  后成套恢复会失效"，再要求输入 `delete`。
- 批量删除只调用一次 `quicksave`，由 `snapper` 一次删完，不再每个 ID 起一个进程。
- `clean all` 除了保留 `before*` 节点，还会**保留最近一套 `maintenance_batch` 快照**，
  也就是最近一次更新前的回滚点，并在输出里说明保留了哪些。

## 迁移配置档（v2）

`migration-pack` 用于生成“重建工作环境”的资料包，而不是完整 HOME 或系统镜像。先预览，确认
路径范围后再生成：

```bash
migration-pack --plan
migration-pack --pack ~/migration
migration-pack --check ~/migration
```

默认输出始终是单一的 `~/migration/`；生成会先在同级临时目录完成校验，再原子替换旧目录，
不会在 HOME 内持续累积按时间戳命名的多份迁移包。

默认配置档会原样纳入整个 `~/.config`、`~/.ssh`、`~/obsidian`、`~/Projects`、指定的背景/头像
目录、`scripts`、`md`、本地命令入口和桌面启动器。可复制仓库中的 `migration-profile.example` 到
`~/.config/maintenance/migration-profile.conf` 后按需调整。配置档只能使用：

```text
include <相对 HOME 路径>
exclude <glob>
secret <相对 HOME 路径>
```

路径不能是绝对路径或包含 `..`。默认不使用 `secret`；只有你显式写入 `secret` 时，该路径才只会
生成是否存在与权限的引用记录、不会导出内容。默认范围包含 SSH 身份材料、应用凭据、项目和完整配置，
所以迁移包必须只保存到你本人可访问的加密或受保护存储；不要上传公共网盘、公开仓库或发送给他人。
系统级 `/etc` 文件仍不会被自动归档；迁移包仅记录受关注的系统配置路径和 systemd override 审查信息，
恢复端也只产生计划，不会自动覆盖系统文件。若选定内容含 Docker/Podman 等服务创建、当前用户无权读取的
数据卷，`migration-pack` 会先记录原始权限失败诊断，再只为该次 `tar` 读取通过
终端中的 `sudo` 请求认证；不会以 root 身份运行整个迁移流程，也不会静默跳过文件。
若该工具不可用或授权失败，打包会明确失败且不会发布不完整的迁移包。

v2 包采用结构化目录：`payload/home-config.tar.zst`、`packages/`、`services/`、`system/`、
`secrets/references.tsv`、`format.json` 和全量 `SHA256SUMS`。`backup-restore` 仍可读取既有 v1
包。独立 `migration-pack --pack` 会保存完整选定内容；异盘备份中 HOME 归档已经包含这些数据，因此会
以 `--metadata-only` 生成不重复文件的迁移元数据，仍与 `home.tar.zst` 对应同一冻结时间点。

## 备份恢复

`offsite-backup` 只接受不同物理磁盘或远端挂载。创建时会先通过覆盖 HOME 挂载点的
Snapper 配置生成临时只读 Btrfs 快照，再从该固定时间点归档；不会直接打包持续变化的
活动 HOME。临时快照不交给 `snapper-cleanup.timer`，以免归档中途被删除；正常退出时
立即删除，断电或强制终止留下的同类快照会在下一次备份开始前回收。当前用户必须具备
该 Snapper 配置的创建和删除权限。每个 `set-*` 集合包含 HOME 归档、迁移包和校验文件，
只有完整校验通过后才会原子更新 `latest`。自动保留轮换只删除带本工具集合标记的新式
备份；旧版本集合和用户自己创建的同名前缀目录不会按名称直接删除。

恢复默认只生成计划：

```bash
backup-restore --source /run/media/$USER/BACKUP
```

独立的迁移包目录也可以直接作为恢复源：

```bash
backup-restore --source ~/migration
```

独立 v2 迁移包会暂存所选配置和资料；既有 v1 包仍会按原行为映射其专用 secrets。异盘 `set-*`
则暂存完整 HOME 归档，迁移目录只保存包、服务和系统审查元数据以避免重复归档。两种来源使用相同的
预览和回滚保护。

计划目录包含：

- `packages-official.txt`：待安装的官方仓库包
- `packages-foreign.txt`：待安装的 AUR/foreign 包
- `services-system.txt`：待人工确认启用的系统服务
- `services-user.txt`：待人工确认启用的用户服务
- `home-changes.txt`：HOME 合并范围

显式恢复 HOME：

```bash
backup-restore --source /run/media/$USER/BACKUP --set latest --apply-home
```

恢复前会验证 HOME 和迁移包两层校验、归档可读性及路径边界。HOME 采用合并语义，
不会删除当前系统多出的文件；被覆盖文件的旧版本保存在
`~/.cache/maintenance-restore-rollback/`。应用恢复需要 `rsync`。软件包和服务始终只
输出计划，不会自动安装或启用。

恢复演练建议先在一次性测试用户或 Btrfs 虚拟机中进行。确认计划、回滚目录和应用
启动均正常后，再把该备份视为经过恢复验证的灾难恢复副本。

### btrfs-assistant 不可用时的 root 恢复

注意：`btrfs-assistant` **以普通用户直接运行会段错误，以 root 运行正常**（本机实测：
用户态 exit 139 core dumped，root 下 `-l` 正常返回 34 条恢复条目）。所以 `quickload` 的
后端预检必须先拿到管理员权限；在终端里交互运行时它会请求密码。如果预检没能提权，
脚本会说明"没能以管理员权限探测恢复后端"，而不是谎报后端崩溃。

`quickload` 默认仍使用 btrfs-assistant；如果它段错误或无法启动，默认会安全停止，绝不
猜测恢复 ID。对于常见的顶级 `@` root 子卷布局，可以在确认目标快照后显式使用原生 Btrfs
后端：

```bash
sudo quickload -n -c root -d '你的快照描述' --native-root-fallback
```

它只恢复 root，不触碰 HOME，也不需要 `btrfs-assistant` 本身可执行。脚本会先确认当前运行的
根确实是通过 `subvol=@`（或等价路径）挂载、目标确实是 Btrfs 子卷；随后从 Snapper 快照创建新的
可写 `@`，把旧 root 保留为 `@quickload-pre-时间-PID`，并重建新 root 的 `/.snapshots` 子卷，最后
才请求重启。它不会为不明布局猜测路径；检查不通过时不会挂载顶级子卷或改名。

首次启动恢复后的 root 后，请先验证系统、网络和关键应用。若结果不接受，可在**已经成功启动的
恢复 root**上执行（`latest` 会选最新一个本工具保留的旧 root）：

```bash
sudo quickload -n -c root --native-root-rollback latest
```

该回退会把当前恢复 root 保留为 `@quickload-rejected-时间-PID`，再将旧 root 换回 `@` 并重启；即使
恢复 root 的 Snapper 列表暂时不可读，回退也不依赖它。两个命令都会实际切换下次 GRUB 启动的根子卷，
只能在已验证的异盘备份或一次性 VM 中使用。不要删除 `@quickload-pre-*` / `@quickload-rejected-*`，
直到完成一次成功启动、数据检查和新的快照创建。原生恢复会为新 root 建立新的 Snapper 快照存储，历史
快照仍随保留的旧 root 保存，不会自动合并。

## Btrfs Scrub

查看所有已挂载 Btrfs 文件系统的状态：

```bash
btrfs-scrub --status
btrfs-scrub --status --strict
```

手动启动和管理每月 timer：

```bash
btrfs-scrub --start /
btrfs-scrub --enable /
btrfs-scrub --disable /
```

相同设备上的多个子卷只处理一次。写操作需要输入完整确认词；非交互调用还必须显式
添加 `--yes`。启用 timer 不会立即启动完整 scrub，只会启动 systemd 定时器。

## 存储健康

```bash
storage-health
storage-health --strict
```

检查内容包括 SMART 总体结论、NVMe 温度/寿命/介质错误、ATA 关键错误属性、文件系统
空间、Btrfs device stats、上次 scrub 和每月 timer。SMART 使用 `smartctl -j` JSON，
不会解析本地化表格。详细 SMART 读取可能请求 sudo，但检查不会修改磁盘。

## 集中配置

可将仓库中的 `config.example` 复制为 `~/.config/maintenance/config`。解析器只接受已知
的 `KEY=VALUE`，不会把文件当 Shell 脚本执行；未知键、重复键和非法数值都会报错。

```ini
BACKUP_TARGET=/mnt/offsite-backup
BACKUP_KEEP=3
BACKUP_ON_CALENDAR=weekly
BACKUP_RANDOM_DELAY=1h
MIRROR_BACKUP_KEEP=5
MIRROR_MAX_AGE_DAYS=30
MIRROR_THREADS=5
UPDATE_QUERY_TIMEOUT=90
UPDATE_LOCK_WAIT=300
ROOT_MIN_FREE_MIB=5120
BOOT_MIN_FREE_MIB=200
JOURNAL_RETENTION=2weeks
THUMBNAIL_MAX_AGE_DAYS=30
```

优先级为：命令行参数、已有环境变量、配置文件、内置默认值。配置中的 `~/` 会安全
展开为当前 HOME，其它 `$变量`、命令替换和 Shell 语法不会执行。

## 更新后检查

`sysup` 在软件包、Flatpak、GRUB 和更新缓存步骤结束后自动运行：

```bash
post-update-check
post-update-check --strict
```

它只读检查 pacnew/pacsave、系统与用户 failed units、当前运行内核是否仍有已安装模块、
明确的重启需求和 GRUB 配置。需要人工处理的结果会显示警告；查询命令本身失败会返回
非零，避免把“无法检查”写成健康。

## 定时异盘备份

在配置好 `BACKUP_TARGET` 后运行：

```bash
offsite-backup-schedule --install
offsite-backup-schedule --status
```

安装器会先执行异盘目标只读校验，再写入
`~/.config/systemd/user/maintenance-offsite-backup.{service,timer}`。service 同时使用
`ConditionPathIsMountPoint` 和 `mountpoint` 检查安装时记录的挂载点；目标磁盘未挂载时
跳过，不会自动挂载，也不会在系统盘创建替代目录。备份失败由 journal 记录，
`offsite-backup` 的暂存与原子 `latest` 逻辑会保留上一份完整集合。

## 终端效率工具

`terminal-tools` 负责把三个已经安装的可选工具接到**当前用户**的 Fish 和 Git 中。它
不会更新软件包、不会使用 sudo，也不会改动维护脚本；菜单里的“系统检查 → 终端效率工具”
只读显示状态和新手说明。

```bash
terminal-tools --status       # 只看当前状态（默认）
terminal-tools --enable       # 启用当前用户的 Fish / Git 集成
terminal-tools --disable      # 撤销本工具的写入并恢复旧 Git 设置
```

- **bat**：为文本加语法高亮，读配置、脚本和日志更清楚。启用后仅在交互式 Fish 中把
  `cat` 映射为无分页的 `bat`；Bash 脚本、维护脚本和 `command cat` 都不受影响。
- **zoxide**：学习你实际进入过的目录。重新打开 Fish 后，可用 `z maintenance` 跳到匹配
  的常用目录；`zi` 会打开 fzf 目录选择器。它不会扫描或上传文件。
- **git-delta**：美化 `git diff`、`git log -p` 和冲突显示，方便阅读与审查改动；不会改变
  Git 历史、工作区内容或提交方式。

首次启用时，脚本会把每个要改动的 Git 全局设置的原值保存为仅当前用户可读的
`~/.local/state/maintenance/terminal-tools-git-before.tsv`。`--disable` 会删掉明确标记的
Fish 块，并准确恢复这些旧值；若状态文件不在，脚本只移除自己的 Fish 块，不会猜测或覆盖
现有 Git 配置。

## 菜单操作

`term-menu` 中所有可交互的 fzf 菜单都支持首尾循环：在第一项按 **↑** 会跳到最后一项，
在最后一项按 **↓** 会回到第一项。功能执行完成、失败，或在子工具中按 **Esc** 取消后，
父菜单会保留在刚才的分类和功能上；不会自动跳回第一项。若该动态条目在操作后已经消失
（例如刚删除的快照），菜单会安全地回到第一项。

## 退出码

- `0`：操作完成，且没有发现需要处理的问题
- `1`：① 无法得出结论（查询失败、工具报错、权限不足、超时）——即使没有 `--strict`；
  ② `--strict` 下发现警告或缺失；③ 操作本身失败
- `2`：命令行参数错误；非交互环境执行高风险操作又没有 `--yes`（不会自动确认）
- `10`：子工具请求返回父菜单
- `75`：另一项维护操作持有共享锁
- `127`：缺少执行该功能所需的命令（会打印缺哪个命令）
- `130`：Ctrl+C 中断，或菜单子工具用 Esc/取消请求立即返回父菜单

`term-menu` 里运行叶子子工具期间按 Ctrl+C 只打断本次操作并回到父菜单；主菜单里 fzf
被中断（130）按取消处理，fzf 真报错（≥2）会以同样状态退出，不再折叠成 `0`。

## 开发检查

```bash
find . -maxdepth 2 -type f -perm -u+x -exec bash -n {} +
shellcheck -x backup-restore btrfs-scrub storage-health term-menu
MAINTENANCE_NO_NOTIFY=1 tests/run
```

`tests/run` 使用临时目录和命令桩测试更新、清理、快照、迁移、恢复和存储状态，不会
执行真实系统升级、快照恢复、深度清理或磁盘 scrub。端到端用例会隔离 `HOME`，`test_syntax`
会跳过 `review*/` 归档目录。只跑其中一部分可以使用正则过滤：

```bash
TESTS_FILTER='snapshot|lock' MAINTENANCE_NO_NOTIFY=1 tests/run
```
