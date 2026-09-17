#!/usr/bin/env bash
# =============================================================================
# upgrade-dsh.sh —— dsh 升级器（宿主服务运行中、agent 会话寄生其内时同样安全）
#
# 背景：本机 dsh web 由 ~/scripts/dsh/dsh-web.sh 拉起，agent 会话就寄生在 `dsh web`
# 进程里（`ps --forest` 可见会话的 bash 是 `dsh web` 的直接子进程）。因此：
#   * 直接 `npm i -g` 会原地覆盖正在运行的 npm 树（运行中进程懒加载会读到半新半旧）；
#   * 重启服务会终结当前 agent turn。
# 所以升级拆成两段：
#
#   --probe      无损预检（技能 SOP 强制）：新版本装到**暂存前缀**，复制一份 DSH_HOME
#                到探测目录，在空闲端口预启动探测。不碰真实 home、不碰运行中的服务。
#   --activate   破坏性原子切换：**必须用 systemd-run --user 独立单元执行**——寄生在
#                调用方的 systemd 瞬态 scope 内时，scope 停止会连带杀死它（2026-09-15 事故）。
#                顺序：停服 → 换装 → 同步实验包 → 起服 → 验证 → 失败回滚。
#
# 用法：
#   bash upgrade-dsh.sh --probe --target 0.1.6-alpha.2
#   # 切换必须脱离调用者的 cgroup（否则调用方的 systemd 瞬态 scope 停止会连带杀死它），
#   # 且必须带 --property=KillMode=process：
#   #   本脚本 start_server 用 setsid nohup 派生服务，而 setsid **只换会话不换 cgroup**。
#   #   瞬态单元默认 KillMode=control-group，主进程退出时会杀掉 cgroup 内全部进程，
#   #   于是新起的 dsh web 随单元一起消失，机器停在"端口无服务"。
#   #   2026-09-17 A/B 实测：不带该属性 -> 派生进程被杀；带上 -> 存活。
#   systemd-run --user --unit=dsh-upgrade-$(date +%s) --collect \
#       --property=KillMode=process \
#       bash /home/pang/scripts/dsh/upgrade-dsh.sh \
#       --activate --target 0.1.6-alpha.2 --fallback 0.1.6-alpha.1 --grace 90
#
# 产物：
#   ~/.dsh/notes/probe-<target>.log / probe-<target>-STATUS        探测日志与结论
#   ~/.dsh/notes/upgrade-<target>.log / -REPORT.md / -STATUS       切换日志/报告/状态
#
# 环境变量：
#   DSH_HOME_REAL(~/.dsh) DSH_PREFIX(~/.npm-global) DSH_BACKUP_ROOT(~/backups)
#   DSH_WEB_PORT(3080) DSH_PROBE_PORT(3099) DSH_SETTLE_SEC(60) DSH_WEB_IDLE_SEC(120)
# =============================================================================
set -uo pipefail

# 启动器（systemd-run --user / cron 等）的环境可能不带用户 PATH，这里自带一份
export PATH="$HOME/.npm-global/bin:$HOME/.local/bin:$HOME/scripts/dsh:$PATH"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REAL_HOME="${DSH_HOME_REAL:-$HOME/.dsh}"
REAL_PREFIX="${DSH_PREFIX:-$HOME/.npm-global}"
BACKUP_ROOT="${DSH_BACKUP_ROOT:-$HOME/backups}"
NOTES_DIR="$REAL_HOME/notes"
SKILL_VERIFY="$REAL_HOME/skills/dsh-upgrade/scripts/verify.sh"
PORT="${DSH_WEB_PORT:-3080}"
PROBE_PORT="${DSH_PROBE_PORT:-3099}"
SETTLE_SEC="${DSH_SETTLE_SEC:-60}"
IDLE_SEC="${DSH_WEB_IDLE_SEC:-120}"
ALLOW_SCRIPTS="node-pty,@deepseek-ai/dsh-subprocess-local"
WATCHDOG="$SCRIPT_DIR/dsh-web-watchdog.sh"
LAUNCHER="$SCRIPT_DIR/dsh-web.sh"
SPEEDUP_PATCH="$SCRIPT_DIR/patch-upstream-client-modules-speedup.sh"
WATCHDOG_PIDFILE="$REAL_HOME/dsh-web-watchdog.pid"
WATCHDOG_LOG="$REAL_HOME/watchdog.log"
KEEPALIVE="$REAL_HOME/keepalive"

TARGET=""
FALLBACK=""
GRACE=45
FORCE=0
WEB_OFFSET=0
BUMP_FAILS=0

EXPERIMENTAL=(
  '@deepseek-ai/dsh-experimental-agent-team'
  '@deepseek-ai/dsh-experimental-agent-team-profile'
  '@deepseek-ai/dsh-experimental-agent-team-web-profile'
  '@deepseek-ai/dsh-experimental-client-ui-agent-team'
  '@deepseek-ai/dsh-experimental-tool-agent-team'
)

# web profile 组合树里应出现的 bundle 层标记（--dump-config 的注释行）
LAYER_MARKERS=(
  '# == dshmarket'
  '# == dsh-better-sidebar'
  '# == dsh-web-fetch-global'
  '# == @opencode2dsh/dsh-plugin'
  '# == @deepseek-ai/dsh-experimental-agent-team-profile'
  '# == @deepseek-ai/dsh-experimental-agent-team-web-profile'
  '# == dsh-theme-xuanpaper'
  '# == @axiaohungry/dsh-llm-workbuddy'
)

log()   { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
usage() { sed -n '2,32p' "${BASH_SOURCE[0]}"; }

stage_prefix() { printf '%s/.npm-global-stage-%s' "$HOME" "$TARGET"; }

dsh_pid_on_port() {
  local p="${1:-$PORT}" out=""
  out=$(ss -tlnp 2>/dev/null | grep -F ":$p " | grep -oE 'pid=[0-9]+' | head -1 | cut -d= -f2) || true
  printf '%s' "$out"
}

http_code() { curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:${1:-$PORT}/" 2>/dev/null; }

wait_port() { # $1 port, $2 timeout sec
  local i code
  for ((i = 0; i < ${2:-60}; i++)); do
    code=$(http_code "$1")
    [[ -n "$code" && "$code" != "000" ]] && return 0
    sleep 1
  done
  return 1
}

SCAN_RE='plugin tree failed to load|did not activate|pending \(waiting|failed to import loader entry|ERR_MODULE_NOT_FOUND|Cannot find module|SyntaxError|does not provide an export named'

scan_errors() { # $1 logfile, $2 byte offset -> matching lines
  local from=$(( ${2:-0} + 1 ))
  tail -c "+$from" "$1" 2>/dev/null | grep -E "$SCAN_RE" || true
}

install_dsh() { # $1 prefix, $2 version, $3 logfile
  log "npm install -g --prefix $1 @deepseek-ai/dsh@$2"
  npm install -g --prefix "$1" --prefer-online --allow-scripts="$ALLOW_SCRIPTS" \
    "@deepseek-ai/dsh@$2" >>"$3" 2>&1
}

bump_experimental() { # $1 home, $2 dsh bin, $3 version, $4 logfile; 结果写入全局 BUMP_FAILS
  local p
  BUMP_FAILS=0
  for p in "${EXPERIMENTAL[@]}"; do
    log "  实验包 → $p@$3"
    if ! DSH_HOME="$1" "$2" plugin --profile web add "$p@$3" >>"$4" 2>&1; then
      log "  警告: $p@$3 升级失败（继续，结论里标出）"
      BUMP_FAILS=$((BUMP_FAILS + 1))
    fi
  done
}

dump_config() { # $1 home, $2 dsh bin, $3 outfile, $4 logfile
  DSH_HOME="$1" "$2" --profile web --dump-config >"$3" 2>>"$4"
}

missing_markers() { # $1 dumpfile -> missing markers, one per line
  local m
  for m in "${LAYER_MARKERS[@]}"; do
    grep -qF "$m" "$1" 2>/dev/null || printf '%s\n' "$m"
  done
}

start_server() { # $1 dsh bin -> sets WEB_OFFSET; 0 ok / 1 port never opened
  local bin="$1" dpid
  WEB_OFFSET=$(stat -c %s "$REAL_HOME/web.log" 2>/dev/null || echo 0)
  log "启动服务: $bin web --no-open --port $PORT"
  setsid nohup "$bin" web --no-open --port "$PORT" >>"$REAL_HOME/web.log" 2>&1 </dev/null &
  disown 2>/dev/null || true
  wait_port "$PORT" 90 || return 1
  dpid=$(dsh_pid_on_port "$PORT")
  if [[ -n "$dpid" && -x "$WATCHDOG" ]]; then
    local wp wt rest
    read -r wp wt rest <"$WATCHDOG_PIDFILE" 2>/dev/null || true
    if [[ -n "${wp:-}" && "${wt:-}" == "$dpid" ]] && kill -0 "$wp" 2>/dev/null; then
      log "看门狗已在守候 pid=$dpid（pid=$wp），跳过重复派生"
    else
      setsid nohup "$WATCHDOG" --pid "$dpid" --port "$PORT" --idle-sec "$IDLE_SEC" \
        --log "$WATCHDOG_LOG" --keepalive "$KEEPALIVE" --pidfile "$WATCHDOG_PIDFILE" \
        >/dev/null 2>&1 </dev/null &
      disown 2>/dev/null || true
      log "看门狗已武装 pid=$dpid"
    fi
  fi
  return 0
}

stop_server() { # $1 logfile
  log "停止 dsh web 与看门狗"
  bash "$LAUNCHER" --stop >>"${1:-/dev/null}" 2>&1 || true
  sleep 3
  local p; p=$(dsh_pid_on_port "$PORT")
  if [[ -n "$p" ]]; then
    log "兜底 TERM pid=$p"; kill -TERM "$p" 2>/dev/null || true; sleep 3
  fi
  return 0
}

# 退出兜底：无论 activate 走到哪一步结束，3080 都必须有服务在跑。
# 2026-09-15 事故：切换脚本寄生在工具调用的 systemd 瞬态 scope 内，桌面会话在宽限期
# 结束前重启（13:49:16 全体 app scope 被停），脚本与服务一起被杀，机器停在"无 GUI"
# 状态三小时。故：① 必须用 systemd-run --user 独立单元启动（见 --help 尾部）；
# ② 脚本自身保证退出时服务在位。
ensure_server_up() {
  local code; code=$(http_code "$PORT")
  if [[ -n "$code" && "$code" != "000" ]]; then return 0; fi
  log "[trap] 端口 $PORT 无服务，兜底拉起当前实装版本"
  if [[ -x "$REAL_PREFIX/bin/dsh" ]]; then
    start_server "$REAL_PREFIX/bin/dsh" || log "[trap] 兜底起服失败，需人工: bash $LAUNCHER --status"
  else
    log "[trap] $REAL_PREFIX/bin/dsh 不可执行，需人工介入"
  fi
  return 0
}

stop_probe() {
  local pp; pp=$(dsh_pid_on_port "$PROBE_PORT")
  if [[ -n "$pp" ]]; then
    log "[probe] 停止探测服务 pid=$pp"
    pkill -TERM -P "$pp" 2>/dev/null || true
    kill -TERM "$pp" 2>/dev/null || true
    sleep 3
    kill -KILL "$pp" 2>/dev/null || true
  fi
  return 0
}

# ---------------------------------------------------------------- probe ----
probe() {
  local stage probe_home plog dump fail=0 have miss errs
  stage="$(stage_prefix)"
  # 探测 home 必须与真实 home **同深度**（$HOME 下）：
  # profile 的 pnpm-lock.yaml 把 file: 依赖存成相对路径（如 ../../../Projects/dsh/...），
  # 放到 ~/backups/ 下层级一变就解析到不存在的路径，pnpm 直接 ENOENT。
  probe_home="$HOME/.dsh-probe-$TARGET"
  plog="$NOTES_DIR/probe-$TARGET.log"
  dump="$NOTES_DIR/probe-$TARGET-dump-config.yml"
  mkdir -p "$NOTES_DIR"; : >"$plog"

  log "[probe] 目标=$TARGET 暂存前缀=$stage 探测 home=$probe_home 端口=$PROBE_PORT"

  # 1) 暂存安装（不触碰真实前缀）
  have=""
  [[ -x "$stage/bin/dsh" ]] && have="$("$stage/bin/dsh" --version 2>/dev/null)"
  if [[ "$have" != "$TARGET" ]]; then
    install_dsh "$stage" "$TARGET" "$plog" || { log "[probe] 暂存安装失败，见 $plog"; return 1; }
    have="$("$stage/bin/dsh" --version 2>/dev/null)"
  fi
  [[ "$have" == "$TARGET" ]] || { log "[probe] 暂存树版本异常: '$have'"; return 1; }
  log "[probe] 暂存树就绪: $have"

  # 2) 复制 DSH_HOME（排除顶层 sessions/attachments —— 探测绝不碰真实会话）
  #    注意 exclude 必须带前导斜杠锚定到传输根：`--exclude 'sessions'` 会匹配任意层级
  #    同名目录，曾把 @anthropic-ai/sdk/resources/beta/sessions/ 一起排除掉，
  #    导致 llm-workbuddy 导入 SDK 失败、插件树加载中断（假故障，排查了半小时）。
  rm -rf "$probe_home"; mkdir -p "$probe_home"
  if ! rsync -a --exclude '/sessions' --exclude '/attachments' --exclude '/web.log' \
      --exclude '/watchdog.log' --exclude '/dsh-web-watchdog.pid' --exclude '/keepalive' \
      "$REAL_HOME/" "$probe_home/" >>"$plog" 2>&1; then
    log "[probe] rsync 失败"; return 1
  fi
  # 副本完整性哨兵：SDK 的 sessions 目录必须跟着过来（防止 exclude 再次误伤）
  if [[ -d "$REAL_HOME/profiles/web/node_modules/@anthropic-ai/sdk/resources/beta/sessions" \
        && ! -d "$probe_home/profiles/web/node_modules/@anthropic-ai/sdk/resources/beta/sessions" ]]; then
    log "[probe] rsync 副本缺少 sdk/resources/beta/sessions —— exclude 误伤，探测不可信"; return 1
  fi

  # 3) 实验包对齐到目标版本（对齐失败 = 探测失败：否则测的不是要交付的状态）
  bump_experimental "$probe_home" "$stage/bin/dsh" "$TARGET" "$plog"
  if [[ "$BUMP_FAILS" -ne 0 ]]; then
    log "[probe] 有 $BUMP_FAILS 个实验包未能对齐到 $TARGET"; fail=1
  fi

  # 4) 组合树预检（不起服务）
  dump_config "$probe_home" "$stage/bin/dsh" "$dump" "$plog"
  miss=$(missing_markers "$dump")
  if [[ -z "$miss" ]]; then
    log "[probe] dump-config: 8 个 bundle 层标记齐全"
  else
    log "[probe] dump-config 缺层:"; printf '%s\n' "$miss"; fail=1
  fi

  # 5) 空闲端口预启动探测
  : >"$probe_home/web-probe.log"
  log "[probe] 端口 $PROBE_PORT 预启动 ..."
  DSH_HOME="$probe_home" setsid nohup "$stage/bin/dsh" web --no-open --port "$PROBE_PORT" \
    >>"$probe_home/web-probe.log" 2>&1 </dev/null &
  disown 2>/dev/null || true

  if wait_port "$PROBE_PORT" 90; then
    log "[probe] 端口已就绪，等 ${SETTLE_SEC}s 让插件树 settle ..."
  else
    log "[probe] 端口 $PROBE_PORT 90s 未就绪"; fail=1
  fi
  sleep "$SETTLE_SEC"

  # settle 后复检存活：webserver 端口会提前绑定，端口通 ≠ 插件树装载成功
  # （踩过：插件树加载中断后进程退出，而 wait_port 早在崩溃前就返回成功 → 假 PASS）
  local pid_after; pid_after=$(dsh_pid_on_port "$PROBE_PORT")
  if [[ -z "$pid_after" || "$(http_code "$PROBE_PORT")" == "000" ]]; then
    log "[probe] settle 后探测服务已不在（插件树加载中断或进程崩溃）"; fail=1
  else
    log "[probe] settle 后服务仍在: pid=$pid_after"
  fi

  errs=$(scan_errors "$probe_home/web-probe.log" 0 | wc -l)
  if [[ "$errs" -eq 0 ]]; then
    log "[probe] 启动日志 0 条激活/加载失败"
  else
    log "[probe] 启动日志有 $errs 条激活/加载失败:"; scan_errors "$probe_home/web-probe.log" 0 | head -8
    fail=1
  fi

  stop_probe

  if [[ "$fail" -eq 0 ]]; then
    log "[probe] 结论: PASS —— $TARGET 在隔离 home 里带着全部插件层成功启动"
    printf 'PASS\n' >"$NOTES_DIR/probe-$TARGET-STATUS"
    return 0
  fi
  log "[probe] 结论: FAIL —— 见 $plog 与 $probe_home/web-probe.log"
  printf 'FAIL\n' >"$NOTES_DIR/probe-$TARGET-STATUS"
  return 1
}

# ------------------------------------------------------------- activate ----
emit_report() { # $1 report path, $2 status, $3 body
  {
    printf '# dsh 升级报告：→ %s\n\n' "$TARGET"
    printf -- '- 状态: **%s**\n' "$2"
    printf -- '- 时间: %s\n' "$(date -Iseconds)"
    printf -- '- 目标版本: `%s`（回退 `%s`）\n' "$TARGET" "$FALLBACK"
    printf -- '- 实装版本: `%s`\n' "$("$REAL_PREFIX/bin/dsh" --version 2>/dev/null || echo '?')"
    printf -- '- 切换日志: `%s`\n' "$NOTES_DIR/upgrade-$TARGET.log"
    printf -- '- 升级前全量备份: `%s`\n' "$(cat "$BACKUP_ROOT/.last-dsh-backup-path" 2>/dev/null || echo '未记录')"
    printf -- '- 隔离探测记录: `%s`\n\n' "$NOTES_DIR/probe-$TARGET-STATUS"
    printf '%s\n' "$3"
  } >"$1"
}

activate() {
  local stage report alog snap sver ver errs miss code dumpfile bootlog status="success" body=""
  stage="$(stage_prefix)"
  report="$NOTES_DIR/upgrade-$TARGET-REPORT.md"
  alog="$NOTES_DIR/upgrade-$TARGET.log"
  dumpfile="$NOTES_DIR/upgrade-$TARGET-dump-config.yml"
  mkdir -p "$NOTES_DIR"; : >"$alog"
  # 自带时间线落盘（不依赖启动器的 stdout 重定向）+ 退出兜底
  exec >>"$NOTES_DIR/upgrade-$TARGET-timeline.log" 2>&1
  trap ensure_server_up EXIT

  log "[activate] 目标=$TARGET 回退=$FALLBACK 宽限=${GRACE}s"
  log "[activate] 等待 ${GRACE}s 让宿主 turn 先把消息送出去 ..."
  sleep "$GRACE"

  # 前置 1：必须先跑过 --probe 且 PASS
  if [[ "$(cat "$NOTES_DIR/probe-$TARGET-STATUS" 2>/dev/null)" != "PASS" && "$FORCE" -eq 0 ]]; then
    log "[activate] 中止：未找到 $TARGET 的 PASS 探测记录（--force 可跳过）"
    emit_report "$report" "failed" $'## 中止\n\n未找到隔离探测的 PASS 记录。请先执行：\n\n    bash '"$SCRIPT_DIR"'/upgrade-dsh.sh --probe --target '"$TARGET"$'\n'
    printf 'failed\n' >"$NOTES_DIR/upgrade-$TARGET-STATUS"
    return 1
  fi

  # 前置 2：暂存树必须是目标版本
  sver="$("$stage/bin/dsh" --version 2>/dev/null)"
  if [[ "$sver" != "$TARGET" ]]; then
    log "[activate] 中止：暂存树版本为 '$sver'"
    emit_report "$report" "failed" $'## 中止\n\n暂存前缀版本为 `'"$sver"$'`，不是目标 `'"$TARGET"$'`。'
    printf 'failed\n' >"$NOTES_DIR/upgrade-$TARGET-STATUS"
    return 1
  fi

  # 快照 profile 声明（回滚参考）
  snap="$BACKUP_ROOT/upgrade-$TARGET-snapshot"
  mkdir -p "$snap"
  cp -a "$REAL_HOME/profiles/web/package.json" "$snap/" 2>/dev/null || true
  cp -a "$REAL_HOME/profiles/web/pnpm-lock.yaml" "$snap/" 2>/dev/null || true

  # 1) 停服（会终结寄生其中的 agent turn —— 预期行为）
  stop_server "$alog"

  # 2) 换装真实前缀
  if ! install_dsh "$REAL_PREFIX" "$TARGET" "$alog"; then
    status="failed"
    body=$'## 换装失败\n\n`npm install` 返回非零，服务保持停止。人工回退：\n\n    npm install -g --prefix '"$REAL_PREFIX"' @deepseek-ai/dsh@'"$FALLBACK"$'\n    bash '"$LAUNCHER"$'\n'
    emit_report "$report" "$status" "$body"
    printf 'failed\n' >"$NOTES_DIR/upgrade-$TARGET-STATUS"
    return 1
  fi
  ver="$("$REAL_PREFIX/bin/dsh" --version 2>/dev/null)"
  log "[activate] 实装版本: $ver"

  # 3) 实验包对齐 + 提速补丁
  bump_experimental "$REAL_HOME" "$REAL_PREFIX/bin/dsh" "$TARGET" "$alog"
  local bumpnote=""
  [[ "$BUMP_FAILS" -ne 0 ]] && bumpnote="失败 $BUMP_FAILS 个（Agent Teams 仍为旧版，见日志）"
  if [[ -f "$SPEEDUP_PATCH" ]]; then
    bash "$SPEEDUP_PATCH" >>"$alog" 2>&1 || log "警告: 提速补丁应用失败（不阻断）"
  fi

  # 4) 起服并验证
  if ! start_server "$REAL_PREFIX/bin/dsh"; then
    status="failed"
    body=$'## 起服失败\n\n端口 '"$PORT"' 90s 未就绪。\n'
  else
    log "[activate] 端口就绪，等 ${SETTLE_SEC}s settle ..."
    sleep "$SETTLE_SEC"
    # 整段启动日志先落盘：启动器下次启动用 > 截断 web.log，不存就永久丢失（2026-09-15 教训）
    bootlog="$NOTES_DIR/upgrade-$TARGET-web-boot.log"
    tail -c "+$((WEB_OFFSET + 1))" "$REAL_HOME/web.log" >"$bootlog" 2>/dev/null || true
    errs=$(scan_errors "$REAL_HOME/web.log" "$WEB_OFFSET" | wc -l)
    if [[ "$errs" -ne 0 ]]; then
      { printf '# 匹配到的失败行（含前后 3 行上下文）\n# 本次启动的完整日志: %s\n\n' "$bootlog"
        grep -nE -B3 -A3 "$SCAN_RE" "$bootlog" || true
        printf '\n# 判读：若是插件树激活/加载失败（plugin tree failed to load / did not activate /\n# pending (waiting for service: …) / does not provide an export named），按插件侧坑表处置；\n# 若是 MCP/npx/子进程的普通 Node 报错，属非激活噪声，可据实重跑 --activate（探测已 PASS）。\n'
      } >"$NOTES_DIR/upgrade-$TARGET-activation-failures.log"
      log "[activate] $errs 条失败原文（含上下文）已另存: $NOTES_DIR/upgrade-$TARGET-activation-failures.log"
    else
      # 本次没有失败原文：删掉上一轮的，避免"先读这个文件"读到陈旧证据
      rm -f "$NOTES_DIR/upgrade-$TARGET-activation-failures.log"
    fi
    dump_config "$REAL_HOME" "$REAL_PREFIX/bin/dsh" "$dumpfile" "$alog"
    miss=$(missing_markers "$dumpfile")
    code=$(http_code "$PORT")
    body="$(printf '## 验证\n\n| 检查 | 结果 |\n|---|---|\n| 实装版本 | `%s` |\n| 端口 %s HTTP | %s |\n| 启动日志激活失败条数 | %s |\n| dump-config 缺失层 | %s |\n| 实验包对齐 | %s |\n' \
      "$ver" "$PORT" "$code" "$errs" "${miss:-无}" "${bumpnote:-全部对齐}")"
    [[ "$errs" -ne 0 ]] && body="$body"$'\n\n失败原文（含上下文）：`'"$NOTES_DIR/upgrade-$TARGET-activation-failures.log"$'`；本次启动完整日志：`'"$bootlog"$'`\n'
    if [[ "$ver" != "$TARGET" || "$errs" -ne 0 || -n "$miss" || "$code" == "000" || -z "$code" ]]; then
      status="failed"
    fi
  fi

  # 5) 失败回滚
  if [[ "$status" != "success" ]]; then
    log "[activate] 验证未通过 → 回滚到 $FALLBACK"
    stop_server "$alog"
    if install_dsh "$REAL_PREFIX" "$FALLBACK" "$alog" \
      && [[ "$("$REAL_PREFIX/bin/dsh" --version 2>/dev/null)" == "$FALLBACK" ]]; then
      bump_experimental "$REAL_HOME" "$REAL_PREFIX/bin/dsh" "$FALLBACK" "$alog"
      if start_server "$REAL_PREFIX/bin/dsh"; then
        status="rolled_back"
        body="$body"$'\n\n## 回滚\n\n已回滚到 `'"$FALLBACK"$'` 并重启成功（端口 '"$PORT"$' 已就绪）。\n\n**注意**：若 '"$TARGET"$' 已打开过真实会话，可能产生新代际会话文件；升级前全量备份是彻底还原点。\n'
      else
        status="failed"
        body="$body"$'\n\n## 回滚\n\n回滚后端口仍未就绪，需人工介入：`bash '"$LAUNCHER"$' --status`。\n'
      fi
    else
      status="failed"
      body="$body"$'\n\n## 回滚\n\n回滚换装失败，需人工介入。\n'
    fi
  else
    # 成功的收尾信息
    if [[ -f "$SKILL_VERIFY" ]]; then
      bash "$SKILL_VERIFY" >"$NOTES_DIR/upgrade-$TARGET-verify-sh.out" 2>&1 || true
      body="$body"$'\n\n技能自校验已写入 `'"$NOTES_DIR/upgrade-$TARGET-verify-sh.out"$'`（版本锚点必然报 `[DRIFT]`）。\n'
    fi
    body="$body"$'\n\n## 后续收尾（建议在会话恢复后做）\n\n1. 刷新 `http://127.0.0.1:'"$PORT"$'/`（30 天 trust cookie 仍在，无需 token）；\n2. 按 verify.sh 输出把 `SKILL.md` 与 `scripts/verify.sh` 的版本锚点从 `'"$FALLBACK"$'` 修订到 `'"$TARGET"$'`；\n3. 更新 `~/.ai/WORKING.md` 与 `~/.dsh/notes/REINSTALL-INVENTORY.md` 的版本记录。\n'
  fi

  emit_report "$report" "$status" "$body"
  printf '%s\n' "$status" >"$NOTES_DIR/upgrade-$TARGET-STATUS"
  log "[activate] 结论: $status，报告: $report"
  [[ "$status" == "success" || "$status" == "rolled_back" ]]
}

# ------------------------------------------------------------------ main ----
ACTION=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --probe)    ACTION="probe" ;;
    --activate) ACTION="activate" ;;
    --target)   TARGET="${2:-}"; shift ;;
    --fallback) FALLBACK="${2:-}"; shift ;;
    --grace)    GRACE="${2:-45}"; shift ;;
    --force)    FORCE=1 ;;
    -h|--help)  usage; exit 0 ;;
    *) printf '未知参数: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

[[ -n "$TARGET" ]] || { echo "缺少 --target <版本>"; usage >&2; exit 2; }
mkdir -p "$NOTES_DIR" "$BACKUP_ROOT"

case "$ACTION" in
  probe)
    probe ;;
  activate)
    [[ -n "$FALLBACK" ]] || { echo "--activate 需要 --fallback <当前版本>"; exit 2; }
    activate ;;
  *)
    usage; exit 2 ;;
esac
