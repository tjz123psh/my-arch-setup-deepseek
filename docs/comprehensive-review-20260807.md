# my-arch-setup-deepseek 全面审查与整改任务书

- 审查日期：2026-08-07
- 审查对象：`/home/pang/Projects/my-arch-setup-deepseek`
- 审查基线：`main`；开始本轮审查时与 `origin/main` 无已跟踪文件差异
- 报告性质：代码、清单、配置、宿主快照和文档的只读审查；本轮只重写本报告，不修改安装器实现
- 边界：**没有安装/删除软件包，没有启停服务，没有启动 VMware 虚拟机，没有删除宿主机 KVM 虚拟机，也没有把宿主配置同步进仓库**
- 当前结论：仓库的数据资产较丰富，但安装器仍存在多条“实际失败、流程却继续并标记成功”的路径。新增的宿主同步、KVM→VMware 和 Hyprland/DMS 需求不能直接叠加到现有流程上；必须先补机器角色、秘密隔离、失败传播和桌面会话生命周期。

---

## 1. 执行摘要

### 1.1 本轮新增结论

1. **不能直接把宿主 `~/.config` 镜像进公开仓库。**宿主 `/home/pang/.config/fish/config.fish` 当前含硬编码凭据赋值形态，权限还是 `0644`；`conf.d/age-api-key.fish` 也含凭据赋值形态。报告没有读取或记录凭据值。同步前应先撤销/轮换相关凭据，并恢复仓库现有的私有文件引用方案。
2. 对清单中映射到 `~/.config`、`~/md`、`~/scripts` 的 205 个目标逐文件比较后，得到 **182 相同、22 不同、1 个宿主缺失**。差异不是同一性质：有手工配置、运行时主题生成物、秘密风险、历史 KVM 文档和新 VMware 资产，不能一次性全选覆盖。
3. `nomacs` 已在宿主显式安装，当前版本 `1:3.23.2-1`，来自 `archlinuxcn`；仓库清单缺失。宿主 MIME 配置还把 PNG 默认程序设为 `org.nomacs.ImageLounge.desktop`，因此任务不仅是加包，还应同步并验证默认关联。
4. 当前项目的虚拟化模块没有区分 **VMware host** 与 **VMware guest**。现有 VM 模式仍会装 KVM host 栈，而 VMware Workstation 只能装在物理宿主，`open-vm-tools` 应装在 VMware guest。若直接“把 KVM 包名换成 VMware 包名”，会在两种机器上装错角色。
5. `vmware-workstation` 不是一个可直接塞进现有 AUR 数组的独立 recipe：它依赖另一个 AUR 包 `vmware-keymaps`，而当前 `06-aur.sh` 是“全部构建完后再统一安装”。即使加入两个 recipe，构建 Workstation 时它的 AUR 依赖仍未安装，现有顺序模型会失败。
6. Hyprland 配置语法本身可通过 `Hyprland --verify-config`；更可疑的是会话启动链。仓库在 Hyprland 中直接执行 `dms run -d`，绕开了 `dms.service`、`graphical-session.target` 和统一的 DBus/systemd 用户环境。这个问题在 VMware guest 中可能更容易暴露。
7. 本机 DMS 1.5.3 二进制内嵌的 Hyprland 模板会导入 DBus/systemd 环境并启动 `hyprland-session.target`；但本机实际不存在这个 target，`systemctl --user cat hyprland-session.target` 返回 1。因此不能简单复制模板中的两行命令，必须先明确由 UWSM、标准 `graphical-session.target`，还是仓库自建 target 管理完整生命周期。
8. 当前 VMware VM 没有运行，`vmrun list` 为 `Total running VMs: 0`。本轮没有 guest journal，所以不能把 DMS 故障宣称为已锁定唯一根因；目前只能给出“高概率启动链问题”和“待隔离验证的 VMware 3D/blur 渲染因素”。
9. 夜间实施完成后，最低验证要求不是“跑过一次”，而是 **VM 模式完整安装连续成功两轮 + VMware VM 内仿物理模式安装连续成功两轮**。每轮都必须从同一干净快照恢复，并使用同一最终 `TEST_ID`；失败尝试不计数，`TEST_ID` 变化后此前成功计数全部重新开始。

### 1.2 原审查结论仍成立的最高优先级问题

1. 临时 `${TARGET_USER} ALL=(ALL) NOPASSWD: ALL` 在失败、中断和断电路径不会可靠清理。
2. Hyprland-only、both、none 与固定 `dms-greeter --command niri` 的 greetd 配置矛盾。
3. AUR 最终 `pacman -U` 失败会被吞掉，产物随后删除，步骤仍可能标记完成。
4. 物理机驱动安装失败只 warning，仍继续桌面安装。
5. 配置部署会跟随目标 symlink 覆盖指向文件，且不备份 symlink 目标。
6. “离线 AUR”仍可能 fetch，部分 VCS 源未固定，缓存完整性也没有结构化证明。
7. `.install_progress` 不绑定参数、commit 和输入清单。
8. 18 个 verify-only 前置条件没有实际验证实现。

### 1.3 总体判断

> **当前安装器的成功退出，仍不能可靠证明工作站恢复完成；新增 VMware 与配置同步任务若直接实施，还会扩大假成功、角色混装和公开泄密风险。**

推荐顺序不是“先把新文件复制进来”，而是：

1. 阻断凭据同步与临时 sudoers 残留；
2. 修复失败传播、桌面选择和机器角色；
3. 再做经过分类的宿主资产同步；
4. 最后加入 VMware host/guest、nomacs 和 Hyprland/DMS 专项验收。

---

## 2. 审查范围、方法与未覆盖项

### 2.1 已审查

- 入口与编排：`strap.sh`、`install.sh`、`scripts/00-utils.sh`、`scripts/01` 至 `99`
- 软件包策略：`manifests/workstation-packages.tsv`
- 配置映射：`manifests/config-mappings.tsv`
- AUR：`manifests/aur-recipes.tsv`、`third_party/aur/`、`scripts/06-aur.sh`、`fetch-aur-sources.sh`
- 配置资产：`config/home`、`config/etc`
- 维护脚本：`sync-scripts.sh`、`config/home/scripts/maintenance/`
- 文档：README、project vision、handoff、离线安装、宿主 VMware 笔记和快捷键文档
- 宿主只读状态：已安装软件包、unit 文件、服务 enabled 状态、内核模块、VMX 配置、宿主与仓库文件摘要差异
- Hyprland/DMS：仓库与宿主配置验证、DMS unit、Niri unit、Hyprland session desktop、DMS 1.5.3 内嵌模板

### 2.2 已执行检查

| 检查 | 结果 | 说明 |
| --- | --- | --- |
| Git 初始状态 | 通过 | `main...origin/main`；开始时无已跟踪文件改动 |
| Bash 语法复核 | 通过 | 最终按 Git 跟踪文件的 shell shebang 选择 67 个候选，`bash -n` 0 失败 |
| 核心/全量 ShellCheck | **有发现** | 全量 65 个脚本中 38 个有 findings，不能称为通过 |
| 包清单回归测试 | 通过 | 本轮最终复跑通过：total=208、install=190、verify=18、pacman install=176、AUR install=14、mapping=233、recipe=14 |
| Neovim 配置测试 | 通过 | `tests/nvim-config-test.sh` |
| maintenance 测试 | 通过 | 原审查为 51/51 TAP |
| 当前 pacman 包名可用性 | 通过 | 原清单的 176 个 pacman install-policy 包在当时同步数据库均可找到 |
| `.SRCINFO` 重生成比较 | **有差异** | 14 个 recipe 中 4 个不一致 |
| 仓库秘密静态扫描 | 未发现实际凭据 | 只适用于当前仓库；不适用于准备同步的宿主 Fish 配置 |
| 宿主映射哈希比较 | 完成 | 205 项：182 same、22 different、1 live missing |
| Hyprland 配置验证 | 通过 | 仓库和宿主 `hyprland.lua` 均 `config ok` |
| DMS CLI 参数 | 通过 | `dms run -d`、`--session`、debug/log 参数均存在 |
| VMware 运行中 VM 查询 | 完成 | `vmrun list` 成功，0 个运行中 VM |
| VMware guest DMS 日志 | **未取得** | VM 未运行；不能把查询失败或未执行写成“没有错误” |
| 独立 reviewer | **未执行** | 本轮没有授权使用子代理；不能记为通过 |
| 真实主机 apply | 未执行 | 本报告只读审查 |

复核阶段曾有一次**无效的语法检查尝试**：候选选择条件过宽，把 4 个 ELF 和 4 个 Markdown 文件交给了 `bash -n`，因此返回失败；这不是脚本语法失败，也没有被记作通过。改为只选择 Git 跟踪且 shebang 指向 Bash/sh 的文件后，67/67 通过。

### 2.3 明确未做

- 未运行 `sync-scripts.sh` 的实际同步；
- 未复制宿主 `~/.config`、`~/md`、`~/scripts`；
- 未编辑宿主 VMX；
- 未启动、停止、快照或删除任何 VM；
- 未卸载 KVM 包或禁用 `libvirtd.service`；
- 未安装 nomacs、VMware 或 open-vm-tools；
- 未在 VMware guest 中复现 DMS 故障。

---

## 3. 新增任务一：安全更新 `~/md`、`~/.config`、`~/scripts`

### 3.1 映射内差异总览

依据 `manifests/config-mappings.tsv`，只比较目标位于 `.config/`、`md/`、`scripts/` 的 205 条映射：

| 状态 | 数量 |
| --- | ---: |
| 内容相同 | 182 |
| 内容不同 | 22 |
| 宿主缺失、仓库存在 | 1 |
| 仓库缺失 | 0 |
| 类型不匹配 | 0 |

22 个内容不同的路径：

```text
.config/alacritty/dank-theme.toml
.config/fish/config.fish
.config/fuzzel/colors.ini
.config/gtk-3.0/dank-colors.css
.config/gtk-4.0/dank-colors.css
.config/hypr/conf/keybinds.lua
.config/hypr/dms/colors.lua
.config/kitty/dank-tabs.conf
.config/kitty/dank-theme.conf
.config/niri/config.kdl
.config/niri/dms/colors.kdl
.config/niri/dms/keybinds.kdl
.config/nvim/lua/core/cheatsheet.lua
.config/nvim/lua/core/commands.lua
.config/nvim/lua/core/init.lua
.config/nvim/lua/core/keymaps.lua
.config/nvim/lua/plugins/dashboard.lua
.config/nvim/lua/plugins/telescope.lua
.config/dgop/colors.json
scripts/maintenance/quicksave
md/linux/当前archlinux快捷键.md
.config/mimeapps.list
```

宿主缺失、仓库仍映射：

```text
md/kvm虚拟机/KVM虚拟机优化记录.md
```

### 3.2 必须阻断：Fish 配置含凭据赋值形态

只报告位置和权限，不记录值：

| 路径 | 权限 | 结果 |
| --- | --- | --- |
| `/home/pang/.config/fish/config.fish` | `0644` | 存在硬编码凭据赋值形态 |
| `/home/pang/.config/fish/conf.d/age-api-key.fish` | `0600` | 存在凭据赋值形态 |
| `config/home/.config/fish/config.fish` | `0644` | 未发现该赋值形态；使用私有文件引用 |

仓库当前方案在 `config/home/.config/fish/config.fish:37-38` 只在可读时加载 `~/.config/fish/private-env.fish`，这是更合理的公开仓库边界。

**任务要求：**

1. 不得把宿主 Fish 文件原样复制进公开仓库；
2. 撤销/轮换已硬编码的凭据；
3. 将宿主恢复为 `private-env.fish`、age 解密后的临时环境或其他不入 Git 的引用模式；
4. 修正含凭据文件的权限；
5. 同步完成前后都运行秘密扫描，并人工检查 staged diff。

这是新增任务中唯一应先于普通配置同步完成的阻断项。

### 3.3 可明确识别的手工变更

#### Niri 与 VM 测试模式

宿主 `/home/pang/.config/niri/config.kdl` 新增：

- `Super+Shift+D` 加载 `~/.config/niri/config.kdl.vmtest`；
- `polkit-gnome-authentication-agent-1` 启动项。

宿主新脚本 `/home/pang/scripts/desktop/niri-vmtest-gen`：

- 从正常 `config.kdl` 生成 VM test 配置；
- 移除原 VM 开关块；
- 注释 DMS keybind include；
- 清空 recent-windows binds；
- 追加唯一恢复键。

宿主文档 `/home/pang/md/linux/当前archlinux快捷键.md` 新增 VM 测试模式章节；VMware 运维笔记也描述了同一机制。

**合理落库方案：**

- 同步 `config.kdl`、快捷键文档和 `niri-vmtest-gen`；
- 给生成器新增 mapping；
- `config.kdl.vmtest` 作为生成物，不建议与生成器同时无校验地静态映射；
- 更稳妥的安装顺序是：部署正常 Niri 配置 → 运行生成器 → `niri validate -c ~/.config/niri/config.kdl.vmtest`；
- 不同步 `config.kdl.bak-vmtoggle` 等备份文件。

**生成器风险：**它用跨行正则匹配 KDL 注释和大括号，依赖当前格式。应至少增加：

1. 连续运行两次输出哈希相同；
2. 正常配置不被修改；
3. 只删除预期 VM 开关块和按键块；
4. 正常与 VM test 两份配置都通过 `niri validate`；
5. 当目标注释/结构变化导致匹配不到时明确失败，而不是生成半有效配置。

#### 快捷键入口

宿主把：

- Niri 的 `~/scripts/desktop/niri-keys`
- Hyprland 的 `~/scripts/desktop/hypr-keys`

改为通过 `~/.local/bin/niri-keys` 和 `~/.local/bin/hypr-keys` 调用。宿主这两个 `.local/bin` 条目目前是指向 `~/scripts/desktop/` 的 symlink；仓库只映射脚本本体，没有创建这两个 symlink 的安装逻辑。

因此不能只同步 keybind 文件。应二选一：

- 保留仓库现有直接脚本路径；或
- 在安装器中显式、幂等地创建两个命令入口，并验证 symlink target 存在。

否则新配置在干净恢复后会产生断链。

#### Neovim、quicksave、MIME

- 6 个 Neovim Lua 文件有宿主变更，应按功能 diff 和现有测试审查后同步；
- `scripts/maintenance/quicksave` 修改了权限错误识别正则，应补针对“真实非权限错误不能被误判”的回归测试；
- `mimeapps.list` 新增 nomacs 的 PNG 默认/added association，应与 nomacs 包作为同一任务落库。

### 3.4 运行时主题生成物不能盲目同步

以下 9 个差异大多由 DMS/Matugen 主题生成：

```text
.config/alacritty/dank-theme.toml
.config/fuzzel/colors.ini
.config/gtk-3.0/dank-colors.css
.config/gtk-4.0/dank-colors.css
.config/hypr/dms/colors.lua
.config/kitty/dank-tabs.conf
.config/kitty/dank-theme.conf
.config/niri/dms/colors.kdl
.config/dgop/colors.json
```

需要先决定项目策略：

- 若仓库保存“恢复后的固定初始主题”，可同步一次并记录由哪张壁纸/哪组 Matugen 设置生成；
- 若这些是纯运行时输出，应从恢复 payload 移除或在首次登录时再生成；
- 不能一边映射静态文件、一边允许 DMS 首次启动立即重写，却没有漂移说明和验收。

### 3.5 明确不应纳入恢复 payload 的宿主状态

- Fish 凭据赋值文件；
- `config.kdl.bak-vmtoggle` 等备份；
- DMS changelog/first-launch 状态；
- Fish variables、Niri 当前布局等机器运行状态；
- systemd enable 产生的 symlink 快照；
- `~/scripts/maintenance/.git/` 嵌套仓库元数据；
- 无引用的空文件 `/home/pang/.config/hypr/dms/windowrules.lua`；
- 其他缓存、日志、socket、lock 和临时文件。

当前 `sync-scripts.sh` 的 rsync 路径已显式 `--exclude='.git'`，这个保护必须保留；但它仍默认实际执行 `--delete`、没有 dry-run 和备份，见 M-10。

### 3.6 安全同步工作流

建议把这次同步实现为可审查任务，而不是一次 rsync：

1. 只读 inventory：列出 same/changed/new/deleted/type-mismatch，保留每个查询退出码；
2. secret gate：Fish 和其他高风险文件先拦截；
3. 分类：手工配置、运行时生成物、备份、历史文档、程序、凭据；
4. 默认 dry-run：展示将新增、修改、删除和新增 mapping 的清单；
5. 人工选择后 `--apply`，仅写当前仓库；
6. 更新 mapping，检查 source/target 唯一性和文件权限；
7. 运行语法/配置测试；
8. staged diff 再做秘密扫描；
9. 不把“源路径不存在”自动解释为应该删除，尤其是 KVM→VMware 迁移这类语义变化。

---

## 4. 新增任务二：加入 nomacs

### 4.1 当前事实

- 宿主已显式安装：`nomacs 1:3.23.2-1`；
- 当前同步数据库来源：`archlinuxcn`；
- 用途：Qt 图片查看器；
- `manifests/workstation-packages.tsv` 当前没有 `nomacs`；
- 宿主 `~/.config/mimeapps.list` 已把 `image/png` 指向 `org.nomacs.ImageLounge.desktop`。

### 4.2 应实施的项目任务

1. 在 `manifests/workstation-packages.tsv` 增加 `nomacs`：
   - channel：`pacman`
   - repository：`archlinuxcn`
   - module：建议 `desktop-apps`
   - policy：`install`
   - restore：可标为 `config-backed`，因为默认关联由共享 MIME 配置恢复
2. 同步经审查的 `config/home/.config/mimeapps.list`；
3. 更新包清单测试的期望统计；
4. 增加验收：
   - `pacman -Q nomacs`
   - `test -f /usr/share/applications/org.nomacs.ImageLounge.desktop`
   - `xdg-mime query default image/png` 返回该 desktop entry
5. 是否把 JPEG/WebP/TIFF 等也改为 nomacs 必须由用户显式决定；不能仅因 PNG 已修改就推断全部图片格式。

---

## 5. 新增任务三：项目从 KVM 迁移到 VMware

### 5.1 边界声明

这里的“删除 KVM”指：

- 从**本项目未来恢复出的系统**移除 KVM host/guest 包、服务、组、配置映射和活跃运维入口；
- 将项目的 VM 验收流程改为 VMware。

这里**不包括**：

- 删除宿主机现有 libvirt domain；
- 删除 qcow2、XML、snapshot 或 KVM 网络；
- 卸载宿主机当前 KVM 软件；
- 禁用宿主机 `libvirtd.service`。

本轮没有执行任何宿主 KVM 删除操作。

### 5.2 宿主只读现状

2026-08-07 查询到：

- VMware：`vmware-workstation 26H1-3`、`open-vm-tools 6:13.1.0-2` 均显式安装；
- KVM：`libvirt`、`qemu-desktop`、`virt-manager`、`virt-viewer`、`qemu-guest-agent`、`spice-vdagent`、`dnsmasq`、`edk2-ovmf` 均显式安装；
- `vmware-networks.service`：enabled；
- `vmware-usbarbitrator.service`：enabled；
- `vmware-networks-configuration.service`：static；
- `vmware-vmnet.service`：not-found；
- `libvirtd.service`：enabled；
- 已加载模块同时包含 `vmmon`、`vmnet`、`kvm_amd`、`kvm`。

这说明宿主当前是 VMware 与 KVM 并存状态，但不能据此自动对宿主做卸载。

### 5.3 当前项目中的活跃 KVM footprint

#### 软件包

至少 8 个 KVM/QEMU/SPICE 项：

```text
dnsmasq
edk2-ovmf
libvirt
qemu-desktop
qemu-guest-agent
spice-vdagent
virt-manager
virt-viewer
```

#### 服务和用户组

- `scripts/08-services.sh:77-79` 启用 `libvirtd.service`；
- `scripts/08-services.sh:107-113` 处理 libvirt default network autostart；
- `scripts/08-services.sh:125` 无条件要求 `libvirt` 用户组。

#### 配置、脚本和文档映射

- `manifests/config-mappings.tsv:176`：KVM 优化文档；
- `:218-219`：libvirt storage XML；
- `:234-235`：KVM hugepages 工具和 README；
- README、project vision、handoff 和 maintenance destructive VM 文档中还有大量 KVM 验收记录。

### 5.4 必须先补 machine role

当前 `scripts/03-packages.sh` 除硬件驱动和桌面模块外，physical 与 vm 基本选择同一包集。这导致 VM 模式也会安装 KVM host 栈和 QEMU/SPICE guest agent。

VMware 需要至少两种明确角色：

| 角色 | 应安装 | 不应安装 |
| --- | --- | --- |
| physical / VMware host | `vmware-workstation`、匹配当前内核的 headers、所需 host 服务 | `open-vm-tools`、KVM host 栈 |
| vm / VMware guest | `open-vm-tools`、guest 服务 | `vmware-workstation`、libvirt/qemu/virt-manager、QEMU/SPICE guest agent |

推荐用简单模块名实现，不必引入复杂框架：

- `virtualization-vmware-host`
- `virtualization-vmware-guest`

并在 `module_selected()` 中按 `MACHINE_TYPE` 过滤。配置映射也需要同样按机器/桌面模块选择；当前 `07-config.sh` 固定部署整个 `physical-v1`，完全忽略 mapping 的 module 字段。

### 5.5 VMware Workstation AUR 不是单 recipe 问题

宿主缓存的 `vmware-workstation 26H1-3` recipe 显示：

- AUR 包，安装后约 1106 MiB；
- 依赖 `dkms`、`gtkmm3`、`libxcrypt-compat`、`libxml2-legacy`、`vmware-keymaps` 等；
- 可选依赖当前内核 headers；
- source 包含 Workstation bundle 和多份 VMware Tools ISO；
- 自定义许可证，不能默认假设可以把大体积 vendor 资产提交到公开 Git。

关键阻塞：`vmware-keymaps` 在当前 pacman 同步数据库中找不到，是独立 AUR 包。现有 `06-aur.sh` 的流程是：

1. 对所有 recipe 执行 `makepkg -s`；
2. 收集所有包；
3. 最后一次性 `pacman -U`。

因此 Workstation 构建时 `vmware-keymaps` 还没安装。仅把两个名字追加到数组不会解决依赖。

**可选修复：**

- 将 `vmware-keymaps` 作为 bootstrap recipe，先构建并安装，再构建 Workstation；或
- 建立本地临时 pacman repo，让后续 `makepkg -s` 能解析已构建 AUR 依赖；或
- 为 recipe 增加简单依赖拓扑和分批安装。

同时需要：

- 新增 `third_party/aur/vmware-keymaps/` 和 `vmware-workstation/`；
- 更新 `.SRCINFO`、AUR manifest、06 的唯一数据源；
- 将两者纳入离线 source cache；
- 验证 Workstation bundle、ISO、patch 和 DKMS source 的 checksum；
- 不把超大、授权边界不明的 vendor payload 直接提交到公开仓库。

统计有两种设计：

- 若 package manifest 只记录最终目标包：迁移后目标包统计约为 total=203、install=185、pacman=170、AUR target=15，但 recipe 数为 16；
- 若继续强制“每个 recipe 都必须有 package policy 行”：还需把 `vmware-keymaps` 列入 manifest，约为 total=204、install=186、pacman=170、AUR=16。

应先决定 manifest 是否描述“最终显式目标”还是“所有需本地构建的 AUR 包”，不要继续让测试隐含这个语义。

### 5.6 VMware host 配置任务

依据 `/home/pang/md/vmware/VMware-使用与运维笔记.md`，项目应恢复：

1. 与实际安装内核匹配的 headers；
2. DKMS 构建和验收 `vmmon`、`vmnet`；
3. 仅启用：
   - `vmware-networks.service`
   - `vmware-usbarbitrator.service`
4. 不尝试 enable：
   - 不存在的 `vmware-vmnet.service`
   - static 的 `vmware-networks-configuration.service`
5. 不依赖本机已确认不可用的 `vmware-modconfig --console --install-all`；
6. 内核升级后验证：
   - `dkms status`
   - `modprobe -n vmmon vmnet`
   - unit enabled/active 状态
7. Workstation host 安装失败必须是 required failure，不能 warning 后继续。

### 5.7 VMware guest 配置任务

`open-vm-tools` 当前包提供：

- `/usr/lib/systemd/system/vmtoolsd.service`
- `/usr/lib/systemd/system/vmware-vmblock-fuse.service`

两者都有 `ConditionVirtualization=vmware`。建议：

- VM 模式 required：安装并 enable `vmtoolsd.service`；
- 若验收目标包含主客机拖放/复制粘贴，再 enable 并验证 `vmware-vmblock-fuse.service`；
- 检查 `gtkmm3`、`libxtst` 等可选依赖是否满足预期桌面集成功能；
- 不在 physical 模式安装 guest tools；
- 使用 `systemd-detect-virt` 和 unit Condition 做最终角色验收。

### 5.8 VMX 与验证基线

当前 VMX 只读检查：

```text
virtualHW.version = "22"
guestOS = "other6xlinux-64"
numvcpus = "4"
memsize = "4096"
ethernet0.connectionType = "nat"
ethernet0.virtualDev = "e1000"
mks.enable3d = "TRUE"
svga.maxWidth = "1920"
svga.maxHeight = "1080"
vmci0.present = "FALSE"
```

`vmci0.present = "FALSE"` 与运维笔记一致。项目不应直接编辑用户真实 VMX；可以提供只读 preflight/文档，提示必须先关闭 VMware GUI 后再人工修改，否则 GUI 可能覆盖回写。

原来的 libvirt overlay/qcow2 验证流程应替换为：

1. VMware VMX 基线；
2. 安装前 snapshot；
3. 执行恢复；
4. 收集 guest acceptance；
5. revert snapshot；
6. 不在命令行、日志或仓库保存 guest 密码。

历史 KVM handoff 可以保留为 dated archive，但 README/project vision 的“当前保证”必须改为 VMware；恢复 payload 中不再部署 KVM storage XML 和 hugepages 工具。

---

## 6. 新增任务四：VMware guest 中 Hyprland/DMS 专项

### 6.1 已排除：不是明显 Lua 语法错误

- `dms-shell 1.5.3-1`
- `hyprland 0.56.2-1`
- 仓库和宿主 Hyprland 配置均通过 `Hyprland --verify-config`
- `dms run -d` 是有效命令

所以目前不能把问题简单归结为“Hyprland 配置语法错”或“参数不存在”。

### 6.2 高概率问题：Hyprland 绕过 DMS 的 systemd 会话模型

仓库 `config/home/.config/hypr/conf/autostart.lua:8-31` 明确认为 `start-hyprland` 不触发 graphical target，因此直接执行：

```text
pgrep -f '[q]s -p /usr/share/quickshell/dms' >/dev/null || dms run -d
```

当前 `/usr/lib/systemd/user/dms.service` 则要求：

- `PartOf=graphical-session.target`
- `After=graphical-session.target`
- `Requisite=graphical-session.target`
- `ExecStart=/usr/bin/dms run --session`
- `WantedBy=graphical-session.target`
- `Restart=on-failure`

Niri 的 `/usr/lib/systemd/user/niri.service` 会绑定并拉起 `graphical-session.target`，Hyprland 的普通 desktop entry 只执行 `/usr/bin/start-hyprland`。系统另有 `hyprland-uwsm.desktop`，但本机未安装 `uwsm`。

直接 daemon 路径的问题：

1. DBus/systemd 用户环境可能没有完整导入 Wayland/Hyprland 变量；
2. DMS 不再受 `dms.service` 的 restart、状态和日志管理；
3. `xdg-desktop-autostart.target` 和其他 graphical-session user services 没有统一生命周期；
4. `08-services.sh` 即使 enable `dms.service`，普通 Hyprland 会话也不会自然拉起它；
5. 失败只剩进程守卫，没有 required acceptance。

### 6.3 DMS 内嵌模板也不能直接照抄

本机 DMS 1.5.3 二进制内嵌的 Hyprland Lua 模板包含：

```text
dbus-update-activation-environment --systemd --all
systemctl --user start hyprland-session.target
```

但当前系统没有 `hyprland-session.target` 文件：

- `/usr/lib/systemd/user/` 只有 generic `graphical-session*.target`；
- `~/.config/systemd/user/` 也没有该 target；
- `systemctl --user cat hyprland-session.target` 返回 1。

因此专项整改必须选择并验证一种完整设计：

- **优先候选：**安装并采用 `uwsm` 管理 Hyprland，会话进入标准 systemd graphical lifecycle；
- 或者：仓库明确提供、启用并测试自己的 Hyprland session target；
- 或者：保留普通 `start-hyprland`，但显式导入环境、启动/停止标准 graphical targets，并证明退出生命周期正确。

不能只把缺失 target 的启动命令加入 autostart 后就宣布修复。

### 6.4 greetd 当前还阻断 Hyprland-only 标准入口

`scripts/08-services.sh:45-65` 无条件生成：

```text
dms-greeter --command niri
```

所以项目的 `--desktop hyprland` 并没有一个与包选择一致的登录链。专项测试前必须先修 C-02，否则 VM 中启动 Hyprland 很可能是绕过项目标准入口手工启动，测试结果不能代表恢复流程。

### 6.5 次级候选：VMware SVGA3D 与 blur/动画

当前 VMX 启用 `mks.enable3d = "TRUE"`。仓库同时启用：

- DMS blur 与 foreground blur；
- DMS frame blur；
- Hyprland blur；
- 多组 Hyprland 动画；
- DMS GPU 温度/索引设置；
- Hyprland Matugen 模板。

VMware 的 SVGA3D/Mesa 渲染路径可能触发 Quickshell/Qt blur 兼容性或性能问题，但目前没有 guest 日志，证据不足以定为根因。

应把“启动链”和“渲染兼容”分开验证：

1. 先证明 DMS 服务已启动、环境正确、IPC 可用；
2. 再对比 DMS/Hyprland blur 与动画开/关；
3. 再对比 VMware 3D 开/关；
4. 不要用“关特效后看起来正常”替代启动链修复。

### 6.6 guest 必采证据

在故障 VM 中保存命令、退出码和输出到 guest 内日志：

```text
dms doctor
systemctl --user status dms.service
journalctl --user -b -u dms.service
systemctl --user status graphical-session.target
systemctl --user list-dependencies graphical-session.target
pgrep -af 'dms|qs'
hyprctl configerrors
hyprctl systeminfo
systemctl --user show-environment
echo "$WAYLAND_DISPLAY"
echo "$HYPRLAND_INSTANCE_SIGNATURE"
echo "$XDG_CURRENT_DESKTOP"
```

再分别测试：

```text
dms run --log-level debug --log-file <guest-local-log>
```

任何查询非零都必须标为“检查失败/不可用”，不能写成“没有发现”。日志不得包含密码、token 或 guest 凭据。

### 6.7 Hyprland/DMS 验收门槛

- 从项目提供的 Hyprland 登录入口进入，而不是 TTY 手工补启动；
- `dms.service` 或选定的受管理替代路径处于 active；
- DMS 日志没有持续重启循环；
- 状态栏、通知、壁纸、IPC 和关键插件可用；
- 退出 Hyprland 后 DMS 和 graphical-session 相关服务正确停止；
- 再次登录能稳定复现成功；
- VMware 3D on/off 与 blur on/off 的结果有记录；
- Niri 不因 Hyprland 修复而回归。

---

## 7. 原有严重问题复核

### C-01：临时全权限 NOPASSWD 在失败路径不会恢复

**证据：**`install.sh:131-140` 创建 `/etc/sudoers.d/99-install-nopasswd`，删除只在 `scripts/99-cleanup.sh:13-15`；主安装器没有覆盖 `EXIT/ERR/INT/TERM` 的清理 trap。`set -e` 还可能在自定义错误处理之前退出。

**影响：**任何中途失败或中断都可能留下永久、无限命令范围的免密 root 授权。

**整改：**取消 `NOPASSWD: ALL`；使用最小权限或重构 makepkg 权限模型；创建后立即注册幂等 trap；启动时检测遗留文件；用 `visudo -cf` 验证。

### C-02：桌面选项与 greetd 登录链矛盾

**证据：**03 按 `niri|hyprland|both|none` 过滤包；08 却固定 `dms-greeter --command niri` 并总是启用 greetd。

**影响：**Hyprland-only 和 none 可能重启后不可登录，both 也不是真正的会话选择。

**整改：**为四种模式分别定义登录策略，并在 VM 中测试真实登录。

### C-03：AUR 最终安装失败被吞掉

**证据：**`scripts/06-aur.sh:161-169` 对 `pacman -U` 失败只 warning，随后删除产物并打印 success；主安装器可能继续 `mark_done`。

**影响：**AUR 包缺失但流程成功，现场证据还被删除。

**整改：**失败非零退出、保留产物/日志、逐包 `pacman -Q` 差异验证；新增 AUR 依赖拓扑后更不能继续吞错。

### C-04：物理驱动失败被吞掉

**证据：**`scripts/04-drivers.sh:44-50` 逐包失败只 warning，随后仍启用服务并声明成功。

**影响：**无完整 GPU/DKMS 状态时继续进入桌面和登录管理器配置。

**整改：**区分 required 驱动和 optional 工具；required 任一失败即停止并保留日志。

### C-05：配置部署跟随 symlink 覆盖未备份文件

**证据：**`scripts/07-config.sh:38-45` 对 symlink 不备份，随后 `cp -a` 到同一路径；隔离复现会保留 symlink 并覆盖其指向文件。

**影响：**可能修改 HOME 外、另一个 dotfiles 仓库或共享路径。

**整改：**用 `lstat/readlink/realpath` 分类；默认拒绝跟随；备份 symlink 本身或要求人工处理；验证解析后路径边界。

### C-06：宿主配置同步可能把凭据发布到公开仓库

**证据：**见 3.2；宿主 Fish 配置含凭据赋值形态，仓库当前不含。

**影响：**一旦 commit/push，删除工作树文件也无法消除 Git 历史和远端泄露。

**整改：**先轮换，再同步；secret gate 必须在复制前和 commit 前各执行一次。

---

## 8. 高风险问题复核

### H-01：“离线 AUR”不保证离线或可复现

- `.aur-sources` 存在时，git source 仍可能 fetch；
- greetd greeter 的 VCS source 未完全固定；
- Go/Cargo 缓存只按目录存在性判断；
- 新增 VMware bundle、Tools ISO、patch 和 `vmware-keymaps` 后，离线资产更大、授权更复杂。

**整改：**生成机器可读 source manifest；固定 commit/checksum；断网 VM 验证所有 recipe；失败时保留缓存诊断。

### H-02：`.install_progress` 不绑定安装上下文

旧 progress 不绑定 `MACHINE_TYPE`、`DESKTOP_ENV`、用户、commit、package manifest、mapping 和 AUR recipe。KVM→VMware 后尤其危险：旧 03/06/08 done 状态会跳过新虚拟化角色。

**整改：**进度文件记录参数与输入哈希；不匹配时拒绝自动 resume。

### H-03：18 个 verify-only 前置条件没有实际验证

03 直接跳过 policy=`verify`，仓库没有统一 preflight 对 base、bootloader、内核、mkinitcpio、文件系统和网络逐项验证。

**整改：**把 verify 项实现成结构化检查；查询失败与“不存在”分开；required 前置条件失败禁止 apply。

### H-04：动态 TARGET_USER 与 `/home/pang` 硬编码冲突

大量配置和脚本硬编码 `/home/pang`，但安装器允许任意 TARGET_USER。新增 VM test 配置又增加绝对路径。

**整改：**个人项目可直接 assert 用户名必须为 `pang`；若要支持其他用户，则必须模板化全部路径并测试。不要维持“参数可变、资产固定”的假象。

### H-05：root/strap 下 makepkg 权限模型不闭合

`makepkg -s` 由目标用户运行时可能需要 sudo 安装依赖，这也是临时 NOPASSWD 的根源。新增 AUR→AUR 依赖后问题更严重。

**整改：**root 先解析并安装官方依赖；目标用户只构建；AUR prerequisites 用受控分批安装或本地 repo；不要给无限 sudo。

### H-06：服务失败大量降级 warning，缺少最终 acceptance

`08-services.sh` 多处 enable 失败只 warning。VMware host/guest 服务若沿用这种模式，会出现“Workstation 包已装但 vmmon/vmnet/网络不可用”或“guest tools 未运行”的假成功。

**整改：**定义 required/optional service；required 失败非零；最后结构化检查 enabled、active、failed units 和角色条件。

### H-07：配置 mapping 的 module 字段没有参与部署选择

`07-config.sh` 固定 `SCOPE=physical-v1`，读取 module 后丢弃。结果 niri-only、hyprland-only、none、physical、vm 都部署同一配置集合。

**影响：**桌面/虚拟化角色即使在包清单修好，配置和脚本仍会混装。

**整改：**让 mapping 使用与 package 一致的 module selection，并添加分支测试。

### H-08：Hyprland/DMS 会话链不受 systemd 管理

见第 6 章。必须作为独立高风险问题处理，不能只在配置中追加另一个 `exec`。

---

## 9. 中低风险与维护问题

| 编号 | 问题 | 证据/影响 | 建议 |
| --- | --- | --- | --- |
| M-01 | 镜像优化与系统更新重复 | strap、01/02 有重复刷新/升级路径 | 明确唯一更新阶段和失败语义 |
| M-02 | reflector fallback 不可执行 | `timeout` 不能直接调用 shell function，隔离复现返回 127 | 改为外部命令或 `bash -c`，补测试 |
| M-03 | 配置备份不等于 rollback | 无变更清单、恢复顺序、删除项处理和恢复验证 | 每次部署生成 manifest 与 rollback 脚本 |
| M-04 | `config/README.md` 声明超过实现 | 文档声称多项 symlink/secret/runtime 安全检查，当前测试未实现 | 删掉虚假保证或先实现测试 |
| M-05 | AUR 有多份真相源 | policy、aur-recipes.tsv、06 硬编码数组并存 | 由单一清单生成执行列表 |
| M-06 | 4 份 `.SRCINFO` 漂移 | 重生成比较不一致 | 修复并加 CI 检查 |
| M-07 | 预编译 ELF 直接入库并自动部署 | vellum 系列二进制缺少统一来源/哈希/构建证明 | 建立来源、哈希、许可证和更新流程 |
| M-08 | 第三方资产授权与体积不清 | 字体、图片、主题、ELF；根目录无统一授权总览 | 建 third-party inventory；大资产用 release/LFS/受控下载 |
| M-09 | AUR cache 完整性判断不足 | 文件/镜像/Go/Cargo 仅按存在或非空判断；固定 `/tmp` 日志 | 校验 checksum/commit，使用唯一临时目录 |
| M-10 | `sync-scripts.sh` 默认破坏性 apply | `set -uo pipefail` 无 `-e`；`rsync --delete` 无默认 dry-run/备份 | 默认 plan，显式 `--apply`，严格状态检查 |
| M-11 | 无全局 plan/inventory/audit | 安装器直接升级、覆盖、enable、改 GRUB/组 | 至少提供只读 `--plan` 和结构化日志 |
| M-12 | Niri VM generator 依赖正则结构 | 注释/缩进变化可能误删或生成半有效 KDL | 幂等/结构/validate 回归测试 |
| M-13 | polkit agent 可能重复 | 当前宿主同时运行 polkit-gnome agent 与 DMS Quickshell；仓库注释又称 DMS 接管 | 确定唯一 agent，按 Niri/Hyprland 分支验收 |
| L-01 | ShellCheck 未清零 | 65 个脚本中 38 个有 findings | 区分可解释 source 告警与真实引用/数组问题 |
| L-02 | 统计和文案漂移 | 03 注释、config README rows、README 体积等过时 | 从测试或脚本生成统计 |
| L-03 | 一个脚本绕过 mapping | `shorin-screenrec-menu` 由 09 单独部署 | 文档明确特殊部署并纳入验证 |
| L-04 | GRUB 主题可执行位噪声 | 普通数据文件记录 executable | 清理权限元数据 |
| L-05 | 系统变更缺少对称 rollback | mirrors、pacman、GRUB、locale、services、groups 等 | 逐类记录 before/after 与恢复命令 |
| L-06 | Rust 切换用 `pacman -Rdd` | 替代工具链失败会留下依赖中间态 | 事务化或取消强制移除 |

---

## 10. 清单与数据一致性复核

### 10.1 当前包策略基线

```text
total=208
install=190
verify=18
pacman install=176
AUR install=14
```

- duplicate package：0；
- 当前 14 个 AUR policy、`aur-recipes.tsv`、recipe 目录和 06 硬编码列表在原审查时一致；
- 加入 VMware 后不能只机械更新数字，必须先决定 `vmware-keymaps` 是 package target 还是仅 recipe dependency。

### 10.2 当前配置映射基线

- mapping rows：233；
- source/target 重复或 `..` 遍历项：原审查未发现；
- `config/home` 文件：234；
- 唯一未映射文件：`config/home/.local/bin/shorin-screenrec-menu`，由 09 特殊部署；
- 这不证明运行时 symlink 安全，也不证明 module filtering 已实现。

### 10.3 对原报告的纠正和补充

1. 原“仓库未发现实际秘密”结论仍适用于当前 Git 工作树，但不能扩展为“宿主待同步配置安全”；Fish 是本轮新增阻断项。
2. 原“脚本同步差异只有两个文件”需要加限定：使用现有 `.git` exclude 后主要是 `niri-vmtest-gen` 和 `quicksave`；若没有 exclude，会连嵌套 `maintenance/.git` 元数据一起复制。
3. 原“KVM→VMware 只需加 Workstation recipe”的思路不完整；`vmware-keymaps` AUR 依赖和现有 bulk-at-end 构建模型是新增阻塞。
4. 原“采用 DMS 内嵌 Hyprland target 启动即可”的推断不完整；当前系统实际没有 `hyprland-session.target`，必须补生命周期设计或采用 UWSM。
5. 原 Hyprland/DMS 结论应表述为“高概率启动链问题，渲染因素待分离”，不能写成已确认唯一根因。
6. KVM 历史 handoff 仍可作为历史证据，但不能继续充当 VMware/Hyprland 当前版本的 acceptance。

---

## 11. 综合整改任务清单

### P0：先阻断安全问题和假成功

- [ ] 轮换/撤销宿主 Fish 中硬编码的凭据，恢复私有引用；禁止原样同步。
- [ ] 移除 `NOPASSWD: ALL` 设计，补可靠 trap 和遗留检测。
- [ ] 修正主编排的 `set -e`/返回码捕获，任何 required 模块失败不得 `mark_done`。
- [ ] 修正 AUR bulk install 和驱动阶段的失败传播，保留日志与产物。
- [ ] 禁止配置部署跟随目标 symlink。

### P1：建立一致的桌面与机器角色

- [ ] 定义 `physical/VMware-host` 与 `vm/VMware-guest` 包模块。
- [ ] package 和 config mapping 使用同一 module selection。
- [ ] 修正 niri/hyprland/both/none 的 greetd 登录策略。
- [ ] progress 绑定机器、桌面、用户、commit 和输入哈希。
- [ ] 实现 18 个 verify-only preflight。

### P2：执行经过分类的宿主资产同步

- [ ] 默认 dry-run，输出新增/修改/删除和 mapping 变化。
- [ ] 同步经审查的 Niri VM test 入口、生成器和文档。
- [ ] 决定 `.local/bin/{niri-keys,hypr-keys}` 入口策略。
- [ ] 审查并同步 Neovim 6 个文件。
- [ ] 为 quicksave 正则变更补测试后同步。
- [ ] 决定 9 个主题生成物是固定 baseline 还是运行时生成。
- [ ] 不同步备份、状态、nested `.git`、空无引用文件和 secrets。
- [ ] 同步后执行 secret scan、路径/mapping 校验和 staged diff 审查。

### P3：nomacs

- [ ] 增加 `nomacs` package policy。
- [ ] 同步 PNG MIME 默认关联。
- [ ] 更新统计测试。
- [ ] 增加安装和 MIME acceptance。

### P4：KVM→VMware 项目迁移

- [ ] 从未来恢复 payload 移除 8 个 KVM/QEMU/SPICE 包。
- [ ] 移除 `libvirtd.service`、libvirt network、libvirt group 的活跃恢复逻辑。
- [ ] 移除 libvirt storage XML、KVM hugepages 和 KVM 优化文档的活跃 mapping。
- [ ] 保留需要的历史记录但标为 archive；README/project vision 改为 VMware 当前方案。
- [ ] 新增 `vmware-keymaps` 与 `vmware-workstation` recipe，并解决 AUR→AUR 依赖顺序。
- [ ] physical 模式启用并验收 VMware host 服务和 DKMS。
- [ ] vm 模式安装并验收 open-vm-tools。
- [ ] 将 VMware 运维笔记纳入 `config/home/md/vmware/` 和 mapping。
- [ ] 用 VMware snapshot/revert 替换 libvirt overlay/qcow2 acceptance。
- [ ] 全程不删除宿主实际 KVM VM。

### P5：Hyprland/DMS 专项

- [ ] 先修 Hyprland 登录入口。
- [ ] 选择 UWSM、标准 graphical target 或仓库自建 target 的一种完整生命周期。
- [ ] 导入 DBus/systemd 会话环境并验证，而不是只执行 `dms run -d`。
- [ ] 采集 guest DMS/systemd/Hyprland 日志和退出码。
- [ ] 分离测试 VMware 3D、DMS blur、Hyprland blur/动画。
- [ ] 确定唯一 polkit agent。
- [ ] Niri 与 Hyprland 都做重登和退出清理验收。

### P6：离线、测试与文档

- [ ] 为 VMware 大源文件建立 checksum/授权/缓存策略。
- [ ] 断网验证全部 AUR recipe，包括 AUR 依赖拓扑。
- [ ] 增加失败注入、symlink、四桌面、两机器角色、progress context 测试。
- [ ] 在兼容当前工作区边界的明确授权下，于 VMware 中完成 VM 安装与仿物理安装各至少两轮独立成功验收；四轮使用同一最终 `TEST_ID`，失败尝试不计数。
- [ ] 修复 4 份 `.SRCINFO` 和真实 ShellCheck 问题。
- [ ] 当前保证与历史 handoff 分离。
- [ ] 独立只读 reviewer 可用时再做一次复核；不可用必须继续标注。

---

## 12. 夜间 VMware 自动实施与四轮最低验证计划

本章用于后续夜间执行。它既是顺序计划，也是安全边界和完成判定；执行模型不得把“命令已运行”当成“任务完成”。

**当前工作区硬边界必须先说明：**项目级 `AGENTS.md` 将唯一可写范围限定为 `/home/pang/Projects/my-arch-setup-deepseek/`，因此在这条指令仍然有效时，模型不能直接创建/恢复工作区外的 VMware 快照、启动/关停工作区外的 VMX，或向 guest 写入安装结果。后续普通用户指令不能自动覆盖这一项目级边界。若要真正执行本章的四轮 VM 测试，必须由更高优先级的执行环境明确允许“仅指定 VMware 测试 VM”的外部状态变更，并且仍需用户对该 VM 的明确授权；否则只能完成本章的代码、测试 harness、静态检查和可审查 checkpoint，不能声称取得 VM PASS。

### 12.1 夜间完成定义

最低必须取得 **4 个独立 PASS**：

| 测试类型 | 最低成功轮数 | 推荐安装参数 | 目的 |
| --- | ---: | --- | --- |
| VMware guest / VM 模式 | 2 | `./install.sh -d both -t vm` | 验证真实 VMware guest 恢复、open-vm-tools、Niri/Hyprland/DMS 与无 KVM host 栈 |
| VMware guest / 仿物理模式 | 2 | `./install.sh -d both -t physical --test-profile physical-sim-vmware` | 在可回滚 VM 中走 physical 分支，验证完整包/config/AUR/服务计划及物理专用分支的安全降级 |

其中 `--test-profile physical-sim-vmware` 是**待实现的测试专用参数**；当前 `install.sh:29-33` 只支持 desktop、machine、assume-yes 和 help。未实现前禁止直接在 VMware guest 中把普通 `-t physical` 当作合格的仿物理测试，因为它可能真实启动 VMware host 网络、加载 host-only 模块或错误处理无硬件环境。

“至少两轮”的严格含义：

1. 每种类型必须在最终 `TEST_ID` 下取得两轮独立成功；
2. 每轮都从同一只读确认过的 clean baseline snapshot 恢复，不能在上一轮安装后的脏系统上重跑；
3. 失败、超时、日志缺失、快照未恢复、验收不完整都不计入两轮；
4. 任何进入 guest 的代码、清单、配置、recipe、脚本、测试 harness、软件源/缓存基线或 snapshot 基线发生变化，`TEST_ID` 就变化；此前所有 PASS 均失效，四轮必须在新的 `TEST_ID` 下重新取得；仅修改报告或 artifact 摘要且不进入测试 payload 时除外；
5. 最低 4 个 PASS 必须属于同一最终 `TEST_ID`，才可把夜间任务标为完成；真实物理机验收仍是独立门槛。

### 12.2 夜间执行授权边界

后续用户明确下达“按本报告执行夜间计划”时，也必须同时满足当前项目级边界和执行环境权限；普通用户指令不能单独授权工作区外写入。**在当前 `AGENTS.md` 不变的情况下，VMware VMX、快照、虚拟磁盘和 guest 文件系统均属于工作区外状态，模型只能停留在只读 inventory/实现/静态验证，不能把四轮 VM 测试当作已获授权的动作。**

只有当更高优先级的执行约束明确扩展出“仅限用户指定专用 VMware 测试 VM”的外部操作范围，并且用户明确指定目标 VMX 后，才可执行以下限定动作：

- 修改当前项目工作区内的代码、清单、配置和文档；
- 操作用户明确指定的**专用 VMware 测试 VM**；
- 对该 VM 创建/恢复测试快照、软关机、启动和 guest 内安装；
- 将测试日志写入当前项目的 `artifacts/nightly-validation-20260807/`；
- 在 guest 内执行为本项目验收所必需的包、服务、配置和重启操作。

即使外部范围已被明确允许，也不在该授权范围内：

- 删除、修改、启动或停止任何宿主 KVM/libvirt VM；
- 在宿主安装/卸载包、启停服务、改内核模块、改 GRUB、改网络或改真实 VMX；
- 操作未指定的其他 VMware VM；
- 使用 `vmrun stop ... hard`、强制杀进程或删除虚拟磁盘；
- 把 guest 密码、token、cookie、private key 或 Fish 凭据写入命令行、日志、文档或 Git；
- 为了让测试通过而弱化断言、吞掉失败或把失败检查改成 optional。

如果夜间执行会话没有明确指定允许操作的 VMX，或者发现目标 VM 不是专用测试机，应停止在只读 inventory 阶段并写 checkpoint，不得自行猜测。

### 12.3 执行前硬门槛

只有以下条件全部满足才能开始第 1 轮；若当前执行环境没有得到上一节所述的工作区外 VM 操作许可，应在 inventory 后停止并写 `UNAVAILABLE` checkpoint：

1. 当前执行约束已明确允许操作用户指定的唯一测试 VMX，且目标路径/VM 身份已由用户确认；
2. P0/P1 中会导致永久宿主或 guest 风险的项已经修复并有测试：
   - 临时 sudoers 可靠清理；
   - required failure 正确传播；
   - symlink 部署安全；
   - progress 绑定上下文；
   - machine/config module selection 生效；
3. KVM→VMware 迁移至少完成：
   - VM 模式选 open-vm-tools；
   - physical 模式选 Workstation host；
   - KVM/QEMU/SPICE 活跃 payload 已移除；
   - `vmware-keymaps` AUR 依赖顺序已解决；
4. `physical-sim-vmware` profile 已实现并有静态/单元测试；
5. Hyprland greetd 入口和 DMS session 模型已有明确实现；
6. 当前工作树完成秘密扫描，不含宿主 Fish 凭据；
7. Shell 语法、目标测试、package/mapping reconciliation 全部通过；
8. VMware VM 当前没有运行，或可以通过 guest 正常软关机；
9. snapshot、VMX、虚拟磁盘和 artifact 分区空间充足；
10. 存在可登录的 guest 管理通道，优先 SSH key；不得在 `vmrun -gp` 或 shell history 中放密码；
11. clean baseline 的系统、磁盘、用户、网络和 snapshot 名称已记录；
12. `TEST_ID` 已生成并固定，至少包含 payload manifest、工作区/harness 状态、pacman 数据库与 AUR/source-cache manifest、clean baseline snapshot 标识和 VMX preflight 摘要哈希。

任一查询失败必须记为 `CHECK_FAILED` 或 `UNAVAILABLE`，不能当作条件满足。

### 12.4 专用 VM 和快照规则

- 只操作用户指定的 VMware VMX；执行记录中保存 VMX 路径和 SHA-256，不复制其中可能含环境信息的完整内容；
- 开始时运行 `vmrun list`：若存在非目标 VM，立即停止，不关闭其他 VM；
- 若目标 VM 正在运行，优先 guest 内正常关机，其次 `vmrun stop <vmx> soft`；软关机失败则停止，禁止自动 hard stop；
- 基线快照建议命名：`myarch-clean-base-20260807`；
- 每轮前必须确认目标已关机，再恢复基线；
- 恢复后启动并等待 SSH/guest heartbeat，使用明确超时；
- 每轮结束先收集日志，再正常关机；不得在日志尚未复制时直接 revert；
- snapshot/revert 失败时该轮为 `INFRA_FAIL`，不计成功，也不得继续在未知磁盘状态上测试；
- 不删除基线快照，不自动 compact 虚拟磁盘。

### 12.5 测试 payload、环境基线与 TEST_ID 固定

夜间实现可能尚未 commit，因此不能只记录 Git commit。开始测试前应固定一个机器可读的 `TEST_ID`，而不是只记录代码 hash。`TEST_ID` 至少由以下规范化输入的 SHA-256 组成：待传入 guest 的 payload、执行 harness、排除 artifact/cache 后的待测工作区状态、pacman 同步数据库/镜像状态、AUR/source cache manifest、clean baseline snapshot 标识以及只读 VMX preflight 摘要。开始测试前应：

1. 在工作区生成待测文件清单；
2. 排除 `.git`、artifact、cache、secret、VM 文件和构建产物；
3. 对所有待传入 guest 的文件生成 SHA-256 manifest；
4. 在 `artifacts/nightly-validation-20260807/payloads/<hash>/` 保存：
   - commit ID；
   - `git status --short`；
   - tracked diff；
   - untracked 文件清单；
   - payload SHA-256；
   - package/mapping/recipe 统计；
5. 四轮必须使用同一最终 `TEST_ID`；若任一进入 guest 或影响可重复性的输入改变，生成新的 `TEST_ID`，此前所有成功轮次重新从第 1 轮计数；
6. guest 内再次计算 payload hash，主客机不一致则停止；若 guest 的软件源/缓存或 baseline 证据与 `TEST_ID` 不匹配，也不得继续。

四轮等价性还要求冻结依赖输入：优先使用同一只读本地 pacman repo/cache、同一同步数据库快照和同一 AUR/source cache manifest。若安装流程每轮从滚动镜像重新刷新，或任一包/源码版本发生漂移，该轮必须生成新的 `TEST_ID`，之前的 PASS 失效；不能仅因项目 payload 未变就认定仍是同一测试。

artifact 目录不得被安装器当作配置源，也不应提交到 Git；建议加入 `.gitignore`。

### 12.6 每轮统一步骤

每一轮，无论 VM 模式还是仿物理模式，都按以下顺序：

1. `ROUND_PRECHECK`
   - 记录时间、round ID、payload hash、VMX hash、snapshot、宿主剩余磁盘/内存；
   - 确认没有其他 VMware VM 运行；
2. `REVERT_BASELINE`
   - 软关机目标 VM；
   - 恢复 clean baseline；
   - 启动 VM，等待管理通道；
3. `GUEST_BASELINE_INVENTORY`
   - OS/kernel、virtualization、磁盘、网络、包、enabled/failed units、用户组；
   - 确认不存在上轮 `.install_progress`、安装日志和临时 sudoers；
4. `TRANSFER_AND_VERIFY`
   - 复制固定 payload；
   - guest 内复核 hash；
5. `INSTALL`
   - 通过非交互 SSH 执行；当前安装器在非 TTY 下不会自动重启；
   - VM 轮：`./install.sh -d both -t vm`；
   - 仿物理轮：`./install.sh -d both -t physical --test-profile physical-sim-vmware`；
   - 保存 stdout、stderr、退出码、每阶段耗时和 progress 内容；
6. `PRE_REBOOT_ACCEPTANCE`
   - required 包差异、禁止包差异、sudoers 清理、failed units、配置映射、AUR 产物和日志；
7. `CONTROLLED_REBOOT`
   - guest 内正常重启；
   - 等待 SSH 恢复；
8. `POST_REBOOT_ACCEPTANCE`
   - greetd、Niri、Hyprland、DMS、网络、open-vm-tools/VMware host 计划、MIME、配置与服务；
9. `DESKTOP_ACCEPTANCE`
   - 分别进入 Niri 和 Hyprland；
   - 验证 DMS 状态栏、通知、壁纸、IPC、退出清理和再次登录；
   - Hyprland 收集第 6 章规定的 systemd/DMS/Hyprland 证据；
10. `COLLECT_ARTIFACTS`
    - 将 guest 日志复制到本轮 artifact 目录；
    - 生成 `result.json` 和 `summary.md`；
11. `ROUND_CLOSE`
    - 正常关机；
    - 确认日志完整后，才允许开始下一轮的 baseline revert。

安装命令不加 `-y`，避免安装器自行重启导致日志截断；当前 `install.sh:170-188` 在非 TTY 且未指定 `-y` 时不会自动重启，重启统一由测试 harness 控制。

### 12.7 VM 模式两轮

#### VM-R1：干净基线完整安装

目的：证明 VMware guest 的标准恢复路径第一次可用。

必须验证：

- installer exit 0；
- 03/06/07/08/09/99 没有被错误跳过；
- `systemd-detect-virt` 识别 VMware；
- `open-vm-tools` 被本次目标策略安装/保留并正确启用；
- `vmtoolsd.service` active；需要剪贴板/拖放时验证 vmblock；
- VMware Workstation host 包没有被 VM 策略新增；
- 8 个 KVM/QEMU/SPICE 目标没有被本次策略新增；
- `libvirtd.service` 没有被本项目 enable；
- Niri 和 Hyprland 都能从项目登录入口进入；
- 两个会话中的 DMS 均通过 acceptance；
- nomacs 和 PNG MIME 关联正确；
- 无 `/etc/sudoers.d/99-install-nopasswd` 残留；
- reboot 后没有 required failed unit。

#### VM-R2：同基线独立重复

步骤与 VM-R1 相同，必须重新 revert clean baseline，而不是在 R1 上重跑。

附加比较：

- 使用同一最终 `TEST_ID`（包含 payload hash、软件源/缓存基线和 snapshot/VMX 摘要）；
- 目标包集合、mapping 部署计数和 AUR recipe 结果与 R1 一致；
- 非确定性差异必须解释；
- 总耗时异常增长、网络重试和 DMS 启动时序差异需记录；
- R1 成功但 R2 失败时，VM 类型成功计数归零；若任何输入导致 `TEST_ID` 变化，VM-R1/R2 的旧 PASS 也全部失效，必须重新取得两轮连续成功。

### 12.8 仿物理模式的定义

`physical-sim-vmware` 不是把失败隐藏为成功，而是把**无法在 VMware guest 中安全证明的物理效果**显式标为 `NOT_APPLICABLE_SIMULATED`。

该 profile 必须：

- 保持 `MACHINE_TYPE=physical`，真实走 physical package/config/AUR 分支；
- 真实解析、下载、构建和安装 physical 目标包，以发现依赖、recipe、DKMS 和文件冲突；
- 真实部署 physical 配置到 disposable guest；
- 禁止修改宿主；
- 对 guest 内危险或无意义的 host runtime 动作使用明确 adapter：
  - 不启动嵌套 VMware host 网络；
  - 不执行硬件模式切换；
  - 不依赖真实 ASUS/NVIDIA 设备存在；
  - 不把 unit/hardware 不适用称为 healthy；
- 输出原本会在真实物理机执行的动作清单、unit 存在性和 package/file 验证；
- 对所有非硬件 required 路径仍保持严格失败传播。

物理模拟不能替代真实 ASUS 物理机上的 GPU、ASUS 服务、VMware host networking、USB arbitration 和 DKMS 模块加载验收。

### 12.9 仿物理模式两轮

#### PHY-R1：physical 分支完整模拟安装

必须验证：

- installer exit 0；
- physical 模块确实被选择，不能因检测到 VMware 自动退回 VM 分支；
- Workstation 与 `vmware-keymaps` 的 AUR 构建依赖顺序成功；
- physical 目标包的安装集合符合 manifest；
- KVM/QEMU/SPICE 活跃目标不再出现；
- VMware host unit 文件存在，正确 unit 名和 static unit 规则被验证；
- host-only activation 被记录为 simulated/N/A，而不是执行失败后 warning；
- `open-vm-tools` 若为测试基线管理依赖，只能标记为 pre-existing exception，不能被误判为 physical 策略新增；
- physical 配置、Niri、Hyprland、DMS、nomacs、MIME 均完成非硬件验收；
- 临时 sudoers 和测试 adapter 状态没有残留。

#### PHY-R2：同基线独立重复

与 PHY-R1 使用同一 payload 和同一 clean baseline，重新完整安装。

附加比较：

- Workstation/`vmware-keymaps` 构建顺序与产物哈希一致或有合理版本原因；
- physical package delta、config deployment 和 simulated action manifest 与 R1 一致；
- 没有因为 R1 的宿主/guest cache 或 snapshot 污染而虚假加速通过；
- PHY-R1 成功但 PHY-R2 失败时，仿物理成功计数归零；若任何输入导致 `TEST_ID` 变化，PHY-R1/R2 的旧 PASS 也全部失效，必须重新取得两轮连续成功。

### 12.10 每轮 PASS 判定

一轮只有同时满足以下条件才是 `PASS`：

- 安装器和所有 required acceptance 命令退出 0；
- 没有 required `CHECK_FAILED`、`UNAVAILABLE` 或无法解释的 warning；
- 没有临时 sudoers、错误 progress 或未收集的关键日志；
- expected package/service/config 差异匹配测试 profile；
- 禁止的 KVM host payload 没有被本项目新增；
- 重启后两个桌面会话均验收；
- artifact 完整且包含原始退出码；
- `result.json` 至少记录 `TEST_ID`、payload hash、round ID、测试 profile、baseline snapshot、VMX 摘要和每个 acceptance 的结果枚举；
- VM 正常关机，snapshot 状态可继续恢复。

结果枚举必须使用：

- `PASS`
- `PRODUCT_FAIL`：项目实现/配置失败
- `INFRA_FAIL`：snapshot、SSH、VMware、宿主资源等测试基础设施失败
- `CHECK_FAILED`：检查命令自身失败
- `UNAVAILABLE`：环境没有该检查能力
- `NOT_APPLICABLE_SIMULATED`：仅用于仿物理硬件效果，并必须附理由

除 `PASS` 外都不计入最低两轮。

### 12.11 停止条件

遇到以下情况必须停止自动推进，保存 checkpoint，不得用破坏性绕过：

- 当前有效指令仍禁止工作区外 VM/guest 写入；
- 发现目标不是专用测试 VM；
- 有未授权的其他 VMware VM 正在运行；
- snapshot/revert 或软关机连续失败；
- 需要 hard stop、删除磁盘、改真实 VMX 或修改宿主网络/服务；
- secret scan 命中真实凭据；
- guest 管理凭据只能通过明文参数提供；
- 空间不足可能损坏虚拟磁盘或 artifact；
- physical-sim profile 尚未实现却即将运行普通 physical apply；
- 同一失败在没有新证据/新改动时重复出现；
- 无法区分产品失败与测试基础设施失败。

停止时不是“任务完成”。必须在 checkpoint 写明：阻塞条件、已完成轮次、失败轮次、最后 `TEST_ID` 与 payload hash、日志路径、宿主/VM 未变更声明和唯一下一步。

### 12.12 夜间 checkpoint 与最终交付

固定目录：

```text
artifacts/nightly-validation-20260807/
  checkpoint.md
  payloads/<TEST_ID>/
  rounds/VM-R1/
  rounds/VM-R2/
  rounds/PHY-R1/
  rounds/PHY-R2/
  final-summary.md
```

每轮至少包含：

```text
metadata.json
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

`checkpoint.md` 在每次代码变更、每轮开始、每轮结束和任何阻塞时更新。最终 `final-summary.md` 必须明确：

- 4 个最低 round 的 `TEST_ID`、payload hash、软件源/缓存基线和结果；
- 失败尝试及修复，不得只列最终 PASS；
- 哪些是 simulated/N/A；
- 哪些真实物理机验证仍未完成；
- 未执行或不可用检查；
- 修改文件清单；
- 测试期间没有操作宿主 KVM、没有改宿主系统的声明。

如果到夜间结束没有取得 4 个合格 PASS，应交付真实的部分进度和 checkpoint，不能把“已经跑了四次”写成“完成四轮验证”。

---

## 13. 最终完成门槛

在再次把项目称为“一条命令恢复完整桌面环境”前，至少满足：

### 夜间最低四轮验证

- VM-R1、VM-R2 均为 `PASS`；
- PHY-R1、PHY-R2 均为 `PASS`；
- 四轮属于同一最终 `TEST_ID`；任何影响测试输入或可重复性的修改后，不能沿用旧 PASS；
- 每轮都从 clean baseline snapshot 独立恢复；
- failed/infra/unavailable/N/A 不计入成功轮数；
- 仿物理两轮只证明 physical 分支在 VMware 中的结构和非硬件路径，不替代真实 ASUS 物理机验收。

### 安全与失败语义

- VM 四轮执行时，当前有效约束已明确允许操作唯一指定的专用 VMware VM；若没有该许可，只能交付 `UNAVAILABLE` checkpoint，不能宣称 PASS；
- 任一 required 阶段注入失败时：安装器非零退出、不写 done、临时授权已恢复、日志和产物保留；
- 配置目标为文件、目录、symlink、broken symlink、父目录 symlink 时都有明确且经过测试的行为；
- 仓库和 staged diff 不含宿主秘密；
- 旧 progress 与新参数/commit/manifest 不匹配时被拒绝。

### 桌面矩阵

| 机器 | 桌面 | 必须验证 |
| --- | --- | --- |
| physical | Niri | greetd 登录、DMS、服务、VMware host |
| physical | Hyprland | greetd 登录、受管理 DMS 会话、VMware host |
| physical | both | 可选择两个会话，互不污染 |
| physical | none | 不启用不可用图形登录链 |
| VMware guest | Niri | open-vm-tools、DMS、分辨率/剪贴板目标 |
| VMware guest | Hyprland | DMS 启动链、3D/blur 分离验收 |
| VMware guest | both | 两会话都可进入和退出 |
| VMware guest | none | 无错误 greeter 与无 host 虚拟化栈 |

### VMware

- physical：`vmmon`/`vmnet` DKMS 与服务验证通过；
- guest：`systemd-detect-virt` 为 VMware，`vmtoolsd.service` active；
- VMX preflight 确认 `vmci0.present = "FALSE"`，但项目不越权改真实 VMX；
- snapshot→install→acceptance→revert 流程可重复；
- 项目恢复结果不再安装或启用 KVM host stack。

### 离线与供应链

- 删除 VM 默认路由后，构建全部 AUR recipe 不产生 DNS/TCP 外连尝试；
- `vmware-keymaps` 与 Workstation 的依赖顺序可离线完成；
- 所有缓存文件、git commit、Go/Cargo 数据有结构化完整性证明；
- vendor bundle/ISO 不因“离线方便”未经授权进入公开 Git。

### 文档可信度

- README 中的数字由测试生成或验证；
- 历史 KVM handoff 明确标为 archive；
- VMware 和 Hyprland/DMS 的当前保证只来自最新 acceptance；
- 未执行、失败和不可用检查分别标注，绝不混写为“没有问题”。

---

## 14. 最终判断

仓库仍具备良好的个人恢复数据基础：包策略、桌面配置、AUR recipe、维护脚本和文档已经积累到较高完整度。新增的 VMware 笔记、VM test 开关、nomacs 与宿主配置变化也都有明确价值。

但本轮精读后确认，真正的瓶颈不是“少复制几个文件或少加几个包”，而是三个边界尚未闭合：

1. **成功/失败边界**：多处 required failure 被 warning 或吞掉；
2. **角色边界**：桌面选择、physical/guest、KVM/VMware 和 config mapping 没有统一状态机；
3. **数据边界**：宿主运行状态、主题生成物、私密凭据和可公开恢复资产尚未可靠分离。

因此，当前合理结论是：

> 可以把这份报告作为下一阶段实施任务书，但不应现在就直接运行全量同步、删除宿主 KVM、或把 VMware/DMS 配置未经测试地加入一键恢复路径。

先完成 P0/P1，再按 P2–P5 分批实现，并依照第 12 章取得两类测试各两轮独立 PASS，才能避免把已有风险固化进新的 VMware 恢复方案。
