#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tool="$root/installer/system-action-plan.py"
[[ -f $tool && ! -L $tool ]] || { printf '%s\n' 'system action planner is missing or unsafe' >&2; exit 1; }

test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT

python "$tool" --profile asus-amd-nvidia --json >"$test_root/asus.json"
python - "$test_root/asus.json" <<'PY'
import json,sys
p=json.load(open(sys.argv[1]))
assert p['schema']==1
assert p['safety']=={
  'read_only':True,'apply_authorized':False,'installer_apply_integration':False,'system_changes':False,
}
assert p['profile']=='asus-amd-nvidia'
assert p['counts']=={'selected':29,'apply':11,'verify':10,'manual':6,'deferred':2,'root_apply':8,'user_apply':3}
by_id={r['id']:r for r in p['actions']}
for action in (
  'base-network-handoff','time-sync-service','bluetooth-service','power-profiles-service',
  'dms-niri-session-wants','dsearch-user-service','docker-service','libvirtd-service',
  'libvirt-default-network','locale-zh-cn','fcitx-system-environment','kernel-dkms-verification',
  'supergfxd-physical-service','grub-btrfs-recovery','greeter-login-manager',
):
  if action == 'greeter-login-manager':
    assert action not in by_id
  else:
    assert action in by_id,action
assert by_id['audio-package-activation']['disposition']=='verify'
assert by_id['supergfxd-physical-service']['disposition']=='manual'
assert by_id['grub-btrfs-recovery']['disposition']=='deferred'
assert by_id['docker-service']['handler']=='enable-system-unit'
assert by_id['libvirt-default-network']['requires']==['libvirtd-service']
assert by_id['power-profiles-service']['conflict_set']=='power-owner-conflicts'
assert not p['overall']['blockers'] and not p['overall']['unavailable_checks']
assert p['apply']['authorized'] is False and p['apply']['commands'] is None
PY

python "$tool" --profile vm --json >"$test_root/vm.json"
python - "$test_root/vm.json" <<'PY'
import json,sys
p=json.load(open(sys.argv[1]));by={x['id']:x for x in p['actions']}
assert p['counts']=={'selected':11,'apply':4,'verify':7,'manual':0,'deferred':0,'root_apply':2,'user_apply':2}
for action in ('base-network-handoff','base-package-preconditions','failed-unit-baseline','time-sync-service','audio-package-activation','portal-package-activation','fcitx-session-owner','dms-niri-session-wants','dsearch-user-service','fcitx-system-environment','relogin-reboot-report'):
  assert action in by,action
for forbidden in ('bluetooth-service','power-profiles-service','docker-service','libvirtd-service','locale-zh-cn','physical-hardware-acceptance','greeter-login-manager'):
  assert forbidden not in by,forbidden
PY

# Exact module selection is never merged with defaults.  Missing action-level
# prerequisites are deterministic blockers rather than silently inferred work.
set +e
python "$tool" --profile asus-amd-nvidia --modules power --json >"$test_root/power.json"
power_status=$?
set -e
((power_status == 1)) || { cat "$test_root/power.json" >&2; printf 'power-only plan exited %s\n' "$power_status" >&2; exit 1; }
python - "$test_root/power.json" <<'PY'
import json,sys
p=json.load(open(sys.argv[1]));assert p['selection']['requested_modules']==['power'];assert p['overall']['status']=='blocked';assert any('base-package-preconditions' in x for x in p['overall']['blockers']);assert p['apply']['authorized'] is False
PY

# Every manifest action, dependency and conflict reference is represented once;
# malformed query/data is unavailable/fatal, not an empty plan.
python - "$root" <<'PY'
from pathlib import Path
import sys
root=Path(sys.argv[1])
actions=[l for l in (root/'manifests/system-actions.tsv').read_text().splitlines() if l and not l.startswith('#')]
conflicts=[l for l in (root/'manifests/system-action-conflicts.tsv').read_text().splitlines() if l and not l.startswith('#')]
assert len(actions)==30 and len(conflicts)==5
assert len({x.split('\t',1)[0] for x in actions})==30
assert len({x.split('\t',1)[0] for x in conflicts})==5
PY

if grep -Eq '"argv"|sudo pacman|gsudo --|systemctl enable --now|virsh net-start default' "$test_root/asus.json"; then
  printf '%s\n' 'system action plan exposed an executable command' >&2
  exit 1
fi
printf '%s\n' 'System action manifest/plan checks passed.'
