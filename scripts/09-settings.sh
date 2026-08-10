#!/usr/bin/env bash
# 09-settings.sh - system settings matching the operator host snapshot:
# locale (zh_CN.UTF-8 + en_US.UTF-8), timezone (Asia/Shanghai), hostname
# (default), zram swap, and the 32-bit multilib flag already handled by 01.
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=00-utils.sh
source "${SCRIPT_DIR}/00-utils.sh"

section "System settings"

# --- locale ---
log "Configuring locale (zh_CN.UTF-8, en_US.UTF-8)..."
# A fresh base may ship a minimal locale.gen (e.g. cloud-init image) with no
# commented zh_CN line; sed-uncommenting then misses it. Enable lines that
# exist, and append missing ones.
run bash -c 'sed -i "s/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/; s/^#zh_CN.UTF-8 UTF-8/zh_CN.UTF-8 UTF-8/" /etc/locale.gen; grep -q "^en_US.UTF-8 UTF-8" /etc/locale.gen || echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen; grep -q "^zh_CN.UTF-8 UTF-8" /etc/locale.gen || echo "zh_CN.UTF-8 UTF-8" >> /etc/locale.gen'
run locale-gen
run bash -c 'printf "LANG=zh_CN.UTF-8\nLC_CTYPE=en_US.UTF-8\n" > /etc/locale.conf'
success "Locale: LANG=zh_CN.UTF-8, LC_CTYPE=en_US.UTF-8"

# --- timezone ---
log "Setting timezone to Asia/Shanghai..."
run bash -c 'ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime'
run bash -c 'printf "Asia/Shanghai\n" > /etc/timezone'
success "Timezone: Asia/Shanghai"

# --- hostname (default unless already set) ---
if [[ ! -s /etc/hostname ]]; then
  log "Setting hostname to archlinux..."
  run bash -c 'printf "archlinux\n" > /etc/hostname'
else
  log "Hostname already set: $(cat /etc/hostname)"
fi

# --- zram (matches host /etc/systemd/zram-generator.conf) ---
if ! pacman -Q zram-generator >/dev/null 2>&1; then
  log "Installing zram-generator..."
  run pacman -S --needed --noconfirm zram-generator
fi
log "Writing zram-generator.conf..."
run bash -c 'cat > /etc/systemd/zram-generator.conf <<EOF
[zram0]
zram-size = ram
compression-algorithm = zstd
EOF'
run systemctl daemon-reload
success "zram configured (zstd, size=ram)"

# --- VMware guest graphics workaround ---
# Hyprland cannot import mesa/vmwgfx dma-bufs (upstream Hyprland#7658), so on
# VMware guests every GL client dies with "wl_surface.attach: invalid
# arguments". LIBGL_ALWAYS_SOFTWARE=1 routes clients through llvmpipe (wl_shm
# buffers), which imports fine - terminals, apps and DMS all work. Physical
# (bare-metal) installs must NOT get this: they keep hardware GL. The guard is
# the same systemd-detect-virt == vmware check install.sh uses for the
# physical-sim-vmware preflight.
if is_vmware_guest; then
  log "VMware guest detected: forcing software GL (LIBGL_ALWAYS_SOFTWARE=1) for Hyprland client buffer compatibility"
  apply_vmware_graphics_workaround
  if grep -q '^LIBGL_ALWAYS_SOFTWARE=1' /etc/environment; then
    success "LIBGL_ALWAYS_SOFTWARE=1 set in /etc/environment (VMware guest)"
  else
    error "failed to write LIBGL_ALWAYS_SOFTWARE=1 to /etc/environment"
    exit 1
  fi
else
  log "Not a VMware guest; keeping hardware GL (no LIBGL_ALWAYS_SOFTWARE)"
fi

# --- standard user directories (empty, xdg defaults) ---
# Operator decision (2026-08-05): only create the default empty dirs that a
# fresh xdg-user-dirs setup provides; the host's existing files in them are
# personal data and are NOT migrated. user-dirs.dirs is deployed by 07-config
# and defines the paths; this step creates the directories themselves.
log "Creating standard user directories (Desktop/Documents/Downloads/Music/Public/Templates/Videos)..."
STD_DIRS=(Desktop Documents Downloads Music Public Templates Videos)
if [[ "$(id -u)" -eq 0 ]]; then
  for d in "${STD_DIRS[@]}"; do
    mkdir -p "${TARGET_HOME}/${d}"
    chown "${TARGET_USER}:${TARGET_USER}" "${TARGET_HOME}/${d}"
  done
else
  for d in "${STD_DIRS[@]}"; do
    mkdir -p "${HOME}/${d}"
  done
fi
success "Standard user directories ready"

# --- login shell (align the host: fish) ---
# /etc/shells must list fish before chsh/`useradd -s` accepts it; the
# operator's login shell on the host is /usr/bin/fish.
if command -v fish >/dev/null 2>&1; then
  if ! grep -q '^/usr/bin/fish$' /etc/shells; then
    run bash -c 'echo /usr/bin/fish >> /etc/shells; echo /bin/fish >> /etc/shells'
  fi
  if [[ "$(getent passwd "${TARGET_USER}" | cut -d: -f7)" != "/usr/bin/fish" ]]; then
    log "Setting login shell for ${TARGET_USER} to fish..."
    run chsh -s /usr/bin/fish "${TARGET_USER}" || warn "could not set fish as login shell"
  fi
fi

# --- dms plugin runtime dependencies ---
# dankmaintenance and ShorinScreenrec run a startup check that requires these
# paths; a fresh install lacks them, so the plugins report "启动失败" until the
# directories exist. Create them so the plugins load right after deployment.
# shorin-screenrec-menu (user script, kept under config/home/.local/bin) is
# installed to /usr/local/bin because the plugin's startup check runs under
# `sh -c 'command -v ...'` whose PATH does not include ~/.local/bin.
log "Creating dms plugin dependency paths..."
mkdir -p "${TARGET_HOME}/.cache/checkallupdates"
run mkdir -p /.snapshots /home/.snapshots
if [[ -f "${PROJECT_DIR}/config/home/.local/bin/shorin-screenrec-menu" ]]; then
  run install -m 755 "${PROJECT_DIR}/config/home/.local/bin/shorin-screenrec-menu" /usr/local/bin/shorin-screenrec-menu
  log "Deployed shorin-screenrec-menu to /usr/local/bin"
else
  warn "shorin-screenrec-menu not found in config; ShorinScreenrec plugin may fail its startup check"
fi

# Preset the recording engine. The plugin's startup check only verifies
# shorin-screenrec-menu exists; the actual engine pick happens at record
# time from ~/.cache/shorin-screenrec/engine. 2026-08-09: wl-screenrec-git
# was dropped from archlinuxcn and its binary is broken by the ffmpeg 9 ABI
# (libavutil.so.60 -> 61), so BOTH machine types are pinned to wf-recorder
# (extra, rebuilt against the current ffmpeg; CPU encoding).
log "Presetting screen recording engine for ${MACHINE_TYPE}..."
mkdir -p "${TARGET_HOME}/.cache/shorin-screenrec"
printf 'wf-recorder\n' > "${TARGET_HOME}/.cache/shorin-screenrec/engine"
# 编码质量参数：libx264 默认 CRF 23 对屏幕录制偏糊（2026-08-10 用户反馈），
# 固定 crf=18 + preset=veryfast；shorin-screenrec-menu 按冒号拆分后作为
# wf-recorder 的 -p 参数传入。
printf 'crf=18:preset=veryfast\n' > "${TARGET_HOME}/.cache/shorin-screenrec/enc_params_wf"
# root/strap path: mkdir -p creates root-owned dirs; chown the whole chain
# (including the ~/.cache parent itself) so the first desktop session can
# write its caches. Chowning only the leaves leaves ~/.cache root-owned and
# fontconfig/GTK/Chromium-class apps fail with EACCES (same defect class as
# the 07-config dir-chown fix, found 2026-08-10 swarm audit).
if [[ "$(id -u)" -eq 0 ]]; then
  for d in "${TARGET_HOME}/.cache" \
           "${TARGET_HOME}/.cache/checkallupdates" \
           "${TARGET_HOME}/.cache/shorin-screenrec"; do
    chown "${TARGET_USER}:${TARGET_USER}" "${d}" 2>/dev/null || true
  done
fi
log "Recording engine: $(cat "${TARGET_HOME}/.cache/shorin-screenrec/engine") params: $(cat "${TARGET_HOME}/.cache/shorin-screenrec/enc_params_wf")"
success "dms plugin dependencies ready"

# --- snapper snapshot configs (align the host snapshot: root + home) ---
# 08-services enables snapper-cleanup.timer; without a per-config the
# operator's snapshot tooling (backup-restore/quickload) reports
# "no snapper config" for root/home. snapper needs .snapshots as btrfs
# subvolumes, but the plugin-dependency dirs above are plain directories -
# remove the empty ones so create-config can make real subvolumes.
#
# Permission alignment (host snapshot 2026-08-07): on the host,
# /etc/snapper/configs/{root,home} carry ALLOW_GROUPS=wheel and the
# .snapshots subvolumes carry a group:wheel:r-x ACL, so the operator can
# run snapper as a normal user. A bare `create-config` sets neither:
# the config is root-only and the .snapshots subvolume is 750 root:root,
# which makes the dms plugin StartupCheck (`test -r /.snapshots`) fail
# and quicksave/term-menu report "No permissions"/"配置不存在". Mirror the
# host: grant wheel after create-config (success or failure path).
if command -v snapper >/dev/null 2>&1 && command -v btrfs >/dev/null 2>&1; then
  if [[ ! -f /etc/snapper/configs/root ]]; then
    log "Initializing snapper root config..."
    run rmdir /.snapshots 2>/dev/null || true
    run snapper -c root create-config / || {
      warn "snapper root config failed; snapshots unavailable"
      # keep the dms plugin dependency path readable even without snapper
      run mkdir -p /.snapshots
    }
  fi
  if [[ ! -f /etc/snapper/configs/home ]]; then
    log "Initializing snapper home config..."
    run rmdir /home/.snapshots 2>/dev/null || true
    run snapper -c home create-config /home || {
      warn "snapper home config failed; home snapshots unavailable (VM /home is not a btrfs subvolume; physical @home succeeds)"
      # restore the plain dir the dms plugins' startup check requires
      run mkdir -p /home/.snapshots
    }
  fi
  # Mirror the host ACL/ALLOW_GROUPS so a normal user (wheel) can read
  # .snapshots and run snapper without sudo. Host snapshot 2026-08-07:
  # configs carry ALLOW_GROUPS=wheel SYNC_ACL=yes, and .snapshots is 750
  # root:root with a group:wheel:r-x ACL (other::---). Only add the ACL;
  # do NOT chmod o+rx - that would widen the dir to world-readable, which
  # the host does not have (snapshots contain every user's files).
  for conf in root home; do
    [[ -f /etc/snapper/configs/${conf} ]] \
      && run snapper -c "${conf}" set-config ALLOW_GROUPS=wheel SYNC_ACL=yes || true
  done
  run bash -c 'setfacl -m g:wheel:r-x /.snapshots 2>/dev/null || true; setfacl -m g:wheel:r-x /home/.snapshots 2>/dev/null || true'
fi

success "System settings complete"

# --- nomacs acceptance (review 4.2 / P1-8) ---
# nomacs is the PNG default image viewer (mimeapps.list is deployed by
# 07-config) and a manifest required install row (desktop-apps). Missing
# package / desktop entry / MIME association must FAIL the step, not
# log-and-continue; xdg-mime query failure is reported, not swallowed.
nomacs_ok=1
if pacman -Q nomacs >/dev/null 2>&1; then
  log "nomacs package present: $(pacman -Q nomacs | awk '{print $2}')"
else
  error "nomacs not installed (required desktop-apps row)"
  nomacs_ok=0
fi
if [[ -f /usr/share/applications/org.nomacs.ImageLounge.desktop ]]; then
  if ! desktop-file-validate /usr/share/applications/org.nomacs.ImageLounge.desktop >/dev/null 2>&1; then
    error "nomacs desktop entry failed desktop-file-validate"
    nomacs_ok=0
  fi
else
  error "nomacs desktop entry missing: /usr/share/applications/org.nomacs.ImageLounge.desktop"
  nomacs_ok=0
fi
# xdg-mime reads ~/.config/mimeapps.list, which 07 deployed for the target
# user; run it as that user (root/strap path needs runuser) and do not let a
# query failure abort via set -e before it can be reported.
query_png_mime() {
  if [[ "$(id -u)" -eq 0 ]]; then
    runuser -u "${TARGET_USER}" -- xdg-mime query default image/png
  else
    xdg-mime query default image/png
  fi
}
mime_default=
if ! mime_default="$(query_png_mime 2>/dev/null)"; then
  error "xdg-mime query default image/png failed (CHECK_FAILED)"
  nomacs_ok=0
elif [[ -z "${mime_default}" ]]; then
  error "xdg-mime query default image/png returned nothing (CHECK_FAILED)"
  nomacs_ok=0
elif [[ "${mime_default}" != *"org.nomacs.ImageLounge.desktop"* ]]; then
  error "image/png default is '${mime_default}' (expected org.nomacs.ImageLounge.desktop)"
  nomacs_ok=0
fi
if (( nomacs_ok == 1 )); then
  success "nomacs + PNG MIME association verified"
else
  error "nomacs acceptance failed; PNG default viewer not ready"
  exit 1
fi
