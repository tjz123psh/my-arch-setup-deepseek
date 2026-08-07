#!/usr/bin/env bash
# 07-config.sh - deploy reviewed user config mappings.
# Reads manifests/config-mappings.tsv (reused asset); every machine deploys
# the single scope physical-v1 (VM and physical share the full config set).
# Rows are filtered by the SAME module_selected() as packages (review H-07),
# so a desktop/machine role can never be half-deployed. Backs up any
# existing target first; refuses to follow symlinks (review C-05).
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=00-utils.sh
source "${SCRIPT_DIR}/00-utils.sh"

MAPPINGS="${PROJECT_DIR}/manifests/config-mappings.tsv"
CONFIG_SRC="${PROJECT_DIR}/config"
BACKUP_DIR="${TARGET_HOME}/.config-backup-my-arch-$(date +%Y%m%d%H%M%S)"
# Operator decision (2026-08-05): the VM restores the same full configuration
# as the physical machine (packages minus GPU drivers; config is identical).
# physical-v1 carries the complete reviewed mapping set; the old vm-v1
# "lightweight VM" split was removed on 2026-08-07.
SCOPE="physical-v1"

section "Deploying config mappings (scope: ${SCOPE}, target: ${TARGET_USER})"

[[ -f "${MAPPINGS}" ]] || die "Missing ${MAPPINGS}"
mkdir -p "${BACKUP_DIR}"
log "Backup directory: ${BACKUP_DIR}"

deployed=0 skipped=0

deploy_one() {
  local src="$1" tgt="$2" mode="$3"
  local local_src="${CONFIG_SRC}/${src#config/}"
  if [[ ! -f "${local_src}" ]]; then
    warn "Source file missing: ${src}"; skipped=$((skipped + 1)); return 0
  fi

  local target="${TARGET_HOME}/${tgt}"

  # C-05: never follow a symlink anywhere in the target path. A symlinked
  # target (or path component) would write through to a file outside HOME -
  # e.g. a dotfiles repo or a shared path - silently modifying something the
  # installer must not touch. Refuse and skip such rows.
  local dir="${target}"
  while [[ "$(dirname "${dir}")" != "${dir}" ]]; do
    dir="$(dirname "${dir}")"
    if [[ -L "${dir}" ]]; then
      warn "refusing to deploy ${tgt}: path component is a symlink (${dir}); would write outside HOME"
      skipped=$((skipped + 1)); return 0
    fi
  done

  # backup the existing target; if it is a symlink, back up the LINK itself
  # (cp -aP), never what it points at.
  if [[ -e "${target}" || -L "${target}" ]]; then
    mkdir -p "${BACKUP_DIR}/$(dirname "${tgt}")"
    cp -aP "${target}" "${BACKUP_DIR}/${tgt}" 2>/dev/null || true
  fi
  # remove an existing symlink so cp -a creates a real file; the symlink's
  # target is left untouched (the backup above saved the link itself)
  [[ -L "${target}" ]] && rm -f "${target}"

  mkdir -p "$(dirname "${target}")"
  cp -a "${local_src}" "${target}"
  chmod "${mode}" "${target}" 2>/dev/null || true
  # when running as root, keep files owned by the target user
  if [[ "$(id -u)" -eq 0 ]]; then
    chown "${TARGET_USER}:${TARGET_USER}" "${target}" 2>/dev/null || true
  fi
  deployed=$((deployed + 1))
}

while IFS=$'\t' read -r scope module src tgt mode; do
  [[ -z "${src}" || "${src}" == "#"* ]] && continue
  [[ "${scope}" != "${SCOPE}" ]] && continue
  # same module selection as packages (P1-2): hardware modules are never
  # deployed here (04 handles them), machine-role modules follow
  # MACHINE_TYPE, desktop modules follow DESKTOP_ENV.
  module_selected "${src}" "${module}" || continue
  deploy_one "${src}" "${tgt}" "${mode}"
done < "${MAPPINGS}"

log "Deployed: ${deployed} file(s), skipped: ${skipped}"
success "Config deployment complete (backup in ${BACKUP_DIR})"
