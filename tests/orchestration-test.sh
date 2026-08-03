#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT
export MY_ARCH_SETUP_LEGACY_COMPONENT_TESTING=1 MY_ARCH_SETUP_LEGACY_TEST_ROOT="$test_root"
mock_bin="$test_root/mock-bin"
mkdir -p "$mock_bin"

desktop_modules="desktop-shared,wm-niri"
vm_modules="desktop-shared,wm-niri"

cat >"$mock_bin/pacman" <<'MOCK'
#!/usr/bin/env bash
set -u
printf 'pacman' >>"$MOCK_CALL_LOG"
printf '\t%s' "$@" >>"$MOCK_CALL_LOG"
printf '\n' >>"$MOCK_CALL_LOG"
case "${1:-}" in
  -Si)
    exit 0
    ;;
  -Q)
    if [[ -n "${MOCK_QUERY_STATUS:-}" ]]; then
      exit "$MOCK_QUERY_STATUS"
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
if [[ -n "${MOCK_SUDO_FAIL_MATCH:-}" && "$*" == *"$MOCK_SUDO_FAIL_MATCH"* ]]; then
  exit "${MOCK_SUDO_STATUS:-29}"
fi
if [[ "${MOCK_CREATE_CONFIG_SYMLINK_AFTER_PACKAGE:-}" == true && "$*" == *"pacman -S --needed"* ]]; then
  mkdir -p "$HOME/.config/fuzzel"
  ln -s -- /tmp "$HOME/.config/fuzzel/colors.ini"
fi
MOCK

cat >"$mock_bin/getent" <<'MOCK'
#!/usr/bin/env bash
set -u
printf 'getent' >>"$MOCK_CALL_LOG"
printf '\t%s' "$@" >>"$MOCK_CALL_LOG"
printf '\n' >>"$MOCK_CALL_LOG"
printf '203.0.113.1 STREAM archlinux.org\n'
MOCK

cat >"$mock_bin/df" <<'MOCK'
#!/usr/bin/env bash
set -u
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
printf '/dev/mock 20971520 1024 20970496 1%% /\n'
MOCK

cat >"$mock_bin/systemctl" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
chmod 755 "$mock_bin"/*

fail() {
  printf 'orchestration test failed: %s\n' "$*" >&2
  exit 1
}

state_path() {
  local home="$1" base run_id
  base="$home/.local/state/my-archlinux-setup"
  [[ -f "$base/latest-run" ]] || fail "latest-run is missing under $home"
  run_id=$(<"$base/latest-run")
  [[ "$run_id" =~ ^[A-Za-z0-9._-]+$ ]] || fail "latest run id is unsafe: $run_id"
  printf '%s/runs/%s/state' "$base" "$run_id"
}

run_log_path() {
  local home="$1" base run_id
  base="$home/.local/state/my-archlinux-setup"
  run_id=$(<"$base/latest-run")
  printf '%s/runs/%s/run.log' "$base" "$run_id"
}

# A successful physical run executes packages before config and records both.
success_home="$test_root/success-home"
success_calls="$test_root/success.calls"
mkdir -p "$success_home"
: >"$success_calls"
set +e
HOME="$success_home" XDG_STATE_HOME="$success_home/.local/state" \
  PATH="$mock_bin:$PATH" MOCK_CALL_LOG="$success_calls" \
  "$root/installer/install.sh" --profile desktop-amd --modules "$desktop_modules" \
  --apply --confirm-system-changes --confirm-config \
  >"$test_root/success.out" 2>&1
success_status=$?
set -e
if ((success_status != 0)); then
  cat "$test_root/success.out" >&2
  fail "successful combined run exited with $success_status"
fi
success_state=$(state_path "$success_home")
success_log=$(run_log_path "$success_home")
[[ -f "$success_state" && -f "$success_log" ]] || fail 'successful run omitted state/log'
[[ $(stat -c '%a' "$success_state") == 600 ]] || fail 'orchestrator state is not mode 600'
[[ $(stat -c '%a' "$success_log") == 600 ]] || fail 'orchestrator log is not mode 600'
[[ $(stat -c '%a' "$(dirname -- "$success_state")") == 700 ]] || fail 'run directory is not mode 700'
grep -Fqx 'status=completed' "$success_state" || fail 'successful run state is not completed'
grep -Fqx 'stage_official-packages=passed' "$success_state" || fail 'package stage was not recorded passed'
grep -Fqx 'stage_user-config=passed' "$success_state" || fail 'config stage was not recorded passed'
grep -Fq 'official-packages: passed' "$test_root/success.out" || fail 'final report omitted passed package stage'
grep -Fq 'user-config: passed' "$test_root/success.out" || fail 'final report omitted passed config stage'
grep -Fq 'result: passed' "$test_root/success.out" || fail 'final report omitted passed result'
grep -Fq 'config: deployed .config/niri/config.kdl' "$success_log" || \
  fail 'orchestrator log omitted config stage output'
[[ -f "$success_home/.config/niri/config.kdl" ]] || fail 'combined run did not deploy selected config'
[[ -f "$success_home/.local/state/my-archlinux-setup/official-package-state" ]] || fail 'combined run omitted package state'
package_line=$(grep -n -m1 $'^sudo\tpacman\t-S\t--needed' "$success_calls" | cut -d: -f1)
[[ -n "$package_line" ]] || fail 'combined run did not invoke package install'

# All confirmations are collected before state, sudo, or config writes.
cancel_home="$test_root/cancel-home"
cancel_calls="$test_root/cancel.calls"
mkdir -p "$cancel_home"
: >"$cancel_calls"
set +e
printf 'apply-system-changes\ncancel\n' | HOME="$cancel_home" XDG_STATE_HOME="$cancel_home/.local/state" \
  PATH="$mock_bin:$PATH" MOCK_CALL_LOG="$cancel_calls" \
  "$root/installer/install.sh" --profile desktop-amd --modules "$desktop_modules" --apply \
  >"$test_root/cancel.out" 2>&1
cancel_status=$?
set -e
((cancel_status != 0)) || fail 'cancelled combined run unexpectedly succeeded'
grep -Fq 'configuration deployment cancelled' "$test_root/cancel.out" || fail 'second confirmation cancellation was not explained'
[[ ! -e "$cancel_home/.local/state/my-archlinux-setup" ]] || fail 'cancelled combined run wrote state'
[[ ! -e "$cancel_home/.config" ]] || fail 'cancelled combined run wrote config'
! grep -q $'^sudo\t' "$cancel_calls" || fail 'cancelled combined run invoked sudo'

# A core package failure is preserved and skips dependent config.
package_fail_home="$test_root/package-fail-home"
package_fail_calls="$test_root/package-fail.calls"
mkdir -p "$package_fail_home"
: >"$package_fail_calls"
set +e
HOME="$package_fail_home" XDG_STATE_HOME="$package_fail_home/.local/state" \
  PATH="$mock_bin:$PATH" MOCK_CALL_LOG="$package_fail_calls" \
  MOCK_SUDO_FAIL_MATCH='pacman -Syu' MOCK_SUDO_STATUS=29 \
  "$root/installer/install.sh" --profile desktop-amd --modules "$desktop_modules" \
  --apply --confirm-system-changes --confirm-config \
  >"$test_root/package-fail.out" 2>&1
package_fail_status=$?
set -e
((package_fail_status == 29)) || fail "package failure status was not preserved: $package_fail_status"
package_fail_state=$(state_path "$package_fail_home")
package_fail_log=$(run_log_path "$package_fail_home")
grep -Fqx 'status=failed' "$package_fail_state" || fail 'failed run state is not failed'
grep -Fqx 'failed_stage=official-packages' "$package_fail_state" || fail 'failed package stage was not identified'
grep -Fqx 'failure_status=29' "$package_fail_state" || fail 'failed package status was not recorded'
grep -Fqx 'stage_official-packages=failed' "$package_fail_state" || fail 'package stage was not marked failed'
grep -Fqx 'stage_user-config=skipped' "$package_fail_state" || fail 'dependent config was not marked skipped'
[[ ! -e "$package_fail_home/.config" ]] || fail 'package failure deployed config'
grep -Fq 'result: failed' "$test_root/package-fail.out" || fail 'failed final report was omitted'
grep -Fq 'result=failed failed_stage=official-packages exit=29' "$package_fail_log" || \
  fail 'failed run log omitted terminal result metadata'

# Cancelling retry confirmations leaves the failed run evidence immutable.
retry_cancel_state_hash=$(sha256sum "$package_fail_state" | awk '{ print $1 }')
retry_cancel_log_hash=$(sha256sum "$package_fail_log" | awk '{ print $1 }')
retry_cancel_sudo_count=$(grep -c $'^sudo\t' "$package_fail_calls")
set +e
printf 'apply-system-changes\ncancel\n' | \
  HOME="$package_fail_home" XDG_STATE_HOME="$package_fail_home/.local/state" \
  PATH="$mock_bin:$PATH" MOCK_CALL_LOG="$package_fail_calls" \
  "$root/installer/install.sh" --profile desktop-amd --modules "$desktop_modules" \
  --apply --retry desktop-shared >"$test_root/retry-cancel.out" 2>&1
retry_cancel_status=$?
set -e
((retry_cancel_status != 0)) || fail 'cancelled retry unexpectedly succeeded'
grep -Fq 'configuration deployment cancelled' "$test_root/retry-cancel.out" || \
  fail 'retry confirmation cancellation was not explained'
[[ "$(sha256sum "$package_fail_state" | awk '{ print $1 }')" == "$retry_cancel_state_hash" ]] || \
  fail 'cancelled retry modified prior state'
[[ "$(sha256sum "$package_fail_log" | awk '{ print $1 }')" == "$retry_cancel_log_hash" ]] || \
  fail 'cancelled retry modified prior log'
[[ $(grep -c $'^sudo\t' "$package_fail_calls") == "$retry_cancel_sudo_count" ]] || \
  fail 'cancelled retry reached sudo'

# Retry rejects a non-selected module or a changed selection without mutating evidence.
package_fail_state_hash=$(sha256sum "$package_fail_state" | awk '{ print $1 }')
package_fail_sudo_count=$(grep -c $'^sudo\t' "$package_fail_calls")
set +e
HOME="$package_fail_home" XDG_STATE_HOME="$package_fail_home/.local/state" \
  PATH="$mock_bin:$PATH" MOCK_CALL_LOG="$package_fail_calls" \
  "$root/installer/install.sh" --profile desktop-amd --modules "$desktop_modules" \
  --apply --retry developer-editor --confirm-system-changes --confirm-config \
  >"$test_root/retry-unselected.out" 2>&1
retry_unselected_status=$?
set -e
((retry_unselected_status != 0)) || fail 'retry accepted an unselected module'
grep -Fq 'retry module is not selected' "$test_root/retry-unselected.out" || fail 'unselected retry failure was not explained'
set +e
HOME="$package_fail_home" XDG_STATE_HOME="$package_fail_home/.local/state" \
  PATH="$mock_bin:$PATH" MOCK_CALL_LOG="$package_fail_calls" \
  "$root/installer/install.sh" --profile desktop-amd \
  --modules desktop-shared,developer-editor,wm-niri \
  --apply --retry desktop-shared --confirm-system-changes --confirm-config \
  >"$test_root/retry-mismatch.out" 2>&1
retry_mismatch_status=$?
set -e
((retry_mismatch_status != 0)) || fail 'retry accepted a changed module selection'
grep -Fq 'latest run does not match the current profile, modules, mode, and plan fingerprint' \
  "$test_root/retry-mismatch.out" || fail 'retry plan mismatch was not explained'
[[ "$(sha256sum "$package_fail_state" | awk '{ print $1 }')" == "$package_fail_state_hash" ]] || \
  fail 'rejected retry modified prior state'
[[ $(grep -c $'^sudo\t' "$package_fail_calls") == "$package_fail_sudo_count" ]] || \
  fail 'rejected retry reached sudo'

# Retrying the failed module resumes the same run and completes it.
HOME="$package_fail_home" XDG_STATE_HOME="$package_fail_home/.local/state" \
  PATH="$mock_bin:$PATH" MOCK_CALL_LOG="$package_fail_calls" \
  "$root/installer/install.sh" --profile desktop-amd --modules "$desktop_modules" \
  --apply --retry desktop-shared --confirm-system-changes --confirm-config \
  >"$test_root/package-retry.out" 2>&1
package_retry_state=$(state_path "$package_fail_home")
grep -Fqx 'status=completed' "$package_retry_state" || fail 'retried package run did not complete'
grep -Fqx 'attempt=2' "$package_retry_state" || fail 'retry did not increment attempt'
[[ $(find "$package_fail_home/.local/state/my-archlinux-setup/runs" -mindepth 1 -maxdepth 1 -type d | wc -l) == 1 ]] || \
  fail 'retry created a new run instead of resuming'
[[ -f "$package_fail_home/.config/niri/config.kdl" ]] || fail 'retry did not run dependent config'

# A config race after package success fails config; retry verifies/skips packages.
config_fail_home="$test_root/config-fail-home"
config_fail_calls="$test_root/config-fail.calls"
mkdir -p "$config_fail_home"
: >"$config_fail_calls"
set +e
HOME="$config_fail_home" XDG_STATE_HOME="$config_fail_home/.local/state" \
  PATH="$mock_bin:$PATH" MOCK_CALL_LOG="$config_fail_calls" \
  MOCK_CREATE_CONFIG_SYMLINK_AFTER_PACKAGE=true \
  "$root/installer/install.sh" --profile desktop-amd --modules "$desktop_modules" \
  --apply --confirm-system-changes --confirm-config \
  >"$test_root/config-fail.out" 2>&1
config_fail_status=$?
set -e
((config_fail_status != 0)) || fail 'post-package config race unexpectedly succeeded'
config_fail_state=$(state_path "$config_fail_home")
grep -Fqx 'stage_official-packages=passed' "$config_fail_state" || fail 'package stage did not remain passed'
grep -Fqx 'stage_user-config=failed' "$config_fail_state" || fail 'config stage was not marked failed'
[[ -L "$config_fail_home/.config/fuzzel/colors.ini" ]] || fail 'config race fixture was not created'
rm -f -- "$config_fail_home/.config/fuzzel/colors.ini"
syu_before_retry=$(grep -c $'^sudo\tpacman\t-Syu$' "$config_fail_calls")
HOME="$config_fail_home" XDG_STATE_HOME="$config_fail_home/.local/state" \
  PATH="$mock_bin:$PATH" MOCK_CALL_LOG="$config_fail_calls" \
  "$root/installer/install.sh" --profile desktop-amd --modules "$desktop_modules" \
  --apply --retry desktop-shared --confirm-system-changes --confirm-config \
  >"$test_root/config-retry.out" 2>&1
syu_after_retry=$(grep -c $'^sudo\tpacman\t-Syu$' "$config_fail_calls")
((syu_after_retry == syu_before_retry)) || fail 'retry reran a package stage that re-verified successfully'
grep -Fq 'stage official-packages: verified; skipping' "$test_root/config-retry.out" || fail 'verified package skip was not disclosed'
config_retry_state=$(state_path "$config_fail_home")
grep -Fqx 'status=completed' "$config_retry_state" || fail 'config retry did not complete'
[[ -f "$config_fail_home/.config/fuzzel/colors.ini" && ! -L "$config_fail_home/.config/fuzzel/colors.ini" ]] || \
  fail 'config retry did not safely deploy the target'

# An interrupted run between stages resumes the first pending stage safely.
interrupted_home="$test_root/interrupted-home"
interrupted_calls="$test_root/interrupted.calls"
mkdir -p "$interrupted_home"
: >"$interrupted_calls"
HOME="$interrupted_home" XDG_STATE_HOME="$interrupted_home/.local/state" \
  PATH="$mock_bin:$PATH" MOCK_CALL_LOG="$interrupted_calls" \
  "$root/installer/install.sh" --profile desktop-amd --modules "$desktop_modules" \
  --apply --confirm-system-changes --confirm-config >/dev/null 2>&1
interrupted_state=$(state_path "$interrupted_home")
sed -i -e 's/^status=completed$/status=running/' \
  -e 's/^stage_user-config=passed$/stage_user-config=pending/' "$interrupted_state"
set +e
HOME="$interrupted_home" XDG_STATE_HOME="$interrupted_home/.local/state" \
  PATH="$mock_bin:$PATH" MOCK_CALL_LOG="$interrupted_calls" \
  "$root/installer/install.sh" --profile desktop-amd --modules "$desktop_modules" \
  --apply --retry desktop-shared --confirm-system-changes --confirm-config \
  >"$test_root/interrupted-retry.out" 2>&1
interrupted_retry_status=$?
set -e
if ((interrupted_retry_status != 0)); then
  cat "$test_root/interrupted-retry.out" >&2
  fail "interrupted retry exited with $interrupted_retry_status"
fi
grep -Fq 'stage official-packages: verified; skipping' "$test_root/interrupted-retry.out" || \
  fail 'interrupted retry did not verify/skip the completed package stage'
grep -Fqx 'status=completed' "$interrupted_state" || fail 'interrupted run did not complete after retry'
grep -Fqx 'attempt=2' "$interrupted_state" || fail 'interrupted retry did not increment attempt'

# A completed identical plan needs --rerun; rerun creates a new audited run.
syu_before_duplicate=$(grep -c $'^sudo\tpacman\t-Syu$' "$success_calls")
success_log_hash_before_duplicate=$(sha256sum "$success_log" | awk '{ print $1 }')
set +e
HOME="$success_home" XDG_STATE_HOME="$success_home/.local/state" \
  PATH="$mock_bin:$PATH" MOCK_CALL_LOG="$success_calls" \
  "$root/installer/install.sh" --profile desktop-amd --modules "$desktop_modules" \
  --apply --confirm-system-changes --confirm-config \
  >"$test_root/duplicate.out" 2>&1
duplicate_status=$?
set -e
((duplicate_status != 0)) || fail 'completed identical plan reran without --rerun'
grep -Fq -- 'use --rerun for an intentional rerun' "$test_root/duplicate.out" || fail 'rerun guidance was omitted'
syu_after_duplicate=$(grep -c $'^sudo\tpacman\t-Syu$' "$success_calls")
((syu_after_duplicate == syu_before_duplicate)) || fail 'rejected duplicate plan reached sudo'
success_log_hash_after_duplicate=$(sha256sum "$success_log" | awk '{ print $1 }')
[[ "$success_log_hash_after_duplicate" == "$success_log_hash_before_duplicate" ]] || \
  fail 'rejected duplicate plan modified prior run evidence'
HOME="$success_home" XDG_STATE_HOME="$success_home/.local/state" \
  PATH="$mock_bin:$PATH" MOCK_CALL_LOG="$success_calls" \
  "$root/installer/install.sh" --profile desktop-amd --modules "$desktop_modules" \
  --apply --rerun --confirm-system-changes --confirm-config \
  >"$test_root/rerun.out" 2>&1
[[ $(find "$success_home/.local/state/my-archlinux-setup/runs" -mindepth 1 -maxdepth 1 -type d | wc -l) == 2 ]] || \
  fail '--rerun did not create a separate audited run'

# VM has a dedicated config scope; combined apply requires the independent
# config confirmation and records a passed user-config stage.
vm_home="$test_root/vm-home"
vm_calls="$test_root/vm.calls"
mkdir -p "$vm_home"
: >"$vm_calls"
HOME="$vm_home" XDG_STATE_HOME="$vm_home/.local/state" \
  PATH="$mock_bin:$PATH" MOCK_CALL_LOG="$vm_calls" \
  "$root/installer/install.sh" --profile vm --modules "$vm_modules" \
  --apply --confirm-system-changes --confirm-config >"$test_root/vm.out" 2>&1
vm_state=$(state_path "$vm_home")
grep -Fqx 'stage_official-packages=passed' "$vm_state" || fail 'VM package stage did not pass'
grep -Fqx 'stage_user-config=passed' "$vm_state" || fail 'VM config stage did not pass'
grep -Fq 'user-config: passed' "$test_root/vm.out" || fail 'VM final report hid config success'
cmp -s -- "$root/config/vm/home/.config/niri/config.kdl" "$vm_home/.config/niri/config.kdl" || \
  fail 'VM combined run did not deploy the dedicated Niri config'
[[ ! -e "$vm_home/.config/hypr" ]] || fail 'Niri-only VM combined run leaked Hyprland config'

# Greeter is outside every executable profile and is rejected before state or sudo.
dms_home="$test_root/dms-home"
dms_calls="$test_root/dms.calls"
mkdir -p "$dms_home"
: >"$dms_calls"
set +e
HOME="$dms_home" XDG_STATE_HOME="$dms_home/.local/state" \
  PATH="$mock_bin:$PATH" MOCK_CALL_LOG="$dms_calls" \
  "$root/installer/install.sh" --profile asus-amd-nvidia \
  --modules desktop-shared,wm-hyprland,dms-greetd --apply \
  --confirm-system-changes --confirm-config >"$test_root/dms.out" 2>&1
dms_status=$?
set -e
((dms_status != 0)) || fail 'out-of-profile greeter combined apply succeeded'
grep -Fq 'module is not supported by profile asus-amd-nvidia: dms-greetd' "$test_root/dms.out" || fail 'greeter profile exclusion was not explained'
[[ ! -e "$dms_home/.local/state/my-archlinux-setup" ]] || fail 'rejected greeter combined apply wrote state'
! grep -q $'^sudo\t' "$dms_calls" || fail 'rejected greeter combined apply reached sudo'

# Retry refuses changed installer inputs even when profile/modules are unchanged.
fingerprint_project="$test_root/fingerprint-project"
fingerprint_home="$test_root/fingerprint-home"
fingerprint_calls="$test_root/fingerprint.calls"
mkdir -p "$fingerprint_project/installer" "$fingerprint_project/manifests" "$fingerprint_home"
cp -- "$root/installer/install.sh" "$fingerprint_project/installer/install.sh"
cp -a -- "$root/config" "$fingerprint_project/config"
cp -- "$root/manifests/"*.tsv "$fingerprint_project/manifests/"
: >"$fingerprint_calls"
set +e
HOME="$fingerprint_home" XDG_STATE_HOME="$fingerprint_home/.local/state" \
  PATH="$mock_bin:$PATH" MOCK_CALL_LOG="$fingerprint_calls" \
  MOCK_SUDO_FAIL_MATCH='pacman -Syu' MOCK_SUDO_STATUS=29 \
  "$fingerprint_project/installer/install.sh" --profile desktop-amd --modules "$desktop_modules" \
  --apply --confirm-system-changes --confirm-config >"$test_root/fingerprint-fail.out" 2>&1
fingerprint_fail_status=$?
set -e
((fingerprint_fail_status == 29)) || fail 'fingerprint fixture did not create a failed run'
fingerprint_state=$(state_path "$fingerprint_home")
fingerprint_state_hash=$(sha256sum "$fingerprint_state" | awk '{ print $1 }')
printf '\n# changed after failed run\n' >>"$fingerprint_project/config/home/.config/fuzzel/colors.ini"
fingerprint_sudo_before=$(grep -c $'^sudo\t' "$fingerprint_calls")
set +e
HOME="$fingerprint_home" XDG_STATE_HOME="$fingerprint_home/.local/state" \
  PATH="$mock_bin:$PATH" MOCK_CALL_LOG="$fingerprint_calls" \
  "$fingerprint_project/installer/install.sh" --profile desktop-amd --modules "$desktop_modules" \
  --apply --retry desktop-shared --confirm-system-changes --confirm-config \
  >"$test_root/fingerprint-retry.out" 2>&1
fingerprint_retry_status=$?
set -e
((fingerprint_retry_status != 0)) || fail 'retry accepted changed installer inputs'
grep -Fq 'latest run does not match the current profile, modules, mode, and plan fingerprint' \
  "$test_root/fingerprint-retry.out" || fail 'changed-input retry failure was not explained'
[[ "$(sha256sum "$fingerprint_state" | awk '{ print $1 }')" == "$fingerprint_state_hash" ]] || \
  fail 'changed-input retry modified prior state'
[[ $(grep -c $'^sudo\t' "$fingerprint_calls") == "$fingerprint_sudo_before" ]] || \
  fail 'changed-input retry reached sudo'

# Symlinked run-state control paths are rejected without touching the target or sudo.
state_link_home="$test_root/state-link-home"
state_link_calls="$test_root/state-link.calls"
state_link_external="$test_root/external-latest-run"
mkdir -p "$state_link_home/.local/state/my-archlinux-setup"
printf 'external-evidence\n' >"$state_link_external"
chmod 600 "$state_link_external"
ln -s -- "$state_link_external" "$state_link_home/.local/state/my-archlinux-setup/latest-run"
: >"$state_link_calls"
external_hash_before=$(sha256sum "$state_link_external" | awk '{ print $1 }')
set +e
HOME="$state_link_home" XDG_STATE_HOME="$state_link_home/.local/state" \
  PATH="$mock_bin:$PATH" MOCK_CALL_LOG="$state_link_calls" \
  "$root/installer/install.sh" --profile desktop-amd --modules "$desktop_modules" \
  --apply --confirm-system-changes --confirm-config >"$test_root/state-link.out" 2>&1
state_link_status=$?
set -e
((state_link_status != 0)) || fail 'symlinked latest-run pointer was accepted'
grep -Fq 'latest run pointer must not be a symlink' "$test_root/state-link.out" || \
  fail 'symlinked latest-run failure was not explained'
[[ "$(sha256sum "$state_link_external" | awk '{ print $1 }')" == "$external_hash_before" ]] || \
  fail 'symlinked latest-run target was modified'
! grep -q $'^sudo\t' "$state_link_calls" || fail 'symlinked latest-run case reached sudo'

runs_link_home="$test_root/runs-link-home"
runs_link_calls="$test_root/runs-link.calls"
runs_link_external="$test_root/external-runs"
mkdir -p "$runs_link_home/.local/state/my-archlinux-setup" "$runs_link_external"
chmod 755 "$runs_link_external"
ln -s -- "$runs_link_external" "$runs_link_home/.local/state/my-archlinux-setup/runs"
: >"$runs_link_calls"
set +e
HOME="$runs_link_home" XDG_STATE_HOME="$runs_link_home/.local/state" \
  PATH="$mock_bin:$PATH" MOCK_CALL_LOG="$runs_link_calls" \
  "$root/installer/install.sh" --profile desktop-amd --modules "$desktop_modules" \
  --apply --confirm-system-changes --confirm-config >"$test_root/runs-link.out" 2>&1
runs_link_status=$?
set -e
((runs_link_status != 0)) || fail 'symlinked runs directory was accepted'
grep -Fq 'refusing to use a symlinked installer runs directory' "$test_root/runs-link.out" || \
  fail 'symlinked runs directory failure was not explained'
[[ $(stat -c '%a' "$runs_link_external") == 755 ]] || fail 'symlinked runs target mode was changed'
[[ -z "$(find "$runs_link_external" -mindepth 1 -print -quit)" ]] || fail 'symlinked runs target received files'
! grep -q $'^sudo\t' "$runs_link_calls" || fail 'symlinked runs directory case reached sudo'

printf 'Staged orchestration checks passed.\n'
