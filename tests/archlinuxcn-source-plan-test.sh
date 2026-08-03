#!/usr/bin/env bash
set -Eeuo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tool="$root/installer/archlinuxcn-plan.py"
[[ -f $tool && ! -L $tool ]] || { printf '%s\n' 'archlinuxcn source planner is missing or unsafe' >&2; exit 1; }

test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT
mock_bin="$test_root/bin"
mkdir -p "$mock_bin" "$test_root/target/etc" "$test_root/target/usr/share/pacman/keyrings"
printf '[options]\n' >"$test_root/target/etc/pacman.conf"

cat >"$mock_bin/pacman-conf" <<'MOCK'
#!/usr/bin/env bash
set -u
scenario=${MOCK_SCENARIO:-absent}
if [[ $scenario == repo-query-failed ]]; then exit 31; fi
if [[ $* == *--repo-list* ]]; then
  printf 'core\nextra\nmultilib\n'
  [[ $scenario == absent || $scenario == package-query-failed ]] || printf 'archlinuxcn\n'
  exit 0
fi
if [[ $* == *Server* ]]; then
  if [[ $scenario == conflict ]]; then
    printf 'Server = https://unreviewed.invalid/archlinuxcn/x86_64\n'
  else
    printf 'Server = https://mirrors.tuna.tsinghua.edu.cn/archlinuxcn/x86_64\n'
  fi
  exit 0
fi
if [[ $* == *SigLevel* ]]; then
  [[ $scenario == inherited ]] || printf 'SigLevel = PackageRequired\nSigLevel = PackageTrustedOnly\nSigLevel = DatabaseOptional\nSigLevel = DatabaseTrustedOnly\n'
  exit 0
fi
if [[ $* == *Usage* ]]; then printf 'Usage = All\n'; exit 0; fi
exit 97
MOCK
cat >"$mock_bin/pacman" <<'MOCK'
#!/usr/bin/env bash
set -u
scenario=${MOCK_SCENARIO:-absent}
if [[ $scenario == package-query-failed ]]; then printf 'error: database read failure\n' >&2; exit 37; fi
if [[ $scenario == absent ]]; then printf "error: package 'archlinuxcn-keyring' was not found\n" >&2; exit 1; fi
printf 'archlinuxcn-keyring 20260505-1\n'
MOCK
chmod 755 "$mock_bin"/*

run_case() {
  local scenario=$1 expected_status=$2
  set +e
  PATH="$mock_bin:$PATH" MOCK_SCENARIO="$scenario" \
    python "$tool" --root "$test_root/target" --json >"$test_root/$scenario.json" 2>"$test_root/$scenario.err"
  local status=$?
  set -e
  ((status == expected_status)) || { printf 'scenario %s: expected exit %s got %s\n' "$scenario" "$expected_status" "$status" >&2; cat "$test_root/$scenario.err" >&2; exit 1; }
}

run_case absent 0
python - "$test_root/absent.json" <<'PY'
import json,sys
p=json.load(open(sys.argv[1]))
assert p['overall']['status']=='ready',p['overall']
assert p['current']['repository']['state']=='absent'
assert p['current']['keyring']['state']=='absent'
assert [x['id'] for x in p['effects']] == ['bootstrap-keyring','write-repository-fragment','include-repository-fragment']
assert p['source_policy']['keyring']['sha256']=='f8ed39c21babdf8fccfc36f603bc6d99c808332238d7e5297714a0f1f624e17a'
assert p['source_policy']['keyring']['signature_sha256']=='e5d4703cf40ee68db240660d19e2806a499837d305510593c9919181c8e70292'
assert p['source_policy']['keyring']['signer_primary_fingerprint']=='B5971F2C5C10A9A08C60030F786C63F330D7CB92'
assert p['safety']=={'read_only':True,'apply_authorized':False,'installer_apply_integration':False,'system_changes':False}
assert p['apply']['commands'] is None and p['apply']['authorized'] is False
assert p['rollback'] and p['post_checks']
PY

run_case matching 0
python - "$test_root/matching.json" <<'PY'
import json,sys
p=json.load(open(sys.argv[1]));assert p['overall']['status']=='ready';assert p['current']['repository']['state']=='matching';assert p['current']['keyring']['state']=='matching';assert p['effects']==[]
PY

run_case conflict 1
python - "$test_root/conflict.json" <<'PY'
import json,sys
p=json.load(open(sys.argv[1]));assert p['overall']['status']=='blocked';assert p['current']['repository']['state']=='conflict';assert p['overall']['blockers'];assert not p['overall']['unavailable_checks']
PY

run_case inherited 1
python - "$test_root/inherited.json" <<'PY'
import json,sys
p=json.load(open(sys.argv[1]));assert p['overall']['status']=='blocked';assert p['current']['repository']['state']=='unmanaged-existing';assert any('SigLevel' in x for x in p['overall']['blockers'])
PY

run_case repo-query-failed 2
python - "$test_root/repo-query-failed.json" <<'PY'
import json,sys
p=json.load(open(sys.argv[1]));assert p['overall']['status']=='unavailable';assert p['current']['repositories']['query_exit']==31;assert p['overall']['unavailable_checks']
PY

run_case package-query-failed 2
python - "$test_root/package-query-failed.json" <<'PY'
import json,sys
p=json.load(open(sys.argv[1]));assert p['overall']['status']=='unavailable';assert p['current']['keyring']['query_exit']==37;assert p['overall']['unavailable_checks']
PY

# Real-host run stays read-only and must preserve its exact nonzero/zero classification.
set +e
python "$tool" --json >"$test_root/real.json"
real_status=$?
set -e
((real_status == 0 || real_status == 1 || real_status == 2))
python - "$test_root/real.json" "$real_status" <<'PY'
import json,sys
p=json.load(open(sys.argv[1]));status=int(sys.argv[2]);expected={'ready':0,'blocked':1,'unavailable':2}[p['overall']['status']];assert status==expected;assert p['safety']['read_only'];assert p['apply']['commands'] is None
PY
printf 'archlinuxcn source plan checks passed (real-host exit=%s).\n' "$real_status"
