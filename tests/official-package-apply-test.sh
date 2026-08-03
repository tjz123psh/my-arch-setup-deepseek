#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tool="$root/installer/official-package-apply.py"
[[ -f $tool && ! -L $tool ]] || {
  printf '%s\n' 'official package apply adapter is missing or unsafe' >&2
  exit 1
}
python - "$tool" "$root" <<'PY'
import hashlib
import importlib.util
from pathlib import Path
import sys
path = Path(sys.argv[1])
root = Path(sys.argv[2])
spec = importlib.util.spec_from_file_location("official_adapter_constants", path)
assert spec is not None and spec.loader is not None
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)
assert module.MINIMUM_FREE_BYTES == 5 * 1024 * 1024 * 1024
assert module.AUDITED_GSUDO_SHA256 == hashlib.sha256(
    (root / "config/home/scripts/desktop/gsudo").read_bytes()
).hexdigest()
assert module.AUDITED_ASKPASS_SHA256 == hashlib.sha256(
    (root / "config/home/scripts/desktop/fuzzel-askpass").read_bytes()
).hexdigest()
assert module.PENDING_GSUDO_SHA256 == module.AUDITED_GSUDO_SHA256
assert module.PENDING_ASKPASS_SHA256 == module.AUDITED_ASKPASS_SHA256
assert module.ARCHLINUXCN_PLANNER_SHA256 == hashlib.sha256(
    (root / "installer/archlinuxcn-plan.py").read_bytes()
).hexdigest()
PY

test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT
mock_bin="$test_root/bin"
case_home="$test_root/home"
system_root="$test_root/system-root"
mkdir -p "$mock_bin" "$case_home/scripts/desktop" "$system_root/etc" "$system_root/var/lib/pacman"
printf 'Arch Linux\n' >"$system_root/etc/arch-release"

call_log="$test_root/calls.tsv"
: >"$call_log"

cat >"$case_home/scripts/desktop/gsudo" <<'MOCK'
#!/usr/bin/env bash
set -u
printf 'gsudo' >>"$MOCK_CALL_LOG"
printf '\t%s' "$@" >>"$MOCK_CALL_LOG"
printf '\n' >>"$MOCK_CALL_LOG"
if [[ -n ${MOCK_GSUDO_FAIL_MATCH:-} && " $* " == *" ${MOCK_GSUDO_FAIL_MATCH} "* ]]; then
  exit "${MOCK_GSUDO_STATUS:-29}"
fi
exit 0
MOCK
cat >"$case_home/scripts/desktop/fuzzel-askpass" <<'MOCK'
#!/usr/bin/env bash
exit 97
MOCK

cat >"$mock_bin/pacman" <<'MOCK'
#!/usr/bin/env bash
set -u
printf 'pacman' >>"$MOCK_CALL_LOG"
printf '\t%s' "$@" >>"$MOCK_CALL_LOG"
printf '\n' >>"$MOCK_CALL_LOG"
scenario=${MOCK_SCENARIO:-ready}
if [[ ${1:-} == --root ]]; then shift 2; fi
case "${1:-}" in
  -Si)
    package=${@: -1}
    if [[ $scenario == si-failed ]]; then
      printf 'mock repository query failed\n' >&2
      exit "${MOCK_QUERY_STATUS:-37}"
    fi
    repository=extra
    [[ $scenario != wrong-repository ]] || repository=archlinuxcn
    printf 'Repository      : %s\n' "$repository"
    printf 'Name            : %s\n' "$package"
    printf 'Version         : 1.0-1\n'
    ;;
  -Q)
    if [[ $scenario == q-failed ]]; then
      printf 'mock installed query failed\n' >&2
      exit "${MOCK_QUERY_STATUS:-41}"
    fi
    [[ $scenario != q-empty ]] || exit 0
    shift
    [[ ${1:-} != -- ]] || shift
    for package in "$@"; do
      if [[ $package == archlinuxcn-keyring ]]; then
        printf '%s 20260505-1\n' "$package"
      else
        printf '%s 1.0-1\n' "$package"
      fi
    done
    ;;
  -Qu)
    case "$scenario" in
      update-pending)
        printf 'mock-package 2.0-1 -> 2.0-2\n'
        exit 0
        ;;
      qu-empty-zero)
        exit 0
        ;;
      qu-failed)
        printf 'mock update query failed\n' >&2
        exit "${MOCK_QUERY_STATUS:-43}"
        ;;
      *)
        exit 1
        ;;
    esac
    ;;
  *)
    printf 'unexpected pacman argv\n' >&2
    exit 97
    ;;
esac
MOCK
cat >"$mock_bin/pacman-conf" <<'MOCK'
#!/usr/bin/env bash
set -u
printf 'pacman-conf' >>"$MOCK_CALL_LOG"
printf '\t%s' "$@" >>"$MOCK_CALL_LOG"
printf '\n' >>"$MOCK_CALL_LOG"
scenario=${MOCK_SCENARIO:-ready}
if [[ $scenario == repo-query-failed ]]; then exit "${MOCK_QUERY_STATUS:-45}"; fi
if [[ ${1:-} == --rootdir ]]; then shift 2; fi
if [[ " $* " == *" --repo-list "* ]]; then
  printf 'core\nextra\nmultilib\n'
  case $scenario in
    arch-existing|arch-conflict) printf 'archlinuxcn\n' ;;
    unknown-repository) printf 'unreviewed\n' ;;
  esac
  exit 0
fi
if [[ " $* " == *" --repo archlinuxcn --verbose Server "* ]]; then
  if [[ $scenario == arch-conflict ]]; then
    printf 'Server = https://unreviewed.invalid/archlinuxcn/x86_64\n'
  else
    printf 'Server = https://mirrors.tuna.tsinghua.edu.cn/archlinuxcn/x86_64\n'
  fi
  exit 0
fi
if [[ " $* " == *" --repo archlinuxcn --verbose SigLevel "* ]]; then
  printf 'SigLevel = PackageRequired\nSigLevel = PackageTrustedOnly\nSigLevel = DatabaseOptional\nSigLevel = DatabaseTrustedOnly\n'
  exit 0
fi
if [[ " $* " == *" --repo archlinuxcn --verbose Usage "* ]]; then
  printf 'Usage = All\n'
  exit 0
fi
exit 97
MOCK
cat >"$mock_bin/getent" <<'MOCK'
#!/usr/bin/env bash
set -u
printf 'getent' >>"$MOCK_CALL_LOG"
printf '\t%s' "$@" >>"$MOCK_CALL_LOG"
printf '\n' >>"$MOCK_CALL_LOG"
if [[ ${MOCK_SCENARIO:-ready} == dns-failed ]]; then
  exit "${MOCK_QUERY_STATUS:-31}"
fi
printf '192.0.2.1 STREAM archlinux.org\n'
MOCK
cat >"$mock_bin/sudo" <<'MOCK'
#!/usr/bin/env bash
printf 'sudo-must-not-run\n' >>"$MOCK_CALL_LOG"
exit 99
MOCK
chmod 755 "$case_home/scripts/desktop/gsudo" "$case_home/scripts/desktop/fuzzel-askpass" "$mock_bin"/*

# Test wrapper changes only in-memory constants for its isolated root and the
# fixture filesystem's free-space threshold.  The production CLI has no
# environment/argument override for /etc, /var/lib, or the 5 GiB threshold.
cat >"$test_root/invoke.py" <<'PY'
#!/usr/bin/env python3
import importlib.util
import os
from pathlib import Path
import sys

path = Path(os.environ["OFFICIAL_ADAPTER_PATH"])
spec = importlib.util.spec_from_file_location("official_package_apply", path)
assert spec is not None and spec.loader is not None
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)
module.SYSTEM_ROOT = Path(os.environ["OFFICIAL_TEST_SYSTEM_ROOT"])
module.MINIMUM_FREE_BYTES = 0
module.AUDITED_GSUDO_SHA256 = os.environ["OFFICIAL_TEST_GSUDO_SHA256"]
module.AUDITED_ASKPASS_SHA256 = os.environ["OFFICIAL_TEST_ASKPASS_SHA256"]
raise SystemExit(module.main())
PY
chmod 755 "$test_root/invoke.py"
audited_gsudo_sha256=$(sha256sum "$case_home/scripts/desktop/gsudo" | awk '{ print $1 }')
audited_askpass_sha256=$(sha256sum "$case_home/scripts/desktop/fuzzel-askpass" | awk '{ print $1 }')

update_effects='[{"detail":"rolling full-system refresh boundary","id":"full-system-refresh","module":"-"}]'
package_effects='[{"detail":"package=power-profiles-daemon channel=pacman repository=extra acquisition=pacman","id":"install:power-profiles-daemon","module":"power"}]'

fail() {
  printf 'official package apply test failed: %s\n' "$*" >&2
  exit 1
}

run_case() {
  local name=$1 stage=$2 action=$3 effects=$4 modules=$5 stage_modules=$6
  shift 6
  local output="$test_root/$name.out"
  : >"$call_log"
  set +e
  env \
    HOME="$case_home" \
    XDG_STATE_HOME="$case_home/.local/state" \
    PATH="$mock_bin:/usr/bin:/bin" \
    MOCK_CALL_LOG="$call_log" \
    OFFICIAL_ADAPTER_PATH="$tool" \
    OFFICIAL_TEST_SYSTEM_ROOT="$system_root" \
    OFFICIAL_TEST_GSUDO_SHA256="$audited_gsudo_sha256" \
    OFFICIAL_TEST_ASKPASS_SHA256="$audited_askpass_sha256" \
    FULL_ORCHESTRATOR_ACTION="$action" \
    FULL_ORCHESTRATOR_STAGE="$stage" \
    FULL_ORCHESTRATOR_PROFILE=asus-amd-nvidia \
    FULL_ORCHESTRATOR_MODULES="$modules" \
    FULL_ORCHESTRATOR_STAGE_MODULES="$stage_modules" \
    FULL_ORCHESTRATOR_EFFECTS_JSON="$effects" \
    FULL_ORCHESTRATOR_PLAN_FINGERPRINT=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    FULL_ORCHESTRATOR_RUN_ID=20260801T000000Z-aaaaaaaaaaaa \
    FULL_ORCHESTRATOR_ATTEMPT=1 \
    "$@" "$test_root/invoke.py" >"$output" 2>&1
  CASE_STATUS=$?
  set -e
  CASE_OUTPUT=$output
}

# Read-only preflight validates runtime, active repository trust, disk, DNS and
# package metadata but never invokes the privilege wrapper.
run_case update-preflight official-update preflight "$update_effects" power power
((CASE_STATUS == 0)) || { cat "$CASE_OUTPUT" >&2; fail "update preflight exited $CASE_STATUS"; }
! grep -Fq $'gsudo\t' "$call_log" || fail 'update preflight invoked gsudo'
grep -Fqx $'getent\tahosts\tarchlinux.org' "$call_log" || fail 'update preflight omitted DNS inventory'
run_case package-preflight official-packages preflight "$package_effects" power power
((CASE_STATUS == 0)) || { cat "$CASE_OUTPUT" >&2; fail "package preflight exited $CASE_STATUS"; }
! grep -Fq $'gsudo\t' "$call_log" || fail 'package preflight invoked gsudo'
grep -Fqx $'pacman\t-Si\t--\tpower-profiles-daemon' "$call_log" || fail 'package preflight omitted repository metadata'

# On a clean target, preflight may recognize that the explicit prerequisite
# privilege-wrapper stage will deploy both exact pinned files; execute still
# requires the installed copies and never falls back to sudo.
mv -- "$case_home/scripts/desktop/gsudo" "$case_home/scripts/desktop/gsudo.pending"
mv -- "$case_home/scripts/desktop/fuzzel-askpass" "$case_home/scripts/desktop/fuzzel-askpass.pending"
run_case pending-wrapper-preflight official-update preflight "$update_effects" power power
((CASE_STATUS == 0)) || { cat "$CASE_OUTPUT" >&2; fail "pending wrapper preflight exited $CASE_STATUS"; }
! grep -Fq $'gsudo\t' "$call_log" || fail 'pending wrapper preflight invoked privilege wrapper'
mv -- "$case_home/scripts/desktop/gsudo.pending" "$case_home/scripts/desktop/gsudo"
mv -- "$case_home/scripts/desktop/fuzzel-askpass.pending" "$case_home/scripts/desktop/fuzzel-askpass"

# Full refresh runs exactly once through the audited graphical wrapper and has
# no sudo fallback or unreviewed shell execution.
run_case update-execute official-update execute "$update_effects" power power
((CASE_STATUS == 0)) || { cat "$CASE_OUTPUT" >&2; fail "update execute exited $CASE_STATUS"; }
grep -Fqx $'gsudo\t--\tpacman\t-Syu\t--noconfirm' "$call_log" || fail 'full update gsudo argv was not exact/noninteractive'
! grep -Fq 'sudo-must-not-run' "$call_log" || fail 'adapter fell back to sudo'
grep -Fqx $'getent\tahosts\tarchlinux.org' "$call_log" || fail 'full update omitted DNS preflight'
grep -Fq $'pacman-conf\t--rootdir\t' "$call_log" || fail 'full update omitted active-repository inventory'

# A full update cannot silently consume an unknown repository or an existing
# archlinuxcn repository that was not selected/independently authorized.
run_case unknown-repository official-update execute "$update_effects" power power env MOCK_SCENARIO=unknown-repository
((CASE_STATUS == 1)) || { cat "$CASE_OUTPUT" >&2; fail "unknown repository exited $CASE_STATUS"; }
! grep -Fq $'gsudo\t' "$call_log" || fail 'unknown repository reached gsudo'
run_case repository-query-failed official-update execute "$update_effects" power power env MOCK_SCENARIO=repo-query-failed MOCK_QUERY_STATUS=45
((CASE_STATUS == 45)) || { cat "$CASE_OUTPUT" >&2; fail "repository query failure became $CASE_STATUS instead of 45"; }
! grep -Fq $'gsudo\t' "$call_log" || fail 'failed repository inventory reached gsudo'
run_case unselected-existing-archlinuxcn official-update execute "$update_effects" power power env MOCK_SCENARIO=arch-existing
((CASE_STATUS == 1)) || { cat "$CASE_OUTPUT" >&2; fail "unselected existing archlinuxcn exited $CASE_STATUS"; }
! grep -Fq $'gsudo\t' "$call_log" || fail 'unselected archlinuxcn reached gsudo'
run_case selected-existing-archlinuxcn official-update execute "$update_effects" asus-hardware asus-hardware env MOCK_SCENARIO=arch-existing
((CASE_STATUS == 0)) || { cat "$CASE_OUTPUT" >&2; fail "selected matching archlinuxcn exited $CASE_STATUS"; }
grep -Fqx $'gsudo\t--\tpacman\t-Syu\t--noconfirm' "$call_log" || fail 'matching selected archlinuxcn did not reach exact noninteractive full update'
run_case conflicting-existing-archlinuxcn official-update execute "$update_effects" asus-hardware asus-hardware env MOCK_SCENARIO=arch-conflict
((CASE_STATUS == 1)) || { cat "$CASE_OUTPUT" >&2; fail "conflicting archlinuxcn exited $CASE_STATUS"; }
! grep -Fq $'gsudo\t' "$call_log" || fail 'conflicting archlinuxcn reached gsudo'

# External failure codes are preserved, and preflight failures occur before
# any privilege request.
run_case update-gsudo-failed official-update execute "$update_effects" power power \
  env MOCK_GSUDO_FAIL_MATCH='pacman -Syu' MOCK_GSUDO_STATUS=29
((CASE_STATUS == 29)) || { cat "$CASE_OUTPUT" >&2; fail "gsudo failure became $CASE_STATUS instead of 29"; }
run_case update-dns-failed official-update execute "$update_effects" power power \
  env MOCK_SCENARIO=dns-failed MOCK_QUERY_STATUS=31
((CASE_STATUS == 31)) || { cat "$CASE_OUTPUT" >&2; fail "DNS failure became $CASE_STATUS instead of 31"; }
! grep -Fq $'gsudo\t' "$call_log" || fail 'DNS failure reached gsudo'

: >"$system_root/var/lib/pacman/db.lck"
run_case update-lock official-update execute "$update_effects" power power
((CASE_STATUS == 2)) || { cat "$CASE_OUTPUT" >&2; fail "pacman lock was not a deterministic blocker ($CASE_STATUS)"; }
! grep -Fq $'gsudo\t' "$call_log" || fail 'pacman lock reached gsudo'
rm -f -- "$system_root/var/lib/pacman/db.lck"

# A successful empty `pacman -Qu` is distinct from query failure or a pending
# transaction.  Pacman's documented empty state is exit 1 with no output.
run_case update-verify-ready official-update verify "$update_effects" power power
((CASE_STATUS == 0)) || { cat "$CASE_OUTPUT" >&2; fail "empty update verification exited $CASE_STATUS"; }
run_case update-verify-pending official-update verify "$update_effects" power power env MOCK_SCENARIO=update-pending
((CASE_STATUS == 1)) || { cat "$CASE_OUTPUT" >&2; fail "pending update verification exited $CASE_STATUS"; }
run_case update-verify-failed official-update verify "$update_effects" power power env MOCK_SCENARIO=qu-failed MOCK_QUERY_STATUS=43
((CASE_STATUS == 43)) || { cat "$CASE_OUTPUT" >&2; fail "update query failure became $CASE_STATUS instead of 43"; }
run_case update-verify-empty-zero official-update verify "$update_effects" power power env MOCK_SCENARIO=qu-empty-zero
((CASE_STATUS == 2)) || { cat "$CASE_OUTPUT" >&2; fail "ambiguous empty exit-0 update query became $CASE_STATUS"; }

# Selected official packages are policy-derived, repository checked, and sent
# as one exact --needed transaction through gsudo.
run_case package-execute official-packages execute "$package_effects" power power
((CASE_STATUS == 0)) || { cat "$CASE_OUTPUT" >&2; fail "package execute exited $CASE_STATUS"; }
grep -Fqx $'pacman\t-Si\t--\tpower-profiles-daemon' "$call_log" || fail 'package repository preflight argv was not exact'
grep -Fqx $'gsudo\t--\tpacman\t-S\t--needed\t--noconfirm\t--\tpower-profiles-daemon' "$call_log" || fail 'package install gsudo argv was not exact/noninteractive'

run_case package-verify official-packages verify "$package_effects" power power
((CASE_STATUS == 0)) || { cat "$CASE_OUTPUT" >&2; fail "package verification exited $CASE_STATUS"; }
grep -Fqx $'pacman\t-Q\t--\tpower-profiles-daemon' "$call_log" || fail 'installed package verification argv was not exact'
grep -Fqx $'pacman\t-Si\t--\tpower-profiles-daemon' "$call_log" || fail 'repository verification argv was not exact'

run_case package-q-failed official-packages verify "$package_effects" power power env MOCK_SCENARIO=q-failed MOCK_QUERY_STATUS=41
((CASE_STATUS == 41)) || { cat "$CASE_OUTPUT" >&2; fail "installed query failure became $CASE_STATUS instead of 41"; }
run_case package-q-empty official-packages verify "$package_effects" power power env MOCK_SCENARIO=q-empty
((CASE_STATUS == 2)) || { cat "$CASE_OUTPUT" >&2; fail "successful empty installed query became $CASE_STATUS"; }
run_case package-wrong-repository official-packages verify "$package_effects" power power env MOCK_SCENARIO=wrong-repository
((CASE_STATUS == 1)) || { cat "$CASE_OUTPUT" >&2; fail "repository mismatch became $CASE_STATUS instead of blocker 1"; }
run_case package-si-failed official-packages execute "$package_effects" power power env MOCK_SCENARIO=si-failed MOCK_QUERY_STATUS=37
((CASE_STATUS == 37)) || { cat "$CASE_OUTPUT" >&2; fail "repository query failure became $CASE_STATUS instead of 37"; }
! grep -Fq $'gsudo\t' "$call_log" || fail 'repository query failure reached gsudo'

# Effect data is not an arbitrary package interface.  It must equal the exact
# selected rows in workstation-packages.tsv, including module and repository.
tampered='[{"detail":"package=unreviewed-package channel=pacman repository=extra acquisition=pacman","id":"install:unreviewed-package","module":"power"}]'
run_case tampered-effect official-packages execute "$tampered" power power
((CASE_STATUS == 2)) || { cat "$CASE_OUTPUT" >&2; fail "tampered package effect exited $CASE_STATUS"; }
[[ ! -s $call_log ]] || fail 'tampered package effect invoked an external command'
run_case mismatched-stage-module official-packages execute "$package_effects" power bluetooth
((CASE_STATUS == 2)) || { cat "$CASE_OUTPUT" >&2; fail "mismatched stage module exited $CASE_STATUS"; }
[[ ! -s $call_log ]] || fail 'mismatched stage module invoked an external command'

# Missing/unsafe gsudo components fail closed and never discover PATH sudo.
mv -- "$case_home/scripts/desktop/gsudo" "$case_home/scripts/desktop/gsudo.saved"
run_case missing-gsudo official-update execute "$update_effects" power power
((CASE_STATUS == 127)) || { cat "$CASE_OUTPUT" >&2; fail "missing gsudo exited $CASE_STATUS instead of 127"; }
[[ ! -s $call_log ]] || fail 'missing gsudo invoked an external command'
mv -- "$case_home/scripts/desktop/gsudo.saved" "$case_home/scripts/desktop/gsudo"
printf '# drift\n' >>"$case_home/scripts/desktop/gsudo"
run_case drifted-gsudo official-update execute "$update_effects" power power
((CASE_STATUS == 2)) || { cat "$CASE_OUTPUT" >&2; fail "drifted gsudo exited $CASE_STATUS"; }
[[ ! -s $call_log ]] || fail 'drifted gsudo invoked an external command'
sed -i '$d' "$case_home/scripts/desktop/gsudo"
rm -f -- "$case_home/scripts/desktop/fuzzel-askpass"
ln -s /bin/false "$case_home/scripts/desktop/fuzzel-askpass"
run_case unsafe-helper official-update execute "$update_effects" power power
((CASE_STATUS == 2)) || { cat "$CASE_OUTPUT" >&2; fail "symlinked askpass helper exited $CASE_STATUS"; }
[[ ! -s $call_log ]] || fail 'unsafe askpass helper invoked an external command'

printf '%s\n' 'Official package apply adapter checks passed.'
