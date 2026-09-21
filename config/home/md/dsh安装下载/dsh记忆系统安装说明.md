# DeepSeek Harness (dsh) 记忆系统安装说明

> 本文档基于 2026-08-23 在本机的实际配置整理。
> dsh 版本以 npm 最新发布版为准；部署请以现网技能锚点为准（`verify.sh` 的 `EXPECTED_DSH_VERSION`，升级 dsh 后见第五节维护例行）。姊妹篇见《dsh安装指南》。

---

## 一、这是什么

一套让 AI 模型"从容装卸 dsh 插件不出 bug"的**全局运维记忆**，解决两个问题：

1. **自动化加载**——不依赖模型自觉翻笔记，运维守则通过 deployment persona 注入到**每一个请求**的系统提示里；
2. **抗版本漂移**——dsh 是预览版，知识自带版本锚点和自校验脚本，升级后能机械地发现知识过期并引导修订。

采用双层架构：

| 层 | 载体 | 作用 |
|---|---|---|
| 自动注入层 | 家目录补丁层 `~/.dsh/cordis.patch.yml` | 把一条"运维守则"覆盖进 system-prompt 的 persona，每请求必然可见 |
| 知识本体层 | 两个用户级技能：`~/.dsh/skills/dsh-plugin-management/`（插件域）与 `~/.dsh/skills/dsh-upgrade/`（dsh 本体域） | 各自的 SOP + 坑表/变更表 + **唯一的**自校验脚本（在 dsh-upgrade），模型按守则提示加载 |

> 为什么不把 SOP 全文塞进 persona：每请求多几百 token、编辑破坏 KV cache 稳定性、细节越具体越易过期。
> 为什么不用本地插件注册 prompt section：插件代码与预览版 API 强耦合，升级即挂且可能阻断启动。

## 二、组成文件清单

| 文件 | 职责 |
|---|---|
| `~/.dsh/cordis.patch.yml` | 全局补丁层（跨 profile 生效）。仅一条补丁：覆盖 `system-prompt` 行的 `persona`，在原身份句后追加运维守则 |
| `~/.dsh/skills/dsh-plugin-management/SKILL.md` | 插件域入口：分诊、心智模型、安装/卸载 SOP、路径速查与插件台账；坑表在 `references/plugin-traps.md` |
| `~/.dsh/skills/dsh-upgrade/SKILL.md` | dsh 本体域入口：**版本锚点（唯一）**、升级门禁与 SOP、回滚、升级后维护例行 |
| `~/.dsh/skills/dsh-upgrade/references/` | `breaking-changes.md`（逐版破坏性变更与迁移）、`session-data.md`（会话格式与运维）、`platform-patches.md`（平台侧补丁） |
| `~/.dsh/skills/dsh-upgrade/scripts/verify.sh` | 自校验脚本，7 项机械探测（见第四节） |

三者是配套整体：守则负责"提醒加载"，SKILL.md 负责"怎么干"，verify.sh 负责"知识是否过期"。

## 三、从零安装步骤

### 前提

- dsh 已按《dsh安装指南》装好并能运行 `dsh web`
- pnpm 已安装（插件管理依赖它）。本机为**独立版布局**：`~/.local/share/pnpm`（入口 `~/.local/bin/pnpm`，可 `pnpm self-update` 自升级）；备选：`npm install -g --prefix ~/.npm-global pnpm`

### 步骤 1：部署技能目录

```sh
mkdir -p ~/.dsh/skills/dsh-plugin-management/references
mkdir -p ~/.dsh/skills/dsh-upgrade/scripts ~/.dsh/skills/dsh-upgrade/references
```

放入以下文件（本机现网文件可直接拷贝迁移）：

- `dsh-plugin-management/SKILL.md` + `references/plugin-traps.md`
- `dsh-upgrade/SKILL.md` + `references/breaking-changes.md`、`session-data.md`、`platform-patches.md`
- `dsh-upgrade/scripts/verify.sh`，并 `chmod +x`

**为什么是两个技能**：插件的生命周期与 dsh 本体的版本演进变化速率不同——插件 SOP 稳定，而版本锚点、破坏性变更与迁移项每版都变。混在一个技能里会造成『每升级一次就要改插件技能』的耦合；拆开后 **版本锚点与 verify.sh 唯一归属 `dsh-upgrade`**，两边各留一行交叉引用（触发词不同：装插件 vs 升级本体）。

技能目录会被 dsh 的文件系统技能提供者（rank 400 的 user-dsh 根）自动发现，**热生效无需重启**。

### 步骤 2：写入自动注入补丁

创建 `~/.dsh/cordis.patch.yml`，内容如下（在原 persona 句后追加守则段；`{{model}}`/`{{cwd}}` 是已注册模板变量，保留不动）：

```yaml
# 家目录全局补丁层 —— 跨 profile 生效，在各 profile 层之后应用。
# 匹配不到的补丁仅警告并跳过，绝不会阻断启动。
- id: system-prompt
  name: "@deepseek-ai/dsh-system-prompt"
  config:
    persona: >-
      You are a coding agent powered by the {{model}} model. Your working
      directory is {{cwd}}.
      运维守则：涉及 DSH 时先按领域加载对应技能并严格按其流程执行——
      · 安装/卸载/更新插件、主题、扩展，或诊断插件加载类报错（Failed to load
        plugins、bundle script failed to load、pnpm not found 等）→ 加载
        dsh-plugin-management；
      · 查询版本、升级/降级/回滚 dsh 本体、评估破坏性变更、会话数据格式迁移、
        启动变慢等本体侧问题 → 加载 dsh-upgrade。
      动手前先运行 dsh --version 核对所加载技能标注的验证版本；不一致则先运行
      该技能的 scripts/verify.sh（dsh-upgrade/scripts/verify.sh）并按输出校准知识，
      再执行用户任务。
```

⚠️ 补丁语义注意：`config` 键是**整体替换**该条目配置。当前上游该行 config 只有 persona 一个字段，所以这样写无损；若未来版本加了别的字段，需合并后重写（verify.sh 第 4 项会探测这种情况）。

### 步骤 3：重启 Web 服务使补丁生效

补丁走组合树，和插件一样**启动时固化**：

```sh
~/scripts/dsh/dsh-web.sh --stop && ~/scripts/dsh/dsh-web.sh
```

技能部分不需要等重启，写入即被 watcher 发现。

## 四、验证

```sh
bash ~/.dsh/skills/dsh-upgrade/scripts/verify.sh
```

7 项检查中除已知的 persona 遮蔽 `[WARN]` 外应全 `[PASS]`、退出码 0 即为健康：

1. CLI 版本 = 技能标注的锚点版本
2. pnpm 可用
3. lib 中仍存在 `dsh.profile.bundles` 对账逻辑
4. 上游 standard 预设的 persona 起始句未漂移（防我们的补丁覆盖掉官方新文案）
5. 组合树中 persona 已含运维守则（注入存活；因预设 persona 遮蔽，此项带 `[WARN]`）
6. zod 承重解除（web 层实体副本）
7. 上游启动提速补丁是否在位（`npm install` 会覆盖，启动器会自动补）

也可人工确认：`dsh --profile web --dump-config | grep 运维守则`

## 五、升级 dsh 后的维护例行

1. 跑一遍 `verify.sh`；
2. 有 `[DRIFT]` 按输出修订：
   - 版本/命令变更 → 更新 **`dsh-upgrade/SKILL.md`（版本锚点的唯一归属）** 与脚本顶部锚点常量；
   - 上游 persona 变更 → diff `config/agent-presets/standard/agent.cordis.yml`，把新文案合并进补丁的 persona；
3. 重跑直至全绿。

最坏情况论证：dsh 改名/移除了 system-prompt 条目时，补丁匹配不到只是**警告并跳过**——守则静默失效退化为普通技能，不会阻断启动。

## 六、卸载

删除以下三项即可完全移除，互不留残留：

```sh
rm ~/.dsh/cordis.patch.yml
rm -rf ~/.dsh/skills/dsh-plugin-management ~/.dsh/skills/dsh-upgrade
~/scripts/dsh/dsh-web.sh --stop && ~/scripts/dsh/dsh-web.sh   # 重启去除 persona 注入
```

## 七、已沉淀的核心经验（SKILL.md 内容速览）

- `dsh plugin add/remove` 只是 pnpm 转发器，装完会自动对账 `dsh.profile.bundles`
- **启动时序坑**：服务在插件仍装着时启动、之后才卸载 → 页面报 Failed to load plugins 且插件 URL 404，磁盘其实已干净，再重启一次即愈
- pnpm 缺失或 npm 装到 /usr 报 EACCES → 用户级安装；本机 pnpm 现为独立版布局（`~/.local/share/pnpm`，入口 `~/.local/bin/pnpm`）
- git clone GitHub 常挂起 → 插件优先走 npm registry

---

## 附录：知识本体的迁移

SKILL.md 与 verify.sh 是自包含文本，整目录拷贝即可在任意机器复现：

```sh
rsync -a ~/.dsh/skills/dsh-plugin-management/ 新机器:~/.dsh/skills/dsh-plugin-management/
rsync -a ~/.dsh/skills/dsh-upgrade/           新机器:~/.dsh/skills/dsh-upgrade/
scp ~/.dsh/cordis.patch.yml 新机器:~/.dsh/cordis.patch.yml
```

建议把 `~/.dsh/skills/` 与 `~/.dsh/cordis.patch.yml` 纳入 dotfiles 备份（如 my-arch-setup-deepseek 仓库）。
