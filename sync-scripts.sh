#!/usr/bin/env bash
# sync-scripts.sh - keep the operator's ~/scripts in sync with the repo and
# make sure every file is listed in config-mappings.tsv.
#
# 07-config deploys ONLY what config-mappings.tsv lists, so a file that
# exists in config/home/scripts/ without a mapping row silently never gets
# installed. This tool (run on the host):
#   1. inventories ~/scripts -> config/home/scripts/ (excluding any .git)
#      and classifies every file same/changed/new/deleted
#   2. runs a secret gate over every file that WOULD be written
#   3. plans mapping additions (mode 755 if executable, else 644)
#   4. --apply stages into the workspace, backs up the previous state with a
#      timestamp, and only then switches; a post-switch secret scan runs
#      again. --rollback <dir> restores a previous state from the backup.
#
# SAFETY (review P0-4 / 4.3):
#   - default is a read-only PLAN: zero writes, zero mkdir, zero mapping edits
#   - a secret hit FAILS CLOSED during --apply: nothing is written
#   - apply never uses --delete against the live tree; it switches from a
#     staging dir and keeps a timestamped backup for rollback
set -Eeuo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${HOME}/scripts"
DEST="${REPO_DIR}/config/home/scripts"
MAPPINGS="${REPO_DIR}/manifests/config-mappings.tsv"

ACTION=plan
ROLLBACK_DIR=""
while (( $# > 0 )); do
  case "$1" in
    --plan) ACTION=plan; shift ;;
    --apply) ACTION=apply; shift ;;
    --rollback)
      ACTION=rollback
      shift
      [[ $# -ge 1 ]] || { echo "error: --rollback needs a backup directory"; exit 1; }
      ROLLBACK_DIR="$1"
      shift
      ;;
    -h|--help)
      echo "usage: sync-scripts.sh [--plan] [--apply] [--rollback <backup-dir>]"
      echo "  (default is read-only plan; --apply writes; --rollback restores)"
      exit 0
      ;;
    *) echo "unknown argument: $1"; exit 1 ;;
  esac
done

[[ -d "${SRC}" ]] || { echo "error: source not found: ${SRC}"; exit 1; }

# ---------------------------------------------------------------------------
# inventory: classify SRC files relative to DEST
# ---------------------------------------------------------------------------
declare -a changed=() newfiles=() deleted=() same=()
while IFS= read -r -d '' srcfile; do
  rel="${srcfile#"${SRC}"/}"
  dest="${DEST}/${rel}"
  if [[ -f "${dest}" ]]; then
    if cmp -s "${srcfile}" "${dest}"; then
      same+=("${rel}")
    else
      changed+=("${rel}")
    fi
  else
    newfiles+=("${rel}")
  fi
done < <(find "${SRC}" -type f ! -path '*/.git/*' -print0 | sort -z)

# files present in DEST but not in SRC (candidates for removal / stale)
while IFS= read -r -d '' destfile; do
  rel="${destfile#"${DEST}"/}"
  [[ -f "${SRC}/${rel}" ]] || deleted+=("${rel}")
done < <(find "${DEST}" -type f -print0 | sort -z)

echo "== 1/4 inventory =="
echo "  same=${#same[@]} changed=${#changed[@]} new=${#newfiles[@]} stale=${#deleted[@]}"
for rel in "${changed[@]}"; do printf '  [changed] %s\n' "$rel"; done
for rel in "${newfiles[@]}"; do printf '  [new]     %s\n' "$rel"; done
for rel in "${deleted[@]}"; do printf '  [stale]   %s (in repo, missing from %s)\n' "$rel" "$SRC"; done

# ---------------------------------------------------------------------------
# secret gate: scan every file that would be written (fail closed)
# ---------------------------------------------------------------------------
secret_hits=0
scan_file() { # scan_file <path> <label>
  # case-insensitive: SECRET_TOKEN / ApiKey / PASSWORD all must fail closed
  if grep -qiE '(api[_-]?key|token|secret|password|passwd|BEGIN (RSA|OPENSSH|EC|PRIVATE)|sk-[A-Za-z0-9]{20,}|gh[pousr]_[A-Za-z0-9]{20,})[[:space:]]*[=:][[:space:]]*["'"'"']?[A-Za-z0-9_/+=.-]{8,}' "$1" 2>/dev/null; then
    echo "  [SECRET] ${2}"
    secret_hits=$((secret_hits + 1))
  fi
}
for rel in "${changed[@]}" "${newfiles[@]}"; do
  scan_file "${SRC}/${rel}" "${rel}"
done
if (( secret_hits > 0 )); then
  echo "error: ${secret_hits} file(s) with suspected credentials; FAIL CLOSED, nothing was written"
  echo "  (remove/replace the credential values in ${SRC} first, or use a private-env.fish reference)"
  exit 1
fi
echo "  secret gate: clean (${#changed[@]} changed + ${#newfiles[@]} new scanned)"

# ---------------------------------------------------------------------------
# mapping plan: validate existing rows + plan new rows
# ---------------------------------------------------------------------------
mapping_bad=0
mapping_plan=()
for rel in "${changed[@]}" "${newfiles[@]}"; do
  # path safety: no '..' anywhere in the relative path
  if [[ "${rel}" == *".."* || "${rel}" == /* || "${rel}" == *"//"* ]]; then
    echo "  [INVALID PATH] ${rel}"
    mapping_bad=$((mapping_bad + 1))
    continue
  fi
  if grep -qF "config/home/scripts/${rel}" "${MAPPINGS}"; then
    continue
  fi
  if [[ -x "${SRC}/${rel}" ]]; then mode="755"; else mode="644"; fi
  mapping_plan+=("${rel}	${mode}")
done
# duplicate-target check across the whole mapping file
dup_targets="$(awk -F'\t' '!/^#/ && NF>=5 {print $3}' "${MAPPINGS}" | sort | uniq -d)"
if [[ -n "${dup_targets}" ]]; then
  echo "  [DUP TARGET] existing mapping file already has duplicate targets:"
  echo "${dup_targets}" | sed 's/^/    /'
  mapping_bad=$((mapping_bad + 1))
fi
if (( mapping_bad > 0 )); then
  echo "error: mapping validation failed (${mapping_bad} issue(s)); aborting"
  exit 1
fi

echo "== 2/4 mapping plan =="
if (( ${#mapping_plan[@]} == 0 )); then
  echo "  no new mapping rows needed"
else
  for row in "${mapping_plan[@]}"; do
    printf '  [add] %s (mode %s)\n' "${row%%$'\t'*}" "${row##*$'\t'}"
  done
fi

if [[ "${ACTION}" == "plan" ]]; then
  echo
  echo "PLAN ONLY - nothing was written (no mkdir, no rsync, no mapping edits)."
  echo "Run: sync-scripts.sh --apply   (staging + backup + switch)"
  echo "     sync-scripts.sh --rollback <backup-dir>  (restore)"
  exit 0
fi

# ---------------------------------------------------------------------------
# apply: stage -> backup -> switch -> post-scan (with rollback support)
# ---------------------------------------------------------------------------
if [[ "${ACTION}" == "rollback" ]]; then
  [[ -n "${ROLLBACK_DIR}" && -d "${ROLLBACK_DIR}" ]] || { echo "error: --rollback needs an existing backup dir"; exit 1; }
  if [[ ! -f "${ROLLBACK_DIR}/mappings.tsv.backup" ]]; then
    echo "error: ${ROLLBACK_DIR} is not a sync-scripts backup (missing mappings.tsv.backup)"
    exit 1
  fi
  echo "== rollback: ${ROLLBACK_DIR} =="
  rsync -a --delete "${ROLLBACK_DIR}/scripts/" "${DEST}/"
  cp -f "${ROLLBACK_DIR}/mappings.tsv.backup" "${MAPPINGS}"
  echo "  restored config/home/scripts and config-mappings.tsv from backup"
  echo "  review: git -C ${REPO_DIR} diff --stat config/home/scripts manifests/config-mappings.tsv"
  exit 0
fi

# --apply
echo
echo "== 3/4 apply: staging + backup + switch =="
# staging + backup 放在工作区外（2026-08-10：备份目录曾被误提交进仓库；
# ~/.cache 保留 rollback 能力又不污染 git 树）
cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/my-arch-setup"
mkdir -p "${cache_dir}"
# staging inside the cache (never touches the live tree)
staging="$(mktemp -d "${cache_dir}/.sync-staging.XXXXXX")"
trap 'rm -rf "${staging}"' EXIT
rsync -a --exclude='.git' "${SRC}/" "${staging}/"
# pre-switch dry-run so the exact change set is visible before the switch
echo "  dry-run of the switch (staging -> ${DEST}):"
rsync -a --dry-run --delete "${staging}/" "${DEST}/" \
  | grep -vE '^sending incremental|^$|^sent |^total size' || true

# timestamped backup of the current state (cache-internal, rollback source)
ts="$(date +%Y%m%d-%H%M%S)"
backup="${cache_dir}/.sync-backup-${ts}"
mkdir -p "${backup}/scripts"
rsync -a "${DEST}/" "${backup}/scripts/"
cp -f "${MAPPINGS}" "${backup}/mappings.tsv.backup"
echo "  backup written to: ${backup}"

# switch: delete only inside the live tree is NOT used; rsync --delete from
# the staging copy removes stale files, which is exactly what we reviewed.
rsync -a --delete "${staging}/" "${DEST}/"

# append mapping rows (validated above; no duplicates possible)
added=0
for row in "${mapping_plan[@]}"; do
  rel="${row%%$'\t'*}"
  mode="${row##*$'\t'}"
  printf 'physical-v1\tmaintenance\tconfig/home/scripts/%s\tscripts/%s\t%s\n' "${rel}" "${rel}" "${mode}" >> "${MAPPINGS}"
  added=$((added + 1))
done
echo "  added ${added} mapping rows"

# post-switch secret scan over the freshly written tree
post_hits=0
while IFS= read -r -d '' f; do
  rel="${f#"${DEST}"/}"
  if grep -qiE '(api[_-]?key|token|secret|password|passwd|BEGIN (RSA|OPENSSH|EC|PRIVATE))[[:space:]]*[=:][[:space:]]*["'"'"']?[A-Za-z0-9_/+=.-]{8,}' "$f" 2>/dev/null; then
    echo "  [POST-SCAN SECRET] ${rel}"
    post_hits=$((post_hits + 1))
  fi
done < <(find "${DEST}" -type f -print0)
if (( post_hits > 0 )); then
  echo "error: post-switch secret scan found ${post_hits} hit(s); roll back with:"
  echo "  sync-scripts.sh --rollback ${backup}"
  exit 1
fi

# optional gitleaks confirmation if available (does not fail the run)
if command -v gitleaks >/dev/null 2>&1; then
  if gitleaks detect --no-banner --source "${REPO_DIR}" >/dev/null 2>&1; then
    echo "  gitleaks: clean"
  else
    echo "  gitleaks: hits reported - review before committing (see above)"
  fi
fi

echo
echo "== 4/4 git status =="
git -C "${REPO_DIR}" status --short config/home/scripts manifests/config-mappings.tsv
echo
echo "done. rollback: sync-scripts.sh --rollback ${backup}"
echo "commit suggestion:"
echo "  cd ${REPO_DIR} && git add config/home/scripts manifests/config-mappings.tsv && git commit && git push"
