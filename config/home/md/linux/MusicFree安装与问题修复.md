# MusicFree 安装与问题修复（Arch + niri）

> 更新日期：2026-08-18
> 安装包：`~/Downloads/MusicFree-0.0.8-linux-amd64.deb`（约 80MB，Electron 应用）

## 背景

Arch Linux 没有 `dpkg`/`apt`，不能直接安装 `.deb`。MusicFree 是自包含的 Electron 应用（本体在 `/usr/lib/musicfree`），不依赖系统包管理，所以直接解压 deb 内容到系统目录即可，效果等同手动安装。

本机所有运行时依赖原本已装好（gtk3、libnotify、nss、libxtst、xdg-utils、at-spi2-core、libdrm、mesa、libxcb、gvfs），无需额外安装任何包。

## 安装步骤

```bash
cd /tmp && mkdir -p musicfree-deb && cd musicfree-deb
ar x ~/Downloads/MusicFree-0.0.8-linux-amd64.deb

# 查看依赖声明（Debian 包名）
bsdtar -xOf control.tar.zst ./control

# 解压安装到系统（gsudo 会弹 fuzzel 密码框）
~/scripts/desktop/gsudo -- sh -c 'cd /tmp/musicfree-deb && bsdtar -xpf data.tar.zst -C /'
```

### 安装内容

| 路径 | 内容 |
| --- | --- |
| `/usr/lib/musicfree/` | 应用本体（Electron 运行时 + 资源，约 270MB） |
| `/usr/bin/musicfree` | 软链 → `../lib/musicfree/MusicFree` |
| `/usr/share/applications/musicfree.desktop` | 应用菜单入口 |
| `/usr/share/pixmaps/musicfree.png` | 图标 |
| `/usr/share/doc/musicfree/copyright` | 版权信息 |

注意：`chrome-sandbox` 在归档中是 setuid root，以 root 解压会自动保留，Electron 沙箱可用。

### 依赖对照（Debian 名 → Arch 包名）

| Debian | Arch |
| --- | --- |
| libgtk-3-0 | gtk3 |
| libnotify4 | libnotify |
| libnss3 | nss |
| libxtst6 | libxtst |
| xdg-utils | xdg-utils |
| libatspi2.0-0 | at-spi2-core |
| libdrm2 | libdrm |
| libgbm1 | mesa |
| libxcb-dri3-0 | libxcb |
| kde-cli-tools \| ... \| gvfs-bin | gvfs（垃圾桶依赖） |

## 问题：niri 下窗口宽度不对（不是正常对半）

### 现象
- 配置 `default-column-width { proportion 0.5 }`，新窗口应占输出一半（1920/2 ≈ 954px）
- MusicFree 窗口却是 1050px，比同工作区其他窗口（954px）宽约 90px

### 原因
应用主进程写死了最小窗口尺寸，niri 平铺严格遵守该约束，无法缩到 954：

```js
// /usr/lib/musicfree/resources/app/.webpack/main/index.js
new BrowserWindow({ height: ...??700, width: ...??1050, minHeight: 700, minWidth: 1050, ... })
```

niri 没有"忽略某个应用最小尺寸"的配置项，所以只能在应用侧改。

## 修复：改小应用的最小尺寸

备份后替换两处字符串（在 bundle 中各出现一次），然后重启应用：

```bash
# 1. 备份
~/scripts/desktop/gsudo -- cp -a \
  /usr/lib/musicfree/resources/app/.webpack/main/index.js \
  /usr/lib/musicfree/resources/app/.webpack/main/index.js.bak

# 2. 替换最小尺寸（1050×700 → 800×500）
~/scripts/desktop/gsudo -- sed -i \
  's/minWidth:1050/minWidth:800/; s/minHeight:700/minHeight:500/' \
  /usr/lib/musicfree/resources/app/.webpack/main/index.js

# 3. 重启应用
kill $(pgrep -f '/usr/lib/musicfree/MusicFree$')   # 或 pkill -x MusicFree
setsid /usr/bin/musicfree &
```

验证（niri IPC）：

```bash
~/.grok/skills/niri-ipc/scripts/niri.py windows
# MusicFree 的 tile_size 应变为 [954, 1028]，与其他窗口一致
```

## 还原

```bash
~/scripts/desktop/gsudo -- cp \
  /usr/lib/musicfree/resources/app/.webpack/main/index.js.bak \
  /usr/lib/musicfree/resources/app/.webpack/main/index.js
# 或直接重装原始 deb（会覆盖为原版）
```

## 注意事项

- 应用更新（重装新版 deb）会覆盖修补，需要重新打一遍
- 本 deb 的 Linux 构建是 X11 版，运行在 xwayland-satellite 下

## X11 服务起不来的根治（2026-08-17）

### 现象
某次开机后 X11 应用（MusicFree 等）全部打不开，报 `Missing X server or $DISPLAY`；niri 日志出现：

```
niri::utils::xwayland::satellite: error opening X11 sockets,
disabling xwayland-satellite integration: wrong X11 directory permissions
```

### 原因
开机时序竞态：tmpfs `/tmp` 挂载与 tmpfiles 初始化几乎同时完成，登录屏 greeter 会话（`greeter` 用户）的 Xwayland 抢先创建了 `/tmp/.X11-unix`，归属为 `greeter:greeter`、权限 `1771`（其他用户不可写）。用户会话 niri 自带的 xwayland-satellite 集成检查目录归属时发现不对，直接禁用集成 → 所有 X11 应用无法连接 X 服务。

niri（≥25.5）自带 xwayland-satellite 集成，目录正常时它会自行启动 xwayland-satellite，无需手启。

### 根治方案
新增根级 oneshot 服务，开机在 greetd 之后持续校正目录，直到用户登录（`/run/user/1000` 出现）才结束，保证 niri 启动检查前目录一定是 `root:root 1777`：

```ini
# /etc/systemd/system/fix-x11-unix-dir.service
[Unit]
Description=Ensure /tmp/.X11-unix is root-owned mode 1777 for Xwayland
After=greetd.service systemd-tmpfiles-setup.service
Wants=systemd-tmpfiles-setup.service

[Service]
Type=oneshot
ExecStart=/bin/sh -ec 'fix(){ install -d -o root -g root -m 1777 /tmp/.X11-unix; }; fix; i=0; while [ $i -lt 60 ] && [ ! -d /run/user/1000 ]; do sleep 2; fix; i=$((i+1)); done; fix'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
```

```bash
gsudo install -o root -g root -m 0644 /tmp/fix-x11-unix-dir.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now fix-x11-unix-dir.service
```

### 临时应急（目录已被抢占时）
```bash
gsudo chmod 1777 /tmp/.X11-unix && gsudo chown root:root /tmp/.X11-unix
systemctl --user restart xwayland-satellite.service   # 或重登一次会话
```

### 还原
```bash
systemctl disable --now fix-x11-unix-dir.service
gsudo rm /etc/systemd/system/fix-x11-unix-dir.service
systemctl daemon-reload
```

## 问题：点「显示歌词在外部」报 Object has been destroyed（2026-08-18）

### 现象
- 重启后外部歌词窗口**自动弹出**；关闭后再点右下角「显示歌词在外部」，主进程弹错误对话框：
  `A JavaScript error occurred in the main process / Uncaught Exception: TypeError: Object has been destroyed`
- `~/.config/MusicFree/logs/main.log` 每次点击都记录：`设置配置失败 TypeError Object has been destroyed`

### 原因（应用代码 bug，与窗口位置无关）
`/usr/lib/musicfree/resources/app/.webpack/main/index.js` 的歌词窗口逻辑：

```js
showLyricWindow() { f.lrcWindow || this.createLyricWindow(), f.lrcWindow.show(), ... }
```

窗口被关闭后 `f.lrcWindow` 仍指向**已销毁的 BrowserWindow 对象**（未置空），再次点击按钮时 `f.lrcWindow.show()` 对已销毁对象调用 → 抛 `Object has been destroyed`。此外 `resize` 回调、配置更新回调也直接操作窗口对象，同样无销毁保护。

### 修复：给主进程 bundle 打补丁（4 处 isDestroyed 保护）

补丁脚本（先存为 `/tmp/patch_lrc.py`，各替换串在 bundle 中只出现一次）：

```python
path = '/usr/lib/musicfree/resources/app/.webpack/main/index.js'
data = open(path, encoding='utf-8').read()
patches = [
  ('showLyricWindow(){f.lrcWindow||this.createLyricWindow(),f.lrcWindow.show(),p.default.setConfig({"lyric.enableDesktopLyric":!0})}',
   'showLyricWindow(){f.lrcWindow&&f.lrcWindow.isDestroyed()&&(f.lrcWindow=null),f.lrcWindow||this.createLyricWindow(),f.lrcWindow.show(),p.default.setConfig({"lyric.enableDesktopLyric":!0})}'),
  ('closeLyricWindow(){f.lrcWindow?.close(),f.lrcWindow=null,p.default.setConfig({"lyric.enableDesktopLyric":!1})}',
   'closeLyricWindow(){f.lrcWindow&&!f.lrcWindow.isDestroyed()&&f.lrcWindow.close(),f.lrcWindow=null,p.default.setConfig({"lyric.enableDesktopLyric":!1})}'),
  ('o.on("resize",(()=>{const[e,t]=o.getSize(),n=Math.max(Math.min(Math.floor((i-60)/2),80),16);p.default.setConfig({"lyric.fontSize":n,"private.lyricWindowSize":{width:r,height:i}}),r=e,i=t}))',
   'o.on("resize",(()=>{if(o.isDestroyed())return;const[e,t]=o.getSize(),n=Math.max(Math.min(Math.floor((i-60)/2),80),16);p.default.setConfig({"lyric.fontSize":n,"private.lyricWindowSize":{width:r,height:i}}),r=e,i=t}))'),
  ('const l=(e,t,n)=>{"renderer"===n&&e["lyric.fontSize"]&&(i=this.evaluateWindowHeight(),o.setSize(r,i))}',
   'const l=(e,t,n)=>{"renderer"===n&&e["lyric.fontSize"]&&!o.isDestroyed()&&(i=this.evaluateWindowHeight(),o.setSize(r,i))}'),
]
for old, new in patches:
    assert data.count(old) == 1, f'匹配数异常: {old[:40]}'
    data = data.replace(old, new)
open(path, 'w', encoding='utf-8').write(data)
```

执行：

```bash
pkill -x MusicFree; sleep 3        # 1. 关闭应用
~/scripts/desktop/gsudo -- cp /usr/lib/musicfree/resources/app/.webpack/main/index.js{,.bak.lyr}   # 2. 备份
~/scripts/desktop/gsudo -- python3 /tmp/patch_lrc.py   # 3. 打补丁
setsid /usr/bin/musicfree &        # 4. 重启
```

| 补丁位置 | 修改 |
| --- | --- |
| `showLyricWindow` | 旧引用已销毁 → 先置 null 再重建 |
| `closeLyricWindow` | 已销毁的窗口不再 `close()` |
| `resize` 回调 | 开头 `if(o.isDestroyed())return` |
| 配置更新回调 | `setSize` 前加 `!o.isDestroyed()&&` |

> 注意：本机 MusicFree 已改为 deb 安装（本体 `/usr/lib/musicfree`），**启动必须用 `/usr/bin/musicfree`**（或应用菜单）。旧的便携副本 `~/Music/MusicFree/` 已废（resources 为空），用它的启动脚本会起不来。

> ✅ **已实测验证（2026-08-18）**：补丁后按复现路径（自动弹出 → 关闭 → 再点按钮）不再报错，外部歌词窗口正常。

### 还原

```bash
~/scripts/desktop/gsudo -- cp /usr/lib/musicfree/resources/app/.webpack/main/index.js.bak.lyr /usr/lib/musicfree/resources/app/.webpack/main/index.js
# 注意：之前窗口宽度修复的备份是 index.js.bak，本补丁备份是 index.js.bak.lyr，两者独立
```

### 备选：升级
MusicFreeDesktop 已有 v1.0.0-beta 系列（2026-03），可能已修；但大版本重写有插件兼容风险，升级前需确认当前插件（酷我系/GD音乐台/B站）可用。

## 备选：AUR 包

| 包名 | 说明 |
| --- | --- |
| `musicfree-desktop-wayland-bin` | 第三方 fork（txgde-space）的原生 Wayland 预构建，不经 XWayland；但同版本代码大概率仍带 1050 最小宽度限制，换后可能仍需修补 |
| `musicfree-desktop-bin` / `musicfree-desktop` | 预构建版，使用系统 electron |
| `musicfree` | 基础版 |
