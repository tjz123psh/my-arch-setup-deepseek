#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tool="$root/installer/aur-build.py"
[[ -x $tool && ! -L $tool ]] || { printf '%s\n' 'AUR build tool is missing or unsafe' >&2; exit 1; }

test_root=$(mktemp -d -p /var/tmp myarch-aur-build-test.XXXXXX)
trap 'rm -rf -- "$test_root"' EXIT
home="$test_root/home"
mock_bin="$test_root/mock-bin"
mkdir -p "$home/scripts/desktop" "$mock_bin"

fail() {
  printf 'AUR build test failed: %s\n' "$*" >&2
  exit 1
}

cat >"$home/scripts/desktop/gsudo" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ ${1:-} == -- ]] && shift
printf 'gsudo' >>"$MOCK_CALL_LOG"; printf '\t%s' "$@" >>"$MOCK_CALL_LOG"; printf '\n' >>"$MOCK_CALL_LOG"
exec "$@"
MOCK
cat >"$home/scripts/desktop/fuzzel-askpass" <<'MOCK'
#!/usr/bin/env bash
exit 97
MOCK
cat >"$mock_bin/makepkg" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'makepkg' >>"$MOCK_CALL_LOG"; printf '\t%s' "$@" >>"$MOCK_CALL_LOG"; printf '\n' >>"$MOCK_CALL_LOG"
exit "${MOCK_MAKEPKG_STATUS:-0}"
MOCK
cat >"$mock_bin/mkarchroot" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'mkarchroot' >>"$MOCK_CALL_LOG"; printf '\t%s' "$@" >>"$MOCK_CALL_LOG"; printf '\n' >>"$MOCK_CALL_LOG"
status=${MOCK_MKARCHROOT_STATUS:-0}
root=''
for argument in "$@"; do
  [[ $argument == */root ]] && root=$argument
done
[[ -n $root ]] || exit 96
[[ -d ${root%/root} ]] || { printf 'fixture: working-directory parent is missing\n' >&2; exit 255; }
if ((status != 0)); then
  if [[ ${MOCK_MKARCHROOT_PARTIAL:-0} == 1 ]]; then
    mkdir -p "$root/usr/bin"
    printf 'partial\n' >"$root/usr/bin/pacman"
  fi
  exit "$status"
fi
mkdir -p "$root/usr/bin"
printf 'fixture\n' >"$root/.arch-chroot"
printf '#!/usr/bin/env bash\nexit 0\n' >"$root/usr/bin/pacman"
printf '#!/usr/bin/env bash\nexit 0\n' >"$root/usr/bin/rustc"
chmod 755 "$root/usr/bin/pacman" "$root/usr/bin/rustc"
MOCK
cat >"$mock_bin/arch-nspawn" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'arch-nspawn' >>"$MOCK_CALL_LOG"; printf '\t%s' "$@" >>"$MOCK_CALL_LOG"; printf '\n' >>"$MOCK_CALL_LOG"
exit "${MOCK_ARCH_NSPAWN_STATUS:-0}"
MOCK
cat >"$mock_bin/makechrootpkg" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'makechrootpkg' >>"$MOCK_CALL_LOG"; printf '\t%s' "$@" >>"$MOCK_CALL_LOG"; printf '\n' >>"$MOCK_CALL_LOG"
status=${MOCK_MAKECHROOT_STATUS:-0}
((status == 0)) || exit "$status"
: "${PKGDEST:?}"
pkgbase=$(awk -F ' = ' '$1 == "pkgbase" {print $2; exit}' .SRCINFO)
pkgname=$(awk -F ' = ' '$1 == "pkgname" {print $2; exit}' .SRCINFO)
pkgver=$(awk -F ' = ' '$1 ~ /^[[:space:]]*pkgver$/ {print $2; exit}' .SRCINFO)
pkgrel=$(awk -F ' = ' '$1 ~ /^[[:space:]]*pkgrel$/ {print $2; exit}' .SRCINFO)
arch=$(awk -F ' = ' '$1 ~ /^[[:space:]]*arch$/ {print $2; exit}' .SRCINFO)
[[ -n $pkgbase && -n $pkgname && -n $pkgver && -n $pkgrel && -n $arch ]] || exit 95
[[ ${MOCK_ARTIFACT_SCENARIO:-ready} != wrong-name ]] || pkgname=wrong-package
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/usr/bin" "$PKGDEST"
cat >"$work/.PKGINFO" <<EOF
pkgname = $pkgname
pkgbase = $pkgbase
pkgver = $pkgver-$pkgrel
arch = $arch
packager = my-archlinux-setup fixed AUR recipe
EOF
printf 'fixture artifact\n' >"$work/usr/bin/$pkgname"
out="$PKGDEST/$pkgname-$pkgver-$pkgrel-$arch.pkg.tar.zst"
bsdtar -a -C "$work" -cf "$out" .PKGINFO usr
MOCK
chmod 755 "$home/scripts/desktop"/* "$mock_bin"/*

run_tool() {
  local expected=$1 output=$2 state=$3
  shift 3
  set +e
  HOME="$home" PATH="$mock_bin:/usr/bin" MOCK_CALL_LOG="$test_root/calls" \
    XDG_STATE_HOME="$state" XDG_CACHE_HOME="$test_root/cache" \
    python "$tool" --packages wooz-git \
      --source-cache "$test_root/cache/my-archlinux-setup/aur-sources" \
      --build-root "$state/my-archlinux-setup/builds/aur" \
      --state-root "$state/my-archlinux-setup" \
      "$@" --json >"$output" 2>"$output.err"
  local status=$?
  set -e
  ((status == expected)) || {
    cat "$output.err" >&2
    cat "$output" >&2
    fail "expected exit $expected, got $status for $*"
  }
}

: >"$test_root/calls"
state="$test_root/state"
run_tool 0 "$test_root/plan.json" "$state"
python - "$test_root/plan.json" <<'PY'
import json,sys
p=json.load(open(sys.argv[1]))
assert p['overall']['status']=='ready',p['overall']
assert p['chroot']['state']=='absent'
assert p['root_helper']['state']=='available'
assert p['source_plan']['overall']['status']=='static-ready'
assert p['packages'][0]['artifact']['state']=='absent'
assert [e['id'] for e in p['effects']]==['initialize-official-clean-chroot','verify-source-and-build']
assert p['confirmation']['required_flags']==['--confirm-aur','--confirm-system-changes']
assert p['apply']=={'authorized':False,'commands':None}
assert p['safety']=={
 'system_changes':False,'host_package_changes':False,'artifact_install':False,
 'official_only_chroot':True,'build_user_unprivileged':True,'network_during_package_build':False,
}
assert all(c['state']=='available' for c in p['commands'])
PY
[[ ! -e $state ]] || fail 'read-only build plan created state'
[[ ! -s $test_root/calls ]] || fail 'read-only build plan invoked commands'

set +e
HOME="$home" PATH="$mock_bin:/usr/bin" python "$tool" --packages wooz-git --build \
  >"$test_root/no-confirm.out" 2>"$test_root/no-confirm.err"
no_confirm_status=$?
set -e
((no_confirm_status == 2)) || fail "unconfirmed build exited $no_confirm_status"

run_tool 0 "$test_root/build.json" "$state" --build --confirm-aur --confirm-system-changes
python - "$test_root/build.json" <<'PY'
import json,sys
p=json.load(open(sys.argv[1]));assert p['status']=='passed';assert p['exit_code']==0;assert p['artifact_install'] is False
assert p['results'][0]['status']=='passed' and p['results'][0]['artifact']['state']=='verified'
PY
artifact_dir=$(find "$state/my-archlinux-setup/builds/aur/artifacts/wooz-git" -mindepth 1 -maxdepth 1 -type d -print -quit)
[[ -n $artifact_dir && -f $artifact_dir/artifact.json ]] || fail 'verified artifact state missing'
artifact=$(find "$artifact_dir" -maxdepth 1 -type f -name '*.pkg.tar.zst' -print -quit)
[[ -n $artifact && $(stat -c '%a' "$artifact") == 600 ]] || fail 'artifact missing or not private mode 600'
[[ $(stat -c '%a' "$artifact_dir/artifact.json") == 600 ]] || fail 'artifact metadata is not mode 600'
python - "$artifact_dir/artifact.json" <<'PY'
import json,sys
p=json.load(open(sys.argv[1]));assert p['package']=='wooz-git';assert p['pkgbase']=='wooz-git';assert p['version']=='r189.24e2856-1';assert p['arch']=='x86_64';assert p['file_count']>=2
PY
mapfile -t logs < <(find "$state/my-archlinux-setup/builds/aur/logs" -type f -name 'aur-build-*.log')
((${#logs[@]} == 1)) || fail 'build did not create exactly one private log'
[[ $(stat -c '%a' "${logs[0]}") == 600 ]] || fail 'build log is not mode 600'
grep -Fq $'mkarchroot\t-C' "$test_root/calls" || fail 'build omitted clean-chroot initialization'
grep -Fq $'arch-nspawn\t' "$test_root/calls" || fail 'build omitted clean-chroot full update'
grep -Fq $'makechrootpkg\t-c\t-r' "$test_root/calls" || fail 'build omitted isolated package build'

# A verified artifact is skipped on rerun; the clean root is still refreshed.
before_builds=$(grep -c $'^makechrootpkg\t' "$test_root/calls")
run_tool 0 "$test_root/rerun.json" "$state" --build --confirm-aur --confirm-system-changes
after_builds=$(grep -c $'^makechrootpkg\t' "$test_root/calls")
((before_builds == after_builds)) || fail 'verified artifact was rebuilt on rerun'

# Source verification failure preserves its exact exit and creates no artifact state.
source_state="$test_root/source-fail-state"
set +e
HOME="$home" PATH="$mock_bin:/usr/bin" MOCK_CALL_LOG="$test_root/calls" MOCK_MAKEPKG_STATUS=38 \
  XDG_STATE_HOME="$source_state" XDG_CACHE_HOME="$test_root/cache" \
  python "$tool" --packages wooz-git --source-cache "$test_root/cache/my-archlinux-setup/aur-sources" \
    --build-root "$source_state/my-archlinux-setup/builds/aur" --state-root "$source_state/my-archlinux-setup" \
    --build --confirm-aur --confirm-system-changes --json >"$test_root/source-fail.json"
source_status=$?
set -e
((source_status == 38)) || fail "source verification failure exit was not preserved: $source_status"
python - "$test_root/source-fail.json" <<'PY'
import json,sys
p=json.load(open(sys.argv[1]));assert p['status']=='failed';assert p['exit_code']==38;assert p['results'][0]['status']=='failed';assert p['results'][0]['exit']==38
PY

# Clean-chroot build failure preserves its exact exit.
build_state="$test_root/build-fail-state"
set +e
HOME="$home" PATH="$mock_bin:/usr/bin" MOCK_CALL_LOG="$test_root/calls" MOCK_MAKECHROOT_STATUS=47 \
  XDG_STATE_HOME="$build_state" XDG_CACHE_HOME="$test_root/cache" \
  python "$tool" --packages wooz-git --source-cache "$test_root/cache/my-archlinux-setup/aur-sources" \
    --build-root "$build_state/my-archlinux-setup/builds/aur" --state-root "$build_state/my-archlinux-setup" \
    --build --confirm-aur --confirm-system-changes --json >"$test_root/build-fail.json"
build_status=$?
set -e
((build_status == 47)) || fail "chroot build failure exit was not preserved: $build_status"
python - "$test_root/build-fail.json" <<'PY'
import json,sys
p=json.load(open(sys.argv[1]));assert p['status']=='failed';assert p['exit_code']==47;assert p['results'][0]['exit']==47
PY

# Chroot initialization failure preserves its exact exit and stops before package build.
init_state="$test_root/init-fail-state"
set +e
HOME="$home" PATH="$mock_bin:/usr/bin" MOCK_CALL_LOG="$test_root/calls" MOCK_MKARCHROOT_STATUS=43 \
  XDG_STATE_HOME="$init_state" XDG_CACHE_HOME="$test_root/cache" \
  python "$tool" --packages wooz-git --source-cache "$test_root/cache/my-archlinux-setup/aur-sources" \
    --build-root "$init_state/my-archlinux-setup/builds/aur" --state-root "$init_state/my-archlinux-setup" \
    --build --confirm-aur --confirm-system-changes >"$test_root/init-fail.out" 2>"$test_root/init-fail.err"
init_status=$?
set -e
((init_status == 43)) || fail "chroot initialization failure exit was not preserved: $init_status"

# High external statuses are still exact evidence; they are not collapsed to a
# generic 1 merely because they exceed the shell's conventional signal range.
init_high_state="$test_root/init-high-fail-state"
set +e
HOME="$home" PATH="$mock_bin:/usr/bin" MOCK_CALL_LOG="$test_root/calls" MOCK_MKARCHROOT_STATUS=255 \
  XDG_STATE_HOME="$init_high_state" XDG_CACHE_HOME="$test_root/cache" \
  python "$tool" --packages wooz-git --source-cache "$test_root/cache/my-archlinux-setup/aur-sources" \
    --build-root "$init_high_state/my-archlinux-setup/builds/aur" --state-root "$init_high_state/my-archlinux-setup" \
    --build --confirm-aur --confirm-system-changes >"$test_root/init-high-fail.out" 2>"$test_root/init-high-fail.err"
init_high_status=$?
set -e
((init_high_status == 255)) || fail "high chroot initialization failure exit was not preserved: $init_high_status"

# A failed mkarchroot may leave a root-owned partial root. The adapter must
# remove only that fixed private root through the audited helper so the same
# run can retry; preserving the original external exit remains mandatory.
init_retry_state="$test_root/init-retry-state"
set +e
HOME="$home" PATH="$mock_bin:/usr/bin" MOCK_CALL_LOG="$test_root/calls" \
  MOCK_MKARCHROOT_STATUS=43 MOCK_MKARCHROOT_PARTIAL=1 \
  XDG_STATE_HOME="$init_retry_state" XDG_CACHE_HOME="$test_root/cache" \
  python "$tool" --packages wooz-git --source-cache "$test_root/cache/my-archlinux-setup/aur-sources" \
    --build-root "$init_retry_state/my-archlinux-setup/builds/aur" \
    --state-root "$init_retry_state/my-archlinux-setup" \
    --build --confirm-aur --confirm-system-changes >"$test_root/init-retry-first.out" 2>"$test_root/init-retry-first.err"
init_retry_first=$?
set -e
((init_retry_first == 43)) || fail "retryable chroot initialization failure exited $init_retry_first"
retry_root="$init_retry_state/my-archlinux-setup/builds/aur/chroot/root"
[[ ! -e $retry_root && ! -L $retry_root ]] || fail 'failed initialization left an incomplete chroot root'
grep -Fq $'gsudo	/usr/bin/rm	-rf	--one-file-system	--preserve-root=all	--	' "$test_root/calls" \
  || fail 'failed initialization omitted exact audited partial-root cleanup'
HOME="$home" PATH="$mock_bin:/usr/bin" MOCK_CALL_LOG="$test_root/calls" \
  XDG_STATE_HOME="$init_retry_state" XDG_CACHE_HOME="$test_root/cache" \
  python "$tool" --packages wooz-git --source-cache "$test_root/cache/my-archlinux-setup/aur-sources" \
    --build-root "$init_retry_state/my-archlinux-setup/builds/aur" \
    --state-root "$init_retry_state/my-archlinux-setup" \
    --build --confirm-aur --confirm-system-changes --json >"$test_root/init-retry-second.json"
python3 - "$test_root/init-retry-second.json" <<'PY'
import json,sys
report=json.load(open(sys.argv[1])); assert report['status']=='passed' and report['exit_code']==0
PY

# Artifact identity mismatch is rejected after a nominal build.
wrong_state="$test_root/wrong-artifact-state"
set +e
HOME="$home" PATH="$mock_bin:/usr/bin" MOCK_CALL_LOG="$test_root/calls" MOCK_ARTIFACT_SCENARIO=wrong-name \
  XDG_STATE_HOME="$wrong_state" XDG_CACHE_HOME="$test_root/cache" \
  python "$tool" --packages wooz-git --source-cache "$test_root/cache/my-archlinux-setup/aur-sources" \
    --build-root "$wrong_state/my-archlinux-setup/builds/aur" --state-root "$wrong_state/my-archlinux-setup" \
    --build --confirm-aur --confirm-system-changes --json >"$test_root/wrong-artifact.json"
wrong_status=$?
set -e
((wrong_status == 1)) || fail "wrong artifact identity exited $wrong_status"
python - "$test_root/wrong-artifact.json" <<'PY'
import json,sys
p=json.load(open(sys.argv[1]));assert p['status']=='failed';assert p['results'][0]['exit']==1;assert 'identity mismatch' in p['results'][0]['message']
PY

# Post-official mode distinguishes unavailable devtools from a successful empty result.
missing_bin="$test_root/missing-bin"
mkdir -p "$missing_bin"
ln -s /usr/bin/makepkg "$missing_bin/makepkg"
ln -s /usr/bin/vercmp "$missing_bin/vercmp"
set +e
HOME="$home" PATH="$missing_bin:/usr/bin" python "$tool" --packages wooz-git --post-official \
  --source-cache "$test_root/cache/my-archlinux-setup/aur-sources" \
  --build-root "$test_root/post/builds/aur" --state-root "$test_root/post" --json >"$test_root/post.json"
post_status=$?
set -e
# /usr/bin does not contain devtools on this host; if that changes, the check legitimately becomes ready.
python - "$test_root/post.json" "$post_status" <<'PY'
import json,sys
p=json.load(open(sys.argv[1]));status=int(sys.argv[2])
if any(c['command']=='mkarchroot' and c['state']=='missing' for c in p['commands']):
 assert status==2 and p['overall']['status']=='unavailable' and p['overall']['unavailable_checks']
else:
 assert status in (0,1)
PY

# Symlinked state/build roots fail closed.
mkdir -p "$test_root/symlink-target"
ln -s "$test_root/symlink-target" "$test_root/symlink-build"
run_tool 1 "$test_root/symlink.json" "$test_root/symlink-state" --build-root "$test_root/symlink-build"
python - "$test_root/symlink.json" <<'PY'
import json,sys
p=json.load(open(sys.argv[1]));assert p['overall']['status']=='blocked';assert any('symlink' in x for x in p['overall']['blockers'])
PY

printf '%s\n' 'AUR clean-chroot build checks passed (plan/no-write, dual confirmation, private verified artifact, rerun, exact failures).'
