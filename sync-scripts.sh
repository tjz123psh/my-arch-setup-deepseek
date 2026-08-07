#!/usr/bin/env bash
# sync-scripts.sh - keep the operator's ~/scripts in sync with the repo and
# make sure every file is listed in config-mappings.tsv.
#
# 07-config deploys ONLY what config-mappings.tsv lists, so a file that
# exists in config/home/scripts/ without a mapping row silently never gets
# installed. This tool (run on the host):
#   1. mirrors ~/scripts -> config/home/scripts/ (excluding any .git)
#   2. appends mapping rows for any file missing from config-mappings.tsv
#      (mode 755 if executable, else 644)
#   3. shows the resulting git status for a manual commit
#
# SAFETY (M-10): the default is a read-only PLAN. Nothing is written unless
# --apply is given. A secret scan runs on every file that would be written;
# files containing credential assignments are skipped with a warning.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${HOME}/scripts"
DEST="${REPO_DIR}/config/home/scripts"
MAPPINGS="${REPO_DIR}/manifests/config-mappings.tsv"
APPLY=false

for arg in "$@"; do
  case "$arg" in
    --apply) APPLY=true ;;
    --plan) APPLY=false ;;
    -h|--help) echo "usage: sync-scripts.sh [--plan|--apply]"; exit 0 ;;
    *) echo "unknown argument: $arg (--plan default, --apply to write)"; exit 1 ;;
  esac
done

[[ -d "${SRC}" ]] || { echo "source not found: ${SRC}"; exit 1; }
mkdir -p "${DEST}"

echo "== 1/3 同步计划 ${SRC} -> ${DEST} =="
# Compute what rsync would do without touching anything.
if command -v rsync >/dev/null 2>&1; then
  rsync -a --dry-run --delete --exclude='.git' "${SRC}/" "${DEST}/" \
    | grep -vE '^sending incremental|^$|^sent |^total size' || true
else
  echo "  (rsync not available; plan mode only shows existing diffs)"
fi

echo
echo "== 2/3 secret gate（计划写入的文件）=="
blocked=0
while IFS= read -r f; do
  rel="${f#"${DEST}"/}"
  # files that already exist unchanged are not at risk
  if [[ -f "${f}" ]] && [[ "$(sha256sum "${f}" | cut -c1-16)" == "$(sha256sum "${SRC}/${rel}" | cut -c1-16)" ]]; then
    continue
  fi
  if grep -qE '(api[_-]?key|token|secret|password|passwd)[[:space:]]*=[[:space:]]*["'"'"'][A-Za-z0-9_\-]{8,}' "${SRC}/${rel}" 2>/dev/null; then
    echo "  [跳过-疑似凭据] ${rel}"
    blocked=$((blocked + 1))
  fi
done < <(find "${SRC}" -type f | sort | sed "s|^${SRC}/|${DEST}/|")
echo "  凭据拦截 ${blocked} 个文件"

echo
echo "== 3/3 映射差异（计划） =="
added=0
while IFS= read -r f; do
  rel="${f#"${DEST}"/}"
  if ! grep -qF "config/home/scripts/${rel}" "${MAPPINGS}"; then
    if [[ -x "${f}" ]]; then mode="755"; else mode="644"; fi
    echo "  [将新增映射] ${rel} (${mode})"
    added=$((added + 1))
  fi
done < <(find "${DEST}" -type f | sort)
echo "  计划新增映射 ${added} 行"

if [[ "${APPLY}" != "true" ]]; then
  echo
  echo "PLAN ONLY - 未做任何修改。确认后运行：sync-scripts.sh --apply"
  exit 0
fi

echo
echo "== 执行同步（--apply）=="
if command -v rsync >/dev/null 2>&1; then
  rsync -a --delete --exclude='.git' "${SRC}/" "${DEST}/"
else
  tar -C "${SRC}" --exclude='.git' -cf - . | tar -C "${DEST}" -xf -
fi
echo "  done"

echo
echo "== 补全映射 =="
added=0
while IFS= read -r f; do
  rel="${f#"${DEST}"/}"
  if ! grep -qF "config/home/scripts/${rel}" "${MAPPINGS}"; then
    if [[ -x "${f}" ]]; then mode="755"; else mode="644"; fi
    printf 'physical-v1\tmaintenance\tconfig/home/scripts/%s\tscripts/%s\t%s\n' "${rel}" "${rel}" "${mode}" >> "${MAPPINGS}"
    echo "  [补充映射] ${rel} (${mode})"
    added=$((added + 1))
  fi
done < <(find "${DEST}" -type f | sort)
echo "  新增映射 ${added} 行"

echo
echo "== git 状态（请人工确认后提交）=="
git -C "${REPO_DIR}" status --short config/home/scripts manifests/config-mappings.tsv
echo
echo "提交建议："
echo "  cd ${REPO_DIR} && git add config/home/scripts manifests/config-mappings.tsv && git commit && git push"
