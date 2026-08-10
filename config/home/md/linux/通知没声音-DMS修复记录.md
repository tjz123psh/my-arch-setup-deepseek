# 通知没声音：为什么、怎么解决的

> 日期：2026-08-09  
> 现象：桌面通知能正常弹出，但**没有任何声音**。  
> 结果：已修复，通知音恢复（原版自带音色）。  
> 环境：Arch Linux + niri（Wayland）+ quickshell DMS（`dms-shell` 1.5.3）+ kitty 0.48.2。

## 背景

一开始以为是 kitty 的通知配置问题。查证后结论：**通知是 DMS（quickshell DankMaterialShell）显示的桌面通知，跟 kitty 无关**——kitty 的 `notify_on_cmd_finish` 默认 `never`，没启用，kitty 根本不发通知。

通知链路：

```
应用 → org.freedesktop.Notifications（dbus）
     → quickshell DMS 的 NotificationService
     → 弹窗 + AudioService 播放声音（QMediaPlayer + AudioOutput → QtMultimedia → ffmpeg 后端）
```

“没声音”其实是**三个问题叠加**，逐个拆掉才恢复。

## 根因 1：系统缺 `qt6-multimedia`，声音链路整个是断的

- DMS 播通知音走 Qt 的 `QMediaPlayer`，依赖 Qt Multimedia 模块。
- 检查发现 `/usr/lib/qt6/qml/QtMultimedia` 不存在——**`qt6-multimedia` 没装**。
- `quickshell` 和 `dms-shell` 的依赖列表里都没有它，所以装了外壳也不会自动带。
- 后果：`AudioService.soundsAvailable = MultimediaService.available = false`，声音加载器不激活，**任何情况下都播不出声音**。

```bash
# 解决：安装 Qt Multimedia（6.11.1-2，含 FFmpeg 后端）
sudo pacman -S qt6-multimedia qt6-multimedia-ffmpeg
```

> 注意：当时镜像对 `qt6-multimedia 6.11.1-1` 全部 404，是本地同步数据库过期。先 `sudo pacman -Sy` 刷新，版本变成 `6.11.1-2` 后正常安装。

## 根因 2：ffmpeg 8 太旧，ffmpeg 后端插件加载失败

装完重启 DMS 后日志报：

```
WARN: No QtMultimedia backends found. Only QMediaDevices, QAudioDevice, QSoundEffect ... available.
WARN: Failed to initialize QMediaPlayer "Not available"
```

`ldd /usr/lib/qt6/plugins/multimedia/libffmpegmediaplugin.so`：

```
libavformat.so.63 => not found
libavcodec.so.63  => not found
```

系统 ffmpeg 是 **8.1.2**（只到 `libavcodec.so.62`），而后端插件要 **ffmpeg 9** 的库（`.so.63`）——**版本不匹配，插件直接加载失败**，`QMediaPlayer` 不可用（`QSoundEffect` 反而能用，但 DMS 用的是 `MediaPlayer`）。

```bash
# 解决：升级 ffmpeg 到 9（连带一批依赖它的媒体包：mpv/opencv/gstreamer 等）
sudo pacman -Syu
```

升级后日志变为：

```
INFO qt.multimedia.ffmpeg: Using Qt multimedia with FFmpeg version n9.0 GPL version 3 or later
```

## 根因 3：`muteSoundsWhenMediaPlaying` + 媒体在播 = 主动静音

后端好了，但发通知**还是没声音**。用调试副本打点（把 DMS 复制到 `/tmp`，在 `AudioService.playNormalNotificationSound` 加日志）抓到：

```
DBG PLAY NORMAL: avail= true playerNull= false dnd= false muted= false muteForMedia= true
```

**`muteForMedia=true`**，`play()` 根本没被调用。链路：

- `shouldMuteForMedia() = SettingsData.muteSoundsWhenMediaPlaying && isMediaPlaying()`
- `isMediaPlaying() = MprisController.activePlayer?.isPlaying ?? false`
- 当时 Chrome 正在放 LPL 直播（MPRIS `PlaybackStatus = "Playing"`，`wpctl` 可见活跃输出流）
- 设置 `muteSoundsWhenMediaPlaying: true`（“媒体播放时静音”防打扰功能）→ 通知音被刻意静音

```bash
# 解决：设置改为 false（通知音任何时候都响，即使在看直播）
# ~/.config/DankMaterialShell/settings.json
"muteSoundsWhenMediaPlaying": false
```

改完重启 `dms.service`，发通知时用 `wpctl` 对比抓到新音频流（节点 70/73/74）——**声音恢复**。

## 验证方法（可复用）

| 手段 | 用途 |
|---|---|
| `dbus-send ... org.freedesktop.DBus.GetNameOwner string:org.freedesktop.Notifications` + `GetConnectionUnixProcessID` | 查通知服务归谁（确认是 quickshell 不是 kitty） |
| `wpctl status` 前后 diff（Streams 段节点 id） | 抓通知瞬间是否出现新音频流 |
| `pactl subscribe` | 监听 pulse 兼容层的流事件 |
| `ldd <插件.so> \| grep 'not found'` | 查后端插件缺库 |
| 独立 `qs -p test.qml` 跑一个最小 MediaPlayer | 证明 QtMultimedia 本身能播（排除 DMS 之外的问题） |
| 复制 DMS 到 /tmp 打点日志 | 定位 `play()` 被哪个守卫条件拦截 |

## 声音选项（DMS 设置 → 声音）

- **启用系统声音**：总开关。
- **使用系统主题**：开 = 用系统声音主题（`/usr/share/sounds/`）；关 = 用 DMS 自带音色（当前）。
- **声音主题下拉**：只列出**已安装**的主题（`/usr/share/sounds/*/stereo`）。装更多主题包（`ocean-sound-theme`、`pop-sound-theme` 等）才有更多选项；主题要含 DMS 需要的事件文件（普通 = `dialog-information`/`message`，紧急 = `dialog-warning`/`message-new-instant`），否则回退到 freedesktop 或自带音色。
- **新通知 / 音量变化 / 连接电源 / 登录**：各事件开关。
- **媒体播放时静音**：媒体（MPRIS Playing）播放时消除系统声音。
- **自定义音色**：直接替换 `/usr/share/quickshell/dms/assets/sounds/freedesktop/` 下的 `message.wav`（普通）、`message-new-instant.wav`（紧急）。注意该目录属包管理，升级 `dms-shell` 会被覆盖。
- 通知音量无独立滑块，跟随系统输出音量。

## 最终状态

- 通知音 = DMS 原版自带音色（`useSystemSoundTheme: false`）
- `soundNewNotification: true`、`muteSoundsWhenMediaPlaying: false`
- 临时试装的 `ocean-sound-theme` 已删除，gsettings 主题名重置回 `freedesktop`
- kitty 未做任何改动
