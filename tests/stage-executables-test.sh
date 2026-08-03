#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
manifest="$root/manifests/stage-executables.tsv"
engine="$root/installer/full-orchestrator.py"
test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT

fail() { printf 'stage executable manifest test failed: %s\n' "$*" >&2; exit 1; }

python - "$root" "$manifest" <<'PY'
import hashlib
import sys
from pathlib import Path
root, manifest = map(Path, sys.argv[1:])
lines = manifest.read_text().splitlines()
assert lines[:3] == [
    '# schema=1',
    '# reviewed=true',
    '# stage<TAB>execute-path<TAB>execute-sha256<TAB>verify-path<TAB>verify-sha256',
]
expected = {
    'privilege-wrapper': 'installer/config-stage-apply.py',
    'official-update': 'installer/official-package-apply.py',
    'official-packages': 'installer/official-package-apply.py',
    'archlinuxcn-bootstrap': 'installer/archlinuxcn-apply.py',
    'archlinuxcn-packages': 'installer/archlinuxcn-apply.py',
    'aur-source-acquisition': 'installer/aur-stage-apply.py',
    'aur-build-install': 'installer/aur-stage-apply.py',
    'user-config': 'installer/config-stage-apply.py',
    'system-actions': 'installer/system-action-apply.py',
}
rows = {}
for number, line in enumerate(lines[3:], 4):
    parts = line.split('\t')
    assert len(parts) == 5, (number, parts)
    stage, execute, execute_hash, verify, verify_hash = parts
    assert stage not in rows
    assert execute == verify == expected[stage]
    path = root / execute
    assert path.is_file() and not path.is_symlink()
    assert path.stat().st_mode & 0o111
    actual = hashlib.sha256(path.read_bytes()).hexdigest()
    assert execute_hash == verify_hash == actual
    rows[stage] = execute
assert rows == expected
PY

home="$test_root/home"
mkdir -p "$home"
set +e
HOME="$home" XDG_STATE_HOME="$test_root/state" \
  python "$engine" --profile vm --plan --json \
  >"$test_root/plan.json" 2>"$test_root/plan.err"
status=$?
set -e
((status == 0)) || { cat "$test_root/plan.err" >&2; fail "reviewed manifest plan exited $status"; }
[[ ! -e $test_root/state ]] || fail 'reviewed manifest plan wrote private run state'
python - "$test_root/plan.json" <<'PY'
import json,sys
p=json.load(open(sys.argv[1]))
expected = [
    'privilege-wrapper','official-update','official-packages',
    'archlinuxcn-bootstrap','archlinuxcn-packages',
    'aur-source-acquisition','aur-build-install','user-config','system-actions',
]
assert [s['id'] for s in p['stages']] == expected
assert [s['id'] for s in p['stages'] if s['applicable']] == expected
assert p['safety']['execution_adapter'] == 'canonical-reviewed-executable-manifest'
assert p['safety']['adapter_fingerprint']
assert p['apply_blockers']['missing_adapter_stages'] == []
# The canonical VM plan is production-ready only after the reviewed
# Niri/Hyprland/both disposable-candidate matrix promoted the exact gates.
assert p['safety']['production_apply_integration'] is True
assert p['apply_blockers']['non_integrated_stages'] == []
assert p['apply_blockers']['non_executable_modules'] == []
assert all(stage['production_apply_integration'] is True for stage in p['stages'])
PY

# A byte-identical manifest at an arbitrary caller path remains external. It
# may be reviewed in plan mode but cannot claim canonical production integration
# or reach preflight/apply.
cp -- "$manifest" "$test_root/external.tsv"
HOME="$home" XDG_STATE_HOME="$test_root/external-plan-state" \
  python "$engine" --profile vm --plan --json --executable-manifest "$test_root/external.tsv" \
  >"$test_root/external-plan.json"
python - "$test_root/external-plan.json" <<'PY'
import json,sys
p=json.load(open(sys.argv[1]))
assert p['safety']['execution_adapter']=='external-reviewed-executable-manifest'
assert p['safety']['production_apply_integration'] is False
assert p['apply_blockers']['noncanonical_adapter'] is True
PY
[[ ! -e $test_root/external-plan-state ]] || fail 'external reviewed plan wrote state'
set +e
HOME="$home" XDG_STATE_HOME="$test_root/external-apply-state" \
  python "$engine" --profile vm \
  --modules desktop-shared,wm-niri,base-preconditions,build-foundation,fonts,input-fcitx-rime,audio \
  --apply --executable-manifest "$test_root/external.tsv" \
  --confirm-system-changes --confirm-archlinuxcn --confirm-aur \
  >"$test_root/external-apply.out" 2>&1
external_apply_status=$?
set -e
((external_apply_status == 1)) || { cat "$test_root/external-apply.out" >&2; fail "external manifest apply exited $external_apply_status"; }
grep -Fq 'rejects a noncanonical reviewed executable manifest' "$test_root/external-apply.out" \
  || fail 'external manifest apply was not rejected explicitly'
[[ ! -e $test_root/external-apply-state ]] || fail 'external manifest rejection wrote state'

# A changed pin is a failed trust check, not an empty/missing stage result.
python - "$manifest" "$test_root/tampered.tsv" <<'PY'
import sys
from pathlib import Path
source, target = map(Path, sys.argv[1:])
lines=source.read_text().splitlines()
parts=lines[3].split('\t');parts[2]='0'*64;lines[3]='\t'.join(parts)
target.write_text('\n'.join(lines)+'\n')
PY
set +e
HOME="$home" XDG_STATE_HOME="$test_root/tampered-state" \
  python "$engine" --profile vm --plan --json --executable-manifest "$test_root/tampered.tsv" \
  >"$test_root/tampered.out" 2>&1
tampered_status=$?
set -e
((tampered_status == 1)) || { cat "$test_root/tampered.out" >&2; fail "tampered manifest exited $tampered_status"; }
grep -Fq 'adapter executable hash mismatch' "$test_root/tampered.out" \
  || fail 'tampered manifest failure was not explicit'
[[ ! -e $test_root/tampered-state ]] || fail 'tampered manifest wrote run state'

printf '%s\n' 'Stage executable manifest checks passed.'
