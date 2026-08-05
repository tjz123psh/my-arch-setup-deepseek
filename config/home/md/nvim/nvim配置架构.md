# Neovim 配置架构

> 本文档描述整个 Neovim 配置的组织结构、加载顺序和设计约定。

## 加载顺序

```
init.lua
  ├── vim.g.mapleader = " "           ← 先设 leader 键
  ├── vim.g.maplocalleader = "\\"     ← 设本地 leader 键（预留）
  ├── require("core")                 ← 加载 core/init.lua
  │     ├── options.lua               ← 编辑器全局选项
  │     ├── filetypes.lua             ← 自定义文件类型识别
  │     ├── keymaps.lua               ← 全局快捷键
  │     ├── commands.lua              ← 自定义命令
  │     └── autocmds.lua             ← 自动命令
  ├── require("core.lazy")           ← 启动 lazy.nvim
  │     └── lazy 自动加载 lua/plugins/
  │           ├── *.lua               ← 顶层文件自动识别
  │           ├── */init.lua          ← 子目录自动识别
  │           └── 其他 .lua           ← 需由父级 init.lua 手动 require
  └── if neovide → require("neovide")
```

## 目录树

```
~/.config/nvim/
├── init.lua                    ← 入口文件
├── lazy-lock.json              ← 插件版本锁定
│
├── lua/
│   ├── core/
│   │   ├── init.lua            ← 按顺序加载核心模块
│   │   ├── lazy.lua            ← lazy.nvim 启动和配置
│   │   ├── options.lua         ← 全局设置（行号、缩进、搜索等）
│   │   ├── filetypes.lua       ← gotmpl、mdx、docker-compose/gitlab/helm YAML
│   │   ├── keymaps.lua         ← 全局快捷键（窗口、保存、搜索等）
│   │   ├── cheatsheet.lua      ← 快捷键速查浮动窗口（<leader>hk 打开/关闭）
│   │   ├── commands.lua        ← 自定义命令（:R、:A、:Projects、:LspInfo、:LspLog、:JavaInit、:JavaRun）
│   │   └── autocmds.lua        ← 自动命令（文件类型、插入模式事件）
│   │
│   ├── neovide.lua             ← Neovide GUI 专用：透明度、字体、光标动画、缩放快捷键
│   │
│   └── plugins/                ← 插件配置，每文件管理一个或一组插件
│       ├── theme.lua           ← catppuccin 主题
│       ├── treesitter.lua      ← nvim-treesitter 语法高亮
│       ├── completion.lua      ← blink.cmp + 原生 vim.snippet + friendly-snippets
│       ├── mason.lua           ← mason 工具安装器
│       ├── mason-tool-installer.lua ← 调试器自动安装列表
│       ├── lsp/init.lua        ← nvim-lspconfig + mason-lspconfig
│       ├── flash.lua           ← flash.nvim 屏幕跳转
│       ├── format.lua          ← conform.nvim 自动格式化
│       ├── telescope.lua       ← telescope.nvim 模糊搜索
│       ├── filetree.lua        ← neo-tree.nvim 文件树
│       ├── bufferline.lua      ← bufferline.nvim 标签栏
│       ├── statusline.lua      ← lualine.nvim 状态栏
│       ├── dashboard.lua       ← alpha-nvim 欢迎页
│       ├── dressing.lua        ← dressing.nvim 美化 vim.ui.select（代码操作菜单等）
│       ├── noice.lua           ← noice.nvim 命令行美化
│       ├── whichkey.lua        ← which-key.nvim 快捷键提示
│       ├── autopairs.lua       ← nvim-autopairs 自动括号
│       ├── comment.lua         ← Comment.nvim 注释工具
│       ├── indentline.lua      ← indent-blankline.nvim 缩进线
│       ├── neotab.lua          ← neotab.nvim Tab 跳出括号
│       ├── betterescape.lua    ← better-escape.vim jk 不延迟
│       ├── project.lua         ← project.nvim + monkey-patch（启动即初始化项目历史）
│       ├── terminal.lua        ← toggleterm.nvim 浮动/分屏终端
│       ├── dap/init.lua        ← nvim-dap + nvim-dap-ui + nvim-dap-virtual-text 调试器
│       └── lang/
│           ├── init.lua        ← 聚合入口
│           ├── cpp.lua         ← clangd 扩展 + codelldb C/C++/Rust 调试
│           ├── java.lua        ← nvim-jdtls + Java 调试
│           ├── go.lua          ← gopls + delve Go 调试
│           └── rust.lua        ← rust_analyzer 扩展 + codelldb Rust 调试
```

## 插件配置约定

### opts 与 config 的选择

| 方式 | 适用场景 | 示例 |
|------|----------|------|
| `opts = { ... }` | 简单插件，直接给 setup() 传参 | dashboard.lua、autopairs.lua |
| `opts = function(_, opts)` | 需合并或修改 opts | cpp.lua 扩展 clangd |
| `config = function(_, opts)` | 多步骤逻辑、注册快捷键 | lsp/init.lua、java.lua |

### 延迟加载方式

| 方式 | 用途 | 示例 |
|------|------|------|
| `lazy = false` | 必须立即加载 | 主题、mason、lspconfig、blink.cmp、project.nvim、noice |
| `event = "UIEnter"` | UI 出现后加载 | 状态栏 |
| `lazy = false` | 启动时加载 | treesitter（新版不支持 lazy-loading） |
| `event = "InsertEnter"` | 进入插入模式时加载 | autopairs、betterescape、neotab |
| `event = "VeryLazy"` | 启动后加载 | flash、indentline、whichkey、dressing |
| `event = "BufWritePre"` | 保存前加载 | conform（格式化） |
| 条件 `event = "VimEnter"` | 无文件参数时加载 | alpha 欢迎页；有文件时仍保留 `:Alpha` / `:A` 按需加载 |
| `ft = "java"` | 打开特定类型文件时加载 | nvim-jdtls |
| `cmd = "Telescope"` | 输入命令时加载 | telescope、mason |
| `keys = { "gc" }` | 按到对应键时加载 | comment、bufferline |
| `keys + event` | 混合触发 | telescope（cmd + keys）、conform（event + keys） |

### 子目录加载规则

- `dap/init.lua` — 被 lazy 自动加载（`*/init.lua` 模式）
- `lsp/init.lua` — 被 lazy 自动加载
- `lang/init.lua` — 被 lazy 自动加载，然后在内部 `require` 同目录的 `cpp.lua` 和 `java.lua`

```
lua/plugins/lang/
├── init.lua    ← lazy 自动加载
├── cpp.lua     ← init.lua 通过 require 手动加载
├── java.lua    ← init.lua 通过 require 手动加载
├── go.lua      ← init.lua 通过 require 手动加载
└── rust.lua    ← init.lua 通过 require 手动加载
```

## 特殊处理

| 位置 | 问题 | 处理方式 |
|------|------|----------|
| project.lua | `vim.lsp.buf_get_clients()` 在 0.10 已废弃 | 运行时 monkey-patch `find_lsp_root`，不修改插件文件 |
| commands.lua / project.lua | 启动页第一次打开项目列表为空，且项目列表二次选择可能卡住 | project.nvim `lazy = false` 先初始化；`:Projects` 同步读取历史并使用自定义 Telescope picker，回车只切项目和刷新文件树，不走 `Telescope projects` 的嵌套 find_files |
| project.lua / filetree.lua | 从项目列表切换项目后文件树仍停在旧目录 | neo-tree `filesystem.bind_to_cwd = true`，且 project.nvim `set_pwd()` 成功后主动刷新已加载的 neo-tree filesystem state |
| lsp/init.lua | jdtls 不由 lspconfig 管理 | `setup = { jdtls = function() return true end }` 跳过 |
| lsp/init.lua | mason-lspconfig 早于 mason setup 会启动告警 | mason-lspconfig config 中先 `require("mason").setup({ PATH = "prepend" })` 再 setup |
| lsp/init.lua | `vim.diagnostic.goto_prev/goto_next` 在 0.12 废弃 | `[d`/`]d` 改用 `vim.diagnostic.jump({ count = ±1, float = true })` |
| core/filetypes.lua | LSP health 报 Unknown filetype | 用 `vim.filetype.add()` 注册 gotmpl、markdown.mdx、docker-compose/gitlab/helm YAML |
| java.lua | 0.12+ `vim.lsp.start` 不解析函数式 root_dir | 在 config() 中预求值为字符串再传 opts.root_dir |
| java.lua | 同一会话切不同 Java 项目时 workspace_dir 不更新 | `cmd_base` 保存基础 cmd，`build_cmd()` 每次 start_or_attach 时重新拼装 `-data` 参数，按项目名隔离 workspace |
| autopairs.lua | 特殊界面不宜自动补全 | `opts = {}`（blink.cmp 在无补全窗口时正常触发） |
| betterescape.lua | 插件的 vim.g 变量需在 setup 前设置 | 用 `config` 而非 `init` 也行，在 InsertEnter 时加载 |
| format.lua | 保存自动格式化 500ms 偏短，Java/C++/Rust 大项目易超时 | `timeout_ms = 2000` |
| format.lua | LSP 可能抢先于显式 formatter | `lsp_format = "fallback"`，显式工具优先，LSP 兜底 |
| bufferline.lua | `bdelete!` 会丢未保存修改 | 改为 `bdelete %d` |
| options.lua | 退出含未保存修改的缓冲区时容易误操作 | `confirm = true`，退出/关闭前明确确认 |
| dashboard.lua | `cond = argc == 0` 会让带文件启动后的 `:A` 也不可用 | 只给 `VimEnter` 事件加条件，保留 `Alpha` 命令按需加载；窄窗口使用紧凑 Logo/页脚 |
| treesitter.lua | Treesitter 可能早于 Mason setup，找不到已安装的 CLI | 安装解析器前检测并补入 Mason bin 路径；补齐 JavaScript 解析器 |
| filetree.lua | `r` 被错误映射成 move，与界面和文档不一致 | `r` 恢复重命名，`m` 单独用于移动 |
| telescope.lua | 默认搜索窗口信息密度和视觉层级不统一 | 顶部搜索框、智能路径、动态预览标题、圆角自适应布局 |
| lazy.lua | checkhealth 报 luarocks/hererocks 警告 | `rocks = { enabled = false }` |
| options.lua | checkhealth 报 node/python/perl/ruby provider 警告 | `vim.g.loaded_*_provider = 0` |
| options.lua | shell 写死路径不够稳 | `vim.fn.exepath("bash")` 找到 bash 时再设置 |
| core/cheatsheet.lua | 原速查窗口样式简单、小终端可能越界 | 改为严格受终端宽高约束的浮动命令面板；分区、快捷键列高亮；`<leader>hk` 再按关闭，`q`/`Esc` 关闭 |

## 当前快捷键约定

| 按键 | 说明 |
|------|------|
| `J` | 普通模式下移当前行，支持数字前缀 |
| `K` | 普通模式上移当前行，支持数字前缀 |
| `J` / `K` | 可视模式下移/上移整块选中行，保持选择和缩进 |
| `<leader>j` | 合并下一行 |
| `gh` | LSP 悬浮文档 |
| `<leader>hk` | 打开/关闭个人快捷键速查浮动窗口 |

## 添加新内容指南

### 加插件

在 `lua/plugins/` 下新建 `.lua` 文件，返回 lazy.nvim spec 表即可。

### 加语言支持

1. 如有新文件类型，先在 `core/filetypes.lua` 补识别规则
2. 在 `lsp/init.lua` 的 `mason-lspconfig.ensure_installed` 里加语言服务器名
3. 在 `lsp/init.lua` 的 `servers` 表里加配置
4. 如需 DAP，在 `lang/` 下新建文件，并在 `lang/init.lua` 里 `require`
5. 如需格式化器，在 `mason-tool-installer.lua` 的 `ensure_installed` 里添加

## 文档同步规则

修改 Neovim 配置后同步本地文档：

```text
~/md/nvim/nvim快捷键.md
~/md/nvim/nvim命令.md
~/md/nvim/nvim插件介绍.md
~/md/nvim/nvim配置架构.md
~/md/opencode/opencode配置.md（涉及 opencode skill/命令时）
```

当前不再同步 Obsidian 里的旧配置备份，除非用户明确要求。
