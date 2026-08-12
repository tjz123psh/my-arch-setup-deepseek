# 下载模式实验最终报告（第一阶段）

- **项目**：`my-arch-setup-deepseek`
- **实验目录**：`download-mode-lab/`
- **报告日期**：2026-08-08（Asia/Shanghai）
- **结论状态**：已完成隔离实验；**尚未合并主安装器，尚未修改宿主系统**
- **适用范围**：pacman 官方包下载、镜像选择、AUR 源码预取、VMware 大文件缓存，以及 Go/Cargo 构建缓存的下载阶段

> **2026-08-10 更新**：本实验的 AUR 离线缓存部分已合并进主安装器——
> `fetch-aur-sources.sh` 现支持 `physical|vm` 双 profile（`fd31d1e`），离线缓存
> 按机型生成并发布（`aur-sources-physical.tar.gz` / `aur-sources-vm.tar.gz`）；
> 06-aur 双模式（offline makepkg / online paru）已上线。本文档"尚未合并"仅指
> 2026-08-08 时的状态，勿据此判断当前安装器能力。

> 这是一个证据报告，不是“所有安装已经变快”的承诺。mock 测试证明了下载器的并发/失败语义和当前 `XferCommand` 的行为；真实网络速度具有时段、代理、镜像同步状态和出口差异，必须在目标测试机上做最终验收。

## 0. 当前进展（2026-08-08）

- 第一步（默认移除外部 `XferCommand`）已在历史提交 `5964752` 完成；第二步（镜像配置/同步职责整理）仍在当前工作树 dirty diff 中，已通过调用序列回归，但尚未形成独立稳定提交。
- 第三步已在 `download-mode-lab/` 完成隔离 planner：package/database/latency lane 隔离、TTL/future gate、fallback/degraded 契约、严格 URL/状态校验和诊断脱敏；**没有接入主安装器，也没有写宿主配置**。
- 第三步最终本地回归为 `mirror-plan-test.py 41/41 PASS`，`run-lab.sh` 连续两轮通过；真实官方/archlinuxcn 只读探测已保存第一轮快照并完成第二、第三轮复测。
- 当前结论是“可进入 integration review”，不是“已获准 apply”。任何 `scripts/01-mirror.sh` 主代码集成、宿主 mirrorlist 写入或 VM/物理测试仍需单独审批。

## 1. 最终判断

### 1.1 先纠正一个时序误判：最初的系统更新发生在镜像优化之前

`install.sh:176-178` 在模块循环之前就执行 `pacman -Sy archlinux-keyring` 和
`pacman -Syyu`；`01-mirror.sh` 要到后面的模块循环才运行。因此用户看到的第一次
大等待（尤其是全系统升级）仍然使用启动前已有的 mirrorlist 和 downloader，01 的镜像
优化根本来不及改善这段时间。这是高置信的代码时序问题，不能只盯着 01 内部测速。

建议把“只读探测/生成可审查 mirror plan”提前到系统升级之前；在用户批准后先应用镜像
配置，再进行唯一的同步/升级事务。若探测 fallback 需要安装 reflector，必须设计无 reflector
时的最小路径，不能为了测速又引入一次长同步。

### 1.2 最可疑、且已经被实验复现的慢点

当前 `scripts/01-mirror.sh` 在首次安装时向 `/etc/pacman.conf` 的 `[options]` 段插入外部 `XferCommand`：

```text
XferCommand = /usr/bin/curl ... -o %o %u
```

在本机 `pacman 7.1.0 / libalpm 16.0.1` 的隔离 mock 仓库中：

- 原生 pacman + `ParallelDownloads=3`：下载阶段约 **0.627 s**，服务端最大并发 **3**；
- 原生 pacman + `ParallelDownloads=5`：约 **0.628 s**，最大并发 **3**（测试目标只有 3 个包）；
- 外部 `XferCommand` + `ParallelDownloads=3/5`：均约 **1.86 s**，最大并发 **1**。

延迟 0.4 s 的重复对照也复现：原生 p=3 **0.428 s / 并发 3**，外部 Xfer p=3 **约 1.26 s / 并发 1**。在这个模型中，外部 Xfer 让 `ParallelDownloads` 的收益消失，约慢 **2.9 倍**。

这不是完整生产网络 benchmark，但足以支持以下优先决策：

> **不要默认把 pacman 的下载改道到外部 curl。先保留 pacman 原生 downloader 和现有并发设置；外部 Xfer 只能作为明确的兼容性 fallback。**

另外做了一个本地“服务器 12 秒不返回任何字节”的 native stall 对照：pacman 在约 10 秒后以非零退出，并报告 `Operation too slow. Less than 1 bytes/sec transferred the last 10 seconds`（见 `results/pacman-native-stall.json`）。这证明当前 pacman 原生路径有低速超时和失败传播，不是无限期无反馈；但它不是硬性的单文件总时限，持续低速但高于阈值的传输仍需在目标网络验证。

### 1.3 第二个已确认的问题：镜像列表是“可达优先”，不是“实际包吞吐优先”

当前 01 只对 Aliyun 的 `core.db` 做一次可达性判断，然后按固定顺序写入 8 个官方镜像；archlinuxcn 也使用固定顺序。只读 HEAD/Range 探测表明，同一时刻不同镜像、不同仓库、不同对象的差异很大：

| 1 MiB Range 对象 | 最高 | 其他可用代表值 | 不可用/限制 |
|---|---:|---:|---|
| 官方 `coreutils` 包 | Aliyun **2.792 MiB/s** | USTC 2.415、Huawei 1.723、Tencent 1.557、清华 1.479、ZJU 0.209 | 163 超时；LZU 返回 200/无法安全截断 |
| archlinuxcn `flclash` 包 | Aliyun **2.862 MiB/s** | Huawei 0.491、Tencent 0.488、USTC 0.472、清华 0.372、ZJU 0.249 | LZU 超时/Range 探测不可用 |

256 KiB 探测的排序又不同，说明不能把一次采样永久写死。`UNAVAILABLE` 表示探测失败、超时或服务器忽略 Range，不表示“镜像为空”。

> **建议**：按实际 repo（官方、archlinuxcn）和代表包做短探测，多次取中位数/加权分数，生成带 TTL 的排序；保留 fallback，而不是只测一个 `core.db` 就固定整组顺序。

### 1.4 AUR 链路的慢点不是单一命令，而是三个串行层叠

代码阅读确认：

1. `fetch-aur-sources.sh` 中 `gitm`/`dl` 调用按脚本顺序逐个执行；VMware bundle 与 8 个 guest-tools ISO 也逐个下载。
2. `scripts/06-aur.sh` 对 recipe 使用单一 `for` 循环，逐个 `makepkg -s`，失败再完整重试一次。
3. `makepkg -s` 在构建期间仍可能解析/安装依赖并下载源，下载阶段与构建阶段没有清晰分离。

对当前 15 棵 recipe 执行 `makepkg --printsrcinfo`，得到 **32 个远程 source 条目**（HTTP/HTTPS/VCS）；`fetch-aur-sources.sh` 又手工重复维护这些 alias/URL。虽然当前静态比对没有发现明显漏项，但这种双重清单本身就是版本漂移风险，尤其是 VMware 的 URL basename/alias 和 AUR cache 命名。

本目录的 6 个独立源、本地每请求 0.25 s 延迟模型：

- 当前串行形状（jobs=1）：**1.610 s**；
- 有界预取（jobs=3）：**0.590 s**；
- 服务端最大并发：**3**；模型加速约 **2.7 倍**。

这只证明“独立网络源可以有界并发预取”，**不证明可以并发运行所有 makepkg**。AUR 构建仍需按依赖拓扑顺序执行：`paru`、`vmware-keymaps`、`vmware-workstation` 等不能无脑同时构建。

### 1.5 可靠性方面当前比“速度”更危险的缺口

静态审计 `tests/source-cache-audit.py`（结果为 `defects_confirmed`，不是 PASS）也复现了这些代码事实。`fetch-aur-sources.sh` 的通用 `dl()` 在目标文件只要非空时就直接 `SKIP`（`fetch-aur-sources.sh:18-20`），大多数调用没有给出 checksum。结果是：

- 损坏的非空缓存会被误认为可用；
- 直到后面的 makepkg 校验/构建才失败，浪费前面所有时间；
- 网络失败时删除 `.part`，没有 HTTP Range 断点恢复（`fetch-aur-sources.sh:21-38`）；
- URL 与错误日志共用 `/tmp/aur-dl.err`/`/tmp/aur-git.err`，未来并发化会互相覆盖诊断；
- 缓存目录只按“目录非空”判断，未绑定 recipe/source hash 或 manifest 版本。

VMware 专用 `dl_vmware()` 已做 checksum 检查，但仍是串行、无断点续传，并使用共享错误日志。大文件下载失败后重来，是“等待很久”的高概率来源。

## 2. 审查范围与现状基线

### 2.1 阅读的主链路

- `install.sh`：阶段编排、resume、首次同步/全系统升级；
- `scripts/00-utils.sh`：权限、机器角色/桌面模块选择、命令包装；
- `scripts/01-mirror.sh`：官方镜像、multilib、pacman downloader；
- `scripts/02-system.sh`：基础工具与系统升级；
- `scripts/03-packages.sh`：清单过滤、archlinuxcn、官方包事务、FlClash 迁移；
- `scripts/05-niri.sh` / `05-hyprland.sh`：桌面包安装；
- `scripts/06-aur.sh`：recipe 构建、AUR→AUR 依赖 bootstrap、最终安装；
- `fetch-aur-sources.sh`：离线 AUR 源、VMware 大文件、Go/Cargo cache；
- `scripts/07-config.sh`、`08-services.sh`、`09-settings.sh`、`99-cleanup.sh`：配置/服务/收尾对下载缓存和安装重试的影响；
- `manifests/workstation-packages.tsv`、`manifests/aur-recipes.tsv`、所有 AUR `PKGBUILD/.SRCINFO`；
- `README.md`、`docs/comprehensive-review-20260807.md`、handoff/离线安装文档。

### 2.2 宿主只读基线

只读查询得到：

```text
pacman 7.1.0 / libalpm 16.0.1
/etc/pacman.conf: ParallelDownloads = 5
/etc/pacman.conf: DownloadUser = alpm
/etc/pacman.conf: active XferCommand = none（只有注释示例）
aria2c/axel/parallel/wget2 = unavailable
```

这里的“unavailable”是命令查询结果，不是安装失败；实验没有安装这些额外下载器，也没有写入宿主 pacman/makepkg 配置。

pacman 7.1 的本地 `pacman.conf(5)` 说明了：

- `ParallelDownloads` 控制并发下载流；
- `XferCommand` 会接管所有远程文件；
- `DisableDownloadTimeout` 是禁用默认低速/超时的选项；
- `DownloadUser` 可限制下载用户。

因此主脚本注释中“内置 libcurl 没有任何总超时”的说法至少不应继续作为默认改道的充分理由；它需要与 pacman 当前版本的默认低速/超时行为、真实网络错误一起验证。

### 2.3 主项目当前验证（与本实验分开）

本轮未运行主安装器，也未进行真实包安装、VM 启停或物理机配置变更。已运行的只读/隔离检查：

| 检查 | 结果 |
|---|---|
| 全仓库 Bash syntax | **0 failures** |
| `tests/installer-behavior-test.sh` | **36 passed, 0 failed** |
| workstation package reconciliation | **PASS**（install=191、verify=12、deferred=8、mappings=231、recipes=15） |
| FlClash migration contract | **PASS** |
| Neovim config contract | **PASS** |
| ShellCheck | **非全绿**：命令返回 1；既有 warning 较多，当前记录仍有真实 SC1087，不能写成 clean |
| 独立 reviewer | 第一轮发现问题；修复后 blocker-only 复核结论为“无阻断发现”，但其完整 41 项执行受只读约束未独立重复，不能把该限制写成测试 PASS |
| VMware 四轮 runtime/仿物理实战 | 不属于本实验本轮，未重新执行 |

主工作树本身有上一任务遗留 dirty diff；本实验没有用 `git restore` 或全局清理覆盖它。

### 2.4 文档与代码的漂移（需单独修复）

精读现有 `docs/comprehensive-review-20260807.md` 后发现，不能把其中所有勾选项直接当作当前事实：

- 文档一处进度栏把 ShellCheck 修复标为完成，但同一文档的 P1-10/第 9 节仍记录 `SC1087`；本轮全量 shellcheck 再次复现了 `config/home/.local/bin/shorin-screenrec-menu:723:111` 的 SC1087。
- 文档历史段落记录 `installer-behavior` 为 34/34；当前工作树测试实际是 **36/36**。这属于测试契约增加后的数字漂移，不是把 36 误写回 34。
- VMware/KVM、Hyprland/DMS 和 FlClash 的旧批次结果混在同一长文档中；文档自己也要求按 `TEST_ID` 区分。没有同一最终 payload 的 artifact，就只能记为历史/未完成。
- 旧文档把 `XferCommand` 当作“超时修复”结论；本实验补充了并发代价证据，因此合并前应重写该段，而不是只复制旧批次结论。

解决方向：主代码每次变更后自动重算清单数字、测试计数、ShellCheck 状态和实验报告链接；历史记录保留，但在标题中明确 `HISTORICAL`/`UNAVAILABLE`，当前状态只从新的 checkpoint 和结果文件读取。

## 3. 实验证据

### 3.1 pacman 原生 downloader 与 XferCommand 对照

实验脚本：

```text
bin/mock-repo-server.py
bin/run-pacman-mock.py
bin/xfer-curl-wrapper.sh
results/pacman-*.json
```

所有 pacman 操作使用临时 `--config`、临时 root/db/cache 和本地 mock HTTP server；未安装 fixture 包，未写宿主数据库或缓存。

| 模式 | ParallelDownloads | mock 延迟 | 下载阶段 | 服务端最大并发 | 结果 |
|---|---:|---:|---:|---:|---|
| native | 1 | 0.6 s | 约 1.84 s | 1 | PASS |
| native | 3 | 0.6 s | 约 0.627 s | 3 | PASS |
| native | 5 | 0.6 s | 约 0.628 s | 3 | PASS |
| XferCommand | 1 | 0.6 s | 约 1.86 s | 1 | PASS |
| XferCommand | 3 | 0.6 s | 约 1.86 s | 1 | PASS |
| XferCommand | 5 | 0.6 s | 约 1.86 s | 1 | PASS |
| native repeat | 3 | 0.4 s | 约 0.428 s | 3 | PASS |
| Xfer repeat | 3 | 0.4 s | 约 1.26 s | 1 | PASS |
| native stall | 3 | server waits 12 s | sync fails at ~10 s | 1 | EXPECTED FAIL/timeout propagation |

**解释边界**：mock 服务器延迟的是每个 HTTP 请求，不模拟真实镜像带宽、TLS、PGP、磁盘、DNS、代理或完整安装事务；它只回答“pacman 在这两个配置下到底开了多少下载进程”。

### 3.2 镜像只读探测

实验脚本只发 HEAD 或有限 Range，并把 curl 返回码、HTTP 状态和错误尾部都写入 JSON。没有把超时/Range 不支持伪装成空结果。

证据文件：

```text
results/mirror-head.json
results/mirror-range-256k.json
results/package-range-1m.json
```

测量对象：官方 `coreutils-9.11-2-x86_64.pkg.tar.zst` 与 archlinuxcn `flclash-0.8.94-3-x86_64.pkg.tar.zst`。这是一次时间点样本，不应直接硬编码为永久排序。

### 3.3 原子并发下载器故障注入

实验候选（仅实验目录）：

```text
bin/batch-download.py
 tests/download-integrity-test.py
results/download-integrity.json
```

候选实现使用 Python 标准库，不依赖 aria2/axel/parallel。它提供：

- 有界 worker 数；
- `.part` 写入，成功后 checksum/size 验证；
- `os.replace` 原子发布，正式文件不会暴露半截内容；
- HTTP Range 断点恢复；Range 被服务器忽略时安全重启；
- 有限重试、指数退避、逐项错误报告；
- 任何失败项都让进程返回非零；
- manifest 路径遍历和 symlink 防护。

当前故障注入结果：**20/20 PASS**，服务端最大并发 3。覆盖：

1. 首次 503 后有限重试；
2. 连接中断后保留 `.part`，正式文件不存在；
3. 第二次用 `Range` 恢复；
4. 服务器忽略 Range 时不追加污染；
5. 完整大小但错误的 `.part` 从零重来；
6. checksum 错误不替换旧正式文件；
7. 404 失败保持非零；
8. 有效缓存零网络请求；
9. 原子发布观察不到半成品；
10. 不安全 manifest 名称 fail closed。

这是候选性质测试，不是已经批准的生产代码；真实生产接入还要补上 git source、凭据/代理策略、磁盘配额、锁竞争、清理策略和包管理事务测试。候选的 `--timeout` 是 socket 操作级预算，不等同于大文件总时限；生产实现还要明确低速、总时限、取消信号和重启后的锁语义。

### 3.4 AUR 源码预取队列模型

实验脚本：

```text
 tests/aur-prefetch-queue-test.py
results/aur-queue-model.json
```

六个独立对象、每请求固定 0.25 s 的本地模型：

| 队列 | 时间 | 最大并发 |
|---|---:|---:|
| 当前串行形状 jobs=1 | 约 1.61 s | 1 |
| 候选有界预取 jobs=3 | 约 0.59 s | 3 |

两轮重复均通过，测得约 **2.7 倍**只代表“独立源预取”的理论空间；recipe 构建、AUR 依赖、磁盘 IO、Go/Cargo 编译不能按这个倍数推断。

## 4. 代码审查发现与解决方向

### P0/P1：应优先处理

#### D-00：镜像优化晚于第一次全系统更新（P1，高置信）

- **位置**：`install.sh:176-178` 与模块循环 `install.sh:202-226` 的顺序。
- **现象**：第一次 `-Sy/-Syyu` 使用旧 mirrorlist；`01-mirror.sh` 的探测和镜像列表写入发生在这之后。用户感知的首个长等待不受 01 的优化影响。
- **方向**：把只读探测和 reviewable mirror plan 提前；应用后再做一次同步/升级。不要简单把 `01` 整个脚本前移而制造新的 keyring/reflector 循环，需先拆出“配置”和“同步”职责并做隔离测试。

#### D-01：默认 XferCommand 破坏原生并发（P1，高置信）

- **位置**：`scripts/01-mirror.sh:79-93`。
- **现象**：实际写入外部 curl 后，mock 中 p=3/5 都退化为串行。
- **方向**：删除默认插入；保留 pacman 原生 downloader 和 `ParallelDownloads`。如果某类代理确实需要外部程序，设计为显式 `--download-backend=xfer`/配置开关，并单独显示“并发能力可能下降”。不要在默认路径静默切换。
- **注意**：不要为了补救而直接把并发调到很大；先测 native p=3、5、7 在目标网络的错误率和磁盘/带宽。

#### D-02：镜像选择没有按实际包测速（P1，中高置信）

- **位置**：`scripts/01-mirror.sh:19-50`；archlinuxcn 列表在 `scripts/03-packages.sh`。
- **现象**：Aliyun `core.db` 成功只说明可达，不说明 `archlinuxcn` 或大包速度；样本中官方和 archlinuxcn 排名明显不同。
- **方向**：探测实际启用的 repo，各选 1 个数据库 + 1 个中等包，短 Range/HEAD 多次取中位数；按 repo 生成排序，并保留至少 2 个 fallback。探测失败必须保留原状态和非零/不可用信息，不当作空列表。
- **边界**：镜像测速结果有时效，建议 TTL（例如一次安装会话或数小时），不要把实验当天排序永久提交为固定事实。
- **第三步状态**：隔离 planner 已实现 lane 隔离、过期/future fail closed、至少两个 fallback 门槛、`degraded` 非零退出和 URL/诊断安全校验；尚未接入 01，也没有 apply consumer。

#### D-03：数据库同步/系统升级重复（P1，高置信）

- **位置**：`install.sh:176-178`、`scripts/01-mirror.sh:95`、`scripts/02-system.sh:12`、`scripts/03-packages.sh:94-100`。
- **现象**：首次路径先 `-Sy archlinux-keyring`、`-Syyu`，01 再 `-Sy`，02 再 `-Syu`；启用 archlinuxcn 后又同步。每次 resume 进入模块前的 pre-flight 也可能重复等待。
- **方向**：把“镜像/仓库配置 → 一次数据库同步 → 一次系统升级 → 下载/安装事务”编排成明确阶段。只有新增 repo/keyring 时做一次必要同步；`-Syyu` 仅作为显式修复模式，不作为每次默认动作。后续模块只执行安装，不自行刷新数据库。
- **风险**：修改前必须用隔离 root/db 对照验证签名、keyring bootstrap 和 resume；不能只删命令而不处理 archlinuxcn keyring 时序。

#### D-04：AUR/VMware 下载没有断点和统一缓存清单（P1，高置信）

- **位置**：`fetch-aur-sources.sh:18-50, 100-120, 123-148`；`scripts/06-aur.sh:60-100, 183-195`。
- **现象**：独立源和 VMware 大文件串行；普通 `dl()` 失败会删 `.part`；重试仍是同一 URL；非空缓存直接跳过；同一阶段既下载又构建。
- **方向**：先生成 source manifest，再做有限并发预取；每项独立 `.part`、Range 恢复、checksum/size 验证、原子 rename、独立日志和失败报告。大 VMware bundle/ISO 低优先级单独队列；git source 用临时 mirror + commit 校验后原子替换。

#### D-05：源缓存完整性不足（P1，高置信）

- **位置**：`fetch-aur-sources.sh:20` 的通用 `-s` 判断；多处 `dl` 调用未传 checksum。
- **现象**：损坏但非空的文件会打印 `SKIP`，直到 makepkg 才暴露问题；缓存内容没有和 recipe/source hash 绑定。
- **方向**：从 `makepkg --printsrcinfo` 生成 alias/URL/checksum/recipe hash 清单；有 checksum 的项一律先校验，`SKIP` 只对验证通过的完整文件；`SKIP` 项记录“仅 commit/包内校验”，不能伪造已验证。缓存 manifest 版本变化时拒绝静默复用旧对象。

### P2：应在第一轮合并后处理

#### D-06：Go/Cargo 冷缓存会把网络等待推迟到 build

- **位置**：`fetch-aur-sources.sh:150-188`；`greetd-dms-greeter-git/PKGBUILD`；`paru/PKGBUILD`。
- **现象**：源准备机没有 `go`/`cargo` 时只打印 NOTE，后续 06 构建仍需访问 proxy.golang.org/crates.io；缓存判断是目录非空，缺少按 lock/module graph 的完整性报告；`git clone`、`go mod download`、`cargo fetch` 也没有与 HTTP `dl()` 同等级的统一超时/失败预算。
- **方向**：把 Go/Cargo 依赖预取做成独立可验证阶段：Go 用固定 `go.sum`/module graph，Cargo 用 committed `Cargo.lock` + `cargo fetch --locked`；同一 cache 禁止并发写；缺缓存时明确列为网络前置，不宣称离线。

#### D-07：Git 源码失败后整个镜像删除，无法续传

- **位置**：`fetch-aur-sources.sh:41-50`。
- **方向**：临时目录/临时 bare mirror，完成后 `git fsck`、`rev-parse` 检查 pinned commit，再原子目录替换；失败保留有界诊断，不让半成品看起来是 cache。

#### D-08：`makepkg -s` 顺序正确但下载与构建耦合

- **位置**：`scripts/06-aur.sh:69-100, 183-195`。
- **方向**：只并发“源码预取”，不并发所有 makepkg。构建阶段按拓扑：`paru` → 普通独立 recipe；物理 host 的 `vmware-keymaps` → `vmware-workstation`。每个 recipe 单独 build dir，最终 pacman 事务仍保持原子/可验证。

#### D-09：离线源脚本没有按机器角色/模块裁剪（P2，中高置信）

- **位置**：`fetch-aur-sources.sh:53-148`。
- **现象**：脚本无 `--machine`/桌面参数，固定抓取全部 AUR 源，包含物理 host 专用的 VMware bundle、8 个 ISO 和 `vmware-keymaps`；即使目标是 VMware guest，也会先花时间准备不使用的 host payload。
- **方向**：让 source manifest 读取与 `03/06` 相同的 `module_selected()`/机器角色；`--machine vm` 默认跳过 host-only 大文件，`--machine physical` 才进入 VMware 队列。若用户确实要构建全量离线包，提供显式 `--include-host-payload`，并在计划中显示预计大小。

#### D-10：下载参数直接改全局 makepkg.conf，失败后可能残留（P2）

- **位置**：`scripts/06-aur.sh:45-58`。
- **现象**：AUR 阶段用 `sed` 直接改 `/etc/makepkg.conf` 的 DLAGENT；没有按本次构建生成隔离配置，也没有在中断/失败路径恢复原内容。后续用户手工 `makepkg` 也会继承这组 timeout/retry。
- **方向**：优先用项目内临时 `MAKEPKG_CONF`/显式 `DLAGENTS`，或 inventory→备份→apply→EXIT restore；对自定义配置做解析验证，不能用单个 `grep` 作为完整状态判断。

#### D-11：默认 cleanup 可能削弱后续 resume/重复安装速度

- **位置**：`scripts/99-cleanup.sh:9-12`。
- **现象**：成功后清 pacman cache 和 `.aur-build`；如果用户随后测试/重装，未安装或未保留的包会再次下载，失败诊断产物也不再可复用。
- **方向**：将清 cache 改成明确的可选动作（例如 `--clean-cache`），默认只清临时目录；失败路径保留 manifest、日志和可恢复 `.part`。

## 5. 推荐的目标下载模式（不含主代码变更）

### 阶段 A：预检与镜像排序

1. 读取当前 pacman/makepkg 配置，输出 reviewable plan；不直接改宿主。
2. 对官方和 archlinuxcn 分别探测数据库、代表包、Range 支持和短吞吐；记录 `OK`、`UNAVAILABLE`、`RANGE_UNSUPPORTED`、超时的不同状态。
3. 根据加权中位速度生成本次会话的 mirror order；第一个镜像失败时按顺序 fallback，不把失败查询转成空结果。
4. 只在用户批准的安装阶段写入临时/备份后的 pacman 配置；记录原文件和恢复路径。

### 阶段 B：官方包

1. **默认使用 pacman native downloader**，`ParallelDownloads` 先保持 3–5；不要默认 XferCommand；不要设置 `DisableDownloadTimeout` 来掩盖卡死。
2. 完成镜像/仓库配置后集中同步数据库；避免各脚本自行 `-Sy`。
3. 用 `pacman -Sw --needed`（或等价 `--downloadonly`）预取本阶段包，网络失败在“下载阶段”报告；确认缓存、签名和包依赖后，再执行安装事务。
4. 包缓存不做无条件清理；将清理作为安装结束后的显式策略。

### 阶段 C：AUR 源和大型文件

1. 从清单/`makepkg --printsrcinfo` 生成 source manifest：recipe、alias、URL/VCS ref、checksum、可得的 size、recipe hash、目标机器模块。
2. HTTP/HTTPS 独立源使用实验候选的有界队列（初始 jobs=3，配置可调），`.part` + Range + 验证 + 原子发布；每项失败独立记录，整体非零。
3. Git 源采用有限并发的 bare mirror 临时目录；完成后验证 pinned commit，再原子替换。
4. VMware bundle/ISO 单独低并发队列，支持断点；不要让一个几十 GB/数 GB 文件占住普通小源的唯一串行队列。
5. 预取全部可独立获取的源后，才运行 makepkg；不并发共享 pacman DB、同一 `SRCDEST` 写入或所有 recipe 构建。

### 阶段 D：Go/Cargo

- `greetd-dms-greeter`：固定 checkout/`go.sum`，一次 `go mod download`，确认 module cache 完整后再 build；缺 Go 工具或缺 cache 明确失败/标记网络依赖。
- `paru`：使用仓库内锁定的 `Cargo.lock`，`cargo fetch --locked`；不要在安装阶段隐式 `cargo update`；缓存写入必须串行/加锁。
- 构建时设置 `GOMODCACHE`/`CARGO_HOME` 指向已验证 cache；不要把“目录非空”当成完整性证明。

## 6. 最小合并方案（须用户明确批准后执行）

### 第一小步：低风险、优先收益

只修改主安装器下载相关逻辑：

1. 删除/禁用 `scripts/01-mirror.sh` 默认插入 `XferCommand` 的代码；
2. 保留并验证 `ParallelDownloads`，不新增 aria2/axel 依赖；
3. 把注释改成符合 pacman 7.1 行为的说明；
4. 用隔离 pacman mock 重新跑 native/Xfer 对照，确认没有意外改变配置解析。

这一小步不应顺便重构 AUR、仓库 keyring 或系统服务。

### 第二小步：减少重复同步

在隔离 root/db 中先做调用序列对照，再合并：

- 明确唯一的数据库同步/系统升级入口；
- archlinuxcn keyring 添加后只做必要的一次同步；
- 保留 `-Syyu` 的显式修复开关，不作为默认；
- 增加 invocation-count 回归测试和 resume 场景测试。

### 第三小步：动态镜像计划（隔离实验，已完成但未 apply）

`download-mode-lab/bin/mirror-plan.py` 与 `tests/mirror-plan-test.py` 已在实验目录完成，
当前 `41/41 PASS`。它只生成 reviewable JSON，不修改 01、pacman 配置或宿主。接入主代码
前必须先展示 dry-run，并明确处理 `ok`、`degraded`、`unavailable`、`stale`、`future`
和 `invalid`；默认只能自动应用 `status=ok && applyable=true`。

真实镜像探测已进行多轮，但没有 `pacman -Sw` 或完整安装前后对照，因此不能把排序样本
宣称为安装提速结果。主代码 integration 仍待用户单独批准。

### 第四小步：AUR 预取

把 `batch-download.py` 仅作为设计参考，生产接入前还需：

- 从 PKGBUILD 自动生成 manifest，禁止手工重复 URL/版本/哈希；
- 覆盖 git source、代理、磁盘不足、锁竞争、权限、取消/重启；
- 与 makepkg 的 `SRCDEST` 命名/alias 精确对齐；
- 在专用 VM 的断网/限速网络上验证后，才替换 `fetch-aur-sources.sh`；
- 构建阶段继续按依赖拓扑顺序，不因预取并发而并发 makepkg。

### 明确不采用

- 不直接把 `ParallelDownloads` 调到很高；
- 不为了“更快”盲装 aria2c/axel；
- 不并发所有 `makepkg`；
- 不使用无 checksum 下载；
- 不用 `curl | sh`；
- 不直接改宿主 `/etc/pacman.conf`、`/etc/makepkg.conf`；
- 不删除宿主 KVM/VMware 资产，不启动/修改 VM。

## 7. 合并前/合并后的验收门槛

### 7.1 当前实验目录验证状态

```bash
bash download-mode-lab/run-lab.sh
```

结果：

- integrity：20/20 PASS；最大并发 3；
- queue model：两轮均通过，串行约 1.61 s、jobs=3 约 0.59 s、约 2.7x；
- 正常 mock pacman native/Xfer 对照：sync/download exit code=0；`pacman-native-stall-test.sh` 约 10 s 非零并保留低速错误；
- 原始镜像探测结果保留失败码/HTTP 状态/错误尾部；生成计划只保留脱敏后的 `error_class`；
- source-cache 静态审计状态为 `defects_confirmed`，这是对主代码问题的证据，不是产品健康 PASS；
- 动态 mirror planner：`41/41 PASS`，连续两轮完整 lab 通过，第三轮真实 probe 契约和
  package-lane dry-run 也以 `status=ok, applyable=true` 生成（只写 `fixtures/tmp/`）。

### 7.2 尚未完成或不可用的检查

- 真实目标网络的完整 `pacman -Sw`/安装耗时：**未测**，不能由 mock 数字代替；
- AUR 真实下载/构建全链路的前后对照：**未测**；
- VMware bundle/ISO 在目标出口上的断点恢复：**未测**；
- 物理机和专用 VMware 测试 VM 的两轮回归：本实验未执行；
- Hyprland/DMS 真实登录、重登、VMware 3D/Wayland 运行时：本实验未执行；
- reviewer 第一轮发现了 planner 的输入/状态/安全边界问题；修复后 blocker-only 复核为
  **无阻断发现**，但 reviewer 没有独立运行会写临时文件的完整 41 项套件（该检查为
  unavailable），主流程仍应保留我们本地两轮 41/41 的证据；
- ShellCheck 当前仍非全绿，先修真实 error 再宣称代码清洁。

### 7.3 获批合并后必须执行

1. inventory 当前目标机；展示 dry-run/可审查计划；获得明确批准；
2. 只在专用测试 VM 做 `pacman -Sw`/配置 apply，保存不含凭据的日志；
3. 原生 downloader 与 fallback 各跑至少两轮，比较总时间、失败率、并发和缓存命中；
4. AUR source prefetch 在限速/断网/恢复场景至少两轮；
5. VMware guest 测试与仿物理 profile 各至少两轮；物理机实战部署按现有审批单独进行；
6. 检查 `pacman -Q`、签名、`.part`/cache、resume、服务和桌面运行时；
7. 任何失败查询、超时、工具缺失、reviewer 不可用都如实保留；不能以“没有输出”解释为健康。

## 8. 文件索引

### 证据与设计

- `CHECKPOINT.md`：当前状态、失败/不可用检查和唯一下一动作；
- `NEXT-STEP-PROMPT.txt`：下一模型的受控接手提示词；
- `01-inventory.md`：主链路盘点；
- `02-design.md`：候选方向与取舍；
- `03-mirror-plan.md`：第三步动态镜像排序实验；
- `results/pacman-*.json`：native/Xfer 并发对照和 native stall 超时；
- `results/mirror-*.json`、`results/package-range-1m.json`：第一轮镜像只读探测快照；重复轮次在 `fixtures/tmp/final-verification/`；
- `results/mirror-plan-test.json`：当前 41 项 planner 回归快照；
- `results/download-integrity.json`：故障注入与原子发布结果；
- `results/aur-queue-model.json`：AUR 独立源队列模型；
- `results/source-cache-audit.json`：现有 AUR cache helper 的静态缺陷证据（明确标为 `defects_confirmed`）。

### 实验工具

- `bin/run-pacman-mock.py`：隔离 pacman root/db/cache 对照；
- `bin/probe-*.py`：只读镜像探测；
- `bin/mirror-plan.py`：只生成可审查动态镜像计划，不写宿主配置；
- `tests/mirror-plan-test.py`：动态排序/新鲜度/fallback 回归；
- `run-lab.sh`：一键运行本地实验（不含网络镜像探测）；
- `bin/batch-download.py`：仅实验候选，不是生产安装器；
- `tests/download-integrity-test.py`：本地 HTTP 故障注入；
- `tests/aur-prefetch-queue-test.py`：串行/有界预取模型；
- `tests/pacman-native-stall-test.sh`：隔离 native 低速超时回归；
- `tests/source-cache-audit.py`：只读静态审计，不执行现有 fetch 脚本。

## 9. 最终建议

第一步/第二步的主工作树改动已有回归证据；第三步动态 planner 现已完成隔离验证，但仍
**没有主代码 apply**。下一步风险最低的动作不是直接改 01，而是：

> **先展示只涉及 `scripts/01-mirror.sh` 的 integration dry-run、forward/rollback patch
> 和 fake-root 回归设计；用户明确批准后，才做最小主代码集成。**

集成时必须保留 native downloader、单一同步所有权、旧 mirrorlist fail-closed、备份+原子
替换和 `status=ok && applyable=true` 门槛；不要顺便治理 AUR、服务、桌面或 VM。合并后再
按专用 VM、仿物理 profile、物理机实战及 Hyprland/DMS 验收矩阵执行，不能用本实验样本
代替真实安装耗时。
