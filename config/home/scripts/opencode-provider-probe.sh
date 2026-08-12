#!/usr/bin/env bash
# 探测 opencode 各供应商可用性，并让每个可用模型返回书目信息（JSON 书单）。
# 用法:
#   opencode-provider-probe.sh              # 每个 provider 测第一个文本模型
#   opencode-provider-probe.sh --all        # 测该 provider 配置的所有文本模型
# 不读取、不输出任何凭据，只通过 opencode CLI 发请求。
set -uo pipefail

ALL=0
for arg in "$@"; do
  case "$arg" in
    --all) ALL=1 ;;
    *) echo "未知参数: $arg（支持 --all）" >&2; exit 2 ;;
  esac
done

config_file="${OPENCODE_CONFIG_DIR:-$HOME/.config/opencode}/opencode.json"
if [[ ! -f "$config_file" ]]; then
  echo "找不到 opencode 配置: $config_file" >&2
  exit 1
fi

PROMPT='请用中文回答。列出 5 本你推荐的科幻小说，用 JSON 数组返回，每个元素包含 title（书名）、author（作者）、year（出版年份）、summary（一句话简介）。只输出 JSON 数组，不要输出任何其他文字。'

# 从配置读取每个 provider 的模型清单（兼容字符串和对象两种写法）
providers=()
mapfile -t providers < <(jq -r '.provider | to_entries[] | select((.value.models // []) | length > 0) | .key' "$config_file")

fail=0
pass=0
echo "=============================================="
echo "opencode 供应商探测（$([ "$ALL" -eq 1 ] && echo 全部模型 || echo 每个 provider 首模型)）"
echo "=============================================="
echo

for p in "${providers[@]}"; do
  models=()
  # models 是对象，key 即模型 id；name 只是显示名，不可用作调用 ID。
  mapfile -t models < <(jq -r --arg p "$p" '.provider[$p].models? | if type == "object" then keys[] else empty end' "$config_file")
  [[ ${#models[@]} -eq 0 ]] && continue

  if [[ "$ALL" -eq 1 ]]; then
    sel=("${models[@]}")
  else
    sel=("${models[0]}")
  fi

  for m in "${sel[@]}"; do
    model="$p/$m"
    printf '▶ %-22s ... ' "$model"
    out="$(mktemp "${TMPDIR:-/tmp}/probe.XXXXXX.out")"
    err="$(mktemp "${TMPDIR:-/tmp}/probe.XXXXXX.err")"
    start=$(date +%s)
    if timeout 90 opencode run --model "$model" "$PROMPT" >"$out" 2>"$err"; then
      rc=0
    else
      rc=$?
    fi
    end=$(date +%s)
    el=$((end - start))

    if [[ $rc -eq 0 && -s "$out" ]]; then
      pass=$((pass + 1))
      echo "✅ OK   (${el}s)"
      # 只清理 opencode 的启动横幅/空行和 ANSI 转义，保留模型内容（含缩进 JSON）
      body="$(sed -e 's/\x1b\[[0-9;]*m//g' -e '/^> build ·/d' -e '/^Trying/d' "$out" | sed '/^\s*$/d')"
      echo "$body" | head -c 1500
      echo
    else
      fail=$((fail + 1))
      echo "❌ FAIL($rc) (${el}s)"
      if [[ -s "$err" ]]; then
        echo "  stderr: $(head -c 400 "$err")"
      fi
    fi
    echo
    rm -f "$out" "$err"
  done
done

echo "=============================================="
echo "结果: $pass 可用 / $fail 失败 / 共 $((pass + fail)) 次请求"
echo "=============================================="
[[ $fail -gt 0 ]] && exit 1
exit 0
