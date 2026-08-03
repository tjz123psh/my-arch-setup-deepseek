#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source_tool="$root/installer/system-action-apply.py"
source_planner="$root/installer/system-action-plan.py"

fail() {
  printf 'system action apply test failed: %s\n' "$*" >&2
  exit 1
}

[[ -f $source_tool && ! -L $source_tool ]] || fail 'production system-actions adapter is missing or unsafe'
[[ -x $source_tool ]] || fail 'production system-actions adapter is not executable'
[[ -f $source_planner && ! -L $source_planner ]] || fail 'existing system action planner is missing or unsafe'

python3 -B - "$source_tool" "$root" <<'PY'
import hashlib
import importlib.util
import sys
from pathlib import Path

path = Path(sys.argv[1])
root = Path(sys.argv[2])
spec = importlib.util.spec_from_file_location("system_action_apply_constants", path)
assert spec is not None and spec.loader is not None
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)
assert module.AUDITED_GSUDO_SHA256 == hashlib.sha256(
    (root / "config/home/scripts/desktop/gsudo").read_bytes()
).hexdigest()
assert module.AUDITED_ASKPASS_SHA256 == hashlib.sha256(
    (root / "config/home/scripts/desktop/fuzzel-askpass").read_bytes()
).hexdigest()
PY

test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT
fixture="$test_root/project"
tool="$fixture/installer/system-action-apply.py"
planner="$fixture/installer/system-action-plan.py"
home="$test_root/home"
target_root="$test_root/target-root"
state_home="$test_root/state"
mock_bin="$test_root/mock-bin"
mock_state="$test_root/mock-state"
call_log="$test_root/calls.tsv"
mkdir -p "$fixture/installer" "$fixture/manifests" "$fixture/config/home/scripts/desktop" \
  "$home/scripts/desktop" "$mock_bin" "$mock_state"
chmod 700 "$home" "$mock_state"
cp -- "$source_tool" "$tool"
cp -- "$source_planner" "$planner"
cp -- "$root/config/home/scripts/desktop/gsudo" \
  "$root/config/home/scripts/desktop/fuzzel-askpass" \
  "$fixture/config/home/scripts/desktop/"
cp -- "$root/manifests/modules.tsv" \
  "$root/manifests/profile-modules.tsv" \
  "$root/manifests/system-actions.tsv" \
  "$root/manifests/system-action-conflicts.tsv" \
  "$root/manifests/workstation-packages.tsv" \
  "$fixture/manifests/"
chmod 755 "$tool" "$planner"

python3 "$planner" --profile asus-amd-nvidia --json >"$test_root/planner.json"
python3 - "$test_root/planner.json" "$fixture/manifests/workstation-packages.tsv" \
  "$test_root/effects.json" "$test_root/modules" "$test_root/stage-modules" "$test_root/installed-all" <<'PY'
import csv
import json
import sys
from pathlib import Path

plan = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
policy_path = Path(sys.argv[2])
selected = tuple(plan["selection"]["resolved_modules"])
selected_set = set(selected)
effects = []
for action in plan["actions"]:
    conflict = action["conflict_set"] or "-"
    effects.append(
        {
            "id": f"action:{action['id']}",
            "module": action["module"],
            "detail": " ".join(
                (
                    f"disposition={action['disposition']}",
                    f"privilege={action['privilege']}",
                    f"handler={action['handler']}",
                    f"target={action['target']}",
                    f"applicability={action['applicability']}",
                    f"conflict={conflict}",
                )
            ),
        }
    )
rows = []
with policy_path.open(encoding="utf-8", newline="") as handle:
    for row in csv.reader(handle, delimiter="\t"):
        if not row or not row[0] or row[0].startswith("#"):
            continue
        assert len(row) == 9
        rows.append(row)
for package, channel, repository, acquisition, module, _restore, policy, _origin, _purpose in sorted(
    rows, key=lambda row: row[0]
):
    if module in selected_set and acquisition == "verify-only" and policy == "verify":
        effects.append(
            {
                "id": f"verify:{package}",
                "module": module,
                "detail": (
                    f"package={package} channel={channel} "
                    f"repository={repository} acquisition={acquisition}"
                ),
            }
        )
Path(sys.argv[3]).write_text(
    json.dumps(effects, sort_keys=True, separators=(",", ":")), encoding="utf-8"
)
Path(sys.argv[4]).write_text(",".join(selected), encoding="utf-8")
effect_modules = {effect["module"] for effect in effects}
Path(sys.argv[5]).write_text(
    ",".join(module for module in selected if module in effect_modules), encoding="utf-8"
)
installable = {
    row[0]
    for row in rows
    if row[4] in selected_set
    and (
        (row[6] == "verify" and row[3] == "verify-only")
        or (row[6] == "install" and row[3] in {"pacman", "archlinuxcn-bootstrap", "aur-build", "paru-bootstrap"})
    )
}
Path(sys.argv[6]).write_text(
    "".join(f"{package} 1.0-1\n" for package in sorted(installable)), encoding="utf-8"
)
PY

effects=$(<"$test_root/effects.json")
modules=$(<"$test_root/modules")
stage_modules=$(<"$test_root/stage-modules")

cat >"$mock_bin/pacman" <<'MOCK'
#!/usr/bin/env bash
set -u
printf 'pacman' >>"$MOCK_CALL_LOG"; printf '\t%s' "$@" >>"$MOCK_CALL_LOG"; printf '\n' >>"$MOCK_CALL_LOG"
case "${1:-}" in
  -Q)
    [[ $# == 1 ]] || exit 97
    if [[ -f $MOCK_STATE/pacman-q-fail ]]; then exit "$(<"$MOCK_STATE/pacman-q-fail")"; fi
    cat -- "$MOCK_INSTALLED"
    ;;
  -Si)
    [[ ${2:-} == -- && ${3:-} == pacman && $# == 3 ]] || exit 97
    if [[ -f $MOCK_STATE/pacman-si-fail ]]; then exit "$(<"$MOCK_STATE/pacman-si-fail")"; fi
    printf 'Repository      : core\nName            : pacman\nVersion         : 1.0-1\n'
    ;;
  -Qo)
    [[ ${2:-} == -- && $# == 3 ]] || exit 97
    if [[ -f $MOCK_STATE/pacman-qo-fail ]]; then exit "$(<"$MOCK_STATE/pacman-qo-fail")"; fi
    owner=libvirt
    [[ ! -f $MOCK_STATE/pacman-qo-owner ]] || owner=$(<"$MOCK_STATE/pacman-qo-owner")
    printf '%s is owned by %s 1.0-1\n' "$3" "$owner"
    ;;
  *) exit 97 ;;
esac
MOCK

cat >"$mock_bin/systemctl" <<'MOCK'
#!/usr/bin/env bash
set -u
printf 'systemctl' >>"$MOCK_CALL_LOG"; printf '\t%s' "$@" >>"$MOCK_CALL_LOG"; printf '\n' >>"$MOCK_CALL_LOG"
scope=system
if [[ ${1:-} == --user ]]; then scope=user; shift; fi
if [[ ${1:-} == --global ]]; then scope=global; shift; fi
command=${1:-}; shift || true
key() { printf '%s' "$1" | tr '/:@.' '____'; }
case "$command" in
  is-active)
    [[ $# == 1 ]] || exit 97
    unit_key=$(key "$1")
    fail_file="$MOCK_STATE/systemctl-fail-active-$scope-$unit_key"
    [[ ! -f $fail_file ]] || exit "$(<"$fail_file")"
    if [[ -f $MOCK_STATE/inactive-$scope-$unit_key ]]; then printf 'inactive\n'; exit 3; fi
    printf 'active\n'
    ;;
  is-enabled)
    [[ $# == 1 ]] || exit 97
    unit_key=$(key "$1")
    fail_file="$MOCK_STATE/systemctl-fail-enabled-$scope-$unit_key"
    [[ ! -f $fail_file ]] || exit "$(<"$fail_file")"
    if [[ -f $MOCK_STATE/disabled-$scope-$unit_key ]]; then printf 'disabled\n'; exit 1; fi
    printf 'enabled\n'
    ;;
  show)
    if [[ ${1:-} == --property=LoadState && ${2:-} == --value && $# == 3 ]]; then
      unit_key=$(key "$3")
      fail_file="$MOCK_STATE/systemctl-fail-load-$scope-$unit_key"
      [[ ! -f $fail_file ]] || exit "$(<"$fail_file")"
      if [[ -f $MOCK_STATE/missing-$scope-$unit_key ]]; then printf 'not-found\n'; else printf 'loaded\n'; fi
    elif [[ ${1:-} == --property=Wants && ${2:-} == --value && ${3:-} == niri.service && $# == 3 ]]; then
      if [[ -f $MOCK_STATE/wants-missing ]]; then printf 'graphical-session.target\n'; else printf 'dms.service graphical-session.target\n'; fi
    else
      exit 97
    fi
    ;;
  --failed)
    [[ ${1:-} == --output=json && ${2:-} == --no-legend && $# == 2 ]] || exit 97
    fail_file="$MOCK_STATE/systemctl-fail-failed-$scope"
    [[ ! -f $fail_file ]] || exit "$(<"$fail_file")"
    if [[ -f $MOCK_STATE/failed-array-$scope ]]; then cat "$MOCK_STATE/failed-array-$scope"; else printf '[]\n'; fi
    ;;
  enable)
    [[ ${1:-} == --now && $# == 2 ]] || exit 97
    unit_key=$(key "$2")
    rm -f -- "$MOCK_STATE/disabled-$scope-$unit_key" "$MOCK_STATE/inactive-$scope-$unit_key"
    ;;
  add-wants)
    [[ $scope == user && ${1:-} == niri.service && ${2:-} == dms.service && $# == 2 ]] || exit 97
    rm -f -- "$MOCK_STATE/wants-missing"
    ;;
  daemon-reload)
    [[ $scope == user && $# == 0 ]] || exit 97
    [[ ! -f $MOCK_STATE/daemon-reload-fail ]] || exit "$(<"$MOCK_STATE/daemon-reload-fail")"
    ;;
  *) exit 97 ;;
esac
MOCK

cat >"$mock_bin/timedatectl" <<'MOCK'
#!/usr/bin/env bash
set -u
printf 'timedatectl' >>"$MOCK_CALL_LOG"; printf '\t%s' "$@" >>"$MOCK_CALL_LOG"; printf '\n' >>"$MOCK_CALL_LOG"
[[ $* == 'show --property=NTPSynchronized --value' ]] || exit 97
[[ ! -f $MOCK_STATE/timedatectl-fail ]] || exit "$(<"$MOCK_STATE/timedatectl-fail")"
if [[ -f $MOCK_STATE/time-unsynchronized ]]; then printf 'no\n'; else printf 'yes\n'; fi
MOCK

cat >"$mock_bin/getent" <<'MOCK'
#!/usr/bin/env bash
set -u
printf 'getent' >>"$MOCK_CALL_LOG"; printf '\t%s' "$@" >>"$MOCK_CALL_LOG"; printf '\n' >>"$MOCK_CALL_LOG"
[[ $* == 'ahostsv4 archlinux.org' ]] || exit 97
[[ ! -f $MOCK_STATE/getent-fail ]] || exit "$(<"$MOCK_STATE/getent-fail")"
printf '95.217.163.246 STREAM archlinux.org\n'
MOCK

cat >"$mock_bin/bluetoothctl" <<'MOCK'
#!/usr/bin/env bash
set -u
printf 'bluetoothctl' >>"$MOCK_CALL_LOG"; printf '\t%s' "$@" >>"$MOCK_CALL_LOG"; printf '\n' >>"$MOCK_CALL_LOG"
[[ $* == list ]] || exit 97
[[ ! -f $MOCK_STATE/bluetooth-fail ]] || exit "$(<"$MOCK_STATE/bluetooth-fail")"
[[ ! -f $MOCK_STATE/no-bluetooth-controller ]] || exit 0
printf 'Controller AA:BB:CC:DD:EE:FF Test Controller [default]\n'
MOCK

cat >"$mock_bin/powerprofilesctl" <<'MOCK'
#!/usr/bin/env bash
set -u
printf 'powerprofilesctl' >>"$MOCK_CALL_LOG"; printf '\t%s' "$@" >>"$MOCK_CALL_LOG"; printf '\n' >>"$MOCK_CALL_LOG"
[[ $* == list ]] || exit 97
[[ ! -f $MOCK_STATE/power-fail ]] || exit "$(<"$MOCK_STATE/power-fail")"
printf '  performance:\n* balanced:\n  power-saver:\n'
MOCK

cat >"$mock_bin/virsh" <<'MOCK'
#!/usr/bin/env bash
set -u
printf 'virsh' >>"$MOCK_CALL_LOG"; printf '\t%s' "$@" >>"$MOCK_CALL_LOG"; printf '\n' >>"$MOCK_CALL_LOG"
[[ ${1:-} == --connect && ${2:-} == qemu:///system ]] || exit 97
shift 2
case "${1:-}" in
  uri)
    [[ $# == 1 ]] || exit 97
    [[ ! -f $MOCK_STATE/virsh-uri-fail ]] || exit "$(<"$MOCK_STATE/virsh-uri-fail")"
    printf 'qemu:///system\n'
    ;;
  net-info)
    [[ ${2:-} == default && $# == 2 ]] || exit 97
    [[ ! -f $MOCK_STATE/virsh-info-fail ]] || exit "$(<"$MOCK_STATE/virsh-info-fail")"
    if [[ -f $MOCK_STATE/network-absent ]]; then printf "error: failed to get network 'default'\n" >&2; exit 1; fi
    active=yes; autostart=yes
    [[ ! -f $MOCK_STATE/network-inactive ]] || active=no
    [[ ! -f $MOCK_STATE/network-no-autostart ]] || autostart=no
    printf 'Name:           default\nUUID:           11111111-2222-3333-4444-555555555555\nActive:         %s\nPersistent:     yes\nAutostart:      %s\nBridge:         virbr0\n' "$active" "$autostart"
    ;;
  net-define)
    [[ $# == 2 && $2 == "$SYSTEM_ACTION_EXPECTED_NETWORK_XML" ]] || exit 97
    rm -f -- "$MOCK_STATE/network-absent"
    : >"$MOCK_STATE/network-inactive"
    : >"$MOCK_STATE/network-no-autostart"
    ;;
  net-start)
    [[ ${2:-} == default && $# == 2 ]] || exit 97
    rm -f -- "$MOCK_STATE/network-inactive"
    ;;
  net-autostart)
    [[ ${2:-} == default && $# == 2 ]] || exit 97
    rm -f -- "$MOCK_STATE/network-no-autostart"
    ;;
  *) exit 97 ;;
esac
MOCK

cat >"$mock_bin/locale" <<'MOCK'
#!/usr/bin/env bash
set -u
printf 'locale' >>"$MOCK_CALL_LOG"; printf '\t%s' "$@" >>"$MOCK_CALL_LOG"; printf '\n' >>"$MOCK_CALL_LOG"
[[ $* == -a ]] || exit 97
[[ ! -f $MOCK_STATE/locale-query-fail ]] || exit "$(<"$MOCK_STATE/locale-query-fail")"
if [[ -f $MOCK_STATE/locales-missing ]]; then printf 'C\n'; else printf 'C\nen_US.utf8\nzh_CN.utf8\n'; fi
MOCK

cat >"$mock_bin/locale-gen" <<'MOCK'
#!/usr/bin/env bash
set -u
printf 'locale-gen' >>"$MOCK_CALL_LOG"; printf '\t%s' "$@" >>"$MOCK_CALL_LOG"; printf '\n' >>"$MOCK_CALL_LOG"
[[ $# == 0 ]] || exit 97
if [[ -f $MOCK_STATE/locale-gen-fail ]]; then
  printf 'locale generation fixture failure\n' >&2
  exit "$(<"$MOCK_STATE/locale-gen-fail")"
fi
rm -f -- "$MOCK_STATE/locales-missing"
printf 'Generation complete.\n'
MOCK

cat >"$mock_bin/systemd-analyze" <<'MOCK'
#!/usr/bin/env bash
set -u
printf 'systemd-analyze' >>"$MOCK_CALL_LOG"; printf '\t%s' "$@" >>"$MOCK_CALL_LOG"; printf '\n' >>"$MOCK_CALL_LOG"
if [[ ${1:-} == --version && $# == 1 ]]; then printf 'systemd 258 (258.1-1-arch)\n'; exit 0; fi
if [[ ${1:-} == --user && ${2:-} == verify && ${3:-} == -- && $# -ge 4 ]]; then
  [[ ! -f $MOCK_STATE/systemd-analyze-fail ]] || exit "$(<"$MOCK_STATE/systemd-analyze-fail")"
  exit 0
fi
exit 97
MOCK

cat >"$mock_bin/sudo" <<'MOCK'
#!/usr/bin/env bash
printf 'sudo' >>"$MOCK_CALL_LOG"; printf '\t%s' "$@" >>"$MOCK_CALL_LOG"; printf '\n' >>"$MOCK_CALL_LOG"
exit 99
MOCK

for command in pacman systemctl timedatectl getent bluetoothctl powerprofilesctl virsh locale locale-gen systemd-analyze sudo; do
  chmod 755 "$mock_bin/$command"
done

cat >"$home/scripts/desktop/gsudo" <<'MOCK'
#!/usr/bin/env bash
set -u
printf 'gsudo' >>"$MOCK_CALL_LOG"; printf '\t%s' "$@" >>"$MOCK_CALL_LOG"; printf '\n' >>"$MOCK_CALL_LOG"
[[ ${1:-} == -- ]] || exit 96
shift
if [[ -f $MOCK_STATE/gsudo-fail ]]; then exit "$(<"$MOCK_STATE/gsudo-fail")"; fi
if [[ -f $MOCK_STATE/gsudo-fail-unit && ${1:-} == "$MOCK_COMMAND_DIR/systemctl" && ${2:-} == enable && ${3:-} == --now ]]; then
  IFS=: read -r failed_unit failed_status <"$MOCK_STATE/gsudo-fail-unit"
  [[ ${4:-} != "$failed_unit" ]] || exit "$failed_status"
fi
exec "$@"
MOCK
cat >"$home/scripts/desktop/fuzzel-askpass" <<'MOCK'
#!/usr/bin/env bash
exit 96
MOCK
chmod 755 "$home/scripts/desktop/gsudo" "$home/scripts/desktop/fuzzel-askpass"
gsudo_sha=$(sha256sum "$home/scripts/desktop/gsudo" | awk '{print $1}')
askpass_sha=$(sha256sum "$home/scripts/desktop/fuzzel-askpass" | awk '{print $1}')

reset_target() {
  rm -rf -- "$target_root" "$state_home"
  rm -rf -- "$home/.config"
  mkdir -p "$target_root/etc" "$target_root/usr/lib" "$target_root/usr/share/libvirt/networks"
  mkdir -p "$home/.config/systemd/user"
  chmod 700 "$target_root"
  chmod 755 "$target_root/etc" "$target_root/usr" "$target_root/usr/lib" \
    "$target_root/usr/share" "$target_root/usr/share/libvirt" "$target_root/usr/share/libvirt/networks"
  cat >"$target_root/usr/lib/os-release" <<'EOF_OS'
NAME="Arch Linux"
ID=arch
PRETTY_NAME="Arch Linux"
EOF_OS
  cat >"$target_root/etc/locale.gen" <<'EOF_LOCALE_GEN'
#en_US.UTF-8 UTF-8
#zh_CN.UTF-8 UTF-8
de_DE.UTF-8 UTF-8
EOF_LOCALE_GEN
  cat >"$target_root/etc/locale.conf" <<'EOF_LOCALE_CONF'
LANG=C.UTF-8
EOF_LOCALE_CONF
  cat >"$target_root/etc/environment" <<'EOF_ENVIRONMENT'
EDITOR=vim
QT_IM_MODULE=old
XMODIFIERS=@im=old
UNRELATED=value
EOF_ENVIRONMENT
  printf '<network><name>default</name></network>\n' >"$target_root/usr/share/libvirt/networks/default.xml"
  local mapped_unit
  for mapped_unit in openai-oauth.service penpot-mcp.service vellum-tray.service vellum.service; do
    printf '[Unit]\nDescription=Fixture %s\n' "$mapped_unit" >"$home/.config/systemd/user/$mapped_unit"
    chmod 644 "$home/.config/systemd/user/$mapped_unit"
  done
  chmod 644 "$target_root/usr/lib/os-release" "$target_root/etc/locale.gen" \
    "$target_root/etc/locale.conf" "$target_root/etc/environment" \
    "$target_root/usr/share/libvirt/networks/default.xml"
  cp -- "$test_root/installed-all" "$test_root/installed"
  rm -rf -- "$mock_state"
  mkdir -p "$mock_state"
  chmod 700 "$mock_state"
  local scope unit key
  for unit in ntpd.service chronyd.service openntpd.service \
    tlp.service tuned.service auto-cpufreq.service system76-power.service \
    virtqemud.service virtqemud.socket virtnetworkd.service virtnetworkd.socket \
    virtstoraged.service virtstoraged.socket; do
    key=$(printf '%s' "$unit" | tr '/:@.' '____')
    : >"$mock_state/inactive-system-$key"
  done
  for unit in pulseaudio.service pulseaudio.socket pipewire-media-session.service; do
    key=$(printf '%s' "$unit" | tr '/:@.' '____')
    : >"$mock_state/inactive-user-$key"
  done
  : >"$call_log"
}

mark_unit_unready() {
  local scope=$1 unit=$2 key
  key=$(printf '%s' "$unit" | tr '/:@.' '____')
  : >"$mock_state/disabled-$scope-$key"
  : >"$mock_state/inactive-$scope-$key"
}

case_counter=0
run_case() {
  local name action effect_value profile module_value stage_module_value run_id
  local explicit_run_id attempt
  local fingerprint=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  name=$1
  action=$2
  effect_value=${3:-$effects}
  profile=${4:-asus-amd-nvidia}
  module_value=${5:-$modules}
  stage_module_value=${6:-$stage_modules}
  explicit_run_id=${7:-}
  attempt=${8:-1}
  case_counter=$((case_counter + 1))
  if [[ -n $explicit_run_id ]]; then
    run_id=$explicit_run_id
  else
    run_id="20260801T0101${case_counter}Z-$(printf '%012d' "$case_counter")"
  fi
  set +e
  env \
    HOME="$home" \
    XDG_STATE_HOME="$state_home" \
    PATH="$mock_bin:/usr/bin:/bin" \
    MOCK_CALL_LOG="$call_log" \
    MOCK_STATE="$mock_state" \
    MOCK_INSTALLED="$test_root/installed" \
    MOCK_COMMAND_DIR="$mock_bin" \
    SYSTEM_ACTION_APPLY_TESTING=1 \
    SYSTEM_ACTION_APPLY_TEST_ROOT="$target_root" \
    SYSTEM_ACTION_TEST_COMMAND_DIR="$mock_bin" \
    SYSTEM_ACTION_TEST_GSUDO_SHA256="$gsudo_sha" \
    SYSTEM_ACTION_TEST_ASKPASS_SHA256="$askpass_sha" \
    SYSTEM_ACTION_EXPECTED_NETWORK_XML="$target_root/usr/share/libvirt/networks/default.xml" \
    FULL_ORCHESTRATOR_ACTION="$action" \
    FULL_ORCHESTRATOR_STAGE=system-actions \
    FULL_ORCHESTRATOR_PROFILE="$profile" \
    FULL_ORCHESTRATOR_MODE=new \
    FULL_ORCHESTRATOR_MODULES="$module_value" \
    FULL_ORCHESTRATOR_STAGE_MODULES="$stage_module_value" \
    FULL_ORCHESTRATOR_EFFECTS_JSON="$effect_value" \
    FULL_ORCHESTRATOR_PLAN_FINGERPRINT="$fingerprint" \
    FULL_ORCHESTRATOR_RUN_ID="$run_id" \
    FULL_ORCHESTRATOR_ATTEMPT="$attempt" \
    "$tool" >"$test_root/$name.out" 2>&1
  CASE_STATUS=$?
  set -e
  CASE_OUTPUT="$test_root/$name.out"
  CASE_RUN_ID=$run_id
}

assert_no_changing_calls() {
  ! grep -Eq $'^(gsudo|sudo)\t|^systemctl\t.*(enable\t--now|add-wants|daemon-reload)|^virsh\t.*net-(define|start|autostart)|^locale-gen\t' "$call_log" || {
    cat "$call_log" >&2
    fail 'a read-only case invoked a changing command'
  }
}

# Baseline preflight inventories all fixed boundaries but creates no target,
# backup, log, state, or wrapper side effect.
reset_target
before=$(find "$target_root" "$home" -xdev -printf '%p|%y|%m|%s|%T@|%l\n' -exec sha256sum {} \; 2>/dev/null | sha256sum)
run_case preflight preflight
((CASE_STATUS == 0)) || { cat "$CASE_OUTPUT" >&2; fail "baseline preflight exited $CASE_STATUS"; }
after=$(find "$target_root" "$home" -xdev -printf '%p|%y|%m|%s|%T@|%l\n' -exec sha256sum {} \; 2>/dev/null | sha256sum)
[[ $before == "$after" ]] || fail 'preflight changed target or home files'
[[ ! -e $state_home ]] || fail 'preflight created state/log/backup directories'
assert_no_changing_calls
grep -Fq '"classification":"ready"' "$CASE_OUTPUT" || fail 'preflight omitted ready classifications'
grep -Fq '"action":"preflight"' "$CASE_OUTPUT" || fail 'preflight omitted structured action evidence'
grep -Fqx $'pacman\t-Si\t--\tpacman' "$call_log" || fail 'network handoff did not query the fixed core/pacman identity'

# A failed package query remains unavailable with its exact external status;
# a successful empty package database is instead an honest missing blocker.
reset_target
printf '43\n' >"$mock_state/pacman-q-fail"
run_case package-query-failure preflight
((CASE_STATUS == 43)) || { cat "$CASE_OUTPUT" >&2; fail "package query status became $CASE_STATUS instead of 43"; }
grep -Fq '"classification":"unavailable"' "$CASE_OUTPUT" || fail 'failed package query was not unavailable'
[[ ! -e $state_home ]] || fail 'failed preflight wrote state'
assert_no_changing_calls

reset_target
: >"$test_root/installed"
run_case successful-empty-packages preflight
((CASE_STATUS == 1)) || { cat "$CASE_OUTPUT" >&2; fail "successful empty package inventory exited $CASE_STATUS"; }
grep -Fq '"classification":"missing-current"' "$CASE_OUTPUT" || fail 'successful empty inventory was not classified as missing'
! grep -Fq 'package inventory query unavailable' "$CASE_OUTPUT" || fail 'successful empty inventory was called unavailable'
assert_no_changing_calls

# Earlier install stages may satisfy install-policy packages after global
# preflight; verify-only packages and real conflicts may not be waved through.
reset_target
grep -v '^docker ' "$test_root/installed-all" >"$test_root/installed"
run_case expected-pending preflight
((CASE_STATUS == 0)) || { cat "$CASE_OUTPUT" >&2; fail "expected-pending package blocked with $CASE_STATUS"; }
grep -Fq '"package":"docker"' "$CASE_OUTPUT" || fail 'docker classification missing'
grep -Fq '"classification":"expected-pending"' "$CASE_OUTPUT" || fail 'earlier-stage package was not expected-pending'
assert_no_changing_calls

reset_target
printf 'chrony 1.0-1\n' >>"$test_root/installed"
run_case package-conflict preflight
((CASE_STATUS == 1)) || { cat "$CASE_OUTPUT" >&2; fail "installed conflict exited $CASE_STATUS"; }
grep -Fq 'chrony' "$CASE_OUTPUT" || fail 'installed conflict was not named'
assert_no_changing_calls

reset_target
rm -f -- "$mock_state/inactive-system-virtqemud_service"
run_case modular-conflict preflight
# Defaults are active in the mock, so selected modular units must block.
((CASE_STATUS == 1)) || { cat "$CASE_OUTPUT" >&2; fail "active modular libvirt conflict exited $CASE_STATUS"; }
grep -Fq 'virtqemud.service' "$CASE_OUTPUT" || fail 'active modular libvirt conflict was omitted'
assert_no_changing_calls

# Mark every modular unit inactive for the remaining ready cases.
mark_modular_inactive() {
  local unit
  for unit in virtqemud.service virtqemud.socket virtnetworkd.service virtnetworkd.socket virtstoraged.service virtstoraged.socket; do
    key=$(printf '%s' "$unit" | tr '/:@.' '____')
    : >"$mock_state/inactive-system-$key"
  done
}

# The baseline above intentionally proves strict modular conflict detection.
# From here onward every reset is followed by the reviewed monolithic state.
ready_reset() {
  reset_target
  mark_modular_inactive
}

ready_reset
printf 'GTK_IM_MODULE=fcitx\n' >>"$target_root/etc/environment"
run_case gtk-blocker preflight
((CASE_STATUS == 1)) || { cat "$CASE_OUTPUT" >&2; fail "GTK_IM_MODULE blocker exited $CASE_STATUS"; }
grep -Fq 'GTK_IM_MODULE' "$CASE_OUTPUT" || fail 'GTK_IM_MODULE blocker was hidden'
assert_no_changing_calls

ready_reset
printf '71\n' >"$mock_state/systemctl-fail-active-system-chronyd_service"
run_case unit-query-failure preflight
((CASE_STATUS == 71)) || { cat "$CASE_OUTPUT" >&2; fail "unit query status became $CASE_STATUS instead of 71"; }
grep -Fq '"classification":"unavailable"' "$CASE_OUTPUT" || fail 'failed unit query was treated as inactive'
assert_no_changing_calls

# Wrapper/helper payload drift blocks before any privilege call and never falls
# back to sudo.
ready_reset
printf '# drift\n' >>"$home/scripts/desktop/gsudo"
run_case wrapper-drift preflight
((CASE_STATUS == 1)) || { cat "$CASE_OUTPUT" >&2; fail "wrapper drift exited $CASE_STATUS"; }
assert_no_changing_calls
# Restore the exact reviewed test payload and digest for later execute cases.
sed -i '$d' "$home/scripts/desktop/gsudo"
gsudo_sha=$(sha256sum "$home/scripts/desktop/gsudo" | awk '{print $1}')

# On a clean HOME the privilege-wrapper stage has not executed yet. Exactly
# two absent installed payloads are expected-pending only when the repository
# copies still match the fixed production SHA values. Partial installation is
# a blocker and preflight still performs no wrapper call or write.
ready_reset
mv -- "$home/scripts/desktop/gsudo" "$test_root/installed-gsudo.saved"
mv -- "$home/scripts/desktop/fuzzel-askpass" "$test_root/installed-askpass.saved"
run_case wrapper-expected-pending preflight
((CASE_STATUS == 0)) || { cat "$CASE_OUTPUT" >&2; fail "clean-HOME wrapper preflight exited $CASE_STATUS"; }
grep -Fq '"classification":"expected-pending"' "$CASE_OUTPUT" || fail 'clean-HOME wrapper pair was not expected-pending'
assert_no_changing_calls
mv -- "$test_root/installed-gsudo.saved" "$home/scripts/desktop/gsudo"
run_case wrapper-partial preflight
((CASE_STATUS == 1)) || { cat "$CASE_OUTPUT" >&2; fail "partial wrapper installation exited $CASE_STATUS"; }
assert_no_changing_calls
mv -- "$test_root/installed-askpass.saved" "$home/scripts/desktop/fuzzel-askpass"

# Root-helper target safety is checked read-only. Symlink and hardlink targets
# are blockers; neither condition reaches gsudo.
ready_reset
rm -f -- "$target_root/etc/locale.conf"
ln -s /tmp/elsewhere "$target_root/etc/locale.conf"
run_case symlink-locale preflight
((CASE_STATUS == 1)) || { cat "$CASE_OUTPUT" >&2; fail "symlink locale target exited $CASE_STATUS"; }
assert_no_changing_calls

ready_reset
ln "$target_root/etc/environment" "$target_root/etc/environment.alias"
run_case hardlink-environment preflight
((CASE_STATUS == 1)) || { cat "$CASE_OUTPUT" >&2; fail "hardlink environment target exited $CASE_STATUS"; }
assert_no_changing_calls

# Full execute: prior disabled/inactive state is recorded, exact reviewed calls
# are made, fixed files are backed up and atomically converged, and no manual or
# deferred action executes.
ready_reset
for unit in systemd-timesyncd.service bluetooth.service power-profiles-daemon.service docker.service libvirtd.service; do
  mark_unit_unready system "$unit"
done
mark_unit_unready user dsearch.service
: >"$mock_state/wants-missing"
: >"$mock_state/network-absent"
: >"$mock_state/locales-missing"
run_case execute execute
((CASE_STATUS == 0)) || { cat "$CASE_OUTPUT" >&2; cat "$call_log" >&2; fail "baseline execute exited $CASE_STATUS"; }
for unit in systemd-timesyncd.service bluetooth.service power-profiles-daemon.service docker.service libvirtd.service; do
  grep -Fqx $'gsudo\t--\t'"$mock_bin/systemctl"$'\tenable\t--now\t'"$unit" "$call_log" || fail "missing exact root enable argv for $unit"
done
grep -Fqx $'systemctl\t--user\tadd-wants\tniri.service\tdms.service' "$call_log" || fail 'missing exact user add-wants argv'
grep -Fqx $'systemctl\t--user\tenable\t--now\tdsearch.service' "$call_log" || fail 'missing exact user enable argv'
grep -Fqx $'systemctl\t--user\tdaemon-reload' "$call_log" || fail 'missing exact user daemon-reload argv'
grep -Fqx $'gsudo\t--\t'"$mock_bin/virsh"$'\t--connect\tqemu:///system\tnet-define\t'"$target_root/usr/share/libvirt/networks/default.xml" "$call_log" || fail 'missing exact libvirt net-define argv'
grep -Fqx $'gsudo\t--\t'"$mock_bin/virsh"$'\t--connect\tqemu:///system\tnet-start\tdefault' "$call_log" || fail 'missing exact libvirt net-start argv'
grep -Fqx $'gsudo\t--\t'"$mock_bin/virsh"$'\t--connect\tqemu:///system\tnet-autostart\tdefault' "$call_log" || fail 'missing exact libvirt net-autostart argv'
grep -Fq $'gsudo\t--\t'"$tool"$'\t--root-helper\tlocale\t' "$call_log" || fail 'locale did not use the hidden helper through gsudo'
grep -Fq $'gsudo\t--\t'"$tool"$'\t--root-helper\tenvironment\t' "$call_log" || fail 'environment did not use the hidden helper through gsudo'
[[ $(grep -c '^en_US.UTF-8 UTF-8$' "$target_root/etc/locale.gen") == 1 ]] || fail 'en_US locale line was not exact once'
[[ $(grep -c '^zh_CN.UTF-8 UTF-8$' "$target_root/etc/locale.gen") == 1 ]] || fail 'zh_CN locale line was not exact once'
printf 'LANG=zh_CN.UTF-8\nLC_CTYPE=en_US.UTF-8\n' >"$test_root/expected-locale.conf"
cmp -s "$test_root/expected-locale.conf" "$target_root/etc/locale.conf" || fail 'locale.conf did not converge exactly'
grep -Fqx 'EDITOR=vim' "$target_root/etc/environment" || fail 'unrelated environment entry was lost'
grep -Fqx 'UNRELATED=value' "$target_root/etc/environment" || fail 'second unrelated environment entry was lost'
[[ $(grep -c '^QT_IM_MODULE=fcitx$' "$target_root/etc/environment") == 1 ]] || fail 'QT_IM_MODULE is not exact once'
[[ $(grep -c '^XMODIFIERS=@im=fcitx$' "$target_root/etc/environment") == 1 ]] || fail 'XMODIFIERS is not exact once'
! grep -q '^GTK_IM_MODULE' "$target_root/etc/environment" || fail 'execute introduced GTK_IM_MODULE'
state_file="$state_home/my-archlinux-setup/system-actions/$CASE_RUN_ID/actions.json"
[[ -f $state_file && ! -L $state_file ]] || fail 'incremental action state is missing'
[[ $(stat -c '%a' "$state_file") == 600 ]] || fail 'action state is not mode 600'
grep -Fq '"systemd-timesyncd.service"' "$state_file" || fail 'action state omitted fixed target evidence'
grep -Fq 'rollback_guidance' "$state_file" || fail 'action state omitted rollback guidance'
! grep -Fq 'EDITOR=vim' "$state_file" || fail 'action state leaked file content'
backup_root="$state_home/my-archlinux-setup/system-actions/$CASE_RUN_ID/backups"
for backup in etc/locale.gen etc/locale.conf etc/environment; do
  [[ -f $backup_root/$backup && $(stat -c '%a' "$backup_root/$backup") == 600 ]] || fail "private backup missing/unsafe: $backup"
done
! grep -Eq 'supergfx|snapper|grub|usermod|gpasswd|groupadd|reboot|supergfxctl' "$call_log" || fail 'manual/deferred/forbidden action executed'
grep -Fq '"classification":"manual"' "$CASE_OUTPUT" || fail 'manual actions were not explicitly reported'
grep -Fq '"classification":"deferred"' "$CASE_OUTPUT" || fail 'deferred actions were not explicitly reported'
! grep -q $'^sudo\t' "$call_log" || fail 'sudo fallback was invoked'

# A retry of the same orchestrator run must retain the first observed prior
# state and backup references. Re-querying an already converged target may
# prove idempotence, but it must not rewrite rollback evidence to "enabled" or
# discard the original file backup. The durable attempt advances exactly.
baseline_run_id=$CASE_RUN_ID
baseline_state="$test_root/baseline-system-actions-state.json"
cp -- "$state_file" "$baseline_state"
: >"$call_log"
run_case execute-same-run-retry execute "$effects" asus-amd-nvidia "$modules" \
  "$stage_modules" "$baseline_run_id" 2
((CASE_STATUS == 0)) || { cat "$CASE_OUTPUT" >&2; fail "same-run retry exited $CASE_STATUS"; }
python3 - "$baseline_state" "$state_file" <<'PY'
import json
import sys

before = json.load(open(sys.argv[1], encoding="utf-8"))
state = json.load(open(sys.argv[2], encoding="utf-8"))
assert state["attempt"] == 2
for action_id in ("time-sync-service", "locale-zh-cn", "fcitx-system-environment"):
    assert state["actions"][action_id]["prior"] == before["actions"][action_id]["prior"]
PY
! grep -q $'^gsudo\t' "$call_log" || { cat "$call_log" >&2; fail 'same-run retry repeated a root action'; }

# Rerun against matching prior state is idempotent for system/user enables,
# libvirt network and fixed files. daemon-reload remains the one reviewed,
# harmless user refresh; no root command is repeated.
: >"$call_log"
run_case execute-idempotent execute
((CASE_STATUS == 0)) || { cat "$CASE_OUTPUT" >&2; fail "idempotent execute exited $CASE_STATUS"; }
! grep -q $'^gsudo\t' "$call_log" || { cat "$call_log" >&2; fail 'idempotent rerun repeated a root action'; }
! grep -Eq $'^systemctl\t--user\t(add-wants|enable\t--now)' "$call_log" || fail 'idempotent rerun repeated a user enable'
[[ $(grep -c $'^systemctl\t--user\tdaemon-reload$' "$call_log") == 1 ]] || fail 'idempotent rerun did not limit daemon-reload to one call'

# Exact root failure status survives while independent later branches continue.
ready_reset
for unit in systemd-timesyncd.service docker.service libvirtd.service; do mark_unit_unready system "$unit"; done
printf 'systemd-timesyncd.service:37\n' >"$mock_state/gsudo-fail-unit"
run_case root-failure execute
((CASE_STATUS == 37)) || { cat "$CASE_OUTPUT" >&2; fail "root failure status became $CASE_STATUS instead of 37"; }
grep -Fq '"action_id":"time-sync-service"' "$CASE_OUTPUT" || fail 'failed root action was not reported'
grep -Fq $'gsudo\t--\t'"$mock_bin/systemctl"$'\tenable\t--now\tdocker.service' "$call_log" || fail 'independent Docker branch did not continue'
grep -Fq $'gsudo\t--\t'"$tool"$'\t--root-helper\tenvironment\t' "$call_log" || fail 'independent environment branch did not continue'
! grep -q $'^sudo\t' "$call_log" || fail 'root failure fell back to sudo'

# A failed libvirtd dependency skips only default-network mutation; locale and
# environment remain independent and execute, with the first exact status kept.
ready_reset
mark_unit_unready system libvirtd.service
: >"$mock_state/network-absent"
printf 'libvirtd.service:29\n' >"$mock_state/gsudo-fail-unit"
run_case dependency-failure execute
((CASE_STATUS == 29)) || { cat "$CASE_OUTPUT" >&2; fail "dependency failure status became $CASE_STATUS instead of 29"; }
grep -Fq '"action_id":"libvirt-default-network"' "$CASE_OUTPUT" || fail 'dependent network action was not reported'
grep -Fq '"classification":"skipped-dependency"' "$CASE_OUTPUT" || fail 'dependent network action was not skipped honestly'
! grep -q $'net-define\t' "$call_log" || fail 'dependent libvirt network mutated after service failure'
grep -Fq $'gsudo\t--\t'"$tool"$'\t--root-helper\tenvironment\t' "$call_log" || fail 'independent environment branch stopped after dependency failure'

# locale-gen failure is durable evidence, not rollback: exact status survives,
# the safely written files and original private backups remain, and the
# independent environment action still runs.
ready_reset
: >"$mock_state/locales-missing"
printf '53\n' >"$mock_state/locale-gen-fail"
run_case locale-failure execute
((CASE_STATUS == 53)) || { cat "$CASE_OUTPUT" >&2; fail "locale-gen status became $CASE_STATUS instead of 53"; }
grep -Fqx 'LANG=zh_CN.UTF-8' "$target_root/etc/locale.conf" || fail 'locale failure silently rolled locale.conf back'
locale_state="$state_home/my-archlinux-setup/system-actions/$CASE_RUN_ID/actions.json"
grep -Fq '"exit_status":53' "$locale_state" || fail 'locale-gen exact failure was absent from state'
evidence="$state_home/my-archlinux-setup/system-actions/$CASE_RUN_ID/evidence/locale-gen.txt"
[[ -f $evidence && $(stat -c '%a' "$evidence") == 600 ]] || fail 'locale-gen failure evidence is missing or unsafe'
grep -Fq 'fixture failure' "$evidence" || fail 'locale-gen failure evidence was not retained'
grep -Fqx 'QT_IM_MODULE=fcitx' "$target_root/etc/environment" || fail 'environment branch did not continue after locale failure'

# Hidden helper rejects a target-root mismatch and a stale TOCTOU hash without
# touching any fixed file. This interface offers no arbitrary path payload.
ready_reset
locale_before=$(sha256sum "$target_root/etc/locale.gen" "$target_root/etc/locale.conf" "$target_root/etc/environment")
stale_locale_sha=$(printf x | sha256sum | awk '{print $1}')
set +e
env HOME="$home" PATH="$mock_bin:/usr/bin:/bin" MOCK_CALL_LOG="$call_log" MOCK_STATE="$mock_state" \
  MOCK_COMMAND_DIR="$mock_bin" SYSTEM_ACTION_APPLY_TESTING=1 SYSTEM_ACTION_APPLY_TEST_ROOT="$target_root" \
  SYSTEM_ACTION_TEST_COMMAND_DIR="$mock_bin" \
  "$tool" --root-helper locale --target-root / --expected-locale-gen "sha256:$stale_locale_sha" \
    --expected-locale-conf absent >"$test_root/helper-root-mismatch.out" 2>&1
helper_status=$?
set -e
((helper_status == 2)) || { cat "$test_root/helper-root-mismatch.out" >&2; fail "root helper target mismatch exited $helper_status"; }
[[ $locale_before == "$(sha256sum "$target_root/etc/locale.gen" "$target_root/etc/locale.conf" "$target_root/etc/environment")" ]] || fail 'rejected helper target changed fixed files'

set +e
env HOME="$home" PATH="$mock_bin:/usr/bin:/bin" MOCK_CALL_LOG="$call_log" MOCK_STATE="$mock_state" \
  MOCK_COMMAND_DIR="$mock_bin" SYSTEM_ACTION_APPLY_TESTING=1 SYSTEM_ACTION_APPLY_TEST_ROOT="$target_root" \
  SYSTEM_ACTION_TEST_COMMAND_DIR="$mock_bin" \
  "$tool" --root-helper environment --target-root "$target_root" \
    --expected-environment sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    >"$test_root/helper-stale.out" 2>&1
helper_status=$?
set -e
((helper_status == 1)) || { cat "$test_root/helper-stale.out" >&2; fail "stale helper fingerprint exited $helper_status"; }
[[ $locale_before == "$(sha256sum "$target_root/etc/locale.gen" "$target_root/etc/locale.conf" "$target_root/etc/environment")" ]] || fail 'stale helper fingerprint changed fixed files'

# A successful execute followed by verify performs only read-only commands.
# Successful empty failed-unit JSON arrays are accepted, while manual and
# physical checks remain explicitly pending rather than being called passed.
ready_reset
run_case verify-setup execute
((CASE_STATUS == 0)) || { cat "$CASE_OUTPUT" >&2; fail "verify setup execute exited $CASE_STATUS"; }
: >"$call_log"
# Verify uses its own run id and may inspect current state without changing it.
run_case verify verify
((CASE_STATUS == 0)) || { cat "$CASE_OUTPUT" >&2; cat "$call_log" >&2; fail "baseline verify exited $CASE_STATUS"; }
assert_no_changing_calls
grep -Fq '"classification":"pending"' "$CASE_OUTPUT" || fail 'manual/physical verification was falsely called passed'
grep -Fq '"classification":"empty"' "$CASE_OUTPUT" || fail 'successful empty failed-unit arrays were not preserved'

# Unit drift is a semantic verification failure and never triggers repair.
key=$(printf '%s' docker.service | tr '/:@.' '____')
: >"$mock_state/inactive-system-$key"
: >"$call_log"
run_case verify-drift verify
((CASE_STATUS == 1)) || { cat "$CASE_OUTPUT" >&2; fail "verify drift exited $CASE_STATUS"; }
grep -Fq 'docker.service' "$CASE_OUTPUT" || fail 'verify drift omitted the unit'
assert_no_changing_calls

# Failed failed-unit queries preserve their exact status and are not treated as
# successful empty arrays.
ready_reset
printf '47\n' >"$mock_state/systemctl-fail-failed-user"
run_case failed-unit-query verify
((CASE_STATUS == 47)) || { cat "$CASE_OUTPUT" >&2; fail "failed-unit query status became $CASE_STATUS instead of 47"; }
! grep -Fq '"scope":"user","classification":"empty"' "$CASE_OUTPUT" || fail 'failed user-unit query was called empty'
assert_no_changing_calls

ready_reset
printf '[{"unit":"broken.service","active":"failed"}]\n' >"$mock_state/failed-array-system"
run_case nonempty-failed-units verify
((CASE_STATUS == 1)) || { cat "$CASE_OUTPUT" >&2; fail "nonempty failed-unit array exited $CASE_STATUS"; }
grep -Fq 'broken.service' "$CASE_OUTPUT" || fail 'failed unit identity was hidden'
assert_no_changing_calls

# Exact effect order and profile/module order are part of the reviewed payload.
tampered=$(python3 - "$test_root/effects.json" <<'PY'
import json,sys
items=json.load(open(sys.argv[1],encoding='utf-8'))
items[0],items[1]=items[1],items[0]
print(json.dumps(items,sort_keys=True,separators=(',',':')))
PY
)
ready_reset
run_case effect-order-drift preflight "$tampered"
((CASE_STATUS == 2)) || { cat "$CASE_OUTPUT" >&2; fail "effect order drift exited $CASE_STATUS"; }
assert_no_changing_calls

reversed_modules=$(python3 - "$test_root/modules" <<'PY'
import sys
values=open(sys.argv[1],encoding='utf-8').read().split(',')
print(','.join(reversed(values)))
PY
)
ready_reset
run_case module-order-drift preflight "$effects" asus-amd-nvidia "$reversed_modules" "$stage_modules"
((CASE_STATUS == 2)) || { cat "$CASE_OUTPUT" >&2; fail "module order drift exited $CASE_STATUS"; }
assert_no_changing_calls

# Malformed private state is never ignored. Use a fixed run id by invoking the
# adapter directly with the same strict environment after creating bad JSON.
ready_reset
bad_run=20260801T999999Z-badbadbadbad
bad_dir="$state_home/my-archlinux-setup/system-actions/$bad_run"
mkdir -p "$bad_dir"
chmod 700 "$state_home" "$state_home/my-archlinux-setup" "$state_home/my-archlinux-setup/system-actions" "$bad_dir"
printf '{bad json\n' >"$bad_dir/actions.json"
chmod 600 "$bad_dir/actions.json"
: >"$call_log"
set +e
env HOME="$home" XDG_STATE_HOME="$state_home" PATH="$mock_bin:/usr/bin:/bin" \
  MOCK_CALL_LOG="$call_log" MOCK_STATE="$mock_state" MOCK_INSTALLED="$test_root/installed" MOCK_COMMAND_DIR="$mock_bin" \
  SYSTEM_ACTION_APPLY_TESTING=1 SYSTEM_ACTION_APPLY_TEST_ROOT="$target_root" SYSTEM_ACTION_TEST_COMMAND_DIR="$mock_bin" \
  SYSTEM_ACTION_TEST_GSUDO_SHA256="$gsudo_sha" SYSTEM_ACTION_TEST_ASKPASS_SHA256="$askpass_sha" \
  SYSTEM_ACTION_EXPECTED_NETWORK_XML="$target_root/usr/share/libvirt/networks/default.xml" \
  FULL_ORCHESTRATOR_ACTION=execute FULL_ORCHESTRATOR_STAGE=system-actions FULL_ORCHESTRATOR_PROFILE=asus-amd-nvidia \
  FULL_ORCHESTRATOR_MODE=new FULL_ORCHESTRATOR_MODULES="$modules" FULL_ORCHESTRATOR_STAGE_MODULES="$stage_modules" \
  FULL_ORCHESTRATOR_EFFECTS_JSON="$effects" \
  FULL_ORCHESTRATOR_PLAN_FINGERPRINT=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
  FULL_ORCHESTRATOR_RUN_ID="$bad_run" FULL_ORCHESTRATOR_ATTEMPT=1 \
  "$tool" >"$test_root/malformed-state.out" 2>&1
malformed_status=$?
set -e
((malformed_status == 2)) || { cat "$test_root/malformed-state.out" >&2; fail "malformed state exited $malformed_status"; }
assert_no_changing_calls

# Ordinary CLI has no action/unit/path escape hatch.
set +e
"$tool" --action arbitrary --unit arbitrary.service --path /tmp/arbitrary >"$test_root/arbitrary-cli.out" 2>&1
cli_status=$?
set -e
((cli_status == 2)) || { cat "$test_root/arbitrary-cli.out" >&2; fail "arbitrary CLI exited $cli_status"; }

! grep -q $'^sudo\t' "$call_log" || fail 'a sudo fallback was observed'
# A writer landing after helper_snapshot but at the final replacement boundary
# must be detected without losing its bytes.
python3 - "$source_tool" "$test_root/system-final-race" <<'PYRACE'
import importlib.util
import os
from pathlib import Path
import sys

sys.dont_write_bytecode = True
path = Path(sys.argv[1])
root = Path(sys.argv[2])
target_root = root / "target"
parent = target_root / "etc"
parent.mkdir(parents=True, mode=0o700)
target_root.chmod(0o700)
parent.chmod(0o700)
target = parent / "environment"
target.write_bytes(b"BEFORE=1\n")
target.chmod(0o600)

spec = importlib.util.spec_from_file_location("system_action_final_race", path)
assert spec is not None and spec.loader is not None
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)
context = module.ExecutionContext(True, target_root, None, os.geteuid(), os.getegid())
prior = module.snapshot_fixed(context, Path("/etc/environment"), "environment", allow_missing=False)
concurrent = b"CONCURRENT=1\n"
raced = False


def audit(event, args):
    global raced
    if raced or event not in {"os.rename", "myarch.system-conditional-replace"}:
        return
    if len(args) < 2 or Path(os.fspath(args[1])) != target:
        return
    raced = True
    target.write_bytes(concurrent)
    target.chmod(0o600)


sys.addaudithook(audit)
failed_closed = False
try:
    module.atomic_replace_fixed(target, b"AFTER=1\n", prior, context)
except module.AdapterFailure:
    failed_closed = True
assert raced, "race injection did not reach the system commit boundary"
assert failed_closed, "system final-window race was not rejected"
assert target.read_bytes() == concurrent, "concurrent system target content was overwritten"

new_target = parent / "new-environment"
new_prior = module.snapshot_fixed(
    context,
    Path("/etc/new-environment"),
    "new environment",
    allow_missing=True,
)
assert not new_prior.exists
new_concurrent = b"NEW_CONCURRENT=1\n"
new_raced = False


def audit_create(event, args):
    global new_raced
    if new_raced or event != "myarch.system-conditional-replace":
        return
    if len(args) < 2 or Path(os.fspath(args[1])) != new_target:
        return
    new_raced = True
    new_target.write_bytes(new_concurrent)
    new_target.chmod(0o600)


sys.addaudithook(audit_create)
new_failed_closed = False
try:
    module.atomic_replace_fixed(new_target, b"NEW_AFTER=1\n", new_prior, context)
except module.AdapterFailure:
    new_failed_closed = True
assert new_raced, "absent system target race did not reach commit"
assert new_failed_closed, "concurrent system target creation was not rejected"
assert new_target.read_bytes() == new_concurrent
PYRACE

printf 'system action apply tests: PASS\n'
