#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
desktop_modules="desktop-shared,input-fcitx-rime,developer-editor,wm-niri"
vm_modules="desktop-shared,input-fcitx-rime,wm-niri"
test_home=$(mktemp -d)
trap 'rm -rf -- "$test_home"' EXIT
export MY_ARCH_SETUP_LEGACY_COMPONENT_TESTING=1 MY_ARCH_SETUP_LEGACY_TEST_ROOT="$test_home"

run_install() {
  printf 'apply-config\n' | HOME="$test_home" XDG_STATE_HOME="$test_home/.local/state" \
    "$root/installer/install.sh" --profile desktop-amd --modules "$desktop_modules" "$@"
}

run_install --apply-config
test -f "$test_home/.config/fuzzel/fuzzel.ini"
test -f "$test_home/.config/niri/dms/binds.kdl"
test -f "$test_home/.config/niri/scripts/niri-force-kill-window"
test ! -e "$test_home/.config/hypr"
test -f "$test_home/.config/DankMaterialShell/firefox.css"
test -f "$test_home/.config/DankMaterialShell/plugins/ShorinScreenrec/StartupCheck.qml"
test "$(find "$test_home/.config/DankMaterialShell" -type f | wc -l)" = 8
test -f "$test_home/.config/dankcal/ui-settings.json"
test -f "$test_home/.config/danksearch/config.toml"
test -f "$test_home/.config/dgop/colors.json"
test -f "$test_home/.config/matugen/dms/configs/fuzzel.toml"
test -f "$test_home/.config/matugen/templates/fuzzel.ini"
test -f "$test_home/.local/share/fcitx5/rime/default.custom.yaml"
test -f "$test_home/.local/share/fcitx5/rime/rime_ice.custom.yaml"
test "$(stat -c '%a' "$test_home/.local/share/fcitx5/rime/default.custom.yaml")" = 644
test "$(stat -c '%a' "$test_home/.config/fcitx5/config")" = 600
test -x "$test_home/scripts/desktop/fuzzel-askpass"
test -x "$test_home/scripts/desktop/gsudo"
test -x "$test_home/scripts/desktop/screenshot-sound"
test -x "$test_home/scripts/desktop/niri-keys"
test -x "$test_home/scripts/desktop/niri-quit"
grep -F "\$HOME/scripts/desktop/niri-keys" "$test_home/.config/niri/dms/keybinds.kdl" >/dev/null
if grep -F "\$HOME/.local/bin/niri-keys" "$test_home/.config/niri/dms/keybinds.kdl" >/dev/null; then
  printf 'niri keybinding still references non-restored .local/bin entrypoint\n' >&2
  exit 1
fi
test ! -e "$test_home/scripts/desktop/hypr-keys"
test ! -e "$test_home/scripts/desktop/hypr-magnifier"
test "$(stat -c '%a' "$test_home/scripts/maintenance/lib/ui.sh")" = 644
HOME="$test_home" "$test_home/scripts/desktop/gsudo" --help >/dev/null
HOME="$test_home" "$test_home/scripts/desktop/screenshot-sound" --help >/dev/null
HOME="$test_home" "$test_home/scripts/desktop/niri-keys" --print >/dev/null
HOME="$test_home" "$test_home/scripts/desktop/niri-quit" --help >/dev/null
test -f "$test_home/.local/state/my-archlinux-setup/config-state"
test "$(stat -c '%a' "$test_home/.local/state/my-archlinux-setup/config-state")" = 600
test "$(stat -c '%a' "$test_home/.local/state/my-archlinux-setup")" = 700
test "$(stat -c '%a' "$test_home/.local/state/my-archlinux-setup/backups")" = 700
test "$(stat -c '%a' "$test_home/.config/fuzzel/fuzzel.ini")" = 644
test "$(stat -c '%a' "$test_home/.config/niri/scripts/niri-force-kill-window")" = 755
test "$(find "$test_home/.config" -type f | wc -l)" = 93
if find "$test_home/.local/state/my-archlinux-setup/backups" -mindepth 1 -type d -print -quit | grep -q .; then
  printf 'expected no backup directory when no target changed\n' >&2
  exit 1
fi

chmod 700 "$test_home/.config/niri/scripts/niri-force-kill-window"
run_install --mode reconcile --apply-config
mode_backup=$(find "$test_home/.local/state/my-archlinux-setup/backups" \
  -path '*/.config/niri/scripts/niri-force-kill-window' -type f -print -quit)
test -n "$mode_backup"
test "$(stat -c '%a' "$mode_backup")" = 700
test "$(stat -c '%a' "$test_home/.config/niri/scripts/niri-force-kill-window")" = 755

hypr_home="$test_home/hypr-only-home"
mkdir -p "$hypr_home"
HOME="$hypr_home" XDG_STATE_HOME="$hypr_home/.local/state" \
  "$root/installer/install.sh" --profile desktop-amd --modules desktop-shared,input-fcitx-rime,wm-hyprland \
  --apply-config --confirm-config >/dev/null
test -f "$hypr_home/.config/fuzzel/fuzzel.ini"
test -f "$hypr_home/.config/hypr/hyprland.lua"
test -f "$hypr_home/.config/hypr/scripts/hypr-keys"
test ! -e "$hypr_home/.config/niri"
test -f "$hypr_home/.config/DankMaterialShell/firefox.css"
test -f "$hypr_home/.local/share/fcitx5/rime/default.custom.yaml"
test -x "$hypr_home/scripts/desktop/hypr-keys"
test -x "$hypr_home/scripts/desktop/hypr-magnifier"
test ! -e "$hypr_home/scripts/desktop/niri-keys"
test ! -e "$hypr_home/scripts/desktop/niri-quit"
HOME="$hypr_home" "$hypr_home/scripts/desktop/hypr-keys" --print >/dev/null
HOME="$hypr_home" "$hypr_home/scripts/desktop/hypr-magnifier" --help >/dev/null
grep -F "\$HOME/scripts/desktop/hypr-keys" "$hypr_home/.config/hypr/conf/keybinds.lua" >/dev/null
if grep -F "\$HOME/.local/bin/hypr-keys" "$hypr_home/.config/hypr/conf/keybinds.lua" >/dev/null; then
  printf 'hypr keybinding still references non-restored .local/bin entrypoint\n' >&2
  exit 1
fi
test "$(stat -c '%a' "$hypr_home/.config/hypr/scripts/fake-overview.sh")" = 755
test "$(stat -c '%a' "$hypr_home/.config/hypr/scripts/hypr-force-kill-window")" = 755
test "$(stat -c '%a' "$hypr_home/.config/hypr/scripts/hypr-keys")" = 755
test "$(find "$hypr_home/.config" -type f | wc -l)" = 52

both_home="$test_home/both-wm-home"
mkdir -p "$both_home"
HOME="$both_home" XDG_STATE_HOME="$both_home/.local/state" \
  "$root/installer/install.sh" --profile desktop-amd \
  --modules desktop-shared,input-fcitx-rime,wm-niri,wm-hyprland --apply-config --confirm-config >/dev/null
test -f "$both_home/.config/niri/config.kdl"
test -f "$both_home/.config/niri/scripts/niri-force-kill-window"
test -f "$both_home/.config/hypr/hyprland.lua"
test -f "$both_home/.config/hypr/scripts/hypr-keys"
test -f "$both_home/.config/DankMaterialShell/firefox.css"
test "$(find "$both_home/.config/DankMaterialShell" -type f | wc -l)" = 8
test -f "$both_home/.config/matugen/templates/fuzzel.ini"
test -f "$both_home/.local/share/fcitx5/rime/rime_ice.custom.yaml"
test "$(find "$both_home/scripts/desktop" -maxdepth 1 -type f | wc -l)" = 7
test -f "$both_home/scripts/maintenance/lib/ui.sh"
test "$(find "$both_home/.config" -type f | wc -l)" = 65

asus_default_home="$test_home/asus-default-home"
mkdir -p "$asus_default_home"
printf 'apply-config\n' | HOME="$asus_default_home" XDG_STATE_HOME="$asus_default_home/.local/state" \
  "$root/installer/install.sh" --profile asus-amd-nvidia \
  --modules desktop-shared,input-fcitx-rime,developer-editor,wm-niri,wm-hyprland,personal-scripts,personal-autostart,asus-hardware,personal-user-services \
  --apply-config >/dev/null
test -f "$asus_default_home/.config/autostart/FlClash.desktop"
test -f "$asus_default_home/.config/rog/rog-control-center.cfg"
test -f "$asus_default_home/.config/systemd/user/openai-oauth.service"
test -f "$asus_default_home/.config/systemd/user/penpot-mcp.service"
test -f "$asus_default_home/.config/systemd/user/vellum-tray.service"
test -f "$asus_default_home/.config/systemd/user/vellum.service"
for personal_file in \
  "$asus_default_home/.config/autostart/FlClash.desktop" \
  "$asus_default_home/.config/rog/rog-control-center.cfg" \
  "$asus_default_home/.config/systemd/user/openai-oauth.service" \
  "$asus_default_home/.config/systemd/user/penpot-mcp.service" \
  "$asus_default_home/.config/systemd/user/vellum-tray.service" \
  "$asus_default_home/.config/systemd/user/vellum.service"; do
  test "$(stat -c '%a' "$personal_file")" = 644
done

printf 'local override\n' >"$test_home/.config/fuzzel/colors.ini"
run_install --mode reconcile --apply-config

cmp -s -- "$root/config/home/.config/fuzzel/colors.ini" "$test_home/.config/fuzzel/colors.ini"
backup_file=$(find "$test_home/.local/state/my-archlinux-setup/backups" -path '*/.config/fuzzel/colors.ini' -type f -print -quit)
test -n "$backup_file"
test "$(<"$backup_file")" = 'local override'

if printf 'wrong\n' | HOME="$test_home" XDG_STATE_HOME="$test_home/.local/state" \
  "$root/installer/install.sh" --profile desktop-amd --modules "$desktop_modules" --apply-config >/dev/null 2>&1; then
  printf 'expected cancellation to fail\n' >&2
  exit 1
fi

vm_home="$test_home/vm-niri-home"
mkdir -p "$vm_home"
printf 'apply-config
' | HOME="$vm_home" XDG_STATE_HOME="$vm_home/.local/state" \
  "$root/installer/install.sh" --profile vm --modules "$vm_modules" --apply-config >/dev/null
cmp -s -- "$root/config/vm/home/.config/niri/config.kdl" "$vm_home/.config/niri/config.kdl"
cmp -s -- "$root/config/vm/home/.config/fuzzel/fuzzel.ini" "$vm_home/.config/fuzzel/fuzzel.ini"
cmp -s -- "$root/config/vm/home/.config/DankMaterialShell/settings.json" "$vm_home/.config/DankMaterialShell/settings.json"
test -f "$vm_home/.config/fcitx5/config"
test -f "$vm_home/.local/share/fcitx5/rime/rime_ice.custom.yaml"
test -x "$vm_home/scripts/desktop/gsudo"
test ! -e "$vm_home/.config/hypr"
test "$(find "$vm_home" -type f ! -path '*/.local/state/*' | wc -l)" = 35

vm_hypr_home="$test_home/vm-hypr-home"
mkdir -p "$vm_hypr_home"
HOME="$vm_hypr_home" XDG_STATE_HOME="$vm_hypr_home/.local/state" \
  "$root/installer/install.sh" --profile vm \
  --modules desktop-shared,input-fcitx-rime,wm-hyprland --apply-config --confirm-config >/dev/null
cmp -s -- "$root/config/vm/home/.config/hypr/hyprland.lua" "$vm_hypr_home/.config/hypr/hyprland.lua"
test ! -e "$vm_hypr_home/.config/niri"
test "$(find "$vm_hypr_home" -type f ! -path '*/.local/state/*' | wc -l)" = 35

vm_both_home="$test_home/vm-both-home"
mkdir -p "$vm_both_home"
HOME="$vm_both_home" XDG_STATE_HOME="$vm_both_home/.local/state" \
  "$root/installer/install.sh" --profile vm \
  --modules desktop-shared,input-fcitx-rime,wm-niri,wm-hyprland --apply-config --confirm-config >/dev/null
test -f "$vm_both_home/.config/niri/config.kdl"
test -f "$vm_both_home/.config/hypr/hyprland.lua"
test "$(find "$vm_both_home" -type f ! -path '*/.local/state/*' | wc -l)" = 36

mkdir -p "$test_home/.config/fuzzel"
rm -f -- "$test_home/.config/fuzzel/colors.ini"
ln -s /tmp "$test_home/.config/fuzzel/colors.ini"
if printf 'apply-config\n' | HOME="$test_home" XDG_STATE_HOME="$test_home/.local/state" \
  "$root/installer/install.sh" --profile desktop-amd --modules "$desktop_modules" --apply-config >/dev/null 2>&1; then
  printf 'expected symlinked config target to fail\n' >&2
  exit 1
fi

rm -f -- "$test_home/.config/fuzzel/colors.ini"
rm -f -- "$test_home/.local/share/fcitx5/rime/default.custom.yaml"
ln -s /tmp "$test_home/.local/share/fcitx5/rime/default.custom.yaml"
if printf 'apply-config\n' | HOME="$test_home" XDG_STATE_HOME="$test_home/.local/state" \
  "$root/installer/install.sh" --profile desktop-amd --modules "$desktop_modules" --apply-config >/dev/null 2>&1; then
  printf 'expected symlinked Rime data target to fail\n' >&2
  exit 1
fi
rm -f -- "$test_home/.local/share/fcitx5/rime/default.custom.yaml"

rm -f -- "$test_home/scripts/desktop/gsudo"
ln -s /tmp "$test_home/scripts/desktop/gsudo"
if printf 'apply-config\n' | HOME="$test_home" XDG_STATE_HOME="$test_home/.local/state" \
  "$root/installer/install.sh" --profile desktop-amd --modules "$desktop_modules" --apply-config >/dev/null 2>&1; then
  printf 'expected symlinked personal script target to fail\n' >&2
  exit 1
fi
rm -f -- "$test_home/scripts/desktop/gsudo"

outside_file="$test_home/outside-hardlink-target"
printf 'do not replace through hardlink\n' >"$outside_file"
ln -- "$outside_file" "$test_home/.config/fuzzel/colors.ini"
if printf 'apply-config\n' | HOME="$test_home" XDG_STATE_HOME="$test_home/.local/state" \
  "$root/installer/install.sh" --profile desktop-amd --modules "$desktop_modules" --apply-config >/dev/null 2>&1; then
  printf 'expected hard-linked config target to fail\n' >&2
  exit 1
fi
test "$(<"$outside_file")" = 'do not replace through hardlink'

rm -f -- "$test_home/.config/fuzzel/colors.ini" "$outside_file"
mkdir -- "$test_home/.config/fuzzel/colors.ini"
if printf 'apply-config\n' | HOME="$test_home" XDG_STATE_HOME="$test_home/.local/state" \
  "$root/installer/install.sh" --profile desktop-amd --modules "$desktop_modules" --apply-config >/dev/null 2>&1; then
  printf 'expected non-regular config target to fail\n' >&2
  exit 1
fi
rmdir -- "$test_home/.config/fuzzel/colors.ini"

HOME="$test_home" XDG_STATE_HOME="$test_home/.local/state" \
  "$root/installer/install.sh" --profile desktop-amd --modules "$desktop_modules" --apply-config --confirm-config \
  </dev/null >/dev/null
test -f "$test_home/.config/fuzzel/colors.ini"

fresh_home="$test_home/fresh-cancel-home"
mkdir -p "$fresh_home"
set +e
printf 'cancel\n' | HOME="$fresh_home" XDG_STATE_HOME="$fresh_home/.local/state" \
  "$root/installer/install.sh" --profile desktop-amd --modules "$desktop_modules" --apply-config \
  >"$test_home/fresh-cancel.out" 2>&1
fresh_cancel_status=$?
set -e
((fresh_cancel_status != 0)) || { printf 'fresh config cancellation unexpectedly succeeded\n' >&2; exit 1; }
[[ ! -e "$fresh_home/.local/state/my-archlinux-setup" ]] || { printf 'fresh config cancellation wrote installer state\n' >&2; exit 1; }

fixture="$test_home/manifest-symlink-project"
mkdir -p "$fixture/installer" "$fixture/manifests"
cp -- "$root/installer/install.sh" "$fixture/installer/install.sh"
cp -a -- "$root/config" "$fixture/config"
cp -- "$root/manifests/config-mappings.tsv" "$test_home/external-config-mappings.tsv"
cp -- "$root/manifests/official-packages.tsv" "$fixture/manifests/official-packages.tsv"
cp -- "$root/manifests/modules.tsv" "$fixture/manifests/modules.tsv"
cp -- "$root/manifests/profile-modules.tsv" "$fixture/manifests/profile-modules.tsv"
ln -s -- "$test_home/external-config-mappings.tsv" "$fixture/manifests/config-mappings.tsv"
fixture_home="$test_home/manifest-symlink-home"
mkdir -p "$fixture_home"
set +e
HOME="$fixture_home" XDG_STATE_HOME="$fixture_home/.local/state" \
  "$fixture/installer/install.sh" --profile desktop-amd --modules "$desktop_modules" --apply-config --confirm-config \
  >"$test_home/manifest-symlink.out" 2>&1
fixture_status=$?
set -e
((fixture_status != 0)) || { printf 'symlinked config manifest was accepted\n' >&2; exit 1; }
[[ ! -e "$fixture_home/.local/state/my-archlinux-setup" ]] || { printf 'symlinked config manifest wrote installer state\n' >&2; exit 1; }
[[ ! -e "$fixture_home/.config" ]] || { printf 'symlinked config manifest deployed targets\n' >&2; exit 1; }

state_link_home="$test_home/state-link-home"
state_link_root="$state_link_home/.local/state/my-archlinux-setup"
state_link_outside="$test_home/state-link-outside"
mkdir -p "$state_link_root" "$state_link_outside"
chmod 755 "$state_link_outside"
ln -s -- "$state_link_outside" "$state_link_root/backups"
set +e
HOME="$state_link_home" XDG_STATE_HOME="$state_link_home/.local/state" \
  "$root/installer/install.sh" --profile desktop-amd --modules "$desktop_modules" --apply-config --confirm-config \
  >"$test_home/state-link.out" 2>&1
state_link_status=$?
set -e
((state_link_status != 0)) || { printf 'symlinked backup state directory was accepted\n' >&2; exit 1; }
[[ $(stat -c '%a' "$state_link_outside") == 755 ]] || { printf 'symlinked backup target mode was changed\n' >&2; exit 1; }
[[ ! -e "$state_link_home/.config" ]] || { printf 'symlinked backup state case deployed config\n' >&2; exit 1; }

printf 'Config deployment checks passed.\n'
