#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT

fail() {
  printf 'preflight test failed: %s\n' "$*" >&2
  exit 1
}

plan_home="$test_root/plan-home"
mkdir -p "$plan_home"
HOME="$plan_home" XDG_STATE_HOME="$plan_home/.local/state" \
  "$root/installer/install.sh" --profile vm --plan >"$test_root/plan.out"
[[ ! -e "$plan_home/.local/state/my-archlinux-setup" ]] || fail "--plan wrote installer state"
grep -Fq 'filesystem writes: none' "$test_root/plan.out" || fail "--plan did not disclose zero writes"

run_failed_query_case() {
  local name="$1" command_name="$2" command_body="$3" expected_status="$4" expected_message="$5"
  local mock_bin="$test_root/$name-bin" case_home="$test_root/$name-home"
  mkdir -p "$mock_bin" "$case_home"
  printf '%s\n' '#!/usr/bin/env bash' "$command_body" >"$mock_bin/$command_name"
  chmod 755 "$mock_bin/$command_name"
  set +e
  HOME="$case_home" XDG_STATE_HOME="$case_home/.local/state" PATH="$mock_bin:$PATH" \
    "$root/installer/install.sh" --profile vm --plan >"$test_root/$name.out" 2>&1
  local status=$?
  set -e
  ((status == expected_status)) || fail "$name status was not preserved (got $status)"
  grep -Fq "$expected_message" "$test_root/$name.out" || fail "$name failure was not explained"
  [[ ! -e "$case_home/.local/state/my-archlinux-setup" ]] || fail "$name wrote installer state"
}

run_failed_query_case id-failure id 'exit 45' 45 'id -u failed with exit 45'
run_failed_query_case uname-failure uname 'exit 46' 46 'uname -m failed with exit 46'
run_failed_query_case unsupported-architecture uname 'printf aarch64\\n' 1 'unsupported architecture: aarch64'

set +e
HOME=relative-home XDG_STATE_HOME="$test_root/relative-state" \
  "$root/installer/install.sh" --profile vm --plan >"$test_root/relative-home.out" 2>&1
relative_status=$?
set -e
((relative_status != 0)) || fail "relative HOME was accepted"
grep -Fq 'HOME must be an absolute path' "$test_root/relative-home.out" || fail "relative HOME failure was not explained"
[[ ! -e "$test_root/relative-state/my-archlinux-setup" ]] || fail "relative HOME case wrote installer state"

printf 'Preflight checks passed.\n'
