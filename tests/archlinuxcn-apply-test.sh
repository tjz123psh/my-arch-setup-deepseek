#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source_tool="$root/installer/archlinuxcn-apply.py"
source_planner="$root/installer/archlinuxcn-plan.py"

fail() {
  printf 'archlinuxcn apply test failed: %s\n' "$*" >&2
  exit 1
}

[[ -f $source_tool && ! -L $source_tool ]] || fail 'production archlinuxcn stage adapter is missing or unsafe'
[[ -x $source_tool ]] || fail 'production archlinuxcn stage adapter is not executable'
python3 - "$source_tool" "$root" <<'PY'
import hashlib,importlib.util,sys
from pathlib import Path
path=Path(sys.argv[1]);root=Path(sys.argv[2])
spec=importlib.util.spec_from_file_location("archlinuxcn_apply_constants",path)
assert spec is not None and spec.loader is not None
module=importlib.util.module_from_spec(spec);sys.modules[spec.name]=module;spec.loader.exec_module(module)
assert module.AUDITED_GSUDO_SHA256 == hashlib.sha256((root/'config/home/scripts/desktop/gsudo').read_bytes()).hexdigest()
assert module.AUDITED_ASKPASS_SHA256 == hashlib.sha256((root/'config/home/scripts/desktop/fuzzel-askpass').read_bytes()).hexdigest()
assert module.ARCHLINUXCN_PLANNER_SHA256 == hashlib.sha256((root/'installer/archlinuxcn-plan.py').read_bytes()).hexdigest()
PY
[[ -f $source_planner && ! -L $source_planner ]] || fail 'existing archlinuxcn planner is missing or unsafe'

test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT
fixture="$test_root/project"
tool="$fixture/installer/archlinuxcn-apply.py"
planner="$fixture/installer/archlinuxcn-plan.py"
mkdir -p "$fixture/installer" "$fixture/manifests" "$fixture/config/templates" \
  "$fixture/config/home/scripts/desktop"
cp -- "$source_tool" "$tool"
cp -- "$source_planner" "$planner"
cp -- "$root/config/home/scripts/desktop/gsudo" \
  "$fixture/config/home/scripts/desktop/gsudo"
cp -- "$root/config/home/scripts/desktop/fuzzel-askpass" \
  "$fixture/config/home/scripts/desktop/fuzzel-askpass"
chmod 755 "$tool" "$planner"
chmod 755 "$fixture/config/home/scripts/desktop/gsudo" \
  "$fixture/config/home/scripts/desktop/fuzzel-askpass"

package_asset="$test_root/archlinuxcn-keyring.pkg.tar.zst"
signature_asset="$test_root/archlinuxcn-keyring.pkg.tar.zst.sig"
printf 'fixed test keyring package payload\n' >"$package_asset"
printf 'fixed detached signature payload\n' >"$signature_asset"
package_sha=$(sha256sum "$package_asset" | awk '{print $1}')
signature_sha=$(sha256sum "$signature_asset" | awk '{print $1}')
signer='AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
secret='bootstrap-query-secret'

cat >"$fixture/manifests/archlinuxcn-bootstrap.tsv" <<EOF
# schema=1
# package<TAB>version<TAB>package-url<TAB>sha256<TAB>signature-url<TAB>signature-sha256<TAB>signer-primary-fingerprint<TAB>repository<TAB>server<TAB>siglevel<TAB>database-signature<TAB>authorization
archlinuxcn-keyring	20260505-1	https://downloads.example.test/archlinuxcn-keyring.pkg.tar.zst?token=$secret	$package_sha	https://downloads.example.test/archlinuxcn-keyring.pkg.tar.zst.sig?token=$secret	$signature_sha	$signer	archlinuxcn	https://mirror.example.test/archlinuxcn/\$arch	Required DatabaseOptional TrustedOnly	unavailable-upstream	archlinuxcn
EOF

cat >"$fixture/config/templates/archlinuxcn.conf" <<'EOF'
# Managed by my-archlinux-setup only after an exact absent-state check and explicit archlinuxcn authorization.
[archlinuxcn]
SigLevel = Required DatabaseOptional TrustedOnly
Server = https://mirror.example.test/archlinuxcn/$arch
EOF

cat >"$fixture/manifests/workstation-packages.tsv" <<'EOF'
# schema=1
# package<TAB>channel<TAB>repository<TAB>acquisition<TAB>module<TAB>restore-mode<TAB>policy<TAB>origin<TAB>purpose
archlinuxcn-keyring	pacman	archlinuxcn	archlinuxcn-bootstrap	repository-tools	package-only	install	current-explicit	Pinned keyring fixture
cc-switch	pacman	archlinuxcn	pacman	development-toolchain	package-only	install	current-explicit	Package fixture one
downgrade	pacman	archlinuxcn	pacman	repository-tools	package-only	install	current-explicit	Package fixture two
evil-official	pacman	extra	pacman	repository-tools	package-only	install	confirmed-desired	Must never enter archlinuxcn stage
deferred-cn	pacman	archlinuxcn	deferred	repository-tools	deferred	deferred	current-explicit	Must never be executable
EOF

mock_bin="$test_root/mock-bin"
mkdir -p "$mock_bin"

cat >"$mock_bin/curl" <<'MOCK'
#!/usr/bin/env bash
set -u
printf 'curl' >>"$MOCK_CALL_LOG"; printf '\t%s' "$@" >>"$MOCK_CALL_LOG"; printf '\n' >>"$MOCK_CALL_LOG"
if [[ -f "$MOCK_STATE/curl-fail" ]]; then exit "$(<"$MOCK_STATE/curl-fail")"; fi
output=''
url=''
head_only=false
while (($#)); do
  case "$1" in
    --output) output=${2:-}; shift 2 ;;
    --head) head_only=true; shift ;;
    https://*) url=$1; shift ;;
    *) shift ;;
  esac
done
[[ -n $url ]] || exit 96
if [[ $head_only == true ]]; then exit 0; fi
[[ -n $output ]] || exit 96
if [[ $url == *.sig* ]]; then
  cp -- "$MOCK_SIGNATURE_ASSET" "$output"
else
  cp -- "$MOCK_PACKAGE_ASSET" "$output"
fi
MOCK

cat >"$mock_bin/gpg" <<'MOCK'
#!/usr/bin/env bash
set -u
printf 'gpg' >>"$MOCK_CALL_LOG"; printf '\t%s' "$@" >>"$MOCK_CALL_LOG"; printf '\n' >>"$MOCK_CALL_LOG"
if [[ -f "$MOCK_STATE/gpg-fail" ]]; then exit "$(<"$MOCK_STATE/gpg-fail")"; fi
signer=${MOCK_EXPECTED_SIGNER:?}
[[ ! -f "$MOCK_STATE/gpg-signer" ]] || signer=$(<"$MOCK_STATE/gpg-signer")
printf '[GNUPG:] NEWSIG\n'
printf '[GNUPG:] GOODSIG 0000000000000000 Test Signer\n'
printf '[GNUPG:] VALIDSIG %s 2026-08-01 1785500000 0 4 0 1 10 00 %s\n' "$signer" "$signer"
MOCK

cat >"$mock_bin/pacman-conf" <<'MOCK'
#!/usr/bin/env bash
set -u
printf 'pacman-conf' >>"$MOCK_CALL_LOG"; printf '\t%s' "$@" >>"$MOCK_CALL_LOG"; printf '\n' >>"$MOCK_CALL_LOG"
root=/
args=("$@")
if [[ ${1:-} == --rootdir ]]; then root=$2; shift 2; fi
mode=auto
[[ ! -f "$MOCK_STATE/repo-mode" ]] || mode=$(<"$MOCK_STATE/repo-mode")
fragment="$root/etc/pacman.d/my-archlinux-setup-archlinuxcn.conf"
conf="$root/etc/pacman.conf"
if [[ $mode == auto ]]; then
  if [[ -f $fragment && -f $conf ]] && grep -Fqx 'Include = /etc/pacman.d/my-archlinux-setup-archlinuxcn.conf' "$conf"; then
    mode=matching
  else
    mode=absent
  fi
fi
if [[ $mode == unavailable ]]; then exit 31; fi
if [[ $* == *--repo-list* ]]; then
  printf 'core\nextra\n'
  [[ $mode == absent ]] || printf 'archlinuxcn\n'
  exit 0
fi
if [[ $* == *Server* ]]; then
  if [[ $mode == conflict ]]; then
    printf 'Server = https://unreviewed.invalid/archlinuxcn/x86_64\n'
  else
    printf 'Server = https://mirror.example.test/archlinuxcn/x86_64\n'
  fi
  exit 0
fi
if [[ $* == *SigLevel* ]]; then
  [[ $mode == inherited ]] || printf 'SigLevel = PackageRequired\nSigLevel = PackageTrustedOnly\nSigLevel = DatabaseOptional\nSigLevel = DatabaseTrustedOnly\n'
  exit 0
fi
if [[ $* == *Usage* ]]; then printf 'Usage = All\n'; exit 0; fi
exit 97
MOCK

cat >"$mock_bin/pacman" <<'MOCK'
#!/usr/bin/env bash
set -u
printf 'pacman' >>"$MOCK_CALL_LOG"; printf '\t%s' "$@" >>"$MOCK_CALL_LOG"; printf '\n' >>"$MOCK_CALL_LOG"
if [[ ${1:-} == --root ]]; then shift 2; fi
action=${1:-}
shift || true
case "$action" in
  -Q)
    [[ ${1:-} != -- ]] || shift
    package=${1:-}
    if [[ -f "$MOCK_STATE/fail-Q-$package" ]]; then exit "$(<"$MOCK_STATE/fail-Q-$package")"; fi
    if [[ -f "$MOCK_STATE/empty-Q-$package" ]]; then exit 0; fi
    if [[ $package == archlinuxcn-keyring ]]; then
      if [[ -f "$MOCK_STATE/keyring-installed" ]]; then
        printf 'archlinuxcn-keyring 20260505-1\n'
        exit 0
      fi
      printf "error: package 'archlinuxcn-keyring' was not found\n" >&2
      exit 1
    fi
    if [[ -f "$MOCK_STATE/installed-$package" ]]; then
      printf '%s 1.0-1\n' "$package"
      exit 0
    fi
    printf "error: package '%s' was not found\n" "$package" >&2
    exit 1
    ;;
  -Si)
    [[ ${1:-} != -- ]] || shift
    package=${1:-}
    if [[ -f "$MOCK_STATE/fail-Si-$package" ]]; then exit "$(<"$MOCK_STATE/fail-Si-$package")"; fi
    if [[ -f "$MOCK_STATE/empty-Si-$package" ]]; then exit 0; fi
    if [[ ! -f "$MOCK_STATE/database-ready" ]]; then
      printf 'error: database not found: archlinuxcn\n' >&2
      exit 1
    fi
    repository=archlinuxcn
    [[ ! -f "$MOCK_STATE/repo-Si-$package" ]] || repository=$(<"$MOCK_STATE/repo-Si-$package")
    printf 'Repository      : %s\n' "$repository"
    printf 'Name            : %s\n' "$package"
    printf 'Version         : 1.0-1\n'
    ;;
  -Syu)
    [[ ${1:-} == --noconfirm && $# == 1 ]] || exit 90
    if [[ -f "$MOCK_STATE/syu-fail" ]]; then exit "$(<"$MOCK_STATE/syu-fail")"; fi
    : >"$MOCK_STATE/database-ready"
    ;;
  -U)
    [[ ${1:-} == --needed ]] || exit 91
    shift
    [[ ${1:-} == --noconfirm ]] || exit 92
    shift
    [[ ${1:-} == -- ]] || exit 93
    shift
    (($# == 1)) || exit 94
    : >"$MOCK_STATE/keyring-installed"
    ;;
  -S)
    [[ ${1:-} == --needed ]] || exit 91
    shift
    [[ ${1:-} == --noconfirm ]] || exit 92
    shift
    [[ ${1:-} == -- ]] || exit 93
    shift
    (($# > 0)) || exit 94
    for package in "$@"; do : >"$MOCK_STATE/installed-$package"; done
    ;;
  *) exit 95 ;;
esac
MOCK

cat >"$mock_bin/sudo" <<'MOCK'
#!/usr/bin/env bash
set -u
printf 'sudo-called\n' >>"$MOCK_CALL_LOG"
exit 99
MOCK
chmod 755 "$mock_bin"/*

make_wrapper() {
  local home=$1
  mkdir -p "$home/scripts/desktop"
  cat >"$home/scripts/desktop/gsudo" <<'MOCK'
#!/usr/bin/env bash
set -u
printf 'gsudo' >>"$MOCK_CALL_LOG"; printf '\t%s' "$@" >>"$MOCK_CALL_LOG"; printf '\n' >>"$MOCK_CALL_LOG"
if [[ -f "$MOCK_STATE/gsudo-fail" ]]; then exit "$(<"$MOCK_STATE/gsudo-fail")"; fi
[[ ${1:-} == -- ]] || exit 98
shift
exec "$@"
MOCK
  cat >"$home/scripts/desktop/fuzzel-askpass" <<'MOCK'
#!/usr/bin/env bash
exit 97
MOCK
  chmod 755 "$home/scripts/desktop/gsudo" "$home/scripts/desktop/fuzzel-askpass"
}

reviewed_wrapper_home="$test_root/reviewed-wrapper-home"
make_wrapper "$reviewed_wrapper_home"
reviewed_gsudo_sha256=$(sha256sum "$reviewed_wrapper_home/scripts/desktop/gsudo" | awk '{print $1}')
reviewed_askpass_sha256=$(sha256sum "$reviewed_wrapper_home/scripts/desktop/fuzzel-askpass" | awk '{print $1}')

CASE_HOME=''
CASE_ROOT=''
CASE_STATE=''
CASE_CALLS=''
prepare_case() {
  local name=$1
  CASE_HOME="$test_root/cases/$name/home"
  CASE_ROOT="$test_root/cases/$name/target"
  CASE_STATE="$test_root/cases/$name/mock-state"
  CASE_CALLS="$test_root/cases/$name/calls.tsv"
  mkdir -p "$CASE_HOME" "$CASE_ROOT" "$CASE_STATE"
  chmod 700 "$CASE_HOME" "$CASE_ROOT" "$CASE_STATE"
  mkdir -p "$CASE_ROOT/etc/pacman.d/gnupg"
  printf '[options]\nArchitecture = auto\n' >"$CASE_ROOT/etc/pacman.conf"
  chmod 640 "$CASE_ROOT/etc/pacman.conf"
  printf 'fixture official keyring\n' >"$CASE_ROOT/etc/pacman.d/gnupg/pubring.gpg"
  : >"$CASE_CALLS"
  make_wrapper "$CASE_HOME"
}

stage_effects_bootstrap='[{"detail":"package=archlinuxcn-keyring channel=pacman repository=archlinuxcn acquisition=archlinuxcn-bootstrap repository-config=fixed-include-fragment refresh=conditional-full-system-and-repository","id":"bootstrap:archlinuxcn-keyring","module":"repository-tools"}]'
stage_effects_packages='[{"detail":"package=cc-switch channel=pacman repository=archlinuxcn acquisition=pacman","id":"install:cc-switch","module":"development-toolchain"},{"detail":"package=downgrade channel=pacman repository=archlinuxcn acquisition=pacman","id":"install:downgrade","module":"repository-tools"}]'

run_stage() {
  local output=$1 stage=$2 action=$3 effects=$4 selected_modules=$5 stage_modules=$6
  set +e
  HOME="$CASE_HOME" XDG_STATE_HOME="$CASE_HOME/state" PATH="$mock_bin:/usr/bin" \
    ARCHLINUXCN_APPLY_TESTING=1 ARCHLINUXCN_APPLY_TEST_ROOT="$CASE_ROOT" \
    ARCHLINUXCN_TEST_GSUDO_SHA256="$reviewed_gsudo_sha256" \
    ARCHLINUXCN_TEST_ASKPASS_SHA256="$reviewed_askpass_sha256" \
    MOCK_STATE="$CASE_STATE" MOCK_CALL_LOG="$CASE_CALLS" \
    MOCK_PACKAGE_ASSET="$package_asset" MOCK_SIGNATURE_ASSET="$signature_asset" \
    MOCK_EXPECTED_SIGNER="$signer" \
    FULL_ORCHESTRATOR_ACTION="$action" FULL_ORCHESTRATOR_STAGE="$stage" \
    FULL_ORCHESTRATOR_PROFILE=test FULL_ORCHESTRATOR_MODULES="$selected_modules" \
    FULL_ORCHESTRATOR_STAGE_MODULES="$stage_modules" FULL_ORCHESTRATOR_EFFECTS_JSON="$effects" \
    FULL_ORCHESTRATOR_PLAN_FINGERPRINT=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    FULL_ORCHESTRATOR_RUN_ID=20260801T000000Z-deadbeef0001 FULL_ORCHESTRATOR_ATTEMPT=1 \
    python3 "$tool" >"$output" 2>&1
  RUN_STATUS=$?
  set -e
}

prepare_matching() {
  cp -- "$fixture/config/templates/archlinuxcn.conf" \
    "$CASE_ROOT/etc/pacman.d/my-archlinux-setup-archlinuxcn.conf"
  printf '\nInclude = /etc/pacman.d/my-archlinux-setup-archlinuxcn.conf\n' >>"$CASE_ROOT/etc/pacman.conf"
  : >"$CASE_STATE/keyring-installed"
  : >"$CASE_STATE/database-ready"
}

prepare_matching_without_database() {
  cp -- "$fixture/config/templates/archlinuxcn.conf" \
    "$CASE_ROOT/etc/pacman.d/my-archlinux-setup-archlinuxcn.conf"
  printf '\nInclude = /etc/pacman.d/my-archlinux-setup-archlinuxcn.conf\n' >>"$CASE_ROOT/etc/pacman.conf"
  : >"$CASE_STATE/keyring-installed"
}

count_call() {
  local prefix=$1
  awk -v prefix="$prefix" 'index($0,prefix)==1 {count++} END {print count+0}' "$CASE_CALLS"
}

# Planner code is part of the reviewed trust boundary. Drift is rejected before
# the planner or any package/network/root command can run.
cp -- "$planner" "$test_root/planner.reviewed"
printf '# concurrent planner drift
' >>"$planner"
prepare_case planner-drift
run_stage "$test_root/planner-drift.out" archlinuxcn-bootstrap preflight \
  "$stage_effects_bootstrap" repository-tools repository-tools
((RUN_STATUS == 1)) || { cat "$test_root/planner-drift.out" >&2; fail "planner drift exited $RUN_STATUS"; }
grep -Fq 'planner SHA-256 mismatch' "$test_root/planner-drift.out" || fail 'planner drift was not explicit'
[[ ! -s $CASE_CALLS ]] || fail 'drifted planner reached an external command'
cp -- "$test_root/planner.reviewed" "$planner"
chmod 755 "$planner"

# Preflight is strictly read-only: planner/trust, wrapper/helper, source tools,
# free space, HTTPS reachability and pre-existing cache conflicts are checked
# without creating state/cache/logs, downloading, invoking gsudo, or changing packages.
prepare_case bootstrap-preflight
preflight_target_hash=$(find "$CASE_ROOT" -xdev -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | awk '{print $1}')
run_stage "$test_root/bootstrap-preflight.out" archlinuxcn-bootstrap preflight \
  "$stage_effects_bootstrap" repository-tools repository-tools
((RUN_STATUS == 0)) || { cat "$test_root/bootstrap-preflight.out" >&2; fail "bootstrap preflight exited $RUN_STATUS"; }
[[ ! -e "$CASE_HOME/state/my-archlinux-setup/archlinuxcn-apply" ]] || fail 'bootstrap preflight wrote state/cache/logs'
[[ $(count_call $'gsudo\t') == 0 ]] || fail 'bootstrap preflight invoked gsudo'
[[ $(count_call $'gpg\t') == 0 ]] || fail 'bootstrap preflight invoked GPG instead of checking tool/key availability'
[[ $(grep -c $'^curl\t.*\t--head\t--\thttps://' "$CASE_CALLS") == 2 ]] || \
  fail 'bootstrap preflight did not perform two fixed HTTPS HEAD checks'
! grep -q $'^curl\t.*\t--output\t' "$CASE_CALLS" || fail 'bootstrap preflight supplied a download output path'
preflight_target_after=$(find "$CASE_ROOT" -xdev -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | awk '{print $1}')
[[ $preflight_target_after == "$preflight_target_hash" ]] || fail 'bootstrap preflight changed isolated target files'

prepare_case packages-preflight
prepare_matching
run_stage "$test_root/packages-preflight.out" archlinuxcn-packages preflight \
  "$stage_effects_packages" repository-tools,development-toolchain repository-tools,development-toolchain
((RUN_STATUS == 0)) || { cat "$test_root/packages-preflight.out" >&2; fail "packages preflight exited $RUN_STATUS"; }
[[ ! -e "$CASE_HOME/state/my-archlinux-setup/archlinuxcn-apply" ]] || fail 'packages preflight wrote state/cache/logs'
[[ $(count_call $'gsudo\t') == 0 ]] || fail 'packages preflight invoked gsudo'
grep -Fqx $'pacman\t-Si\t--\tcc-switch' "$CASE_CALLS" || fail 'packages preflight omitted exact cc-switch metadata check'
grep -Fqx $'pacman\t-Si\t--\tdowngrade' "$CASE_CALLS" || fail 'packages preflight omitted exact downgrade metadata check'
! grep -Eq -- $'(^|\t)-S(yu)?($|\t)' "$CASE_CALLS" || fail 'packages preflight invoked a changing pacman action'

# Global preflight runs before the earlier privilege-wrapper stage executes.
# Exactly two absent installed payloads are therefore expected-pending when the
# repository copies still match the fixed review. Execute must remain strict.
prepare_case packages-preflight-clean-home
prepare_matching
rm -f -- "$CASE_HOME/scripts/desktop/gsudo" "$CASE_HOME/scripts/desktop/fuzzel-askpass"
clean_home_before=$(find "$CASE_HOME" "$CASE_ROOT" -xdev -printf '%p|%y|%m|%s|%T@|%l\n' \
  -exec sha256sum {} \; 2>/dev/null | sha256sum)
run_stage "$test_root/packages-preflight-clean-home.out" archlinuxcn-packages preflight \
  "$stage_effects_packages" development-toolchain,repository-tools development-toolchain,repository-tools
((RUN_STATUS == 0)) || { cat "$test_root/packages-preflight-clean-home.out" >&2; fail "clean-HOME packages preflight exited $RUN_STATUS"; }
clean_home_after=$(find "$CASE_HOME" "$CASE_ROOT" -xdev -printf '%p|%y|%m|%s|%T@|%l\n' \
  -exec sha256sum {} \; 2>/dev/null | sha256sum)
[[ $clean_home_after == "$clean_home_before" ]] || fail 'clean-HOME packages preflight changed target or HOME'
[[ $(count_call $'gsudo\t') == 0 ]] || fail 'clean-HOME packages preflight invoked gsudo'

run_stage "$test_root/packages-execute-clean-home.out" archlinuxcn-packages execute \
  "$stage_effects_packages" development-toolchain,repository-tools development-toolchain,repository-tools
((RUN_STATUS != 0)) || fail 'clean-HOME packages execute accepted missing privilege payloads'
[[ $(count_call $'gsudo\t') == 0 ]] || fail 'clean-HOME packages execute reached gsudo'
! grep -Eq -- $'(^|\t)-S($|\t)' "$CASE_CALLS" || fail 'clean-HOME packages execute reached package installation'

# The archlinuxcn package stage is globally preflighted before its bootstrap
# dependency executes. A planner-approved absent keyring/repository is pending,
# so metadata cannot yet be queried; execute/verify remain strict afterward.
prepare_case packages-preflight-bootstrap-pending
rm -f -- "$CASE_HOME/scripts/desktop/gsudo" "$CASE_HOME/scripts/desktop/fuzzel-askpass"
pending_before=$(find "$CASE_HOME" "$CASE_ROOT" -xdev -printf '%p|%y|%m|%s|%T@|%l\n' \
  -exec sha256sum {} \; 2>/dev/null | sha256sum)
run_stage "$test_root/packages-preflight-bootstrap-pending.out" archlinuxcn-packages preflight \
  "$stage_effects_packages" development-toolchain,repository-tools development-toolchain,repository-tools
((RUN_STATUS == 0)) || { cat "$test_root/packages-preflight-bootstrap-pending.out" >&2; fail "pending-bootstrap packages preflight exited $RUN_STATUS"; }
pending_after=$(find "$CASE_HOME" "$CASE_ROOT" -xdev -printf '%p|%y|%m|%s|%T@|%l\n' \
  -exec sha256sum {} \; 2>/dev/null | sha256sum)
[[ $pending_after == "$pending_before" ]] || fail 'pending-bootstrap packages preflight changed target or HOME'
[[ $(count_call $'gsudo\t') == 0 ]] || fail 'pending-bootstrap packages preflight invoked gsudo'
[[ $(count_call $'pacman\t-Si\t') == 0 ]] || fail 'pending-bootstrap packages preflight queried unavailable repository metadata'

prepare_case preflight-network-failure
printf '43\n' >"$CASE_STATE/curl-fail"
run_stage "$test_root/preflight-network-failure.out" archlinuxcn-bootstrap preflight \
  "$stage_effects_bootstrap" repository-tools repository-tools
((RUN_STATUS == 43)) || fail "preflight network failure exit was $RUN_STATUS instead of 43"
[[ ! -e "$CASE_HOME/state/my-archlinux-setup/archlinuxcn-apply" ]] || fail 'failed preflight wrote state/cache/logs'
[[ $(count_call $'gsudo\t') == 0 ]] || fail 'failed preflight invoked gsudo'

prepare_case preflight-missing-gsudo
rm -f -- "$CASE_HOME/scripts/desktop/gsudo"
run_stage "$test_root/preflight-missing-gsudo.out" archlinuxcn-bootstrap preflight \
  "$stage_effects_bootstrap" repository-tools repository-tools
((RUN_STATUS != 0)) || fail 'preflight accepted a missing gsudo wrapper'
[[ ! -e "$CASE_HOME/state/my-archlinux-setup/archlinuxcn-apply" ]] || fail 'missing-wrapper preflight wrote state'
[[ $(count_call $'curl\t') == 0 && $(count_call $'gsudo\t') == 0 ]] || \
  fail 'missing-wrapper preflight reached network/root'
! grep -Fq 'sudo-called' "$CASE_CALLS" || fail 'preflight missing wrapper fell back to sudo'

prepare_case preflight-drifted-gsudo
printf '# drift\n' >>"$CASE_HOME/scripts/desktop/gsudo"
run_stage "$test_root/preflight-drifted-gsudo.out" archlinuxcn-bootstrap preflight \
  "$stage_effects_bootstrap" repository-tools repository-tools
((RUN_STATUS == 1)) || fail "drifted gsudo preflight exited $RUN_STATUS instead of 1"
[[ $(count_call $'curl\t') == 0 && $(count_call $'gsudo\t') == 0 ]] || \
  fail 'drifted wrapper reached network or privilege execution'

prepare_case preflight-cache-conflict
preflight_state="$CASE_HOME/state/my-archlinux-setup/archlinuxcn-apply"
mkdir -p "$preflight_state/cache"
chmod 700 "$CASE_HOME/state" "$CASE_HOME/state/my-archlinux-setup" "$preflight_state" "$preflight_state/cache"
printf 'conflicting cached bytes\n' >"$preflight_state/cache/archlinuxcn-keyring-20260505-1.pkg.tar.zst"
chmod 600 "$preflight_state/cache/archlinuxcn-keyring-20260505-1.pkg.tar.zst"
cache_hash_before=$(sha256sum "$preflight_state/cache/archlinuxcn-keyring-20260505-1.pkg.tar.zst" | awk '{print $1}')
run_stage "$test_root/preflight-cache-conflict.out" archlinuxcn-bootstrap preflight \
  "$stage_effects_bootstrap" repository-tools repository-tools
((RUN_STATUS == 1)) || fail "preflight cache conflict exit was $RUN_STATUS instead of 1"
grep -Fq 'cached package SHA-256 mismatch' "$test_root/preflight-cache-conflict.out" || fail 'preflight cache conflict was not explained'
[[ $(sha256sum "$preflight_state/cache/archlinuxcn-keyring-20260505-1.pkg.tar.zst" | awk '{print $1}') == "$cache_hash_before" ]] || \
  fail 'preflight rewrote conflicting cache evidence'
[[ $(count_call $'gsudo\t') == 0 ]] || fail 'cache-conflict preflight invoked gsudo'

# Bootstrap execute must classify through the existing planner before network or root,
# verify both exact hashes and the offline primary signer, preserve prior config, and
# perform every root command through the audited wrapper.
prepare_case bootstrap-success
run_stage "$test_root/bootstrap-success.out" archlinuxcn-bootstrap execute \
  "$stage_effects_bootstrap" repository-tools repository-tools
((RUN_STATUS == 0)) || { cat "$test_root/bootstrap-success.out" >&2; fail "bootstrap execute exited $RUN_STATUS"; }
fragment="$CASE_ROOT/etc/pacman.d/my-archlinux-setup-archlinuxcn.conf"
cmp -s -- "$fixture/config/templates/archlinuxcn.conf" "$fragment" || fail 'root helper did not install the exact fragment'
[[ $(grep -Fxc 'Include = /etc/pacman.d/my-archlinux-setup-archlinuxcn.conf' "$CASE_ROOT/etc/pacman.conf") == 1 ]] || \
  fail 'root helper did not install one exact Include line'
[[ $(stat -c '%a' "$CASE_ROOT/etc/pacman.conf") == 640 ]] || fail 'root helper did not preserve pacman.conf mode'
[[ $(stat -c '%a' "$fragment") == 644 ]] || fail 'new repository fragment is not mode 644'
grep -Eq $'^gsudo\t--\tpacman\t-U\t--needed\t--noconfirm\t--\t.*/cache/archlinuxcn-keyring-20260505-1.pkg.tar.zst$' "$CASE_CALLS" || \
  fail 'bootstrap keyring install argv was not exact or did not use gsudo'
grep -Eq $'^gsudo\t--\t.*/installer/archlinuxcn-apply.py\t--root-helper\t--target-root\t' "$CASE_CALLS" || \
  fail 'repository writes did not use the same-file root helper through gsudo'
grep -Fqx $'gsudo\t--\tpacman\t-Syu\t--noconfirm' "$CASE_CALLS" || \
  fail 'clean bootstrap did not perform one exact full refresh through gsudo'
[[ $(grep -Fxc $'gsudo\t--\tpacman\t-Syu\t--noconfirm' "$CASE_CALLS") == 1 ]] || \
  fail 'clean bootstrap performed more than one full refresh'
helper_line=$(grep -n -m1 $'^gsudo\t--\t.*/installer/archlinuxcn-apply.py\t--root-helper' "$CASE_CALLS" | cut -d: -f1)
syu_line=$(grep -n -m1 -F $'gsudo\t--\tpacman\t-Syu\t--noconfirm' "$CASE_CALLS" | cut -d: -f1)
((helper_line < syu_line)) || fail 'full refresh ran before keyring/fragment/Include configuration completed'
(( $(grep -c $'^pacman\t-Si\t--\tarchlinuxcn-keyring$' "$CASE_CALLS") >= 1 )) || \
  fail 'bootstrap did not verify archlinuxcn metadata after full refresh'
grep -Eq $'^curl\t--disable\t--fail\t--show-error\t--silent\t--location\t--proto\t=https\t--proto-redir\t=https\t--tlsv1.2\t--output\t' "$CASE_CALLS" || \
  fail 'curl HTTPS restriction argv was not exact'
grep -Eq $'^gpg\t--batch\t--no-options\t--homedir\t.*/gpg-[^/]+\t--no-auto-key-retrieve\t--no-default-keyring\t--keyring\t.*/etc/pacman.d/gnupg/pubring.gpg\t--status-fd\t1\t--trust-model\talways\t--verify\t' "$CASE_CALLS" || \
  fail 'offline GPG verification argv was not exact'
first_curl=$(grep -n -m1 $'^curl\t' "$CASE_CALLS" | cut -d: -f1)
first_planner=$(grep -n -m1 $'^pacman-conf\t' "$CASE_CALLS" | cut -d: -f1)
((first_planner < first_curl)) || fail 'bootstrap downloaded before planner classification'
state_root="$CASE_HOME/state/my-archlinux-setup/archlinuxcn-apply"
[[ $(stat -c '%a' "$state_root") == 700 ]] || fail 'adapter state root is not mode 700'
[[ $(stat -c '%a' "$state_root/cache") == 700 ]] || fail 'download cache is not mode 700'
while IFS= read -r cached; do [[ $(stat -c '%a' "$cached") == 600 ]] || fail "cache file is not mode 600: $cached"; done < <(find "$state_root/cache" -maxdepth 1 -type f)
logs=("$state_root"/logs/*.log)
((${#logs[@]} == 1)) || fail 'bootstrap did not create one private adapter log'
[[ $(stat -c '%a' "${logs[0]}") == 600 ]] || fail 'adapter log is not mode 600'
! grep -Fq "$secret" "${logs[0]}" || fail 'adapter log leaked a sensitive URL query'
! grep -Fq 'https://' "${logs[0]}" || fail 'adapter log recorded a download URL'
backup_meta=$(find "$state_root/backups" -name prior.json -type f -print -quit)
[[ -n $backup_meta && $(stat -c '%a' "$backup_meta") == 600 ]] || fail 'prior-state metadata backup is missing or not private'
python3 - "$backup_meta" <<'PY' || fail 'prior-state backup did not record both exact targets'
import json,sys
p=json.load(open(sys.argv[1]))
assert p['pacman_conf']['exists'] is True
assert p['fragment']['exists'] is False
assert p['automatic_rollback'] is False
PY

# Matching rerun is a no-op: no second curl/GPG/root operation. Verify is read-only.
curl_before=$(count_call $'curl\t')
gsudo_before=$(count_call $'gsudo\t')
syu_before=$(grep -Fxc $'gsudo\t--\tpacman\t-Syu\t--noconfirm' "$CASE_CALLS")
run_stage "$test_root/bootstrap-rerun.out" archlinuxcn-bootstrap execute \
  "$stage_effects_bootstrap" repository-tools repository-tools
((RUN_STATUS == 0)) || { cat "$test_root/bootstrap-rerun.out" >&2; fail "idempotent bootstrap exited $RUN_STATUS"; }
[[ $(count_call $'curl\t') == "$curl_before" ]] || fail 'idempotent bootstrap downloaded again'
[[ $(count_call $'gsudo\t') == "$gsudo_before" ]] || fail 'idempotent bootstrap invoked root again'
[[ $(grep -Fxc $'gsudo\t--\tpacman\t-Syu\t--noconfirm' "$CASE_CALLS") == "$syu_before" ]] || \
  fail 'idempotent bootstrap refreshed again'
run_stage "$test_root/bootstrap-verify.out" archlinuxcn-bootstrap verify \
  "$stage_effects_bootstrap" repository-tools repository-tools
((RUN_STATUS == 0)) || { cat "$test_root/bootstrap-verify.out" >&2; fail "bootstrap verify exited $RUN_STATUS"; }
[[ $(count_call $'gsudo\t') == "$gsudo_before" ]] || fail 'bootstrap verify invoked root'

# A matching existing configuration with a missing database is classified as
# refresh-required, never as a successful empty query. Execute may repair it only
# with the same exact full refresh; verifier remains read-only and preserves exit 1.
prepare_case matching-needs-refresh
prepare_matching_without_database
run_stage "$test_root/matching-needs-refresh.out" archlinuxcn-bootstrap execute \
  "$stage_effects_bootstrap" repository-tools repository-tools
((RUN_STATUS == 0)) || { cat "$test_root/matching-needs-refresh.out" >&2; fail "matching refresh repair exited $RUN_STATUS"; }
[[ $(grep -Fxc $'gsudo\t--\tpacman\t-Syu\t--noconfirm' "$CASE_CALLS") == 1 ]] || \
  fail 'matching repo with missing database did not perform one exact full refresh'

prepare_case matching-verifier-needs-refresh
prepare_matching_without_database
run_stage "$test_root/matching-verifier-needs-refresh.out" archlinuxcn-bootstrap verify \
  "$stage_effects_bootstrap" repository-tools repository-tools
((RUN_STATUS == 1)) || fail "matching verifier missing database exit was $RUN_STATUS instead of 1"
grep -Fq 'metadata refresh required' "$test_root/matching-verifier-needs-refresh.out" || \
  fail 'matching verifier hid the refresh-required classification'
[[ $(count_call $'gsudo\t') == 0 ]] || fail 'matching verifier performed a refresh or other root action'

# Full refresh and post-refresh metadata failures retain their exact exits and
# leave the bootstrap stage failed, so package installation cannot begin.
prepare_case refresh-failure
printf '67\n' >"$CASE_STATE/syu-fail"
run_stage "$test_root/refresh-failure.out" archlinuxcn-bootstrap execute \
  "$stage_effects_bootstrap" repository-tools repository-tools
((RUN_STATUS == 67)) || fail "full refresh failure exit was $RUN_STATUS instead of 67"
[[ $(grep -Fxc $'gsudo\t--\tpacman\t-Syu\t--noconfirm' "$CASE_CALLS") == 1 ]] || \
  fail 'refresh failure did not use the exact full-refresh argv'

prepare_case post-refresh-metadata-failure
printf '46\n' >"$CASE_STATE/fail-Si-archlinuxcn-keyring"
run_stage "$test_root/post-refresh-metadata-failure.out" archlinuxcn-bootstrap execute \
  "$stage_effects_bootstrap" repository-tools repository-tools
((RUN_STATUS == 46)) || fail "post-refresh metadata failure exit was $RUN_STATUS instead of 46"

prepare_case post-refresh-metadata-empty
: >"$CASE_STATE/empty-Si-archlinuxcn-keyring"
run_stage "$test_root/post-refresh-metadata-empty.out" archlinuxcn-bootstrap execute \
  "$stage_effects_bootstrap" repository-tools repository-tools
((RUN_STATUS == 1)) || fail "empty post-refresh metadata exit was $RUN_STATUS instead of 1"
grep -Fq 'returned an empty result' "$test_root/post-refresh-metadata-empty.out" || \
  fail 'empty post-refresh metadata was confused with failed query'

# Planner conflict and unavailable classifications are distinct and block all effects.
prepare_case planner-conflict
printf 'conflict\n' >"$CASE_STATE/repo-mode"
: >"$CASE_STATE/keyring-installed"
run_stage "$test_root/planner-conflict.out" archlinuxcn-bootstrap execute \
  "$stage_effects_bootstrap" repository-tools repository-tools
((RUN_STATUS == 1)) || fail "planner conflict exited $RUN_STATUS instead of 1"
[[ $(count_call $'curl\t') == 0 && $(count_call $'gsudo\t') == 0 ]] || fail 'planner conflict reached network/root'
grep -Fq 'classification=conflict' "$test_root/planner-conflict.out" || fail 'planner conflict classification was hidden'

prepare_case planner-unavailable
printf 'unavailable\n' >"$CASE_STATE/repo-mode"
run_stage "$test_root/planner-unavailable.out" archlinuxcn-bootstrap execute \
  "$stage_effects_bootstrap" repository-tools repository-tools
((RUN_STATUS == 2)) || fail "planner unavailable exited $RUN_STATUS instead of 2"
[[ $(count_call $'curl\t') == 0 && $(count_call $'gsudo\t') == 0 ]] || fail 'unavailable planner query reached network/root'
grep -Fq 'classification=unavailable' "$test_root/planner-unavailable.out" || fail 'planner unavailable classification was hidden'

# Package/signature hash drift and signer drift all stop before gsudo.
prepare_case package-hash-drift
bad_package="$test_root/bad-package"
printf 'drifted package\n' >"$bad_package"
MOCK_ORIGINAL_PACKAGE=$package_asset
package_asset=$bad_package
run_stage "$test_root/package-hash-drift.out" archlinuxcn-bootstrap execute \
  "$stage_effects_bootstrap" repository-tools repository-tools
package_asset=$MOCK_ORIGINAL_PACKAGE
((RUN_STATUS == 1)) || fail "package hash drift exited $RUN_STATUS"
grep -Fq 'package SHA-256 mismatch' "$test_root/package-hash-drift.out" || fail 'package hash drift was not explained'
[[ $(count_call $'gpg\t') == 0 && $(count_call $'gsudo\t') == 0 ]] || fail 'package hash drift reached GPG/root'

prepare_case signature-hash-drift
bad_signature="$test_root/bad-signature"
printf 'drifted signature\n' >"$bad_signature"
MOCK_ORIGINAL_SIGNATURE=$signature_asset
signature_asset=$bad_signature
run_stage "$test_root/signature-hash-drift.out" archlinuxcn-bootstrap execute \
  "$stage_effects_bootstrap" repository-tools repository-tools
signature_asset=$MOCK_ORIGINAL_SIGNATURE
((RUN_STATUS == 1)) || fail "signature hash drift exited $RUN_STATUS"
grep -Fq 'signature SHA-256 mismatch' "$test_root/signature-hash-drift.out" || fail 'signature hash drift was not explained'
[[ $(count_call $'gpg\t') == 0 && $(count_call $'gsudo\t') == 0 ]] || fail 'signature hash drift reached GPG/root'

prepare_case signer-drift
printf 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB\n' >"$CASE_STATE/gpg-signer"
run_stage "$test_root/signer-drift.out" archlinuxcn-bootstrap execute \
  "$stage_effects_bootstrap" repository-tools repository-tools
((RUN_STATUS == 1)) || fail "signer drift exited $RUN_STATUS"
grep -Fq 'primary signer fingerprint mismatch' "$test_root/signer-drift.out" || fail 'signer drift was not explained'
[[ $(count_call $'gsudo\t') == 0 ]] || fail 'signer drift reached root'

# External failures preserve exact status; no direct sudo fallback is ever attempted.
prepare_case curl-failure
printf '41\n' >"$CASE_STATE/curl-fail"
run_stage "$test_root/curl-failure.out" archlinuxcn-bootstrap execute \
  "$stage_effects_bootstrap" repository-tools repository-tools
((RUN_STATUS == 41)) || fail "curl failure exit was $RUN_STATUS instead of 41"

prepare_case gsudo-failure
printf '63\n' >"$CASE_STATE/gsudo-fail"
run_stage "$test_root/gsudo-failure.out" archlinuxcn-bootstrap execute \
  "$stage_effects_bootstrap" repository-tools repository-tools
((RUN_STATUS == 63)) || fail "gsudo failure exit was $RUN_STATUS instead of 63"
! grep -Fq 'sudo-called' "$CASE_CALLS" || fail 'gsudo failure fell back to sudo'

prepare_case missing-gsudo
rm -f -- "$CASE_HOME/scripts/desktop/gsudo"
run_stage "$test_root/missing-gsudo.out" archlinuxcn-bootstrap execute \
  "$stage_effects_bootstrap" repository-tools repository-tools
((RUN_STATUS != 0)) || fail 'missing gsudo was accepted'
[[ $(count_call $'curl\t') == 0 ]] || fail 'missing gsudo reached network'
! grep -Fq 'sudo-called' "$CASE_CALLS" || fail 'missing gsudo fell back to sudo'

# Verify and idempotent execute are still production adapter actions, not global
# preflight. They must require the installed reviewed pair even when repository
# and keyring state already match, and must fail before private adapter state.
prepare_case verify-clean-home
prepare_matching
rm -f -- "$CASE_HOME/scripts/desktop/gsudo" "$CASE_HOME/scripts/desktop/fuzzel-askpass"
run_stage "$test_root/verify-clean-home.out" archlinuxcn-bootstrap verify \
  "$stage_effects_bootstrap" repository-tools repository-tools
((RUN_STATUS != 0)) || fail 'bootstrap verify accepted absent installed privilege payloads'
[[ ! -e "$CASE_HOME/state/my-archlinux-setup/archlinuxcn-apply" ]] || fail 'failed verify wrote adapter state'

prepare_case idempotent-execute-clean-home
prepare_matching
rm -f -- "$CASE_HOME/scripts/desktop/gsudo" "$CASE_HOME/scripts/desktop/fuzzel-askpass"
run_stage "$test_root/idempotent-execute-clean-home.out" archlinuxcn-bootstrap execute \
  "$stage_effects_bootstrap" repository-tools repository-tools
((RUN_STATUS != 0)) || fail 'idempotent bootstrap execute accepted absent installed privilege payloads'
[[ ! -e "$CASE_HOME/state/my-archlinux-setup/archlinuxcn-apply" ]] || fail 'failed idempotent execute wrote adapter state'
! grep -Fq 'sudo-called' "$CASE_CALLS" || fail 'strict non-preflight wrapper check fell back to sudo'

prepare_case missing-helper
rm -f -- "$CASE_HOME/scripts/desktop/fuzzel-askpass"
run_stage "$test_root/missing-helper.out" archlinuxcn-bootstrap execute \
  "$stage_effects_bootstrap" repository-tools repository-tools
((RUN_STATUS != 0)) || fail 'missing askpass helper was accepted'
[[ $(count_call $'curl\t') == 0 ]] || fail 'missing askpass helper reached network'
! grep -Fq 'sudo-called' "$CASE_CALLS" || fail 'missing askpass helper fell back to sudo'

# Packages are blocked when matching configuration has no queryable archlinuxcn DB;
# this stage never tries a partial or full refresh on its own.
prepare_case packages-database-missing
prepare_matching_without_database
run_stage "$test_root/packages-database-missing.out" archlinuxcn-packages execute \
  "$stage_effects_packages" repository-tools,development-toolchain repository-tools,development-toolchain
((RUN_STATUS == 1)) || fail "packages missing-database exit was $RUN_STATUS instead of 1"
grep -Fq 'metadata refresh required' "$test_root/packages-database-missing.out" || \
  fail 'packages stage hid missing database/refresh requirement'
[[ $(count_call $'gsudo\t') == 0 ]] || fail 'packages stage attempted root action without queryable metadata'

# Packages stage validates exact effects against policy/modules, confirms trust,
# preflights repository ownership, and passes one exact array to pacman -S.
prepare_case packages-success
prepare_matching
run_stage "$test_root/packages-success.out" archlinuxcn-packages execute \
  "$stage_effects_packages" repository-tools,development-toolchain repository-tools,development-toolchain
((RUN_STATUS == 0)) || { cat "$test_root/packages-success.out" >&2; fail "packages execute exited $RUN_STATUS"; }
grep -Fqx $'gsudo\t--\tpacman\t-S\t--needed\t--noconfirm\t--\tcc-switch\tdowngrade' "$CASE_CALLS" || \
  fail 'packages stage root argv was not one exact reviewed array'
! grep -Eq -- $'(^|\t)-Sy($|\t)' "$CASE_CALLS" || fail 'packages stage used forbidden partial refresh -Sy'
(( $(grep -c $'^pacman\t-Si\t--\tcc-switch$' "$CASE_CALLS") >= 2 )) || fail 'cc-switch was not preflighted and verified through -Si'
(( $(grep -c $'^pacman\t-Q\t--\tcc-switch$' "$CASE_CALLS") >= 1 )) || fail 'cc-switch installed state was not verified through -Q'
gsudo_after_packages=$(count_call $'gsudo\t')
run_stage "$test_root/packages-verify.out" archlinuxcn-packages verify \
  "$stage_effects_packages" repository-tools,development-toolchain repository-tools,development-toolchain
((RUN_STATUS == 0)) || { cat "$test_root/packages-verify.out" >&2; fail "packages verify exited $RUN_STATUS"; }
[[ $(count_call $'gsudo\t') == "$gsudo_after_packages" ]] || fail 'packages verify invoked root'

# A package-stage gsudo failure preserves its exact status and never falls back.
prepare_case packages-gsudo-failure
prepare_matching
printf '68\n' >"$CASE_STATE/gsudo-fail"
run_stage "$test_root/packages-gsudo-failure.out" archlinuxcn-packages execute \
  "$stage_effects_packages" repository-tools,development-toolchain repository-tools,development-toolchain
((RUN_STATUS == 68)) || fail "packages gsudo failure exit was $RUN_STATUS instead of 68"
grep -Fqx $'gsudo\t--\tpacman\t-S\t--needed\t--noconfirm\t--\tcc-switch\tdowngrade' "$CASE_CALLS" || \
  fail 'packages gsudo failure did not retain exact argv evidence'
! grep -Fq 'sudo-called' "$CASE_CALLS" || fail 'packages gsudo failure fell back to sudo'

# Undeclared, wrong-policy, duplicate, and module-mismatched effects are rejected
# before package/repository commands.
prepare_case invalid-effect
prepare_matching
invalid_effect='[{"detail":"package=not-declared channel=pacman repository=archlinuxcn acquisition=pacman","id":"install:not-declared","module":"repository-tools"}]'
run_stage "$test_root/invalid-effect.out" archlinuxcn-packages execute \
  "$invalid_effect" repository-tools repository-tools
((RUN_STATUS != 0)) || fail 'undeclared package effect was accepted'
[[ $(count_call $'pacman\t') == 0 && $(count_call $'gsudo\t') == 0 ]] || fail 'undeclared effect reached package/root commands'

prepare_case wrong-policy-effect
prepare_matching
wrong_policy='[{"detail":"package=archlinuxcn-keyring channel=pacman repository=archlinuxcn acquisition=archlinuxcn-bootstrap repository-config=fixed-include-fragment refresh=conditional-full-system-and-repository","id":"install:archlinuxcn-keyring","module":"repository-tools"}]'
run_stage "$test_root/wrong-policy-effect.out" archlinuxcn-packages execute \
  "$wrong_policy" repository-tools repository-tools
((RUN_STATUS != 0)) || fail 'bootstrap policy row entered packages stage'
[[ $(count_call $'pacman\t') == 0 && $(count_call $'gsudo\t') == 0 ]] || fail 'wrong-policy effect reached package/root commands'

prepare_case module-mismatch
prepare_matching
run_stage "$test_root/module-mismatch.out" archlinuxcn-packages execute \
  "$stage_effects_packages" repository-tools repository-tools
((RUN_STATUS != 0)) || fail 'effect for an unselected module was accepted'
[[ $(count_call $'pacman\t') == 0 && $(count_call $'gsudo\t') == 0 ]] || fail 'module mismatch reached package/root commands'

prepare_case duplicate-effect
prepare_matching
duplicate_effect="[${stage_effects_packages:1:-1},${stage_effects_packages:1:-1}]"
run_stage "$test_root/duplicate-effect.out" archlinuxcn-packages execute \
  "$duplicate_effect" repository-tools,development-toolchain repository-tools,development-toolchain
((RUN_STATUS != 0)) || fail 'duplicate effects were accepted'
[[ $(count_call $'pacman\t') == 0 && $(count_call $'gsudo\t') == 0 ]] || fail 'duplicate effects reached package/root commands'

# Repository metadata and installed-package queries preserve failed-query status;
# successful empty results and wrong repository are different explicit failures.
prepare_case si-query-failure
prepare_matching
printf '44\n' >"$CASE_STATE/fail-Si-cc-switch"
run_stage "$test_root/si-query-failure.out" archlinuxcn-packages execute \
  "$stage_effects_packages" repository-tools,development-toolchain repository-tools,development-toolchain
((RUN_STATUS == 44)) || fail "-Si query failure exit was $RUN_STATUS instead of 44"
[[ $(count_call $'gsudo\t') == 0 ]] || fail '-Si query failure reached root'

prepare_case si-empty
prepare_matching
: >"$CASE_STATE/empty-Si-cc-switch"
run_stage "$test_root/si-empty.out" archlinuxcn-packages execute \
  "$stage_effects_packages" repository-tools,development-toolchain repository-tools,development-toolchain
((RUN_STATUS == 1)) || fail "empty successful -Si exit was $RUN_STATUS instead of 1"
grep -Fq 'returned an empty result' "$test_root/si-empty.out" || fail 'empty -Si result was not distinguished from query failure'

prepare_case repository-drift
prepare_matching
printf 'extra\n' >"$CASE_STATE/repo-Si-cc-switch"
run_stage "$test_root/repository-drift.out" archlinuxcn-packages execute \
  "$stage_effects_packages" repository-tools,development-toolchain repository-tools,development-toolchain
((RUN_STATUS == 1)) || fail "repository drift exit was $RUN_STATUS instead of 1"
[[ $(count_call $'gsudo\t') == 0 ]] || fail 'repository drift reached root'

prepare_case q-query-failure
prepare_matching
: >"$CASE_STATE/installed-cc-switch"
: >"$CASE_STATE/installed-downgrade"
printf '45\n' >"$CASE_STATE/fail-Q-cc-switch"
run_stage "$test_root/q-query-failure.out" archlinuxcn-packages verify \
  "$stage_effects_packages" repository-tools,development-toolchain repository-tools,development-toolchain
((RUN_STATUS == 45)) || fail "-Q query failure exit was $RUN_STATUS instead of 45"

prepare_case q-empty
prepare_matching
: >"$CASE_STATE/installed-cc-switch"
: >"$CASE_STATE/installed-downgrade"
: >"$CASE_STATE/empty-Q-cc-switch"
run_stage "$test_root/q-empty.out" archlinuxcn-packages verify \
  "$stage_effects_packages" repository-tools,development-toolchain repository-tools,development-toolchain
((RUN_STATUS == 1)) || fail "empty successful -Q exit was $RUN_STATUS instead of 1"
grep -Fq 'returned an empty result' "$test_root/q-empty.out" || fail 'empty -Q result was not distinguished from query failure'

# Hidden root-helper accepts only the explicit isolated test root and fixed targets.
# Symlink/hardlink targets fail without touching the outside inode.
prepare_case root-helper-symlink
outside="$test_root/outside-pacman.conf"
printf 'outside-unchanged\n' >"$outside"
rm -f -- "$CASE_ROOT/etc/pacman.conf"
ln -s -- "$outside" "$CASE_ROOT/etc/pacman.conf"
set +e
HOME="$CASE_HOME" ARCHLINUXCN_APPLY_TESTING=1 ARCHLINUXCN_APPLY_TEST_ROOT="$CASE_ROOT" \
  python3 "$tool" --root-helper --target-root "$CASE_ROOT" \
  --expected-pacman-conf-sha256 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  --expected-fragment-state absent >"$test_root/root-helper-symlink.out" 2>&1
root_symlink_status=$?
set -e
((root_symlink_status != 0)) || fail 'root helper accepted symlinked pacman.conf'
[[ $(<"$outside") == outside-unchanged ]] || fail 'root helper followed symlink outside target root'

prepare_case root-helper-preserve
printf 'old fragment\n' >"$CASE_ROOT/etc/pacman.d/my-archlinux-setup-archlinuxcn.conf"
chmod 600 "$CASE_ROOT/etc/pacman.d/my-archlinux-setup-archlinuxcn.conf"
preserve_conf_sha=$(sha256sum "$CASE_ROOT/etc/pacman.conf" | awk '{print $1}')
preserve_fragment_sha=$(sha256sum "$CASE_ROOT/etc/pacman.d/my-archlinux-setup-archlinuxcn.conf" | awk '{print $1}')
HOME="$CASE_HOME" ARCHLINUXCN_APPLY_TESTING=1 ARCHLINUXCN_APPLY_TEST_ROOT="$CASE_ROOT" \
  python3 "$tool" --root-helper --target-root "$CASE_ROOT" \
  --expected-pacman-conf-sha256 "$preserve_conf_sha" \
  --expected-fragment-state "sha256:$preserve_fragment_sha" \
  >"$test_root/root-helper-preserve.out" 2>&1 || fail 'root helper could not replace a backed-up fixed fragment'
cmp -s -- "$fixture/config/templates/archlinuxcn.conf" \
  "$CASE_ROOT/etc/pacman.d/my-archlinux-setup-archlinuxcn.conf" || fail 'root helper preserve case wrote wrong fragment'
[[ $(stat -c '%a' "$CASE_ROOT/etc/pacman.d/my-archlinux-setup-archlinuxcn.conf") == 600 ]] || \
  fail 'root helper did not preserve existing fragment mode'
[[ $(stat -c '%a' "$CASE_ROOT/etc/pacman.conf") == 640 ]] || fail 'root helper preserve case changed pacman.conf mode'
[[ $(grep -Fxc 'Include = /etc/pacman.d/my-archlinux-setup-archlinuxcn.conf' "$CASE_ROOT/etc/pacman.conf") == 1 ]] || \
  fail 'root helper preserve case did not add exactly one Include'
# Direct root-helper rerun with exact current fingerprints is idempotent.
preserve_conf_sha=$(sha256sum "$CASE_ROOT/etc/pacman.conf" | awk '{print $1}')
preserve_fragment_sha=$(sha256sum "$CASE_ROOT/etc/pacman.d/my-archlinux-setup-archlinuxcn.conf" | awk '{print $1}')
HOME="$CASE_HOME" ARCHLINUXCN_APPLY_TESTING=1 ARCHLINUXCN_APPLY_TEST_ROOT="$CASE_ROOT" \
  python3 "$tool" --root-helper --target-root "$CASE_ROOT" \
  --expected-pacman-conf-sha256 "$preserve_conf_sha" \
  --expected-fragment-state "sha256:$preserve_fragment_sha" \
  >"$test_root/root-helper-preserve-rerun.out" 2>&1 || fail 'root helper idempotent rerun failed'
[[ $(grep -Fxc 'Include = /etc/pacman.d/my-archlinux-setup-archlinuxcn.conf' "$CASE_ROOT/etc/pacman.conf") == 1 ]] || \
  fail 'root helper idempotent rerun duplicated Include'

prepare_case root-helper-hardlink
outside_hard="$test_root/outside-hardlink.conf"
printf '[options]\n' >"$outside_hard"
rm -f -- "$CASE_ROOT/etc/pacman.conf"
ln -- "$outside_hard" "$CASE_ROOT/etc/pacman.conf"
hard_sha=$(sha256sum "$CASE_ROOT/etc/pacman.conf" | awk '{print $1}')
set +e
HOME="$CASE_HOME" ARCHLINUXCN_APPLY_TESTING=1 ARCHLINUXCN_APPLY_TEST_ROOT="$CASE_ROOT" \
  python3 "$tool" --root-helper --target-root "$CASE_ROOT" \
  --expected-pacman-conf-sha256 "$hard_sha" --expected-fragment-state absent \
  >"$test_root/root-helper-hardlink.out" 2>&1
root_hardlink_status=$?
set -e
((root_hardlink_status != 0)) || fail 'root helper accepted hard-linked pacman.conf'
[[ $(stat -c '%h' "$outside_hard") == 2 ]] || fail 'root helper altered hardlink evidence'

set +e
ARCHLINUXCN_APPLY_TESTING=1 ARCHLINUXCN_APPLY_TEST_ROOT="$CASE_ROOT" \
  python3 "$tool" --root-helper --target-root / \
  --expected-pacman-conf-sha256 "$hard_sha" --expected-fragment-state absent \
  >"$test_root/root-helper-real-root.out" 2>&1
root_real_status=$?
set -e
((root_real_status != 0)) || fail 'test mode allowed root helper to target real /'

# Regression: the privileged helper must condition both fixed-target commits on
# the exact snapshots it checked.  The audit hook lands a competing administrator
# write at the old os.replace boundary (and at the new renameat2 boundary after
# the fix).  Existing pacman.conf, existing fragment, absent fragment, and an
# otherwise byte-identical replacement inode must all fail closed without
# discarding the competing directory entry.
PYTHONDONTWRITEBYTECODE=1 python3 - "$tool" "$test_root/root-helper-final-window" <<'PY'
from __future__ import annotations

import hashlib
import importlib.util
import os
from pathlib import Path
import stat
import sys

source = Path(sys.argv[1])
cases_root = Path(sys.argv[2])
spec = importlib.util.spec_from_file_location("archlinuxcn_apply_final_window", source)
assert spec is not None and spec.loader is not None
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)

BASE_CONF = b"[options]\nArchitecture = auto\n"
OLD_FRAGMENT = b"# administrator-owned prior fragment\n"
injection: dict[str, object] = {}


def audit(event: str, args: tuple[object, ...]) -> None:
    if injection.get("done") or event not in {
        "os.rename",
        "myarch.archlinuxcn-conditional-replace",
    }:
        return
    if len(args) < 2:
        return
    target = injection.get("target")
    if target is None or Path(os.fspath(args[1])) != target:
        return
    injection["done"] = True
    target = Path(target)
    strategy = injection["strategy"]
    if strategy == "in-place":
        target.write_bytes(injection["bytes"])
        target.chmod(injection["mode"])
    elif strategy == "create":
        assert not target.exists()
        target.write_bytes(injection["bytes"])
        target.chmod(injection["mode"])
    elif strategy == "replace-same":
        replacement = target.parent / f".{target.name}.administrator-race"
        replacement.write_bytes(injection["bytes"])
        replacement.chmod(injection["mode"])
        os.replace(replacement, target)
        injection["replacement_inode"] = target.stat().st_ino
    else:
        raise AssertionError(f"unknown race strategy: {strategy}")


sys.addaudithook(audit)


def prepare(name: str, fragment: bytes | None) -> tuple[Path, Path, Path]:
    root = cases_root / name / "root"
    (root / "etc/pacman.d").mkdir(parents=True)
    root.chmod(0o700)
    conf = root / "etc/pacman.conf"
    conf.write_bytes(BASE_CONF)
    conf.chmod(0o640)
    fragment_path = root / "etc/pacman.d/my-archlinux-setup-archlinuxcn.conf"
    if fragment is not None:
        fragment_path.write_bytes(fragment)
        fragment_path.chmod(0o600)
    return root, conf, fragment_path


def invoke(root: Path, conf: Path, fragment: Path) -> module.AdapterFailure | None:
    os.environ["ARCHLINUXCN_APPLY_TESTING"] = "1"
    os.environ["ARCHLINUXCN_APPLY_TEST_ROOT"] = os.fspath(root)
    expected_fragment = (
        f"sha256:{hashlib.sha256(fragment.read_bytes()).hexdigest()}"
        if fragment.exists()
        else "absent"
    )
    try:
        module.root_helper(
            [
                "--root-helper",
                "--target-root",
                os.fspath(root),
                "--expected-pacman-conf-sha256",
                hashlib.sha256(conf.read_bytes()).hexdigest(),
                "--expected-fragment-state",
                expected_fragment,
            ]
        )
    except module.AdapterFailure as exc:
        return exc
    return None


failures: list[str] = []

# Existing pacman.conf bytes change in place at its final replace boundary.
root, conf, fragment = prepare("pacman-bytes", None)
concurrent_conf = b"[options]\n# administrator final-window edit\n"
injection.clear()
injection.update(target=conf, strategy="in-place", bytes=concurrent_conf, mode=0o620, done=False)
error = invoke(root, conf, fragment)
if not injection.get("done"):
    failures.append("pacman.conf byte-race injection did not reach the final boundary")
if error is None:
    failures.append("pacman.conf final-window byte race returned success")
if conf.read_bytes() != concurrent_conf or stat.S_IMODE(conf.stat().st_mode) != 0o620:
    failures.append("pacman.conf final-window writer bytes/mode were not preserved")

# Existing managed fragment changes at its final exchange boundary.  pacman.conf
# must remain untouched because fragment installation is ordered first.
root, conf, fragment = prepare("fragment-existing", OLD_FRAGMENT)
concurrent_fragment = b"# administrator replacement fragment\n"
injection.clear()
injection.update(target=fragment, strategy="in-place", bytes=concurrent_fragment, mode=0o640, done=False)
error = invoke(root, conf, fragment)
if not injection.get("done"):
    failures.append("existing fragment race injection did not reach the final boundary")
if error is None:
    failures.append("existing fragment final-window race returned success")
if fragment.read_bytes() != concurrent_fragment or stat.S_IMODE(fragment.stat().st_mode) != 0o640:
    failures.append("existing fragment final-window writer was not preserved")
if conf.read_bytes() != BASE_CONF:
    failures.append("pacman.conf changed after the existing-fragment race failed")

# An administrator creates the previously absent managed path at the exact
# create boundary.  RENAME_NOREPLACE must preserve it and reject the helper.
root, conf, fragment = prepare("fragment-absent", None)
created_fragment = b"# administrator created fragment\n"
injection.clear()
injection.update(target=fragment, strategy="create", bytes=created_fragment, mode=0o600, done=False)
error = invoke(root, conf, fragment)
if not injection.get("done"):
    failures.append("absent fragment race injection did not reach the final boundary")
if error is None:
    failures.append("absent fragment final-window creation returned success")
if fragment.read_bytes() != created_fragment:
    failures.append("concurrently created fragment was overwritten")
if conf.read_bytes() != BASE_CONF:
    failures.append("pacman.conf changed after the absent-fragment race failed")

# Equal bytes and metadata are not enough: an atomic editor save changes the
# directory-entry inode.  The displaced dev/inode identity must make this fail.
root, conf, fragment = prepare("pacman-inode", None)
reviewed_inode = conf.stat().st_ino
injection.clear()
injection.update(target=conf, strategy="replace-same", bytes=BASE_CONF, mode=0o640, done=False)
error = invoke(root, conf, fragment)
replacement_inode = injection.get("replacement_inode")
if not injection.get("done") or not isinstance(replacement_inode, int):
    failures.append("pacman.conf inode-race injection did not reach the final boundary")
elif replacement_inode == reviewed_inode:
    failures.append("pacman.conf inode-race fixture did not replace the inode")
if error is None:
    failures.append("byte-identical pacman.conf replacement inode returned success")
if conf.read_bytes() != BASE_CONF or conf.stat().st_ino != replacement_inode:
    failures.append("byte-identical administrator replacement inode was not restored")

# Adjacent rollback boundary: a second administrator writer can replace the
# newly installed inode after the first exchange detects drift but before the
# rollback exchange.  The first writer must return to the target and the second
# must survive at the reported recovery path.
root, conf, fragment = prepare("pacman-double-race", None)
context = module.ExecutionContext(True, root)
prior = module.inspect_target(context, module.PACMAN_CONF_RELATIVE, "pacman.conf", allow_missing=False)
first_writer = b"# first administrator writer\n"
second_writer = b"# second administrator writer\n"
real_renameat2 = module.renameat2
exchange_calls = 0


def double_raced_rename(path_from: Path, path_to: Path, flags: int, *, phase: str) -> None:
    global exchange_calls
    if Path(path_to) != conf or flags != module.RENAME_EXCHANGE:
        return real_renameat2(path_from, path_to, flags, phase=phase)
    exchange_calls += 1
    if exchange_calls == 1:
        conf.write_bytes(first_writer)
        conf.chmod(0o620)
        return real_renameat2(path_from, path_to, flags, phase=phase)
    if exchange_calls == 2:
        replacement = conf.parent / ".pacman.conf.second-administrator"
        replacement.write_bytes(second_writer)
        replacement.chmod(0o600)
        os.replace(replacement, conf)
        return real_renameat2(path_from, path_to, flags, phase=phase)
    raise AssertionError("unexpected third exchange")


module.renameat2 = double_raced_rename
double_error = None
try:
    module.atomic_replace_target(conf, module.build_pacman_conf(BASE_CONF), prior)
except module.AdapterFailure as exc:
    double_error = exc
finally:
    module.renameat2 = real_renameat2
if exchange_calls != 2 or double_error is None:
    failures.append("double-writer rollback boundary was not rejected")
else:
    recovery = getattr(double_error, "recovery_path", None)
    if not getattr(double_error, "preserve_temporary", False) or not isinstance(recovery, Path):
        failures.append("double-writer rollback did not report a retained recovery path")
    elif not recovery.exists() or recovery.read_bytes() != second_writer:
        failures.append("second administrator writer was not retained at the recovery path")
    if conf.read_bytes() != first_writer or stat.S_IMODE(conf.stat().st_mode) != 0o620:
        failures.append("first administrator writer was not restored after the second race")

# If the rollback exchange itself fails, retain the displaced competing file at
# the recovery path and the installer proposal at the fixed target.  Never
# convert an unavailable rollback into success or unlink either side.
root, conf, fragment = prepare("pacman-rollback-failure", None)
context = module.ExecutionContext(True, root)
prior = module.inspect_target(context, module.PACMAN_CONF_RELATIVE, "pacman.conf", allow_missing=False)
rollback_writer = b"# administrator writer before failed rollback\n"
exchange_calls = 0


def failed_rollback_rename(path_from: Path, path_to: Path, flags: int, *, phase: str) -> None:
    global exchange_calls
    if Path(path_to) != conf or flags != module.RENAME_EXCHANGE:
        return real_renameat2(path_from, path_to, flags, phase=phase)
    exchange_calls += 1
    if exchange_calls == 1:
        conf.write_bytes(rollback_writer)
        conf.chmod(0o600)
        return real_renameat2(path_from, path_to, flags, phase=phase)
    raise OSError(5, "injected rollback exchange failure")


module.renameat2 = failed_rollback_rename
rollback_error = None
proposed_conf = module.build_pacman_conf(BASE_CONF)
try:
    module.atomic_replace_target(conf, proposed_conf, prior)
except module.AdapterFailure as exc:
    rollback_error = exc
finally:
    module.renameat2 = real_renameat2
if exchange_calls != 2 or rollback_error is None:
    failures.append("rollback-exchange failure was not reported")
else:
    recovery = getattr(rollback_error, "recovery_path", None)
    if not getattr(rollback_error, "preserve_temporary", False) or not isinstance(recovery, Path):
        failures.append("rollback-exchange failure omitted its recovery path")
    elif not recovery.exists() or recovery.read_bytes() != rollback_writer:
        failures.append("rollback-exchange failure lost the competing administrator bytes")
    if conf.read_bytes() != proposed_conf:
        failures.append("rollback-exchange failure lost the installed proposal side")

if failures:
    raise AssertionError("; ".join(failures))
PY

# The test switch is valid only as an explicit pair with a non-/ isolated root.
prepare_case incomplete-test-mode
set +e
HOME="$CASE_HOME" XDG_STATE_HOME="$CASE_HOME/state" PATH="$mock_bin:/usr/bin" \
  ARCHLINUXCN_APPLY_TESTING=1 \
  FULL_ORCHESTRATOR_ACTION=verify FULL_ORCHESTRATOR_STAGE=archlinuxcn-bootstrap \
  FULL_ORCHESTRATOR_PROFILE=test FULL_ORCHESTRATOR_MODULES=repository-tools \
  FULL_ORCHESTRATOR_STAGE_MODULES=repository-tools FULL_ORCHESTRATOR_EFFECTS_JSON="$stage_effects_bootstrap" \
  FULL_ORCHESTRATOR_PLAN_FINGERPRINT=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  FULL_ORCHESTRATOR_RUN_ID=20260801T000000Z-deadbeef0001 FULL_ORCHESTRATOR_ATTEMPT=1 \
  python3 "$tool" >"$test_root/incomplete-test-mode.out" 2>&1
incomplete_test_status=$?
set -e
((incomplete_test_status != 0)) || fail 'incomplete test-mode environment weakened production defaults'

printf 'archlinuxcn production adapter checks passed.\n'
