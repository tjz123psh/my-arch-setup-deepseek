#!/usr/bin/env bash
# patch-upstream-client-modules-speedup.sh
#
# 修掉上游 @deepseek-ai/dsh-client-modules 里两个热点函数的写法，缩短 dsh web 启动时间。
#
# 背景（2026-09-14 实测，dsh 0.1.5-rc.2）：
#   启动 CPU 的 ~57% 花在组合客户端模块包（buildCombo / identitySectionMap /
#   newlineCount）。其中两处写法代价极高：
#     1) `for (const char of value)` 按**码点**迭代整个字符串（每字符一个字符串对象）；
#     2) `Array.from({length: n}, ...).join(";")` 为**每一行**先建一个字符串再 join。
#   本机客户端模块明文合计约 15MB（单是 dsh 自带的
#   dsh-client-ui-sidebar-documentpreview/lib/client.js 就 6.57MB），每次都全量重算。
#
# 效果（实测，同一台机器、同一份插件集）：
#   启动到就绪 8.13s/8.16s → 5.87s/5.99s（约 -2.2s，-27%）
#
# 等价性（关键，已证明）：
#   组合产物的 `rev` 是 bundle + sourcemap 内容的哈希。补丁前后浏览器请求的 combo
#   都是 `rev=6ed00f8c2f79`、59 个模块、解码后约 14.9MB ⇒ 组合与 sourcemap **逐字节一致**。
#   脚本另带合成用例自测（空串/单行/多行/中文/\r\n/连续空行）。
#
# 注意：这是对**第三方依赖**的本地补丁，`npm install` 重装 dsh 会覆盖掉。
#   → 每次重装/升级 dsh 后重跑本脚本即可（幂等）。
#   技能 dsh-upgrade 的 scripts/verify.sh 会检查它是否在位。
#
# 用法:
#   patch-upstream-client-modules-speedup.sh            # 应用（幂等）
#   patch-upstream-client-modules-speedup.sh --check     # 只看状态，不改动
#   patch-upstream-client-modules-speedup.sh --revert    # 还原成上游原样
set -uo pipefail

MARK='/* dsh-speedup-patch */'
ORIG_COUNT='	for (const char of value) if (char === "\n") count += 1;'
NEW_COUNT="	${MARK}
	for (let index = 0; index < value.length; index += 1) if (value.charCodeAt(index) === 10) count += 1;"
ORIG_MAP='	const mappings = Array.from({ length: newlineCount(source) }, (_, index) => index === 0 ? "AAAA" : "AACA").join(";");'
NEW_MAP="	${MARK}
	const lineCount = newlineCount(source);
	const mappings = lineCount === 0 ? \"\" : lineCount === 1 ? \"AAAA\" : \`AAAA\${';AACA'.repeat(lineCount - 1)}\`;"

usage() { sed -n '3,32p' "$0" | sed 's/^# \{0,1\}//'; }

# 定位文件：由 dsh 可执行入口反推包根，再进嵌套依赖
resolve_target() {
  local bin pkg
  bin=$(readlink -f "$HOME/.npm-global/bin/dsh" 2>/dev/null) || return 1
  [[ -n "$bin" ]] || return 1
  pkg=$(dirname "$(dirname "$bin")")
  printf '%s' "$pkg/node_modules/@deepseek-ai/dsh-client-modules/lib/index.js"
}

self_test() {
  node -e '
    const oldCount=(v)=>{let c=0;for(const ch of v) if(ch==="\n") c+=1;return c};
    const oldMap=(s)=>Array.from({length:oldCount(s)},(_,i)=> i===0?"AAAA":"AACA").join(";");
    const newCount=(v)=>{let c=0;for(let i=0;i<v.length;i+=1) if(v.charCodeAt(i)===10) c+=1;return c};
    const newMap=(s)=>{const n=newCount(s);return n===0?"":n===1?"AAAA":`AAAA${";AACA".repeat(n-1)}`};
    const cases=["","a","a\n","a\nb","a\nb\n","a\nb\nc\n\n","\n".repeat(50),"中文\n多行\r\n混合\ntext"];
    for(const c of cases){ if(oldMap(c)!==newMap(c)||oldCount(c)!==newCount(c)){ console.error("不符: "+JSON.stringify(c.slice(0,20))); process.exit(1);} }
  ' && return 0 || return 1
}

ACTION="apply"
case "${1:-}" in
  --check)  ACTION="check" ;;
  --revert) ACTION="revert" ;;
  -h|--help) usage; exit 0 ;;
  "") : ;;
  *) printf '未知参数: %s\n' "$1" >&2; usage >&2; exit 2 ;;
esac

TARGET=$(resolve_target) || { echo "错误: 找不到 dsh 安装（$HOME/.npm-global/bin/dsh）" >&2; exit 1; }
[[ -f "$TARGET" ]] || { echo "错误: 目标文件不存在: $TARGET" >&2; exit 1; }
BACKUP="$TARGET.orig-speedup"

state() {
  if grep -qF "$MARK" "$TARGET"; then echo patched
  elif grep -qF "$ORIG_COUNT" "$TARGET" && grep -qF "$ORIG_MAP" "$TARGET"; then echo pristine
  else echo unknown; fi
}

case "$ACTION" in
  check)
    case "$(state)" in
      patched)  echo "已应用补丁: $TARGET" ;;
      pristine) echo "未应用（上游原样）: $TARGET" ;;
      *)        echo "状态未知（上游代码已变）: $TARGET" ;;
    esac
    exit 0 ;;
  revert)
    [[ -f "$BACKUP" ]] || { echo "没有备份可还原: $BACKUP" >&2; exit 1; }
    cp -a "$BACKUP" "$TARGET"
    echo "已还原成上游原样: $TARGET"
    exit 0 ;;
esac

case "$(state)" in
  patched)
    echo "已经是打过补丁的状态，无需重复应用。"
    exit 0 ;;
  unknown)
    echo "错误: 目标文件既不是上游原样、也没有补丁标记——上游实现可能已变。" >&2
    echo "      请重新核对 dsh-client-modules 的 newlineCount / identitySectionMap 再更新本脚本。" >&2
    exit 3 ;;
esac

# 前置：替换目标必须各恰好出现一次
count_of() { grep -cF "$1" "$TARGET" || true; }
if [[ "$(count_of "$ORIG_COUNT")" != "1" || "$(count_of "$ORIG_MAP")" != "1" ]]; then
  echo "错误: 待替换片段出现次数异常（期望各 1 次），中止以免改错。" >&2
  exit 3
fi

[[ -f "$BACKUP" ]] || cp -a "$TARGET" "$BACKUP"
echo "备份: $BACKUP"

python3 - "$TARGET" "$ORIG_COUNT" "$NEW_COUNT" "$ORIG_MAP" "$NEW_MAP" <<'PY'
import sys
path, oc, nc, om, nm = sys.argv[1:6]
src = open(path, encoding='utf-8').read()
for old, new in ((oc, nc), (om, nm)):
    if src.count(old) != 1:
        print(f"错误: 片段出现 {src.count(old)} 次，中止", file=sys.stderr); sys.exit(3)
    src = src.replace(old, new, 1)
open(path, 'w', encoding='utf-8').write(src)
print("已写入两处替换")
PY
rc=$?
[[ $rc -ne 0 ]] && { echo "写入失败，请用 --revert 还原" >&2; exit $rc; }

if ! self_test; then
  echo "错误: 等价性自测未通过，自动还原" >&2
  cp -a "$BACKUP" "$TARGET"
  exit 4
fi
echo "等价性自测通过（空串/单行/多行/中文/\\r\\n/连续空行）"
echo "语法检查: $(node --check "$TARGET" 2>&1 | head -1 || true)"
echo
echo "完成。重启 dsh 生效：bash ~/scripts/dsh/dsh-web.sh --stop && bash ~/scripts/dsh/dsh-web.sh"
echo "（重装 dsh 后需重跑本脚本；--revert 可还原）"