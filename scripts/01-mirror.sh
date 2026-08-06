#!/usr/bin/env bash
# 01-mirror.sh - mirrorlist optimisation.
#
# Strategy (order):
#   1. If the Aliyun mirror answers quickly (reachable from this network),
#      use it directly - it is fast for a China timezone host and avoids the
#      slow global reflector scan entirely.
#   2. Otherwise run reflector with a hard timeout and a small candidate set
#      so a restricted network (VM NAT / proxied egress) cannot stall the
#      installer for minutes per mirror.
#   3. Enable multilib (needed for lib32 packages), then resync.
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=00-utils.sh
source "${SCRIPT_DIR}/00-utils.sh"

section "Mirror optimization"

# Candidate China mirrors, in preference order (pacman tries them in order
# and fails over to the next on error, so listing several is pure resilience).
# aliyun first (usually fastest), then USTC and Tsinghua as fallbacks.
MIRROR_BASE=(
  "https://mirrors.aliyun.com/archlinux"
  "https://mirrors.ustc.edu.cn/archlinux"
  "https://mirrors.tuna.tsinghua.edu.cn/archlinux"
)

ALIYUN="${MIRROR_BASE[0]}/core/os/x86_64/core.db"

if [[ "${CN_MIRROR:-0}" == "1" ]] || \
   curl -fsS --connect-timeout 4 --max-time 8 -o /dev/null "${ALIYUN}" 2>/dev/null; then
  log "Aliyun mirror reachable; writing China mirror list (aliyun/ustc/tuna)."
  run bash -c 'printf "%s\n" \
    "Server = https://mirrors.aliyun.com/archlinux/\$repo/os/\$arch" \
    "Server = https://mirrors.ustc.edu.cn/archlinux/\$repo/os/\$arch" \
    "Server = https://mirrors.tuna.tsinghua.edu.cn/archlinux/\$repo/os/\$arch" \
    > /etc/pacman.d/mirrorlist'
  success "Switched to China mirror list (3 mirrors)"
else
  log "Aliyun not reachable; running reflector (60s hard cap)..."
  run pacman -S --noconfirm --needed reflector
  # Hard timeout prevents a multi-minute global scan on a restricted network.
  timeout 60 run reflector --protocol https -a 5 -f 3 --sort rate \
    --save /etc/pacman.d/mirrorlist || {
    warn "reflector timed out or failed; keeping existing mirror"
    true
  }
  success "Mirror selection finished"
fi

# enable multilib (needed for lib32 packages)
if ! grep -q '^\[multilib\]' /etc/pacman.conf; then
  log "Enabling multilib repository..."
  run bash -c 'sed -i "/^#\[multilib\]/,/^#Include/s/^#//" /etc/pacman.conf'
fi

# Download timeout/retry: pacman's built-in libcurl downloader has NO total
# timeout, so a stalled mirror connection hangs the installer forever (seen
# with fuzzel-ime-git's fcft/tllist deps on aliyun). Route downloads through
# curl with a short connect timeout (a dead mirror must fail over quickly),
# a per-file cap for slow transfers, retries and -f (a failed fetch must not
# leave an error page behind as the .db, which pacman then rejects as a bad
# PGP signature). Only set it if the operator has not customized XferCommand.
# NOTE: XferCommand must sit in the global [options] section - appending at
# EOF lands inside the trailing [multilib] block and pacman ignores it.
if ! grep -q '^XferCommand' /etc/pacman.conf; then
  log "Setting pacman XferCommand (download timeout + retry)..."
  # -sS: silent progress (no per-file progress-bar spam) but still print
  # errors, so a failed fetch is visible without the wall of progress lines.
  run bash -c "sed -i '/^\[options\]/a XferCommand = /usr/bin/curl -L -f -sS --connect-timeout 15 --max-time 300 --retry 3 --retry-delay 2 -C - -o %o %u' /etc/pacman.conf"
fi

run pacman -Sy
success "Mirror source ready"
