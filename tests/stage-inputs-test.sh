#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
manifest="$root/manifests/stage-inputs.tsv"
test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT

fail() { printf 'stage input manifest test failed: %s\n' "$*" >&2; exit 1; }

python - "$root" "$manifest" <<'PY'
import csv,hashlib,re,stat,sys
from pathlib import Path
root, manifest=map(Path,sys.argv[1:])
lines=manifest.read_text().splitlines();assert lines[:2]==[
 '# schema=1','# input-id<TAB>stages<TAB>kind<TAB>project-relative-path<TAB>sha256']
known={
 'privilege-wrapper','official-update','official-packages','archlinuxcn-bootstrap',
 'archlinuxcn-packages','aur-source-acquisition','aur-build-install','user-config','system-actions'}
def tree_hash(path):
 entries=sorted(path.iterdir(),key=lambda item:bytes(item.name,'utf-8'))
 assert entries
 h=hashlib.sha256()
 for entry in entries:
  info=entry.lstat();assert stat.S_ISREG(info.st_mode) and not entry.is_symlink() and info.st_nlink==1
  data=entry.read_bytes();h.update(entry.name.encode());h.update(b'\0')
  h.update(f'{stat.S_IMODE(info.st_mode):04o}'.encode());h.update(b'\0')
  h.update(hashlib.sha256(data).hexdigest().encode());h.update(b'\n')
 return h.hexdigest()
seen=set();kinds=set();stages_seen=set()
for number,row in enumerate(csv.reader(lines[2:],delimiter='\t'),3):
 assert len(row)==5 and all(row), (number,row)
 label,stages,kind,raw,digest=row
 assert re.fullmatch(r'[a-z0-9][a-z0-9.:-]*',label) and label not in seen;seen.add(label)
 selected=stages.split(',');assert len(selected)==len(set(selected)) and set(selected)<=known;stages_seen.update(selected)
 path=Path(raw);assert not path.is_absolute() and '..' not in path.parts and '.' not in path.parts
 target=root/path;assert kind in {'file','tree'};kinds.add(kind)
 actual=hashlib.sha256(target.read_bytes()).hexdigest() if kind=='file' else tree_hash(target)
 assert actual==digest,(label,actual,digest)
assert kinds=={'file','tree'}
assert {'official-update','official-packages','archlinuxcn-bootstrap','archlinuxcn-packages','aur-source-acquisition','aur-build-install'}<=stages_seen
assert len([x for x in seen if x.startswith('aur-tree:')])==13
PY

# The production plan must close its fingerprint over every declared applicable
# auxiliary input, not merely the top-level adapter executable.
home="$test_root/home";mkdir -m 700 "$home"
HOME="$home" XDG_STATE_HOME="$test_root/state" \
  python "$root/installer/full-orchestrator.py" --profile vm --plan --json \
  >"$test_root/plan.json"
python - "$test_root/plan.json" <<'PY'
import json,sys
p=json.load(open(sys.argv[1]));inputs=p['inputs']
assert 'stage-input-manifest' in inputs
required={
 'stage-input:archlinuxcn-planner','stage-input:archlinuxcn-bootstrap-policy',
 'stage-input:archlinuxcn-repository-template','stage-input:aur-recipe-policy',
 'stage-input:aur-source-policy','stage-input:aur-build-policy','stage-input:aur-pacman-template',
 'stage-input:aur-plan-tool','stage-input:aur-source-tool','stage-input:aur-build-tool','stage-input:aur-install-tool',
}
assert required<=inputs.keys()
assert len([key for key in inputs if key.startswith('stage-input:aur-tree:')])==13
PY
[[ ! -e $test_root/state ]] || fail 'read-only input-bound plan created state'

# Canonical plans whose applicable stages are already closed over ordinary
# manifest/payload inputs must not be rejected merely because no auxiliary
# stage-input row applies. This covers a real config-only module and the
# explicitly supported empty selection.
for module_selection in personal-scripts none; do
  HOME="$home" XDG_STATE_HOME="$test_root/config-only-state" \
    python "$root/installer/full-orchestrator.py" \
      --profile asus-amd-nvidia --modules "$module_selection" --plan --json \
      >"$test_root/config-only-$module_selection.json"
  python3 - "$test_root/config-only-$module_selection.json" <<'PY'
import json,sys
plan=json.load(open(sys.argv[1]))
stage_inputs=sorted(key for key in plan['inputs'] if key.startswith('stage-input'))
assert stage_inputs == ['stage-input-manifest'], stage_inputs
PY
done
[[ ! -e $test_root/config-only-state ]] || fail 'config-only plan created state'

# A canonical plan must still fail if an applicable trust-boundary stage
# loses every explicitly required auxiliary input while unrelated AUR inputs
# remain. The old global len(result)>1 check missed this partial-coverage case.
coverage_fixture="$test_root/coverage-project"; mkdir -p "$coverage_fixture"
cp -a -- "$root/installer" "$root/manifests" "$root/config" "$root/third_party" "$coverage_fixture/"
python3 - "$coverage_fixture/manifests/stage-inputs.tsv" <<'PY'
from pathlib import Path
import sys
path=Path(sys.argv[1]); lines=path.read_text().splitlines()
remove={'archlinuxcn-planner','archlinuxcn-bootstrap-policy','archlinuxcn-repository-template'}
kept=lines[:2]+[line for line in lines[2:] if line.split('\t',1)[0] not in remove]
path.write_text('\n'.join(kept)+'\n')
PY
set +e
HOME="$home" XDG_STATE_HOME="$test_root/coverage-state" \
  python "$coverage_fixture/installer/full-orchestrator.py" --profile vm --plan --json \
  >"$test_root/coverage.out" 2>&1
coverage_status=$?
set -e
((coverage_status == 1)) || { cat "$test_root/coverage.out" >&2; fail "missing stage input coverage exited $coverage_status"; }
grep -Fq 'applicable stages lack required auxiliary inputs' "$test_root/coverage.out" \
  || fail 'missing per-stage auxiliary input coverage was not reported'
[[ ! -e $test_root/coverage-state ]] || fail 'missing input coverage created state'

# A relocated checkout still resolves project-relative inputs. Mutating one
# pinned planner without updating the reviewed manifest must fail as a trust
# query, before state or any adapter invocation.
fixture="$test_root/project";mkdir -p "$fixture"
cp -a -- "$root/installer" "$root/manifests" "$root/config" "$root/third_party" "$fixture/"
printf '# drift\n' >>"$fixture/installer/archlinuxcn-plan.py"
set +e
HOME="$home" XDG_STATE_HOME="$test_root/drift-state" \
  python "$fixture/installer/full-orchestrator.py" --profile vm --plan --json \
  >"$test_root/drift.out" 2>&1
drift_status=$?
set -e
((drift_status == 1)) || { cat "$test_root/drift.out" >&2; fail "drifted auxiliary input exited $drift_status"; }
grep -Fq 'reviewed stage input hash mismatch' "$test_root/drift.out" \
  || fail 'drifted auxiliary input was not reported explicitly'
[[ ! -e $test_root/drift-state ]] || fail 'drifted auxiliary input created state'

printf '%s\n' 'Stage auxiliary input checks passed.'
