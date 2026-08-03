#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT
home="$test_root/home";mkdir -m 700 "$home"
fail() { printf 'legacy installer gate test failed: %s\n' "$*" >&2; exit 1; }

# The legacy component remains useful for read-only compatibility plans.
HOME="$home" XDG_STATE_HOME="$test_root/plan-state" \
  "$root/installer/install.sh" --profile vm --modules desktop-shared,wm-niri --plan \
  >"$test_root/plan.out"
[[ ! -e $test_root/plan-state ]] || fail 'legacy read-only plan wrote state'

# Its sudo-based changing paths are not a production fallback. Only isolated
# regression tests may opt in with a matching private test root.
set +e
printf 'apply-config\n' | HOME="$home" XDG_STATE_HOME="$test_root/apply-state" \
  "$root/installer/install.sh" --profile vm --modules desktop-shared,wm-niri --apply-config \
  >"$test_root/apply.out" 2>&1
status=$?
set -e
((status == 1)) || { cat "$test_root/apply.out" >&2; fail "legacy changing action exited $status"; }
grep -Fq 'legacy changing actions are disabled' "$test_root/apply.out" \
  || fail 'legacy changing action did not direct callers to the full orchestrator'
[[ ! -e $test_root/apply-state && ! -e $home/.config ]] || fail 'rejected legacy apply wrote state/config'

# Even the hidden test switch is bound to the exact declared temp root.
set +e
MY_ARCH_SETUP_LEGACY_COMPONENT_TESTING=1 \
MY_ARCH_SETUP_LEGACY_TEST_ROOT="$test_root/not-home" \
HOME="$home" XDG_STATE_HOME="$test_root/wrong-root-state" \
  "$root/installer/install.sh" --profile vm --modules desktop-shared,wm-niri --apply-config \
  >"$test_root/wrong-root.out" 2>&1
wrong_status=$?
set -e
((wrong_status == 1)) || fail "wrong legacy test root exited $wrong_status"
grep -Fq 'legacy changing actions are disabled' "$test_root/wrong-root.out" \
  || fail 'wrong legacy test root bypassed the gate'

printf '%s\n' 'Legacy installer production gate checks passed.'
