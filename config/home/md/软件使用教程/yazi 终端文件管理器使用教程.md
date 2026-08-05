# yazi 终端文件管理器使用教程

> 终端文件管理器 | Rust 编写 | 支持图片预览、代码高亮、多标签

---

## 快速启动

```bash
yazi           # 当前目录启动
yazi /path     # 指定目录启动
q              # 退出（自动 cd 到离开时的目录）
Q              # 退出（留在原地）
```

推荐 fish 封装（`~/.config/fish/config.fish`）：

```fish
function y
    set tmp (mktemp -t "yazi-cwd.XXXXXX")
    command yazi $argv --cwd-file="$tmp"
    set cwd (cat "$tmp")
    test "$cwd" != "$PWD"; and test -d "$cwd"; and cd "$cwd"
    command rm -f -- "$tmp"
end
```

bash/zsh 版：

```bash
function y() {
  local tmp="$(mktemp -t "yazi-cwd.XXXXXX")" cwd
  command yazi "$@" --cwd-file="$tmp"
  IFS= read -r -d '' cwd < "$tmp"
  [ "$cwd" != "$PWD" ] && [ -d "$cwd" ] && builtin cd -- "$cwd"
  command rm -f -- "$tmp"
}
```

之后用 `y` 代替 `yazi`，退出自动进入最后浏览的目录。

---

## 常用按键

### 导航

| 按键 | 功能 |
|---|---|
| `j` / `k` | 上下移动 |
| `h` / `l` | 返回上级 / 进入目录 |
| `gg` / `G` | 跳到顶部 / 底部 |
| `K` / `J` | 预览区上下滚动 |
| `z` | fzf 模糊跳转目录 |
| `Z` | zoxide 历史目录跳转 |

### 文件操作

| 按键 | 功能 |
|---|---|
| `Enter` / `o` | 打开文件 |
| `O` | 交互式打开（选应用） |
| `Space` | 切换选中 |
| `v` / `V` | 进入/退出可视模式 |
| `y` / `x` | 复制 / 剪切 |
| `p` / `P` | 粘贴 / 强制覆盖粘贴 |
| `d` / `D` | 移到回收站 / 永久删除 |
| `a` | 新建文件（末尾加 `/` 建目录） |
| `r` | 重命名（多选则批量重命名） |
| `.` | 切换隐藏文件 |
| `Tab` | 查看文件详情 |

### 复制路径

| 按键 | 功能 |
|---|---|
| `cc` | 复制文件路径 |
| `cd` | 复制目录路径 |
| `cf` | 复制文件名 |
| `cn` | 复制无扩展名文件名 |

### 搜索

| 按键 | 功能 |
|---|---|
| `f` | 实时过滤文件名 |
| `/` / `?` | 向下/向上查找文件 |
| `n` / `N` | 下一个 / 上一个匹配 |
| `s` | fd 递归搜索文件名 |
| `S` | ripgrep 搜索文件内容 |

### 多标签

| 按键 | 功能 |
|---|---|
| `tt` | 新建标签页 |
| `1~9` | 切换到第 N 个标签 |
| `[` / `]` | 上一个 / 下一个标签 |
| `Ctrl+c` | 关闭当前标签页 |

### 排序

| 按键 | 功能 |
|---|---|
| `,m` / `,M` | 按修改时间 / 反向 |
| `,e` / `,E` | 按扩展名 / 反向 |
| `,a` / `,A` | 按字母序 / 反向 |
| `,n` / `,N` | 按自然序 / 反向 |
| `,s` / `,S` | 按大小 / 反向 |

### 执行命令

| 按键 | 功能 |
|---|---|
| `;` | 运行 shell 命令（非阻塞） |
| `:` | 运行 shell 命令（阻塞，进入子 shell） |

### 帮助

| 按键 | 功能 |
|---|---|
| `~` / `F1` | 内置帮助浏览器 |

---

## 配置文件

位置：`~/.config/yazi/`

| 文件 | 用途 |
|---|---|
| `yazi.toml` | 通用配置（布局、排序、预览等） |
| `keymap.toml` | 按键自定义 |
| `theme.toml` | 主题 / 配色 |

### 常用配置

```toml
# ~/.config/yazi/yazi.toml
[mgr]
ratio = [1, 4, 3]       # 面板比例：父/当前/预览
sort_by = "natural"      # 排序：none / mtime / extension / alphabetical / size ...
sort_dir_first = true    # 目录排前面
show_hidden = false      # 默认不显示隐藏文件

[preview]
wrap = "no"              # 代码预览不换行
tab_size = 4
max_width = 600
max_height = 600
image_filter = "lanczos3"
image_quality = 75
```

### 文件打开规则

```toml
[opener]
edit = [{ run = "nvim %s", block = true }]
play = [{ run = "mpv %s", orphan = true }]

[open]
prepend_rules = [
  { mime = "text/*", use = "edit" },
  { mime = "video/*", use = "play" },
  { mime = "image/*", use = "play" },
]
```

---

## 图片预览

Kitty 终端下自动启用（Kitty unicode placeholders 协议），无需额外配置。

其他终端：

| 终端 | 方案 |
|---|---|
| foot / Konsole | Sixel（内置） |
| 所有 X11/Wayland 终端 | 安装 Überzug++ |
| 兜底 | Chafa（ASCII 艺术图） |

查看当前预览协议：`yazi --debug` → `Adapter.matches`

### 预览额外依赖

| 文件类型 | 所需工具 | 安装 |
|---|---|---|
| 视频缩略图 | `ffmpegthumbnailer` | `pacman -S ffmpegthumbnailer` |
| PDF | `pdftoppm` | `pacman -S poppler` |
| SVG | `resvg` | `pacman -S resvg` |
| 压缩包 | `7zip` / `unarchiver` | 已有 |

---

## 外部工具集成

| 工具 | 触发 | 用途 |
|---|---|---|
| **fd** | `s` | 按文件名递归搜索 |
| **ripgrep** | `S` | 按文件内容全文搜索 |
| **fzf** | `z` | 模糊匹配跳转目录/文件 |
| **zoxide** | `Z` | 基于历史频率跳转目录 |

---

## 实用技巧

- **批量重命名**：`Space` 多选 → `r` → 编辑器中改文件名 → 保存
- **文件选择器模式**：`yazi --chooser-file=/tmp/out`，选文件后输出路径并退出
- **多选复制/移动**：`Space` 标记 → `y` 或 `x` → 到目标目录 → `p`
- **批量创建文件/目录**：`a file1.txt` → `a dir/` → `a file2.txt`
