#!/usr/bin/env bash
# 07-services.sh - enable reviewed system services.
# Physical-scoped services only on physical machines; VM keeps user units.
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=00-utils.sh
source "${SCRIPT_DIR}/00-utils.sh"

section "启用系统服务 (${MACHINE_TYPE})"

# user units (always)
for u in "${HOME}/.config/systemd/user/"*.service; do
  [[ -e "${u}" ]] || continue
  unit="$(basename "${u}")"
  systemctl --user enable "${unit}" 2>/dev/null && log "用户服务: ${unit}"
done

if [[ "${MACHINE_TYPE}" == "physical" ]]; then
  SERVICES=(bluetooth.service power-profiles-daemon.service docker.service \
            libvirtd.service NetworkManager.service)
  for s in "${SERVICES[@]}"; do
    if systemctl list-unit-files "${s}" >/dev/null 2>&1; then
      run systemctl enable --now "${s}" && log "服务: ${s}"
    fi
  done
  # libvirt default network
  if command -v virsh >/dev/null 2>&1; then
    run virsh net-autostart default 2>/dev/null && log "libvirt 默认网络 autostart"
  fi
  log "提示: docker/libvirt 组成员与 supergfxd 模式请按需手动配置"
else
  log "VM: 跳过物理机服务"
fi

success "服务配置完成"
