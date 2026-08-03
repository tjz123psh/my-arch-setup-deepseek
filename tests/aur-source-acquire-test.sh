#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tool="$root/installer/aur-source-acquire.py"
[[ -x $tool && ! -L $tool ]] || { printf '%s\n' 'AUR acquisition tool is missing or unsafe' >&2; exit 1; }

test_root=$(mktemp -d -p /var/tmp myarch-aur-acquire-test.XXXXXX)
trap 'rm -rf -- "$test_root"' EXIT
fixture="$test_root/project"
mkdir -p "$fixture/manifests" "$fixture/installer" "$fixture/third_party/aur/paru" "$test_root/fixtures" "$test_root/mock-bin"
cp -a -- "$root/manifests/aur-source-acquisition.tsv" "$root/manifests/aur-recipes.tsv" "$fixture/manifests/"
cp -a -- "$tool" "$fixture/installer/"
cp -a -- "$root/third_party/aur/paru/Cargo.lock.libalpm16" "$fixture/third_party/aur/paru/"

fail() {
  printf 'AUR source acquisition test failed: %s\n' "$*" >&2
  exit 1
}

# Tiny deterministic stand-ins exercise the full acquisition/atomicity paths.
printf 'linuxqq-fixed-fixture\n' >"$test_root/fixtures/linuxqq"
printf 'wechat-fixed-fixture\n' >"$test_root/fixtures/wechat"
mkdir -p "$test_root/paru-source/paru-2.1.0"
printf 'fixture-lock\n' >"$test_root/paru-source/paru-2.1.0/Cargo.lock"
printf 'fixture-source\n' >"$test_root/paru-source/paru-2.1.0/README"
cp -- "$test_root/paru-source/paru-2.1.0/Cargo.lock" "$fixture/third_party/aur/paru/Cargo.lock.libalpm16"
tar -C "$test_root/paru-source" -czf "$test_root/fixtures/paru-source.tar.gz" paru-2.1.0

# This exactly mirrors the mock cargo-vendor output and production archive algorithm.
mkdir -p "$test_root/vendor-template/vendor/mock-crate-1.0.0"
printf 'vendored-fixture\n' >"$test_root/vendor-template/vendor/mock-crate-1.0.0/source"
TZ=UTC tar --sort=name --mtime='@0' --owner=0 --group=0 --numeric-owner \
  --format=posix --pax-option=delete=atime,delete=ctime \
  -C "$test_root/vendor-template" -cf "$test_root/fixtures/vendor.tar" vendor
zstd -q -T1 -10 -f -o "$test_root/fixtures/paru-vendor.tar.zst" "$test_root/fixtures/vendor.tar"

linuxqq_hash=$(sha256sum "$test_root/fixtures/linuxqq" | awk '{print $1}')
wechat_hash=$(sha256sum "$test_root/fixtures/wechat" | awk '{print $1}')
source_hash=$(sha256sum "$test_root/fixtures/paru-source.tar.gz" | awk '{print $1}')
lock_hash=$(sha256sum "$test_root/paru-source/paru-2.1.0/Cargo.lock" | awk '{print $1}')
vendor_hash=$(sha256sum "$test_root/fixtures/paru-vendor.tar.zst" | awk '{print $1}')
vendor_size=$(stat -c '%s' "$test_root/fixtures/paru-vendor.tar.zst")
python - "$fixture/manifests/aur-source-acquisition.tsv" \
  "$linuxqq_hash" "$wechat_hash" "$source_hash" "$lock_hash" "$vendor_hash" "$vendor_size" <<'PY'
from pathlib import Path
import sys
path=Path(sys.argv[1])
linuxqq,wechat,source,lock,vendor,size=sys.argv[2:]
out=[]
for line in path.read_text().splitlines():
    if line.startswith('linuxqq-appimage\t'):
        parts=line.split('\t');parts[3]=linuxqq;parts[6]=linuxqq;line='\t'.join(parts)
    elif line.startswith('wechat-appimage\t'):
        parts=line.split('\t');parts[3]=wechat;parts[6]=wechat;line='\t'.join(parts)
    elif line.startswith('paru\t'):
        parts=line.split('\t');parts[3]=vendor;parts[4]=size;parts[6]=source;parts[7]=lock;line='\t'.join(parts)
    out.append(line)
path.write_text('\n'.join(out)+'\n')
PY

cat >"$test_root/mock-bin/curl" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'curl' >>"$MOCK_CALL_LOG"; printf '\t%s' "$@" >>"$MOCK_CALL_LOG"; printf '\n' >>"$MOCK_CALL_LOG"
scenario=${MOCK_CURL_SCENARIO:-ready}
if [[ $scenario == fail ]]; then exit 42; fi
if [[ " $* " == *' --json '* ]]; then
  case $scenario in
    bad-json) printf 'not-json\n' ;;
    bad-host) printf '{"data":{"url":"https://evil.invalid/payload?token=private"}}\n' ;;
    *) printf '{"data":{"url":"https://qqdl.gtimg.cn/qqfile/QQNT/9.9.33/release/c97651b2/QQ_3.2.32_260730_x86_64_01.AppImage?token=private"}}\n' ;;
  esac
  exit 0
fi
if [[ " $* " == *' --config '* ]]; then
  config=${!#}
  output=$(awk -F ' = ' '$1 == "output" {value=$2; sub(/^"/,"",value); sub(/"$/,"",value); print value}' "$config")
  cp -- "$MOCK_FIXTURES/linuxqq" "$output"
  exit 0
fi
output=''
url=''
while (($#)); do
  case $1 in
    --output) output=$2; shift 2 ;;
    https://*) url=$1; shift ;;
    *) shift ;;
  esac
done
[[ -n $output ]] || exit 97
if [[ $output == /dev/null ]]; then
  exit 0
elif [[ $url == *Morganamilo/paru* ]]; then
  cp -- "$MOCK_FIXTURES/paru-source.tar.gz" "$output"
elif [[ $url == *WeChatLinux_x86_64.AppImage* ]]; then
  cp -- "$MOCK_FIXTURES/wechat" "$output"
else
  exit 98
fi
MOCK
cat >"$test_root/mock-bin/cargo" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'cargo' >>"$MOCK_CALL_LOG"; printf '\t%s' "$@" >>"$MOCK_CALL_LOG"; printf '\n' >>"$MOCK_CALL_LOG"
if [[ ${MOCK_CARGO_SCENARIO:-ready} == fail ]]; then exit 53; fi
[[ ${1:-} == vendor ]] || exit 97
destination=${!#}
mkdir -p "$destination/mock-crate-1.0.0"
printf 'vendored-fixture\n' >"$destination/mock-crate-1.0.0/source"
MOCK
chmod 755 "$test_root/mock-bin"/*

run_tool() {
  local expected=$1 output=$2 cache=$3
  shift 3
  set +e
  PATH="$test_root/mock-bin:/usr/bin" \
    MOCK_FIXTURES="$test_root/fixtures" MOCK_CALL_LOG="$test_root/calls" \
    HOME="$test_root/home" XDG_STATE_HOME="$test_root/state" \
    python "$fixture/installer/aur-source-acquire.py" --project-root "$fixture" \
      --cache-root "$cache" "$@" --json >"$output" 2>"$output.err"
  local status=$?
  set -e
  ((status == expected)) || {
    cat "$output.err" >&2
    cat "$output" >&2
    fail "expected exit $expected, got $status for $*"
  }
}

mkdir -p "$test_root/home"
: >"$test_root/calls"
cache="$test_root/cache"
run_tool 0 "$test_root/plan.json" "$cache"
python - "$test_root/plan.json" <<'PY'
import json,sys
p=json.load(open(sys.argv[1]))
assert p['overall']['status']=='ready',p['overall']
assert [e['package'] for e in p['effects']]==['linuxqq-appimage','paru','wechat-appimage']
assert all(r['state']=='absent' for r in p['records'])
assert p['confirmation']=={'authorization':'aur','required_flag':'--confirm-aur'}
assert p['safety']=={
 'read_only':True,'system_changes':False,'package_changes':False,
 'executes_downloaded_sources':False,'credentials_persisted':False,
}
assert p['apply']=={'authorized':False,'commands':None}
PY
[[ ! -e $cache ]] || fail 'read-only plan created the cache root'
[[ ! -s $test_root/calls ]] || fail 'read-only plan invoked acquisition commands'

set +e
PATH="$test_root/mock-bin:/usr/bin" python "$fixture/installer/aur-source-acquire.py" \
  --project-root "$fixture" --cache-root "$cache" --apply >"$test_root/no-confirm.out" 2>"$test_root/no-confirm.err"
no_confirm_status=$?
set -e
((no_confirm_status == 2)) || fail "apply without independent AUR confirmation exited $no_confirm_status"
[[ ! -e $cache ]] || fail 'unconfirmed apply created the cache root'

run_tool 0 "$test_root/apply.json" "$cache" --apply --confirm-aur
python - "$test_root/apply.json" <<'PY'
import json,sys
p=json.load(open(sys.argv[1]))
assert p['overall']['status']=='ready',p['overall']
assert all(r['state']=='matching' for r in p['records']),p['records']
assert p['apply']['authorized'] is True and p['apply']['completed'] is True
assert p['safety']['system_changes'] is False and p['safety']['package_changes'] is False
PY
for path in \
  "$cache/linuxqq-appimage/Linuxqq-3.2.32_20260730-x86_64.AppImage" \
  "$cache/paru/paru-vendor-2.1.0.tar.zst" \
  "$cache/wechat-appimage/WechatLinux-1783692407-x86_64.AppImage"; do
  [[ -f $path && ! -L $path ]] || fail "acquired source missing/unsafe: $path"
  [[ $(stat -c '%a' "$path") == 600 ]] || fail "acquired source mode is not 600: $path"
done
for directory in "$cache" "$cache/linuxqq-appimage" "$cache/paru" "$cache/wechat-appimage"; do
  [[ $(stat -c '%a' "$directory") == 700 ]] || fail "cache directory mode is not 700: $directory"
done
mapfile -t logs < <(find "$test_root/state/my-archlinux-setup/logs" -maxdepth 1 -type f -name 'aur-source-acquire-*.log')
((${#logs[@]} == 1)) || fail 'successful acquisition did not create exactly one private log'
[[ $(stat -c '%a' "${logs[0]}") == 600 ]] || fail 'acquisition log is not mode 600'
if grep -Fq 'token=private' "${logs[0]}"; then fail 'private signed URL leaked into the acquisition log'; fi

# Rerun is idempotent: no acquisition command is called when all hashes match.
before_calls=$(wc -l <"$test_root/calls")
run_tool 0 "$test_root/rerun.json" "$cache" --apply --confirm-aur
after_calls=$(wc -l <"$test_root/calls")
((before_calls == after_calls)) || fail 'idempotent rerun invoked acquisition commands'

# A conflicting cache object is a deterministic blocker and is never overwritten.
conflict_cache="$test_root/conflict-cache"
mkdir -p "$conflict_cache/wechat-appimage"
printf 'conflicting\n' >"$conflict_cache/wechat-appimage/WechatLinux-1783692407-x86_64.AppImage"
run_tool 1 "$test_root/conflict.json" "$conflict_cache" --packages wechat-appimage
python - "$test_root/conflict.json" <<'PY'
import json,sys
p=json.load(open(sys.argv[1]));r=p['records'][0]
assert p['overall']['status']=='blocked';assert r['state']=='conflict';assert r['actual_sha256']
assert not p['overall']['unavailable_checks']
PY
[[ $(cat "$conflict_cache/wechat-appimage/WechatLinux-1783692407-x86_64.AppImage") == conflicting ]] || fail 'conflicting cache file was altered'

# A parent symlink is rejected rather than resolved through.
mkdir -p "$test_root/symlink-target"
ln -s "$test_root/symlink-target" "$test_root/symlink-cache"
run_tool 1 "$test_root/symlink.json" "$test_root/symlink-cache" --packages wechat-appimage
python - "$test_root/symlink.json" <<'PY'
import json,sys
p=json.load(open(sys.argv[1]));assert p['overall']['status']=='blocked';assert any('symlink' in x for x in p['overall']['blockers'])
PY

# A missing required command is unavailable, not an empty or healthy plan.
set +e
PATH="$test_root/no-commands" /usr/bin/python "$fixture/installer/aur-source-acquire.py" \
  --project-root "$fixture" --cache-root "$test_root/missing-command-cache" \
  --packages wechat-appimage --json >"$test_root/missing-command.json"
missing_command_status=$?
set -e
((missing_command_status == 2)) || fail "missing command query exited $missing_command_status"
python - "$test_root/missing-command.json" <<'PY'
import json,sys
p=json.load(open(sys.argv[1]));assert p['overall']['status']=='unavailable';assert p['records'][0]['commands'][0]['state']=='missing';assert p['overall']['unavailable_checks']
PY

# Download failure preserves the exact curl exit and leaves no target/partial file.
failed_cache="$test_root/failed-cache"
set +e
PATH="$test_root/mock-bin:/usr/bin" MOCK_FIXTURES="$test_root/fixtures" MOCK_CALL_LOG="$test_root/calls" \
  MOCK_CURL_SCENARIO=fail HOME="$test_root/home" XDG_STATE_HOME="$test_root/failed-state" \
  python "$fixture/installer/aur-source-acquire.py" --project-root "$fixture" \
    --cache-root "$failed_cache" --packages wechat-appimage --apply --confirm-aur \
    >"$test_root/curl-fail.out" 2>"$test_root/curl-fail.err"
curl_fail_status=$?
set -e
((curl_fail_status == 42)) || fail "curl failure exit was not preserved: $curl_fail_status"
[[ ! -e "$failed_cache/wechat-appimage/WechatLinux-1783692407-x86_64.AppImage" ]] || fail 'failed download left a target file'
if find "$failed_cache/wechat-appimage" -mindepth 1 -maxdepth 1 -name '.wechat-appimage-*' | grep -q .; then fail 'failed download left a temporary directory'; fi

# A checksum mismatch and malformed/unexpected signing responses are blockers.
wrong_fixtures="$test_root/wrong-fixtures"
cp -a "$test_root/fixtures" "$wrong_fixtures"
printf 'wrong\n' >"$wrong_fixtures/wechat"
set +e
PATH="$test_root/mock-bin:/usr/bin" MOCK_FIXTURES="$wrong_fixtures" MOCK_CALL_LOG="$test_root/calls" \
  HOME="$test_root/home" XDG_STATE_HOME="$test_root/wrong-state" \
  python "$fixture/installer/aur-source-acquire.py" --project-root "$fixture" \
    --cache-root "$test_root/wrong-cache" --packages wechat-appimage --apply --confirm-aur \
    >"$test_root/wrong.out" 2>"$test_root/wrong.err"
wrong_status=$?
set -e
((wrong_status == 1)) || fail "checksum mismatch exited $wrong_status"
[[ ! -e "$test_root/wrong-cache/wechat-appimage/WechatLinux-1783692407-x86_64.AppImage" ]] || fail 'checksum mismatch installed a cache target'

for scenario in bad-json bad-host; do
  set +e
  PATH="$test_root/mock-bin:/usr/bin" MOCK_FIXTURES="$test_root/fixtures" MOCK_CALL_LOG="$test_root/calls" \
    MOCK_CURL_SCENARIO="$scenario" HOME="$test_root/home" XDG_STATE_HOME="$test_root/$scenario-state" \
    python "$fixture/installer/aur-source-acquire.py" --project-root "$fixture" \
      --cache-root "$test_root/$scenario-cache" --packages linuxqq-appimage --apply --confirm-aur \
      >"$test_root/$scenario.out" 2>"$test_root/$scenario.err"
  scenario_status=$?
  set -e
  ((scenario_status == 1)) || fail "$scenario signing response exited $scenario_status"
  [[ ! -e "$test_root/$scenario-cache/linuxqq-appimage/Linuxqq-3.2.32_20260730-x86_64.AppImage" ]] || fail "$scenario installed a cache target"
done

# Cargo-vendor command failures preserve their exact exit.
set +e
PATH="$test_root/mock-bin:/usr/bin" MOCK_FIXTURES="$test_root/fixtures" MOCK_CALL_LOG="$test_root/calls" \
  MOCK_CARGO_SCENARIO=fail HOME="$test_root/home" XDG_STATE_HOME="$test_root/cargo-state" \
  python "$fixture/installer/aur-source-acquire.py" --project-root "$fixture" \
    --cache-root "$test_root/cargo-cache" --packages paru --apply --confirm-aur \
    >"$test_root/cargo-fail.out" 2>"$test_root/cargo-fail.err"
cargo_fail_status=$?
set -e
((cargo_fail_status == 53)) || fail "cargo failure exit was not preserved: $cargo_fail_status"
[[ ! -e "$test_root/cargo-cache/paru/paru-vendor-2.1.0.tar.zst" ]] || fail 'failed Cargo vendor acquisition installed a target'

printf '%s\n' 'AUR fixed-source acquisition checks passed (plan, confirmation, private cache/log, atomic failure, exact exits, rerun).'
