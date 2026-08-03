#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tool="$root/installer/aur-install.py"
[[ -x $tool && ! -L $tool ]] || { printf '%s\n' 'AUR install tool is missing or unsafe' >&2; exit 1; }

test_root=$(mktemp -d -p /var/tmp myarch-aur-install-test.XXXXXX)
trap 'rm -rf -- "$test_root"' EXIT
home="$test_root/home"
mock_bin="$test_root/mock-bin"
mkdir -p "$home/scripts/desktop" "$mock_bin"

fail() {
  printf 'AUR install test failed: %s\n' "$*" >&2
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
cat >"$mock_bin/pacman" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'pacman' >>"$MOCK_CALL_LOG"; printf '\t%s' "$@" >>"$MOCK_CALL_LOG"; printf '\n' >>"$MOCK_CALL_LOG"
case ${1:-} in
  -Q)
    if [[ -n ${MOCK_QUERY_STATUS:-} ]]; then exit "$MOCK_QUERY_STATUS"; fi
    package=${3:-}
    version=$(awk -F '\t' -v p="$package" '$1==p {print $2; exit}' "$MOCK_INSTALLED")
    if [[ -n $version ]]; then printf '%s %s\n' "$package" "$version"; exit 0; fi
    printf "error: package '%s' was not found\n" "$package" >&2
    exit 1
    ;;
  -U)
    status=${MOCK_INSTALL_STATUS:-0}
    ((status == 0)) || exit "$status"
    shift
    while (($#)); do
      case $1 in --noconfirm|--) shift; continue;; esac
      artifact=$1; shift
      info=$(bsdtar -xOf "$artifact" .PKGINFO)
      package=$(awk -F ' = ' '$1=="pkgname" {print $2; exit}' <<<"$info")
      version=$(awk -F ' = ' '$1=="pkgver" {print $2; exit}' <<<"$info")
      [[ -n $package && -n $version ]] || exit 96
      awk -F '\t' -v p="$package" '$1!=p' "$MOCK_INSTALLED" >"$MOCK_INSTALLED.tmp"
      printf '%s\t%s\n' "$package" "$version" >>"$MOCK_INSTALLED.tmp"
      mv "$MOCK_INSTALLED.tmp" "$MOCK_INSTALLED"
    done
    ;;
  *) exit 95 ;;
esac
MOCK
chmod 755 "$home/scripts/desktop"/* "$mock_bin"/*

recipe_line=$(awk -F '\t' '$1=="wooz-git" {print; exit}' "$root/manifests/aur-recipes.tsv")
[[ -n $recipe_line ]] || fail 'wooz-git recipe row missing'
IFS=$'\t' read -r package pkgbase _role _module pkgver pkgrel _arch _commit tree_hash _rest <<<"$recipe_line"
build_root="$test_root/builds/aur"
artifact_dir="$build_root/artifacts/$package/$tree_hash"
mkdir -p "$artifact_dir"
payload="$test_root/payload"
mkdir -p "$payload/usr/bin"
cat >"$payload/.PKGINFO" <<EOF
pkgname = $package
pkgbase = $pkgbase
pkgver = $pkgver-$pkgrel
arch = x86_64
packager = my-archlinux-setup fixed AUR recipe
EOF
printf 'fixture\n' >"$payload/usr/bin/$package"
artifact_name="$package-$pkgver-$pkgrel-x86_64.pkg.tar.zst"
bsdtar -a -C "$payload" -cf "$artifact_dir/$artifact_name" .PKGINFO usr
artifact_hash=$(sha256sum "$artifact_dir/$artifact_name" | awk '{print $1}')
cat >"$artifact_dir/artifact.json" <<EOF
{
  "package": "$package",
  "pkgbase": "$pkgbase",
  "version": "$pkgver-$pkgrel",
  "arch": "x86_64",
  "filename": "$artifact_name",
  "sha256": "$artifact_hash",
  "bytes": $(stat -c '%s' "$artifact_dir/$artifact_name"),
  "file_count": 3,
  "files": [".PKGINFO", "usr", "usr/bin/$package"]
}
EOF
chmod 600 "$artifact_dir/artifact.json" "$artifact_dir/$artifact_name"

installed="$test_root/installed.tsv"
: >"$installed"
: >"$test_root/calls"

run_tool() {
  local expected=$1 output=$2 state=$3 artifact_root=${4:-$build_root}
  shift 4 || true
  set +e
  HOME="$home" PATH="$mock_bin:/usr/bin" MOCK_CALL_LOG="$test_root/calls" MOCK_INSTALLED="$installed" \
    XDG_STATE_HOME="$state" python "$tool" --packages wooz-git \
      --build-root "$artifact_root" --state-root "$state/my-archlinux-setup" \
      "$@" --json >"$output" 2>"$output.err"
  local status=$?
  set -e
  ((status == expected)) || {
    cat "$output.err" >&2
    cat "$output" >&2
    fail "expected exit $expected, got $status for $*"
  }
}

state="$test_root/state"
run_tool 0 "$test_root/plan.json" "$state" "$build_root"
python - "$test_root/plan.json" <<'PY'
import json,sys
p=json.load(open(sys.argv[1]));r=p['records'][0]
assert p['overall']['status']=='ready';assert r['installed']['state']=='missing';assert r['action']=='install';assert len(p['effects'])==1
assert p['confirmation']['required_flags']==['--confirm-aur','--confirm-system-changes']
assert p['apply']=={'authorized':False,'commands':None}
assert p['safety']=={'system_changes':False,'package_changes':False,'arbitrary_artifacts':False,'automatic_downgrade':False}
PY
[[ ! -e $state ]] || fail 'read-only install plan created state'
[[ ! -s $test_root/calls || $(grep -c $'^pacman\t-Q' "$test_root/calls") -ge 1 ]] || fail 'unexpected plan command'
if grep -q $'^gsudo\t' "$test_root/calls"; then fail 'read-only plan invoked root helper'; fi

set +e
HOME="$home" PATH="$mock_bin:/usr/bin" python "$tool" --packages wooz-git --install \
  >"$test_root/no-confirm.out" 2>"$test_root/no-confirm.err"
no_confirm_status=$?
set -e
((no_confirm_status == 2)) || fail "unconfirmed install exited $no_confirm_status"

run_tool 0 "$test_root/install.json" "$state" "$build_root" --install --confirm-aur --confirm-system-changes
python - "$test_root/install.json" <<'PY'
import json,sys
p=json.load(open(sys.argv[1]));assert p['status']=='passed';assert p['exit_code']==0
PY
grep -Fqx $'wooz-git\tr189.24e2856-1' "$installed" || fail 'artifact installation did not update installed fixture'
install_state="$state/my-archlinux-setup/aur-installed.json"
[[ -f $install_state && $(stat -c '%a' "$install_state") == 600 ]] || fail 'private AUR install state missing/wrong mode'
python - "$install_state" "$artifact_hash" "$tree_hash" <<'PY'
import json,sys
p=json.load(open(sys.argv[1]));r=p['packages']['wooz-git'];assert r['version']=='r189.24e2856-1';assert r['artifact_sha256']==sys.argv[2];assert r['recipe_tree_sha256']==sys.argv[3]
PY
mapfile -t logs < <(find "$state/my-archlinux-setup/logs" -type f -name 'aur-install-*.log')
((${#logs[@]} == 1)) || fail 'install did not create one private log'
[[ $(stat -c '%a' "${logs[0]}") == 600 ]] || fail 'AUR install log is not mode 600'

# Verified provenance makes rerun idempotent; no second pacman -U occurs.
before_installs=$(grep -c $'^pacman\t-U' "$test_root/calls")
run_tool 0 "$test_root/rerun.json" "$state" "$build_root" --install --confirm-aur --confirm-system-changes
after_installs=$(grep -c $'^pacman\t-U' "$test_root/calls")
((before_installs == after_installs)) || fail 'verified artifact was reinstalled on rerun'
python - "$test_root/rerun.json" <<'PY'
import json,sys
p=json.load(open(sys.argv[1]));assert p['status']=='passed'
PY

# Same installed version without matching private provenance is explicitly reinstalled.
provenance_state="$test_root/provenance-state"
before_installs=$(grep -c $'^pacman\t-U' "$test_root/calls")
run_tool 0 "$test_root/provenance.json" "$provenance_state" "$build_root" --install --confirm-aur --confirm-system-changes
after_installs=$(grep -c $'^pacman\t-U' "$test_root/calls")
((after_installs == before_installs + 1)) || fail 'same-version package without provenance was not reinstalled'

# A newer installed version blocks; no automatic downgrade is attempted.
printf 'wooz-git\tr9999.deadbeef-1\n' >"$installed"
newer_state="$test_root/newer-state"
run_tool 1 "$test_root/newer.json" "$newer_state" "$build_root"
python - "$test_root/newer.json" <<'PY'
import json,sys
p=json.load(open(sys.argv[1]));assert p['overall']['status']=='blocked';assert any('automatic downgrade is forbidden' in x for x in p['overall']['blockers'])
PY

# A failed installed-package query is unavailable and retains its exact query exit.
set +e
HOME="$home" PATH="$mock_bin:/usr/bin" MOCK_CALL_LOG="$test_root/calls" MOCK_INSTALLED="$installed" MOCK_QUERY_STATUS=37 \
  python "$tool" --packages wooz-git --build-root "$build_root" --state-root "$test_root/query-state" --json \
  >"$test_root/query.json"
query_status=$?
set -e
((query_status == 2)) || fail "failed package query exited $query_status"
python - "$test_root/query.json" <<'PY'
import json,sys
p=json.load(open(sys.argv[1]));assert p['overall']['status']=='unavailable';assert 'exit=37' in p['overall']['unavailable_checks'][0]
PY

# A root pacman failure preserves the exact exit and writes no provenance state.
: >"$installed"
failed_state="$test_root/failed-state"
set +e
HOME="$home" PATH="$mock_bin:/usr/bin" MOCK_CALL_LOG="$test_root/calls" MOCK_INSTALLED="$installed" MOCK_INSTALL_STATUS=49 \
  python "$tool" --packages wooz-git --build-root "$build_root" --state-root "$failed_state/my-archlinux-setup" \
    --install --confirm-aur --confirm-system-changes >"$test_root/install-fail.out" 2>"$test_root/install-fail.err"
install_fail_status=$?
set -e
((install_fail_status == 49)) || fail "pacman failure exit was not preserved: $install_fail_status"
[[ ! -e "$failed_state/my-archlinux-setup/aur-installed.json" ]] || fail 'failed install wrote provenance state'

# Artifact hash drift and malformed/symlinked state fail closed.
bad_root="$test_root/bad-build"
cp -a "$build_root" "$bad_root"
printf 'drift\n' >>"$bad_root/artifacts/wooz-git/$tree_hash/$artifact_name"
run_tool 1 "$test_root/bad-artifact.json" "$test_root/bad-artifact-state" "$bad_root"
python - "$test_root/bad-artifact.json" <<'PY'
import json,sys
p=json.load(open(sys.argv[1]));assert any('artifact SHA-256 mismatch' in x for x in p['overall']['blockers'])
PY
malformed_state="$test_root/malformed-state/my-archlinux-setup"
mkdir -p "$malformed_state"
printf 'not-json\n' >"$malformed_state/aur-installed.json"
chmod 600 "$malformed_state/aur-installed.json"
run_tool 1 "$test_root/malformed.json" "$test_root/malformed-state" "$build_root"
python - "$test_root/malformed.json" <<'PY'
import json,sys
p=json.load(open(sys.argv[1]));assert any('malformed' in x for x in p['overall']['blockers'])
PY

printf '%s\n' 'AUR artifact install checks passed (exact plan, dual confirmation, provenance reinstall/skip, no downgrade, exact failures).'
