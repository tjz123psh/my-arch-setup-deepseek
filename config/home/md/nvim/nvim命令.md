# Neovim 命令速查表

> 在命令行输入命令按回车执行

## 常用内置命令

| 命令 | 用途 |
|------|------|
| `:e <文件>` | 打开文件 |
| `:w` | 保存 |
| `:q` | 关闭当前窗口 |
| `:wq` | 保存并关闭 |
| `:q!` | 强制关闭（不保存） |
| `:qa` | 关闭所有窗口 |
| `:wa` | 保存所有文件 |
| `:x` | 保存并退出（同 `:wq`） |

## 配置文件相关

| 命令 | 用途 |
|------|------|
| `:so $MYVIMRC` | 重新加载 `init.lua`（部分生效） |
| `:luafile %` | 将当前 `.lua` 文件作为 Lua 执行 |
| `:R` | 重新加载当前打开的 `.lua` 配置文件（仅 .lua 文件中可用） |
| `:A` | 打开启动欢迎页 |

## 插件管理

| 命令 | 用途 |
|------|------|
| `:Lazy` | 打开 lazy.nvim 插件管理界面 |
| `:Lazy sync` | 同步/安装/更新所有插件 |
| `:Lazy update` | 更新所有插件 |
| `:Lazy clean` | 清理未使用的插件 |
| `:Lazy check` | 检查插件更新 |
| `:Lazy reload <插件名>` | 重新加载指定插件 |
| `:Lazy restore` | 从 lockfile 恢复插件版本 |

## 工具安装与诊断

| 命令 | 用途 |
|------|------|
| `:Mason` | 打开 Mason 界面（安装 LSP、格式化器、调试器） |
| `:MasonInstall <包名>` | 安装指定工具（如 `:MasonInstall clangd pyright`） |
| `:MasonUninstall <包名>` | 卸载指定工具 |
| `:MasonUpdate` | 更新 Mason 注册表 |

## 健康检查

| 命令 | 用途 |
|------|------|
| `:checkhealth` | 运行全部健康检查 |
| `:checkhealth vim.deprecated` | 查看弃用 API 警告 |
| `:checkhealth vim.lsp` | 检查内置 LSP 配置、命令和 filetype |
| `:checkhealth lazy` | 检查 lazy.nvim 状态 |
| `:checkhealth mason` | 检查 Mason 状态 |
| `:checkhealth telescope` | 检查 Telescope 状态 |

## 信息查看

| 命令 | 用途 |
|------|------|
| `:messages` | 查看最近的消息/日志 |
| `:LspInfo` | 查看当前缓冲区 LSP 客户端状态 |
| `:LspLog` | 打开 LSP 日志文件 |
| `:Telescope keymaps` | 查看所有快捷键映射 |
| `:Telescope help_tags` | 搜索帮助文档 |
| `:Telescope diagnostics` | 查看所有诊断（错误/警告） |
| `:Telescope commands` | 搜索所有可用命令 |

## 打开指定 UI

| 命令 | 用途 |
|------|------|
| `:Alpha` | 打开启动欢迎页 |
| `:Neotree` | 打开文件树 |
| `:Neotree toggle` | 切换文件树开关 |
| `:Telescope find_files` | 搜索文件名 |
| `:Telescope live_grep` | 搜索文件内容 |
| `:Telescope buffers` | 切换已打开的缓冲区 |
| `:Telescope oldfiles` | 查看最近打开的文件 |
| `:Projects` | 打开项目列表；首次打开会同步读取 project.nvim 历史，回车切换项目并打开/刷新文件树 |

## 调试命令

| 命令 | 用途 |
|------|------|
| `:DapNew` | 创建 / 编辑调试配置（交互式界面） |
| `:DapContinue` | 开始 / 继续调试 |
| `:DapToggleBreakpoint` | 切换断点 |

## Java

| 命令 | 用途 |
|------|------|
| `:JavaInit` | 在 Java 包根目录生成最小 `pom.xml`，只作为 jdtls 项目根标记 |
| `:JavaRun` | 运行当前 Java 源文件；有 package 时按需编译当前文件和依赖源码后运行 |

## 快捷键速查

| 命令 | 用途 |
|------|------|
| `:Telescope keymaps` | 在 Telescope 中搜索所有快捷键 |
| `<leader>hk` | 打开/关闭个人快捷键速查浮动窗口 |
| `:map` | 列出普通模式快捷键 |
| `:imap` | 列出插入模式快捷键 |
| `:vmap` | 列出可视模式快捷键 |
| `:tmap` | 列出终端模式快捷键 |
