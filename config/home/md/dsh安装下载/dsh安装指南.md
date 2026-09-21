# DeepSeek Harness (dsh) 安装指南

> 本文档基于 2026-08 在本机（Arch Linux / Niri / fish shell）实际安装过程整理。
> 适用版本：**安装前先查标签，别凭记忆**。`npm view @deepseek-ai/dsh dist-tags --json` 当前（2026-09-10）为 `latest` = `next` = **0.1.5-rc.1**、`alpha` = 0.1.5-alpha.2。历史上 `latest` 曾长期停在旧格式的 0.1.1-rc.2（与 0.1.2+ 会话格式不互通，本机 2026-08 因此炸过整条历史），所以**务必显式写版本号**；另注意 `npm view` 可能返回本地缓存里的幽灵标签（曾显示存在 `0.1.3-alpha.1`，实际 registry 无此版本、显式取版本 404），关键判断用 `curl -s https://registry.npmjs.org/@deepseek-ai%2Fdsh` 绕缓存复核。快速迭代中，升级前先看下文"七、升级"。
> 2026-08-23 实测更新：升级/重装全流程见"七、升级"，含运行中升级卡死教训与代理环境 node-gyp 编译坑。

---

## 一、dsh 是什么

DeepSeek Harness（`dsh`）是 DeepSeek AI 开发的开源 agent harness（智能体框架），采用**一切皆插件**架构，由 Cordis 驱动。

- 官方仓库：https://github.com/deepseek-ai/deepseek-harness
- 架构论文：https://github.com/cordiverse/paper
- 当前状态：**开发者预览版**，官方声明会有破坏性兼容变更

## 二、环境要求

| 组件 | 最低 | 本机实测 |
|---|---|---|
| Node.js | >= 18 | v26.7.0 |
| npm | 较新版本（安装脚本策略相关） | 12.0.2 |
| pnpm | 源码构建 / `dsh plugin` 命令需要 | npm 最新版（本机为独立版布局 `~/.local/share/pnpm`，入口链到 `~/.local/bin/pnpm`，可 `pnpm self-update` 自升级） |
| 编译工具链 | 仅安装脚本放行时需要 | gcc 16 / make / python3 |

- `npx` 方式运行不需要额外工具
- 源码构建需要 `pnpm`

## 三、安装方式（三选一）

### 方式 A：npx 直接运行（不安装，临时用）

```sh
npx @deepseek-ai/dsh web
```

### 方式 B：npm 全局安装（推荐，本机采用）

装到**用户级前缀**，避免修改系统目录（/usr 属 root）也不需要 sudo：

```sh
mkdir -p ~/.npm-global
npm install -g --prefix ~/.npm-global @deepseek-ai/dsh
```

### ⚠️ 关键坑：npm 12 会拦截安装脚本，必须放行（本机踩过）

npm 12 默认阻止包安装脚本（安全策略）。若不放行，`node-pty`（Web UI 终端功能的核心原生模块）的二进制缺失，运行时直接报错：

```
Error: Failed to load native module: pty.node ...
```

**修复**：放行被拦截包的脚本后重新安装。2026-08-23 实测新版 npm 会拦截 5 个包（完整清单），建议一次性全部放行：

```sh
npm install -g --prefix ~/.npm-global --allow-scripts=@deepseek-ai/dsh-subprocess-local,koffi,node-pty,@google/genai,protobufjs @deepseek-ai/dsh@next
```

说明：
- `node-pty` 的脚本是 `prebuild.js || node-gyp rebuild`——Linux 没有预编译包，会**本地编译**，需要 gcc/make/python3；产物 `build/Release/pty.node`
- `koffi` 是原生 FFI 绑定（平台包 `@koromix/koffi-linux-x64`），**建议一并放行**，缺失会导致运行时加载失败
- `@deepseek-ai/dsh-subprocess-local` 的脚本只是给 spawn-helper 恢复可执行位（chmod），无害
- `@google/genai`（preinstall 仅 echo）/ `protobufjs`（postinstall 生成代码）可不放行，不影响使用

**验证原生模块**：

```sh
cd ~/.npm-global/lib/node_modules/@deepseek-ai/dsh
node -e "const p=require('node-pty'); const t=p.spawn('echo',['ok'],{name:'xterm',cols:80,rows:24}); t.onData(d=>process.stdout.write(d))"
```

正常输出 `ok`。

> **默认安装到此即算完整**（本机 2026-08-17 实测）：方式 B 装完 → 配置 PATH（第四节）→ 做启动器集成（第六节，含图标与默认浏览器 Firefox）。装完后命令行 `dsh web` 与启动器搜索 DeepSeek Harness 都能用。

### 方式 C：从源码构建（需要 pnpm）

```sh
git clone https://github.com/deepseek-ai/deepseek-harness.git
cd deepseek-harness
pnpm install
pnpm run build
pnpm dsh web
```

## 四、PATH 配置（fish shell）

把 `~/.npm-global/bin` 加入 PATH，写入 `~/.config/fish/config.fish`：

```fish
fish_add_path -g ~/.npm-global/bin
```

验证：

```fish
dsh --version
# 输出: 与 npm 最新版一致（npm view @deepseek-ai/dsh version）
```

## 五、本地运行 Web UI

```sh
dsh web
```

- 默认地址：**http://127.0.0.1:3080**
- `dsh web` 是前台进程，`Ctrl+C` 停止
- 首次使用：在 Web UI 界面里配置模型/API（DeepSeek 或第三方 LLM 的 key 与接口）
- 用户数据目录：`~/.dsh/`（凭据、会话、配置都在这里，备份时打包它）

验证：

```sh
curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:3080/   # 应输出 200
```

## 六、集成到应用启动器（Niri 等桌面环境）

> 本节是**默认安装的一部分**（本机 2026-08 实测确认），不是可选增强。装完后启动器里搜索 DeepSeek Harness 即可一键启动。

从应用菜单/启动器里点一下就能启动并打开浏览器，需要三样东西：

### 1. 启动脚本 `~/scripts/dsh/dsh-web.sh`

```bash
#!/usr/bin/env bash
# 启动 DeepSeek Harness (dsh) Web UI 并在浏览器打开。
# 若 3080 端口已有 dsh 在运行则直接打开浏览器，否则后台启动并等待就绪。
# 用法:
#   dsh-web.sh              # 启动/打开 dsh Web UI
#   dsh-web.sh --stop       # 停止正在运行的 dsh web
#   dsh-web.sh --help       # 显示帮助
set -euo pipefail

DSH_BIN="$HOME/.npm-global/bin/dsh"
LOG_FILE="$HOME/.dsh/web.log"
URL="http://127.0.0.1:3080"
PORT="3080"
TIMEOUT_SEC=30

usage() {
  cat <<'EOF'
Usage: dsh-web.sh [options]

Options:
  -h, --help    显示帮助并退出
  --stop        停止正在运行的 dsh web 进程
EOF
}

require_deps() {
  local missing=()
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  if (( ${#missing[@]} > 0 )); then
    printf '错误: 缺少依赖: %s\n' "${missing[*]}" >&2
    exit 127
  fi
}

port_open() {
  curl -s -o /dev/null --max-time 2 "$URL/" 2>/dev/null
}

stop_dsh() {
  if pkill -f "$DSH_BIN web" 2>/dev/null; then
    echo "已停止 dsh web"
    return 0
  fi
  echo "没有正在运行的 dsh web"
  return 0
}

main() {
  require_deps curl xdg-open
  if [[ ! -x "$DSH_BIN" ]]; then
    printf '错误: 找不到 dsh: %s\n' "$DSH_BIN" >&2
    exit 1
  fi

  if port_open; then
    echo "dsh web 已在运行: $URL"
    xdg-open "$URL"
    exit 0
  fi

  echo "正在启动 dsh web ..."
  mkdir -p "$(dirname "$LOG_FILE")"
  nohup "$DSH_BIN" web >"$LOG_FILE" 2>&1 &
  disown

  local i
  for ((i = 0; i < TIMEOUT_SEC; i++)); do
    if port_open; then
      echo "dsh web 已就绪: $URL（日志: $LOG_FILE）"
      xdg-open "$URL"
      exit 0
    fi
    sleep 1
  done

  printf '错误: %s 秒内端口 %s 未就绪，请查看日志: %s\n' "$TIMEOUT_SEC" "$PORT" "$LOG_FILE" >&2
  exit 1
}

# --- 参数解析 ---
ACTION=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --stop) ACTION="stop" ;;
    *) printf '错误: 未知参数: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

if [[ "$ACTION" == "stop" ]]; then
  stop_dsh
  exit $?
fi

main
```

保存后：

```sh
chmod +x ~/scripts/dsh/dsh-web.sh
```

> **0.1.2-alpha.1 起本机实际脚本已迭代**（以 `~/scripts/dsh/dsh-web.sh` 为准，上例为基础版）：
> - 启动加 `--no-open`，由脚本统一负责打开浏览器，避免双标签；
> - 0.1.2 有 browser-trust 门禁（无 cookie 裸 URL 首开会 401），脚本从 `~/.dsh/web.log` 轮询提取 `?token=` URL 作为通行证打开，取不到再退回裸 URL；该 token 门签发的 cookie 有 30 天有效期，密钥存 credentials，跨重启有效；
> - `--stop` 增加端口释放等待，避免紧接重启时被误判"已在运行"；
> - **关页面即停（2026-09-14 加）**：启动后由 `~/scripts/dsh/dsh-web-watchdog.sh` 守候——数「本地端口是本机 dsh 端口、且属于该 dsh 进程」的 ESTAB 连接；**至少见过一个客户端后才武装**（避免就绪到浏览器连上之间的零连接窗口把自己关掉）；武装后连接数持续为 0 达 `DSH_WEB_IDLE_SEC`（默认 **120**）秒即 SIGTERM 停服。因此**把所有 dsh 页面关掉，两分钟后服务自动停止**，不会留下后台进程。
>   - 多标签页、刷新都不会误停（只要还有页面开着连接数就 > 0）；
>   - **临时保留**（例如让 agent 用 API 驱动 dsh）：`touch ~/.dsh/keepalive` 暂停自动停止，`rm ~/.dsh/keepalive` 恢复。豁免期间看门狗仍在观察客户端，所以解除后能立刻恢复正常计时；
>   - 被**插件市场的"重启"按钮**重启过之后看门狗会消失（市场是照自身 argv 直接 respawn dsh，绕过本脚本）；再点一次图标/跑一次脚本即可重新武装；
>   - 日志：`~/.dsh/watchdog.log`；状态查询：`dsh-web.sh --status`；
>   - 脚本只在**确定数到 0** 时才计时：`ss` 缺失或执行失败一律视为未知，只重置计时、绝不据此停服。

命令行用法：

```sh
~/scripts/dsh/dsh-web.sh          # 启动/打开（并武装看门狗）
~/scripts/dsh/dsh-web.sh --stop   # 停止服务与看门狗
~/scripts/dsh/dsh-web.sh --status # 查看服务/看门狗/客户端连接数
```

> 可调环境变量：`DSH_WEB_PORT`（默认 3080）、`DSH_WEB_IDLE_SEC`（默认 120）。

### 2. 桌面条目 `~/.local/share/applications/dsh.desktop`

```
[Desktop Entry]
Type=Application
Name=DeepSeek Harness
Comment=启动 DeepSeek Harness Web UI (http://127.0.0.1:3080)
Exec=/home/pang/scripts/dsh/dsh-web.sh
Icon=dsh
Terminal=false
Categories=Development;
StartupNotify=false
```

> 注意：
> - `Exec` 里的路径要改成你自己的 `dsh-web.sh` 绝对路径
> - `Icon=dsh` 对应"四步安装图标"（见下文 4 图标一节）；如果不想装图标，可改为 `Icon=applications-development` 用系统通用图标，或直接写图标文件绝对路径 `Icon=/home/pang/.local/share/icons/dsh.svg`

### 3. 设置默认浏览器为 Firefox

`dsh-web.sh` 用 `xdg-open` 打开页面，跟随系统默认浏览器。本机默认浏览器已设为 Firefox：

```sh
xdg-settings set default-web-browser firefox.desktop
xdg-mime default firefox.desktop x-scheme-handler/http
xdg-mime default firefox.desktop x-scheme-handler/https
```

验证：

```sh
xdg-settings get default-web-browser    # 应输出 firefox.desktop
```

> 想保留系统默认浏览器不变、只让 dsh 用 Firefox：把 `dsh-web.sh` 里的 `xdg-open "$URL"` 换成 `firefox "$URL"`，或设置环境变量 `BROWSER=firefox`。

### 4. 图标（让启动器显示 dsh 官方图标）

图标文件在本文档同目录的 `icons/` 子目录里（从官方仓库下载）：

| 文件 | 说明 | 用途 |
|---|---|---|
| `icons/dsh-favicon.svg` | 官方 50×50 图标（DeepSeek 图形，深色模式自适应） | **启动器图标首选** |
| `icons/dsh-wordmark.svg` | 官方宽幅字标 143×23 | 不适合做图标，仅作参考 |
| `icons/dsh-badge.png` | 官方 skill 徽章 | 备选 |

安装步骤（四步）：

```sh
# 1. 创建图标目录并复制（SVG 是矢量，任意尺寸清晰）
mkdir -p ~/.local/share/icons/hicolor/scalable/apps
cp "<本文档目录>/icons/dsh-favicon.svg" ~/.local/share/icons/hicolor/scalable/apps/dsh.svg

# 2. 刷新图标缓存（可选，多数环境不需要）
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
  gtk-update-icon-cache -f ~/.local/share/icons/hicolor
fi

# 3. 刷新应用数据库
update-desktop-database ~/.local/share/applications

# 4. 重新打开启动器，搜索 DeepSeek Harness 即可看到官方图标
```

> 备用方案：如果图标主题不认 SVG，可改用 PNG（需要先转换）：
> ```sh
> # 需要 rsvg-convert 或 inkscape 等工具把 SVG 转成 256x256 PNG
> mkdir -p ~/.local/share/icons/hicolor/256x256/apps
> rsvg-convert -w 256 -h 256 ~/.local/share/icons/hicolor/scalable/apps/dsh.svg \
>   -o ~/.local/share/icons/hicolor/256x256/apps/dsh.png
> gtk-update-icon-cache -f ~/.local/share/icons/hicolor
> ```
> 或者最简单：.desktop 里 `Icon` 直接写图标绝对路径（见上文注意）。

### 5. 刷新并启用

```sh
update-desktop-database ~/.local/share/applications
```

然后打开应用启动器（Niri 下一般是 rofi/walker/fuzzel），搜索 **DeepSeek Harness** 回车即可。若列表里没出现，重新打开一次启动器让它重新扫描。

### 6. 效果

- 点击启动器条目 → 自动后台启动 dsh web → 就绪后自动用默认浏览器（本机为 Firefox）打开 http://127.0.0.1:3080
- 已在运行时再点 → 直接打开浏览器，不会重复启动
- 停止：`~/scripts/dsh/dsh-web.sh --stop`（或按启动器里的停止入口）

## 七、升级

开发者预览版迭代快，升级命令（同样带放行参数，完整清单见"方式 B"）：

```sh
npm install -g --prefix ~/.npm-global --allow-scripts=@deepseek-ai/dsh-subprocess-local,koffi,node-pty,@google/genai,protobufjs @deepseek-ai/dsh@next
```

> ⚠️ **升级前必须先停掉正在运行的旧实例**（`~/scripts/dsh/dsh-web.sh --stop` 或前台 Ctrl+C）。本机 2026-08-23 实测踩过两种后果：
> 1. 旧进程占着 3080 不退出 → 新版启动报 `EADDRINUSE: address already in use 127.0.0.1:3080`；
> 2. **更严重**：直接对着运行中的服务执行 `npm install -g`，npm 会替换进程正在读取的包文件，新旧代码交错导致**服务卡死**，只能停服重装一次并重启。

建议先停服再执行升级：

```sh
~/scripts/dsh/dsh-web.sh --stop
npm install -g --prefix ~/.npm-global --allow-scripts=@deepseek-ai/dsh-subprocess-local,koffi,node-pty,@google/genai,protobufjs @deepseek-ai/dsh@next
~/scripts/dsh/dsh-web.sh
```

> **务必带 `@next`（或显式版本号）**：裸写 `@deepseek-ai/dsh` 会跟 `latest` 走，而该标签历史上长期停在旧格式的 0.1.1-rc.2（与 0.1.2+ 会话格式不互通）。安装前先 `npm view @deepseek-ai/dsh dist-tags --json` 确认，并留意 `npm view` 的缓存幽灵标签。

**跨版本升级（尤其 0.1.2 → 0.1.5 这类跨代）四项必查**，本机 2026-09-10 实测：

1. **先摘掉 `dsh-archive-manager`**：它的"清理失效归档 id"逻辑在 0.1.3+ 持久化 API 变更后会把 `~/.dsh/storages/workspace.json` 的 `global.archivedSessionIds` **清空**（实测 32 → 0），且上游无修复。0.1.5 核心自带归档动作与会话隐藏（会话右键 `归档会话`），但核心 UI **没有已归档列表与"取消归档"**——摘掉后若要找回某个归档会话，仍需手改 `~/.dsh/storages/workspace.json` 的 `global.archivedSessionIds` 再重启。
2. **改家层 persona 补丁的键名**：`~/.dsh/cordis.patch.yml` 里 `config.persona` 已改名为 `config.personaPrefix`（另有 `personaSuffix`）。旧键会被 zod 静默丢弃——**启动不报错，自定义守则直接失效**。
3. **会话文件已按代际命名**：v0 是 `session.jsonl.zstd`，之后是 `session.v2.jsonl.zstd` / `session.v3.jsonl.zstd`。升级只在同目录**旁边**写新代（旧代字节与 inode 不变），并会多出 `session.lock`。**回退不受支持**（官方措辞："升级后的会话不支持降级读取"）：旧版只读 v0，升级后新增的轮次在旧版里静默不可见。因此备份要用**真实整目录副本**（`cp -a`，不要 `cp -al`），并先停服务。
4. **插件必须有适配版**：实证 `dsh-better-sidebar` 需 **≥0.19.0**（0.18.0 调 0.1.5 已删的 `persistence.inspect`；0.19.0 改 `persistence.open(id,'read')` 且 peer 重钉 `^0.1.5-rc.1`）。升级前用 semver 实测各插件 peer 范围是否放行新版本，并 grep 其源码是否引用被删 API——细节见技能 dsh-plugin-management 的坑表。

原生依赖方面：0.1.5 已移除需要 node-gyp 现场编译的 `fs-ext`，改用预编译 N-API 包 `@deepseek-ai/node-addon-system`（含 linux glibc/musl 预构件，安装期无需编译）。

### 0.1.5-rc.2 → 0.1.6-alpha.1（2026-09-15 本机升级实录）

**先试装验收再正式升**（本次做法，推荐沿用）：`npm install -g --prefix /tmp/npm-016 …@0.1.6-alpha.1` → 复制 home 到 `/tmp/eval016` 并把插件层软链接改指到临时树 → 备用端口 3199 启动 → 确认「10 个插件全加载、0 激活错误、页面 0 控制台错误、会话树与归档完好」后才动真机。

**两处必做迁移**：

1. **`llm-deepseek.baseURL` 必须移除或改写**：0.1.6 官方默认改用 Messages 协议，其 baseURL 默认值随协议选择（`messages → https://api.deepseek.com/anthropic`，`chat → https://api.deepseek.com`）。显式写死旧公开根地址会让新协议打错路径。本机已移除该行（改用默认）。
2. **Agent Teams 实验包要连内层一起对齐**：0.1.6 的外层包把 `dsh-experimental-{agent-team,tool-agent-team,client-ui-agent-team}` 声明为 **peer 依赖**，`dsh plugin add` 只升外层、pnpm 会沿用旧 hoisted 副本 → 跨层版本不匹配（`pnpm` 只给 peer 警告）。做法：把这三个内层包以 `0.1.6-alpha.1` 钉进 `~/.dsh/profiles/web/package.json` 的 `dependencies`，再 `cd ~/.dsh/profiles/web && pnpm install`。

**其它变化（实测无碍但要知道）**：会话横幅的 `Agent Team` 按钮在 0.1.6 不再显示（客户端模块仍在组合包内，属 UI 改版）；界面模式按钮文案由「PTC 模式」变为按预设名显示；**设置里新增「已归档会话」面板**（带搜索与「取消归档」，终于不用手改 `workspace.json` 了）；Node PTC 改独立进程执行、`process.env` 为空；配置热更新取消了事务回滚（改坏配置不再是全有全无）。

**技能化的操作手册**：dsh 本体（版本查询、升级门禁与流程、回滚、会话数据迁移、平台补丁）见技能 `~/.dsh/skills/dsh-upgrade/`；插件（安装/卸载/适配/排障）见 `~/.dsh/skills/dsh-plugin-management/`。两者各带 SOP 与 reference，动手前按其流程执行。

**升级后必查**：`dsh --version`、`~/.dsh/web.log` 的激活错误计数、`~/scripts/dsh/dsh-web.sh --status`、技能 `verify.sh`（版本锚点会因升级报 DRIFT，按提示同步）。启动提速补丁由启动器自动补，无需手工（见下）。

**启动提速补丁：已折进启动器，无需手工重跑**（`npm install` 会覆盖 `node_modules`，因此原先需要每次装完手跑一次）：

```sh
bash ~/scripts/dsh/dsh-web.sh          # 启动时自动检查并补上（幂等）
bash ~/scripts/dsh/patch-upstream-client-modules-speedup.sh --check    # 想确认状态时用
```

`dsh-web.sh` 在起新实例前调用该补丁脚本（已打过时只做一次 grep，约毫秒级；补一次约 0.3 秒），并在检测到 dsh 被重装过时打印一行 `已自动重跑启动提速补丁`。**补丁失败绝不阻断启动**（最坏只是启动慢约 2.3 秒，会打印警告）。技能自校验第 7 项也会报告它是否在位。

它修的是第三方依赖 `@deepseek-ai/dsh-client-modules` 里两处热点函数的写法——启动时"组合客户端模块包"占启动 CPU 约 57%，而 `newlineCount` 用 `for (const char of value)` 按**码点**迭代整串、`identitySectionMap` 为**每一行**先建字符串再 join；本机客户端模块明文合计约 15MB（dsh 自带的 `dsh-client-ui-sidebar-documentpreview/client.js` 一个就 6.57MB），每次冷启动全量重算。实测：

| | 启动到就绪 |
|---|---|
| 上游原样 | 8.13s / 8.16s |
| 打补丁后 | **5.76s / 5.89s**（约 −28%） |

等价性已证明：combo 的 `rev`（bundle + sourcemap 内容哈希）补丁前后都是 `6ed00f8c2f79`（59 模块 / 14.9MB），即**组合产物与 sourcemap 逐字节一致**。脚本幂等，带前置片段校验、合成用例自测；`--revert` 可还原，`--check` 只看状态。技能自校验第 7 项会检查它是否在位。

> 另外两条可选路线（见技能坑表"启动慢"行）：② 用 `--patch` 把 `ui-sidebar-documentpreview` 设为 `disabled: true`（启动 5.2–5.9s，但失去右侧栏 Markdown/代码/图片/PDF/HTML 预览）；③ 把 `DSH_WEB_IDLE_SEC` 调大让服务常驻（重开页面 0 秒，代价常驻约 710MB）。注意页面侧本身不慢（`load` 429–793ms、FCP 168ms，combo 有 immutable 缓存），慢的是**服务端冷启动**。

**升级后验证**（三连）：

```sh
dsh --version                                    # 应等于 `npm view @deepseek-ai/dsh dist-tags.next`（不是 version/latest！）
find ~/.npm-global/lib/node_modules/@deepseek-ai/dsh/node_modules -name "*.node" -path "*linux*" | head -3   # 应有 sharp/koffi/pty 的 linux 产物
node -e "const p=require('node-pty');p.spawn('echo',['ok'],{name:'xterm',cols:80,rows:24}).onData(d=>process.stdout.write(d))"   # 冒烟输出 ok
```

升级前建议备份配置：

```sh
cp -r ~/.dsh ~/.dsh.backup.$(date +%Y%m%d)
```

## 八、故障排查速查

| 现象 | 原因 | 处理 |
|---|---|---|
| `Failed to load native module: pty.node` | node-pty 安装脚本被 npm 拦截 | 重装（见"方式 B"放行命令） |
| 端口 3080 无响应 | dsh web 未启动 | `dsh web` 或启动器启动 |
| 启动器里搜不到 | 应用数据库未刷新 | `update-desktop-database ~/.local/share/applications` 后重开启动器 |
| 端口被占 | 之前实例未退出 | `~/scripts/dsh/dsh-web.sh --stop` 后重启 |
| `EADDRINUSE: address already in use 127.0.0.1:3080` | 升级前启动的旧实例未停止 | `~/scripts/dsh/dsh-web.sh --stop` 停旧进程，再启动新版 |
| `corrupt Zstandard session log: first frame is not exactly one header line` 启动即炸 / 旧会话历史加载失败（`sourceEventSeqs must densely contain …`） | 0.1.2 家族（源码与 npm，`ptc` 预设+区间格式）与 npm 0.1.1-rc.2（`code` 预设+扁平格式）的会话数据格式不互通（首帧布局、预设 id `ptc`/`code`、区间/扁平数组三类差异；本机现以 npm **0.1.5-rc.1** 为最终版，会话格式 v3，日志按代际命名 `session.vN.jsonl[.zstd]`（v0 仍为 `session.jsonl.zstd`）——运维脚本已改为每目录只处理最高规范代，不要再手动指定旧名） | 先停服务。首帧修复两个方向都要：`node ~/scripts/dsh/dsh-session-repair.mjs`。数据配 0.1.2 原生格式：从迁移前备份恢复或用 `~/scripts/dsh/dsh-session-migrate.mjs code ptc`；数据配 0.1.1：跑 `migrate.mjs ptc code` + `~/scripts/dsh/dsh-session-expand-ranges.mjs`。同时把 `settings.yaml` 的 `agent-presets.default` 改为对应当前构建的 id（0.1.2=`ptc`，0.1.1=`code`），删 `~/.dsh/storages/session_projcache`，重启。详见技能 dsh-plugin-management 坑表 |
| 升级命令执行后服务卡死/页面无响应 | 在服务运行中执行 `npm install -g`，npm 直接替换了运行中进程正在使用的包文件（本机 2026-08-23 实测踩过） | 升级前必须先 `~/scripts/dsh/dsh-web.sh --stop`；已发生则停服后重装一次再启动 |
| node-gyp 编译报 `InvalidArgumentError: invalid onError method`（undici EnvHttpProxyAgent） | 本机配了 `HTTP(S)_PROXY=127.0.0.1:7890`，npm 内置 undici 的代理 agent 下载 Node headers 时崩溃（本机 2026-08-23 实测踩过） | 用 curl 手动下载 `https://nodejs.org/download/release/v<node版本>/node-v<版本>-headers.tar.gz` 解包到 `~/.cache/node-gyp/<版本>/`（`--strip-components=1`），再前置 `env -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u http_proxy -u https_proxy -u all_proxy` 重跑原命令 |

> 实测补充（2026-08-17）：
> - 在**没有桌面会话变量**的环境（远程 shell、脚本后台）里跑 `dsh-web.sh`，xdg-open 会正常拉起浏览器但进程不退出（等浏览器关闭），属于环境限制不是脚本 bug；从启动器/真实终端跑没有此问题。
> - `--stop` 用 `pkill -f "$DSH_BIN web"` 匹配命令行：不要在命令行里恰好包含该字符串（例如同时在做 `grep`/`pgrep` 该路径）时执行 `--stop`，否则会把自己的命令一并杀掉。

## 九、相关链接

- 仓库：https://github.com/deepseek-ai/deepseek-harness
- 中文 README：https://github.com/deepseek-ai/deepseek-harness/blob/main/README.zh.md
- Web UI 指南：仓库内 `docs/user/guide/index.md`
- 插件生态：#dsh-plugin 话题（GitHub）
