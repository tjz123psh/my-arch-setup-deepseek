# fuzzel 美化与动态配色

> 更新日期：2026-07-27
> 配置目录：`~/.config/fuzzel/`、`~/.config/matugen/`
> 作用范围：所有 fuzzel dmenu 调用方（`~/.config/hypr/conf/keybinds.lua` 的 `menu='fuzzel'`、`~/scripts/desktop/{gsudo,fuzzel-askpass,quickload,wf-recorder-menu}`）

## 目标

让 fuzzel 有精致的静态结构（圆角、内边距、放大镜提示符、图标），配色随 DMS(DankMaterialShell) 的 matugen 动态主题自动变（跟随壁纸/主题色），与系统其它 matugen 应用（kitty/niri/hypr 等）保持一致。

## 文件结构（结构与配色拆分）

fuzzel 的 `include` 文件有独立 section 作用域，且 matugen 会覆盖整份输出文件，因此**静态结构和动态配色必须拆成两个文件**，否则每次重算主题会把结构冲掉。

| 文件 | 作用 | 谁维护 |
|------|------|--------|
| `~/.config/fuzzel/fuzzel.ini` | 静态结构（字体、圆角、边框、内边距、行高、图标、提示符），末行 `include=.../colors.ini` | 手动 |
| `~/.config/fuzzel/colors.ini` | `[colors]` 配色段，首行必须是 `[colors]` header | matugen 生成 |
| `~/.config/matugen/dms/configs/fuzzel.toml` | DMS plugin-dir 配置片段，声明 fuzzel 模板 | 手动 |
| `~/.config/matugen/templates/fuzzel.ini` | matugen 模板，`{{colors.ROLE.default.hex_stripped}}ff` | 手动 |

### fuzzel.ini 关键点

- `include` 指令必须放在 main/default 段（任何 `[section]` header 之前）。
- 提示符 `prompt` 用了 Nerd Font 放大镜 glyph（U+F002）+ 空格。**edit/write 工具会吞掉该 glyph，必须用 `bash printf` 直接写字节**（`\uf002` → `ef 80 82`）。
- 颜色格式是 `RRGGBBAA`（8 位十六进制，无 `#` 前缀）。
- `fuzzel --check-config` 应返回 EXIT 0。

### colors.ini 角色映射（模板）

| fuzzel 键 | Material 角色 |
|-----------|---------------|
| background | surface（+ `f2` 半透明） |
| text / input | on_surface |
| prompt / match / selection-match / border | primary |
| placeholder / counter | on_surface_variant |
| selection | secondary_container |
| selection-text | on_secondary_container |

### 共享 fuzzel.ini 的调用方需按需覆盖占位符/高度（踩坑）

`fuzzel.ini` 里的 `placeholder=搜索…` 和 `lines=8` 是为**应用启动器**设的。其它 dmenu 调用方复用同一份 ini 时，这两项会串味：

- **`fuzzel-askpass`（sudo 密码框）**：空输入时会显示「搜索…」占位符，语义完全不符。修复：调用加 `--placeholder=''` 覆盖（提示语已由 `--prompt-only="$PROMPT"` 给出）。
- **`wf-recorder-menu`（录制短菜单）**：prompt 后拼上全局「搜索…」糊成一行，且为 8 行列表预留固定高度、短列表下方留大片空白。修复：调用加 `--placeholder='' --minimal-lines`。

原则：**只在命令行层面按调用方语义覆盖，不动全局 `fuzzel.ini`**，避免影响应用启动器。fuzzel 1.14+ 支持 `--placeholder=TEXT`、`--minimal-lines`（dmenu 高度收到实际项数）、`--prompt-only`（隐含 `--lines=0`）。

## DMS matugen 接入机制（关键踩坑）

DMS 在每次重算主题时构造一份临时 merged matugen config 再跑标准 matugen。有两条用户接入路径：

1. **`~/.config/matugen/config.toml`（不要用）**：DMS 用朴素字符串查找（`extractTOMLSection`）从中提取 `[config]` 和 `[templates]` 段。**v1.5.2 对 `[templates.fuzzel]` 这种带子表名的 header 提取有 bug，捕获不到，模板会丢失。**
2. **`~/.config/matugen/dms/configs/*.toml`（采用这个）**：每个 `.toml` 文件**逐字写入** merged config，无 marker 提取，可靠。

### 为什么删掉了 config.toml

DMS 在正式生成前会先跑一个**版本探测** `matugen color hex … --dry-run`，此调用**不带 `-c`**，matugen 会自动加载 `~/.config/matugen/config.toml`。若该文件只有 `[config]` 没有 `[templates]`，matugen v4 会报 `missing field templates` 使整个 generate 失败。**所以直接删除 config.toml，fuzzel 模板完全靠 plugin-dir（`dms/configs/`）提供。**

## 手动触发重算（测试用）

```bash
dms matugen generate \
  --config-dir /home/pang/.config \
  --state-dir /home/pang/.local/state/DankMaterialShell \
  --shell-dir /usr/share/quickshell/dms \
  --kind hex --value '#80d4d7' --mode dark --run-user-templates
```

- 用 `--kind hex` 避开壁纸无效 PNG 的问题。
- 日志出现 `No color changes detected, skipping refresh`（EXIT 2）属正常，文件仍会生成。
- 正常使用时无需手动跑：改壁纸或切主题时 DMS 自动重算。

## 验证

- `fuzzel --check-config` → EXIT 0。
- 先写 sentinel 到 colors.ini，跑一次重算，确认被真实配色覆盖 = plugin-dir 机制生效。
- 真实启动 `printf '项1\n项2' | fuzzel --dmenu` + grim 截图确认样式与当前桌面主色一致。

## 教训

- 查 DMS 行为读 GitHub master 源码（`core/internal/matugen/matugen.go`）或针对性 grep，**不要裸 `strings /usr/bin/dms` 或全量 strace**（Go 二进制符号噪声巨大）。
- edit/write 工具会吞掉 Nerd Font glyph，需 `bash printf` 直写字节。
