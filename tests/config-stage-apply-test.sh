#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source_tool="$root/installer/config-stage-apply.py"
[[ -f $source_tool && ! -L $source_tool ]] || { printf '%s\n' 'config stage adapter is missing or unsafe' >&2; exit 1; }

test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT
fixture="$test_root/project"
tool="$fixture/installer/config-stage-apply.py"
home="$test_root/home"
state="$test_root/state"
mkdir -p "$fixture/installer" "$fixture/manifests" "$fixture/config/home/.config/app" "$fixture/config/home/scripts" "$home"
cp -- "$source_tool" "$tool"
chmod 755 "$tool"
cat >"$fixture/manifests/modules.tsv" <<'MANIFEST'
# schema=1
# module<TAB>availability<TAB>kind<TAB>requires-all<TAB>requires-any<TAB>purpose
config	available	selectable	-	-	Fixture config
scripts	available	selectable	-	-	Fixture scripts
bootstrap	available	dependency	-	-	Fixture privilege bootstrap
MANIFEST
cat >"$fixture/manifests/profile-modules.tsv" <<'MANIFEST'
# schema=1
# profile<TAB>config-scope<TAB>module<TAB>default-state
test	fixture-v1	config	selected
test	fixture-v1	scripts	selected
none	none	config	selected
MANIFEST
cat >"$fixture/manifests/config-mappings.tsv" <<'MANIFEST'
# schema=2
# scope<TAB>module<TAB>source<TAB>target
fixture-v1	config	config/home/.config/app/config.ini	.config/app/config.ini
fixture-v1	scripts	config/home/scripts/tool	scripts/tool
fixture-v1	config	config/home/scripts/desktop/gsudo	scripts/desktop/gsudo
fixture-v1	config	config/home/scripts/desktop/fuzzel-askpass	scripts/desktop/fuzzel-askpass
MANIFEST
printf 'fixture=true\n' >"$fixture/config/home/.config/app/config.ini"
printf '#!/usr/bin/env bash\nprintf fixture\\n\n' >"$fixture/config/home/scripts/tool"
mkdir -p "$fixture/config/home/scripts/desktop"
printf '#!/usr/bin/env bash\nexit 0\n' >"$fixture/config/home/scripts/desktop/gsudo"
printf '#!/usr/bin/env bash\nexit 0\n' >"$fixture/config/home/scripts/desktop/fuzzel-askpass"
chmod 755 "$fixture/config/home/scripts/desktop/gsudo" "$fixture/config/home/scripts/desktop/fuzzel-askpass"
chmod 644 "$fixture/config/home/.config/app/config.ini"
chmod 755 "$fixture/config/home/scripts/tool"

effects=$(python - "$fixture" <<'PY'
import hashlib,json,sys
from pathlib import Path
r=Path(sys.argv[1])
items=[]
for module,src,target in [
 ('config','config/home/.config/app/config.ini','.config/app/config.ini'),
 ('scripts','config/home/scripts/tool','scripts/tool'),
]:
 items.append({'id':f'deploy:{target}','module':module,'detail':f'source={src} target={target}','payload_sha256':hashlib.sha256((r/src).read_bytes()).hexdigest()})
items.sort(key=lambda x:x['id'].removeprefix('deploy:'))
print(json.dumps(items,sort_keys=True,separators=(',',':')))
PY
)

fail() { printf 'config stage adapter test failed: %s\n' "$*" >&2; exit 1; }
run_case() {
  local name=$1 action=$2 mode=${3:-new} effect_value=${4:-$effects}
  local fingerprint=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  local run_id=20260801T010101Z-bbbbbbbbbbbb
  if [[ $mode == reconcile ]]; then
    fingerprint=dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
    run_id=20260801T020202Z-dddddddddddd
  fi
  shift 4 || true
  set +e
  env HOME="$home" XDG_STATE_HOME="$state" \
    FULL_ORCHESTRATOR_ACTION="$action" \
    FULL_ORCHESTRATOR_STAGE=user-config \
    FULL_ORCHESTRATOR_PROFILE=test \
    FULL_ORCHESTRATOR_MODE="$mode" \
    FULL_ORCHESTRATOR_MODULES=config,scripts \
    FULL_ORCHESTRATOR_STAGE_MODULES=config,scripts \
    FULL_ORCHESTRATOR_EFFECTS_JSON="$effect_value" \
    FULL_ORCHESTRATOR_PLAN_FINGERPRINT="$fingerprint" \
    FULL_ORCHESTRATOR_RUN_ID="$run_id" \
    FULL_ORCHESTRATOR_ATTEMPT=1 \
    "$@" python "$tool" >"$test_root/$name.out" 2>&1
  CASE_STATUS=$?
  set -e
  CASE_OUTPUT="$test_root/$name.out"
}

privilege_effects=$(python - "$fixture" <<'PY'
import hashlib,json,sys
from pathlib import Path
r=Path(sys.argv[1]);items=[]
for target in ('scripts/desktop/fuzzel-askpass','scripts/desktop/gsudo'):
 src=f'config/home/{target}'
 items.append({'id':f'deploy:{target}','module':'config','detail':f'source={src} target={target}','payload_sha256':hashlib.sha256((r/src).read_bytes()).hexdigest()})
print(json.dumps(items,sort_keys=True,separators=(',',':')))
PY
)
priv_home="$test_root/privilege-home"
mkdir -p "$priv_home"
run_privilege() {
  local action=$1
  set +e
  HOME="$priv_home" XDG_STATE_HOME="$test_root/privilege-state" \
    FULL_ORCHESTRATOR_ACTION="$action" FULL_ORCHESTRATOR_STAGE=privilege-wrapper \
    FULL_ORCHESTRATOR_PROFILE=test FULL_ORCHESTRATOR_MODE=new \
    FULL_ORCHESTRATOR_MODULES=config,scripts FULL_ORCHESTRATOR_STAGE_MODULES=config \
    FULL_ORCHESTRATOR_EFFECTS_JSON="$privilege_effects" \
    FULL_ORCHESTRATOR_PLAN_FINGERPRINT=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee \
    FULL_ORCHESTRATOR_RUN_ID=20260801T030303Z-eeeeeeeeeeee FULL_ORCHESTRATOR_ATTEMPT=1 \
    python "$tool" >"$test_root/privilege-$action.out" 2>&1
  PRIV_STATUS=$?
  set -e
}
run_privilege preflight
((PRIV_STATUS == 0)) || { cat "$test_root/privilege-preflight.out" >&2; fail "privilege preflight exited $PRIV_STATUS"; }
[[ ! -e "$priv_home/scripts" && ! -e "$test_root/privilege-state" ]] || fail 'privilege preflight wrote files/state'
run_privilege execute
((PRIV_STATUS == 0)) || { cat "$test_root/privilege-execute.out" >&2; fail "privilege execute exited $PRIV_STATUS"; }
test -x "$priv_home/scripts/desktop/gsudo"
test -x "$priv_home/scripts/desktop/fuzzel-askpass"
[[ $(find "$priv_home" -type f | wc -l) == 2 ]] || fail 'privilege stage deployed more than two files'
run_privilege verify
((PRIV_STATUS == 0)) || { cat "$test_root/privilege-verify.out" >&2; fail "privilege verify exited $PRIV_STATUS"; }

# Backup inventory is a separate read-only interface. A missing private state
# tree is a successful empty query and must not create it.
HOME="$home" XDG_STATE_HOME="$state" python "$tool" --list-backups >"$test_root/backups-empty.json"
python - "$test_root/backups-empty.json" <<'PY'
import json,sys
p=json.load(open(sys.argv[1]));assert p=={'schema':1,'backups':[]}
PY
[[ ! -e $state ]] || fail 'empty backup listing created state'

# Preflight is genuinely read-only and discloses exact create/replace/unchanged
# classifications before any run state, backup, or target directory exists.
run_case preflight preflight new "$effects"
((CASE_STATUS == 0)) || { cat "$CASE_OUTPUT" >&2; fail "preflight exited $CASE_STATUS"; }
[[ ! -e $home/.config && ! -e $home/scripts && ! -e $state ]] || fail 'preflight wrote target/state paths'
grep -Fq 'create .config/app/config.ini' "$CASE_OUTPUT" || fail 'preflight omitted config create classification'
grep -Fq 'create scripts/tool' "$CASE_OUTPUT" || fail 'preflight omitted script create classification'

# Existing changed targets are backed up once with original mode/content, then
# both targets are installed atomically with reviewed source modes.
mkdir -p "$home/.config/app"
printf 'old=true\n' >"$home/.config/app/config.ini"
chmod 600 "$home/.config/app/config.ini"
run_case execute execute new "$effects"
((CASE_STATUS == 0)) || { cat "$CASE_OUTPUT" >&2; fail "execute exited $CASE_STATUS"; }
cmp -s "$fixture/config/home/.config/app/config.ini" "$home/.config/app/config.ini" || fail 'config content was not deployed'
cmp -s "$fixture/config/home/scripts/tool" "$home/scripts/tool" || fail 'script content was not deployed'
[[ $(stat -c '%a' "$home/.config/app/config.ini") == 644 ]] || fail 'config mode was not deployed'
[[ $(stat -c '%a' "$home/scripts/tool") == 755 ]] || fail 'script mode was not deployed'
backup_root="$state/my-archlinux-setup/backups/20260801T010101Z-bbbbbbbbbbbb-user-config"
[[ -f $backup_root/.config/app/config.ini ]] || fail 'changed target backup missing'
grep -Fqx 'old=true' "$backup_root/.config/app/config.ini" || fail 'backup content changed'
[[ $(stat -c '%a' "$backup_root/.config/app/config.ini") == 600 ]] || fail 'backup mode was not preserved'
provenance="$state/my-archlinux-setup/config-stage/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-user-config.json"
[[ -f $provenance && $(stat -c '%a' "$provenance") == 600 ]] || fail 'private config provenance missing/wrong mode'
[[ $(stat -c '%a' "$(dirname "$provenance")") == 700 ]] || fail 'config state directory is not mode 700'
python - "$provenance" <<'PY'
import json,sys
p=json.load(open(sys.argv[1]));assert p['schema']==1 and p['status']=='completed';assert p['mode']=='new';assert len(p['targets'])==2;assert {x['status'] for x in p['targets']}=={'deployed'};assert all('content' not in x for x in p['targets'])
PY

backup_id=20260801T010101Z-bbbbbbbbbbbb-user-config
[[ -f $backup_root/.backup.json && $(stat -c '%a' "$backup_root/.backup.json") == 600 ]] \
  || fail 'backup metadata missing/wrong mode'
HOME="$home" XDG_STATE_HOME="$state" python "$tool" --list-backups >"$test_root/backups-one.json"
python - "$test_root/backups-one.json" "$backup_id" <<'PY'
import json,sys
p=json.load(open(sys.argv[1]));assert p['schema']==1 and len(p['backups'])==1
b=p['backups'][0];assert b['id']==sys.argv[2] and b['status']=='completed' and b['restorable'] is True
assert b['profile']=='test' and b['stage']=='user-config' and b['targets']==['.config/app/config.ini']
PY

run_case verify verify new "$effects"
((CASE_STATUS == 0)) || { cat "$CASE_OUTPUT" >&2; fail "verification exited $CASE_STATUS"; }

# An intentional rerun is idempotent: no second backup appears and provenance
# records exact unchanged results.
before_backup_hash=$(sha256sum "$backup_root/.config/app/config.ini" | awk '{print $1}')
run_case rerun execute new "$effects"
((CASE_STATUS == 0)) || { cat "$CASE_OUTPUT" >&2; fail "rerun exited $CASE_STATUS"; }
[[ $(find "$state/my-archlinux-setup/backups" -mindepth 1 -maxdepth 1 -type d | wc -l) == 1 ]] || fail 'idempotent rerun created another backup root'
[[ $(sha256sum "$backup_root/.config/app/config.ini" | awk '{print $1}') == "$before_backup_hash" ]] || fail 'rerun overwrote prior backup'
python - "$provenance" <<'PY'
import json,sys
p=json.load(open(sys.argv[1]));assert p['status']=='completed';assert {x['status'] for x in p['targets']}=={'unchanged'}
PY

# Restore is constrained to one manifest-backed approved target set. It first
# previews, requires the exact backup id as confirmation, and makes a reversible
# pre-restore backup before changing any target.
printf 'post-install-local=true\n' >"$home/.config/app/config.ini"
chmod 640 "$home/.config/app/config.ini"
before_restore_hash=$(sha256sum "$home/.config/app/config.ini" | awk '{print $1}')
before_restore_count=$(find "$state/my-archlinux-setup/backups" -mindepth 1 -maxdepth 1 -type d | wc -l)
set +e
printf 'cancel\n' | HOME="$home" XDG_STATE_HOME="$state" \
  python "$tool" --restore-backup "$backup_id" >"$test_root/restore-cancel.out" 2>&1
restore_cancel_status=$?
set -e
((restore_cancel_status == 1)) || { cat "$test_root/restore-cancel.out" >&2; fail "cancelled restore exited $restore_cancel_status"; }
[[ $(sha256sum "$home/.config/app/config.ini" | awk '{print $1}') == "$before_restore_hash" ]] \
  || fail 'cancelled restore changed target'
[[ $(find "$state/my-archlinux-setup/backups" -mindepth 1 -maxdepth 1 -type d | wc -l) == "$before_restore_count" ]] \
  || fail 'cancelled restore wrote backup state'

# A target changed while the confirmation prompt is open aborts before a
# rollback backup/state write; stale bytes are never labelled as the current
# pre-restore state.
fifo="$test_root/restore-confirm.fifo"
mkfifo "$fifo"
set +e
HOME="$home" XDG_STATE_HOME="$state" python "$tool" --restore-backup "$backup_id" \
  <"$fifo" >"$test_root/restore-concurrent.out" 2>&1 &
restore_pid=$!
set -e
exec 9>"$fifo"
for _attempt in {1..100}; do
  grep -Fq 'confirmation required' "$test_root/restore-concurrent.out" && break
  sleep 0.01
done
grep -Fq 'confirmation required' "$test_root/restore-concurrent.out" || fail 'restore prompt was not reached'
concurrent_count=$(find "$state/my-archlinux-setup/backups" -mindepth 1 -maxdepth 1 -type d | wc -l)
printf 'concurrent=true\n' >"$home/.config/app/config.ini"
printf 'restore %s\n' "$backup_id" >&9
exec 9>&-
set +e
wait "$restore_pid"
restore_concurrent_status=$?
set -e
((restore_concurrent_status == 1)) || { cat "$test_root/restore-concurrent.out" >&2; fail "concurrent restore exited $restore_concurrent_status"; }
grep -Fqx 'concurrent=true' "$home/.config/app/config.ini" || fail 'concurrent restore overwrote changed target'
[[ $(find "$state/my-archlinux-setup/backups" -mindepth 1 -maxdepth 1 -type d | wc -l) == "$concurrent_count" ]] \
  || fail 'concurrent restore created a stale rollback backup'
printf 'post-install-local=true\n' >"$home/.config/app/config.ini"
chmod 640 "$home/.config/app/config.ini"

set +e
printf 'restore %s\n' "$backup_id" | HOME="$home" XDG_STATE_HOME="$state" \
  python "$tool" --restore-backup "$backup_id" >"$test_root/restore-apply.out" 2>&1
restore_status=$?
set -e
((restore_status == 0)) || { cat "$test_root/restore-apply.out" >&2; fail "confirmed restore exited $restore_status"; }
grep -Fqx 'old=true' "$home/.config/app/config.ini" || fail 'confirmed restore did not restore backup content'
[[ $(stat -c '%a' "$home/.config/app/config.ini") == 600 ]] || fail 'confirmed restore did not restore backup mode'
grep -Fq 'rollback-backup=' "$test_root/restore-apply.out" || fail 'restore did not report rollback backup id'

HOME="$home" XDG_STATE_HOME="$state" python "$tool" --list-backups >"$test_root/backups-after-restore.json"
rollback_backup_id=$(python - "$test_root/backups-after-restore.json" "$backup_id" <<'PY'
import json,sys
p=json.load(open(sys.argv[1]));rows=p['backups'];assert len(rows)==2
matches=[b for b in rows if b.get('source_backup_id')==sys.argv[2]];assert len(matches)==1
b=matches[0];assert b['kind']=='pre-restore' and b['restorable'] is True
assert b['targets']==['.config/app/config.ini'];print(b['id'])
PY
)
grep -Fqx 'post-install-local=true' \
  "$state/my-archlinux-setup/backups/$rollback_backup_id/.config/app/config.ini" \
  || fail 'pre-restore backup did not preserve current content'
[[ $(stat -c '%a' "$state/my-archlinux-setup/backups/$rollback_backup_id/.config/app/config.ini") == 640 ]] \
  || fail 'pre-restore backup did not preserve current mode'

# The pre-restore backup is itself restorable, proving symmetric rollback.
set +e
printf 'restore %s\n' "$rollback_backup_id" | HOME="$home" XDG_STATE_HOME="$state" \
  python "$tool" --restore-backup "$rollback_backup_id" >"$test_root/restore-rollback.out" 2>&1
restore_rollback_status=$?
set -e
((restore_rollback_status == 0)) || { cat "$test_root/restore-rollback.out" >&2; fail "restore rollback exited $restore_rollback_status"; }
grep -Fqx 'post-install-local=true' "$home/.config/app/config.ini" || fail 'restore rollback did not recover prior current content'
[[ $(stat -c '%a' "$home/.config/app/config.ini") == 640 ]] || fail 'restore rollback did not recover prior current mode'

# Unsafe ids and corrupt backup metadata are failed queries, never empty or
# healthy results, and never escape the private backup root.
set +e
printf 'restore ../escape\n' | HOME="$home" XDG_STATE_HOME="$state" \
  python "$tool" --restore-backup ../escape >"$test_root/restore-traversal.out" 2>&1
restore_traversal_status=$?
set -e
((restore_traversal_status == 2)) || { cat "$test_root/restore-traversal.out" >&2; fail "unsafe backup id exited $restore_traversal_status"; }
[[ ! -e $state/my-archlinux-setup/escape ]] || fail 'unsafe backup id escaped backup root'
mkdir -m 700 "$state/my-archlinux-setup/backups/corrupt"
printf '{}\n' >"$state/my-archlinux-setup/backups/corrupt/.backup.json"
chmod 600 "$state/my-archlinux-setup/backups/corrupt/.backup.json"
set +e
HOME="$home" XDG_STATE_HOME="$state" python "$tool" --list-backups >"$test_root/backups-corrupt.out" 2>&1
corrupt_status=$?
set -e
((corrupt_status == 2)) || { cat "$test_root/backups-corrupt.out" >&2; fail "corrupt backup query exited $corrupt_status"; }
rm -rf -- "$state/my-archlinux-setup/backups/corrupt"

# Reconcile is a distinct fingerprint-bound mode and still backs up only a
# changed managed target; unrelated HOME content remains untouched.
printf 'local-change=true\n' >"$home/.config/app/config.ini"
printf 'unmanaged\n' >"$home/.config/unmanaged"
run_case reconcile-preflight preflight reconcile "$effects"
((CASE_STATUS == 0)) || { cat "$CASE_OUTPUT" >&2; fail "reconcile preflight exited $CASE_STATUS"; }
grep -Fq 'replace .config/app/config.ini' "$CASE_OUTPUT" || fail 'reconcile did not disclose replacement'
run_case reconcile-execute execute reconcile "$effects"
((CASE_STATUS == 0)) || { cat "$CASE_OUTPUT" >&2; fail "reconcile execute exited $CASE_STATUS"; }
grep -Fqx unmanaged "$home/.config/unmanaged" || fail 'reconcile touched unrelated config'

# Verifier distinguishes deterministic drift/missing targets from failed
# inspection; it never calls them healthy.
printf 'drift\n' >"$home/scripts/tool"
run_case verify-drift verify new "$effects"
((CASE_STATUS == 1)) || { cat "$CASE_OUTPUT" >&2; fail "drift verification exited $CASE_STATUS"; }
rm -f -- "$home/scripts/tool"
run_case verify-missing verify new "$effects"
((CASE_STATUS == 1)) || { cat "$CASE_OUTPUT" >&2; fail "missing verification exited $CASE_STATUS"; }
run_case restore execute new "$effects"
((CASE_STATUS == 0)) || { cat "$CASE_OUTPUT" >&2; fail "restore execute exited $CASE_STATUS"; }

# Fingerprint-bound effects are not an arbitrary copy interface.
tampered=$(python - "$effects" <<'PY'
import json,sys
p=json.loads(sys.argv[1]);p[0]['payload_sha256']='0'*64;print(json.dumps(p,separators=(',',':')))
PY
)
run_case effect-drift preflight new "$tampered"
((CASE_STATUS == 2)) || { cat "$CASE_OUTPUT" >&2; fail "effect drift exited $CASE_STATUS"; }
source_hash_before=$(sha256sum "$home/.config/app/config.ini" | awk '{print $1}')
printf 'source-drift=true\n' >>"$fixture/config/home/.config/app/config.ini"
run_case source-drift preflight new "$effects"
((CASE_STATUS == 2)) || { cat "$CASE_OUTPUT" >&2; fail "source drift exited $CASE_STATUS"; }
[[ $(sha256sum "$home/.config/app/config.ini" | awk '{print $1}') == "$source_hash_before" ]] || fail 'source drift changed target'
# Restore source and original effect payload.
printf 'fixture=true\n' >"$fixture/config/home/.config/app/config.ini"

# Symlink and hard-link targets fail in preflight before any target is changed.
rm -f -- "$home/.config/app/config.ini"
ln -s /tmp/forbidden "$home/.config/app/config.ini"
run_case symlink-target preflight new "$effects"
((CASE_STATUS == 2)) || { cat "$CASE_OUTPUT" >&2; fail "symlink target exited $CASE_STATUS"; }
rm -f -- "$home/.config/app/config.ini"
printf 'hardlink\n' >"$home/.config/app/config.ini"
ln "$home/.config/app/config.ini" "$home/.config/app/config-hardlink"
run_case hardlink-target preflight new "$effects"
((CASE_STATUS == 2)) || { cat "$CASE_OUTPUT" >&2; fail "hardlink target exited $CASE_STATUS"; }

# A profile with config scope none has no applicable user-config stage and is
# rejected if invoked rather than silently treated as successful empty work.
set +e
env HOME="$home" XDG_STATE_HOME="$state" \
  FULL_ORCHESTRATOR_ACTION=preflight FULL_ORCHESTRATOR_STAGE=user-config \
  FULL_ORCHESTRATOR_PROFILE=none FULL_ORCHESTRATOR_MODE=new \
  FULL_ORCHESTRATOR_MODULES=config FULL_ORCHESTRATOR_STAGE_MODULES=none \
  FULL_ORCHESTRATOR_EFFECTS_JSON='[]' \
  FULL_ORCHESTRATOR_PLAN_FINGERPRINT=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc \
  FULL_ORCHESTRATOR_RUN_ID=preflight-cccccccccccc FULL_ORCHESTRATOR_ATTEMPT=1 \
  python "$tool" >"$test_root/none.out" 2>&1
none_status=$?
set -e
((none_status == 2)) || { cat "$test_root/none.out" >&2; fail "non-applicable invocation exited $none_status"; }

# A same-user writer landing after the final snapshot check but immediately
# before the commit must not be silently overwritten. The audit hook injects
# that exact race at the rename boundary; production must detect it, restore the
# concurrent bytes, and fail closed.
python3 - "$tool" "$test_root/final-race" <<'PY'
import errno
import hashlib
import importlib.util
import os
from pathlib import Path
import sys

sys.dont_write_bytecode = True
path = Path(sys.argv[1])
root = Path(sys.argv[2])
home = root / "home"
target = home / ".config/app/config.ini"
target.parent.mkdir(parents=True, mode=0o700)
home.chmod(0o700)
(home / ".config").chmod(0o700)
target.parent.chmod(0o700)
target.write_bytes(b"reviewed-before\n")
target.chmod(0o600)

spec = importlib.util.spec_from_file_location("config_stage_final_race", path)
assert spec is not None and spec.loader is not None
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)
source_data = b"reviewed-after\n"
mapping = module.Mapping(
    "fixture-v1",
    "config",
    "config/home/.config/app/config.ini",
    ".config/app/config.ini",
    path,
    source_data,
    hashlib.sha256(source_data).hexdigest(),
    0o600,
)
snapshot = module.inspect_target(home, mapping)
plan = module.TargetPlan(mapping, snapshot, "replace")
concurrent = b"concurrent-final-window\n"
raced = False


def audit(event, args):
    global raced
    if raced or event not in {"os.rename", "myarch.config-conditional-replace"}:
        return
    if len(args) < 2 or Path(os.fspath(args[1])) != target:
        return
    raced = True
    target.write_bytes(concurrent)
    target.chmod(0o600)


sys.addaudithook(audit)
failed_closed = False
try:
    module.deploy_target(home, plan)
except module.ConfigFailure:
    failed_closed = True
assert raced, "race injection did not reach the final commit boundary"
assert failed_closed, "final-window race was not rejected"
assert target.read_bytes() == concurrent, "concurrent target content was overwritten"

# Restore replacement has a narrower second race window: after the first
# exchange discovers a displaced snapshot mismatch, another writer can change
# the newly installed inode before the rollback exchange.  The rollback must
# restore the first writer at the target while retaining the second writer at a
# clearly reported recovery path instead of deleting it as installer scratch.
double_target = home / ".config/app/double.ini"
double_target.write_bytes(b"double-reviewed-before\n")
double_target.chmod(0o600)
double_mapping = module.Mapping(
    "fixture-v1",
    "config",
    "config/home/.config/app/config.ini",
    ".config/app/double.ini",
    path,
    source_data,
    hashlib.sha256(source_data).hexdigest(),
    0o600,
)
double_snapshot = module.inspect_target(home, double_mapping)
double_plan = module.RestorePlan(
    double_mapping,
    double_snapshot,
    True,
    source_data,
    hashlib.sha256(source_data).hexdigest(),
    0o600,
    "replace",
)
first_concurrent = b"first-concurrent-restore-writer\n"
second_concurrent = b"second-concurrent-restore-writer\n"
real_renameat2 = module.renameat2
double_exchange_calls = 0
installer_temporary = None
installer_temporary_inode = None


def double_raced_rename(path_from, path_to, flags, *, audit=True):
    global double_exchange_calls, installer_temporary, installer_temporary_inode
    if Path(path_to) != double_target or flags != module.RENAME_EXCHANGE:
        return real_renameat2(path_from, path_to, flags, audit=audit)
    double_exchange_calls += 1
    if double_exchange_calls == 1:
        double_target.write_bytes(first_concurrent)
        double_target.chmod(0o620)
        installer_temporary = Path(path_from)
        installer_temporary_inode = installer_temporary.stat().st_ino
        real_renameat2(path_from, path_to, flags, audit=audit)
        double_target.write_bytes(second_concurrent)
        double_target.chmod(0o640)
        return None
    return real_renameat2(path_from, path_to, flags, audit=audit)


module.renameat2 = double_raced_rename
double_error = None
try:
    module.atomically_restore_target(home, double_plan)
except module.ConfigFailure as exc:
    double_error = exc
finally:
    module.renameat2 = real_renameat2
assert double_exchange_calls == 2, "double race did not exercise exchange and rollback"
assert double_error is not None, "double concurrent restore race was not rejected"
assert double_target.read_bytes() == first_concurrent, "first concurrent restore writer was lost"
assert double_target.stat().st_mode & 0o777 == 0o620
double_recovery = sorted(double_target.parent.glob(".my-arch-restore-double.ini.*"))
assert len(double_recovery) == 1, "second concurrent restore writer was not retained"
assert double_recovery[0].read_bytes() == second_concurrent
assert double_recovery[0].stat().st_mode & 0o777 == 0o640
assert double_recovery[0].stat().st_ino == installer_temporary_inode
assert installer_temporary == double_recovery[0]
assert getattr(double_error, "preserve_temporary", False)
assert getattr(double_error, "recovery_path", None) == double_recovery[0]
assert str(double_recovery[0]) in str(double_error), "recovery path was not reported"

# With only the first writer, rollback puts the unchanged installer temporary
# back at its original name.  Its payload, mode, and inode all still match, so
# it is scratch rather than recovery data and must not be left behind.
single_target = home / ".config/app/single-restore.ini"
single_target.write_bytes(b"single-reviewed-before\n")
single_target.chmod(0o600)
single_mapping = module.Mapping(
    "fixture-v1",
    "config",
    "config/home/.config/app/config.ini",
    ".config/app/single-restore.ini",
    path,
    source_data,
    hashlib.sha256(source_data).hexdigest(),
    0o600,
)
single_snapshot = module.inspect_target(home, single_mapping)
single_plan = module.RestorePlan(
    single_mapping,
    single_snapshot,
    True,
    source_data,
    hashlib.sha256(source_data).hexdigest(),
    0o600,
    "replace",
)
single_concurrent = b"single-concurrent-restore-writer\n"
single_exchange_calls = 0
single_temporary = None


def single_raced_rename(path_from, path_to, flags, *, audit=True):
    global single_exchange_calls, single_temporary
    if Path(path_to) != single_target or flags != module.RENAME_EXCHANGE:
        return real_renameat2(path_from, path_to, flags, audit=audit)
    single_exchange_calls += 1
    if single_exchange_calls == 1:
        single_target.write_bytes(single_concurrent)
        single_target.chmod(0o620)
        single_temporary = Path(path_from)
    return real_renameat2(path_from, path_to, flags, audit=audit)


module.renameat2 = single_raced_rename
single_error = None
try:
    module.atomically_restore_target(home, single_plan)
except module.ConfigFailure as exc:
    single_error = exc
finally:
    module.renameat2 = real_renameat2
assert single_exchange_calls == 2, "single race did not exercise exchange and rollback"
assert single_error is not None, "single concurrent restore race was not rejected"
assert not getattr(single_error, "preserve_temporary", False)
assert single_target.read_bytes() == single_concurrent
assert single_target.stat().st_mode & 0o777 == 0o620
assert single_temporary is not None and not single_temporary.exists()
assert not list(single_target.parent.glob(".my-arch-restore-single-restore.ini.*")), (
    "single concurrent restore left a spurious recovery file"
)

# If the rollback exchange itself fails, the displaced concurrent target is
# still at temporary.  It must remain available and be named in the failure.
rollback_failure_target = home / ".config/app/rollback-failure.ini"
rollback_failure_target.write_bytes(b"rollback-reviewed-before\n")
rollback_failure_target.chmod(0o600)
rollback_failure_mapping = module.Mapping(
    "fixture-v1",
    "config",
    "config/home/.config/app/config.ini",
    ".config/app/rollback-failure.ini",
    path,
    source_data,
    hashlib.sha256(source_data).hexdigest(),
    0o600,
)
rollback_failure_snapshot = module.inspect_target(home, rollback_failure_mapping)
rollback_failure_plan = module.RestorePlan(
    rollback_failure_mapping,
    rollback_failure_snapshot,
    True,
    source_data,
    hashlib.sha256(source_data).hexdigest(),
    0o600,
    "replace",
)
rollback_failure_concurrent = b"rollback-failure-concurrent-writer\n"
rollback_failure_calls = 0
rollback_failure_temporary = None


def failed_rollback_rename(path_from, path_to, flags, *, audit=True):
    global rollback_failure_calls, rollback_failure_temporary
    if Path(path_to) != rollback_failure_target or flags != module.RENAME_EXCHANGE:
        return real_renameat2(path_from, path_to, flags, audit=audit)
    rollback_failure_calls += 1
    if rollback_failure_calls == 1:
        rollback_failure_target.write_bytes(rollback_failure_concurrent)
        rollback_failure_target.chmod(0o620)
        rollback_failure_temporary = Path(path_from)
        return real_renameat2(path_from, path_to, flags, audit=audit)
    raise OSError(errno.EIO, "injected rollback exchange failure")


module.renameat2 = failed_rollback_rename
rollback_failure_error = None
try:
    module.atomically_restore_target(home, rollback_failure_plan)
except module.ConfigFailure as exc:
    rollback_failure_error = exc
finally:
    module.renameat2 = real_renameat2
assert rollback_failure_calls == 2, "rollback failure injection did not reach rollback"
assert rollback_failure_error is not None, "rollback exchange failure was not reported"
assert getattr(rollback_failure_error, "preserve_temporary", False)
assert getattr(rollback_failure_error, "recovery_path", None) == rollback_failure_temporary
assert rollback_failure_temporary is not None and rollback_failure_temporary.exists()
assert rollback_failure_temporary.read_bytes() == rollback_failure_concurrent
assert rollback_failure_temporary.stat().st_mode & 0o777 == 0o620
assert str(rollback_failure_temporary) in str(rollback_failure_error)
assert rollback_failure_target.read_bytes() == source_data
assert rollback_failure_target.stat().st_mode & 0o777 == 0o600

# Adjacent absent-target boundary: a file created at commit time must make the
# no-replace operation fail while preserving the creator's bytes.
new_target = home / ".config/app/new.ini"
new_mapping = module.Mapping(
    "fixture-v1",
    "config",
    "config/home/.config/app/config.ini",
    ".config/app/new.ini",
    path,
    source_data,
    hashlib.sha256(source_data).hexdigest(),
    0o600,
)
new_snapshot = module.inspect_target(home, new_mapping)
assert not new_snapshot.exists
new_plan = module.TargetPlan(new_mapping, new_snapshot, "create")
new_concurrent = b"concurrent-create-window\n"
new_raced = False


def audit_create(event, args):
    global new_raced
    if new_raced or event != "myarch.config-conditional-replace":
        return
    if len(args) < 2 or Path(os.fspath(args[1])) != new_target:
        return
    new_raced = True
    new_target.write_bytes(new_concurrent)
    new_target.chmod(0o600)


sys.addaudithook(audit_create)
new_failed_closed = False
try:
    module.deploy_target(home, new_plan)
except module.ConfigFailure:
    new_failed_closed = True
assert new_raced, "absent-target race injection did not reach commit"
assert new_failed_closed, "concurrent target creation was not rejected"
assert new_target.read_bytes() == new_concurrent

delete_target = home / ".config/app/delete.ini"
delete_target.write_bytes(b"delete-before\n")
delete_target.chmod(0o600)
delete_mapping = module.Mapping(
    "fixture-v1",
    "config",
    "config/home/.config/app/config.ini",
    ".config/app/delete.ini",
    path,
    source_data,
    hashlib.sha256(source_data).hexdigest(),
    0o600,
)
delete_snapshot = module.inspect_target(home, delete_mapping)
delete_plan = module.RestorePlan(
    delete_mapping,
    delete_snapshot,
    False,
    None,
    None,
    None,
    "remove",
)
delete_concurrent = b"concurrent-delete-window\n"
delete_raced = False


def audit_delete(event, args):
    global delete_raced
    if delete_raced or event not in {"os.remove", "myarch.config-conditional-remove"}:
        return
    if not args or Path(os.fspath(args[0])) != delete_target:
        return
    delete_raced = True
    delete_target.write_bytes(delete_concurrent)
    delete_target.chmod(0o600)


sys.addaudithook(audit_delete)
delete_failed_closed = False
try:
    module.atomically_restore_target(home, delete_plan)
except module.ConfigFailure:
    delete_failed_closed = True
assert delete_raced, "delete race did not reach the removal boundary"
assert delete_failed_closed, "final-window delete race was not rejected"
assert delete_target.read_bytes() == delete_concurrent, "concurrent delete target was lost"
PY

printf '%s\n' 'Config stage adapter checks passed.'
