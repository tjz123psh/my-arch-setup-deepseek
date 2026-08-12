# 如何增改（维护指南）

本文回答一个核心问题：**以后要加软件包、加配置、加服务、换桌面组件，穿插进这个仓库，问题大吗？**

结论：**不大，但有固定套路。** 仓库是「数据驱动」的——安装器不写死清单，而是读
`manifests/` 下的表格；你加东西 = 加一行数据（+ 对应文件），极少需要改脚本本身。
按下面的清单逐项做，**提交前跑一次 `./check-extend.sh`**（一键总检，红了不许提交）
就能自证没破坏现有流程。

> **增改门禁（强制）**：任何增改 commit 前必须 `./check-extend.sh` 全绿。
> 核心 8 节（自动快速模式）：bash 语法、shellcheck、清单一致性、配置内容语法、
> recipe 双向引用、secret scan、README 数字、行为测试；改脚本/测试自动升级全量
> 13 节（含慢速行为套件）。模型与操作者一视同仁。

## 总原则

| 想改什么 | 动哪里 | 要跑什么验证 |
|---|---|---|
| 加/删官方软件包 | `manifests/workstation-packages.tsv` 加一行 | reconciliation 测试 |
| 加/删 AUR 包 | `manifests/aur-recipes.tsv` + `third_party/aur/<name>/` + 包清单 | reconciliation 测试 + fetch-aur-sources.sh 重新生成缓存 |
| 加/改个人配置 | `config/` 放文件 + `manifests/config-mappings.tsv` 加一行 | reconciliation 测试 |
| 加/改 `~/scripts` 脚本 | 直接改本机 `~/scripts`，跑 `sync-scripts.sh` | sync 输出无缺口 |
| 加/改服务或 timer | `scripts/08-services.sh` 的 `SERVICES=` 或 timer 循环 | bash -n + 一次 VM 重装 |
| 改系统设置（locale/时区/录屏等） | `scripts/09-settings.sh` | bash -n + VM 重装 |
| 换 AUR 源、镜像等 | `scripts/01-mirror.sh` / `scripts/06-aur.sh` | VM 重装 |

> 数字会漂移：包数（install/total）、映射数、recipe 树数、config 文件数等清单计数**以 `./check-extend.sh` 的 reconcile 输出为准**（运行后看 numbers 节打印的权威块）；README 已不再写死这些数字，随清单变化处均指向 reconcile。tar 体积会随增改变化：每次增改后重新打包
> `~/Downloads/my-arch-setup.tar`（权威命令见 `docs/physical-offline-install.md`：`tar --exclude='.git' --exclude='.aur-sources' --exclude='artifacts' --exclude='.install_logs' --exclude='.ai' -czf ~/Downloads/my-arch-setup.tar my-arch-setup-deepseek`），
> 并按需更新 README 的代码包体积数字。

## 一、加一个官方软件包

1. 编辑 `manifests/workstation-packages.tsv`，按现有行格式追加一行：
   ```
   包名	pacman	extra	pacman	<module>	package-only	install	current-explicit	一句话用途
   ```
   - `module` 用现有分类（`cli-tools`/`desktop-shared`/`audio`/`bluetooth`/`fonts` 等），
     没有合适的新建一个即可（03-packages 按 module 过滤 wm 专用包，其余全装）。
   - 驱动类包**不要**加在这里——统一放 `scripts/04-drivers.sh`（物理机专属）。
2. 跑 `tests/workstation-package-reconciliation-test.sh` 确认格式与引用合法。
3. 更新 README 包数字。

**archlinuxcn 包的迁移例外：**如果旧 AUR 包提供同名虚拟包（本项目的
`flclash-bin` 提供 `flclash`），不能只把一行的 channel 改成 pacman。必须
同时删除旧 AUR recipe/离线源，确认目标仓库元数据，并在安装器中显式处理
冲突和逐名验收；`pacman -Q flclash` 可能只显示 provider，不能替代对
`flclash` 与 `flclash-bin` 的精确检查。

## 二、加一个 AUR 包（比官方包多三步）

1. **准备 recipe**：在 `third_party/aur/<包名>/` 建目录，放入审阅过的 PKGBUILD
   （+ 必要的 .install / 补丁 / Cargo.lock 等）。参照现有 recipe 的 REVIEW.md 记录来源与审查结论。
2. **登记**：`manifests/aur-recipes.tsv` 加包名；`workstation-packages.tsv` 加一行
   （repository=`aur`，module 按用途）。
3. **更新离线缓存**：在有海外网络的机器跑 `fetch-aur-sources.sh`——它按
   aur-recipes.tsv 抓源码进 `~/Downloads/aur-sources/`。**必须重新生成**，否则物理机
   离线安装新 AUR 包会因无源码失败（在线安装不受影响）。
4. **若新包是 Rust 且用 cargo 构建**（如 paru 这类）：注意 `Cargo.lock` 是否随源码
   提供；paru 的 Cargo.lock 是手工固定在仓库里的（见 `third_party/aur/paru/`），
   版本升级时要同步刷新，否则 `cargo fetch --locked` 会失败。
5. 跑测试 + 更新 README。

## 三、加/改个人配置

1. 把文件放进 `config/` 对应位置（`config/home/.config/...` 或 `config/etc/...`）。
2. 在 `manifests/config-mappings.tsv` 加一行：
   ```
   physical-v1	<module>	config/home/.config/xxx	.config/xxx	<mode>
   ```
   - mode：可执行文件 `755`，普通文件 `644`，含敏感内容（如凭据/密钥）`600`。
   - **凭据类文件不入库**（AGENTS.md 规定）：api key/token/密码不 capture。
3. 跑 reconciliation 测试（会校验 source 文件存在、scope 合法）。
4. VM 重装验证配置确实部署到目标路径。

## 四、加/改 `~/scripts` 脚本（最省事）

本机 `~/scripts` 是日用品。改完后：

```bash
cd ~/Projects/my-arch-setup-deepseek && ./sync-scripts.sh
```

它会把 `~/scripts` 镜像进 `config/home/scripts/` 并自动补映射行（可执行 755 /
普通 644），输出"0 gaps"即同步完成。之后正常 commit/push。

## 五、加/改服务

编辑 `scripts/08-services.sh`：
- `SERVICES=(...)` 数组加系统服务（enable --now）。
- timer 循环加 timer 名。
- 用户级服务在脚本后面 `as_user` 段处理。

注意：新增服务如果只在物理机有意义（如 supergfxd 之类），要包在
`[[ "${MACHINE_TYPE}" == "physical" ]]` 判断里；否则 VM 会多装一个起不来的服务。

## 六、验证纪律（每次增改后，提交前）

1. **跑 `./check-extend.sh`** —— 一键总检（核心 8 节，全量 13 节，见上）。**任一节红 = 禁止提交**；
   红了按输出定位到节，修复后重跑至全绿。
2. 改脚本逻辑（非纯数据）时，至少跑一次 VM 全新重装（`-d niri -t vm`），
   确认闭环 11 步（01-mirror→09-settings + 99-cleanup）。物理机专属改动用
   `-t physical` 在 VM 里跑路径。
3. 更新 README 数字 + 重新打包 `~/Downloads/my-arch-setup.tar`。
4. commit + push（git-push 约定见 AGENTS/仓库惯例）。

## 七、宿主 → 仓库 差异同步（本机改好了，把状态收进仓库）

宿主重装/折腾后，把"本机已有但仓库没有"的配置和包补进仓库。**给审计子 agent 的 prompt 必须带上仓库契约**，否则它会推荐"测试明确禁止入库"的东西（2026-08-10 实例：配置审计推荐了 nvim 的 DMS 主题，实际被 `nvim-config-test.sh` 明确排除）。

**审计 prompt 必须包含的契约提示**：
1. `tests/nvim-config-test.sh` 断言排除的 DMS nvim 集成（`colors/dms.lua`、`lua/lualine/themes/dms.lua`）——**不得入库**
2. `scripts/03-packages.sh` 的 flclash-bin 迁移契约——旧 AUR 包不补，走 archlinuxcn `flclash`
3. 凭据红线（AGENTS）：`gh/hosts.yml`、`pulse/cookie`、fish 明文 key、任何 token/密码**严禁入库**；API key 只允许 `{file:...}`/`{env:...}` 引用
4. `libvirt` 配置视为宿主资产（AGENTS 绝对指令二），**不得同步**
5. 运行时/生成物不入库：浏览器 profile、QQ 数据、缓存、DMS/matugen 生成物（`dms/*.lua`、`colors.ini`、`dank-theme.conf`）、`*.bak`、vmtest 副本、`fish_variables`、`node_modules`
6. 包审计注意：宿主若经离线 `pacman -U` 恢复，**所有包可能都标为显式**（`pacman -Qe` 语义失效）——按依赖关系分类，别按 install reason 判断

**主 agent 整合必做**：
1. 复制文件进 `config/home/` → `./sync-config-mappings.sh --module <默认模块>` 自动补映射（新目录没有可继承 module 时用 `--module`；`config/etc` 不走映射，脚本直接部署）
2. 更新 how-to-extend/README 的包数字（`check-extend` 的 numbers 节会拦错的）
3. `./check-extend.sh --full` 全量验证（含 reconciliation/nvim 契约/行为套件）
4. 判定准则：a 该入库 / b 运行时不入库 / c 不确定——**宁可少加**，c 类列在报告里给用户定

## 增改的「穿插成本」到底多大

- **加官方包 / 加配置 / 加脚本**：5 分钟级别，纯数据操作，风险极低（有测试兜底）。
- **加 AUR 包**：5 分钟（在线模式：清单加一行，paru 自动拉最新版）到 30 分钟
  （离线模式：还需生成离线缓存 + 可能要调 PKGBUILD）。06-aur 是双模式：无
  `.aur-sources/` 缓存 → paru 装最新；有缓存 → makepkg 构建固定 recipe。
  当前 AUR 目标数随清单变化（见 `./check-extend.sh` reconcile 输出；另有
  vmware-keymaps 构建依赖树）；迁移或删除旧 recipe 时必须同步清理 06、
  离线缓存脚本（fetch-aur-sources.sh）和 manifest。
- **改脚本逻辑**：1 小时级别，必须 VM 重装验证。
- **红线（伤筋动骨，必须 VM 重验 + 换新 TEST_ID）**：改 manifests schema（表格列含义）、
  改 config-mappings 的 scope 体系、改 DESKTOP_ENV 过滤逻辑、改安装器核心脚本主流程
  （00-utils/03/06/07/08/09）。按 TEST_ID/clean-baseline 规则，任何代码/清单/recipe/
  cache 变化都使旧 PASS 失效——红线改动不能拿旧验收结果宣称"验收通过"，必须重新冻结
  payload、生成新 TEST_ID 并完整重验。
- **唯一「伤筋动骨」的改动**：改 manifests schema（表格列含义）、改
  config-mappings 的 scope 体系、改 DESKTOP_ENV 过滤逻辑——这些会牵动 03/07 两个
  步骤和全部数据，需要额外小心并完整重验。除此之外，穿插增改是安全的。

## 相关文件速查

| 文件 | 作用 |
|---|---|
| `manifests/workstation-packages.tsv` | 官方 + AUR 包清单（唯一安装来源） |
| `manifests/aur-recipes.tsv` | AUR recipe 登记 |
| `manifests/config-mappings.tsv` | 配置部署映射（scope=physical-v1） |
| `third_party/aur/` | 固定 AUR recipe + 审查记录 |
| `scripts/04-drivers.sh` | 物理机驱动（唯一按机型区分的安装逻辑） |
| `scripts/08-services.sh` | 服务/timer 启用 |
| `scripts/09-settings.sh` | 系统设置 + snapper + 录屏引擎 |
| `fetch-aur-sources.sh` | 生成 AUR 离线缓存（增 AUR 后必跑） |
| `sync-scripts.sh` | 同步本机 ~/scripts 进仓库 |
| `sync-config-mappings.sh` | 为 config/home 新增文件自动生成 config-mappings.tsv 行（module 继承/幂等/按执行位定 mode） |
| `tests/` | 数据一致性测试 |
| `check-extend.sh` | 提交前一键总检（增改门禁；默认按改动范围自动选快慢——只改数据/文档→快速 8 节，改脚本/测试→全量 13 节；`--fast`/`--full` 强制；`--deploy` 闸门通过后同步到宿主；`--only=`/`--skip=` 局部调试） |
| `tests/validate-config-syntax.sh` | 配置内容语法校验（按类型分流；含 QML 结构配平；缺工具 SKIP 并列出人工清单） |
| `tests/check-extend-test.sh` | 错误注入自证（坏配置/重复包/数字漂移/secret/孤儿 recipe 必须被抓住） |
