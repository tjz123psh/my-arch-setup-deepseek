#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT
export MY_ARCH_SETUP_LEGACY_COMPONENT_TESTING=1 MY_ARCH_SETUP_LEGACY_TEST_ROOT="$test_root"

fail() {
  printf 'module selection test failed: %s\n' "$*" >&2
  exit 1
}

run_plan() {
  local name="$1"
  shift
  local home="$test_root/$name-home"
  mkdir -p "$home"
  HOME="$home" XDG_STATE_HOME="$home/.local/state" \
    "$root/installer/install.sh" "$@" --plan >"$test_root/$name.out" 2>&1
  [[ ! -e "$home/.local/state/my-archlinux-setup" ]] || fail "$name plan wrote installer state"
}

assert_contains() {
  local name="$1" expected="$2"
  grep -Fq -- "$expected" "$test_root/$name.out" || fail "$name omitted: $expected"
}

assert_not_contains() {
  local name="$1" unexpected="$2"
  if grep -Fq -- "$unexpected" "$test_root/$name.out"; then
    fail "$name unexpectedly contained: $unexpected"
  fi
}

run_invalid_plan() {
  local name="$1" expected="$2"
  shift 2
  local home="$test_root/$name-home" status
  mkdir -p "$home"
  set +e
  HOME="$home" XDG_STATE_HOME="$home/.local/state" \
    "$root/installer/install.sh" "$@" --plan >"$test_root/$name.out" 2>&1
  status=$?
  set -e
  ((status != 0)) || fail "$name unexpectedly succeeded"
  assert_contains "$name" "$expected"
  [[ ! -e "$home/.local/state/my-archlinux-setup" ]] || fail "$name invalid plan wrote installer state"
}

run_plan asus-default --profile asus-amd-nvidia
assert_contains asus-default 'module selection source: profile defaults'
assert_contains asus-default 'module: wm-niri state=selected origin=default availability=available'
assert_contains asus-default 'module: wm-hyprland state=selected origin=default availability=available'
assert_contains asus-default 'module: personal-scripts state=selected origin=default availability=available'
assert_contains asus-default 'module: personal-autostart state=selected origin=default availability=available'
assert_contains asus-default 'module: asus-hardware state=selected origin=default availability=available'
assert_contains asus-default 'module: personal-user-services state=selected origin=default availability=available'
assert_not_contains asus-default 'module: dms-greetd '
assert_not_contains asus-default 'module: dms-niri-greeter '
assert_contains asus-default 'module: daily-apps state=selected origin=default availability=available'
assert_contains asus-default 'apply readiness: blocked by non-executable selected modules'
assert_contains asus-default 'official packages: 15 reviewed package(s), not installed in plan mode'
assert_contains asus-default 'configuration targets: 171 audited file mapping(s)'
assert_contains asus-default 'scripts/maintenance/term-menu'
assert_contains asus-default 'scripts/package/paru-ui'
assert_contains asus-default '.config/autostart/FlClash.desktop'
assert_contains asus-default '.config/rog/rog-control-center.cfg'
assert_contains asus-default '.config/systemd/user/openai-oauth.service'

asus_both_modules='desktop-shared,input-fcitx-rime,developer-editor,wm-niri,wm-hyprland'
run_plan asus-both --profile asus-amd-nvidia --modules "$asus_both_modules"
assert_contains asus-both 'module selection source: explicit --modules'
assert_contains asus-both 'module: wm-niri state=selected origin=explicit availability=available'
assert_contains asus-both 'module: wm-hyprland state=selected origin=explicit availability=available'
assert_not_contains asus-both 'module: dms-greetd '
assert_contains asus-both 'module: archlinuxcn-trust state=selected origin=dependency availability=available'
assert_contains asus-both 'apply readiness: ready for implemented component actions'
assert_contains asus-both 'official packages: 15 reviewed package(s), not installed in plan mode'
assert_contains asus-both 'configuration targets: 124 audited file mapping(s)'

asus_script_modules='desktop-shared,input-fcitx-rime,developer-editor,wm-niri,wm-hyprland,personal-scripts'
run_plan asus-scripts --profile asus-amd-nvidia --modules "$asus_script_modules"
assert_contains asus-scripts 'module: personal-scripts state=selected origin=explicit availability=available'
assert_contains asus-scripts 'configuration targets: 163 audited file mapping(s)'
assert_contains asus-scripts 'scripts/maintenance/term-menu'
assert_contains asus-scripts 'scripts/package/paru-ui'

asus_full_modules='desktop-shared,input-fcitx-rime,developer-editor,wm-niri,wm-hyprland,personal-scripts,personal-autostart,asus-hardware,personal-user-services'
run_plan asus-full --profile asus-amd-nvidia --modules "$asus_full_modules"
assert_contains asus-full 'module: personal-autostart state=selected origin=explicit availability=available'
assert_contains asus-full 'module: asus-hardware state=selected origin=explicit availability=available'
assert_contains asus-full 'module: personal-user-services state=selected origin=explicit availability=available'
assert_contains asus-full 'configuration targets: 169 audited file mapping(s)'
assert_contains asus-full '.config/autostart/FlClash.desktop'
assert_contains asus-full '.config/rog/rog-control-center.cfg'
assert_contains asus-full '.config/systemd/user/vellum.service'

run_plan asus-niri --profile asus-amd-nvidia \
  --modules desktop-shared,input-fcitx-rime,developer-editor,wm-niri
assert_contains asus-niri 'module: wm-hyprland state=disabled origin=default-overridden availability=available'
assert_contains asus-niri 'official packages: 14 reviewed package(s), not installed in plan mode'
assert_contains asus-niri 'configuration targets: 108 audited file mapping(s)'
assert_not_contains asus-niri '[wm-hyprland] hyprland —'
assert_not_contains asus-niri '.config/hypr/hyprland.lua'
assert_contains asus-niri '.config/niri/config.kdl'
assert_contains asus-niri '.config/niri/scripts/niri-force-kill-window'
assert_contains asus-niri '.config/DankMaterialShell/firefox.css'
assert_contains asus-niri '.config/dankcal/ui-settings.json'
assert_contains asus-niri '.local/share/fcitx5/rime/default.custom.yaml'
assert_contains asus-niri 'scripts/desktop/niri-quit'
assert_not_contains asus-niri 'scripts/desktop/hypr-magnifier'
assert_not_contains asus-niri '.config/hypr/scripts/hypr-keys'

run_plan asus-hypr --profile asus-amd-nvidia \
  --modules desktop-shared,input-fcitx-rime,developer-editor,wm-hyprland
assert_contains asus-hypr 'module: wm-niri state=disabled origin=default-overridden availability=available'
assert_contains asus-hypr 'official packages: 14 reviewed package(s), not installed in plan mode'
assert_contains asus-hypr 'configuration targets: 109 audited file mapping(s)'
assert_not_contains asus-hypr '[wm-niri] niri —'
assert_not_contains asus-hypr '.config/niri/config.kdl'
assert_contains asus-hypr '.config/hypr/hyprland.lua'
assert_contains asus-hypr '.config/hypr/scripts/hypr-keys'
assert_contains asus-hypr '.config/DankMaterialShell/firefox.css'
assert_contains asus-hypr '.config/danksearch/config.toml'
assert_contains asus-hypr '.local/share/fcitx5/rime/rime_ice.custom.yaml'
assert_contains asus-hypr 'scripts/desktop/hypr-magnifier'
assert_not_contains asus-hypr 'scripts/desktop/niri-quit'
assert_not_contains asus-hypr '.config/niri/scripts/niri-force-kill-window'

run_plan desktop-default --profile desktop-amd
assert_contains desktop-default 'module: wm-niri state=selected origin=default availability=available'
assert_contains desktop-default 'module: virtualization state=selected origin=default availability=planning'
assert_contains desktop-default 'apply readiness: blocked by non-executable selected modules'
assert_contains desktop-default 'module: wm-hyprland state=disabled origin=default-disabled availability=available'
assert_contains desktop-default 'official packages: 14 reviewed package(s), not installed in plan mode'
assert_contains desktop-default 'configuration targets: 103 audited file mapping(s)'
assert_not_contains desktop-default '[wm-hyprland] hyprland —'
assert_not_contains desktop-default '.config/hypr/hyprland.lua'
assert_contains desktop-default '.config/DankMaterialShell/settings.json'
assert_contains desktop-default '.config/DankMaterialShell/plugins/ShorinScreenrec/StartupCheck.qml'

run_plan desktop-both --profile desktop-amd --modules "$asus_both_modules"
assert_contains desktop-both 'official packages: 15 reviewed package(s), not installed in plan mode'
assert_contains desktop-both 'configuration targets: 124 audited file mapping(s)'
assert_contains desktop-both '[wm-hyprland] hyprland —'

run_plan vm-default --profile vm
assert_contains vm-default 'configuration scope: vm-v1'
assert_contains vm-default 'module: wm-niri state=selected origin=default availability=available'
assert_contains vm-default 'module: wm-hyprland state=disabled origin=default-disabled availability=available'
assert_contains vm-default 'module: input-fcitx-rime state=selected origin=default availability=available'
assert_contains vm-default 'module: archlinuxcn-trust state=selected origin=dependency availability=available'
assert_contains vm-default 'apply readiness: ready for implemented component actions'
assert_contains vm-default 'official packages: 4 reviewed package(s), not installed in plan mode'
assert_contains vm-default 'configuration targets: 35 audited file mapping(s)'
assert_contains vm-default 'config/vm/home/.config/niri/config.kdl -> .config/niri/config.kdl'
assert_contains vm-default 'config/vm/home/.config/fuzzel/fuzzel.ini -> .config/fuzzel/fuzzel.ini'
assert_not_contains vm-default '.config/hypr/hyprland.lua'

run_plan vm-hypr --profile vm --modules desktop-shared,input-fcitx-rime,wm-hyprland
assert_contains vm-hypr 'module: wm-niri state=disabled origin=default-overridden availability=available'
assert_contains vm-hypr 'module: wm-hyprland state=selected origin=explicit availability=available'
assert_contains vm-hypr 'configuration targets: 35 audited file mapping(s)'
assert_contains vm-hypr 'config/vm/home/.config/hypr/hyprland.lua -> .config/hypr/hyprland.lua'
assert_not_contains vm-hypr '.config/niri/config.kdl'

run_invalid_plan unknown 'unknown module in --modules: not-a-module' \
  --profile asus-amd-nvidia --modules desktop-shared,not-a-module
run_invalid_plan duplicate 'duplicate module in --modules: wm-niri' \
  --profile asus-amd-nvidia --modules desktop-shared,wm-niri,wm-niri
run_invalid_plan greeter-not-main-path 'module is not supported by profile asus-amd-nvidia: dms-greetd' \
  --profile asus-amd-nvidia --modules desktop-shared,dms-greetd
run_invalid_plan malformed-list 'invalid empty entry in --modules' \
  --profile asus-amd-nvidia --modules desktop-shared,,wm-niri

noninteractive_home="$test_root/noninteractive-home"
mkdir -p "$noninteractive_home"
set +e
HOME="$noninteractive_home" XDG_STATE_HOME="$noninteractive_home/.local/state" \
  "$root/installer/install.sh" --profile desktop-amd --apply-config --confirm-config \
  >"$test_root/noninteractive.out" 2>&1
noninteractive_status=$?
set -e
((noninteractive_status != 0)) || fail 'non-interactive apply inferred the profile defaults'
grep -Fq -- '--confirm-config requires an explicit --modules selection' \
  "$test_root/noninteractive.out" || fail 'non-interactive module requirement was not explained'
[[ ! -e "$noninteractive_home/.local/state/my-archlinux-setup" ]] || \
  fail 'rejected non-interactive apply wrote installer state'
[[ ! -e "$noninteractive_home/.config" ]] || fail 'rejected non-interactive apply deployed config'

module_link_project="$test_root/module-link-project"
module_link_home="$test_root/module-link-home"
mkdir -p "$module_link_project/installer" "$module_link_project/manifests" "$module_link_home"
cp -- "$root/installer/install.sh" "$module_link_project/installer/install.sh"
cp -- "$root/manifests/modules.tsv" "$test_root/external-modules.tsv"
ln -s -- "$test_root/external-modules.tsv" "$module_link_project/manifests/modules.tsv"
set +e
HOME="$module_link_home" XDG_STATE_HOME="$module_link_home/.local/state" \
  "$module_link_project/installer/install.sh" --profile vm --plan \
  >"$test_root/module-link.out" 2>&1
module_link_status=$?
set -e
((module_link_status != 0)) || fail 'symlinked module registry was accepted'
grep -Fq -- 'approved source path contains a symlink: manifests/modules.tsv' \
  "$test_root/module-link.out" || fail 'symlinked module registry failure was not explained'
[[ ! -e "$module_link_home/.local/state/my-archlinux-setup" ]] || \
  fail 'symlinked module registry plan wrote installer state'

profile_link_project="$test_root/profile-link-project"
profile_link_home="$test_root/profile-link-home"
mkdir -p "$profile_link_project/installer" "$profile_link_project/manifests" "$profile_link_home"
cp -- "$root/installer/install.sh" "$profile_link_project/installer/install.sh"
cp -- "$root/manifests/modules.tsv" "$profile_link_project/manifests/modules.tsv"
cp -- "$root/manifests/profile-modules.tsv" "$test_root/external-profile-modules.tsv"
ln -s -- "$test_root/external-profile-modules.tsv" "$profile_link_project/manifests/profile-modules.tsv"
set +e
HOME="$profile_link_home" XDG_STATE_HOME="$profile_link_home/.local/state" \
  "$profile_link_project/installer/install.sh" --profile vm --plan \
  >"$test_root/profile-link.out" 2>&1
profile_link_status=$?
set -e
((profile_link_status != 0)) || fail 'symlinked profile module manifest was accepted'
grep -Fq -- 'approved source path contains a symlink: manifests/profile-modules.tsv' \
  "$test_root/profile-link.out" || fail 'symlinked profile module failure was not explained'
[[ ! -e "$profile_link_home/.local/state/my-archlinux-setup" ]] || \
  fail 'symlinked profile module plan wrote installer state'

missing_scope_project="$test_root/missing-scope-project"
missing_scope_home="$test_root/missing-scope-home"
mkdir -p "$missing_scope_project/installer" "$missing_scope_project/manifests" "$missing_scope_home"
cp -- "$root/installer/install.sh" "$missing_scope_project/installer/install.sh"
cp -a -- "$root/config" "$missing_scope_project/config"
cp -- "$root/manifests/"*.tsv "$missing_scope_project/manifests/"
sed -i 's/^physical-v1\t/other-v1\t/' "$missing_scope_project/manifests/config-mappings.tsv"
set +e
HOME="$missing_scope_home" XDG_STATE_HOME="$missing_scope_home/.local/state" \
  "$missing_scope_project/installer/install.sh" --profile desktop-amd --plan \
  >"$test_root/missing-scope.out" 2>&1
missing_scope_status=$?
set -e
((missing_scope_status != 0)) || fail 'missing selected config scope was treated as an empty healthy result'
grep -Fq -- 'configuration mapping has no entries for scope physical-v1' \
  "$test_root/missing-scope.out" || fail 'missing config scope failure was not explained'
[[ ! -e "$missing_scope_home/.local/state/my-archlinux-setup" ]] || \
  fail 'missing config scope plan wrote installer state'

piped_home="$test_root/piped-default-home"
mkdir -p "$piped_home"
set +e
printf 'apply-config\n' | HOME="$piped_home" XDG_STATE_HOME="$piped_home/.local/state" \
  "$root/installer/install.sh" --profile desktop-amd --apply-config \
  >"$test_root/piped-default.out" 2>&1
piped_status=$?
set -e
((piped_status != 0)) || fail 'piped apply inferred profile-default modules'
grep -Fq -- 'non-interactive apply requires an explicit --modules selection' \
  "$test_root/piped-default.out" || fail 'piped non-interactive module requirement was not explained'
[[ ! -e "$piped_home/.local/state/my-archlinux-setup" ]] || \
  fail 'rejected piped apply wrote installer state'
[[ ! -e "$piped_home/.config" ]] || fail 'rejected piped apply deployed config'

printf 'Module selection checks passed.\n'
