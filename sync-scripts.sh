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
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${HOME}/scripts"
DEST="${REPO_DIR}/config/home/scripts"
MAPPINGS="${REPO_DIR}/manifests/config-mappings.tsv"

[[ -d "${SRC}" ]] || { echo "source not found: ${SRC}"; exit 1; }
mkdir -p "${DEST}"

echo "== 1/3 同步 ${SRC} -> ${DEST} =="
if command -v rsync >/dev/null 2>&1; then
  rsync -a --delete --exclude='.git' "${SRC}/" "${DEST}/"
else
  # no rsync: tar pipe, excluding .git (no delete semantics)
  tar -C "${SRC}" --exclude='.git' -cf - . | tar -C "${DEST}" -xf -
fi
echo "  done"

echo
echo "== 2/3 检查并补全映射遗漏 =="
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
echo "== 3/3 git 状态（请人工确认后提交）=="
git -C "${REPO_DIR}" status --short config/home/scripts manifests/config-mappings.tsv
echo
echo "提交建议："
echo "  cd ${REPO_DIR} && git add config/home/scripts manifests/config-mappings.tsv && git commit && git push"
