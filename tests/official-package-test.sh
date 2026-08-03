#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
vm_modules="desktop-shared,wm-niri"
test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT
export MY_ARCH_SETUP_LEGACY_COMPONENT_TESTING=1 MY_ARCH_SETUP_LEGACY_TEST_ROOT="$test_root"
mock_bin="$test_root/mock-bin"
mkdir -p "$mock_bin"

cat >"$mock_bin/pacman" <<'MOCK'
#!/usr/bin/env bash
set -u
printf 'pacman' >>"$MOCK_CALL_LOG"
printf '\t%s' "$@" >>"$MOCK_CALL_LOG"
printf '\n' >>"$MOCK_CALL_LOG"
case "${1:-}" in
  -Si)
    package="${@: -1}"
    if [[ "$package" == "${MOCK_UNAVAILABLE_PACKAGE:-}" ]]; then
      exit "${MOCK_PACMAN_SI_STATUS:-23}"
    fi
    ;;
  -Q)
    if [[ -n "${MOCK_QUERY_STATUS:-}" ]]; then
      exit "$MOCK_QUERY_STATUS"
    fi
    if [[ "${MOCK_EMPTY_QUERY:-}" == true ]]; then
      exit 0
    fi
    shift
    for package in "$@"; do
      printf '%s 1.0-1\n' "$package"
    done
    ;;
  *)
    printf 'unexpected direct pacman call\n' >&2
    exit 97
    ;;
esac
MOCK

cat >"$mock_bin/sudo" <<'MOCK'
#!/usr/bin/env bash
set -u
printf 'sudo' >>"$MOCK_CALL_LOG"
printf '\t%s' "$@" >>"$MOCK_CALL_LOG"
printf '\n' >>"$MOCK_CALL_LOG"
[[ -z "${MOCK_SUDO_OUTPUT:-}" ]] || printf '%s\n' "$MOCK_SUDO_OUTPUT"
if [[ -n "${MOCK_SUDO_FAIL_MATCH:-}" && "$*" == *"$MOCK_SUDO_FAIL_MATCH"* ]]; then
  exit "${MOCK_SUDO_STATUS:-29}"
fi
MOCK

cat >"$mock_bin/getent" <<'MOCK'
#!/usr/bin/env bash
set -u
printf 'getent' >>"$MOCK_CALL_LOG"
printf '\t%s' "$@" >>"$MOCK_CALL_LOG"
printf '\n' >>"$MOCK_CALL_LOG"
if [[ -n "${MOCK_GETENT_STATUS:-}" ]]; then
  exit "$MOCK_GETENT_STATUS"
fi
printf '203.0.113.1 STREAM archlinux.org\n'
MOCK

cat >"$mock_bin/systemctl" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
chmod 755 "$mock_bin"/*

fail() {
  printf 'official package test failed: %s\n' "$*" >&2
  exit 1
}

run_case() {
  local name="$1" confirmation="$2"
  shift 2
  local case_root="$test_root/$name"
  mkdir -p "$case_root/home"
  : >"$case_root/calls"
  set +e
  printf '%s\n' "$confirmation" | env \
    HOME="$case_root/home" \
    XDG_STATE_HOME="$case_root/home/.local/state" \
    PATH="$mock_bin:$PATH" \
    MOCK_CALL_LOG="$case_root/calls" \
    "$@" \
    "$root/installer/install.sh" --profile vm --modules "$vm_modules" --apply-official \
    >"$case_root/output" 2>&1
  CASE_STATUS=$?
  set -e
  CASE_ROOT="$case_root"
}

run_case success apply-system-changes env MOCK_SUDO_OUTPUT=mock-transaction-output
((CASE_STATUS == 0)) || fail "successful apply exited with $CASE_STATUS"
expected_packages=$(awk -F '\t' '$1 == "vm" { printf "%s%s", separator, $3; separator="\t" }' "$root/manifests/official-packages.tsv")
grep -Fqx $'sudo\tpacman\t-Syu' "$CASE_ROOT/calls" || fail "missing full system upgrade call"
grep -Fqx $'sudo\tpacman\t-S\t--needed\t'"$expected_packages" "$CASE_ROOT/calls" || fail "official packages were not passed as one explicit array"
expected_package_count=$(awk -F '\t' '$1 == "vm" { count++ } END { print count+0 }' "$root/manifests/official-packages.tsv")
[[ $(grep -c $'^pacman\t-Si\t--\t' "$CASE_ROOT/calls") -eq $expected_package_count ]] || fail "expected one availability query per VM package"
state="$CASE_ROOT/home/.local/state/my-archlinux-setup/official-package-state"
[[ -f "$state" ]] || fail "successful apply did not write package state"
[[ $(stat -c '%a' "$state") == 600 ]] || fail "package state is not mode 600"
[[ $(stat -c '%a' "$CASE_ROOT/home/.local/state/my-archlinux-setup") == 700 ]] || fail "package project state is not mode 700"
[[ $(stat -c '%a' "$CASE_ROOT/home/.local/state/my-archlinux-setup/logs") == 700 ]] || fail "package log directory is not mode 700"
grep -Fq 'schema=1 profile=vm applied_at=' "$state" || fail "package state metadata is missing"
apply_log=$(find "$CASE_ROOT/home/.local/state/my-archlinux-setup/logs" -maxdepth 1 -type f -name 'official-packages-vm-*.log' -print -quit)
[[ -n "$apply_log" ]] || fail "successful apply did not retain an audit log"
[[ $(stat -c '%a' "$apply_log") == 600 ]] || fail "official apply log is not mode 600"
grep -Fq 'command: sudo pacman -Syu' "$apply_log" || fail "official apply log omitted the system update command"
grep -Fq 'mock-transaction-output' "$apply_log" || fail "official apply log omitted command output"
grep -Fq 'result: completed' "$apply_log" || fail "official apply log omitted successful completion"
while IFS=$'\t' read -r profile _module package _purpose; do
  [[ "$profile" == vm ]] || continue
  grep -Fqx "$package 1.0-1" "$state" || fail "package state omitted $package"
done <"$root/manifests/official-packages.tsv"
if grep -Fq 'configuration-only bootstrap makes no sudo calls' "$CASE_ROOT/output"; then
  fail "official apply preflight incorrectly claims no sudo calls"
fi

flag_root="$test_root/confirm-flag"
mkdir -p "$flag_root/home"
: >"$flag_root/calls"
HOME="$flag_root/home" XDG_STATE_HOME="$flag_root/home/.local/state" \
  PATH="$mock_bin:$PATH" MOCK_CALL_LOG="$flag_root/calls" \
  "$root/installer/install.sh" --profile vm --modules "$vm_modules" --apply-official --confirm-system-changes \
  </dev/null >"$flag_root/output" 2>&1
[[ -f "$flag_root/home/.local/state/my-archlinux-setup/official-package-state" ]] || fail "explicit system confirmation flag did not apply"
grep -Fq 'Confirmation supplied by --confirm-system-changes.' "$flag_root/output" || fail "system confirmation flag was not reported"

set +e
HOME="$flag_root/home" XDG_STATE_HOME="$flag_root/home/.local/state" \
  PATH="$mock_bin:$PATH" MOCK_CALL_LOG="$flag_root/calls" \
  "$root/installer/install.sh" --profile vm --plan --confirm-system-changes \
  >"$flag_root/invalid-output" 2>&1
invalid_status=$?
set -e
((invalid_status != 0)) || fail "system confirmation flag was accepted with --plan"
grep -Fq -- '--confirm-system-changes requires --apply or --apply-official' "$flag_root/invalid-output" || fail "invalid confirmation combination was not explained"

state_link_root="$test_root/official-state-link"
mkdir -p "$state_link_root/home/.local/state/my-archlinux-setup" "$state_link_root/outside-logs"
chmod 755 "$state_link_root/outside-logs"
ln -s -- "$state_link_root/outside-logs" "$state_link_root/home/.local/state/my-archlinux-setup/logs"
: >"$state_link_root/calls"
set +e
printf 'apply-system-changes\n' | HOME="$state_link_root/home" XDG_STATE_HOME="$state_link_root/home/.local/state" \
  PATH="$mock_bin:$PATH" MOCK_CALL_LOG="$state_link_root/calls" \
  "$root/installer/install.sh" --profile vm --modules "$vm_modules" --apply-official \
  >"$state_link_root/output" 2>&1
state_link_status=$?
set -e
((state_link_status != 0)) || fail "symlinked log state directory was accepted"
[[ $(stat -c '%a' "$state_link_root/outside-logs") == 755 ]] || fail "symlinked log target mode was changed"
! grep -q $'^sudo\t' "$state_link_root/calls" || fail "symlinked log state directory reached sudo"

run_case cancelled do-not-apply env
((CASE_STATUS != 0)) || fail "cancelled apply unexpectedly succeeded"
[[ ! -e "$CASE_ROOT/home/.local/state/my-archlinux-setup" ]] || fail "cancelled apply wrote installer state"
! grep -q $'^sudo\t' "$CASE_ROOT/calls" || fail "cancelled apply invoked sudo"

run_case dns-failure apply-system-changes env MOCK_GETENT_STATUS=8
((CASE_STATUS == 8)) || fail "DNS failure status was not preserved (got $CASE_STATUS)"
grep -Fq 'getent exit 8' "$CASE_ROOT/output" || fail "DNS failure did not report query status"
[[ ! -e "$CASE_ROOT/home/.local/state/my-archlinux-setup" ]] || fail "DNS failure wrote installer state"
! grep -q $'^sudo\t' "$CASE_ROOT/calls" || fail "DNS failure invoked sudo"

run_case unavailable-package apply-system-changes env MOCK_UNAVAILABLE_PACKAGE=alacritty MOCK_PACMAN_SI_STATUS=23
((CASE_STATUS == 23)) || fail "package query failure status was not preserved (got $CASE_STATUS)"
grep -Fq 'pacman exit 23' "$CASE_ROOT/output" || fail "package query failure did not report status"
[[ ! -e "$CASE_ROOT/home/.local/state/my-archlinux-setup" ]] || fail "package query failure wrote installer state"
! grep -q $'^sudo\t' "$CASE_ROOT/calls" || fail "package query failure invoked sudo"

run_case upgrade-failure apply-system-changes env MOCK_SUDO_FAIL_MATCH='pacman -Syu' MOCK_SUDO_STATUS=29
((CASE_STATUS == 29)) || fail "upgrade failure status was not preserved (got $CASE_STATUS)"
grep -Fq 'sudo pacman -Syu failed with exit 29' "$CASE_ROOT/output" || fail "upgrade failure did not report status"
[[ ! -e "$CASE_ROOT/home/.local/state/my-archlinux-setup/official-package-state" ]] || fail "upgrade failure wrote completed package state"
failure_log=$(find "$CASE_ROOT/home/.local/state/my-archlinux-setup/logs" -maxdepth 1 -type f -name 'official-packages-vm-*.log' -print -quit)
[[ -n "$failure_log" ]] || fail "upgrade failure did not retain an audit log"
[[ $(stat -c '%a' "$failure_log") == 600 ]] || fail "failed official apply log is not mode 600"
grep -Fq 'sudo pacman -Syu failed with exit 29' "$failure_log" || fail "failed official apply log omitted the failure status"

run_case install-failure apply-system-changes env MOCK_SUDO_FAIL_MATCH='pacman -S --needed' MOCK_SUDO_STATUS=31
((CASE_STATUS == 31)) || fail "package install failure status was not preserved (got $CASE_STATUS)"
grep -Fq 'sudo pacman -S --needed failed with exit 31' "$CASE_ROOT/output" || fail "package install failure did not report status"
[[ ! -e "$CASE_ROOT/home/.local/state/my-archlinux-setup/official-package-state" ]] || fail "package install failure wrote completed package state"

run_case inventory-failure apply-system-changes env MOCK_QUERY_STATUS=37
((CASE_STATUS == 37)) || fail "inventory failure status was not preserved (got $CASE_STATUS)"
grep -Fq 'pacman -Q failed with exit 37' "$CASE_ROOT/output" || fail "inventory failure did not report status"
[[ ! -e "$CASE_ROOT/home/.local/state/my-archlinux-setup/official-package-state" ]] || fail "failed inventory left a partial package state"
state_dir="$CASE_ROOT/home/.local/state/my-archlinux-setup"
if [[ -d "$state_dir" ]] && find "$state_dir" -maxdepth 1 -type f -name '.official-package-state.*' -print -quit | grep -q .; then
  fail "failed inventory left a temporary package state"
fi

run_case empty-inventory apply-system-changes env MOCK_EMPTY_QUERY=true
((CASE_STATUS != 0)) || fail "empty inventory unexpectedly succeeded"
grep -Fq 'inventory query returned an empty result' "$CASE_ROOT/output" || fail "empty inventory was not distinguished from query failure"
[[ ! -e "$CASE_ROOT/home/.local/state/my-archlinux-setup/official-package-state" ]] || fail "empty inventory wrote completed package state"

manifest_fixture="$test_root/manifest-symlink-project"
mkdir -p "$manifest_fixture/installer" "$manifest_fixture/manifests"
cp -- "$root/installer/install.sh" "$manifest_fixture/installer/install.sh"
cp -a -- "$root/config" "$manifest_fixture/config"
cp -- "$root/manifests/config-mappings.tsv" "$manifest_fixture/manifests/config-mappings.tsv"
cp -- "$root/manifests/modules.tsv" "$manifest_fixture/manifests/modules.tsv"
cp -- "$root/manifests/profile-modules.tsv" "$manifest_fixture/manifests/profile-modules.tsv"
cp -- "$root/manifests/official-packages.tsv" "$test_root/external-official-packages.tsv"
ln -s -- "$test_root/external-official-packages.tsv" "$manifest_fixture/manifests/official-packages.tsv"
manifest_home="$test_root/manifest-symlink-home"
mkdir -p "$manifest_home"
: >"$test_root/manifest-symlink-calls"
set +e
HOME="$manifest_home" XDG_STATE_HOME="$manifest_home/.local/state" \
  PATH="$mock_bin:$PATH" MOCK_CALL_LOG="$test_root/manifest-symlink-calls" \
  "$manifest_fixture/installer/install.sh" --profile vm --plan \
  >"$test_root/manifest-symlink.out" 2>&1
manifest_status=$?
set -e
((manifest_status != 0)) || fail "symlinked official package manifest was accepted"
[[ ! -e "$manifest_home/.local/state/my-archlinux-setup" ]] || fail "symlinked package manifest plan wrote state"

run_invalid_manifest_case() {
  local name="$1" expected_status="$2" expected_message="$3" appended_row="$4"
  local project="$test_root/$name-project" case_home="$test_root/$name-home"
  mkdir -p "$project/installer" "$project/manifests" "$case_home"
  cp -- "$root/installer/install.sh" "$project/installer/install.sh"
  cp -a -- "$root/config" "$project/config"
  cp -- "$root/manifests/config-mappings.tsv" "$project/manifests/config-mappings.tsv"
  cp -- "$root/manifests/modules.tsv" "$project/manifests/modules.tsv"
  cp -- "$root/manifests/profile-modules.tsv" "$project/manifests/profile-modules.tsv"
  cp -- "$root/manifests/official-packages.tsv" "$project/manifests/official-packages.tsv"
  printf '%s\n' "$appended_row" >>"$project/manifests/official-packages.tsv"
  : >"$test_root/$name-calls"
  set +e
  HOME="$case_home" XDG_STATE_HOME="$case_home/.local/state" \
    PATH="$mock_bin:$PATH" MOCK_CALL_LOG="$test_root/$name-calls" \
    "$project/installer/install.sh" --profile vm --plan \
    >"$test_root/$name.out" 2>&1
  local status=$?
  set -e
  ((status == expected_status)) || fail "$name manifest status was not preserved (got $status)"
  grep -Fq "$expected_message" "$test_root/$name.out" || fail "$name manifest failure was not explained"
  [[ ! -e "$case_home/.local/state/my-archlinux-setup" ]] || fail "$name manifest plan wrote state"
}

run_invalid_manifest_case malformed 2 'invalid row' $'vm\tbroken-row'
run_invalid_manifest_case duplicate 4 'duplicate package' $'vm\twm-niri\tniri\tDuplicate regression row'

printf 'Official package installation checks passed.\n'
