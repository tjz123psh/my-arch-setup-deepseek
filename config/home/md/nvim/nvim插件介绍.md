# Neovim 插件介绍

> 所有插件通过 lazy.nvim 管理，配置文件在 `lua/plugins/` 下

---

## 主题与外观

### catppuccin/nvim

| 项目 | 说明 |
|------|------|
| **功能** | 主题配色（mocha 风格），覆盖所有插件高亮统一 |
| **配置** | `plugins/theme.lua` |
| **加载** | `lazy = false`, `priority = 1000`（最高优先级，其他插件前加载） |
| **集成** | treesitter、LSP、blink.cmp（`blink_cmp = true`）、telescope、indent-blankline、lualine、noice、DAP、which-key |
| **备注** | 透明背景启用；终端透明度由 kitty/Neovide 配置配合 |

### nvim-lualine/lualine.nvim

| 项目 | 说明 |
|------|------|
| **功能** | 底部状态栏，显示模式、文件名（含路径）、Git 分支、LSP 诊断、文件类型、进度、光标位置 |
| **配置** | `plugins/statusline.lua` |
| **加载** | `event = "UIEnter"` |
| **依赖** | catppuccin（主题适配） |
| **备注** | neo-tree 和 alpha 页面自动隐藏状态栏；诊断按错误/警告/信息/提示显示对应图标和颜色 |

### akinsho/bufferline.nvim

| 项目 | 说明 |
|------|------|
| **功能** | 顶部标签栏，展示所有打开的缓冲区，支持图标、诊断计数、neo-tree 偏移 |
| **配置** | `plugins/bufferline.lua` |
| **加载** | `event = "VeryLazy"`，也可由 `<S-h>`/`<S-l>` 提前触发 |
| **快捷键** | `<S-h>` 上一个缓冲区、`<S-l>` 下一个缓冲区 |
| **依赖** | nvim-web-devicons、catppuccin |
| **备注** | 标签样式 `thin`，关闭按钮「󰅖」，修改标记「●」，诊断按严重级别显示图标和数量，neo-tree 展开时自动偏移；关闭缓冲区用 `bdelete %d`，不会强制丢弃未保存修改 |

### lukas-reineke/indent-blankline.nvim

| 项目 | 说明 |
|------|------|
| **功能** | 缩进位置画竖线，帮助看清代码层级 |
| **配置** | `plugins/indentline.lua` |
| **加载** | `event = "VeryLazy"` |
| **备注** | 竖线字符「│」，作用域高亮关闭（避免太花哨） |

---

## 终端

### akinsho/toggleterm.nvim

| 项目 | 说明 |
|------|------|
| **功能** | 多终端管理器，支持浮动窗口、水平/垂直分屏、多终端实例（`:1` `:2`） |
| **配置** | `plugins/terminal.lua` |
| **加载** | `cmd = "ToggleTerm"`，也可由 `<leader>tt/th/tv` 触发 |
| **快捷键** | `<leader>tt` 切换浮动终端、`<leader>th` 水平分割、`<leader>tv` 垂直分割 |
| **备注** | 复用 keymaps.lua 的终端退出 `jk`；默认 `direction = "float"`，使用插件默认自适应尺寸和圆角边框 |

---

## 文件树与导航

### folke/flash.nvim

| 项目 | 说明 |
|------|------|
| **功能** | 屏幕跳转：按 `s` + 目标字符 → 屏幕上出现标签 → 按标签字母跳到对应位置。比传统 `f/t` 更快，手指不离主行 |
| **配置** | `plugins/flash.lua` |
| **加载** | `event = "VeryLazy"` |
| **快捷键** | `s` Flash 跳转（n/x/o）、`S` Treesitter 选择（n/x/o） |
| **备注** | 覆盖 Vim 默认 `s`（删除字符进入插入模式），用户不需要默认行为 |

### nvim-neo-tree/neo-tree.nvim

| 项目 | 说明 |
|------|------|
| **功能** | 左侧文件树，显示项目文件结构，支持 Git 状态图标、文件监听自动刷新 |
| **配置** | `plugins/filetree.lua` |
| **加载** | `cmd = "Neotree"` |
| **快捷键** | `<leader>e` 打开/关闭 |
| **依赖** | plenary.nvim、nui.nvim、nvim-web-devicons |
| **文件树内快捷键** | `h` 上级目录、`l` 设为根目录、`r` 重命名、`m` 移动、`p` 显示隐藏文件 |
| **备注** | 默认 `follow_current_file` 跟踪当前文件，`bind_to_cwd = true` 跟随 CWD；从项目列表选中项目后，文件树根目录会同步到该项目；`use_popups_for_input = false` 使输入框由 dressing.nvim 统一渲染 |

### nvim-telescope/telescope.nvim

| 项目 | 说明 |
|------|------|
| **功能** | 模糊搜索核心工具，搜索文件名、文件内容、缓冲区、帮助文档等 |
| **配置** | `plugins/telescope.lua` |
| **加载** | `cmd = "Telescope"` |
| **快捷键** | `<leader>ff` 搜索文件名、`<leader>fg` 搜索内容、`<leader>fb` 切换缓冲区、`<leader>fh` 搜索帮助、`<leader>fd` 搜索个人文档（~/md）、`<leader>fp` 搜索项目、`<leader>fc` 搜索 Neovim 配置 |
| **依赖** | plenary.nvim、project.nvim（扩展） |
| **扩展** | projects（已移到 telescope config 注册） |
| **备注** | 圆角自适应水平布局，搜索框置顶，智能缩短路径并显示动态预览标题；弹窗内用 `<C-j>`/`<C-k>` 上下选择 |

### ahmedkhalf/project.nvim

| 项目 | 说明 |
|------|------|
| **功能** | 项目管理，通过 `.git`、CMake、Node、Go、Rust、Maven、Gradle 等标记自动检测项目根目录，联动 Telescope 实现项目快速切换 |
| **配置** | `plugins/project.lua` |
| **加载** | `lazy = false`，启动即初始化项目历史，保证启动页第一次打开项目列表就有内容 |
| **快捷键** | `<leader>fp` 通过 `:Projects` 浏览项目 |
| **备注** | 对 project.nvim 做了 monkey-patch：用 `vim.lsp.get_clients()` 替换已废弃的 `vim.lsp.buf_get_clients()`，只返回非空 root_dir，并包装 `set_pwd()` 在项目切换后同步已加载的 neo-tree 根目录；`:Projects` 同步读取历史，避免异步缓存导致第一次列表为空 |

---

## 代码补全与 LSP

### saghen/blink.cmp

| 项目 | 说明 |
|------|------|
| **功能** | 代码补全引擎，替代 nvim-cmp。支持 LSP、代码片段、缓冲区内容、路径补全 |
| **配置** | `plugins/completion.lua` |
| **加载** | `lazy = false`（立即加载，确保补全始终可用） |
| **快捷键** | `<CR>`/`<Tab>` 选中、`<Tab>`/`<S-Tab>` 前后跳转片段占位符、`<C-n>`/`<C-p>` 上下选择、`<C-e>` 关闭、`<C-u>`/`<C-d>` 文档翻页 |
| **补全来源** | lsp、snippets、buffer、path |
| **备注** | 使用 Neovim 原生 `vim.snippet`，自动读取 friendly-snippets；catppuccin 直接启用 `blink_cmp` 集成 |

### neovim/nvim-lspconfig

| 项目 | 说明 |
|------|------|
| **功能** | LSP 客户端配置框架，管理 clangd、lua_ls、jdtls、gopls、rust_analyzer、html、cssls、jsonls、yamlls、marksman 等语言服务器 |
| **配置** | `plugins/lsp/init.lua` |
| **加载** | `lazy = false` |
| **依赖** | mason.nvim、mason-lspconfig.nvim、blink.cmp |
| **快捷键** | `gd` 跳转定义、`gR` 类型定义、`gr` 引用、`gi` 实现、`gh` 悬停文档、`[d`/`]d` 诊断导航、`<leader>rn` 重命名、`<leader>ca` 代码操作、`<C-k>` 签名提示 |
| **备注** | jdtls 跳过（由 nvim-jdtls 管理）。使用 Neovim 0.12 新 API `vim.lsp.config()` 注册；`[d`/`]d` 使用 `vim.diagnostic.jump` |

### williamboman/mason.nvim

| 项目 | 说明 |
|------|------|
| **功能** | LSP 服务器、格式化工具、调试器安装管理器：`:Mason` 打开界面安装 |
| **配置** | `plugins/mason.lua` |
| **加载** | `lazy = false`，启动时先 setup；`:Mason` 打开管理界面 |
| **依赖** | mason-tool-installer.nvim（自动安装列表见独立文件） |

### williamboman/mason-lspconfig.nvim

| 项目 | 说明 |
|------|------|
| **功能** | Mason 和 lspconfig 的桥接：自动安装 clangd、lua_ls、jdtls、gopls、rust_analyzer、html、cssls、jsonls、yamlls、marksman |
| **配置** | 作为 lsp/init.lua 的依赖，`opts.ensure_installed` 指定列表 |
| **加载** | 作为 lspconfig 的依赖自动加载 |
| **备注** | `automatic_enable = false` 不自动启用，由 lspconfig 手动接管；setup 前显式调用 `require("mason").setup({ PATH = "prepend" })`，避免 Mason 未初始化警告 |

### WhoIsSethDaniel/mason-tool-installer.nvim

| 项目 | 说明 |
|------|------|
| **功能** | 自动安装非 LSP 工具（调试器、格式化器等） |
| **配置** | `plugins/mason-tool-installer.lua`（独立文件，通过 dependencies 引用 mason） |
| **加载** | 作为 mason 的依赖自动加载 |
| **自动安装** | codelldb、java-debug-adapter、java-test、delve、stylua、google-java-format、clang-format、tree-sitter-cli |

### rafamadriz/friendly-snippets

| 项目 | 说明 |
|------|------|
| **功能** | 为常用语言提供现成代码片段，由 blink.cmp 内置 snippets source 读取 |
| **配置** | 作为 `plugins/completion.lua` 的依赖；片段展开和占位符跳转使用 Neovim 原生 `vim.snippet` |
| **加载** | 随 blink.cmp 加载 |
| **备注** | 替代未实际接入 Blink、也没有片段定义的 LuaSnip 空配置，减少无效插件逻辑 |

---

## 界面增强

### folke/noice.nvim

| 项目 | 说明 |
|------|------|
| **功能** | 命令行美化：按 `:` 弹出居中浮动输入框（78 字符宽，窄终端自动收缩，圆角边框）；通知消息和 LSP 进度提示 |
| **配置** | `plugins/noice.lua` |
| **加载** | `lazy = false` |
| **依赖** | nui.nvim、nvim-notify |
| **备注** | `nvim-notify` 接管 `vim.notify`，避免 noice 使用 notify view 时缺依赖；过滤了搜索计数和 jdtls 进度的冗余通知；补全菜单后端用 nui 渲染；与 dressing.nvim 协作实现全局输入框风格统一 |

### stevearc/dressing.nvim

| 项目 | 说明 |
|------|------|
| **功能** | 美化 `vim.ui.select` / `vim.ui.input`，将底部菜单改为居中浮动窗口（代码操作、查找替换等）。配合 neo-tree 统一输入框风格 |
| **配置** | `plugins/dressing.lua`，input 宽度 78 字符、圆角边框、居中显示，与 noice cmdline 样式协调 |
| **加载** | `event = "VeryLazy"` |
| **依赖** | 无 |
| **备注** | neo-tree 设置 `use_popups_for_input = false` 将输入操作委托给 vim.ui.input，由 dressing 接管统一渲染 |

### goolord/alpha-nvim

| 项目 | 说明 |
|------|------|
| **功能** | 启动欢迎页，显示 NEovIM ASCII 艺术字 Logo 和快捷按钮 |
| **配置** | `plugins/dashboard.lua` |
| **加载** | 仅无文件参数时由 `VimEnter` 自动加载；有文件启动时不抢首屏，但 `:Alpha` / `:A` 仍可按需加载 |
| **快捷键** | `f` 查找文件、`r` 最近文件、`c` 打开 Neovim 配置、`p` 项目列表、`n` 新建文件、`q` 退出 |
| **备注** | 宽终端显示完整 ASCII Logo 和路径，窄终端切换为紧凑标题和目录名，避免裁切 |

### folke/which-key.nvim

| 项目 | 说明 |
|------|------|
| **功能** | 快捷键提示：按 `g`、`z`、`[`、`]` 等前缀键后弹出浮动窗口，显示该前缀下所有快捷键 |
| **配置** | `plugins/whichkey.lua`（内含 `g`、`z`、`[`、`]`、`<C-w>` 等前缀的全量快捷键说明） |
| **加载** | `event = "VeryLazy"` |
| **备注** | 新增快捷键时需要在 `whichkey.lua` 的 `spec` 中添加对应条目才会有提示 |

---

## 编辑辅助

### windwp/nvim-autopairs

| 项目 | 说明 |
|------|------|
| **功能** | 自动补全括号：输入 `(` 自动加 `)`，输入 `{` 自动加 `}`，以此类推 |
| **配置** | `plugins/autopairs.lua` |
| **加载** | `event = "InsertEnter"` |
| **备注** | 使用默认配置 |

### kawre/neotab.nvim

| 项目 | 说明 |
|------|------|
| **功能** | 按 Tab 跳出括号/引号：当光标在 `]`、`)`、`}`、`'`、`"`、`` ` ``、`>` 等配对符内时，Tab 直接跳出而非输入空格 |
| **配置** | `plugins/neotab.lua` |
| **加载** | `event = "InsertEnter"` |
| **备注** | `act_as_tab = true` 保证无补全时 Tab 正常输入空格；与 blink.cmp 协作：补全菜单显示时 Tab 先触发补全确认，无菜单时走 neotab |

### nvim-zh/better-escape.vim

| 项目 | 说明 |
|------|------|
| **功能** | 用 `jk` 快速退出插入模式，不依赖 timeoutlen，无延迟感 |
| **配置** | `plugins/betterescape.lua` |
| **加载** | `event = "InsertEnter"` |
| **备注** | 间隔 200ms，比默认 timeoutlen 方案响应更快 |

### numToStr/Comment.nvim

| 项目 | 说明 |
|------|------|
| **功能** | 快速注释：`gcc` 注释/取消注释当前行，`gc` 注释/取消注释选中区域 |
| **配置** | `plugins/comment.lua` |
| **加载** | `keys = { "gc" }`（按到 `gc` 时触发） |

### nvim-treesitter/nvim-treesitter

| 项目 | 说明 |
|------|------|
| **功能** | Treesitter 语法解析器，提供精确的语法高亮、代码折叠、智能缩进 |
| **配置** | `plugins/treesitter.lua` |
| **加载** | `lazy = false`（新版 nvim-treesitter 不支持 lazy-loading）+ `cmd = { "TSInstall", "TSUpdate", "TSConfigInfo" }` |
| **备注** | 自动安装未安装的语言解析器，安装前兼容 Mason CLI 加载时序；清单包括 bash、c/cpp、css、go、html、java、javascript、json、lua、markdown、rust、vim、yaml 等 |

---

## 调试

### mfussenegger/nvim-dap

| 项目 | 说明 |
|------|------|
| **功能** | DAP（调试适配器协议）客户端，配合 codelldb 调试 C/C++/Rust、delve 调试 Go、jdtls 调试 Java |
| **配置** | `plugins/dap/init.lua` |
| **加载** | DAP 快捷键按需触发；Java 配置需要时也会自动加载模块 |
| **依赖** | nvim-dap-ui（调试界面）、nvim-nio（异步 IO）、nvim-dap-virtual-text（行内变量值） |
| **快捷键** | `<leader>dl` 重跑上次调试、`<leader>db` 断点列表、`<leader>dB` 条件断点、`<leader>dL` 日志断点、`<leader>dC` 清除所有断点、`<F5>` 继续、`<F9>` 切换断点、`<F10>` 单步跳过、`<F11>` 单步进入、`<F12>` 单步跳出 |
| **备注** | 调试 UI 放右侧（避免和左侧 neo-tree 冲突）；调试开始自动打开 UI，结束自动关闭；断点符号改用 Nerd Font 图标 |

### rcarriga/nvim-dap-ui

| 项目 | 说明 |
|------|------|
| **功能** | DAP 图形界面：右侧面板显示变量、断点、堆栈、监视，底部显示 REPL 和日志 |
| **配置** | 作为 dap 依赖，在 `plugins/dap/init.lua` 中配置布局 |
| **加载** | 作为 dap 的依赖自动加载 |

### nvim-neotest/nvim-nio

| 项目 | 说明 |
|------|------|
| **功能** | 异步 IO 库，nvim-dap-ui 的依赖 |
| **配置** | 作为 dap 的依赖 |
| **加载** | 作为 dap 的依赖自动加载 |

### theHamsta/nvim-dap-virtual-text

| 项目 | 说明 |
|------|------|
| **功能** | 调试时在行尾显示变量值，无需切换到 scopes 面板 |
| **配置** | 作为 dap 依赖，`opts.all_frames = true` 显示所有栈帧，`virt_text_pos = "eol"` 放行尾 |
| **加载** | 作为 dap 的依赖自动加载 |

---

## 代码格式化

### stevearc/conform.nvim

| 项目 | 说明 |
|------|------|
| **功能** | 代码格式化引擎，保存文件时自动格式化，也支持手动触发 |
| **配置** | `plugins/format.lua` |
| **加载** | `event = { "BufWritePre" }`，并保留 `<leader>F` 手动触发 |
| **快捷键** | `<leader>F` 手动格式化 |
| **支持的格式工具** | stylua（lua，2 格）、google-java-format（java，4 格，`--aosp`）、clang-format（c/cpp，4 格）、rustfmt（rust，4 格） |
| **格式化器配置文件** | `~/.clang-format`（clang-format） |
| **备注** | `format_on_save.timeout_ms = 2000` 超时保护；`lsp_format = "fallback"` 优先用显式配置的格式化器，缺失时再用 LSP；Lua 跟随 `stylua.toml` 使用 2 格，其余常用语言使用 4 格 |

---

## 语言专用

### mfussenegger/nvim-jdtls

| 项目 | 说明 |
|------|------|
| **功能** | Java 语言服务器增强（Eclipse JDTLS），提供代码补全、调试、重构等完整 Java 开发体验 |
| **配置** | `plugins/lang/java.lua` |
| **加载** | `ft = { "java" }`（打开 Java 文件时加载） |
| **快捷键** | `<F5>` 调试 Java（输入主类名）、`<leader>co` Java 代码操作、`<leader>ot` 整理 import |
| **依赖** | nvim-dap（调试）、mason 安装的 jdtls 和 java-debug-adapter |
| **备注** | lspconfig 已跳过 jdtls（由本插件接管）；自动将 java-debug-adapter 的 JAR 作为 bundles 传给 jdtls；工作区目录按项目名分开存储，避免反复索引 |

## C/C++ 语言附加配置

### plugins/lang/cpp.lua

| 项目 | 说明 |
|------|------|
| **配置位置** | `plugins/lang/cpp.lua`（通过 `lang/init.lua` 聚合加载） |
| **clangd 参数** | `--background-index`（后台索引）、`--clang-tidy`（启用 clang-tidy 检查）、`--completion-style=detailed`、`--header-insertion=iwyu` |
| **codelldb 调试** | 通过 mason 安装 codelldb，配置为 server 类型，端口动态分配 |
| **备注** | clangd 的 `opts.servers.clangd` 扩展了 `lsp/init.lua` 中的基础配置；显式固定 filetypes 为 `c/cpp/objc/objcpp/cuda/proto`，避免 `c.doxygen/cpp.doxygen` health warning；DAP 配置含 `cpp`（3 种）、`c`（2 种） |

### Rust 语言（plugins/lang/rust.lua）

Rust 的 LSP 配置在 `lsp/init.lua`（基础）和 `lang/rust.lua`（扩展）中，DAP 配置在 `lang/rust.lua` 中（复用 codelldb 适配器），格式化器 rustfmt 来自 rustup 管理的 stable 工具链。

| 项目 | 说明 |
|------|------|
| **LSP** | `rust_analyzer` 通过 mason-lspconfig 自动安装，配置在 `lsp/init.lua` `opts.servers.rust_analyzer` |
| **DAP** | 复用 codelldb（`cpp.lua` 定义适配器），`lang/rust.lua` 中配置 `rust` 类型（启动调试取 `target/debug/` 路径 + attach） |
| **格式化** | `rustfmt` 由 rustup component 提供，`format.lua` 中配置 `formatters_by_ft.rust` |
| **前置** | Arch 上安装 `rustup` 包，执行 `rustup default stable`，再安装 `rust-src rustfmt clippy` |
| **备注** | `rust_analyzer` 仅在 `rustc` 和 `cargo` 可用时启用；当前 `rustc --print sysroot` 指向 `~/.rustup/toolchains/stable-x86_64-unknown-linux-gnu`；检查命令使用 `check.command = "clippy"` |

### plugins/lang/go.lua

| 项目 | 说明 |
|------|------|
| 项目 | 说明 |
|------|------|
| **配置位置** | `plugins/lang/go.lua`（通过 `lang/init.lua` 聚合加载） |
| **gopls LSP** | 通过 mason-lspconfig 自动安装 `gopls`，启用 gofumpt、unusedparams、unreachable 分析、staticcheck |
| **delve 调试** | 通过 mason 自动安装 `delve`，配置为 server 类型；单配置 `启动调试`，自动编译运行当前 package |
| **快捷键** | 复用 DAP 全局快捷键（`<F5>` 启动、`<F9>` 断点等） |

---

## 依赖库

### nvim-tree/nvim-web-devicons

| 项目 | 说明 |
|------|------|
| **功能** | 文件类型图标，被 bufferline、neo-tree、telescope 等插件共用 |
| **配置** | 不单独配置，作为其它插件的依赖引入 |

### nvim-lua/plenary.nvim

| 项目 | 说明 |
|------|------|
| **功能** | 通用工具库，提供异步 IO、文件操作、字符串处理等基础功能 |
| **配置** | 不单独配置，作为 telescope、neo-tree 等插件的依赖引入 |

### MunifTanjim/nui.nvim

| 项目 | 说明 |
|------|------|
| **功能** | UI 组件库，提供浮动窗口、输入框等底层组件 |
| **配置** | 不单独配置，作为 noice、neo-tree 等插件的依赖引入 |

---

## 配置文件对应关系

| 配置文件 | 用途 / 对应插件 |
|----------|------------------|
| `plugins/autopairs.lua` | nvim-autopairs |
| `plugins/betterescape.lua` | better-escape.vim |
| `plugins/bufferline.lua` | bufferline.nvim |
| `plugins/comment.lua` | Comment.nvim |
| `plugins/completion.lua` | blink.cmp |
| `plugins/dashboard.lua` | alpha-nvim |
| `plugins/filetree.lua` | neo-tree.nvim |
| `plugins/flash.lua` | flash.nvim |
| `plugins/format.lua` | conform.nvim |
| `core/filetypes.lua` | 自定义 filetype 识别 |
| `plugins/indentline.lua` | indent-blankline.nvim |
| `plugins/mason.lua` | mason.nvim |
| `plugins/mason-tool-installer.lua` | mason-tool-installer.nvim |
| `plugins/neotab.lua` | neotab.nvim |
| `plugins/dressing.lua` | dressing.nvim |
| `plugins/noice.lua` | noice.nvim |
| `plugins/project.lua` | project.nvim |
| `plugins/statusline.lua` | lualine.nvim |
| `plugins/terminal.lua` | toggleterm.nvim |
| `plugins/telescope.lua` | telescope.nvim |
| `plugins/theme.lua` | catppuccin/nvim |
| `plugins/treesitter.lua` | nvim-treesitter |
| `plugins/whichkey.lua` | which-key.nvim |
| `plugins/dap/init.lua` | nvim-dap + nvim-dap-ui + nvim-nio |
| `plugins/lsp/init.lua` | nvim-lspconfig + mason-lspconfig |
| `plugins/lang/init.lua` | 语言配置聚合入口 |
| `plugins/lang/cpp.lua` | clangd 扩展 + codelldb DAP |
| `plugins/lang/java.lua` | nvim-jdtls + Java DAP |
| `plugins/lang/go.lua` | gopls + delve DAP |
| `plugins/lang/rust.lua` | rust_analyzer 扩展 + codelldb Rust DAP |

---

> **插件总数**：34 个（不含 lazy.nvim 本身）
> **最后更新**：2026-07-14
