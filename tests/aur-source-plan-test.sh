#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tool="$root/installer/aur-plan.py"
manifest="$root/manifests/aur-recipes.tsv"
[[ -x $tool && -f $manifest && ! -L $tool && ! -L $manifest ]] || {
  printf '%s\n' 'AUR source planner or manifest is missing/unsafe' >&2
  exit 1
}
for review in \
  "$root/third_party/aur/linuxqq-appimage/REVIEW.md" \
  "$root/third_party/aur/wechat-appimage/REVIEW.md"; do
  grep -Fq 'my-archlinux-setup/aur-sources/' "$review" || {
    printf 'external-source review omits the private cache layout: %s\n' "$review" >&2
    exit 1
  }
  if grep -Eq "(next to|beside) \`PKGBUILD\`" "$review"; then
    printf 'external-source review incorrectly instructs repository-directory placement: %s\n' "$review" >&2
    exit 1
  fi
done

test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT
mkdir -p "$test_root/empty-cache"

fail() {
  printf 'AUR source plan test failed: %s\n' "$*" >&2
  exit 1
}

run_plan() {
  local expected_status=$1 output=$2
  shift 2
  set +e
  python "$tool" "$@" --json >"$output" 2>"$output.err"
  local status=$?
  set -e
  ((status == expected_status)) || {
    cat "$output.err" >&2
    fail "expected exit $expected_status, got $status for $*"
  }
}

# The complete real-tree plan is intentionally blocked, not unavailable: two
# fixed local AppImages and the fixed Paru offline-vendor archive are absent.
run_plan 1 "$test_root/default.json" --source-cache "$test_root/empty-cache"
python - "$test_root/default.json" <<'PY'
import json, sys
plan = json.load(open(sys.argv[1]))
assert plan["overall"]["status"] == "blocked", plan["overall"]
assert plan["counts"] == {
    "selected": 13,
    "aur_build": 12,
    "paru_bootstrap": 1,
    "ready": 0,
    "static_ready": 10,
    "blocked": 3,
    "unavailable": 0,
}, plan["counts"]
assert not plan["overall"]["unavailable_checks"], plan["overall"]
records = {record["package"]: record for record in plan["recipes"]}
assert len(records) == 13
assert records["linuxqq-appimage"]["status"] == "blocked"
assert records["wechat-appimage"]["status"] == "blocked"
assert records["paru"]["status"] == "blocked"
assert records["obsidian-bin"]["pkgbase"] == "obsidian"
assert records["obsidian-bin"]["aur_commit"] == "f5fc32c5df9b3caae1c719f78992277ab8dab1f0"
assert any("required fixed local source is missing: paru-vendor-2.1.0.tar.zst" in item for item in records["paru"]["blockers"])
assert any("required fixed local source is missing" in item for item in records["linuxqq-appimage"]["blockers"])
assert plan["build_policy"] == {
    "ordinary_user": True,
    "isolated_build_required": True,
    "network_during_prepare_build_package": False,
    "downloaded_source_execution_requires_isolation": True,
    "arbitrary_packages_allowed": False,
}
assert plan["apply"] == {"authorized": False, "commands": None}
assert plan["safety"]["system_changes"] is False
assert plan["safety"]["installer_apply_integration"] is False
PY

# A declared, fully static-ready subset is ready; undeclared arbitrary names fail closed.
run_plan 0 "$test_root/subset.json" --source-cache "$test_root/empty-cache" \
  --packages fcitx5-skin-fluentdark-git,fuzzel-ime-git,wooz-git
python - "$test_root/subset.json" <<'PY'
import json, sys
plan = json.load(open(sys.argv[1]))
assert plan["overall"]["status"] == "static-ready", plan["overall"]
assert plan["counts"]["selected"] == 3 and plan["counts"]["static_ready"] == 3
assert plan["counts"]["ready"] == 0
assert all(record["arch"] == "x86_64" for record in plan["recipes"])
assert all(record["status"] == "static-ready" for record in plan["recipes"])
assert all(record["source_verification"]["status"] == "not-run" for record in plan["recipes"])
assert plan["overall"]["source_verification_required"] == [
    "fcitx5-skin-fluentdark-git", "fuzzel-ime-git", "wooz-git"
]
PY
set +e
python "$tool" --packages arbitrary-not-declared --json >"$test_root/arbitrary.out" 2>"$test_root/arbitrary.err"
arbitrary_status=$?
set -e
((arbitrary_status == 2)) || fail "undeclared package exit was $arbitrary_status"
grep -Fq 'undeclared package in --packages' "$test_root/arbitrary.err" || fail 'undeclared package was not diagnosed'

# The current obsidian split-pkgbase wrapper and conditional AppArmor lifecycle are retained.
[[ $(sha256sum "$root/third_party/aur/obsidian-bin/obsidian-bin" | awk '{print $1}') == \
  a94e20705d4b67501f225d74f4460b746a258e52aa6bc522aed1e26ac42dbef9 ]] || fail 'Obsidian wrapper hash drifted'
grep -Fq 'obsidian-flags.conf' "$root/third_party/aur/obsidian-bin/obsidian-bin" || fail 'Obsidian wrapper lost flags support'
grep -Fq 'APPARMOR_PROFILE_TARGET' "$root/third_party/aur/obsidian-bin/obsidian-bin.install" || fail 'Obsidian hook lost AppArmor install handling'
grep -Fq 'APPARMOR_PROFILE_DEST' "$root/third_party/aur/obsidian-bin/obsidian-bin.install" || fail 'Obsidian hook lost AppArmor removal symmetry'
python - "$root/third_party/aur/paru/Cargo.lock.libalpm16" <<'PY'
import hashlib,sys,tomllib
path=sys.argv[1];data=open(path,'rb').read()
assert hashlib.sha256(data).hexdigest()=='4231e3bfa8172ad2c0c79322921fd974be97f1dec00bf970e9892ada9a98b323'
packages={item['name']:item['version'] for item in tomllib.loads(data.decode())['package']}
assert packages['alpm']=='4.0.4' and packages['alpm-sys']=='4.0.5',packages
PY
if grep -Eq '\bcargo[[:space:]]+(update|fetch|install)\b' "$root/third_party/aur/paru/PKGBUILD"; then
  fail 'Paru PKGBUILD reintroduced build-time Cargo networking'
fi
grep -Fq 'cargo build --frozen --offline' "$root/third_party/aur/paru/PKGBUILD" || fail 'Paru build lost frozen offline mode'

# Fuzzel links Cairo into the installed binary, so the fixed recipe must make it
# a runtime dependency. The metadata reproduction below also proves PKGBUILD and
# the committed .SRCINFO stay in sync.
grep -Fxq $'\tdepends = cairo' "$root/third_party/aur/fuzzel-ime-git/.SRCINFO" || \
  fail 'fuzzel-ime-git runtime metadata omits cairo'

# Reproduce the committed makepkg metadata and output identity without fetching/building.
command -v makepkg >/dev/null || fail 'makepkg unavailable; metadata reproduction is unavailable, not passing'
for directory in "$root"/third_party/aur/*; do
  [[ -d $directory ]] || continue
  package=${directory##*/}
  bash -n "$directory/PKGBUILD"
  generated="$test_root/$package.SRCINFO"
  (cd "$directory" && makepkg --printsrcinfo) >"$generated"
  cmp -s "$generated" "$directory/.SRCINFO" || fail "$package committed .SRCINFO differs from makepkg output"
  mapfile -t outputs < <(cd "$directory" && makepkg --packagelist)
  primary=0
  for output in "${outputs[@]}"; do
    filename=${output##*/}
    if [[ $filename == "$package-"* && $filename != "$package-debug-"* ]]; then
      ((primary += 1))
    elif [[ $filename == "$package-debug-"* ]]; then
      :
    else
      fail "$package produced an undeclared package-list identity: $filename"
    fi
  done
  ((primary == 1)) || fail "$package did not produce exactly one primary package identity"
done
mapfile -t recipe_shell_files < <(
  find "$root/third_party/aur" -maxdepth 2 -type f \
    \( -name PKGBUILD -o -name '*.install' -o -name '*.sh' -o -name wechat -o -name obsidian-bin \) \
    -print | LC_ALL=C sort
)
shellcheck -s bash -e SC2034,SC2154 "${recipe_shell_files[@]}"

copy_fixture() {
  local destination=$1
  mkdir -p "$destination/manifests" "$destination/installer"
  cp -a -- "$root/manifests/aur-recipes.tsv" \
    "$root/manifests/workstation-packages.tsv" \
    "$root/manifests/workstation-package-inventory.tsv" \
    "$destination/manifests/"
  cp -a -- "$root/installer/aur-plan.py" "$destination/installer/"
  cp -a -- "$root/third_party" "$destination/"
}

run_fixture() {
  local fixture=$1 expected_status=$2 output=$3
  shift 3
  set +e
  python "$fixture/installer/aur-plan.py" --project-root "$fixture" \
    --source-cache "$test_root/empty-cache" "$@" --json >"$output" 2>"$output.err"
  local status=$?
  set -e
  ((status == expected_status)) || {
    cat "$output.err" >&2
    fail "fixture expected exit $expected_status, got $status"
  }
}

# Recipe-tree drift is detected before apply.
drift="$test_root/drift"
copy_fixture "$drift"
printf '\n# unreviewed drift\n' >>"$drift/third_party/aur/wooz-git/PKGBUILD"
run_fixture "$drift" 1 "$test_root/drift.json" --packages wooz-git
python - "$test_root/drift.json" <<'PY'
import json, sys
plan=json.load(open(sys.argv[1])); record=plan["recipes"][0]
assert any("recipe tree SHA-256 differs" in item for item in record["blockers"]), record
PY

wrong_pkgbase="$test_root/wrong-pkgbase"
copy_fixture "$wrong_pkgbase"
sed -i 's/^pkgbase = obsidian$/pkgbase = obsidian-bin/' \
  "$wrong_pkgbase/third_party/aur/obsidian-bin/.SRCINFO"
run_fixture "$wrong_pkgbase" 1 "$test_root/wrong-pkgbase.json" --packages obsidian-bin
python - "$test_root/wrong-pkgbase.json" <<'PY'
import json,sys
r=json.load(open(sys.argv[1]))["recipes"][0]
assert any(".SRCINFO pkgbase differs" in x for x in r["blockers"]),r
PY

# SKIP, moving branches, and build-time networking are each explicit blockers.
skip="$test_root/skip"
copy_fixture "$skip"
sed -i '0,/sha256sums = [0-9a-f]/{s/sha256sums = [0-9a-f]*/sha256sums = SKIP/}' \
  "$skip/third_party/aur/wooz-git/.SRCINFO"
run_fixture "$skip" 1 "$test_root/skip.json" --packages wooz-git
python - "$test_root/skip.json" <<'PY'
import json,sys
r=json.load(open(sys.argv[1]))["recipes"][0]
assert any("invalid or skipped checksum" in x for x in r["blockers"]),r
PY

moving="$test_root/moving"
copy_fixture "$moving"
sed -i -E 's#/archive/[0-9a-f]{40}\.tar\.gz#/archive/main.tar.gz#' \
  "$moving/third_party/aur/wooz-git/.SRCINFO"
run_fixture "$moving" 1 "$test_root/moving.json" --packages wooz-git
python - "$test_root/moving.json" <<'PY'
import json,sys
r=json.load(open(sys.argv[1]))["recipes"][0]
assert any("moving branch/latest" in x for x in r["blockers"]),r
PY

paru_domain="$test_root/paru-domain"
copy_fixture "$paru_domain"
sed -i -E 's#https://github.com/Morganamilo/paru/archive/v2\.1\.0\.tar\.gz#https://repo.archlinuxcn.org/x86_64/paru-2.1.0-5-x86_64.pkg.tar.zst#' \
  "$paru_domain/third_party/aur/paru/.SRCINFO"
run_fixture "$paru_domain" 1 "$test_root/paru-domain.json" --packages paru
python - "$test_root/paru-domain.json" <<'PY'
import json,sys
r=json.load(open(sys.argv[1]))["recipes"][0]
assert any("crosses into archlinuxcn" in x for x in r["blockers"]),r
PY

network="$test_root/network"
copy_fixture "$network"
printf '\nprepare() { curl https://unreviewed.invalid/payload; }\n' >>"$network/third_party/aur/wooz-git/PKGBUILD"
run_fixture "$network" 1 "$test_root/network.json" --packages wooz-git
python - "$test_root/network.json" <<'PY'
import json,sys
r=json.load(open(sys.argv[1]))["recipes"][0]
assert any("build-time network command" in x for x in r["blockers"]),r
PY

# A version regression is separate from source/hash drift.
regression="$test_root/regression"
copy_fixture "$regression"
python - "$regression/manifests/workstation-package-inventory.tsv" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); lines=p.read_text().splitlines()
out=[]
for line in lines:
    if line.startswith("wooz-git\t"):
        parts=line.split("\t"); parts[1]="r9999.deadbeef-1"; line="\t".join(parts)
    out.append(line)
p.write_text("\n".join(out)+"\n")
PY
run_fixture "$regression" 1 "$test_root/regression.json" --packages wooz-git
python - "$test_root/regression.json" <<'PY'
import json,sys
r=json.load(open(sys.argv[1]))["recipes"][0]
assert any("regresses observed" in x for x in r["blockers"]),r
PY

# A supplied local precondition is hash-checked. Use a tiny fixture and update
# only its reviewed expected checksum/tree hash so this does not require private binaries.
local_ready="$test_root/local-ready"
copy_fixture "$local_ready"
cache="$test_root/local-cache"
mkdir -p "$cache/linuxqq-appimage"
printf 'fixed-fixture-source\n' >"$cache/linuxqq-appimage/Linuxqq-3.2.32_20260730-x86_64.AppImage"
fixture_hash=$(sha256sum "$cache/linuxqq-appimage/Linuxqq-3.2.32_20260730-x86_64.AppImage" | awk '{print $1}')
python - "$local_ready" "$fixture_hash" <<'PY'
from pathlib import Path
import hashlib, stat, sys
root=Path(sys.argv[1]); expected=sys.argv[2]
recipe=root/'third_party/aur/linuxqq-appimage'
for relative in ('PKGBUILD','.SRCINFO'):
    p=recipe/relative
    p.write_text(p.read_text().replace('719fa8307f569fcfa99f57f321b5c1e2f7bc8450b24bbfcb55fbc46a70b8f07e', expected))
h=hashlib.sha256()
for p in sorted((p for p in recipe.iterdir() if p.is_file()), key=lambda p:p.name.encode()):
    digest=hashlib.sha256(p.read_bytes()).hexdigest(); mode=stat.S_IMODE(p.stat().st_mode)
    h.update(p.name.encode());h.update(b'\0');h.update(f'{mode:04o}'.encode());h.update(b'\0');h.update(digest.encode());h.update(b'\n')
manifest=root/'manifests/aur-recipes.tsv'; lines=[]
for line in manifest.read_text().splitlines():
    if line.startswith('linuxqq-appimage\t'):
        parts=line.split('\t');parts[8]=h.hexdigest();line='\t'.join(parts)
    lines.append(line)
manifest.write_text('\n'.join(lines)+'\n')
PY
set +e
python "$local_ready/installer/aur-plan.py" --project-root "$local_ready" \
  --source-cache "$cache" --packages linuxqq-appimage --json >"$test_root/local-ready.json"
local_ready_status=$?
set -e
((local_ready_status == 0)) || fail "fixed local source fixture exited $local_ready_status"
python - "$test_root/local-ready.json" <<'PY'
import json,sys
r=json.load(open(sys.argv[1]))["recipes"][0]
assert r["status"]=="ready",r
external=[s for s in r["sources"] if s["filename"].endswith('.AppImage')]
assert len(external)==1 and external[0]["state"]=="verified",external
PY

mkdir -p "$test_root/source-cache-target"
ln -s "$test_root/source-cache-target" "$test_root/source-cache-link"
run_plan 1 "$test_root/source-cache-symlink.json" --source-cache "$test_root/source-cache-link" \
  --packages linuxqq-appimage
python - "$test_root/source-cache-symlink.json" <<'PY'
import json,sys
r=json.load(open(sys.argv[1]))["recipes"][0]
assert any("local source path contains a symlink" in x for x in r["blockers"]),r
PY

polluted="$test_root/polluted-recipe"
copy_fixture "$polluted"
dd if=/dev/zero of="$polluted/third_party/aur/linuxqq-appimage/Linuxqq-3.2.32_20260730-x86_64.AppImage" \
  bs=1048577 count=1 status=none
run_fixture "$polluted" 1 "$test_root/polluted.json" --packages linuxqq-appimage
python - "$test_root/polluted.json" <<'PY'
import json,sys
r=json.load(open(sys.argv[1]))["recipes"][0]
assert any("recipe static file exceeds 1 MiB" in x for x in r["blockers"]),r
PY

# Failed version and source queries remain unavailable with their exact exits;
# a checksum failure is a deterministic blocker instead.
mock_bin="$test_root/mock-bin"
mkdir -p "$mock_bin"
cat >"$mock_bin/vercmp" <<'MOCK'
#!/usr/bin/env bash
exit 37
MOCK
chmod 755 "$mock_bin/vercmp"
set +e
PATH="$mock_bin:$PATH" python "$tool" --source-cache "$test_root/empty-cache" \
  --packages wooz-git --json >"$test_root/vercmp-failed.json"
vercmp_status=$?
set -e
((vercmp_status == 2)) || fail "failed vercmp query exited $vercmp_status"
python - "$test_root/vercmp-failed.json" <<'PY'
import json,sys
p=json.load(open(sys.argv[1]));r=p["recipes"][0]
assert p["overall"]["status"]=="unavailable",p["overall"]
assert r["version_comparison"]["query_exit"]==37,r
assert r["unavailable_checks"],r
PY
rm -f "$mock_bin/vercmp"

cat >"$mock_bin/makepkg" <<'MOCK'
#!/usr/bin/env bash
case ${MOCK_MAKEPKG_SCENARIO:-ready} in
  ready) exit 0 ;;
  network) printf 'curl: (6) Could not resolve host: example.invalid\n' >&2; exit 42 ;;
  checksum) printf 'One or more files did not pass the validity check!\n' >&2; exit 1 ;;
  *) exit 99 ;;
esac
MOCK
chmod 755 "$mock_bin/makepkg"
set +e
PATH="$mock_bin:$PATH" MOCK_MAKEPKG_SCENARIO=network python "$tool" \
  --packages wooz-git --source-cache "$test_root/empty-cache" --verify-sources --json \
  >"$test_root/source-network.json"
source_network_status=$?
PATH="$mock_bin:$PATH" MOCK_MAKEPKG_SCENARIO=checksum python "$tool" \
  --packages wooz-git --source-cache "$test_root/empty-cache" --verify-sources --json \
  >"$test_root/source-checksum.json"
source_checksum_status=$?
PATH="$mock_bin:$PATH" MOCK_MAKEPKG_SCENARIO=ready python "$tool" \
  --packages wooz-git --source-cache "$test_root/empty-cache" --verify-sources --json \
  >"$test_root/source-ready.json"
source_ready_status=$?
set -e
((source_network_status == 2)) || fail "source network failure exited $source_network_status"
((source_checksum_status == 1)) || fail "source checksum failure exited $source_checksum_status"
((source_ready_status == 0)) || fail "source verification success exited $source_ready_status"
python - "$test_root/source-network.json" "$test_root/source-checksum.json" "$test_root/source-ready.json" <<'PY'
import json,sys
network,checksum,ready=(json.load(open(p)) for p in sys.argv[1:])
assert network["overall"]["status"]=="unavailable"
assert network["recipes"][0]["source_verification"]["query_exit"]==42
assert checksum["overall"]["status"]=="blocked"
assert checksum["recipes"][0]["source_verification"]["query_exit"]==1
assert ready["overall"]["status"]=="ready"
assert ready["recipes"][0]["source_verification"]=={"status":"verified","query_exit":0}
PY

printf '%s\n' 'AUR source plan checks passed (default local-source preconditions preserved for Paru, LinuxQQ, and WeChat).'
