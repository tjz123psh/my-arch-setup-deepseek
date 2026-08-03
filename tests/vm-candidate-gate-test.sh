#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source_tool="$root/installer/vm-candidate-gate.py"
[[ -f $source_tool && ! -L $source_tool ]] || {
  printf '%s\n' 'vm candidate gate test failed: tool is missing or unsafe' >&2
  exit 1
}

test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT
fixture="$test_root/project";home="$test_root/home";state="$test_root/state"
mkdir -p "$fixture/installer" "$fixture/manifests" "$home" "$test_root/bin"
cp -- "$source_tool" "$fixture/installer/vm-candidate-gate.py"
cp -- "$root/manifests/modules.tsv" "$root/manifests/stages.tsv" "$fixture/manifests/"
# Keep the transaction/race fixture closed even after the canonical manifests
# are promoted by the completed disposable-VM matrix.
python3 - "$fixture/manifests/modules.tsv" "$fixture/manifests/stages.tsv" <<'PY_FIXTURE_GATES'
import csv
import sys
from pathlib import Path

modules, stages = map(Path, sys.argv[1:])
module_targets = {
    "base-preconditions", "archlinuxcn-trust", "build-foundation", "fonts", "audio",
}
lines = modules.read_text().splitlines()
for index, row in enumerate(csv.reader(lines[1:], delimiter="\t"), 1):
    if not row or row[0].startswith("#"):
        continue
    assert len(row) == 6
    if row[0] in module_targets:
        row[1] = "planning"
        lines[index] = "\t".join(row)
modules.write_text("\n".join(lines) + "\n")

lines = stages.read_text().splitlines()
for index, row in enumerate(csv.reader(lines[1:], delimiter="\t"), 1):
    if not row or row[0].startswith("#"):
        continue
    assert len(row) == 8
    row[6] = "false"
    lines[index] = "\t".join(row)
stages.write_text("\n".join(lines) + "\n")
PY_FIXTURE_GATES
chmod 755 "$fixture/installer/vm-candidate-gate.py"
fail() { printf 'vm candidate gate test failed: %s\n' "$*" >&2; exit 1; }

cat >"$test_root/bin/detect-vm" <<'SH'
#!/usr/bin/env bash
printf 'detect-vm\n' >>"$DETECT_LOG"
exit "${DETECT_STATUS:-0}"
SH
chmod 755 "$test_root/bin/detect-vm"
export VM_CANDIDATE_GATE_TESTING=1 VM_CANDIDATE_GATE_DETECTOR="$test_root/bin/detect-vm"
export DETECT_LOG="$test_root/detect.log"

modules="$fixture/manifests/modules.tsv";stages="$fixture/manifests/stages.tsv"
original_modules=$(sha256sum "$modules" | awk '{print $1}')
original_stages=$(sha256sum "$stages" | awk '{print $1}')

HOME="$home" XDG_STATE_HOME="$state" python "$fixture/installer/vm-candidate-gate.py" --plan --json >"$test_root/plan.json"
python - "$test_root/plan.json" <<'PY'
import json,sys
p=json.load(open(sys.argv[1]));assert p['schema']==1 and p['action']=='plan'
assert p['stage_changes']==[
 'privilege-wrapper','official-update','official-packages','archlinuxcn-bootstrap',
 'archlinuxcn-packages','aur-source-acquisition','aur-build-install','user-config','system-actions']
assert p['module_changes']==['base-preconditions','archlinuxcn-trust','build-foundation','fonts','audio']
assert p['system_changes'] is False and p['requires_vm'] is True
PY
[[ ! -e $state && ! -s $DETECT_LOG ]] || fail 'read-only candidate plan wrote state or queried VM runtime'
[[ $(sha256sum "$modules" | awk '{print $1}') == "$original_modules" ]] || fail 'candidate plan changed modules'

set +e
HOME="$home" XDG_STATE_HOME="$state" python "$fixture/installer/vm-candidate-gate.py" --enable >"$test_root/no-confirm.out" 2>&1
no_confirm_status=$?
set -e
((no_confirm_status == 1)) || { cat "$test_root/no-confirm.out" >&2; fail "unconfirmed enable exited $no_confirm_status"; }
[[ ! -e $state && ! -s $DETECT_LOG ]] || fail 'unconfirmed enable wrote state or queried VM'

set +e
DETECT_STATUS=1 HOME="$home" XDG_STATE_HOME="$state" \
  python "$fixture/installer/vm-candidate-gate.py" --enable --confirm-vm-candidate >"$test_root/not-vm.out" 2>&1
not_vm_status=$?
set -e
((not_vm_status == 1)) || { cat "$test_root/not-vm.out" >&2; fail "not-VM query exited $not_vm_status"; }
[[ ! -e $state ]] || fail 'not-VM blocker wrote candidate state'

set +e
DETECT_STATUS=42 HOME="$home" XDG_STATE_HOME="$state" \
  python "$fixture/installer/vm-candidate-gate.py" --enable --confirm-vm-candidate >"$test_root/vm-query-fail.out" 2>&1
vm_query_status=$?
set -e
((vm_query_status == 42)) || { cat "$test_root/vm-query-fail.out" >&2; fail "failed VM query exited $vm_query_status"; }
[[ ! -e $state ]] || fail 'failed VM query wrote candidate state'

DETECT_STATUS=0 HOME="$home" XDG_STATE_HOME="$state" \
  python "$fixture/installer/vm-candidate-gate.py" --enable --confirm-vm-candidate >"$test_root/enable.out"
! grep -q $'\tfalse\t' "$stages" || fail 'candidate enable left false stage gates'
for module in base-preconditions archlinuxcn-trust build-foundation fonts audio; do
  awk -F '\t' -v m="$module" '$1==m {found=1; if ($2!="available") exit 2} END {exit found?0:3}' "$modules" \
    || fail "candidate enable did not promote $module"
done
candidate_modules=$(sha256sum "$modules" | awk '{print $1}')
candidate_stages=$(sha256sum "$stages" | awk '{print $1}')
modules_mode=$(stat -c '%a' "$modules")
stages_mode=$(stat -c '%a' "$stages")
candidate_modules_file="$test_root/candidate-modules.tsv"
candidate_stages_file="$test_root/candidate-stages.tsv"
original_modules_file="$test_root/original-modules.tsv"
original_stages_file="$test_root/original-stages.tsv"
cp -- "$modules" "$candidate_modules_file"
cp -- "$stages" "$candidate_stages_file"
state_root="$state/my-archlinux-setup/vm-candidate-gate"
[[ -f $state_root/state.json && $(stat -c '%a' "$state_root/state.json") == 600 ]] || fail 'candidate state missing/wrong mode'
[[ $(stat -c '%a' "$state_root") == 700 && $(stat -c '%a' "$state_root/backup") == 700 ]] || fail 'candidate state dirs not private'
[[ -f $state_root/backup/modules.tsv && -f $state_root/backup/stages.tsv ]] || fail 'candidate originals not backed up'
cp -- "$state_root/backup/modules.tsv" "$original_modules_file"
cp -- "$state_root/backup/stages.tsv" "$original_stages_file"

HOME="$home" XDG_STATE_HOME="$state" python "$fixture/installer/vm-candidate-gate.py" --status --json >"$test_root/status.json"
python - "$test_root/status.json" <<'PY'
import json,sys
p=json.load(open(sys.argv[1]));assert p['status']=='enabled' and p['candidate_matches'] is True
PY
# Idempotent re-enable keeps the exact candidate and original backups.
backup_hash=$(sha256sum "$state_root/backup/modules.tsv" | awk '{print $1}')
DETECT_STATUS=0 HOME="$home" XDG_STATE_HOME="$state" \
  python "$fixture/installer/vm-candidate-gate.py" --enable --confirm-vm-candidate >/dev/null
[[ $(sha256sum "$modules" | awk '{print $1}') == "$candidate_modules" ]] || fail 'idempotent enable changed candidate modules'
[[ $(sha256sum "$state_root/backup/modules.tsv" | awk '{print $1}') == "$backup_hash" ]] || fail 'idempotent enable overwrote original backup'

# Regression: a same-user writer landing after restore's hash check but at the
# final replacement boundary must not be silently overwritten.  The audit hook
# injects the race immediately before the old os.replace call (and, after the
# fix, immediately before the conditional rename boundary).
HOME="$home" XDG_STATE_HOME="$state" python - "$fixture/installer/vm-candidate-gate.py" "$modules" <<'PY'
import importlib.util
import json
import os
from pathlib import Path
import sys

tool_path = Path(sys.argv[1])
target = Path(sys.argv[2])
candidate = target.read_bytes()
candidate_mode = target.stat().st_mode & 0o777
concurrent = b"# concurrent final-window writer\n"
raced = False

spec = importlib.util.spec_from_file_location("vm_candidate_gate_restore_race", tool_path)
assert spec is not None and spec.loader is not None
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)


def audit(event, args):
    global raced
    if raced or event not in {"os.rename", "myarch.vm-conditional-replace"}:
        return
    if len(args) < 2 or Path(os.fspath(args[1])) != target:
        return
    raced = True
    target.write_bytes(concurrent)
    target.chmod(candidate_mode)


sys.addaudithook(audit)
failed_closed = False
try:
    module.run(["--restore", "--confirm-vm-candidate"])
except module.GateFailure:
    failed_closed = True

assert raced, "restore race injection did not reach the final commit boundary"
assert failed_closed, "restore final-window race was not rejected"
assert target.read_bytes() == concurrent, "concurrent restore edit was overwritten"

# Leave the fixture usable for the remainder of this integration test when the
# fixed implementation rejects the race and keeps the cycle in progress.
target.write_bytes(candidate)
target.chmod(candidate_mode)
assert module.run(["--enable", "--confirm-vm-candidate"]) == 0
state = Path(os.environ["XDG_STATE_HOME"]) / "my-archlinux-setup/vm-candidate-gate/state.json"
assert json.loads(state.read_text())["status"] == "enabled"
PY

run_manifest_race() {
  local action=$1 target=$2 current_file=$3 concurrent_file=$4
  HOME="$home" XDG_STATE_HOME="$state" python - \
    "$fixture/installer/vm-candidate-gate.py" "$target" "$current_file" "$concurrent_file" "$action" <<'PY'
import importlib.util
import json
import os
from pathlib import Path
import sys

tool_path = Path(sys.argv[1])
target = Path(sys.argv[2])
current_file = Path(sys.argv[3])
concurrent_file = Path(sys.argv[4])
action = sys.argv[5]
current_mode = target.stat().st_mode & 0o777
concurrent = concurrent_file.read_bytes()
raced = False

spec = importlib.util.spec_from_file_location("vm_candidate_gate_boundary_race", tool_path)
assert spec is not None and spec.loader is not None
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)


def audit(event, args):
    global raced
    if raced or event not in {"os.rename", "myarch.vm-conditional-replace"}:
        return
    if event == "myarch.vm-conditional-replace" and len(args) >= 3 and args[2] != "replace":
        return
    if len(args) < 2 or Path(os.fspath(args[1])) != target:
        return
    raced = True
    target.write_bytes(concurrent)
    target.chmod(current_mode)


sys.addaudithook(audit)
failed_closed = False
try:
    result = module.run(
        (["--restore", "--confirm-vm-candidate"] if action == "restore" else
         ["--enable", "--confirm-vm-candidate"])
    )
    assert result != 0, "boundary race unexpectedly returned success"
except module.GateFailure as exc:
    failed_closed = True
    assert exc.status == 1, f"boundary race returned unexpected status {exc.status}"

assert raced, "boundary race injection did not reach the conditional commit"
assert failed_closed, "boundary race was not rejected"
assert target.read_bytes() == concurrent, "concurrent boundary edit was overwritten"
document = json.loads((Path(os.environ["XDG_STATE_HOME"]) /
                       "my-archlinux-setup/vm-candidate-gate/state.json").read_text())
assert document["status"] in {"enabling", "restoring"}, document

# Re-establish the reviewed side and let the real command resume the same
# cycle.  This also checks that a rejected exchange does not poison recovery.
target.write_bytes(current_file.read_bytes())
target.chmod(current_mode)
assert module.run(["--enable", "--confirm-vm-candidate"]) == 0
PY
}

# The adjacent stage target must use the same final conditional boundary.
printf '%s\n' '# concurrent restore/stages writer' >"$test_root/concurrent-restore-stages.tsv"
run_manifest_race restore "$stages" "$candidate_stages_file" "$test_root/concurrent-restore-stages.tsv"

# Exercise the enable path independently for both manifest targets.
cp -- "$original_modules_file" "$modules"; chmod "$modules_mode" "$modules"
printf '%s\n' '# concurrent enable/modules writer' >"$test_root/concurrent-enable-modules.tsv"
run_manifest_race enable "$modules" "$original_modules_file" "$test_root/concurrent-enable-modules.tsv"

cp -- "$original_stages_file" "$stages"; chmod "$stages_mode" "$stages"
printf '%s\n' '# concurrent enable/stages writer' >"$test_root/concurrent-enable-stages.tsv"
run_manifest_race enable "$stages" "$original_stages_file" "$test_root/concurrent-enable-stages.tsv"

# A second writer reaching the rollback exchange must not cause cleanup to
# delete that writer's bytes.  Both boundary versions remain addressable and
# the state stays non-terminal.
HOME="$home" XDG_STATE_HOME="$state" python - \
  "$fixture/installer/vm-candidate-gate.py" "$modules" <<'PY'
import importlib.util
import json
import os
from pathlib import Path
import sys

tool_path = Path(sys.argv[1])
target = Path(sys.argv[2])
candidate = target.read_bytes()
target_mode = target.stat().st_mode & 0o777
first_writer = b"# first final-window writer\n"
second_writer = b"# second rollback-window writer\n"
replace_raced = False
rollback_raced = False

spec = importlib.util.spec_from_file_location("vm_candidate_gate_second_race", tool_path)
assert spec is not None and spec.loader is not None
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)


def audit(event, args):
    global replace_raced, rollback_raced
    if event != "myarch.vm-conditional-replace" or len(args) < 3:
        return
    if Path(os.fspath(args[1])) != target:
        return
    if args[2] == "replace" and not replace_raced:
        replace_raced = True
        target.write_bytes(first_writer)
        target.chmod(target_mode)
    elif args[2] == "rollback" and not rollback_raced:
        rollback_raced = True
        target.write_bytes(second_writer)
        target.chmod(target_mode)


sys.addaudithook(audit)
failed_closed = False
try:
    module.run(["--restore", "--confirm-vm-candidate"])
except module.GateFailure as exc:
    failed_closed = True
    assert exc.status == 1
    assert "changed during rollback" in str(exc)

assert replace_raced and rollback_raced, "second race did not reach both exchanges"
assert failed_closed, "second rollback-window race was not rejected"
assert target.read_bytes() == first_writer, "first writer was not restored at the target"
retained = [
    path for path in target.parent.glob(f".{target.name}.*")
    if path.is_file() and path.read_bytes() == second_writer
]
assert retained, "second writer was not retained after rollback conflict"
state_path = (Path(os.environ["XDG_STATE_HOME"]) /
              "my-archlinux-setup/vm-candidate-gate/state.json")
assert json.loads(state_path.read_text())["status"] == "restoring"

target.write_bytes(candidate)
target.chmod(target_mode)
assert module.run(["--enable", "--confirm-vm-candidate"]) == 0
assert json.loads(state_path.read_text())["status"] == "enabled"
PY

# Exact bytes and mode are still insufficient if an editor atomically saved a
# replacement inode.  The displaced inode check must reject that otherwise
# invisible boundary change and restore the editor's directory entry.
HOME="$home" XDG_STATE_HOME="$state" python - \
  "$fixture/installer/vm-candidate-gate.py" "$modules" <<'PY'
import importlib.util
import json
import os
from pathlib import Path
import sys

tool_path = Path(sys.argv[1])
target = Path(sys.argv[2])
candidate = target.read_bytes()
target_mode = target.stat().st_mode & 0o777
reviewed_inode = target.stat().st_ino
replacement_inode = None
raced = False

spec = importlib.util.spec_from_file_location("vm_candidate_gate_inode_race", tool_path)
assert spec is not None and spec.loader is not None
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)


def audit(event, args):
    global raced, replacement_inode
    if raced or event != "myarch.vm-conditional-replace" or len(args) < 3:
        return
    if args[2] != "replace" or Path(os.fspath(args[1])) != target:
        return
    raced = True
    replacement = target.parent / ".vm-candidate-inode-race"
    replacement.write_bytes(candidate)
    replacement.chmod(target_mode)
    os.replace(replacement, target)
    replacement_inode = target.stat().st_ino


sys.addaudithook(audit)
failed_closed = False
try:
    module.run(["--restore", "--confirm-vm-candidate"])
except module.GateFailure as exc:
    failed_closed = True
    assert exc.status == 1

assert raced and replacement_inode is not None
assert replacement_inode != reviewed_inode, "test did not install a replacement inode"
assert failed_closed, "same-content replacement inode was accepted"
assert target.read_bytes() == candidate and target.stat().st_ino == replacement_inode
state_path = (Path(os.environ["XDG_STATE_HOME"]) /
              "my-archlinux-setup/vm-candidate-gate/state.json")
assert json.loads(state_path.read_text())["status"] == "restoring"
assert module.run(["--enable", "--confirm-vm-candidate"]) == 0
assert json.loads(state_path.read_text())["status"] == "enabled"
PY

# Concurrent checkout drift blocks restore; it is not overwritten to manufacture rollback.
printf '# concurrent drift\n' >>"$stages"
set +e
HOME="$home" XDG_STATE_HOME="$state" python "$fixture/installer/vm-candidate-gate.py" --restore --confirm-vm-candidate \
  >"$test_root/restore-drift.out" 2>&1
restore_drift_status=$?
set -e
((restore_drift_status == 1)) || { cat "$test_root/restore-drift.out" >&2; fail "drifted restore exited $restore_drift_status"; }
grep -Fq 'candidate manifest drifted' "$test_root/restore-drift.out" || fail 'restore drift was not explicit'
# Return to the exact generated candidate, then restore originals.
head -n -1 "$stages" >"$test_root/stages.candidate";mv "$test_root/stages.candidate" "$stages";chmod 644 "$stages"
[[ $(sha256sum "$stages" | awk '{print $1}') == "$candidate_stages" ]] || fail 'test could not reconstruct candidate stages'

# A writer landing while the terminal state JSON is being renamed must make
# restore fail and must be followed by a non-terminal state rewrite.  A stale
# "restored" record is not allowed to outlive the post-commit verification.
HOME="$home" XDG_STATE_HOME="$state" python - \
  "$fixture/installer/vm-candidate-gate.py" "$modules" "$original_modules_file" "$state_root/state.json" <<'PY'
import importlib.util
import json
import os
from pathlib import Path
import sys

tool_path = Path(sys.argv[1])
target = Path(sys.argv[2])
original_file = Path(sys.argv[3])
state_path = Path(sys.argv[4])
target_mode = target.stat().st_mode & 0o777
concurrent = original_file.read_bytes() + b"# concurrent terminal-state writer\n"
raced = False

spec = importlib.util.spec_from_file_location("vm_candidate_gate_terminal_race", tool_path)
assert spec is not None and spec.loader is not None
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)


def audit(event, args):
    global raced
    if raced or event != "os.rename" or len(args) < 2:
        return
    if Path(os.fspath(args[1])) != state_path:
        return
    source = Path(os.fspath(args[0]))
    try:
        document = json.loads(source.read_text())
    except (OSError, json.JSONDecodeError):
        return
    if document.get("status") != "restored":
        return
    raced = True
    target.write_bytes(concurrent)
    target.chmod(target_mode)


sys.addaudithook(audit)
failed_closed = False
try:
    module.run(["--restore", "--confirm-vm-candidate"])
except module.GateFailure as exc:
    failed_closed = True
    assert exc.status == 1

assert raced, "terminal-state race did not reach the restored state rename"
assert failed_closed, "terminal-state race returned success"
assert target.read_bytes() == concurrent
assert json.loads(state_path.read_text())["status"] == "restoring"

# Recover only the fixture bytes; the ordinary restore invocation below must
# finish the interrupted state transition itself.
target.write_bytes(original_file.read_bytes())
target.chmod(target_mode)
PY

HOME="$home" XDG_STATE_HOME="$state" python "$fixture/installer/vm-candidate-gate.py" --restore --confirm-vm-candidate \
  >"$test_root/restore.out"
[[ $(sha256sum "$modules" | awk '{print $1}') == "$original_modules" ]] || fail 'restore did not recover modules'
[[ $(sha256sum "$stages" | awk '{print $1}') == "$original_stages" ]] || fail 'restore did not recover stages'
HOME="$home" XDG_STATE_HOME="$state" python "$fixture/installer/vm-candidate-gate.py" --status --json >"$test_root/restored.json"
python - "$test_root/restored.json" <<'PY'
import json,sys
p=json.load(open(sys.argv[1]));assert p['status']=='restored' and p['original_matches'] is True
PY

# Restore is idempotent only while exact original content and mode still match.
HOME="$home" XDG_STATE_HOME="$state" python "$fixture/installer/vm-candidate-gate.py" --restore --confirm-vm-candidate \
  >"$test_root/restore-idempotent.out"
[[ $(sha256sum "$modules" | awk '{print $1}') == "$original_modules" ]] || fail 'idempotent restore changed modules'
[[ $(sha256sum "$stages" | awk '{print $1}') == "$original_stages" ]] || fail 'idempotent restore changed stages'

# A terminal state is reported as drifted (and exits nonzero) when the bytes
# still match but a manifest mode no longer matches the reviewed cycle.
chmod 600 "$modules"
set +e
HOME="$home" XDG_STATE_HOME="$state" python "$fixture/installer/vm-candidate-gate.py" --status --json \
  >"$test_root/restored-mode-drift.json"
mode_drift_status=$?
set -e
((mode_drift_status == 1)) || fail "mode-drift status exited $mode_drift_status"
python - "$test_root/restored-mode-drift.json" <<'PY'
import json,sys
p=json.load(open(sys.argv[1]));assert p['status']=='drifted' and p['original_matches'] is True
PY
chmod "$modules_mode" "$modules"
HOME="$home" XDG_STATE_HOME="$state" python "$fixture/installer/vm-candidate-gate.py" --status --json \
  >"$test_root/restored-after-mode-recovery.json"
python - "$test_root/restored-after-mode-recovery.json" <<'PY'
import json,sys
p=json.load(open(sys.argv[1]));assert p['status']=='restored' and p['original_matches'] is True
PY

# Once the exact candidate bytes become canonical, planning must report no
# remaining transaction instead of claiming the same 9/5 rows will change.
cp -- "$candidate_modules_file" "$modules"
cp -- "$candidate_stages_file" "$stages"
chmod "$modules_mode" "$modules"
chmod "$stages_mode" "$stages"
HOME="$home" XDG_STATE_HOME="$state" python "$fixture/installer/vm-candidate-gate.py" --plan --json \
  >"$test_root/already-promoted-plan.json"
python - "$test_root/already-promoted-plan.json" <<'PY'
import json,sys
p=json.load(open(sys.argv[1]))
assert p['action']=='already-promoted'
assert p['stage_changes']==[] and p['module_changes']==[]
assert p['current_hashes']==p['candidate_hashes']
assert p['system_changes'] is False
PY
: >"$DETECT_LOG"
set +e
HOME="$home" XDG_STATE_HOME="$test_root/promoted-state" \
  python "$fixture/installer/vm-candidate-gate.py" --enable --confirm-vm-candidate \
  >"$test_root/already-promoted-enable.out" 2>&1
promoted_enable_status=$?
set -e
((promoted_enable_status == 1)) || fail "already-promoted enable exited $promoted_enable_status"
grep -Fq 'candidate gates are already canonical' "$test_root/already-promoted-enable.out" \
  || fail 'already-promoted enable was not rejected explicitly'
[[ ! -e $test_root/promoted-state && ! -s $DETECT_LOG ]] \
  || fail 'already-promoted enable wrote state or queried VM runtime'

printf '%s\n' 'VM candidate gate checks passed.'
