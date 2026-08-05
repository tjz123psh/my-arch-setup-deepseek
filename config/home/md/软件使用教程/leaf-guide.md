# Leaf — 终端 Markdown 阅读器

Rust 编写的终端 Markdown 预览工具，GUI 般的体验。

## 安装

```bash
# Arch Linux (AUR)
paru -S leaf-markdown-viewer-bin

# 一键脚本
curl -fsSL https://leaf.rivolink.mg/install.sh | sh    # ⚠ 建议先下载审查脚本内容再执行

# npm
npm install -g @rivolink/leaf
```

## 使用说明

### 基本阅读

```bash
# 打开文件（TUI 交互模式）
leaf 文件.md

# 打开目录的文件选择器
leaf 目录/

# 只打开文件选择器，再选文件
leaf --picker

# 模糊搜索选择器（默认行为，不带参数时）
leaf
```

### 监听模式

```bash
# 文件变化时自动刷新
leaf -w 文件.md

# 选定文件后自动进入监听模式
leaf -w
leaf -w --picker
```

配合 AI 或笔记编辑特别有用：

```bash
# 终端1：编辑文件
nvim 文件.md

# 终端2：实时预览
leaf -w 文件.md
```

### 管道输入

```bash
# 从其他命令输出渲染
cat 文件.md | leaf
echo '# Hello' | leaf

# AI 输出预览
claude "解释 Rust 生命周期" | leaf
```

### 内联模式（输出到 stdout）

```bash
# 带颜色输出到终端
leaf --inline 文件.md

# 纯文本（无 ANSI）
leaf --inline plain 文件.md

# 指定宽度
leaf --inline 60 文件.md

# 配合 fzf 预览
fzf --preview 'leaf --inline ansi {}'
fzf --preview 'leaf --inline ansi:$FZF_PREVIEW_COLUMNS {}'
```

### 其他

```bash
# 指定主题
leaf --theme arctic 文件.md

# 指定外部编辑器
leaf -e nvim 文件.md

# 设置内容最大宽度
leaf --width 80 文件.md

# 以 `-` 开头的文件名
leaf -- -notes.md
```

## 快捷键

### 导航

| 按键 | 作用 |
|------|------|
| `j` / `↓` | 向下滚动一行 |
| `k` / `↑` | 向上滚动一行 |
| `d` / `PgDn` | 向下翻页（20 行） |
| `u` / `PgUp` | 向上翻页（20 行） |
| `g` / `Home` | 跳转到文件顶部 |
| `G` / `End` | 跳转到文件底部 |
| `Ctrl+L` | 跳转到指定行 |

### 搜索

| 按键 | 作用 |
|------|------|
| `/` / `Ctrl+F` | 搜索 |
| `n` | 下一个匹配 |
| `N` | 上一个匹配 |

### 视图操作

| 按键 | 作用 |
|------|------|
| `t` | 切换目录（TOC）侧边栏 |
| `Shift+L` | 切换行号显示 |
| `Shift+T` | 打开主题选择器 |
| `Shift+E` | 打开编辑器选择器 |
| `Shift+P` | 打开文件浏览器 |
| `Ctrl+P` | 打开模糊文件选择器 |
| `Ctrl+E` | 在编辑器中打开当前文件 |

### 其他

| 按键 | 作用 |
|------|------|
| `?` | 显示帮助弹窗 |
| `r` | 强制重新加载（监听模式） |
| `q` | 退出 |
| `Ctrl+Click` | 打开链接 |
| `双击` | 复制链接 |
| `Shift+选择` | 选中文本 |

## 配置

配置文件位置：`~/.config/leaf/config.toml`

用 leaf 编辑配置：

```bash
leaf --config         # 打开配置文件（不存在则创建默认配置）
leaf --config reset   # 重置为默认配置
```

### 完整配置项

```toml
# 颜色主题
# 内置主题：arctic, forest, ocean, solarized-dark
# 或指定自定义主题文件路径
theme = "ocean"

# 默认编辑器（Ctrl+E 打开）
editor = "nvim"

# 监听模式：文件变化时自动刷新
watch = false

# 内容最大宽度（0 = 终端宽度）
width = 80

# 文件选择器中额外显示的文件类型
extras = ["txt", "csv", "rs", "java", "json", "yaml"]
```

优先级：`命令行参数 > 环境变量 > 配置文件 > 默认值`

环境变量：`LEAF_THEME`、`LEAF_EDITOR`、`LEAF_WIDTH`

### 内置主题

| 主题 | 风格 |
|------|------|
| `ocean` | 深蓝海洋（默认） |
| `arctic` | 冷色调北极 |
| `forest` | 绿色森林 |
| `solarized-dark` | Solarized 暗色 |

### 自定义主题

创建 `.toml` 文件，继承内置主题并覆写颜色：

```toml
base = "ocean"
syntax = "base16-ocean.dark"

[ui]
content_bg = "#282828"
toc_accent = "#fe8019"

[markdown]
text = "#ebdbb2"
heading_1 = "#fabd2f"
```

用法：

```toml
theme = "/home/pang/.config/leaf/gruvbox.toml"
```

完整示例见 GitHub 上的 [`gruvbox.toml`](https://github.com/RivoLink/leaf/blob/main/gruvbox.toml)。

## Neovim 集成

在 `~/.config/nvim/init.lua` 或个人 Lua 配置中添加：

```lua
vim.keymap.set("n", "<leader>md", "<cmd>vertical botright terminal leaf -w %<cr>", {
  desc = "Leaf 预览当前 Markdown 文件",
})
```

之后按 `<leader>md` 打开实时预览。当前 Neovim 配置的 leader 是空格键，按 `<C-w>h` 切回 Markdown 缓冲区。

## Shell 补全

```bash
# 安装补全（支持 bash/zsh/fish/powershell）
leaf --auto-complete

# 导出补全脚本到文件
leaf --auto-complete bash:dump
leaf --auto-complete zsh:dump
leaf --auto-complete fish:dump

# 重启 shell 生效
```

## 更新

```bash
# 自动更新到最新版（自带 SHA256 校验）
leaf --update

# npm 安装的用 npm 更新
npm update -g @rivolink/leaf
```

## 卸载

```bash
# 脚本安装
rm -f ~/.local/bin/leaf

# npm 安装
npm uninstall -g @rivolink/leaf
```

## 常见场景

### 结合 Neovim 写笔记

```bash
# 终端1：编辑
nvim ~/notes/linux-notes.md

# 终端2：实时预览
leaf -w ~/notes/linux-notes.md
```

### fzf 快速预览

```bash
# 在当前目录搜索 md 文件并预览
find . -name '*.md' | fzf --preview 'leaf --inline ansi {}'

# 搜索所有代码文件并预览
find . -name '*.rs' | fzf --preview 'leaf --inline ansi {}'
```

### 阅读本机文档

```bash
leaf ~/md/vmware-144hz-guide.md
```

---

**项目地址**：<https://github.com/RivoLink/leaf>
