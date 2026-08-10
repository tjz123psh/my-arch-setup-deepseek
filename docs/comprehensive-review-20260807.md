# my-arch-setup-deepseek 全面审查、问题清单与后续执行计划

> **当前有效版本：二次复审（2026-08-08）**。文件名沿用初审日期；本章及后文
> 以当前工作树为准，旧的 KVM/批次记录只能作为历史证据，不能当作当前验收结论。

- 审查对象：`/home/pang/Projects/my-arch-setup-deepseek`
- 审查基线：`main`，HEAD 为 `f44066d2a07b13a7bf542f17bde048d803ab2e6c`
- 当前工作树：本次复审正在修改中（flclash 迁移、测试和文档修改尚未提交）

> **后续模型进度（2026-08-08 14:30）**：`docs/next-model-prompt-20260808.txt` 的
> P0/P1 已按本文件第 10 节顺序实施并回归通过（详见
> `artifacts/nightly-validation-20260807/checkpoint.md` 末尾"二次复审 P0/P1 整改"）。
> 已修：06 AUR 角色过滤、sim preflight、sync-scripts 安全模型、reflector timeout、
> progress context 加强、behavior 注入/counter、hardware config ctx、Hyprland 部署
> 代码链、niri-vmtest-gen、.local/bin、vmware-keymaps 缓存名、VCS commit 固定、
> nomacs/DKMS/guest-tools/greetd required 传播、FlClash 文件验收。
> 未完成（如实）：VMware 四轮 runtime 验收、断网 AUR 构建、宿主 flclash 迁移
> （未批准）、Hyprland 真实登录/退出/重登与 3D/blur 对比。commit/push 未执行。
- 项目定位：个人 ASUS Arch Linux 恢复工具；公开 Git 仓库
- 当前用户状态：用户报告物理机实战部署已完成；VMware 测试仍在进行
- 本文性质：代码/清单/配置/文档的证据驱动复审 + 后续模型执行任务书
- 可直接复制给后续模型的提示词：`docs/next-model-prompt-20260808.txt`

## 0. 先看结论

### 0.1 可以确认的事情

1. **仓库静态资产已经比较完整，但“静态通过”不等于恢复成功。**包清单、配置映射、AUR recipe、Niri/Hyprland 配置和若干行为测试都存在；仍有脚本会把 warning 当作继续条件、机器角色没有贯穿所有阶段、桌面运行时没有真实登录/退出/重登证据。
2. **FlClash 已按用户要求从 AUR 迁移到 `archlinuxcn` 的 pacman 包。**当前目标是 `flclash`，不是 `flclash-bin`；AUR recipe、离线下载项和 AUR 执行列表已移除旧目标，启动配置改用包提供的 `flclash` 命令。安装器还加入旧包冲突迁移和逐名验收逻辑。
3. **FlClash 的真实宿主迁移本轮没有执行。**只读查询显示宿主当前仍安装 `flclash-bin 0.8.94-1`；没有删除宿主包，也没有安装 `flclash 0.8.94-3`。下一模型必须把这当作待批准的系统变更，不能写成已完成。
4. **nomacs 已在宿主存在，仓库也已有 package row、PNG MIME 映射和 acceptance 代码。**但 acceptance 目前在 `command -v nomacs` 失败时只记录普通日志，可能漏报包缺失，仍需改成 required 检查并在 VMware/物理验收中实际证明。
5. **KVM 资产必须保留。**项目恢复 payload 已把 KVM 包置为 `deferred`、把历史文件归档；这不代表可以删除宿主实际 KVM domain、qcow2、XML、快照、网络、模块或服务。当前只读状态仍显示宿主 KVM/libvirt active。
6. **VMware 验收门槛 2026-08-10 已取得。**在测试 VM（原 VM 的安全克隆 + 克隆内 pacstrap 的全新磁盘）上从 clean 基线完成了两轮真实安装：`strap.sh -t vm -d both`（VM 安装）与 `strap.sh -t physical --test-profile physical-sim-vmware -d both`（仿物理安装）。两轮均通过 install.sh 全 11 步（含 13/14 个 AUR 配方构建）、自动重启，并在装好的系统里验证了 Hyprland 会话 + DMS 栏（`dms:bar` 层 + com.danklinux.dms 窗口映射）+ kitty/nemo/FlClash 窗口映射。进程上下文：`commit=57b3bcb`，`machine=vm` 与 `machine=physical profile=physical-sim-vmware` 各一轮。
7. **Hyprland/DMS 真实运行时闭环证据 2026-08-10 已取得。**在装好的 VM 里以 stock 入口 `hyprland.desktop -> start-hyprland` 登录 Hyprland，`hyprctl layers` 显示 `dms:bar`（1280x44）与 quickshell 全屏层、`hyprctl clients` 显示 kitty/nemo/dms 窗口 `mapped: True`；`/etc/environment` 含 `LIBGL_ALWAYS_SOFTWARE=1`（VMware guest 图形变通，见 0.4）。"终端打不开/软件不显示"的原始症状已消失。

### 0.2 总判定

> **2026-08-10 更新：仓库已具备可宣称 VMware 验收完成的运行时证据。**
> 上一轮的主要缺口（真实 VM 安装、Hyprland/DMS 运行时闭环）已在测试 VM 上
> 补齐并通过；0.4 节记录本次验收发现并修复的 5 个真实缺陷与 2 个基础安装
> 对齐项。仿物理 profile 的硬件效果（GPU 切换、真实驱动加载）仍属模拟，
> 不能替代真实物理机验收；物理机最终确认仍需用户在本机跑一次。

### 0.3 本轮安全边界

本轮只在项目工作区内编辑代码、清单和文档，并做只读查询；没有：

- 安装/删除宿主软件包；
- 启停或修改宿主服务、内核模块、GRUB、网络；
- 启动、停止、快照、revert、修改 VMX 或删除任何 KVM/VMware 资产；
- 读取、打印、保存密码、token、cookie、私钥或 guest 凭据值。

项目级 `AGENTS.md` 的“唯一可写范围”和系统变更审批规则继续有效。

---

### 0.4 2026-08-10 验收：真实缺陷与修复记录

本次在测试 VM（原 VM 的安全克隆内 pacstrap 全新磁盘）上从 clean 基线跑了两轮
真实安装，发现并修复 5 个**只在 strap.sh（root）路径暴露**的缺陷（用户平时
`./install.sh` 普通用户路径不受影响），并落实 2 个基础安装对齐项：

| # | 缺陷 / 发现 | 症状（fresh VM 安装实测） | 修复 commit |
|---|---|---|---|
| 1 | `install.sh parse_args` 的 `-y/--assume-yes` 与 `--force-refresh` case 缺 `shift` | 传 `-y` 时 100% CPU 无限循环、零输出，装到一半卡死 | `decf0a6` |
| 2 | `06-aur` 先 chown 后 `cp -a 源/. 目标/`：GNU cp 会把源目录属主应用到目标目录，chown 被覆盖 | 13 个 AUR 全部报 `$BUILDDIR 无写权限` | `a89d56c`（chown 移到 cp 之后） |
| 3 | strap.sh（root）路径不创建 scoped pacman NOPASSWD drop-in | `makepkg -s` 装缺失依赖时 `sudo` 无 tty 无密码 → 4 个配方（fcft/tllist/ttf-liberation/fuse2 依赖）失败 | `b99e271`（root 路径同样创建） |
| 4 | `07-config` 只 chown 文件不 chown 中间目录（root 路径） | `niri-vmtest-gen` 写 `config.kdl.vmtest` 权限拒绝；`systemctl --user enable dms.service` 无法创建 `.wants` → 08-services required 失败 | `57b3bcb` |
| 5 | Hyprland/aquamarine 在 VMware guest 无法导入 mesa/vmwgfx dma-buf（上游 `hyprwm/Hyprland#7658`，未修复） | 所有 GL 客户端 `wl_surface.attach: invalid arguments`（kitty 打不开、软件不显示）；**不是 3D 关闭**（dmesg 3D caps 齐全，`SVGA3D;LLVM` 是正常硬件渲染串） | `62d73b0`（VMware guest 写 `LIBGL_ALWAYS_SOFTWARE=1`） |
| 6 | 蜂群审计（2026-08-10，两条路径对称性 + 边界/前置/清理）：`~/.cache` 属主链、07-config `..` 路径逃逸与备份失败静默、08-services 用户管理器引导 + NetworkManager 吞错、06-aur DLAGENT 补丁无验证、LIBGL 幂等 `=` vs `=1`、XDG_CONFIG_HOME 冲突 | 详见 `aea4fbe` 提交说明；普通用户路径的 `09-settings` 曾以 `Permission denied` 中止（LIBGL 直写 /etc/environment） | `aea4fbe` |

**普通用户路径确认（2026-08-10）**：root/strap 两轮验收之外，操作员本人在原 VM 上以 `./install.sh -t vm -d both`（pang 用户）重跑并自行验收通过（`aea4fbe` 之后）。至此三条安装路径（strap root、物理仿真实测、普通用户 `./install.sh`）均有真实运行记录。

基础安装对齐（README 已更新）：
- **内核**：03-packages 硬性前置要求 `linux-zen` 与 `linux` 并存；archinstall 默认
  只装 `linux`，需在 archinstall kernel 选项补选 linux-zen 或装后
  `pacman -S linux-zen && grub-mkconfig`。
- **faillock 事故**（修复 #3 的连锁）：makepkg 的 `sudo -k pacman` 无密码失败会
  被 pam_faillock 计为 3 次失败并锁定目标账户，导致连正确密码的 sudo 也被拒；
  #3 修复后该路径不再产生失败，无需额外代码。

验收结果（两轮均通过 install.sh 全 11 步 + 自动重启 + 运行时验证）：
- VM 安装：`-t vm -d both`，13/13 AUR，Hyprland/DMS/kitty/nemo 窗口映射，`LIBGL_ALWAYS_SOFTWARE=1` 生效。
- 仿物理安装：`-t physical --test-profile physical-sim-vmware -d both`，14/14 AUR（含 vmware-workstation），同样验收通过；首次因 codeberg 临时 504 失败一次，续跑成功。
- 全套静态测试（installer-behavior 48 + session-lifecycle 276 + pacman-sync 17 + 其余）绿。

---

## 1. 审查方法与证据纪律

### 1.1 阅读范围

精读了以下类别：

- `strap.sh`、`install.sh`、`scripts/00-utils.sh`、`scripts/01-*` 至 `09-*`、`99-cleanup.sh`；
- `manifests/workstation-packages.tsv`、`manifests/aur-recipes.tsv`、`manifests/config-mappings.tsv`；
- `third_party/aur/*` 的 `PKGBUILD`、`.SRCINFO`、review 记录；
- `config/home/.config`、`config/home/md`、`config/home/scripts`、systemd user units；
- `README.md`、`config/README.md`、`docs/project-vision.md`、`docs/how-to-extend.md`、离线指南和历史 handoff；
- `tests/`、`fetch-aur-sources.sh`、`sync-scripts.sh` 和当前 artifact 元数据。

### 1.2 查询结果的表述规则

- 命令退出非零时写成**失败/不可用**，不写成“没有发现”；
- “宿主当前存在”与“项目代码会恢复”分开记录；
- `UNAVAILABLE`、`NOT_APPLICABLE_SIMULATED`、`INFRA_FAIL`、`PRODUCT_FAIL` 不得计为 PASS；
- 旧 KVM 文档中的路径和测试密码不复制到新文档；历史 handoff 中曾出现凭据字段，当前工作树已脱敏，但外部凭据仍应轮换/撤销，Git 历史也不能因此视为安全。

### 1.3 本轮已做的只读包查询

`pacman -Si flclash` 成功，关键字段为：

```text
repository : archlinuxcn
package    : flclash
version    : 0.8.94-3
conflicts  : none
replaces   : none
```

`pacman -Qi flclash-bin` 成功，宿主当前包为 `flclash-bin 0.8.94-1`，它：

- `provides = flclash=0.8.94`；
- `conflicts = flclash`；
- 不是同步数据库中的 pacman 目标包。

`pacman -Si flclash-bin` 返回非零“package not found”，这是**查询不可用/同步库中没有 AUR 包**，不是“系统没有该包”；系统安装状态由 `pacman -Qi` 单独确认。

只读流式查看目标包内容确认它提供：

```text
/usr/bin/flclash
/usr/lib/flclash/FlClash
/usr/share/applications/com.follow.clash.desktop
/usr/share/pixmaps/flclash.png
```

因此启动配置改用 `Exec=flclash` 是比硬编码旧 recipe 路径更稳的方向；desktop entry 文件名不能假定为旧包的 `flclash.desktop`，必须在验收中检查实际包文件。

---

## 2. 当前清单基线与变更后统计

### 2.1 变更后包清单

| 项目 | 数量 | 说明 |
|---|---:|---|
| package manifest 总行数 | 211 | 不含注释 |
| `policy=install` | 191 | 真正尝试安装 |
| `policy=verify` | 12 | 手工交接硬前置，不自动安装 |
| `policy=deferred` | 8 | KVM 历史资产，不进入安装 |
| install / pacman | 177 | 含 core/extra/archlinuxcn |
| install / AUR | 14 | 目标 AUR 包 |
| AUR recipe manifest | 15 | 14 目标 + `vmware-keymaps` 构建依赖 |
| recipe 目录 | 15 | 与 manifest 一致 |
| config mappings | 231 | `physical-v1` 映射行 |
| config regular files | 330 | 当前工作区统计 |

FlClash 行现在是：

```text
flclash  pacman  archlinuxcn  pacman  personal-autostart  config-backed  install
```

### 2.2 迁移后的主动修改文件

- `manifests/workstation-packages.tsv`：`flclash-bin` → `flclash/pacman/archlinuxcn`；
- `manifests/aur-recipes.tsv`：删除 `flclash-bin`；
- `scripts/06-aur.sh`：AUR 目标列表从 15 减为 14；
- `fetch-aur-sources.sh`：删除旧 Debian 和 QuickJS bridge 下载项；
- `third_party/aur/flclash-bin/`：删除旧 AUR recipe tree；
- `scripts/03-packages.sh`：显式处理旧包冲突，安装后按精确包名验收；
- `config/home/.config/autostart/FlClash.desktop`：`Exec=flclash`；
- `config/home/.config/hypr/conf/autostart.lua`：用 `flclash` launcher；
- `config/home/md/archlinux/Shorin-ArchLinux-Guide-合集.md`：标注 `archlinuxcn` 来源和迁移冲突；
- `README.md`、`docs/project-vision.md`、离线指南、增改指南：同步当前数字和语义；
- `tests/flclash-migration-test.sh`：静态迁移契约测试。

### 2.3 仍需留意的统计/文档漂移

历史 `docs/handoff-20260805.md`、`docs/handoff-20260806.md` 保留旧批次数字是有意的历史记录，但已加历史提示，不能作为当前状态来源。当前状态只看 README、project vision 和本文。本次修改后还必须：

1. 重跑 reconciliation，确认 191/12/8、177/14、231/15；
2. 对所有 recipe 运行 `makepkg --printsrcinfo`，确认 15/15；
3. 重新生成/清理 `.aur-sources`，确认不再包含旧 FlClash AUR 输入；
4. 检查 staged diff 和 secret scan；
5. 将最终 payload hash 写入新的 VM `TEST_ID`，不能复用迁移前 artifact。

---

## 3. FlClash 从 AUR 到 archlinuxcn 的迁移审查

### 3.1 为什么不能只改一行包名

目标仓库包声明 `conflicts/replaces = none`；旧 AUR 包声明提供虚拟名并与目标冲突。直接运行：

```bash
pacman -S --needed --noconfirm flclash
```

在旧包仍安装时会进入“删除 `flclash-bin`?”冲突路径；非交互的 `--noconfirm` 不能可靠地替代一个明确的迁移策略。因此 `03-packages.sh` 采用了：

1. 只有当 `flclash` 被当前机器/桌面选择选中时才进入迁移；
2. 检测**精确包名** `flclash-bin`；
3. 用不带 `-s/-Rns` 的 `pacman -R --noconfirm flclash-bin` 删除旧包本体，尽量不碰共享依赖；
4. 执行官方/archlinuxcn 批量安装；
5. 在完整 `pacman -Qq` 列表上用 `grep -Fx flclash >/dev/null` 确认新包名存在，用 `grep -Fx flclash-bin >/dev/null` 确认旧包不存在，否则非零退出、不写完成状态。

这解决了截图中的冲突语义，但仍有一个**可接受前提**：删除旧包后若镜像或目标包安装失败，系统会暂时没有 FlClash。后续模型应把“先预下载目标包/使用本地缓存后再做替换”作为更强的事务化改进方向；至少要保留 pacman 日志、非零退出和重跑指引，不能静默继续。

### 3.2 启动与 desktop entry 兼容性

目标包实测文件列表显示 `/usr/bin/flclash` 和 `/usr/lib/flclash/FlClash` 均存在，但目标 desktop entry 是 `com.follow.clash.desktop`。本项目自定义自启动不依赖 desktop entry 文件名，改为调用命令：

- GTK/XDG 自启动：`config/home/.config/autostart/FlClash.desktop` 的 `Exec=flclash`；
- Hyprland：`pgrep -x FlClash >/dev/null || flclash`；
- Niri/DMS：仍需在 VMware/物理登录中确认 XDG 自启动不会重复拉起两个实例。

**验收方向：**

```bash
pacman -Qq | grep -Fx flclash
pacman -Qq | grep -Fx flclash-bin  # 应非零；非零要记录为“旧包不存在”，不是失败查询
command -v flclash
test -x /usr/bin/flclash
test -x /usr/lib/flclash/FlClash
desktop-file-validate /usr/share/applications/com.follow.clash.desktop
pgrep -af '[F]lClash'         # 只检查进程名，不记录用户代理配置
```

若 `pacman -Qq flclash-bin` 查询失败，必须结合 `pacman -Qq` 的退出码和完整包列表判断；不能把“查询命令失败”写成“迁移成功”。

### 3.3 离线缓存注意事项

FlClash 现在来自 archlinuxcn，不应再进入 AUR cache。旧 `.aur-sources/` 即使残留旧 `.deb`/bridge 文件，也不会被新 06 使用，但会造成供应链和体积混淆；重新打包缓存前应在缓存目录内删除它们并记录 manifest。当前发现另一个独立 cache defect：

```text
fetch-aur-sources.sh 下载 vmware-keymaps-1.0.tar.gz
PKGBUILD/.SRCINFO 需要 vmware-keymaps-1.0-3.tar.gz
```

后续模型必须修正文件名或建立明确的 source alias，并离线构建验证；不能因为下载脚本返回成功就认为 makepkg 能命中缓存。

---

## 4. 宿主 `~/.config`、`~/md`、`~/scripts` 同步审查

### 4.1 差异盘点

根据 `manifests/config-mappings.tsv` 对映射目标做的只读比较：

| 状态 | 数量 |
|---|---:|
| 内容相同 | 182 |
| 内容不同 | 22 |
| 宿主缺失、仓库仍有映射 | 1 |
| 仓库缺失 | 0 |
| 类型不匹配 | 0 |

内容不同的 22 项主要包括手工 Niri/Hyprland/Nvim 配置、DMS/Matugen 运行时主题、MIME 默认关联、`quicksave` 和用户快捷键文档。宿主缺失但仓库仍映射的是历史 KVM 优化文档；它不应触发自动删除宿主数据，也不应继续作为 active KVM 方案。

### 4.2 必须先处理的秘密边界

历史 handoff 中发现过 guest 密码/命令行凭据字段，当前工作树已将文档中的值脱敏；宿主 Fish 配置此前也发现凭据赋值形态。只报告位置和权限，不记录值：

- `/home/pang/.config/fish/config.fish`：曾发现凭据赋值形态，权限需复核；
- `/home/pang/.config/fish/conf.d/age-api-key.fish`：曾发现凭据赋值形态；
- `docs/handoff-20260805.md`、`docs/handoff-20260806.md`：历史 credential-bearing 内容已脱敏，但旧 Git 历史可能仍含原文；
- ignored 的 `artifacts/nightly-validation-20260807/` 也曾有凭据描述字段，当前工作区已做值级脱敏；它仍是旧测试证据，不得重新用于验收。

**解决方向：**

1. 立即轮换/撤销曾经出现在公开工作区或命令行中的外部凭据；
2. 只保留 `private-env.fish`、受控 secret manager 或运行时注入引用；
3. 同步工具发现疑似秘密时必须 fail closed，不能“计数后继续 rsync”；
4. staged diff、Git 历史和发布包分别扫描，扫描失败与命中分别报告；
5. 不把 `~/.config`、浏览器/聊天/代理配置、cookies、数据库、私钥整目录镜像进公开仓库。

### 4.3 `sync-scripts.sh` 当前问题

文件：`sync-scripts.sh`，核心位置：secret gate、`mkdir -p`、rsync `--delete` 和 `set -uo pipefail`。

问题：

- 命中疑似凭据只增加 `blocked` 计数，`--apply` 仍对整个源目录执行 rsync；
- plan 模式也先创建目标目录，严格说不是完全只读；
- `set -uo pipefail` 没有 `-e`，部分命令失败可能继续；
- apply 没有 staging/备份/可靠 rollback，`--delete` 可能删除仓库已有文件；
- 映射补全只看目标文件，不校验源/目标唯一性、模块归属和删除计划。

**推荐实现方法：**

1. inventory 阶段输出 `same/changed/new/deleted/type-mismatch`，保存退出码；
2. secret gate 只要命中就停止 apply，不执行任何 rsync；
3. plan 阶段不 mkdir、不写 mapping；
4. apply 先在工作区内建立临时 staging 和带时间戳备份，生成 rsync dry-run 清单，经明确批准再切换；
5. mapping 变更单独生成 patch，校验路径不得 `..`、source 存在、mode 合法、无重复；
6. apply 后做 gitleaks/关键词扫描和人工 diff；失败能从工作区内备份恢复。

### 4.4 配置分类与生成物

不可盲目同步的内容：

- Fish 凭据、备份文件、cache、socket、lock、nested `.git`；
- DMS/Matugen 生成的 alacritty/fuzzel/GTK/Hyprland/Kitty/Niri/dgop 主题文件；
- Niri 当前布局、Fish variables、DMS first-launch/changelog 等运行时状态。

可审查落库的内容：

- `niri/config.kdl`、`niri-vmtest-gen`、快捷键文档；
- 经过 portable 审查的 Nvim 变更；
- nomacs 的 MIME 关联；
- VMware 运维笔记；
- 明确没有秘密的维护脚本。

`niri-vmtest-gen` 已在隔离目录验证过幂等和 Niri 语法，但安装器没有自动生成 `config.kdl.vmtest` 的必经步骤；干净恢复后若普通 `config.kdl` 引用生成文件而文件尚不存在，必须明确失败或在部署后生成/验证。

仓库仍没有创建宿主现有的：

```text
~/.local/bin/niri-keys
~/.local/bin/hypr-keys
~/.local/bin/b23
```

如果配置依赖这些入口，需在安装器中幂等创建 symlink 并验收 target；否则保留脚本原路径并同步修正引用。

---

## 5. nomacs 任务复核

### 5.1 已确认事实

- 宿主只读查询：`nomacs 1:3.23.2-1`，来自 archlinuxcn；
- manifest 已列为 `pacman/archlinuxcn`、`desktop-apps`、`config-backed`；
- `config/home/.config/mimeapps.list` 将 `image/png` 默认关联到 `org.nomacs.ImageLounge.desktop`；
- `scripts/09-settings.sh` 有包、desktop entry 和 MIME 检查。

### 5.2 仍有的验收漏洞

`09-settings.sh` 目前先判断 `command -v nomacs`；命令不存在时只输出“nomacs not present”，不会让 required 安装阶段失败。并且 `xdg-mime`/desktop entry 检查的退出码被局部 `|| true` 包装，必须确认最终状态是否传播。

**整改方法：**

- 将 nomacs 作为 manifest 中 required install row；包阶段后用精确 `pacman -Qq nomacs` 验收；
- 无论命令是否在 PATH，都检查 `/usr/bin/nomacs` 或 `pacman -Ql nomacs` 的实际文件；
- 检查目标 desktop entry 的实际名称，不把 `org.nomacs.ImageLounge.desktop` 当成未经查询的常量；
- 在用户图形会话中执行 `xdg-mime query default image/png`，把查询失败单独标为 `CHECK_FAILED`；
- JPEG/WebP/TIFF 是否改为 nomacs 仍需用户明确决定，不从 PNG 推导。

---

## 6. KVM → VMware 迁移复核

### 6.1 绝对边界

“删除 KVM”只表示未来由本项目恢复的系统不再主动安装/启用 KVM host 栈；**不表示**删除物理宿主的 KVM/libvirt VM 或任何虚拟磁盘。禁止：

- 删除/移动/重命名 KVM domain、qcow2、XML、snapshot、网络；
- 卸载宿主 KVM 软件、停用 `libvirtd`、改 `kvm/kvm_amd` 模块；
- 删除或修改 VMware 真实 VMX/VMDK。

当前 manifest 的 8 个 KVM/QEMU/SPICE 条目仍保留为 `deferred`，这是历史审计记录，不是 active install；历史文件已归档到 `docs/archive/kvm-20260808/`。后续可进一步把它们移到显式 archive manifest，但不能误删宿主资产。

### 6.2 宿主只读状态

本轮读到：

```text
vmware-workstation 26H1-3       present
open-vm-tools 6:13.1.0-2       present
vmware-networks.service         enabled + active
vmware-usbarbitrator.service    enabled + active
supergfxd.service               enabled + active
libvirtd.service                enabled + active  (必须保留)
systemd-detect-virt             none（当前物理宿主）
```

`vmtoolsd`/`vmware-vmblock-fuse` 在物理宿主 disabled/inactive 是合理的 guest 条件结果；不能据此宣称 VMware guest 测试通过。

### 6.3 角色混装风险

`03-packages.sh` 使用 `module_selected()` 过滤 `virtualization-vmware-host`/`virtualization-vmware-guest`，但 `06-aur.sh` 的 `RECIPES` 仍硬编码并无机器角色过滤。因此：

- `-t vm` 仍可能构建/安装 `vmware-workstation` 和 `vmware-keymaps`；
- `physical-sim-vmware` 仍可能在 VMware guest 内构建 host Workstation；
- 这会让当前 VM 测试既慢又不能证明“guest 不装 host 栈”。

**解决方法：**让 06 从 package/recipe manifest 读取目标，调用同一 `module_selected()`；`vmware-keymaps` 只在 physical 选择了 `vmware-workstation` 时 bootstrap；VM 模式只选择 `open-vm-tools` 及 guest 服务。增加测试矩阵：

```text
physical: vmware-workstation + keymaps selected; open-vm-tools excluded
vm:       open-vm-tools selected; vmware-workstation + keymaps excluded
```

### 6.4 VMware host/guest 验收

物理/host：

- 当前内核 headers 与 DKMS 匹配；
- `dkms status` 同时证明 `vmmon`/`vmnet`；
- `modprobe -n vmmon vmnet` 成功；
- `vmware-networks.service`、`vmware-usbarbitrator.service` enabled+active；
- 不 enable static `vmware-networks-configuration.service`，不寻找不存在的 `vmware-vmnet.service`；
- host 服务或 DKMS 失败必须 required failure，不得只 warning。

VM/guest：

- `systemd-detect-virt` 必须返回 `vmware`；
- `open-vm-tools` 精确包名存在；
- `vmtoolsd.service` active；需要复制粘贴/拖放时再验收 `vmware-vmblock-fuse.service`；
- 不安装/启用 VMware host 服务或 KVM host 栈。

### 6.5 VMware 测试基础设施

现有 artifact 记录：

```text
TEST_ID=2c604a328ef672be：VM-R1 只有 metadata，没有最终 result
TEST_ID=2620613ddbb71195：VM-R2、PHY-R1、PHY-R2 = UNAVAILABLE
```

旧 ID 与当前 migration payload 不兼容。下一轮必须：

1. 冻结最终 Git commit/dirty diff、manifest hash、recipe hash、source-cache manifest；
2. 为这组输入生成新 `TEST_ID`；
3. 从同一 clean baseline snapshot 开始；
4. 每轮安装、验收、记录、revert；
5. 四个 round 全部同一最终 ID 且 `PASS` 才算完成。

---

## 7. VMware guest 中 Hyprland/DMS 专项

### 7.1 已排除和已确认

- 旧宿主/生成配置曾通过 `Hyprland --verify-config`，但仓库本身只保存 Lua fragments；
  本轮对仓库假定的 `hyprland.conf` 路径查询失败，因此当前 repo-level 语法证据不足；
- `dms run -d` 是有效命令，但不能据此证明会话生命周期正确；
- Niri/DMS 在当前物理用户会话中可见 active；
- 宿主当前精确包查询显示 `dms-shell-hyprland 1.5.3-1` 存在，而 `dms-shell-niri`
  未安装；这不是仓库 `-d both` 干净恢复的证据，必须在目标 VM 中按 manifest 分别验收；
- 仓库新增 `config/home/.config/systemd/user/hyprland-session.target`，并映射到 `config-mappings.tsv`；
- 当前物理用户的 `systemctl --user cat hyprland-session.target` 返回非零，说明该源文件尚未部署/加载到当前会话；`is-active` 也不是 active。

所以“Hyprland 配置语法错误”不是目前最有证据的解释；高概率问题仍是登录入口、DBus/systemd 用户环境和 DMS 生命周期，VMware SVGA3D/blur 是待隔离的第二类变量。

### 7.2 当前启动链风险

`config/home/.config/hypr/conf/autostart.lua` 现在：

1. `dbus-update-activation-environment --systemd --all`；
2. `systemctl --user start hyprland-session.target`；
3. 由 target 拉起 `graphical-session.target`、`xdg-desktop-autostart.target`，再由 `dms.service` 管理 DMS。

这个设计比直接 `dms run -d` 好，但尚未真实证明：

- `hyprland-session.target` 在干净恢复后确实被 07 部署并被 user manager 读取；
- greetd `--command hyprland` 能进入该链，而不是只在 TTY 手工启动；
- 退出 Hyprland 后 DMS、graphical target、XDG autostart 服务全部清理；
- 再次登录不会重复启动 DMS/FlClash；
- VMware 3D 开启时 Qt/Quickshell blur 不崩溃。

### 7.3 分层解决/测试方法

按以下顺序做，不能一上来只关 blur：

1. **入口层**：从项目配置的 greetd 入口登录 Hyprland，保存 greetd、user manager 和 Hyprland 启动日志；
2. **环境层**：记录 `systemctl --user show-environment`、`WAYLAND_DISPLAY`、`HYPRLAND_INSTANCE_SIGNATURE`、`XDG_CURRENT_DESKTOP`；值若含秘密不得写入日志；
3. **服务层**：检查 `systemctl --user status dms.service`、`journalctl --user -b -u dms.service`、target 依赖和重启次数；
4. **功能层**：DMS 状态栏、通知、壁纸、IPC、关键插件、FlClash 单实例；
5. **退出/重登层**：注销后确认 DMS/target 不残留，再登录两次；
6. **渲染层**：固定启动链后，分别比较 VMware 3D on/off、DMS blur on/off、Hyprland blur/animation on/off；每次只变一个变量。

建议只采集以下不含凭据的证据：

```bash
dms doctor
systemctl --user status dms.service
journalctl --user -b -u dms.service
systemctl --user status graphical-session.target
systemctl --user list-dependencies graphical-session.target
pgrep -af 'dms|qs'
hyprctl configerrors
hyprctl systeminfo
systemctl --user show-environment
printf 'WAYLAND_DISPLAY=%s\n' "${WAYLAND_DISPLAY:-}"
printf 'XDG_CURRENT_DESKTOP=%s\n' "${XDG_CURRENT_DESKTOP:-}"
```

任一命令非零都要写 `CHECK_FAILED` 并保留退出码，不得改写成“没有问题”。

---

## 8. 代码与文档问题清单（按优先级）

下面是当前仍需后续模型处理的问题；每项都给出方向，不把建议误报成已修复。

### P0 — 会造成假成功、错误角色或安全事故

#### P0-1 AUR 阶段没有机器角色过滤

- 位置：`scripts/06-aur.sh` 的 `RECIPES` 数组、`vmware-keymaps` bootstrap；
- 现象：VM 模式仍构建 host-only Workstation；
- 影响：VM 测试失败/极慢，且违反 guest 不装 host 栈的目标；
- 方法：以 `manifests/workstation-packages.tsv` 的 install rows 为唯一目标源，用 `module_selected` 过滤；依赖 recipe 单独拓扑排序；加 physical/vm 反向断言。

#### P0-2 仿物理 profile 没有强制确认 VMware

- 位置：`install.sh` 参数校验、`scripts/04-drivers.sh` 和 `08-services.sh` 的 `TEST_PROFILE` 分支；
- 现象：只要求 `-t physical`，不检查 `systemd-detect-virt == vmware`；
- 影响：模型可能在真实物理机误用 simulated profile，或在其他虚拟化环境把结果写成 VMware 证据；
- 方法：profile 启动时做只读 virtualization preflight；失败则 `CHECK_FAILED`/abort；把检测结果写入 artifact metadata；真实物理机不能使用该 profile。

#### P0-3 四轮 artifact 不能计 PASS

- 位置：`artifacts/nightly-validation-20260807/`（ignored，非当前 payload 证明）；
- 现象：四轮没有同一最终 `TEST_ID` 的四个 `result.json` PASS；
- 方法：冻结 payload/source cache/snapshot，失败轮不计数；每轮必须有 metadata、stdout/stderr、退出码、包/服务 delta、配置验证、DMS 证据、result；最终 summary 只接受同一 ID 的四个 PASS。

#### P0-4 `sync-scripts.sh --apply` 可能带着秘密继续写入

- 位置：`sync-scripts.sh` 的 secret gate 与 apply rsync；
- 现象：只计数不 fail closed；plan 仍 mkdir；无 rollback；
- 方法：秘密命中立即退出；全程 `set -Eeuo pipefail`；plan 零写入；staging + backup + dry-run diff + 明确批准后切换；失败可恢复。

#### P0-5 公开历史文档曾保存 credential-bearing 内容

- 位置：历史 `docs/handoff-20260805.md`、`docs/handoff-20260806.md`；当前值已脱敏，但历史 Git 对象可能仍在；
- 方法：轮换/撤销所有曾暴露的凭据；对 Git 历史和发布包做扫描；必要时在用户确认后重写公开历史；以后只记录凭据位置/权限/可用性布尔值。

#### P0-6 FlClash 替换不是完整事务

- 位置：`scripts/03-packages.sh` 的迁移块；
- 现象：目标包没有 `replaces`，代码先移除旧包再批量安装；镜像故障时会暂时无 FlClash；
- 方法：先 `--downloadonly`/本地缓存并验证 checksum，再在同一维护窗口移除旧包、安装目标；失败保留缓存和明确 rollback；禁止在无人批准时直接改宿主。

### P1 — 会导致功能缺失或验证不可信

#### P1-1 配置映射排除了 hardware module

- 位置：`scripts/00-utils.sh:module_selected`、`scripts/07-config.sh`；
- 现象：所有 `graphics-*`/`hardware-tools`/`asus-hardware` mapping 被跳过；例如 `rog-control-center.cfg` 即使 physical 也不会由 07 部署；
- 方法：区分“04 已安装的硬件包”和“07 应部署的硬件配置”，不要用同一 unconditional return；为 physical config mapping 加验收。

#### P1-2 progress context 不含 profile、脚本、配置、harness 和 source cache

- 位置：`scripts/00-utils.sh:progress_context`；
- 现象：`physical` 与 `physical-sim-vmware` 可能拥有相同 context；脚本/配置/AUR 内容变化未必被检测；
- 方法：加入 `TEST_PROFILE`、脚本 hash、关键 config hash、recipe/source-cache manifest、测试 harness 版本；变化即新 ID/拒绝 resume。

#### P1-3 behavior test 的隔离和注入不可信

- 位置：`tests/installer-behavior-test.sh` 与 `scripts/07-config.sh`；
- 现象：测试设置的 `MAPPINGS`/`CONFIG_SRC` 会被 07 内部固定值覆盖；`skipped: 1` 子串会误匹配 `skipped: 114`；历史上曾发生测试覆盖宿主 HOME 的事故；
- 方法：脚本允许受控 dependency injection；测试把 HOME/TARGET_HOME/MAPPINGS/CONFIG_SRC 全部绑定到工作区内 sandbox；解析结构化 counters，不能用模糊 substring；测试失败时保留 sandbox 日志并清理。

#### P1-4 Hyprland/DMS provider 与会话生命周期没有统一 runtime 证明

- 位置：`config/home/.config/systemd/user/hyprland-session.target`、`autostart.lua`、`scripts/08-services.sh`；
- 现象：当前物理用户 target not-found/inactive；Hyprland 真实登录/退出/重登未验收；
- 方法：让 07/08 明确部署、daemon-reload、启用/停止 target；从 greetd 入口做两次登录和一次退出清理；优先采用一个明确的 UWSM/standard target 设计，不混用多个生命周期。

#### P1-5 Niri VM test 生成物没有安装器必经校验

- 位置：`config/home/scripts/desktop/niri-vmtest-gen`、Niri `config.kdl`、07；
- 方法：部署正常 config 后幂等运行生成器；检查输出存在、hash 稳定、普通 config 不变；`niri validate` 两份都通过；生成失败必须非零。

#### P1-6 `.local/bin` 入口缺少创建/验收逻辑

- 位置：mapping 和 `scripts/09-settings.sh`；
- 方法：选择“保留脚本原路径”或显式创建 `niri-keys`/`hypr-keys`/`b23` symlink；每个 target 必须存在且不越出 HOME。

#### P1-7 VMware source cache 文件名错位

- 位置：`fetch-aur-sources.sh` 的 vmware-keymaps 下载项与 `third_party/aur/vmware-keymaps/PKGBUILD`；
- 方法：下载名、PKGBUILD source alias、checksum 三者一致；在断网环境真正执行 makepkg，而不是只看 fetch 日志。

#### P1-8 required 服务/GRUB/DKMS/guest tools 失败仍可能 warning/跳过

- 位置：`scripts/08-services.sh`、`scripts/09-settings.sh`；
- 现象：许多 `|| true`、缺 unit 只 warning；physical VMware DKMS、greetd、GRUB、nomacs 和 guest tools 可能未就绪但步骤仍成功；
- 方法：按 machine role 建 required/optional 清单；required 单项失败非零并保留诊断；simulated profile 只能把明确 host-only 动作标记 N/A。

#### P1-9 `01-mirror.sh` 的 timeout 不能执行 shell function

- 位置：`timeout 60 run reflector ...`；
- 现象：`run` 是 Bash function，timeout 直接找不到外部命令（已复现 rc=127）；
- 方法：使用 `timeout 60 bash -c '...'` 并安全传参，或对 root/non-root 分支分别调用实际命令；对 timeout rc 单独分类。

#### P1-10 ShellCheck 仍有真实 error

- 位置：`config/home/.local/bin/shorin-screenrec-menu:723:111`；
- 现象：`SC1087`，不是可忽略的 source/TSV 提示；当前复核基线为 134 findings（error 1、warning 64、info 69）；
- 方法：修正数组下标/参数展开，重新跑全仓库 Bash 文件；warning/info 要分类，不得把 error 清零写成已完成。

#### P1-11 AUR recipe 的供应链验证不完整

- 位置：`third_party/aur/greetd-dms-greeter-git/PKGBUILD`、各 VCS recipe；
- 现象：VCS source 未固定 upstream commit、checksum `SKIP`、`go test ./... || true` 吞测试失败；
- 方法：固定 commit、记录来源和 checksum；测试失败按 required 处理；离线构建后做包文件清单和运行 smoke test。

#### P1-12 Hyprland payload 不是可独立验证的单一配置

- 位置：`config/home/.config/hypr/`（`hyprland.lua` + `conf/*.lua` fragments）；
- 现象：本轮传入仓库不存在的 `hyprland.conf` 后，Hyprland 返回 canonical path 不存在；只能在已安装 DMS/生成器的宿主上间接验证；
- 方法：提供隔离 HOME 下的最小生成/验证 harness，或明确记录 DMS provider 生成最终配置的步骤；生成后再运行 `Hyprland --verify-config`，失败必须阻止 acceptance。

#### P1-13 root/普通用户 sudo 路径不一致

- 位置：`install.sh`、`scripts/00-utils.sh`、`scripts/06-aur.sh`；
- 现象：root strap 路径的 `runuser + makepkg -s` 可能需要目标用户 sudo；普通路径 `sudo -k` 会使 07/08/09 后续再次提示；sudoers cleanup 失败被 `|| true` 遮蔽；
- 方法：预先 inventory 权限模型，使用项目约定的 `~/scripts/desktop/gsudo --` wrapper；测试 root/普通用户两条路径；cleanup 失败必须显式报告。

### P2 — 结果看似成功但证明强度不足/文档漂移

#### P2-1 verify-only 只检查 `pacman -Q`

`03-packages.sh` 的 12 项 verify 目前主要是包存在性；不能证明真实 GRUB 安装、initramfs 内容、文件系统挂载、NetworkManager 联网或 boot entry 正确。解决方向是把可自动验证的事实写成命令，不能用包名替代运行态；不可验证项标为 handoff/manual，并保存退出码。

#### P2-2 nomacs acceptance 条件过宽

见第 5 节；命令不存在时应 required failure，desktop entry/MIME 查询失败不能静默跳过。

#### P2-3 `gitleaks` 绿灯不是历史安全证明

简单数字密码、命令行参数和用户文档中的环境值可能不被规则命中；必须人工审查 staged diff，并轮换历史暴露凭据。

#### P2-4 Markdown/文档质量

映射的 `config/home/md/archlinux/Shorin-ArchLinux-Guide-合集.md` 当前代码围栏数量为奇数（初次统计 1875），另有尾随空格；运行 Markdown lint/围栏平衡检查，修复后再把文档当作可执行指南。

#### P2-5 当前文档与远端/历史状态可能漂移

README、project vision、offline guide 已更新为 177 pacman + 14 AUR；历史 handoff 保留旧数字并标记为历史。每次 code/manifest 改动后必须重算数字、更新当前文档，并检查 `git status`/remote；未 push 的 dirty tree 不能成为 VM 测试 payload。

---

## 9. 已通过、未通过和不可用检查

以下状态必须随最终 payload 重跑；“通过”只表示对应检查本身通过。

### 9.1 已知通过（静态/隔离）

- Bash 语法检查：迁移后当前 Git/工作区 shell 文件 69/69 PASS（旧 flclash launcher 删除后文件数减少）；
- `tests/workstation-package-reconciliation-test.sh`：当前 PASS，输出 `install=191 verify=12 deferred=8 total=211, mappings=231, recipes=15`；
- `tests/flclash-migration-test.sh`：当前 PASS（只检查工作区契约，不改系统）；
- `tests/nvim-config-test.sh`：当前 PASS；
- `tests/installer-behavior-test.sh`：当前 34/34 PASS，但其注入/计数缺陷仍需修复后重新信任；
- `makepkg --printsrcinfo`：当前迁移后 15/15；
- `niri validate`：当前宿主配置 PASS；仓库只保存 Hyprland Lua fragments，没有可直接传给
  `Hyprland --verify-config` 的单一 `hyprland.conf`，本轮对仓库路径的直接查询失败
  （canonical path 不存在），因此 Hyprland repo-level syntax check 当前是 `UNAVAILABLE`，不能沿用旧“PASS”文案；
- JSON/TOML/Fish 语法、当前仓库 desktop-file-validate、gitleaks 扫描：当前 PASS，但不替代人工秘密审查。

### 9.2 当前明确失败/风险

- ShellCheck：error 1（SC1087），不能写成 error clean；
- `timeout 60 run reflector`：已复现 rc=127；
- 当前物理用户 `hyprland-session.target`：`cat` 查询非零/not-found；
- AUR/VMware 角色过滤：代码路径仍无统一过滤；
- FlClash 宿主 live migration：尚未执行，当前旧包仍在。

### 9.3 不可用或未完成

- VMware guest 四轮安装/登录/退出/revert：未取得合格四轮；
- 真实 Hyprland VMware guest DMS 故障复现：没有当前 guest journal，不能定唯一根因；
- 断网全 AUR 构建：未完成；
- 真实 physical host 重新部署：本轮未执行；用户报告已完成，但属于用户报告/宿主只读状态，不是本轮独立验收；
- reviewer：已请求独立只读复核，但 reviewer 在等待窗口内超时并关闭；状态为
  `UNAVAILABLE`，不能当作 PASS，也没有把其当作通过依据。

---

## 10. 推荐实施顺序（给后续模型）

### 阶段 A：先修会导致假成功的 P0

- [ ] 轮换/撤销历史暴露凭据，确认 staged diff 无值（需用户/外部操作，仓库侧已脱敏）
- [x] 让 `sync-scripts.sh` secret gate fail closed、plan 零写入、apply 可回滚
- [x] 让 06 AUR targets 按 machine role 过滤
- [x] 给 `physical-sim-vmware` 增加 VMware virtualization preflight
- [x] 修复 ShellCheck error、reflector timeout function
- [x] 保留 FlClash 迁移非零/日志语义，考虑预下载后替换（迁移逻辑+验收已实现）

### 阶段 B：修桌面与服务生命周期

- [x] 修 P1-1 hardware config selection
- [x] 完善 progress context
- [x] 重构 behavior harness 的 dependency injection 和 sandbox
- [x] 让 Hyprland target 部署、daemon-reload、greetd 登录、退出清理可证明（代码链；runtime 留待 VM）
- [x] 让 Niri VM generator 生成物成为安装器明确步骤
- [x] 将 required/optional 服务和 nomacs acceptance 分层

### 阶段 C：供应链与离线

- [x] 修 vmware-keymaps cache 名称/alias/checksum
- [x] 固定 VCS recipe commit，移除 `go test ... || true`
- [ ] 生成新的 AUR source manifest，删除旧 FlClash AUR artifacts（需在有海外访问的构建机上执行）
- [ ] 断网执行 14 个 AUR target + keymaps bootstrap，记录无外连证据（未执行）

### 阶段 D：VMware 四轮

- [ ] 只对用户明确指定的专用 VMware 测试 VM 做 snapshot/start/guest 操作；
- [ ] VM 模式两轮：`-d both -t vm`，验证 guest tools 且禁止 host Workstation；
- [ ] 仿物理两轮：`-d both -t physical --test-profile physical-sim-vmware`，先验证虚拟化身份；
- [ ] 每轮 clean snapshot，收集 artifact，revert；
- [ ] 真实 Hyprland/DMS 登录、退出、重登和 3D/blur 对比；
- [ ] 四轮同一最终 `TEST_ID`，否则全部重算。

### 阶段 E：物理机

用户报告已完成，但任何再次 apply 前都必须：inventory → dry-run/review plan → 明确批准 → 使用 `~/scripts/desktop/gsudo --` 做窄范围变更 → post-change verification。绝不因为 VM PASS 就自动修改物理机 KVM/VMware 或网络。

---

## 11. VMware 四轮测试合同

### 11.1 最低成功定义

| round | 参数 | 必须证明 |
|---|---|---|
| VM-R1 | `./install.sh -d both -t vm` | VMware guest 角色、open-vm-tools、Niri/Hyprland/DMS、无 host 栈 |
| VM-R2 | 同上，从 clean baseline 重来 | 第二次独立重复成功 |
| PHY-R1 | `./install.sh -d both -t physical --test-profile physical-sim-vmware` | physical 分支、包/config/AUR/服务规划，host-only 动作 N/A |
| PHY-R2 | 同上，从 clean baseline 重来 | 第二次独立重复成功 |

`physical-sim-vmware` 必须记录：

```text
systemd-detect-virt=vmware
MACHINE_TYPE=physical
TEST_PROFILE=physical-sim-vmware
```

缺任何一项都不能计仿物理 PASS。普通 `-t physical` 在 VMware guest 中不等同于仿物理 profile。

### 11.2 每轮 artifact 最低内容

```text
metadata.json
payload-manifest.txt
install.stdout.log
install.stderr.log
exit-codes.tsv
package-before.tsv
package-after.tsv
package-delta.tsv
services-before.tsv
services-after.tsv
failed-units.txt
progress-state.txt
sudoers-check.txt
config-validation.txt
dms-doctor.txt
dms-journal.txt
hyprland-systeminfo.txt
result.json
summary.md
```

`metadata.json` 必须含最终 `TEST_ID`、commit/payload hash、manifest hash、source-cache hash、profile、machine type、snapshot 名称和时间；不得含 guest 密码、token、cookie、私钥或完整环境秘密。

### 11.3 PASS/失败语义

- `PASS`：安装退出 0、required 包/服务/config/桌面验收全通过、退出清理完成、日志完整；
- `PRODUCT_FAIL`：项目代码/配置/包策略失败；
- `INFRA_FAIL`：VMware/snapshot/磁盘/SSH/资源失败；
- `CHECK_FAILED`：检查命令自身失败；
- `UNAVAILABLE`：没有获得合法检查能力；
- `NOT_APPLICABLE_SIMULATED`：只允许用于仿物理的 host-only 硬件效果，并附理由。

除 `PASS` 外都不计最低四轮。若代码、manifest、recipe、source cache、harness 或 clean baseline 改变，旧 `TEST_ID` 全部失效。

### 11.4 停止条件

出现以下任意情况立即停在 checkpoint，不要继续“试试看”：

- 需要删除/移动 VM 磁盘、hard stop、修改未授权 VMX；
- 目标 guest 不能提供可靠管理通道；
- secret scan 命中真实凭据；
- root/guest 权限模型不明确；
- 磁盘空间不足可能损坏快照/产物；
- 同一失败在无新证据时重复；
- 无法区分产品失败与测试基础设施失败。

checkpoint 必须写：已完成轮次、失败/不可用轮次、最终 ID/hash、日志路径、未执行检查、宿主/KVM/VMware 未变更声明和唯一下一步。

---

## 12. 最终完成门槛

只有同时满足以下条件，才可对外说“当前版本通过”：

1. FlClash 迁移：清单/recipe/cache/启动配置一致；旧 AUR 包替换在专用测试环境中成功；
2. 静态检查：reconciliation 191/12/8、177/14、231/15；ShellCheck error=0；目标测试 PASS；
3. AUR：14 target + keymaps bootstrap 的在线和断网路径均有证据；
4. 角色：VM 不装 Workstation/KVM host 栈，physical host 才装 Workstation；
5. VMware：guest tools/host DKMS/服务按角色验收；
6. Hyprland：从项目 greetd 入口进入，DMS active，退出清理，重登稳定，3D/blur 对比有记录；
7. 四轮：VM-R1/R2 与 PHY-R1/R2 是同一最终 `TEST_ID` 的四个 PASS；
8. 安全：无 credential value 入仓库/日志/提示词，历史暴露凭据已轮换；
9. 文档：当前文档数字来自最终 payload，历史 KVM/旧批次明确隔离。

在此之前，准确措辞是：**静态整改进行中，物理机由用户报告已部署，VMware 四轮和 Hyprland/DMS runtime 验收未完成。**

---

## 13. 给后续模型的执行原则

完整可复制提示词见 `docs/next-model-prompt-20260808.txt`。

- 先读本文件和项目 `AGENTS.md`，不要读取/索要密码；
- 只在工作区内改代码和文档；任何 Arch/VMware/guest apply 前先 inventory、dry-run 和明确批准；
- 不删除宿主 KVM/VMware 资产；不自行选择 VM；
- 所有失败和 unavailable 保留退出码与证据；
- 不要因为旧 artifact 写着“完成”就复用它；迁移后生成新 `TEST_ID`；
- 完成每个阶段后更新 checkpoint，并在最终回复列出真实 PASS、失败、未执行和下一步。
