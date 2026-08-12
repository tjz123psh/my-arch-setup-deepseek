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

# P1-3: allow controlled dependency injection (the behavior harness binds
# MAPPINGS/CONFIG_SRC to a workspace sandbox); production uses the defaults.
MAPPINGS="${MAPPINGS:-${PROJECT_DIR}/manifests/config-mappings.tsv}"
CONFIG_SRC="${CONFIG_SRC:-${PROJECT_DIR}/config}"
BACKUP_DIR="${TARGET_HOME}/.config-backup-my-arch-$(date +%Y%m%d%H%M%S)"
# Operator decision (2026-08-05): the VM restores the same full configuration
# as the physical machine (packages minus GPU drivers; config identical except
# one gated row: the asus-hardware mapping (rog-control-center.cfg) is skipped
# on vm by module_selected (ctx=config), see docs/granularity.md).
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

  # C-06: never deploy outside HOME. An absolute tgt or a path containing
  # ".." escapes TARGET_HOME (on the root/strap path cp -a would write
  # anywhere). The symlink check below cannot catch ".." (it is a real
  # directory), so reject it here explicitly - same principle as
  # 00-utils path_no_symlink_components (found 2026-08-10 swarm audit).
  case "${tgt}" in
    /*|*".."*) warn "refusing to deploy ${tgt}: path escapes HOME (absolute or '..')"; skipped=$((skipped + 1)); return 0 ;;
  esac

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
  # (cp -aP), never what it points at. A failed backup must not silently
  # proceed to overwrite the original (would lose the old config with no
  # copy) - warn instead (found 2026-08-10 swarm audit).
  if [[ -e "${target}" || -L "${target}" ]]; then
    mkdir -p "${BACKUP_DIR}/$(dirname "${tgt}")"
    if ! cp -aP "${target}" "${BACKUP_DIR}/${tgt}" 2>/dev/null; then
      warn "backup of ${tgt} failed; the original will be overwritten without a backup copy"
    fi
  fi
  # remove an existing symlink so cp -a creates a real file; the symlink's
  # target is left untouched (the backup above saved the link itself)
  [[ -L "${target}" ]] && rm -f "${target}"

  mkdir -p "$(dirname "${target}")"
  cp -a "${local_src}" "${target}"
  chmod "${mode}" "${target}" 2>/dev/null || true
  # when running as root, keep the file AND the path to it owned by the
  # target user. Chowning only the file leaves the intermediate dirs
  # root-owned, so later user-run steps cannot write: niri-vmtest-gen's
  # config.kdl.vmtest and `systemctl --user enable` (creating the .wants
  # dirs) both failed on a fresh VM install 2026-08-10 (dms.service is a
  # required user unit, so 08-services aborted).
  if [[ "$(id -u)" -eq 0 ]]; then
    chown "${TARGET_USER}:${TARGET_USER}" "${target}" 2>/dev/null || true
    local d="${target}"
    while [[ "${d}" != "${TARGET_HOME}" && "${d}" != "/" ]]; do
      d="$(dirname "${d}")"
      chown "${TARGET_USER}:${TARGET_USER}" "${d}" 2>/dev/null || true
    done
  fi
  deployed=$((deployed + 1))
}

while IFS=$'\t' read -r scope module src tgt mode; do
  [[ -z "${src}" || "${src}" == "#"* ]] && continue
  [[ "${scope}" != "${SCOPE}" ]] && continue
  # same module selection as packages (P1-2), but with ctx=config so hardware
  # config rows (graphics-*/hardware-tools/asus-hardware) deploy on physical
  # instead of being unconditionally skipped like their package rows are.
  module_selected "${src}" "${module}" config || continue
  deploy_one "${src}" "${tgt}" "${mode}"
done < "${MAPPINGS}"

log "Deployed: ${deployed} file(s), skipped: ${skipped}"
echo "CONFIG_RESULT deployed=${deployed} skipped=${skipped}"

# root/strap path: the backup tree under TARGET_HOME was created by root; hand
# it to the target user so they can inspect/remove it without sudo (found
# 2026-08-10 swarm audit).
if [[ "$(id -u)" -eq 0 && -d "${BACKUP_DIR}" ]]; then
  chown -R "${TARGET_USER}:${TARGET_USER}" "${BACKUP_DIR}" 2>/dev/null || true
fi

# P1-5: niri VM test config generation. After the normal config.kdl is
# deployed, regenerate config.kdl.vmtest (keybinds disabled, switch key
# retained) so the toggle in config.kdl never points at a missing file.
# Idempotent by construction (pure python transform); verify the output
# exists and validate BOTH configs with niri when the binary is present.
if [[ "${DESKTOP_ENV}" == "niri" || "${DESKTOP_ENV}" == "both" ]] \
   && [[ -f "${TARGET_HOME}/scripts/desktop/niri-vmtest-gen" ]] \
   && [[ -f "${TARGET_HOME}/.config/niri/config.kdl" ]]; then
  gen="${TARGET_HOME}/scripts/desktop/niri-vmtest-gen"
  if [[ "$(id -u)" -eq 0 ]]; then
    runuser -u "${TARGET_USER}" -- bash -c "HOME='${TARGET_HOME}' '${gen}'" \
      || warn "niri-vmtest-gen failed; VM test config not generated"
  else
    HOME="${TARGET_HOME}" bash "${gen}" || warn "niri-vmtest-gen failed; VM test config not generated"
  fi
  if [[ -f "${TARGET_HOME}/.config/niri/config.kdl.vmtest" ]]; then
    log "niri VM test config present: config.kdl.vmtest"
  else
    warn "niri config.kdl.vmtest missing after generation"
  fi
  if command -v niri >/dev/null 2>&1; then
    if niri validate -c "${TARGET_HOME}/.config/niri/config.kdl" >/dev/null 2>&1 \
       && niri validate -c "${TARGET_HOME}/.config/niri/config.kdl.vmtest" >/dev/null 2>&1; then
      log "niri validate: normal + vmtest configs both OK"
    else
      warn "niri validate failed for normal or vmtest config (see niri validate -c ...)"
    fi
  fi
fi

# P1-6: create ~/.local/bin entry points referenced by configs via
# $HOME/.local/bin (matches the host: symlinks into ~/scripts). Targets stay
# inside HOME; an existing regular file is never overwritten.
if [[ "${DESKTOP_ENV}" != "none" ]]; then
  local_bin="${TARGET_HOME}/.local/bin"
  if [[ "$(id -u)" -eq 0 ]]; then
    runuser -u "${TARGET_USER}" -- mkdir -p "${local_bin}" 2>/dev/null || true
  else
    mkdir -p "${local_bin}"
  fi
  while IFS='|' read -r link_name script_rel; do
    target="${TARGET_HOME}/scripts/${script_rel}"
    [[ -f "${target}" ]] || { warn "P1-6: ${script_rel} not deployed; skipping ${link_name}"; continue; }
    link_path="${local_bin}/${link_name}"
    if [[ -L "${link_path}" ]]; then
      if [[ "$(readlink "${link_path}")" != "${target}" ]]; then
        ln -sfn "${target}" "${link_path}" && log "P1-6: refreshed ${link_name} -> ${target}"
      fi
    elif [[ -e "${link_path}" ]]; then
      warn "P1-6: ${link_path} exists as a regular file; not overwriting"
    else
      ln -s "${target}" "${link_path}" && log "P1-6: ${link_name} -> ${target}"
    fi
  done <<'ENTRIES'
niri-keys|desktop/niri-keys
hypr-keys|desktop/hypr-keys
b23|media/b23
ENTRIES
fi

success "Config deployment complete (backup in ${BACKUP_DIR})"
