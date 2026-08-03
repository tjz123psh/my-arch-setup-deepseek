#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT
fixture="$test_root/project"
engine="$fixture/installer/full-orchestrator.py"
all_modules='core,arch,aur,config,checks'

fail() {
  printf 'full orchestrator test failed: %s\n' "$*" >&2
  exit 1
}

mkdir -p "$fixture/installer" "$fixture/manifests" "$fixture/config"
cp -- "$root/installer/full-orchestrator.py" "$engine"
cp -- "$root/manifests/stages.tsv" "$fixture/manifests/stages.tsv"
# This fixture intentionally exercises the fail-closed branch independently of
# the now-promoted canonical manifest.
python3 - "$fixture/manifests/stages.tsv" <<'PY_FIXTURE_GATES'
import csv
import sys
from pathlib import Path

path = Path(sys.argv[1])
lines = path.read_text().splitlines()
for index, row in enumerate(csv.reader(lines[1:], delimiter="\t"), 1):
    if not row or row[0].startswith("#"):
        continue
    assert len(row) == 8
    row[6] = "false"
    lines[index] = "\t".join(row)
path.write_text("\n".join(lines) + "\n")
PY_FIXTURE_GATES
chmod 755 "$engine"

cat >"$fixture/manifests/modules.tsv" <<'EOF'
# schema=1
# module<TAB>availability<TAB>kind<TAB>requires-all<TAB>requires-any<TAB>purpose
core	available	selectable	-	-	Official core fixture
arch	available	selectable	-	-	Archlinuxcn optional fixture
aur	available	selectable	-	-	AUR optional fixture
config	available	selectable	-	-	User config fixture
checks	available	selectable	-	-	System verification fixture
EOF

cat >"$fixture/manifests/production-module-readiness.tsv" <<'EOF'
# schema=1
# module<TAB>production-readiness<TAB>evidence
core	available	Fixture production-ready core effects
arch	available	Fixture production-ready archlinuxcn effects
aur	available	Fixture production-ready AUR effects
config	available	Fixture production-ready configuration effects
checks	available	Fixture production-ready verification effects
EOF

cat >"$fixture/manifests/profile-modules.tsv" <<'EOF'
# schema=1
# profile<TAB>config-scope<TAB>module<TAB>default-state
test	physical-v1	core	selected
test	physical-v1	arch	selected
test	physical-v1	aur	selected
test	physical-v1	config	selected
test	physical-v1	checks	selected
EOF

cat >"$fixture/manifests/workstation-packages.tsv" <<'EOF'
# schema=1
# package<TAB>channel<TAB>repository<TAB>acquisition<TAB>module<TAB>restore-mode<TAB>policy<TAB>origin<TAB>purpose
core-fixture	pacman	core	pacman	core	package-only	install	confirmed-desired	Official fixture effect
arch-keyring-fixture	pacman	archlinuxcn	archlinuxcn-bootstrap	arch	package-only	install	confirmed-desired	Archlinuxcn bootstrap fixture effect
arch-package-fixture	pacman	archlinuxcn	pacman	arch	package-only	install	confirmed-desired	Archlinuxcn package fixture effect
aur-package-fixture	aur	aur	aur-build	aur	package-only	install	confirmed-desired	AUR fixture effect
base-fixture	pacman	core	verify-only	checks	manual-precondition	verify	confirmed-desired	System verification fixture effect
EOF

cat >"$fixture/manifests/config-mappings.tsv" <<'EOF'
# schema=3
# scope<TAB>module<TAB>source<TAB>target<TAB>mode
physical-v1	config	config/test.conf	.config/full-orchestrator-test.conf	644
physical-v1	config	config/gsudo	scripts/desktop/gsudo	755
physical-v1	config	config/fuzzel-askpass	scripts/desktop/fuzzel-askpass	755
EOF
printf 'fixture=true\n' >"$fixture/config/test.conf"
printf '#!/usr/bin/env bash\nexit 0\n' >"$fixture/config/gsudo"
printf '#!/usr/bin/env bash\nexit 0\n' >"$fixture/config/fuzzel-askpass"
chmod 755 "$fixture/config/gsudo" "$fixture/config/fuzzel-askpass"

cat >"$fixture/manifests/system-action-conflicts.tsv" <<'EOF'
# schema=1
# conflict-set<TAB>packages<TAB>system-units<TAB>user-units<TAB>behavior<TAB>purpose
fixture-conflicts	fixture-conflict	-	-	block-active-or-installed	Fixture conflict policy
EOF
cat >"$fixture/manifests/system-actions.tsv" <<'EOF'
# schema=1
# action-id<TAB>module<TAB>profiles<TAB>disposition<TAB>privilege<TAB>handler<TAB>target<TAB>applicability<TAB>conflict-set<TAB>requires<TAB>rollback<TAB>post-check<TAB>purpose<TAB>evidence
fixture-system-check	checks	all	verify	none	verify-policy-packages	workstation:verify-only	always	fixture-conflicts	-	No change	Exact fixture package query	Fixture reviewed system action	tests/full-orchestrator-test.sh
fixture-manual-check	checks	all	manual	none	report-manual	fixture-manual	always	-	fixture-system-check	No automatic rollback	Record manual fixture acceptance	Fixture manual acceptance remains explicit	tests/full-orchestrator-test.sh
fixture-deferred-check	checks	all	deferred	root	report-deferred	fixture-deferred	always	-	fixture-system-check	No automatic change	No current post-check	Fixture deferred acceptance remains visible	tests/full-orchestrator-test.sh
EOF

adapter="$test_root/test-adapter.sh"
cat >"$adapter" <<'SH_ADAPTER'
#!/usr/bin/env bash
set -u
: "${FULL_ORCHESTRATOR_STAGE:?}"
: "${FULL_ORCHESTRATOR_ACTION:?}"
: "${MOCK_CALL_LOG:?}"
: "${MOCK_CONTROL_DIR:?}"
printf '%s\t%s\n' "$FULL_ORCHESTRATOR_STAGE" "$FULL_ORCHESTRATOR_ACTION" >>"$MOCK_CALL_LOG"
printf 'adapter stage=%s action=%s\n' "$FULL_ORCHESTRATOR_STAGE" "$FULL_ORCHESTRATOR_ACTION"
if [[ -f $MOCK_CONTROL_DIR/production-env-probe ]]; then
  forbidden=(
    ARCHLINUXCN_APPLY_TESTING ARCHLINUXCN_APPLY_TEST_ROOT
    ARCHLINUXCN_TEST_GSUDO_SHA256 ARCHLINUXCN_TEST_ASKPASS_SHA256
    SYSTEM_ACTION_APPLY_TESTING SYSTEM_ACTION_APPLY_TEST_ROOT
    SYSTEM_ACTION_TEST_COMMAND_DIR SYSTEM_ACTION_TEST_GSUDO_SHA256
    SYSTEM_ACTION_TEST_ASKPASS_SHA256 PYTHONPATH PYTHONHOME BASH_ENV ENV
  )
  for name in "${forbidden[@]}"; do
    [[ ! -v $name ]] || { printf 'forbidden inherited variable: %s\n' "$name" >&2; exit 88; }
  done
  [[ $PATH == /usr/bin ]] || { printf 'unsafe production PATH: %s\n' "$PATH" >&2; exit 89; }
fi
rule="$MOCK_CONTROL_DIR/${FULL_ORCHESTRATOR_STAGE}.${FULL_ORCHESTRATOR_ACTION}"
if [[ -f "$rule" ]]; then
  value=$(<"$rule")
  case "$value" in
    once:*)
      status=${value#once:}
      rm -f -- "$rule"
      ;;
    *) status=$value ;;
  esac
  [[ "$status" =~ ^[1-9][0-9]*$ ]] || exit 99
  exit "$status"
fi
exit 0
SH_ADAPTER
chmod 755 "$adapter"

execution_map="$test_root/execution-map.json"
python3 - "$execution_map" "$adapter" <<'PY'
import json
import sys
stages = [
    "privilege-wrapper",
    "official-update",
    "official-packages",
    "archlinuxcn-bootstrap",
    "archlinuxcn-packages",
    "aur-source-acquisition",
    "aur-build-install",
    "user-config",
    "system-actions",
]
path, adapter = sys.argv[1:]
with open(path, "w", encoding="utf-8") as stream:
    json.dump(
        {
            "schema": 1,
            "test_only": True,
            "stages": {
                stage: {"execute": [adapter], "verify": [adapter]}
                for stage in stages
            },
        },
        stream,
        sort_keys=True,
    )
    stream.write("\n")
PY

python3 -m py_compile "$engine"

state_base() {
  printf '%s/state/my-archlinux-setup/full-orchestrator' "$1"
}

latest_state() {
  local home=$1 base run_id
  base=$(state_base "$home")
  [[ -f "$base/latest.json" ]] || fail "latest pointer missing for $home"
  run_id=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["run_id"])' "$base/latest.json")
  [[ "$run_id" =~ ^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{12}$ ]] || fail "unsafe latest run id: $run_id"
  printf '%s/runs/%s/state.json' "$base" "$run_id"
}

latest_log() {
  local state
  state=$(latest_state "$1")
  printf '%s/run.log' "${state%/state.json}"
}

assert_stage() {
  local state=$1 stage=$2 expected=$3
  python3 - "$state" "$stage" "$expected" <<'PY' || fail "stage $stage was not $expected in $state"
import json
import sys
state, stage, expected = sys.argv[1:]
data = json.load(open(state))
statuses = {row["id"]: row["status"] for row in data["stages"]}
raise SystemExit(0 if statuses.get(stage) == expected else 1)
PY
}

assert_run_field() {
  local state=$1 field=$2 expected=$3
  python3 - "$state" "$field" "$expected" <<'PY' || fail "run field $field was not $expected in $state"
import json
import sys
state, field, expected = sys.argv[1:]
value = json.load(open(state))[field]
if isinstance(value, bool):
    value = "true" if value else "false"
else:
    value = str(value)
raise SystemExit(0 if value == expected else 1)
PY
}

call_count() {
  local log=$1 stage=$2 action=$3
  awk -F '\t' -v stage="$stage" -v action="$action" '$1 == stage && $2 == action { count++ } END { print count + 0 }' "$log"
}

new_case() {
  local name=$1
  CASE_HOME="$test_root/$name/home"
  CASE_CONTROL="$test_root/$name/control"
  CASE_CALLS="$test_root/$name/calls.tsv"
  mkdir -p "$CASE_HOME" "$CASE_CONTROL"
  : >"$CASE_CALLS"
}

run_engine() {
  local output=$1
  shift
  set +e
  HOME="$CASE_HOME" XDG_STATE_HOME="$CASE_HOME/state" \
    FULL_ORCHESTRATOR_TESTING=1 MOCK_CONTROL_DIR="$CASE_CONTROL" MOCK_CALL_LOG="$CASE_CALLS" \
    python3 "$engine" "$@" >"$output" 2>&1
  RUN_STATUS=$?
  set -e
}

apply_args=(
  --profile test --modules "$all_modules" --apply
  --test-execution-map "$execution_map"
  --confirm-system-changes --confirm-archlinuxcn --confirm-aur
)

# The production plan is exact, schema-2, dynamic, and explicitly disconnected.
new_case plan
run_engine "$test_root/plan.json" --profile test --modules "$all_modules" --plan --json
((RUN_STATUS == 0)) || { cat "$test_root/plan.json" >&2; fail "production plan exited $RUN_STATUS"; }
python3 - "$test_root/plan.json" <<'PY' || fail 'production plan safety/stage document was wrong'
import json
import sys
p = json.load(open(sys.argv[1]))
expected = [
    "privilege-wrapper", "official-update", "official-packages", "archlinuxcn-bootstrap",
    "archlinuxcn-packages", "aur-source-acquisition", "aur-build-install",
    "user-config", "system-actions",
]
assert p["schema"] == 2
assert p["mode"] == "new"
assert [s["id"] for s in p["stages"]] == expected
assert all(s["applicable"] for s in p["stages"])
assert all(s["production_apply_integration"] is False for s in p["stages"])
assert p["safety"] == {
    "adapter_fingerprint": None,
    "execution_adapter": "none",
    "production_apply_integration": False,
    "real_system_commands_embedded": False,
}
assert p["required_confirmations"] == ["system", "archlinuxcn", "aur"]
assert p["selection"]["requested_modules"] == ["core", "arch", "aur", "config", "checks"]
bootstrap = next(stage for stage in p["stages"] if stage["id"] == "archlinuxcn-bootstrap")
assert bootstrap["effects"] == [{
    "id": "bootstrap:arch-keyring-fixture",
    "module": "arch",
    "detail": (
        "package=arch-keyring-fixture channel=pacman repository=archlinuxcn "
        "acquisition=archlinuxcn-bootstrap repository-config=fixed-include-fragment "
        "refresh=conditional-full-system-and-repository"
    ),
}]
system = next(stage for stage in p["stages"] if stage["id"] == "system-actions")
assert [effect["id"] for effect in system["effects"]] == [
    "action:fixture-system-check",
    "action:fixture-manual-check",
    "action:fixture-deferred-check",
    "verify:base-fixture",
]
assert p["acceptance"] == {
    "pending_actions": ["fixture-manual-check", "fixture-deferred-check"],
    "manual_actions": ["fixture-manual-check"],
    "deferred_actions": ["fixture-deferred-check"],
    "conditional_actions": [],
    "relogin_or_reboot_reasons": [],
}
assert system["effects"][0]["detail"] == "disposition=verify privilege=none handler=verify-policy-packages target=workstation:verify-only applicability=always conflict=fixture-conflicts"
privilege = next(stage for stage in p["stages"] if stage["id"] == "privilege-wrapper")
user_config = next(stage for stage in p["stages"] if stage["id"] == "user-config")
privilege_ids = {effect["id"] for effect in privilege["effects"]}
user_ids = {effect["id"] for effect in user_config["effects"]}
assert privilege_ids == {
    "deploy:scripts/desktop/fuzzel-askpass",
    "deploy:scripts/desktop/gsudo",
}
assert privilege_ids.isdisjoint(user_ids)
assert user_ids == {"deploy:.config/full-orchestrator-test.conf"}
PY
[[ ! -e "$(state_base "$CASE_HOME")" ]] || fail 'read-only production plan created state'

run_engine "$test_root/reconcile-plan.json" --profile test --modules "$all_modules" --mode reconcile --plan --json
((RUN_STATUS == 0)) || { cat "$test_root/reconcile-plan.json" >&2; fail "reconcile plan exited $RUN_STATUS"; }
python3 - "$test_root/plan.json" "$test_root/reconcile-plan.json" <<'PY' || fail 'deployment mode was not fingerprint-bound'
import json,sys
new=json.load(open(sys.argv[1]));reconcile=json.load(open(sys.argv[2]))
assert reconcile["mode"] == "reconcile"
assert new["plan_fingerprint"] != reconcile["plan_fingerprint"]
PY

# Exact --modules replaces defaults rather than merging with them.
run_engine "$test_root/exact.json" --profile test --modules core --plan --json
((RUN_STATUS == 0)) || fail "exact module plan exited $RUN_STATUS"
python3 - "$test_root/exact.json" <<'PY' || fail 'exact non-interactive --modules was not honored'
import json
import sys
p = json.load(open(sys.argv[1]))
assert p["selection"]["requested_modules"] == ["core"]
assert p["selection"]["resolved_modules"] == ["core"]
statuses = {s["id"]: s["applicable"] for s in p["stages"]}
assert statuses["privilege-wrapper"] and statuses["official-update"] and statuses["official-packages"]
assert not statuses["archlinuxcn-bootstrap"]
assert not statuses["aur-source-acquisition"]
assert not statuses["user-config"]
assert not statuses["system-actions"]
PY

# Production apply has no hidden commands and fails before state creation.
run_engine "$test_root/no-adapter.out" --profile test --modules "$all_modules" --apply \
  --confirm-system-changes --confirm-archlinuxcn --confirm-aur
((RUN_STATUS != 0)) || fail 'production apply ran without an adapter'
grep -Fq 'production apply integration is false' "$test_root/no-adapter.out" || \
  fail 'production apply rejection did not explain the integration boundary'
[[ ! -e "$(state_base "$CASE_HOME")" ]] || fail 'rejected production apply created state'

# A canonical reviewed adapter cannot override a false production-integration
# stage gate. Rejection happens before every preflight and before run state.
reviewed_manifest="$fixture/manifests/stage-executables.tsv"
python3 - "$reviewed_manifest" "$adapter" <<'PY'
import hashlib,sys
from pathlib import Path
manifest, adapter = map(Path, sys.argv[1:])
digest=hashlib.sha256(adapter.read_bytes()).hexdigest()
stages=(
 'privilege-wrapper','official-update','official-packages','archlinuxcn-bootstrap',
 'archlinuxcn-packages','aur-source-acquisition','aur-build-install','user-config','system-actions',
)
lines=['# schema=1','# reviewed=true','# stage<TAB>execute-path<TAB>execute-sha256<TAB>verify-path<TAB>verify-sha256']
lines.extend('\t'.join((stage,str(adapter),digest,str(adapter),digest)) for stage in stages)
manifest.write_text('\n'.join(lines)+'\n')
modules=manifest.parent/'modules.tsv'
modules_digest=hashlib.sha256(modules.read_bytes()).hexdigest()
(manifest.parent/'stage-inputs.tsv').write_text(
 '# schema=1\n'
 '# input-id<TAB>stages<TAB>kind<TAB>project-relative-path<TAB>sha256\n'
 + 'fixture-policy\t' + ','.join(stages) + '\tfile\tmanifests/modules.tsv\t' + modules_digest + '\n'
)
PY
new_case false-production-gate
run_engine "$test_root/false-production-gate.out" --profile test --modules "$all_modules" --apply \
  --executable-manifest "$reviewed_manifest" \
  --confirm-system-changes --confirm-archlinuxcn --confirm-aur
((RUN_STATUS == 1)) || { cat "$test_root/false-production-gate.out" >&2; fail "false production gate exited $RUN_STATUS"; }
grep -Fq 'applicable stages are not production-integrated' "$test_root/false-production-gate.out" || \
  fail 'false production gate rejection was not explicit'
[[ ! -e "$(state_base "$CASE_HOME")" ]] || fail 'false production gate created run state'
[[ ! -s $CASE_CALLS ]] || fail 'false production gate invoked a reviewed adapter'

# Canonical reviewed execution strips adapter test switches and supplies a
# fixed system-command PATH. Test-only execution maps retain their fixture env.
cp -- "$fixture/manifests/stages.tsv" "$test_root/stages-false.tsv"
python3 - "$fixture/manifests/stages.tsv" <<'PY'
import sys
from pathlib import Path
p=Path(sys.argv[1]);p.write_text(p.read_text().replace('	false	','	true	'))
PY
new_case production-env-sanitize
touch "$CASE_CONTROL/production-env-probe"
set +e
ARCHLINUXCN_APPLY_TESTING=1 ARCHLINUXCN_APPLY_TEST_ROOT="$test_root/forbidden-arch-root" \
ARCHLINUXCN_TEST_GSUDO_SHA256=forbidden ARCHLINUXCN_TEST_ASKPASS_SHA256=forbidden \
SYSTEM_ACTION_APPLY_TESTING=1 SYSTEM_ACTION_APPLY_TEST_ROOT="$test_root/forbidden-system-root" \
SYSTEM_ACTION_TEST_COMMAND_DIR="$test_root/forbidden-commands" \
SYSTEM_ACTION_TEST_GSUDO_SHA256=forbidden SYSTEM_ACTION_TEST_ASKPASS_SHA256=forbidden \
PYTHONPATH="$test_root/forbidden-python" BASH_ENV="$test_root/forbidden-bash-env" \
PATH="$test_root/forbidden-path:$PATH" \
run_engine "$test_root/production-env-sanitize.out" --profile test --modules "$all_modules" --apply \
  --executable-manifest "$reviewed_manifest" \
  --confirm-system-changes --confirm-archlinuxcn --confirm-aur
production_env_status=$RUN_STATUS
set -e
((production_env_status == 0)) || { cat "$test_root/production-env-sanitize.out" >&2; fail "sanitized production adapter run exited $production_env_status"; }
[[ ! -e $test_root/forbidden-arch-root && ! -e $test_root/forbidden-system-root ]] \
  || fail 'reviewed adapter inherited a test target root'
cp -- "$test_root/stages-false.tsv" "$fixture/manifests/stages.tsv"
rm -f -- "$reviewed_manifest" "$fixture/manifests/stage-inputs.tsv"

# Interactive selection cancellation exits 130 and writes no selection/run state.
new_case selection-cancel
set +e
printf 'cancel\n' | HOME="$CASE_HOME" XDG_STATE_HOME="$CASE_HOME/state" \
  FULL_ORCHESTRATOR_TESTING=1 MOCK_CONTROL_DIR="$CASE_CONTROL" MOCK_CALL_LOG="$CASE_CALLS" \
  python3 "$engine" --profile test --interactive --apply --test-execution-map "$execution_map" \
  >"$test_root/selection-cancel.out" 2>&1
selection_cancel_status=$?
set -e
((selection_cancel_status == 130)) || fail "selection cancellation returned $selection_cancel_status instead of 130"
grep -Fq 'module selection cancelled' "$test_root/selection-cancel.out" || fail 'selection cancellation was not reported'
[[ ! -e "$(state_base "$CASE_HOME")" ]] || fail 'selection cancellation created state'
[[ ! -s "$CASE_CALLS" ]] || fail 'selection cancellation invoked an adapter'

# All three trust confirmations are independent and collected before run state.
new_case confirmation-cancel
set +e
printf 'profile\nconfirm-system-changes\ncancel\n' | \
  HOME="$CASE_HOME" XDG_STATE_HOME="$CASE_HOME/state" \
  FULL_ORCHESTRATOR_TESTING=1 MOCK_CONTROL_DIR="$CASE_CONTROL" MOCK_CALL_LOG="$CASE_CALLS" \
  python3 "$engine" --profile test --interactive --apply --test-execution-map "$execution_map" \
  >"$test_root/confirmation-cancel.out" 2>&1
confirmation_cancel_status=$?
set -e
((confirmation_cancel_status == 130)) || \
  fail "independent confirmation cancellation returned $confirmation_cancel_status"
grep -Fq 'archlinuxcn stage authorization cancelled' "$test_root/confirmation-cancel.out" || \
  fail 'archlinuxcn cancellation was not reported independently'
[[ $(grep -c '^Plan fingerprint:' "$test_root/confirmation-cancel.out") == 1 ]] || \
  fail 'apply did not render exactly one stage/effect plan'
[[ ! -e "$(state_base "$CASE_HOME")" ]] || fail 'confirmation cancellation created run state'
(( $(awk -F '\t' '$2 == "preflight" { count++ } END { print count+0 }' "$CASE_CALLS") == 9 )) || \
  fail 'confirmation cancellation did not complete every read-only preflight first'
(( $(awk -F '\t' '$2 == "execute" || $2 == "verify" { count++ } END { print count+0 }' "$CASE_CALLS") == 0 )) || \
  fail 'confirmation cancellation invoked a changing/verifying adapter action'

# A failed preflight in any trust branch blocks every execute before confirmation
# or run-state creation while preserving the exact external status.
new_case preflight-failure
printf '53\n' >"$CASE_CONTROL/system-actions.preflight"
run_engine "$test_root/preflight-failure.out" "${apply_args[@]}"
((RUN_STATUS == 53)) || { cat "$test_root/preflight-failure.out" >&2; fail "preflight failure exit was $RUN_STATUS"; }
[[ ! -e "$(state_base "$CASE_HOME")" ]] || fail 'failed preflight created run state'
(( $(awk -F '\t' '$2 == "preflight" { count++ } END { print count+0 }' "$CASE_CALLS") == 9 )) || \
  fail 'read-only preflight did not inventory every applicable stage'
(( $(awk -F '\t' '$2 == "execute" || $2 == "verify" { count++ } END { print count+0 }' "$CASE_CALLS") == 0 )) || \
  fail 'failed preflight reached an execute/verify action'
grep -Fq 'stage system-actions: preflight failed exit=53' "$test_root/preflight-failure.out" || \
  fail 'preflight failure classification was not reported'

# Saved selections contain only credential-free reviewed fields and require explicit reuse.
new_case saved
run_engine "$test_root/saved-create.json" --profile test --modules core,aur --plan --json --save-selection
((RUN_STATUS == 0)) || { cat "$test_root/saved-create.json" >&2; fail "saving selection exited $RUN_STATUS"; }
saved_path="$(state_base "$CASE_HOME")/selections/test.json"
[[ -f "$saved_path" ]] || fail 'saved selection file was not created'
[[ $(stat -c '%a' "$saved_path") == 600 ]] || fail 'saved selection is not mode 600'
python3 - "$saved_path" <<'PY' || fail 'saved selection contained unexpected/credential fields'
import json
import sys
p = json.load(open(sys.argv[1]))
assert set(p) == {"schema", "profile", "requested_modules", "selection_manifest_fingerprint"}
assert p["schema"] == 1 and p["profile"] == "test"
assert p["requested_modules"] == ["core", "aur"]
serialized = json.dumps(p).lower()
for forbidden in ("password", "credential", "token", "cookie", "secret"):
    assert forbidden not in serialized
PY

run_engine "$test_root/saved-not-inferred.out" --profile test --apply --test-execution-map "$execution_map" \
  --confirm-system-changes --confirm-archlinuxcn --confirm-aur
((RUN_STATUS != 0)) || fail 'non-interactive apply silently reused a saved/default selection'
grep -Fq 'saved/default selections are never inferred' "$test_root/saved-not-inferred.out" || \
  fail 'non-interactive exact-selection rejection was not explained'
[[ ! -e "$(state_base "$CASE_HOME")/latest.json" ]] || fail 'rejected saved selection inference created a run'

run_engine "$test_root/saved-reuse.json" --profile test --use-saved-selection --plan --json
((RUN_STATUS == 0)) || fail "explicit saved selection reuse exited $RUN_STATUS"
python3 - "$test_root/saved-reuse.json" <<'PY' || fail 'explicit saved selection reuse selected the wrong modules'
import json
import sys
p = json.load(open(sys.argv[1]))
assert p["selection"]["source"] == "explicit-saved-selection"
assert p["selection"]["requested_modules"] == ["core", "aur"]
PY
saved_hash=$(sha256sum "$saved_path" | awk '{print $1}')
run_engine "$test_root/saved-refuse.out" --profile test --modules core,arch --plan --save-selection
((RUN_STATUS != 0)) || fail 'different saved selection was overwritten without replace'
[[ $(sha256sum "$saved_path" | awk '{print $1}') == "$saved_hash" ]] || \
  fail 'refused saved selection replacement changed the saved file'

set +e
printf 'edit\ncore,arch\nkeep\n' | HOME="$CASE_HOME" XDG_STATE_HOME="$CASE_HOME/state" \
  FULL_ORCHESTRATOR_TESTING=1 MOCK_CONTROL_DIR="$CASE_CONTROL" MOCK_CALL_LOG="$CASE_CALLS" \
  python3 "$engine" --profile test --interactive --plan >"$test_root/saved-edit-keep.out" 2>&1
saved_keep_status=$?
set -e
((saved_keep_status == 0)) || fail "interactive saved edit/keep exited $saved_keep_status"
grep -Fq 'Requested modules: core,arch' "$test_root/saved-edit-keep.out" || \
  fail 'interactive edit did not affect the current plan'
[[ $(sha256sum "$saved_path" | awk '{print $1}') == "$saved_hash" ]] || \
  fail 'interactive keep unexpectedly replaced saved selection'

set +e
printf 'edit\ncore,arch\nreplace\n' | HOME="$CASE_HOME" XDG_STATE_HOME="$CASE_HOME/state" \
  FULL_ORCHESTRATOR_TESTING=1 MOCK_CONTROL_DIR="$CASE_CONTROL" MOCK_CALL_LOG="$CASE_CALLS" \
  python3 "$engine" --profile test --interactive --plan >"$test_root/saved-edit-replace.out" 2>&1
saved_replace_status=$?
set -e
((saved_replace_status == 0)) || fail "interactive saved replace exited $saved_replace_status"
python3 - "$saved_path" <<'PY' || fail 'interactive replace did not update saved selection exactly'
import json
import sys
assert json.load(open(sys.argv[1]))["requested_modules"] == ["core", "arch"]
PY

# A core-stage failure skips dependency descendants and preserves exact exit 31.
new_case core-failure
printf '31\n' >"$CASE_CONTROL/official-update.execute"
run_engine "$test_root/core-failure.out" "${apply_args[@]}"
((RUN_STATUS == 31)) || { cat "$test_root/core-failure.out" >&2; fail "core failure exit was $RUN_STATUS, expected 31"; }
core_state=$(latest_state "$CASE_HOME")
assert_run_field "$core_state" status failed
assert_run_field "$core_state" failure_exit 31
assert_stage "$core_state" privilege-wrapper passed
assert_stage "$core_state" official-update failed
for stage in official-packages archlinuxcn-bootstrap archlinuxcn-packages aur-source-acquisition \
  aur-build-install user-config system-actions; do
  assert_stage "$core_state" "$stage" skipped-dependency
done
[[ $(stat -c '%a' "$core_state") == 600 ]] || fail 'run state is not private mode 600'
core_log=$(latest_log "$CASE_HOME")
[[ $(stat -c '%a' "$core_log") == 600 ]] || fail 'run log is not private mode 600'
[[ $(stat -c '%a' "$(dirname -- "$core_state")") == 700 ]] || fail 'run directory is not private mode 700'
python3 - "$core_log" "$core_state" <<'PY' || fail 'run log was not bound to the state fingerprint'
import json
import sys
first = json.loads(open(sys.argv[1]).readline())
state = json.load(open(sys.argv[2]))
assert first["plan_fingerprint"] == state["plan_fingerprint"]
PY

# An optional archlinuxcn failure does not abort independent AUR/core branches;
# the final process/state still preserve the optional failure's exact exit 47.
new_case optional-failure
printf '47\n' >"$CASE_CONTROL/archlinuxcn-bootstrap.execute"
run_engine "$test_root/optional-failure.out" "${apply_args[@]}"
((RUN_STATUS == 47)) || { cat "$test_root/optional-failure.out" >&2; fail "optional failure exit was $RUN_STATUS"; }
optional_state=$(latest_state "$CASE_HOME")
assert_run_field "$optional_state" status failed
assert_run_field "$optional_state" failure_exit 47
assert_stage "$optional_state" archlinuxcn-bootstrap failed
assert_stage "$optional_state" archlinuxcn-packages skipped-dependency
for stage in aur-source-acquisition aur-build-install user-config system-actions; do
  assert_stage "$optional_state" "$stage" passed
done
(( $(call_count "$CASE_CALLS" aur-build-install execute) == 1 )) || \
  fail 'independent AUR build stage did not continue after archlinuxcn failure'
(( $(call_count "$CASE_CALLS" system-actions execute) == 1 )) || \
  fail 'independent core system-actions stage did not continue after optional failure'

# Honest module retry resolves only a failed stage carrying that module, resets
# its dependency-skipped descendant, and keeps the same audited run.
optional_run_id=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["run_id"])' "$optional_state")
rm -f -- "$CASE_CONTROL/archlinuxcn-bootstrap.execute"
run_engine "$test_root/optional-retry.out" --profile test --modules "$all_modules" --apply \
  --test-execution-map "$execution_map" --retry-module arch \
  --confirm-system-changes --confirm-archlinuxcn --confirm-aur
((RUN_STATUS == 0)) || { cat "$test_root/optional-retry.out" >&2; fail "module retry exited $RUN_STATUS"; }
optional_retry_state=$(latest_state "$CASE_HOME")
assert_run_field "$optional_retry_state" status completed
assert_run_field "$optional_retry_state" attempt 2
assert_stage "$optional_retry_state" archlinuxcn-bootstrap passed
assert_stage "$optional_retry_state" archlinuxcn-packages passed
python3 - "$optional_retry_state" <<'PY' || fail 'completed state lost pending/manual/deferred acceptance'
import json,sys
p=json.load(open(sys.argv[1]));a=p['acceptance']
assert a['pending_actions']==['fixture-manual-check','fixture-deferred-check']
assert a['manual_actions']==['fixture-manual-check']
assert a['deferred_actions']==['fixture-deferred-check']
PY
grep -Fq 'result: automatic-stages-completed-with-pending-acceptance' "$test_root/optional-retry.out" || \
  fail 'completed run reported unqualified completion despite pending acceptance'
grep -Fq 'manual-actions: fixture-manual-check' "$test_root/optional-retry.out" || \
  fail 'final report omitted manual acceptance ids'
grep -Fq 'deferred-actions: fixture-deferred-check' "$test_root/optional-retry.out" || \
  fail 'final report omitted deferred acceptance ids'
[[ $(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["run_id"])' "$optional_retry_state") == "$optional_run_id" ]] || \
  fail 'retry created a new run instead of resuming exact state'
grep -Fq 'stage official-update: verified; skipped' "$test_root/optional-retry.out" || \
  fail 'module retry did not verify before skipping a prior pass'

# A failed verifier on a prior pass forces that stage to rerun; stage retry is
# distinct from module retry and external verifier status is recorded honestly.
new_case verifier-rerun
printf '47\n' >"$CASE_CONTROL/archlinuxcn-bootstrap.execute"
run_engine "$test_root/verifier-first.out" "${apply_args[@]}"
((RUN_STATUS == 47)) || fail "verifier fixture first run exited $RUN_STATUS"
rm -f -- "$CASE_CONTROL/archlinuxcn-bootstrap.execute"
printf 'once:43\n' >"$CASE_CONTROL/official-update.verify"
run_engine "$test_root/verifier-retry.out" --profile test --modules "$all_modules" --apply \
  --test-execution-map "$execution_map" --retry-stage archlinuxcn-bootstrap \
  --confirm-system-changes --confirm-archlinuxcn --confirm-aur
((RUN_STATUS == 0)) || { cat "$test_root/verifier-retry.out" >&2; fail "verifier retry exited $RUN_STATUS"; }
grep -Fq 'stage official-update: verifier failed with exit 43; rerunning' "$test_root/verifier-retry.out" || \
  fail 'failed verifier did not force a rerun'
(( $(call_count "$CASE_CALLS" official-update execute) == 2 )) || \
  fail 'verifier failure did not execute the previously passed stage again'
verifier_state=$(latest_state "$CASE_HOME")
assert_run_field "$verifier_state" status completed
python3 - "$verifier_state" <<'PY' || fail 'verifier rerun attempt count was not retained'
import json
import sys
rows = {row["id"]: row for row in json.load(open(sys.argv[1]))["stages"]}
assert rows["official-update"]["attempts"] == 2
PY

# Interruption while a stage is running leaves dynamic running/pending rows and
# --resume restarts that stage after verifying every prior pass.
new_case interrupted-stage
run_engine "$test_root/interrupted-stage.out" "${apply_args[@]}" --test-interrupt-stage aur-build-install
((RUN_STATUS == 75)) || { cat "$test_root/interrupted-stage.out" >&2; fail "stage interruption exited $RUN_STATUS"; }
interrupted_state=$(latest_state "$CASE_HOME")
assert_run_field "$interrupted_state" status running
assert_stage "$interrupted_state" aur-build-install running
assert_stage "$interrupted_state" user-config pending
run_engine "$test_root/interrupted-resume.out" --profile test --modules "$all_modules" --apply \
  --test-execution-map "$execution_map" --resume \
  --confirm-system-changes --confirm-archlinuxcn --confirm-aur
((RUN_STATUS == 0)) || { cat "$test_root/interrupted-resume.out" >&2; fail "interrupted stage resume exited $RUN_STATUS"; }
interrupted_resumed_state=$(latest_state "$CASE_HOME")
assert_run_field "$interrupted_resumed_state" status completed
assert_run_field "$interrupted_resumed_state" attempt 2
assert_stage "$interrupted_resumed_state" aur-build-install passed
(( $(call_count "$CASE_CALLS" aur-build-install execute) == 1 )) || \
  fail 'running-stage recovery did not execute the interrupted stage exactly once'

# A public, graceful stop boundary validates production resume without killing a
# package manager mid-transaction. The selected stage is fully executed/verified
# and marked passed before exit 75; resume verifies it before continuing.
new_case failed-stop-boundary
printf '47\n' >"$CASE_CONTROL/archlinuxcn-packages.execute"
run_engine "$test_root/failed-stop-boundary.out" "${apply_args[@]}" \
  --stop-after-stage archlinuxcn-packages
((RUN_STATUS == 47)) || { cat "$test_root/failed-stop-boundary.out" >&2; fail "failed stop boundary exited $RUN_STATUS"; }
failed_stop_state=$(latest_state "$CASE_HOME")
assert_run_field "$failed_stop_state" status failed
assert_stage "$failed_stop_state" archlinuxcn-packages failed
assert_stage "$failed_stop_state" aur-source-acquisition pending
(( $(call_count "$CASE_CALLS" aur-source-acquisition execute) == 0 )) || \
  fail 'failed stop boundary executed a later independent AUR stage'
grep -Fq 'failed stop boundary archlinuxcn-packages' "$test_root/failed-stop-boundary.out" || \
  fail 'failed stop boundary was not reported'

new_case graceful-stop
run_engine "$test_root/graceful-stop.out" "${apply_args[@]}" --stop-after-stage aur-source-acquisition
((RUN_STATUS == 75)) || { cat "$test_root/graceful-stop.out" >&2; fail "graceful stop exited $RUN_STATUS"; }
graceful_state=$(latest_state "$CASE_HOME")
assert_run_field "$graceful_state" status running
assert_stage "$graceful_state" aur-source-acquisition passed
assert_stage "$graceful_state" aur-build-install pending
grep -Fq 'graceful stop after passed stage aur-source-acquisition' "$test_root/graceful-stop.out" || \
  fail 'graceful stop boundary was not reported'
run_engine "$test_root/graceful-stop-resume.out" --profile test --modules "$all_modules" --apply \
  --test-execution-map "$execution_map" --resume \
  --confirm-system-changes --confirm-archlinuxcn --confirm-aur
((RUN_STATUS == 0)) || { cat "$test_root/graceful-stop-resume.out" >&2; fail "graceful stop resume exited $RUN_STATUS"; }
(( $(call_count "$CASE_CALLS" aur-source-acquisition execute) == 1 )) || \
  fail 'graceful stop resume re-executed a verified passed stage'

# An interruption after all stages pass but before finalization is recoverable:
# resume verifies every pass, executes none again, and atomically finalizes.
new_case finalize-recovery
run_engine "$test_root/finalize-interrupt.out" "${apply_args[@]}" --test-interrupt-before-finalize
((RUN_STATUS == 75)) || { cat "$test_root/finalize-interrupt.out" >&2; fail "finalization interruption exited $RUN_STATUS"; }
finalize_state=$(latest_state "$CASE_HOME")
assert_run_field "$finalize_state" status running
python3 - "$finalize_state" <<'PY' || fail 'pre-finalize interruption did not retain all passed rows'
import json
import sys
state = json.load(open(sys.argv[1]))
assert all(row["status"] == "passed" for row in state["stages"])
PY
execute_lines_before=$(awk -F '\t' '$2 == "execute" {count++} END {print count+0}' "$CASE_CALLS")
run_engine "$test_root/finalize-resume.out" --profile test --modules "$all_modules" --apply \
  --test-execution-map "$execution_map" --resume \
  --confirm-system-changes --confirm-archlinuxcn --confirm-aur
((RUN_STATUS == 0)) || { cat "$test_root/finalize-resume.out" >&2; fail "finalization recovery exited $RUN_STATUS"; }
execute_lines_after=$(awk -F '\t' '$2 == "execute" {count++} END {print count+0}' "$CASE_CALLS")
((execute_lines_after == execute_lines_before)) || fail 'finalization recovery reran a verified stage'
finalized_state=$(latest_state "$CASE_HOME")
assert_run_field "$finalized_state" status completed
assert_run_field "$finalized_state" attempt 2

# A completed exact plan never reruns silently; --rerun creates a distinct run.
calls_before_duplicate=$(wc -l <"$CASE_CALLS")
run_engine "$test_root/duplicate.out" "${apply_args[@]}"
((RUN_STATUS != 0)) || fail 'completed exact plan reran without --rerun'
grep -Fq 'use --rerun for an intentional rerun' "$test_root/duplicate.out" || fail 'duplicate run omitted rerun guidance'
[[ $(wc -l <"$CASE_CALLS") == "$calls_before_duplicate" ]] || fail 'rejected duplicate invoked adapters'
run_engine "$test_root/rerun.out" "${apply_args[@]}" --rerun
((RUN_STATUS == 0)) || { cat "$test_root/rerun.out" >&2; fail "intentional rerun exited $RUN_STATUS"; }
run_count=$(find "$(state_base "$CASE_HOME")/runs" -mindepth 1 -maxdepth 1 -type d | wc -l)
((run_count == 2)) || fail "--rerun created $run_count run directories instead of 2"

# Changed plan input/fingerprint rejects retry before any adapter invocation.
new_case changed-fingerprint
printf '47\n' >"$CASE_CONTROL/archlinuxcn-bootstrap.execute"
run_engine "$test_root/fingerprint-first.out" "${apply_args[@]}"
((RUN_STATUS == 47)) || fail "fingerprint fixture first run exited $RUN_STATUS"
calls_before_fingerprint=$(wc -l <"$CASE_CALLS")
cp -- "$fixture/manifests/workstation-packages.tsv" "$test_root/workstation-packages.backup"
printf '# concurrent reviewed policy change\n' >>"$fixture/manifests/workstation-packages.tsv"
run_engine "$test_root/fingerprint-retry.out" --profile test --modules "$all_modules" --apply \
  --test-execution-map "$execution_map" --retry-stage archlinuxcn-bootstrap \
  --confirm-system-changes --confirm-archlinuxcn --confirm-aur
((RUN_STATUS != 0)) || fail 'changed plan fingerprint was accepted for retry'
grep -Fq 'plan fingerprint does not match the exact current plan' "$test_root/fingerprint-retry.out" || \
  fail 'changed fingerprint rejection was not explained'
[[ $(wc -l <"$CASE_CALLS") == "$calls_before_fingerprint" ]] || \
  fail 'changed-fingerprint retry invoked an adapter'
cp -- "$test_root/workstation-packages.backup" "$fixture/manifests/workstation-packages.tsv"

# Malformed state is an unavailable/failed check, never an empty/no-prior run.
new_case malformed-state
printf '47\n' >"$CASE_CONTROL/archlinuxcn-bootstrap.execute"
run_engine "$test_root/malformed-first.out" "${apply_args[@]}"
((RUN_STATUS == 47)) || fail "malformed-state fixture first run exited $RUN_STATUS"
malformed_state=$(latest_state "$CASE_HOME")
calls_before_malformed=$(wc -l <"$CASE_CALLS")
printf '{malformed\n' >"$malformed_state"
chmod 600 "$malformed_state"
run_engine "$test_root/malformed-retry.out" --profile test --modules "$all_modules" --apply \
  --test-execution-map "$execution_map" --retry-stage archlinuxcn-bootstrap \
  --confirm-system-changes --confirm-archlinuxcn --confirm-aur
((RUN_STATUS != 0)) || fail 'malformed state was treated as an empty/no-prior run'
grep -Fq 'run state is malformed JSON' "$test_root/malformed-retry.out" || \
  fail 'malformed state failure was not reported honestly'
[[ $(wc -l <"$CASE_CALLS") == "$calls_before_malformed" ]] || fail 'malformed-state retry invoked an adapter'

printf 'Full orchestrator checks passed.\n'
