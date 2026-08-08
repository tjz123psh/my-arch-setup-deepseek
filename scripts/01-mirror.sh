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
# aliyun first (usually fastest), then USTC and Tsinghua as fallbacks, then
# more verified CN mirrors (tencent/huaweicloud/163/lzu/zju, each confirmed
# to serve core.db; sjtu redirects to ftp.sjtu.edu.cn and cqu is dead, so
# they are intentionally not listed).
MIRROR_BASE=(
  "https://mirrors.aliyun.com/archlinux"
  "https://mirrors.ustc.edu.cn/archlinux"
  "https://mirrors.tuna.tsinghua.edu.cn/archlinux"
  "https://mirrors.cloud.tencent.com/archlinux"
  "https://mirrors.huaweicloud.com/archlinux"
  "https://mirrors.163.com/archlinux"
  "https://mirrors.lzu.edu.cn/archlinux"
  "https://mirrors.zju.edu.cn/archlinux"
)

ALIYUN="${MIRROR_BASE[0]}/core/os/x86_64/core.db"

if [[ "${CN_MIRROR:-0}" == "1" ]] || \
   curl -fsS --connect-timeout 4 --max-time 8 -o /dev/null "${ALIYUN}" 2>/dev/null; then
  log "Aliyun mirror reachable; writing China mirror list (8 mirrors)."
  run bash -c 'printf "%s\n" \
    "Server = https://mirrors.aliyun.com/archlinux/\$repo/os/\$arch" \
    "Server = https://mirrors.ustc.edu.cn/archlinux/\$repo/os/\$arch" \
    "Server = https://mirrors.tuna.tsinghua.edu.cn/archlinux/\$repo/os/\$arch" \
    "Server = https://mirrors.cloud.tencent.com/archlinux/\$repo/os/\$arch" \
    "Server = https://mirrors.huaweicloud.com/archlinux/\$repo/os/\$arch" \
    "Server = https://mirrors.163.com/archlinux/\$repo/os/\$arch" \
    "Server = https://mirrors.lzu.edu.cn/archlinux/\$repo/os/\$arch" \
    "Server = https://mirrors.zju.edu.cn/archlinux/\$repo/os/\$arch" \
    > /etc/pacman.d/mirrorlist'
  success "Switched to China mirror list (8 mirrors)"
else
  log "Aliyun not reachable; running reflector (60s hard cap)..."
  run pacman -S --noconfirm --needed reflector
  # Hard timeout prevents a multi-minute global scan on a restricted network.
  # `run` wraps sudo; the timeout must wrap the ACTUAL command, so run executes
  # `timeout 60 reflector ...` as root. The previous `timeout 60 run ...`
  # could not resolve the shell function `run` as an external command and
  # always died with rc=127 (review P1-9). timeout rc=124 means it fired.
  if run timeout 60 reflector --protocol https -a 5 -f 3 --sort rate \
      --save /etc/pacman.d/mirrorlist; then
    success "Mirror selection finished"
  else
    rc=$?
    if (( rc == 124 )); then
      warn "reflector timed out after 60s; keeping existing mirror"
    else
      warn "reflector failed (rc=${rc}); keeping existing mirror"
    fi
  fi
fi

# enable multilib (needed for lib32 packages)
if ! grep -q '^\[multilib\]' /etc/pacman.conf; then
  log "Enabling multilib repository..."
  run bash -c 'sed -i "/^#\[multilib\]/,/^#Include/s/^#//" /etc/pacman.conf'
fi

# Downloader policy (download-mode-lab FINAL.md, D-01; merged step 1,
# 2026-08-08). pacman's NATIVE downloader is the default and
# `ParallelDownloads` (5 in this project's /etc/pacman.conf) gives real
# concurrency. An external XferCommand takes over EVERY remote file and
# serializes downloads (mock-verified ~2.9x slower at p=3/5), so we
# deliberately do NOT write one. pacman >= 7 also has a native low-speed
# abort (fails after ~10 s under 1 byte/s) plus per-mirror failover - that
# is the stall protection that matters for a dead mirror. Only an operator
# who explicitly wants an external downloader sets XferCommand manually;
# note that ParallelDownloads then no longer applies.
if grep -q '^XferCommand' /etc/pacman.conf; then
  warn "XferCommand already set in /etc/pacman.conf; ParallelDownloads is bypassed (native concurrency disabled)"
elif grep -q '^ParallelDownloads' /etc/pacman.conf; then
  log "pacman native downloader active; ParallelDownloads in effect"
else
  log "ParallelDownloads not set in /etc/pacman.conf; pacman defaults to 1 (see pacman.conf(5))"
fi

run pacman -Sy
success "Mirror source ready"
