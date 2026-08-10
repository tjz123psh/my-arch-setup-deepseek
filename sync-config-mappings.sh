#!/usr/bin/env bash
# sync-config-mappings.sh — 为 config/home 下新增文件自动生成 config-mappings.tsv 行。
#
# 用法:
#   ./sync-config-mappings.sh [--module <模块>] [路径...]
#     --module  对"没有既有映射可继承"的新目录使用的默认模块（缺省 desktop-shared）
#     路径      只处理指定文件/目录（缺省扫描 config/home 全部）
#
# 规则（与 07-config / reconciliation 对齐）:
#   - 只处理 config/home/（config/etc 由脚本直接部署，不走映射）
#   - source = 相对仓库根（config/home/...）；target = 去掉 config/home/ 前缀
#     （.config/...、.local/bin/...、md/...）
#   - mode = 可执行 755，否则 644
#   - module = 继承最近祖先目录的既有映射 module；没有则用 --module
#   - 已映射的文件跳过（幂等）
#   - 追加后由 check-extend 的 reconcile 自动验证
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cd "$root"

MANIFEST="manifests/config-mappings.tsv"
DEFAULT_MODULE="desktop-shared"
paths=()

while (( $# > 0 )); do
  case "$1" in
    --module) DEFAULT_MODULE="$2"; shift 2 ;;
    -h|--help) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) paths+=("$1"); shift ;;
  esac
done

# 已映射的 source 集合
declare -A mapped
while IFS=$'\t' read -r _ _ src _ _; do
  [[ -n "$src" ]] && mapped["$src"]=1
done < <(grep -v '^#' "$MANIFEST")

# 每个已映射行的 source 目录 -> module（首个为准，供新文件继承）
declare -A dir_module
while IFS=$'\t' read -r _ mod src _ _; do
  [[ -n "$src" ]] || continue
  d="$(dirname "$src")"
  [[ -z "${dir_module[$d]:-}" ]] && dir_module["$d"]="$mod"
done < <(grep -v '^#' "$MANIFEST")

# 收集待处理文件
mapfile -t files < <(
  if (( ${#paths[@]} > 0 )); then
    for p in "${paths[@]}"; do find "$p" -type f 2>/dev/null; done
  else
    find config/home -type f
  fi | sort -u
)

added=0
for f in "${files[@]}"; do
  [[ "$f" == config/etc/* ]] && continue
  [[ -n "${mapped[$f]:-}" ]] && continue
  tgt="${f#config/home/}"
  if [[ -x "$f" ]]; then mode=755; else mode=644; fi
  mod="$DEFAULT_MODULE"
  d="$(dirname "$f")"
  while [[ "$d" != "." && "$d" != "/" ]]; do
    if [[ -n "${dir_module[$d]:-}" ]]; then mod="${dir_module[$d]}"; break; fi
    d="$(dirname "$d")"
  done
  printf 'physical-v1\t%s\t%s\t%s\t%s\n' "$mod" "$f" "$tgt" "$mode" >> "$MANIFEST"
  echo "  + $f  (module=$mod, $mode)"
  added=$((added + 1))
done
echo "新增映射行: $added（已映射的自动跳过）"
