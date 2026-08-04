#!/usr/bin/env bash
# 06-config.sh - deploy reviewed user config mappings.
# Reads manifests/config-mappings.tsv (reused asset): scope physical-v1 for
# physical machines, vm-v1 for VMs. Backs up any existing target first.
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=00-utils.sh
source "${SCRIPT_DIR}/00-utils.sh"

MAPPINGS="${PROJECT_DIR}/manifests/config-mappings.tsv"
CONFIG_SRC="${PROJECT_DIR}/config"
BACKUP_DIR="${HOME}/.config-backup-my-arch-$(date +%Y%m%d%H%M%S)"
SCOPE="${MACHINE_TYPE}-v1"   # physical-v1 or vm-v1

section "部署配置映射 (scope: ${SCOPE})"

[[ -f "${MAPPINGS}" ]] || die "缺少 ${MAPPINGS}"
mkdir -p "${BACKUP_DIR}"
log "备份目录: ${BACKUP_DIR}"

deployed=0 skipped=0
while IFS=$'\t' read -r scope _module src tgt mode; do
  [[ -z "${src}" || "${src}" == "#"* ]] && continue
  [[ "${scope}" != "${SCOPE}" ]] && continue

  local_src="${CONFIG_SRC}/${src#config/}"
  if [[ ! -f "${local_src}" ]]; then
    warn "源文件缺失: ${src}"; skipped=$((skipped + 1)); continue
  fi

  target="${HOME}/${tgt}"
  # backup existing target
  if [[ -e "${target}" ]] && [[ ! -L "${target}" ]]; then
    mkdir -p "${BACKUP_DIR}/$(dirname "${tgt}")"
    cp -a "${target}" "${BACKUP_DIR}/${tgt}" 2>/dev/null || true
  fi

  mkdir -p "$(dirname "${target}")"
  cp -a "${local_src}" "${target}"
  chmod "${mode}" "${target}" 2>/dev/null || true
  deployed=$((deployed + 1))
done < "${MAPPINGS}"

log "已部署: ${deployed} 个文件, 跳过: ${skipped} 个"
success "配置部署完成 (备份在 ${BACKUP_DIR})"
