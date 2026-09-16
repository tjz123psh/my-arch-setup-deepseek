# opencode 配置

> 更新日期：2026-07-25

## 当前配置摘要

| 项 | 内容 |
|---|------|
| 全局配置 | `~/.config/opencode/opencode.json` |
| 默认 agent | `sisyphus-prometheus` |
| 默认强模型 | `anthropic/claude-opus-4-8` |
| 轻量模型 | `opencode/ling-3.0-flash-free`（`small_model`） |
| Gemini MCP | 主 `gemini-3.5-flash-lite`，备用 `gemini-3.5-flash`；优先免费吞吐的图片分析与头脑风暴 |
| Provider | `anthropic`、`linxi`、`other-linxi`（Opus 通道）、`ly`、`daye`（GPT 通道）、`grok`、`google` |
| 凭据 | `~/.local/share/opencode/secrets/*-api-key`，配置里只写 `{file:...}` |
| MCP | `context7`、`gemini-assistant`、`penpot`、`playwright`、`sequential-thinking` |
| Plugin | `opencode-pty`、`opencode-notifier`、`opencode-dcp`（均锁精确版本） |
| LSP | `lua-ls`、`rust`、`clangd` 启用，其余 35 个内置 server 显式关闭 |
| Formatter | `stylua`（内置清单里没有它，需自定义声明） |
| Skills | `~/.config/opencode/skills`，72 个 |
| Commands | `~/.config/opencode/commands` |
| References | `opencode-config`、`opencode-changelog`、`nvim-docs`、`linux-docs` |
| 输出限制 | `tool_output.max_lines=2000`，`max_bytes=65536` |
| 自动压缩 | `compaction.auto=true`，保留最近 10 轮和约 60000 tokens，预留 100000 |

`mk` provider 已删除，`mk/deepseek-ai/deepseek-v4-pro` 不再存在。

## 模型策略

```jsonc
{
  "model": "anthropic/claude-opus-4-8",
  "small_model": "opencode/ling-3.0-flash-free",
  "default_agent": "sisyphus-prometheus"
}
```

- 主任务默认使用强模型，适合代码、配置、排障和多步骤推理。
- `small_model` 用于标题、摘要等轻量任务。选型前必须实测能否返回内容：`opencode/deepseek-v4-flash-free` 曾长期作为 `small_model`，实测 4/4 超时无输出，会话标题因此出现模型思考残句。
- 图片、截图和开放问题的独立第二视角由 `gemini-assistant` MCP 提供；调用前需要权限确认。
- 浏览器验证默认使用 `@playwright/mcp@0.0.78`；MCP 缺失 trace/PDF 等所需能力时，才回退到固定的 `@playwright/cli@0.1.17`。

## 凭据规则

不要把 API key 写进 `opencode.json`。当前使用文件变量：

```text
{file:~/.local/share/opencode/secrets/anthropic-api-key}
{file:~/.local/share/opencode/secrets/daye-api-key}
{file:~/.local/share/opencode/secrets/google-api-key}
{file:~/.local/share/opencode/secrets/linxi-api-key}
{file:~/.local/share/opencode/secrets/ly-api-key}
{file:~/.local/share/opencode/secrets/other-linxi-api-key}
```

权限要求：

```bash
chmod 700 ~/.local/share/opencode/secrets
chmod 600 ~/.local/share/opencode/secrets/*-api-key
```

新增 provider 后先扫描明文：

```bash
rg --pcre2 -n 'sk-[A-Za-z0-9]|AQ\.|apiKey": "(?!\{file:|\{env:)' -g '!node_modules/**' ~/.config/opencode
```

## 核心文件

| 文件 | 作用 |
|------|------|
| `opencode.json` | 全局配置，符合 `https://opencode.ai/config.json` |
| `docs/instructions.md` | 每次会话加载的全局工作约定 |
| `agents/sisyphus-prometheus.md` | 默认主力 agent 提示词 |
| `agents/reviewer.md` | 只读独立复核 agent |
| `agents/scout.md` | 只读检索 agent |
| `docs/build-prompt.md` | 覆盖内置 build agent 的提示词 |
| `dcp.jsonc` | DCP 上下文剪枝插件配置 |
| `mcp/gemini-assistant.mjs` | 本地 Gemini MCP 服务 |
| `commands/*.md` | 常用工作流入口 |
| `skills/**/SKILL.md` | 按需加载的能力入口 |
| `skills/**/references/` | 长 playbook、历史记录、清单 |
| `docs/changelog.md` | 配置事故和踩坑记录 |
| `docs/README.md` | 配置目录说明 |

根目录只保留 opencode 自己按固定路径读取的文件（`opencode.json`、`dcp.jsonc`、`package.json`、`opencode-notifier-state.json`）和 `agents/`、`commands/`、`skills/`、`mcp/`、`scripts/` 目录；纯文档统一放 `docs/`。`instructions` 与 build agent prompt 由 `opencode.json` 显式指向 `docs/`，移动这些文件必须同步改配置。

## Agents

| Agent | 模式 | 用途 |
|------|------|------|
| `sisyphus-prometheus` | primary | 默认主力 agent：读现场、执行、验证、收尾 |
| `build` | primary | 全栈/前端/代码实现任务，prompt 来自 `build-prompt.md` |
| `reviewer` | subagent | 唯一只读复核，`anthropic/claude-opus-4-7`；拒绝写操作和一切外发通道 |
| `scout` | subagent | 只读检索，`opencode/ling-3.0-flash-free`；只回报位置和数量 |

图片理解由 `gemini-assistant` MCP 提供，不再有独立的 `vision` agent。

只读 agent 的实际工具集用 `opencode debug agent <name> --pure` 确认，不要只读 frontmatter：`edit: deny` 不会自动挡住 `write`、`patch` 和 `task`，这些要分别显式拒绝。

## Commands

| Command | 用途 |
|---------|------|
| `/audit-opencode` | 审计 opencode 配置、agents、skills、commands、凭据引用 |
| `/audit-capabilities` | 审计 Agents、Skills、MCP、Commands、插件与上下文管理如何增强模型能力 |
| `/frontend` | 以 UI Contract 串联平台设计、实现、截图复核和风险分级验收 |
| `/handoff` | 为当前项目生成/更新交接文件 |
| `/model-eval` | 用可复现对照评测模型或 agent 路由 |
| `/nvim-audit` | 检查 Neovim 配置、health、快捷键、文档同步 |
| `/review` | 调用只读 reviewer 复核当前改动 |

## LSP 与 Formatter

`lsp` 和 `formatter` 键**缺失等于全部关闭**，不是使用内置默认（opencode 内部是 `if (!config.lsp) log("all LSPs are disabled")`）。这两个键在 2026-07-25 之前一直没配，所以此前所有会话都没有编辑期诊断，连已装好的 rust-analyzer、clangd 也没被调用。

内置 38 个 server 中，启用但二进制不在 PATH 的多数会从 GitHub releases 拉不受版本控制的二进制。当前策略是只启用二进制已由包管理器管理的三个，其余 35 个显式 `disabled`：

| Server | 二进制 | 备注 |
|--------|--------|------|
| `lua-ls` | `lua-language-server`（pacman） | 必须带 `initialization` 声明 LuaJIT 与 `vim`/`jit` 全局，否则 nvim 配置全是 `Undefined global vim` 误报 |
| `rust` | `rust-analyzer`（`rustup component add`） | PATH 上的同名文件曾是 rustup shim，组件未装时执行即失败，`command -v` 查不出来 |
| `clangd` | `clangd`（pacman） | 带 `--background-index --clang-tidy` |

Formatter 只声明 `stylua`（内置清单里没有它），跟随项目自己的 `stylua.toml`。已验证它在 `edit` 工具路径生效，**`write` 路径不触发**。

`~/.local/share/nvim/mason/bin` 不在 PATH，opencode 看不到 mason 的工具，因此这些二进制走 pacman，与 nvim 的 mason 各自独立。

新增语言支持时：先装二进制并确认能执行，再把对应 server 从 `disabled` 改为 `command`，不要直接写 `"lsp": true`。

## 外部工具

| 工具 | 用途 | 接入点 |
|------|------|--------|
| `gh` | GitHub release/tag/PR | `git-push` 的发布流程 |
| `gitleaks` | 按内容扫描凭据泄露 | `git-push` 的敏感内容扫描 |
| `cargo-audit` | Rust 依赖漏洞审计 | `instructions.md` 的依赖审计规则 |

`gitleaks` **必须带 `--redact`**：不加时报告的 `Secret` 字段含明文凭据。`gitleaks dir` 只看当前工作树，`gitleaks git` 才能发现已删除但仍在历史中的凭据，两者不可互替。`exit 1` 表示有 findings，不是命令失败。

## Skills 结构

```text
~/.config/opencode/skills/
├── meta/             # workflow / brainstorming / session-context / skill-creator / script-composer / model-routing-eval
├── tool/             # ocr / web-content-extractor / web-search
├── git/              # git-workflow / git-push / using-git-worktrees
├── nvim/             # neovim-arch / neovim-debugging / config-auditing / nvim-troubleshooting
├── engineering/      # testing-strategy / backend-service
├── system/           # linux-packaging / niri-ipc
└── frontend-design/  # design-reasoning 编排 Web / Desktop / App / TUI 设计、实现与验收
```

`engineering` 与 `system` 放系统级是因为知识跨项目复用（回归测试落点、systemd 单元形状、XDG 路径在每个项目都一样）。单个项目的具体约定写进该项目的 `AGENTS.md` 或 `.opencode/`，不上升到全局。

维护规则：

- `SKILL.md` 只放触发条件、核心流程、验证标准。
- 长流程、历史问题、示例放 `references/`。
- 当前入口 `SKILL.md` 控制在 150 行以内，长自检与平台矩阵按需放入 references。
- 修改 skill 后运行 `~/.config/opencode/scripts/check-skills.sh`。

### 前端交付链

新建、重设计或“做个好看/高级前端”等宽泛请求统一从 `design-reasoning` 开始，形成产品、结构、视觉、令牌、状态、响应式和验收七项 UI Contract。每个阶段只设一个主导 Skill；Tauri 的桌面外壳与 WebView 内容分别走 Desktop/Web 基线。新建或重设计必须完成一次“真实运行 → 截图 → 视觉评审 → 修正 → 再截图”，然后按 Smoke、Standard 或 Release 运行 Web/Desktop 行为验收。可直接使用 `/frontend <需求>` 进入该流程。

## 当前重要变更

- 2026-07-25：补齐 `lsp` / `formatter`（此前全程关闭）；装 lua-language-server、stylua、gh、gitleaks、cargo-audit、rust-analyzer 组件；新增 `scout` 只读检索 subagent；新增 `testing-strategy`、`backend-service`、`linux-packaging` 三个后端/系统向 skill；`small_model` 从超时的 `deepseek-v4-flash-free` 换成 `ling-3.0-flash-free`。
- `git-push`、`nvim-troubleshooting`、`neovim-arch`、`using-git-worktrees`、`config-auditing` 已拆成短入口 + references。
- 前端 artifact skill 已从 Claude artifact 口径改为本地 HTML artifact。
- `using-git-worktrees` 触发条件已收紧：普通任务不自动创建 worktree。
- Neovim 相关 skill 已同步当前快捷键：`J/K` 移动当前行，`gh` 悬浮文档，`<leader>j` 合并下一行。

## 验证命令

```bash
~/.config/opencode/scripts/check-config.sh
~/.config/opencode/scripts/check-skills.sh
opencode mcp list
opencode agent list --pure
opencode debug agent scout --pure      # 确认只读 agent 的实际工具集
opencode debug lsp diagnostics <file>  # 确认 LSP 真返回诊断，不看退出码
```

不要直接运行 `opencode debug config`，它会解析凭据引用；使用 `scripts/check-config.sh` 输出脱敏摘要。

验证模型是否真的可用要看实际输出，不能只看 exit code：超时的模型也可能返回 0 和空输出。

## 同步规则

修改 opencode 后至少同步：

```text
~/.config/opencode/docs/README.md
~/.config/opencode/skills/meta/workflow/SKILL.md
~/md/opencode/opencode配置.md
```

不再同步 Obsidian 里的旧配置备份，除非用户明确要求。
