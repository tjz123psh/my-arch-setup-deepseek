# B 站视频弹窗播放

> 更新日期：2026-06-30  
> 当前脚本：`~/scripts/media/b23`  
> 命令入口：`~/.local/bin/b23`

## 用法

```bash
b23
b23 'https://b23.tv/...'
b23 'https://www.bilibili.com/video/BV...?p=2&t=60'
```

默认不传参数时，脚本会从 Wayland 剪贴板读取 B 站或 b23.tv 链接。传入 URL 时不需要 `wl-paste`。

Niri 快捷键在 `~/.config/niri/dms/keybinds.kdl`：

```kdl
Alt+B hotkey-overlay-title="B站播放" { spawn-sh "$HOME/.local/bin/b23"; }
```

`~/.local/bin/b23` 是命令入口，直接指向 `~/scripts/media/b23`。

## 当前行为

- 支持 `bilibili.com` 和 `b23.tv` 链接。
- 会清理常见跟踪参数，保留分 P、时间点等播放相关参数。
- 单视频直接交给 `mpv` 播放。
- 多 P / 合集会先用 `yt-dlp --flat-playlist` 探测条目，再生成临时 playlist 给 `mpv`。
- playlist 临时文件会在 `mpv` 退出后自动清理。

## 依赖

| 依赖 | 用途 |
| --- | --- |
| `mpv` | 播放器 |
| `yt-dlp` | 解析 B 站视频流 |
| `wl-clipboard` | 无参数时读取剪贴板 |
| `google-chrome` 或兼容浏览器 | `yt-dlp cookies-from-browser` 读取登录态 |

脚本默认使用：

```bash
B23_COOKIES_FROM_BROWSER=chrome
```

如果你换浏览器，可以临时指定：

```bash
B23_COOKIES_FROM_BROWSER=chromium b23 'https://www.bilibili.com/video/BV...'
```

## mpv 配置

脚本调用：

```text
mpv --profile=b23 --ytdl-raw-options=...
```

所以 B 站专用画质、缓存、窗口行为优先写在 `~/.config/mpv/mpv.conf` 的 `[b23]` profile 里。

## 常用播放快捷键

| 按键 | 功能 |
| --- | --- |
| `<` / `>` | 上一集 / 下一集 |
| `Space` | 暂停 / 播放 |
| `f` | 全屏 |
| `q` | 退出 |
| `Shift+I` | 显示视频信息 |

## 画质排查

如果网页能看 1080p，但 mpv 只有低清，优先确认浏览器登录态能被 `yt-dlp` 读取：

```bash
yt-dlp --cookies-from-browser chrome --impersonate Chrome-131 -F '视频链接'
```

如果这里失败：

1. 确认 Chrome/Chromium 已登录 B 站。
2. 关闭正在占用 cookie 数据库的浏览器进程后再试。
3. 换 `B23_COOKIES_FROM_BROWSER=chromium` 或实际使用的浏览器名。

如果 `yt-dlp -F` 能看到高画质，但 mpv 没选到，检查 `[b23]` profile 里的 `ytdl-format` 或脚本里的 `format` 规则。
