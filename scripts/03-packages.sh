#!/usr/bin/env bash
# 03-packages.sh - install the reviewed workstation package policy.
# Reads manifests/workstation-packages.tsv (reused asset); selects packages
# by module set via the shared module_selected() (see 00-utils.sh):
#   - hardware modules (graphics-*/hardware-tools/asus-hardware) are handled
#     by the dedicated 04-drivers step (physical only) and excluded here on
#     both machine types;
#   - machine-role modules follow MACHINE_TYPE (vmware-host / vmware-guest);
#   - desktop modules (wm-niri / wm-hyprland) follow DESKTOP_ENV.
# policy=verify rows are handoff preconditions and are checked for presence
# up front (never installed); policy=deferred rows are never installed.
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=00-utils.sh
source "${SCRIPT_DIR}/00-utils.sh"

POLICY="${PROJECT_DIR}/manifests/workstation-packages.tsv"

section "Installing packages (${MACHINE_TYPE})"
log "Reading package policy from ${POLICY} ..."

# --- verify-only preflight (review H-03) ---
# policy=verify rows are HARD handoff preconditions (base system, bootloader,
# kernel, initramfs, filesystem, network) that the operator's manual base
# install must satisfy and the installer cannot self-heal. Check them for
# real instead of silently skipping: a missing precondition means the restore
# would build on a broken base. Tool packages the base install usually has
# but that 03 can simply install (dosfstools/efibootmgr/exfat-utils/os-prober/
# wpa_supplicant/zram-generator) are NOT verify rows - they are install rows
# (verified on 2026-08-08: a clean archinstall baseline lacks them, so
# requiring them up front would block the restore).
VERIFY_FAILED=0
VERIFY_COUNT=0
while IFS=$'\t' read -r pkg channel _repo _acq _module _restore pol _origin purpose; do
  [[ -z "${pkg}" || "${pkg}" == "#"* ]] && continue
  [[ "${pol}" != "verify" ]] && continue
  VERIFY_COUNT=$((VERIFY_COUNT + 1))
  if [[ "${channel}" == "pacman" ]]; then
    if ! pacman -Q "${pkg}" >/dev/null 2>&1; then
      warn "precondition NOT satisfied: ${pkg} (${purpose})"
      VERIFY_FAILED=$((VERIFY_FAILED + 1))
    fi
  else
    warn "verify row with non-pacman channel: ${pkg} (${purpose})"
    VERIFY_FAILED=$((VERIFY_FAILED + 1))
  fi
done < "${POLICY}"
if (( VERIFY_FAILED > 0 )); then
  error "${VERIFY_FAILED}/${VERIFY_COUNT} base precondition(s) missing; fix the base install before restoring"
  exit 1
fi
log "Base preconditions: ${VERIFY_COUNT}/${VERIFY_COUNT} present"

# official packages (pacman channel, install policy), filtered by module.
# NOTE: column 2 is the channel (pacman/aur), column 3 is the repository
# (core/extra/multilib/archlinuxcn). archlinuxcn packages install via pacman
# but need the [archlinuxcn] repo configured + keyring bootstrapped first.
OFFICIAL=()
AUR_PKGS=()
HAVE_ARCHLINUXCN=false
while IFS=$'\t' read -r pkg channel repo acq module _restore pol _origin _purpose; do
  [[ -z "${pkg}" || "${pkg}" == "#"* ]] && continue
  module_selected "${pkg}" "${module}" || continue
  # verify-only rows are handoff preconditions (checked above); deferred rows
  # are never installed.
  [[ "${pol}" == "verify" || "${pol}" == "deferred" ]] && continue
  case "${channel}" in
    pacman) OFFICIAL+=("${pkg}") ;;
    aur) AUR_PKGS+=("${pkg}") ;;
  esac
  [[ "${repo}" == "archlinuxcn" ]] && HAVE_ARCHLINUXCN=true
done < "${POLICY}"

log "Official packages: ${#OFFICIAL[@]}, AUR: ${#AUR_PKGS[@]}"

# archlinuxcn repo + keyring bootstrap (only when the selection uses it)
if [[ "${HAVE_ARCHLINUXCN}" == "true" ]]; then
  log "Configuring archlinuxcn repository and keyring..."
  if ! grep -q '^\[archlinuxcn\]' /etc/pacman.conf; then
    # Multiple mirrors for failover, matching the 01-mirror strategy.
    # All seven verified to serve archlinuxcn/x86_64/archlinuxcn.db
    # (163 and sjtu do NOT mirror archlinuxcn and are omitted).
    run bash -c 'printf "%s\n" \
      "[archlinuxcn]" \
      "Server = https://mirrors.aliyun.com/archlinuxcn/\$arch" \
      "Server = https://mirrors.ustc.edu.cn/archlinuxcn/\$arch" \
      "Server = https://mirrors.tuna.tsinghua.edu.cn/archlinuxcn/\$arch" \
      "Server = https://mirrors.cloud.tencent.com/archlinuxcn/\$arch" \
      "Server = https://mirrors.huaweicloud.com/archlinuxcn/\$arch" \
      "Server = https://mirrors.lzu.edu.cn/archlinuxcn/\$arch" \
      "Server = https://mirrors.zju.edu.cn/archlinuxcn/\$arch" \
      >> /etc/pacman.conf'
  fi
  if ! pacman -Q archlinuxcn-keyring >/dev/null 2>&1; then
    # Let pacman resolve the exact keyring package version from the repo.
    run pacman -Sy --noconfirm || die "pacman -Sy failed; cannot reach archlinuxcn repo"
    run pacman -S --noconfirm archlinuxcn-keyring || \
      die "archlinuxcn-keyring install failed; cannot install archlinuxcn packages"
  fi
  run pacman -Sy
fi

# flclash migration: the old AUR flclash-bin package provides the virtual
# name `flclash` but conflicts with the archlinuxcn package. pacman does not
# have a Replaces field to make this transaction automatic, and --noconfirm
# answers the conflict prompt with the default (abort). Remove only the old
# package (not its dependencies) before the official batch, then verify the
# exact target package after installation. This is intentionally explicit so
# a machine restored from the previous manifest does not silently keep the
# AUR build.
if [[ " ${OFFICIAL[*]} " == *" flclash "* ]]; then
  installed_packages="$(pacman -Qq)" || {
    error "could not query the installed package database; refusing flclash migration"
    exit 1
  }
  if grep -Fx flclash-bin >/dev/null <<<"${installed_packages}"; then
    log "Migrating flclash-bin (AUR) -> flclash (archlinuxcn)..."
    if ! run pacman -R --noconfirm flclash-bin; then
      error "could not remove conflicting flclash-bin; flclash migration is required"
      exit 1
    fi
  fi
fi

# install official packages
# rustup conflicts with the rust/cargo packages but provides them too.
# Install it first so any package depending on cargo/rust (e.g. cargo-audit)
# is satisfied via rustup's provides instead of pulling the conflicting rust
# package during the batch dependency resolve. A previous partial install may
# have pulled rust/cargo/rustfmt (per-package fallback), so remove them first.
if [[ " ${OFFICIAL[*]} " == *" rustup "* ]]; then
  for p in rust cargo rustfmt; do
    if pacman -Q "${p}" >/dev/null 2>&1; then
      log "Removing ${p} first (rustup provides it)..."
      # tolerate a stale local-db entry (e.g. after an interrupted run)
      # where -Q reports the package but -Rdd cannot find it
      run pacman -Rdd --noconfirm "${p}" 2>/dev/null || warn "could not remove ${p}; continuing"
    fi
  done
  log "Installing rustup first (it conflicts with rust/cargo)..."
  run pacman -S --needed --noconfirm rustup
fi
log "Installing official/archlinuxcn packages..."
if (( ${#OFFICIAL[@]} > 0 )); then
  run pacman -S --needed --noconfirm "${OFFICIAL[@]}" || {
    error "Official package install failed; retrying once (mirror stalls are common)..."
    if ! run pacman -S --needed --noconfirm "${OFFICIAL[@]}"; then
      error "Retry failed; installing individually to locate the problem..."
      failed=0
      for p in "${OFFICIAL[@]}"; do
        if ! run pacman -S --needed --noconfirm "${p}" >/dev/null 2>&1; then
          warn "failed: ${p}"
          failed=$((failed + 1))
        fi
      done
      if (( failed > 0 )); then
        error "${failed} official package(s) failed to install; rerun install.sh to resume (03 will be retried)"
        exit 1
      fi
    fi
  }
else
  log "No official packages selected for this desktop/machine combination"
fi

# Verify the migration by exact installed package names. `pacman -Q flclash`
# resolves virtual provides (and would report flclash-bin on the old system),
# so filter the complete quiet package list for an exact line.
if [[ " ${OFFICIAL[*]} " == *" flclash "* ]]; then
  installed_packages="$(pacman -Qq)" || {
    error "could not query the installed package database; refusing flclash acceptance"
    exit 1
  }
  if ! grep -Fx flclash >/dev/null <<<"${installed_packages}"; then
    error "flclash (archlinuxcn) is not installed after the official package stage"
    exit 1
  fi
  if grep -Fx flclash-bin >/dev/null <<<"${installed_packages}"; then
    error "legacy flclash-bin remains installed; refusing to mark package stage done"
    exit 1
  fi
  # FlClash C.3: verify the target package ships the expected binaries and a
  # real desktop entry (queried from the installed package, not assumed).
  flclash_missing=0
  for f in /usr/bin/flclash /usr/lib/flclash/FlClash; do
    if [[ ! -x "${f}" ]]; then
      error "flclash package missing expected file: ${f}"
      flclash_missing=$((flclash_missing + 1))
    fi
  done
  if ! pacman -Ql flclash 2>/dev/null | grep -q '[^ ]\.desktop$'; then
    error "flclash package ships no desktop entry (pacman -Ql flclash)"
    flclash_missing=$((flclash_missing + 1))
  fi
  if (( flclash_missing > 0 )); then
    error "flclash acceptance failed (${flclash_missing} missing file(s))"
    exit 1
  fi
  log "Verified flclash package migration: flclash present, flclash-bin absent, binaries + desktop entry OK"
fi

success "Package install complete (${#OFFICIAL[@]} official + ${#AUR_PKGS[@]} AUR pending step 06)"
