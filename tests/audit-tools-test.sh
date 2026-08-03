#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT

fail() {
  printf 'audit tools test failed: %s\n' "$*" >&2
  exit 1
}

home="$test_root/success-home"
state="$test_root/success-state"
mkdir -p \
  "$home/.config/nvim" \
  "$home/.config/google-chrome" \
  "$home/scripts/demo/.git/refs/heads" \
  "$home/scripts/demo/.ssh"
printf '%s%s\n' 'api_' 'key = "FAKE_AUDIT_SECRET_VALUE"' >"$home/.config/nvim/init.lua"
printf '%s\n' '/home/example/private-project' >>"$home/.config/nvim/init.lua"
printf '%s\n' 'FAKE_MEDIA_SECRET_VALUE' >"$home/.config/nvim/screenshot.png"
printf '%s\n' 'FAKE_BROWSER_VALUE' >"$home/.config/google-chrome/profile.data"
printf '%s\n' '#!/usr/bin/env bash' 'printf test' >"$home/scripts/example.sh"
printf '%s\n' 'private-branch-metadata' >"$home/scripts/demo/.git/refs/heads/private-name"
printf '%s\n' 'private-key-metadata' >"$home/scripts/demo/.ssh/id_ed25519"
printf '%s\n' 'TOKEN=metadata-only-but-sensitive-name' >"$home/scripts/demo/.env"
printf '%s\n' '{"token":"metadata-only-but-sensitive-name"}' >"$home/scripts/demo/credentials.json"
chmod 755 "$home/scripts/example.sh"

HOME="$home" XDG_STATE_HOME="$state" "$root/installer/audit-candidates.sh" >/dev/null
metadata_report=$(find "$state/my-archlinux-setup/audits" -maxdepth 1 -type f -name 'candidate-metadata-*.md' -print -quit)
[[ -n "$metadata_report" ]] || fail "metadata audit report was not created"
[[ $(stat -c '%a' "$metadata_report") == 600 ]] || fail "metadata report is not mode 600"
[[ $(stat -c '%a' "$state/my-archlinux-setup") == 700 ]] || fail "audit project state is not mode 700"
[[ $(stat -c '%a' "$state/my-archlinux-setup/audits") == 700 ]] || fail "audit directory is not mode 700"
grep -Fq '.config/nvim/init.lua' "$metadata_report" || fail "metadata report omitted safe candidate path"
grep -Fq '.config/google-chrome' "$metadata_report" || fail "metadata report omitted excluded-root record"
! grep -Fq 'profile.data' "$metadata_report" || fail "metadata report traversed an excluded browser root"
! grep -Fq 'FAKE_AUDIT_SECRET_VALUE' "$metadata_report" || fail "metadata report leaked file content"
! grep -Fq 'scripts/demo/.git' "$metadata_report" || fail "metadata report traversed nested script VCS state"
! grep -Fq 'scripts/demo/.ssh' "$metadata_report" || fail "metadata report traversed nested script SSH state"
! grep -Fq 'scripts/demo/.env' "$metadata_report" || fail "metadata report listed credential-shaped script metadata"
! grep -Fq 'scripts/demo/credentials.json' "$metadata_report" || fail "metadata report listed credential metadata"
HOME="$home" XDG_STATE_HOME="$state" "$root/installer/audit-candidates.sh" >/dev/null
metadata_count=$(find "$state/my-archlinux-setup/audits" -maxdepth 1 -type f -name 'candidate-metadata-*.md' | wc -l)
((metadata_count == 2)) || fail "same-second metadata audits overwrote one another"

HOME="$home" XDG_STATE_HOME="$state" "$root/installer/audit-content.sh" >/dev/null
content_report=$(find "$state/my-archlinux-setup/audits" -maxdepth 1 -type f -name 'candidate-content-risk-*.md' -print -quit)
[[ -n "$content_report" ]] || fail "content-risk report was not created"
[[ $(stat -c '%a' "$content_report") == 600 ]] || fail "content-risk report is not mode 600"
grep -Fq '.config/nvim/init.lua' "$content_report" || fail "content-risk report omitted reviewed candidate"
grep -Fq 'possible-secret-pattern' "$content_report" || fail "content-risk report missed secret marker category"
grep -Fq 'personal-path-or-identity' "$content_report" || fail "content-risk report missed personal path category"
! grep -Fq 'FAKE_AUDIT_SECRET_VALUE' "$content_report" || fail "content-risk report leaked a matched value"
! grep -Fq 'screenshot.png' "$content_report" || fail "content-risk audit read/listed excluded media"

selected_home="$test_root/selected-home"
selected_state="$test_root/selected-state"
selected_list="$test_root/selected-files.txt"
mkdir -p \
  "$selected_home/.config/niri/dms" \
  "$selected_home/.config/hypr/conf" \
  "$selected_home/.config/fcitx5/conf" \
  "$selected_home/.config/DankMaterialShell"
printf '%s\n' 'selected niri value' >"$selected_home/.config/niri/dms/binds.kdl"
printf '%s\n' 'UNLISTED_PRIVATE_VALUE' >"$selected_home/.config/niri/dms/unlisted.kdl"
printf '%s\n' 'selected hypr value' >"$selected_home/.config/hypr/conf/autostart.lua"
printf '%s\n' 'selected backup value' >"$selected_home/.config/fcitx5/conf/classicui.conf.bak-test"
printf '%s\n' 'selected DMS value' >"$selected_home/.config/DankMaterialShell/settings.json.bak-test"
printf '%s\n' \
  '.config/niri/dms/binds.kdl' \
  '.config/hypr/conf/autostart.lua' \
  '.config/fcitx5/conf/classicui.conf.bak-test' \
  '.config/DankMaterialShell/settings.json.bak-test' >"$selected_list"

HOME="$selected_home" XDG_STATE_HOME="$selected_state" \
  "$root/installer/audit-content.sh" --files-from "$selected_list" >/dev/null
selected_report=$(find "$selected_state/my-archlinux-setup/audits" -maxdepth 1 -type f \
  -name 'candidate-content-risk-*.md' -print -quit)
[[ -n "$selected_report" ]] || fail "selected content-risk report was not created"
[[ $(stat -c '%a' "$selected_report") == 600 ]] || fail "selected report is not mode 600"
grep -Fq 'Selected files: 4' "$selected_report" || fail "selected report omitted the exact file count"
for relative in \
  '.config/niri/dms/binds.kdl' \
  '.config/hypr/conf/autostart.lua' \
  '.config/fcitx5/conf/classicui.conf.bak-test' \
  '.config/DankMaterialShell/settings.json.bak-test'; do
  grep -Fq "$relative" "$selected_report" || fail "selected report omitted $relative"
done
! grep -Fq 'unlisted.kdl' "$selected_report" || fail "selected audit traversed an unlisted file"
! grep -Fq 'UNLISTED_PRIVATE_VALUE' "$selected_report" || fail "selected audit leaked unlisted content"

for invalid_case in empty outside duplicate symlink symlink_parent; do
  invalid_state="$test_root/selected-invalid-$invalid_case-state"
  invalid_list="$test_root/selected-invalid-$invalid_case.txt"
  case "$invalid_case" in
    empty)
      : >"$invalid_list"
      ;;
    outside)
      printf '%s\n' '.config/kitty/kitty.conf' >"$invalid_list"
      ;;
    duplicate)
      printf '%s\n' '.config/niri/dms/binds.kdl' '.config/niri/dms/binds.kdl' >"$invalid_list"
      ;;
    symlink)
      ln -s -- binds.kdl "$selected_home/.config/niri/dms/link.kdl"
      printf '%s\n' '.config/niri/dms/link.kdl' >"$invalid_list"
      ;;
    symlink_parent)
      mkdir -p "$selected_home/.config/niri/real-dms"
      printf '%s\n' 'selected through parent' >"$selected_home/.config/niri/real-dms/parent-link.kdl"
      ln -s -- real-dms "$selected_home/.config/niri/linked-dms"
      printf '%s\n' '.config/niri/linked-dms/parent-link.kdl' >"$invalid_list"
      ;;
  esac
  set +e
  HOME="$selected_home" XDG_STATE_HOME="$invalid_state" \
    "$root/installer/audit-content.sh" --files-from "$invalid_list" \
    >"$test_root/selected-invalid-$invalid_case.out" \
    2>"$test_root/selected-invalid-$invalid_case.err"
  invalid_status=$?
  set -e
  ((invalid_status != 0)) || fail "selected audit accepted $invalid_case input"
  invalid_report_dir="$invalid_state/my-archlinux-setup/audits"
  if [[ -d "$invalid_report_dir" ]] && \
    find "$invalid_report_dir" -maxdepth 1 -type f -name 'candidate-*.md' -print -quit | grep -q .; then
    fail "selected audit published a report for $invalid_case input"
  fi
done

for tool in audit-candidates.sh audit-content.sh; do
  link_home="$test_root/link-${tool%.sh}-home"
  link_state_root="$test_root/link-${tool%.sh}-state/my-archlinux-setup"
  link_outside="$test_root/link-${tool%.sh}-outside"
  mkdir -p "$link_home/.config/nvim" "$link_state_root" "$link_outside"
  printf 'return {}\n' >"$link_home/.config/nvim/init.lua"
  chmod 755 "$link_outside"
  ln -s -- "$link_outside" "$link_state_root/audits"
  set +e
  HOME="$link_home" XDG_STATE_HOME="$test_root/link-${tool%.sh}-state" \
    "$root/installer/$tool" >"$test_root/link-$tool.out" 2>"$test_root/link-$tool.err"
  link_status=$?
  set -e
  ((link_status != 0)) || fail "$tool accepted a symlinked audit state directory"
  [[ $(stat -c '%a' "$link_outside") == 755 ]] || fail "$tool changed a symlinked audit target mode"
  if find "$link_outside" -mindepth 1 -print -quit | grep -q .; then
    fail "$tool wrote through a symlinked audit state directory"
  fi
done

mock_bin="$test_root/mock-bin"
mkdir -p "$mock_bin"
cat >"$mock_bin/find" <<'MOCK'
#!/usr/bin/env bash
printf 'simulated find failure\n' >&2
exit 42
MOCK
chmod 755 "$mock_bin/find"

for tool in audit-candidates.sh audit-content.sh; do
  failure_home="$test_root/failure-${tool%.sh}-home"
  failure_state="$test_root/failure-${tool%.sh}-state"
  mkdir -p "$failure_home/.config/nvim"
  printf 'return {}\n' >"$failure_home/.config/nvim/init.lua"
  set +e
  HOME="$failure_home" XDG_STATE_HOME="$failure_state" PATH="$mock_bin:$PATH" \
    "$root/installer/$tool" >"$test_root/$tool.out" 2>"$test_root/$tool.err"
  status=$?
  set -e
  ((status == 42)) || fail "$tool did not preserve find exit 42 (got $status)"
  report_dir="$failure_state/my-archlinux-setup/audits"
  if [[ -d "$report_dir" ]] && find "$report_dir" -maxdepth 1 -type f -name 'candidate-*.md' -print -quit | grep -q .; then
    fail "$tool left a completed-looking report after find failure"
  fi
done

grep_mock_bin="$test_root/grep-mock-bin"
mkdir -p "$grep_mock_bin"
cat >"$grep_mock_bin/grep" <<'MOCK'
#!/usr/bin/env bash
printf 'simulated grep failure\n' >&2
exit 43
MOCK
chmod 755 "$grep_mock_bin/grep"
grep_failure_home="$test_root/grep-failure-home"
grep_failure_state="$test_root/grep-failure-state"
mkdir -p "$grep_failure_home/.config/nvim"
printf 'return {}\n' >"$grep_failure_home/.config/nvim/init.lua"
set +e
HOME="$grep_failure_home" XDG_STATE_HOME="$grep_failure_state" PATH="$grep_mock_bin:$PATH" \
  "$root/installer/audit-content.sh" >"$test_root/grep-failure.out" 2>"$test_root/grep-failure.err"
grep_status=$?
set -e
((grep_status == 43)) || fail "audit-content.sh did not preserve grep exit 43 (got $grep_status)"
grep_report_dir="$grep_failure_state/my-archlinux-setup/audits"
if [[ -d "$grep_report_dir" ]] && find "$grep_report_dir" -maxdepth 1 -type f -name 'candidate-*.md' -print -quit | grep -q .; then
  fail "audit-content.sh left a completed-looking report after grep failure"
fi

printf 'Audit tool checks passed.\n'
