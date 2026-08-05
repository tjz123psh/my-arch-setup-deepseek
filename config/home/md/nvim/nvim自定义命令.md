# Neovim 自定义命令速查表

> 定义在 `lua/core/commands.lua` 中

| 命令 | 用途 |
|------|------|
| `:R` | 重新加载当前打开的 `.lua` 配置文件 |
| `:A` | 返回启动欢迎页 |
| `:LspInfo` | 查看当前缓冲区 LSP 客户端状态 |
| `:LspLog` | 打开 LSP 日志文件 |
| `:Projects` | 打开项目列表，首次打开同步读取项目历史，回车切换项目并刷新文件树 |
| `:JavaInit` | 在推导出的 Java 包根目录生成最小 `pom.xml`，只作为 jdtls 项目根标记 |
| `:JavaRun` | 运行当前 Java 源文件；无 package 走 `java 文件.java`，有 package 走 `javac -sourcepath` 按需编译后运行 |

## 使用说明

- `:R` — 编辑完 `init.lua` 或 `plugins/xxx.lua` 等配置文件后，在该文件内执行即可生效，无需重启 Neovim
- `:A` — 先加载 alpha-nvim，再回到启动欢迎界面
- `:LspInfo` — 0.12 移除了内置 `:LspInfo`，手动恢复
- `:LspLog` — 0.12 移除了内置 `:LspLog`，手动恢复
- `:Projects` — 加载 project.nvim/telescope/neo-tree 后同步读取项目历史，避免启动页第一次打开项目列表为空；使用自定义 Telescope picker，回车只切换项目并打开/刷新 neo-tree，不再调用 `Telescope projects` 的默认嵌套 find_files 行为
- `:JavaInit` — 根据 `package` 声明和当前文件路径推导包根目录，在包根创建最小 `pom.xml`，让 jdtls 有项目根；不创建 `src/main/java/`，也不要求安装 Maven
- `:JavaRun` — 无 `package` 时直接在 Neovim 原生终端跑 `java 当前文件.java`；有 `package` 时推导包根，执行 `javac -d 临时目录 -sourcepath . 当前相对路径.java`，再用 `java -cp 临时目录 包名.类名` 运行，避免编译无关练习文件
