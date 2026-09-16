# QQ/微信 Linux 剪贴板问题快速修复（Niri/Wayland，重装可用）

> 适用：Arch Linux + Niri(Wayland)，QQ（linuxqq-appimage）与微信（wechat-appimage），两者都是 Electron。
> 本文是"重装后由 AI/人工快速恢复"的完整步骤，含全部文件全文与验证命令。
> 编码与时间：2026-09-01 实测（QQ 3.2.32-52194 / 微信 4.1.1 / niri 26.04 / xwayland-satellite 5.x）。
> ✅ 2026-09-01 已在目标机完整实测通过：QQ/微信 文字粘贴、截图粘贴均正常；镜像守护为 v2 轮询版。
> 🔧 2026-09-10 复发修复（v3）：解决"服务 active 但从不镜像"——systemd 启动顺序竞态使服务进程缺
> DISPLAY/WAYLAND_DISPLAY（根因 4），脚本已自举环境；并增加"X11 owner 消失自动重建"自愈。

## 现象
- 复制文字或截图后，在 QQ/微信里粘贴无效、或"粘贴出之前的内容/旧文字"，重启客户端暂时恢复。
- 截图后粘贴，出来的是上次复制的文字而不是图片。
- 文字能粘贴但图片不行（典型：截图→粘贴→旧文字）。
- 系统重启后偶发：服务 active、脚本没改过，但复制后 X11 应用粘贴出旧内容或粘不出来。
  这是 bridge 服务启动早于 niri 导入环境变量所致（见根因 4），v3 已自愈。

## 根因（四层，缺一都修不干净）
1. **腾讯 NT 框架 Electron 客户端在原生 Wayland 下剪贴板集成有缺陷**（粘贴偶发失效、重启恢复）。
   解决：强制走 X11/XWayland（桌面文件加 `ELECTRON_OZONE_PLATFORM_HINT=x11`）。
2. **XWayland 剪贴板桥接不可靠**：xwayland-satellite 虽在运行，但 X11 剪贴板被其他客户端
   （典型：dms 剪贴板组件拉起的 `xclip -selection clipboard`）抢走所有权后，satellite 不再应答，
   X11 应用（QQ/微信）只能读到抢权者手里的旧内容、或读不到。
   解决：常驻镜像守护（wl-paste --watch → xclip 按 MIME 占位 X11 剪贴板），不依赖 satellite 状态。
3. **niri 内置截图动作只保存文件、不写入剪贴板**（`screenshot`/`screenshot-window`/`screenshot-screen`）。
   解决：截图键改为包装脚本：niri 动作存临时文件 → `wl-copy --type image/png`。
4. **clipboard-x11-bridge 服务进程缺 DISPLAY/WAYLAND_DISPLAY**（2026-09-10 复发根因）：
   systemd 用户服务启动瞬间继承当时 user manager 的环境；若 niri 会话还没把环境变量 import 进来
   （启动顺序竞态，实测 niri 与服务同秒启动），wl-paste/xclip 在服务内全部静默失败 →
   服务显示 active 却从不写 X11 剪贴板。v3 脚本开头自举环境（从 `systemctl --user show-environment`
   获取并等待），缺变量时不再静默空转。
   坑：systemd 261 的 `show-environment` 不接受变量名参数（报 `Too many arguments`），必须全量输出后过滤。

> 排除项：系统剪贴板本身正常（wl-paste 可读）；qq/wechat 的缓存与剪贴板无关，清缓存无用。

## 依赖
```bash
sudo pacman -S wl-clipboard xclip xwayland-satellite niri
```

## 修复步骤（按顺序）

### 1. QQ/微信强制 X11 模式（用户级桌面文件覆盖，包更新不覆盖）

`~/.local/share/applications/linuxqq.desktop`：
```ini
[Desktop Entry]
Name=QQ
Exec=env DESKTOPINTEGRATION=false ELECTRON_OZONE_PLATFORM_HINT=x11 /usr/bin/linuxqq --no-sandbox %U
Terminal=false
Type=Application
Icon=/usr/share/icons/linuxqq.png
StartupWMClass=QQ
X-AppImage-Version=52194
Categories=Network;
Comment=QQ
```

`~/.local/share/applications/wechat.desktop`：
```ini
[Desktop Entry]
Categories=Utility;
Comment=Wechat Desktop
Comment[zh_CN]=微信桌面版
Exec=env DESKTOPINTEGRATION=false ELECTRON_OZONE_PLATFORM_HINT=x11 /usr/bin/wechat %U
Icon=/usr/share/icons/wechat.png
Name=wechat
Name[zh_CN]=微信
StartupNotify=true
Terminal=false
Type=Application
X-AppImage-Version=4.1.1
```

```bash
update-desktop-database ~/.local/share/applications
# 杀掉旧实例后从菜单重新启动，验证窗口为 X11：xprop -root _NET_ACTIVE_WINDOW 后查 WM_CLASS
```
（旧版方案 `--ozone-platform=x11 --disable-gpu --in-process-gpu` 见 `linuxqq-wayland-fix.md`，那是"无窗口"问题的历史记录，本问题用环境变量即可。）

### 2. X11 剪贴板镜像守护（核心兜底，satellite 是否工作都有效）

脚本 `/home/pang/scripts/desktop/clipboard-x11-bridge`：
```bash
#!/bin/bash
# clipboard-x11-bridge — 把 Wayland 剪贴板镜像到 X11 侧（QQ/微信等 X11 应用粘贴用）。
# v2（轮询版）：wl-paste --watch 版本实测会静默失效 + 与 satellite 的镜像回环互相干扰，
# 改为 300ms 轮询 + 内容指纹(cksum)去重：自身写入被 satellite 回显时指纹相同，跳过，不会自循环；
# 空内容不占位（防止写空 xclip 抢走所有权毒化剪贴板）。
# v3：1) 自举 DISPLAY/WAYLAND_DISPLAY。本服务可能先于 niri 导入环境变量启动，缺变量时
#        wl-paste/xclip 会全部静默失败，服务显示 active 却从不镜像（2026-09-10 实测复现）。
#        systemd 261 的 show-environment 不接受变量名参数（Too many arguments），只能全量过滤。
#     2) 指纹未变时若 X11 侧已无人持有（owner 被杀/消失），自动重建，不必等下一条复制。
#        只判有无 owner、不比对内容：X11 应用（QQ 等）自己复制的内容也可能与 Wayland 不同，不能覆盖。
set -uo pipefail

while :; do
    env_out=$(systemctl --user show-environment 2>/dev/null)
    [ -z "${DISPLAY:-}" ] && export DISPLAY=$(printf '%s\n' "$env_out" | sed -n 's/^DISPLAY=//p')
    [ -z "${WAYLAND_DISPLAY:-}" ] && export WAYLAND_DISPLAY=$(printf '%s\n' "$env_out" | sed -n 's/^WAYLAND_DISPLAY=//p')
    [ -n "${DISPLAY:-}" ] && [ -n "${WAYLAND_DISPLAY:-}" ] && break
    sleep 1
done

last=""

while true; do
    mimes=$(wl-paste -l 2>/dev/null)

    if [ -n "$mimes" ]; then
        if printf '%s' "$mimes" | grep -q 'image/'; then
            mime=$(printf '%s' "$mimes" | grep -oE 'image/[a-z0-9.+-]+' | head -1)
            target="$mime"
        else
            if printf '%s' "$mimes" | grep -q 'text/plain;charset=utf-8'; then
                mime="text/plain;charset=utf-8"
            elif printf '%s' "$mimes" | grep -q 'text/plain'; then
                mime="text/plain"
            else
                mime=$(printf '%s' "$mimes" | grep -oE 'UTF8_STRING|STRING|TEXT' | head -1)
            fi
            target="UTF8_STRING"
        fi

        if [ -n "$mime" ] && [ -n "$target" ]; then
            h=$(wl-paste --type "$mime" 2>/dev/null | cksum)
            size=$(printf '%s' "$h" | awk '{print $2}')
            if [ "${size:-0}" -gt 0 ]; then
                stale=0
                if [ "$h" != "$last" ]; then
                    stale=1
                elif ! xclip -selection clipboard -t TARGETS -o >/dev/null 2>&1; then
                    stale=1
                fi
                if [ "$stale" = 1 ]; then
                    last="$h"
                    wl-paste --type "$mime" 2>/dev/null | xclip -selection clipboard -t "$target" -i >/dev/null 2>&1 &
                fi
            fi
        fi
    fi
    sleep 0.3
done
```

用户服务 `~/.config/systemd/user/clipboard-x11-bridge.service`：
```ini
[Unit]
Description=Clipboard X11 bridge (mirror Wayland clipboard to X11 for X11 apps)
After=graphical-session.target

[Service]
Type=simple
ExecStart=/home/pang/scripts/desktop/clipboard-x11-bridge
Restart=on-failure

[Install]
WantedBy=default.target
```

```bash
chmod +x ~/scripts/desktop/clipboard-x11-bridge
systemctl --user daemon-reload
systemctl --user enable --now clipboard-x11-bridge
```

### 3. 截图同时写入剪贴板（niri 内置截图默认只存文件）

脚本 `/home/pang/scripts/desktop/screenshot-clipboard`：
```bash
#!/bin/bash
# 截图并复制到剪贴板（niri 内置截图动作只保存文件，不写剪贴板）
# 用法：screenshot-clipboard [window|screen]
set -uo pipefail

case "${1:-}" in
    window) ACTION="screenshot-window" ;;
    screen) ACTION="screenshot-screen" ;;
    *)      ACTION="screenshot" ;;
esac

OUT="/tmp/qq-screenshot-$(date +%s).png"

niri msg action "$ACTION" --path "$OUT" >/dev/null 2>&1
for _ in $(seq 1 50); do
    [ -f "$OUT" ] && break
    sleep 0.1
done

if [ -f "$OUT" ] && [ -s "$OUT" ]; then
    wl-copy --type image/png < "$OUT"
    rm -f "$OUT"
else
    notify-send "screenshot-clipboard" "截图失败：未生成文件" 2>/dev/null
    exit 1
fi
```

`~/.config/niri/dms/keybinds.kdl` 中截图键改为（保留 screenshot-sound arm）：
```kdl
Print        { spawn-sh "/home/pang/scripts/desktop/screenshot-sound arm; /home/pang/scripts/desktop/screenshot-clipboard"; }
Ctrl+Print   { spawn-sh "/home/pang/scripts/desktop/screenshot-sound arm; /home/pang/scripts/desktop/screenshot-clipboard screen"; }
Alt+Print    { spawn-sh "/home/pang/scripts/desktop/screenshot-sound arm; /home/pang/scripts/desktop/screenshot-clipboard window"; }
```
```bash
niri msg action load-config-file
```

## 验证清单（可直接交给 AI 执行）

1. 文字桥接：
   ```bash
   printf 'TEST' | wl-copy; sleep 1; xclip -selection clipboard -t UTF8_STRING -o   # 应输出 TEST
   ```
2. 图片桥接（X11 侧目标可见）：
   ```bash
   wl-copy --type image/png < 任意png文件; sleep 1; xclip -selection clipboard -t TARGETS -o   # 应含 image/png
   ```
3. 截图写剪贴板：按 Print 后 `wl-paste -l` 应出现 `image/png`。
4. 应用内：QQ/微信聊天框 Ctrl+V 能贴出刚截的图、刚复制的文字。
5. satellite 状态判定（**坑**：`pgrep -x xwayland-satellite` 匹配不到，进程名被截断为 15 字符）：
   ```bash
   ps -eo pid,comm,args | grep xwayland        # 看到 xwayland-satellite 说明活着
   ```
5b. bridge 服务环境自检（**复发时最先查这一条**，服务可能"active 但从不镜像"）：
   ```bash
   pid=$(systemctl --user show -p MainPID --value clipboard-x11-bridge)
   tr '\0' '\n' < /proc/$pid/environ | grep -E '^(DISPLAY|WAYLAND_DISPLAY)='   # 两条都应输出
   ```
   缺输出 = 启动竞态（服务早于 niri 导入环境变量），v3 脚本已自举，重启服务即恢复：
   ```bash
   systemctl --user restart clipboard-x11-bridge
   ```
6. 残留 xclip 排查（dms 剪贴板组件可能拉一个钉死旧内容的 xclip 抢走所有权）：
   ```bash
   pgrep -a xclip      # 出现【不带参数启动】的 xclip -selection clipboard 即可疑，杀掉：pkill -x xclip
   ```
   v3 之后影响减弱：Wayland 侧内容一变 bridge 就会重写并夺回所有权。
7. "文字突然什么也粘贴不了"自查（v1 watcher 版会静默失效，v2 轮询版已规避，v3 增加 owner 消失自愈）：
   ```bash
   systemctl --user is-active clipboard-x11-bridge     # 应为 active
   printf 't' | wl-copy; sleep 1; xclip -selection clipboard -t UTF8_STRING -o   # 应输出 t
   ```
   读不到就先 `pkill -x xclip` 清一次再复制。轮询版每 300ms 同步，正常时 xclip 持有者应只有 1 个。
   v3 自愈验证：`pkill -x xclip` 后 1~2 秒内 `pgrep -x xclip` 应有新进程、内容自动重建，无需手动复制。

## 回退
- 删掉 `~/.local/share/applications/{linuxqq,wechat}.desktop` 恢复原生启动。
- `systemctl --user disable --now clipboard-x11-bridge`，删除脚本与服务文件。
- keybinds 里还原为 `niri msg action screenshot*`。

## 相关记录
- QQ 无窗口问题（GPU/X11 连接占满）：`linuxqq-wayland-fix.md`
- 截图快门音效/上膛机制：`/home/pang/scripts/desktop/screenshot-sound`（配合本方案，截图写剪贴板后音效正常触发）