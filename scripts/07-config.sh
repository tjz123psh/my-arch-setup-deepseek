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
BACKUP_DIR="${TARGET_HOME}/.config-backup-my-arch-$(date +%Y%m%d%H%M%S)"
# Operator decision (2026-08-05): the VM restores the same full configuration
# as the physical machine (packages minus GPU drivers; config is identical).
# physical-v1 carries the complete reviewed mapping set (171); vm-v1 was the
# old "lightweight VM" split and is no longer used for deployment.
SCOPE="physical-v1"

section "Deploying config mappings (scope: ${SCOPE}, target: ${TARGET_USER})"

[[ -f "${MAPPINGS}" ]] || die "Missing ${MAPPINGS}"
mkdir -p "${BACKUP_DIR}"
log "Backup directory: ${BACKUP_DIR}"

deployed=0 skipped=0
while IFS=$'\t' read -r scope _module src tgt mode; do
  [[ -z "${src}" || "${src}" == "#"* ]] && continue
  [[ "${scope}" != "${SCOPE}" ]] && continue

  local_src="${CONFIG_SRC}/${src#config/}"
  if [[ ! -f "${local_src}" ]]; then
    warn "Source file missing: ${src}"; skipped=$((skipped + 1)); continue
  fi

  target="${TARGET_HOME}/${tgt}"
  # backup existing target
  if [[ -e "${target}" ]] && [[ ! -L "${target}" ]]; then
    mkdir -p "${BACKUP_DIR}/$(dirname "${tgt}")"
    cp -a "${target}" "${BACKUP_DIR}/${tgt}" 2>/dev/null || true
  fi

  mkdir -p "$(dirname "${target}")"
  cp -a "${local_src}" "${target}"
  chmod "${mode}" "${target}" 2>/dev/null || true
  # when running as root, keep files owned by the target user
  if [[ "$(id -u)" -eq 0 ]]; then
    chown "${TARGET_USER}:${TARGET_USER}" "${target}" 2>/dev/null || true
  fi
  deployed=$((deployed + 1))
done < "${MAPPINGS}"

log "Deployed: ${deployed} file(s), skipped: ${skipped}"
success "Config deployment complete (backup in ${BACKUP_DIR})"
