#!/usr/bin/env bash
# installer-behavior-test.sh - behavioral tests for the installer core
# (review P6): module selection matrix (4 desktops x 2 machine roles),
# progress context binding, config-deploy symlink safety, and failure
# propagation contracts. Each check must be able to FAIL (no swallowed
# errors, no fabricated passes).
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
utils="$root/scripts/00-utils.sh"

pass=0
fail=0

check() { # check <desc> <rc> <expected_rc>
  local desc="$1" rc="$2" expected="$3"
  if [[ "$rc" -eq "$expected" ]]; then
    pass=$((pass + 1))
    printf '  ok   %s\n' "$desc"
  else
    fail=$((fail + 1))
    printf '  FAIL %s (rc=%s expected=%s)\n' "$desc" "$rc" "$expected"
  fi
}

# --- 1. module_selected matrix ---------------------------------------------
# source 00-utils in a subshell with controlled env; module_selected is pure.
modsel() { # modsel <machine> <desktop> <module>  -> echoes 0/1
  MACHINE_TYPE="$1" DESKTOP_ENV="$2" bash -c '
    source "$0" >/dev/null 2>&1
    module_selected x "$1" && echo 0 || echo 1
  ' "$utils" "$3"
}

echo "== module selection matrix =="
# vmware-host only on physical
[[ "$(modsel physical both virtualization-vmware-host)" == "0" ]]; check "vmware-host selected on physical" $? 0
[[ "$(modsel vm both virtualization-vmware-host)" == "1" ]]; check "vmware-host excluded on vm" $? 0
# vmware-guest only on vm
[[ "$(modsel vm both virtualization-vmware-guest)" == "0" ]]; check "vmware-guest selected on vm" $? 0
[[ "$(modsel physical both virtualization-vmware-guest)" == "1" ]]; check "vmware-guest excluded on physical" $? 0
# hardware modules excluded from general path on BOTH machine types
for m in graphics-amd graphics-nvidia hardware-tools asus-hardware; do
  [[ "$(modsel physical both "$m")" == "1" ]]; check "hardware module $m excluded (physical)" $? 0
  [[ "$(modsel vm both "$m")" == "1" ]]; check "hardware module $m excluded (vm)" $? 0
done
# P1-1: config context - hardware config rows deploy on physical, skip on vm
modsel_cfg() { # modsel_cfg <machine> <desktop> <module>  -> echoes 0/1
  MACHINE_TYPE="$1" DESKTOP_ENV="$2" bash -c '
    source "$0" >/dev/null 2>&1
    module_selected x "$1" config && echo 0 || echo 1
  ' "$utils" "$3"
}
[[ "$(modsel_cfg physical both asus-hardware)" == "0" ]]; check "asus-hardware config selected on physical" $? 0
[[ "$(modsel_cfg vm both asus-hardware)" == "1" ]]; check "asus-hardware config excluded on vm" $? 0
# desktop wm modules follow DESKTOP_ENV (niri/both/none; pure hyprland removed
# 2026-08-08 - module_selected's both-fallback for unknown values is a pure
# function safety net, install.sh rejects hyprland/unknown fail-closed)
[[ "$(modsel vm niri wm-hyprland)" == "1" ]]; check "wm-hyprland excluded on niri" $? 0
[[ "$(modsel vm niri wm-niri)" == "0" ]]; check "wm-niri selected on niri" $? 0
[[ "$(modsel vm both wm-niri)" == "0" ]]; check "wm-niri selected on both" $? 0
[[ "$(modsel vm both wm-hyprland)" == "0" ]]; check "wm-hyprland selected on both" $? 0
[[ "$(modsel vm none wm-niri)" == "1" ]]; check "wm-niri excluded on none" $? 0
[[ "$(modsel vm none wm-hyprland)" == "1" ]]; check "wm-hyprland excluded on none" $? 0
[[ "$(modsel vm none desktop-shared)" == "0" ]]; check "desktop-shared selected on none" $? 0

# --- 2. progress context binding -------------------------------------------
echo "== progress context binding =="
# NOTE: 00-utils resolves PROJECT_DIR from its own path and marks it readonly,
# so PROGRESS_CONTEXT_FILE points at <repo>/.install_progress. The test
# re-assigns PROGRESS_CONTEXT_FILE (not readonly) to a sandbox path right
# after sourcing, so it never touches the real repo resume file.
run_ctx() { # run_ctx <machine> <desktop>; echoes rc
  local rc=0
  PROJECT_DIR="$tmp_ctx" MACHINE_TYPE="$1" DESKTOP_ENV="$2" TARGET_USER=pang \
    bash -c 'source "$0" >/dev/null 2>&1
             PROGRESS_CONTEXT_FILE="$PROGRESS_TEST_FILE"
             setup_progress' "$utils" >/dev/null 2>&1 || rc=$?
  echo "$rc"
}
tmp_ctx="$(mktemp -d)"
export PROGRESS_TEST_FILE="$tmp_ctx/progress"
# write context + a done module, same as the installer would
PROJECT_DIR="$tmp_ctx" MACHINE_TYPE=vm DESKTOP_ENV=niri TARGET_USER=pang \
  bash -c '
    source "$0" >/dev/null 2>&1
    PROGRESS_CONTEXT_FILE="$PROGRESS_TEST_FILE"
    setup_progress
    mark_done 01-mirror.sh
  ' "$utils" >/dev/null 2>&1
check "setup_progress writes context header" $? 0
# same context resumes fine
[[ "$(run_ctx vm niri)" == "0" ]]; check "same context resumes" $? 0
# different desktop must refuse to resume (exit 1)
[[ "$(run_ctx vm both)" == "1" ]]; check "different desktop refuses resume (exit 1)" $? 0
# different machine must refuse
[[ "$(run_ctx physical niri)" == "1" ]]; check "different machine refuses resume (exit 1)" $? 0
# the sandbox file exists and the real repo file was never touched
if [[ -f "$tmp_ctx/progress" ]] && [[ ! -e "$root/.install_progress" ]]; then
  pass=$((pass + 1)); echo "  ok   sandboxed progress file used; repo .install_progress untouched"
else
  fail=$((fail + 1)); echo "  FAIL progress test touched the real repo .install_progress"
fi
rm -rf "$tmp_ctx"

# --- 3. config deploy symlink safety ----------------------------------------
echo "== config deploy symlink safety =="
tmp_home="$(mktemp -d)"
outside="$(mktemp -d)"
mkdir -p "$outside/evil"
echo "do-not-touch" > "$outside/evil/compromised"
# a symlinked .config pointing outside HOME must be refused
ln -s "$outside" "$tmp_home/.config"
# minimal mapping file: one row targeting .config/fish/config.fish
minmap="$(mktemp)"
printf 'physical-v1\tdesktop-shared\tconfig/home/.config/fish/config.fish\t.config/fish/config.fish\t644\n' > "$minmap"
# NOTE: 00-utils derives TARGET_HOME from $HOME when non-root, so HOME must
# point at the isolated sandbox or the deploy would touch the real HOME.
out="$(HOME="$tmp_home" MAPPINGS="$minmap" CONFIG_SRC="$root/config" TARGET_USER=pang \
  SCOPE=physical-v1 MACHINE_TYPE=vm DESKTOP_ENV=niri \
  bash "$root/scripts/07-config.sh" 2>&1 || true)"
# P1-3: parse the structured CONFIG_RESULT line and compare the EXACT counter
# (a bare substring "skipped: 1" would falsely match "skipped: 114").
skipped_n="$(printf '%s\n' "$out" | sed -n 's/.*CONFIG_RESULT deployed=[0-9][0-9]* skipped=\([0-9][0-9]*\).*/\1/p' | tail -1)"
# the deploy must have refused exactly one row (skipped=1) and the outside
# file must be intact
if [[ "$out" == *"refusing to deploy"* ]] && [[ "${skipped_n}" == "1" ]] \
   && [[ "$(cat "$outside/evil/compromised")" == "do-not-touch" ]]; then
  pass=$((pass + 1)); echo "  ok   symlinked .config refused; outside file untouched"
else
  fail=$((fail + 1)); echo "  FAIL symlinked .config not safely refused"
  echo "--- output ---"; echo "$out" | tail -5
fi
rm -rf "$tmp_home" "$outside" "$minmap"

# --- 4. failure propagation contracts ----------------------------------------
echo "== failure propagation contracts =="
# 06-aur: a failing final `pacman -U` must exit nonzero (C-03). We stub run()
# to fail and source the install block by extracting it would be fragile, so
# verify the *contract*: grep the step for the required exit path.
if grep -q 'error "bulk AUR install failed' "$root/scripts/06-aur.sh" \
   && grep -q 'exit 1' "$root/scripts/06-aur.sh"; then
  pass=$((pass + 1)); echo "  ok   AUR bulk install failure exits nonzero"
else
  fail=$((fail + 1)); echo "  FAIL AUR bulk install failure not propagated"
fi
# 04-drivers: required driver failure must exit nonzero (C-04)
if grep -q 'required driver package(s) failed; aborting' "$root/scripts/04-drivers.sh" \
   && grep -q 'exit 1' "$root/scripts/04-drivers.sh"; then
  pass=$((pass + 1)); echo "  ok   required driver failure exits nonzero"
else
  fail=$((fail + 1)); echo "  FAIL required driver failure not propagated"
fi
# 03-packages: missing base precondition must abort
if grep -q 'base precondition(s) missing; fix the base install' "$root/scripts/03-packages.sh" \
   && grep -q 'exit 1' "$root/scripts/03-packages.sh"; then
  pass=$((pass + 1)); echo "  ok   missing verify precondition aborts"
else
  fail=$((fail + 1)); echo "  FAIL missing precondition not aborted"
fi
# install.sh: missing module script must die, not warn-and-continue
if grep -q 'Missing required script' "$root/install.sh" && grep -q 'exit 1' "$root/install.sh"; then
  pass=$((pass + 1)); echo "  ok   missing module script aborts"
else
  fail=$((fail + 1)); echo "  FAIL missing module script not aborted"
fi
# install.sh: sudoers grant is scoped to pacman, not ALL (C-01)
if grep -q 'NOPASSWD: /usr/bin/pacman' "$root/install.sh" \
   && ! grep -q 'NOPASSWD: ALL' "$root/install.sh"; then
  pass=$((pass + 1)); echo "  ok   sudoers grant scoped to pacman"
else
  fail=$((fail + 1)); echo "  FAIL sudoers grant not scoped"
fi
# install.sh: the scoped pacman NOPASSWD drop-in must be created in the
# strap.sh (root) path too. 06-aur runs makepkg via `runuser -u TARGET_USER`
# and `makepkg -s` calls `sudo -k pacman` to install missing runtime deps;
# without the grant and with no tty, sudo dies with "a terminal is required"
# and every recipe needing an extra dep fails (found 2026-08-10 fresh VM:
# fuzzel-ime-git/fcft+tllist, google-chrome/ttf-liberation,
# linuxqq-appimage+wechat-appimage/fuse2).
if grep -q 'NOPASSWD: /usr/bin/pacman' "$root/install.sh" \
   && grep -q '> "${SUDOERS_DROPIN}"' "$root/install.sh"; then
  pass=$((pass + 1)); echo "  ok   sudoers drop-in created on the root (strap) path"
else
  fail=$((fail + 1)); echo "  FAIL sudoers drop-in missing on the root (strap) path"
fi
# install.sh: EXIT trap cleans the drop-in
if grep -q 'trap cleanup_install_sudoers EXIT' "$root/install.sh"; then
  pass=$((pass + 1)); echo "  ok   EXIT trap registered"
else
  fail=$((fail + 1)); echo "  FAIL EXIT trap not registered"
fi
# 07-config: symlink refusal code present
if grep -q 'refusing to deploy' "$root/scripts/07-config.sh"; then
  pass=$((pass + 1)); echo "  ok   config deploy refuses symlinked paths"
else
  fail=$((fail + 1)); echo "  FAIL symlink refusal missing"
fi
# 07-config: on the root/strap path the deploy must chown the intermediate
# DIRECTORIES, not just the files. Only chowning files left ~/.config/niri
# and ~/.config/systemd/user root-owned, so niri-vmtest-gen (config.kdl.vmtest)
# and `systemctl --user enable dms.service` (creating .wants dirs) failed on
# a fresh VM install 2026-08-10 and 08-services aborted.
if grep -q 'd="$(dirname "${d}")"' "$root/scripts/07-config.sh" \
   && grep -q 'chown "${TARGET_USER}:${TARGET_USER}" "${d}"' "$root/scripts/07-config.sh"; then
  pass=$((pass + 1)); echo "  ok   07-config chowns deployed directory path"
else
  fail=$((fail + 1)); echo "  FAIL 07-config does not chown deployed directory path"
fi
# 06-aur: the strap.sh (root) path must chown the makepkg build dir AFTER
# copying the recipe. GNU `cp -a source/. dest` applies the SOURCE dir's
# ownership/mode to DEST, so a pre-copy chown is overwritten and makepkg dies
# with "no write permission to $BUILDDIR" (found 2026-08-10 fresh VM install;
# the non-root path was unaffected). Structural check: in install_recipe the
# chown line must appear after the cp -a line.
cp_line=$(grep -n 'cp -a "\${dir}/\."' "$root/scripts/06-aur.sh" | head -1 | cut -d: -f1)
chown_line=$(grep -n 'chown -R "\${TARGET_USER}' "$root/scripts/06-aur.sh" | head -1 | cut -d: -f1)
if [[ -n "$cp_line" && -n "$chown_line" && "$chown_line" -gt "$cp_line" ]]; then
  pass=$((pass + 1)); echo "  ok   06-aur chowns build dir after cp -a (lines $cp_line < $chown_line)"
else
  fail=$((fail + 1)); echo "  FAIL 06-aur chown not after cp -a (cp=$cp_line chown=$chown_line)"
fi
# install.sh: -d hyprland (removed pure-Hyprland entry) must exit nonzero
rc=0
bash "$root/install.sh" -d hyprland -t vm >/dev/null 2>&1 || rc=$?
if [[ "$rc" -ne 0 ]]; then
  pass=$((pass + 1)); echo "  ok   -d hyprland rejected (rc=$rc)"
else
  fail=$((fail + 1)); echo "  FAIL -d hyprland not rejected"
fi
# install.sh: unknown desktop value must fail closed (not silently both)
rc=0
bash "$root/install.sh" -d bogus -t vm >/dev/null 2>&1 || rc=$?
if [[ "$rc" -ne 0 ]]; then
  pass=$((pass + 1)); echo "  ok   -d bogus rejected fail-closed (rc=$rc)"
else
  fail=$((fail + 1)); echo "  FAIL -d bogus not rejected"
fi
# install.sh: flag args (-y / --force-refresh) must be consumed by parse_args.
# Regression: before 2026-08-10 these cases lacked `shift`, so $1 never
# advanced and the while loop spun at 100% CPU (fresh-VM install hang).
# --help exits during parse_args, so a working parse returns 0 quickly;
# a looping parse hits the timeout and returns 124.
for flag in -y --force-refresh; do
  rc=0
  timeout 10 bash "$root/install.sh" -t vm -d both "$flag" --help >/dev/null 2>&1 || rc=$?
  if [[ "$rc" -eq 0 ]]; then
    pass=$((pass + 1)); echo "  ok   parse_args consumes $flag (rc=0, no hang)"
  else
    fail=$((fail + 1)); echo "  FAIL parse_args loops on $flag (rc=$rc)"
  fi
done

# --- 8. vmware graphics workaround (upstream Hyprland#7658) ---------------
echo "== vmware graphics workaround =="
# is_vmware_guest: pure predicate, SYSTEMD_DETECT_VIRT injectable
is_vm() { # is_vm <detect-virt-result> -> echoes 0/1
  SYSTEMD_DETECT_VIRT="$1" bash -c '
    source "$0" >/dev/null 2>&1
    is_vmware_guest && echo 0 || echo 1
  ' "$utils"
}
[[ "$(is_vm vmware)" == "0" ]]; check "is_vmware_guest true on vmware" $? 0
[[ "$(is_vm kvm)" == "1" ]]; check "is_vmware_guest false on kvm" $? 0
[[ "$(is_vm none)" == "1" ]]; check "is_vmware_guest false on bare metal" $? 0
# apply_vmware_graphics_workaround: writes to the given env file, idempotent
apply_wa() { # apply_wa <detect-virt-result> <env-file>
  SYSTEMD_DETECT_VIRT="$1" bash -c '
    source "$0" >/dev/null 2>&1
    apply_vmware_graphics_workaround "$1"
  ' "$utils" "$2"
}
wa_tf=$(mktemp); : > "$wa_tf"
apply_wa vmware "$wa_tf"
grep -q '^LIBGL_ALWAYS_SOFTWARE=1$' "$wa_tf"; check "vmware: writes LIBGL_ALWAYS_SOFTWARE=1" $? 0
apply_wa vmware "$wa_tf"
[[ "$(grep -c '^LIBGL_ALWAYS_SOFTWARE=1$' "$wa_tf")" == "1" ]]; check "vmware: idempotent (single line)" $? 0
: > "$wa_tf"
apply_wa kvm "$wa_tf"
[[ ! -s "$wa_tf" ]]; check "non-vmware: no write to env file" $? 0
rm -f "$wa_tf"
# 09-settings: the workaround call site exists and is gated by is_vmware_guest
if grep -q 'apply_vmware_graphics_workaround' "$root/scripts/09-settings.sh" \
   && grep -q 'is_vmware_guest' "$root/scripts/09-settings.sh"; then
  pass=$((pass + 1)); echo "  ok   09-settings applies workaround gated on is_vmware_guest"
else
  fail=$((fail + 1)); echo "  FAIL 09-settings workaround gate missing"
fi

echo
echo "installer behavior tests: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
