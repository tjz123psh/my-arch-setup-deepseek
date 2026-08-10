#!/usr/bin/env bash
# validate-config-syntax.sh — 静态校验 config/ 载荷里每个文本文件的语法。
#
# 按扩展名/路径分派校验器；缺校验工具的文件记 SKIP（不失败但列出，需人工复核）；
# 无可用校验器的类型记 MANUAL（不失败，仅计数/列出）。任何 FAIL 使退出码非零。
#
# 用法:
#   tests/validate-config-syntax.sh [--verbose]
#   check-extend.sh 会直接调用本脚本
#
# 分派表（扩展名 -> 校验器）：
#   lua       -> luac -p（无 luac 时退 luajit -bl）
#   json      -> jq empty
#   toml      -> python3 tomllib
#   yaml/yml  -> python3 PyYAML（无 PyYAML 记 SKIP）
#   fish      -> fish -n
#   sh        -> bash -n
#   desktop   -> desktop-file-validate
#   service/timer/socket/path -> systemd-analyze verify
#   kdl       -> niri validate -c
#   qml       -> qmllint（无则 python 结构配平：括号/引号/注释）
#   ini       -> python3 configparser（strict=False）
#   .gitconfig-> git config --file --list
#   无扩展名   -> 按 shebang 分派 sh/python，否则 MANUAL
#   其余（qml/css/conf/menu/list 等）-> MANUAL
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
config_dir="$root/config"

verbose=0
[[ "${1:-}" == "--verbose" ]] && verbose=1

pass=0; fail=0; skip=0; manual=0; asset=0
declare -a failures=() skipped=() manual_files=()

have() { command -v "$1" >/dev/null 2>&1; }

note_fail()   { fail=$((fail+1)); failures+=("$1"); }
note_skip()   { skip=$((skip+1)); skipped+=("$1"); }
note_manual() { manual=$((manual+1)); manual_files+=("$1"); }

# type_of <file> -> 输出类型名（lua/json/toml/yaml/fish/sh/python/desktop/systemd/kdl/ini/gitconfig/manual）
type_of() {
  local f="$1" base ext real
  base=$(basename "$f")
  real="$base"
  if [[ "$base" == *.example ]]; then real="${base%.example}"; fi
  ext="${real##*.}"
  case "$base" in
    mimeapps.list)      echo ini; return ;;
    .gitconfig)         echo gitconfig; return ;;
    user-dirs.dirs|user-dirs.locale|ignore|profile|keybinds.list) echo manual; return ;;
  esac
  case "$ext" in
    lua)      echo lua; return ;;
    json)     echo json; return ;;
    toml)     echo toml; return ;;
    yaml|yml) echo yaml; return ;;
    fish)     echo fish; return ;;
    sh)       echo sh; return ;;
    desktop)  echo desktop; return ;;
    service|timer|socket|path) echo systemd; return ;;
    kdl)      echo kdl; return ;;
    qml)      echo qml; return ;;
    ini)      echo ini; return ;;
  esac
  # 有扩展名但类型未知 -> 手工
  if [[ "$real" == *.* && "$ext" != "$real" ]]; then
    echo manual; return
  fi
  # 无扩展名：按 shebang 分派
  local head
  head=$(head -c 80 "$f" 2>/dev/null | tr -d '\0')
  if [[ "$head" == \#!* ]]; then
    if [[ "$head" == *bash* || "$head" == */sh* ]]; then echo sh; return; fi
    if [[ "$head" == *python* ]]; then echo python; return; fi
  fi
  echo manual
}

# validate_type <file> <type>
validate_type() {
  local f="$1" t="$2" rc=0
  case "$t" in
    lua)
      if have luac; then
        if ! luac -p "$f" >/dev/null 2>&1; then rc=1; fi
      elif have luajit; then
        if ! luajit -bl "$f" >/dev/null 2>&1; then rc=1; fi
      else note_skip "$f (lua: luac/luajit 缺失)"; return; fi
      ;;
    json)
      if have jq; then
        if ! jq empty "$f" >/dev/null 2>&1; then rc=1; fi
      else note_skip "$f (json: jq 缺失)"; return; fi
      ;;
    toml)
      if have python3; then
        if ! python3 -c 'import sys,tomllib; tomllib.load(open(sys.argv[1],"rb"))' "$f" >/dev/null 2>&1; then rc=1; fi
      else note_skip "$f (toml: python3 缺失)"; return; fi
      ;;
    yaml)
      if ! have python3; then note_skip "$f (yaml: python3 缺失)"; return; fi
      if [[ -z "${PY_YAML_OK:-}" ]]; then
        if python3 -c 'import yaml' >/dev/null 2>&1; then PY_YAML_OK=1; else PY_YAML_OK=0; fi
      fi
      if (( PY_YAML_OK )); then
        if ! python3 -c 'import sys,yaml; yaml.safe_load(open(sys.argv[1],encoding="utf-8"))' "$f" >/dev/null 2>&1; then rc=1; fi
      else note_skip "$f (yaml: PyYAML 缺失)"; return; fi
      ;;
    fish)
      if have fish; then
        if ! fish -n "$f" >/dev/null 2>&1; then rc=1; fi
      else note_skip "$f (fish: fish 缺失)"; return; fi
      ;;
    sh)
      if ! bash -n "$f" >/dev/null 2>&1; then rc=1; fi
      ;;
    python)
      if have python3; then
        if ! python3 -c 'import ast,sys; ast.parse(open(sys.argv[1],encoding="utf-8").read())' "$f" >/dev/null 2>&1; then rc=1; fi
      else note_skip "$f (python: python3 缺失)"; return; fi
      ;;
    desktop)
      if have desktop-file-validate; then
        if ! desktop-file-validate "$f" >/dev/null 2>&1; then rc=1; fi
      else note_skip "$f (desktop: desktop-file-validate 缺失)"; return; fi
      ;;
    systemd)
      if have systemd-analyze; then
        if ! systemd-analyze verify "$f" >/dev/null 2>&1; then rc=1; fi
      else note_skip "$f (systemd: systemd-analyze 缺失)"; return; fi
      ;;
    kdl)
      if have niri; then
        if ! niri validate -c "$f" >/dev/null 2>&1; then rc=1; fi
      else note_skip "$f (kdl: niri 缺失)"; return; fi
      ;;
    qml)
      if have qmllint; then
        if ! qmllint "$f" >/dev/null 2>&1; then rc=1; fi
      elif have python3; then
        # 结构配平：括号/方括号/花括号成对、字符串与注释闭合。
        # 能抓 DMS 插件这类"改坏括号/漏引号"的常见错误；语义错误仍需真机实测。
        if ! python3 -c '
import sys
src = open(sys.argv[1], encoding="utf-8").read()
stack, pairs = [], {")": "(", "]": "[", "}": "{"}
i, n, line, pc = 0, len(src), 1, ""
in_str = in_line = in_block = None
while i < n:
    c = src[i]
    if in_line:
        if c == "\n": in_line = False; line += 1
        i += 1; continue
    if in_block:
        if c == "*" and i + 1 < n and src[i+1] == "/": in_block = False; i += 2
        else: i += 1
        continue
    if in_str:
        if c == "\\": i += 2; continue
        if c == in_str: in_str = None
        i += 1; continue
    if c == "\n": line += 1; i += 1; continue
    # 注释判定：前一字符是反斜杠时不当作注释（正则里的转义斜杠 \/\/ 会伪造 // 与 /*）
    if pc != "\\" and c == "/" and i + 1 < n and src[i+1] == "/": in_line = True; i += 2; continue
    if pc != "\\" and c == "/" and i + 1 < n and src[i+1] == "*": in_block = True; i += 2; continue
    if c in "\x27\"`": in_str = c; i += 1; continue
    if c in "([{": stack.append((c, line)); i += 1; continue
    if c in ")]}":
        if not stack or stack[-1][0] != pairs[c]:
            print(f"QML 结构: line {line} 的 {c!r} 不匹配", file=sys.stderr); sys.exit(1)
        stack.pop(); i += 1; continue
    pc = c
    i += 1
if in_str:  print("QML 结构: 未闭合字符串", file=sys.stderr); sys.exit(1)
if in_block: print("QML 结构: 未闭合块注释", file=sys.stderr); sys.exit(1)
if stack:
    c, l = stack[-1]
    print(f"QML 结构: 未闭合 {c!r}（开于 line {l}）", file=sys.stderr); sys.exit(1)
' "$f" >/dev/null 2>&1; then rc=1; fi
      else note_skip "$f (qml: qmllint/python3 缺失)"; return; fi
      ;;
    ini)
      if have python3; then
        if ! python3 -c '
import sys, configparser, re
p = configparser.ConfigParser(strict=False)
try:
    p.read(sys.argv[1], encoding="utf-8")
except configparser.MissingSectionHeaderError:
    # fuzzel 等无 section 头的 key=value 配置：逐行宽松检查
    for i, line in enumerate(open(sys.argv[1], encoding="utf-8"), 1):
        s = line.strip()
        if not s or s.startswith("#") or s.startswith(";"):
            continue
        if not re.match(r"^[^=\s]+(?:=.*)?$", s):
            raise SystemExit(f"INI lenient: line {i}: {s!r}")
' "$f" >/dev/null 2>&1; then rc=1; fi
      else note_skip "$f (ini: python3 缺失)"; return; fi
      ;;
    gitconfig)
      if have git; then
        if ! git config --file "$f" --list >/dev/null 2>&1; then rc=1; fi
      else note_skip "$f (gitconfig: git 缺失)"; return; fi
      ;;
    manual|*)
      note_manual "$f"; return
      ;;
  esac
  if (( rc == 0 )); then
    pass=$((pass+1))
    if [[ $verbose == 1 ]]; then echo "  ok   $f"; fi
  else
    note_fail "$f"
  fi
}

check_file() {
  local f="$1" t
  # 二进制/空文件（含字体、图片等资产）直接跳过
  if ! LC_ALL=C grep -Iq . "$f" 2>/dev/null; then
    asset=$((asset+1)); return
  fi
  t=$(type_of "$f")
  validate_type "$f" "$t"
}

while IFS= read -r -d '' f; do
  check_file "$f"
done < <(find "$config_dir" -type f -print0 2>/dev/null)

echo "config syntax: PASS=$pass FAIL=$fail SKIP=$skip MANUAL=$manual ASSET=$asset"

if (( fail > 0 )); then
  echo "--- FAILURES ---"
  printf '  %s\n' "${failures[@]}"
fi
if (( skip > 0 )); then
  echo "--- SKIPPED（工具缺失，需人工复核）---"
  printf '  %s\n' "${skipped[@]}"
fi
if [[ $verbose == 1 && $manual -gt 0 ]]; then
  echo "--- MANUAL（无自动校验器）---"
  printf '  %s\n' "${manual_files[@]}"
fi

(( fail == 0 ))
