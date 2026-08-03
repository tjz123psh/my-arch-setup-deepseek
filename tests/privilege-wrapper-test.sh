#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
gsudo="$root/config/home/scripts/desktop/gsudo"
askpass="$root/config/home/scripts/desktop/fuzzel-askpass"
test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT

fail() {
  printf 'privilege wrapper test failed: %s\n' "$*" >&2
  exit 1
}

[[ -f $gsudo && -x $gsudo && ! -L $gsudo ]] || fail 'gsudo payload is missing or unsafe'
[[ -f $askpass && -x $askpass && ! -L $askpass ]] || fail 'askpass payload is missing or unsafe'

# A clean base may have sudo but not fuzzel yet. NOPASSWD sudo must remain
# usable so the later official/AUR stages can install the graphical provider.
clean_bin="$test_root/clean-bin"
mkdir -p "$clean_bin"
cat >"$clean_bin/sudo" <<'MOCK'
#!/usr/bin/bash
set -euo pipefail
printf '%s\n' "${SUDO_ASKPASS:-}" >"$MOCK_SUDO_ASKPASS_LOG"
printf '%s\n' "$@" >"$MOCK_SUDO_ARGV_LOG"
MOCK
chmod 755 "$clean_bin/sudo"

set +e
PATH="$clean_bin" \
  MOCK_SUDO_ASKPASS_LOG="$test_root/sudo-askpass.log" \
  MOCK_SUDO_ARGV_LOG="$test_root/sudo-argv.log" \
  /usr/bin/bash "$gsudo" -- pacman -Syu \
  >"$test_root/gsudo.out" 2>"$test_root/gsudo.err"
gsudo_status=$?
set -e
((gsudo_status == 0)) || {
  cat "$test_root/gsudo.err" >&2
  fail "clean-base NOPASSWD path exited $gsudo_status"
}
[[ ! -s $test_root/gsudo.out ]] || fail 'gsudo wrote unexpected stdout'
[[ $(<"$test_root/sudo-askpass.log") == "$askpass" ]] || fail 'gsudo did not select its adjacent fixed askpass helper'
mapfile -t sudo_argv <"$test_root/sudo-argv.log"
[[ ${#sudo_argv[@]} -eq 4 ]] || fail 'gsudo changed the reviewed sudo argv length'
[[ ${sudo_argv[0]} == -A && ${sudo_argv[1]} == -- && ${sudo_argv[2]} == pacman && ${sudo_argv[3]} == -Syu ]] \
  || fail 'gsudo changed the reviewed sudo argv'

# When fuzzel is available it remains the preferred masked graphical prompt.
fuzzel_bin="$test_root/fuzzel-bin"
mkdir -p "$fuzzel_bin"
cat >"$fuzzel_bin/fuzzel" <<'MOCK'
#!/usr/bin/bash
set -euo pipefail
printf '%s\n' "$@" >"$MOCK_FUZZEL_ARGV_LOG"
if (( ${MOCK_FUZZEL_STATUS:-0} != 0 )); then
  exit "$MOCK_FUZZEL_STATUS"
fi
printf '%s\n' 'fuzzel-test-password'
MOCK
chmod 755 "$fuzzel_bin/fuzzel"
PATH="$fuzzel_bin" MOCK_FUZZEL_ARGV_LOG="$test_root/fuzzel-argv.log" \
  /usr/bin/bash "$askpass" 'Graphical test prompt: ' \
  >"$test_root/fuzzel.out" 2>"$test_root/fuzzel.err"
[[ $(<"$test_root/fuzzel.out") == 'fuzzel-test-password' ]] || fail 'fuzzel password output was not preserved'
[[ ! -s $test_root/fuzzel.err ]] || fail 'fuzzel path emitted an unexpected fallback warning'
mapfile -t fuzzel_argv <"$test_root/fuzzel-argv.log"
expected_fuzzel_argv=(
  --dmenu
  --password
  --lines=0
  --placeholder=
  '--prompt-only=Graphical test prompt: '
)
[[ ${#fuzzel_argv[@]} -eq ${#expected_fuzzel_argv[@]} ]] || fail 'fuzzel prompt argv length drifted'
for index in "${!expected_fuzzel_argv[@]}"; do
  [[ ${fuzzel_argv[index]} == "${expected_fuzzel_argv[index]}" ]] || fail "fuzzel prompt argv drifted at index $index"
done

# A found-but-cancelled/failed Fuzzel prompt preserves its external status and
# must not surprise the user with a second systemd prompt.
set +e
PATH="$fuzzel_bin" MOCK_FUZZEL_ARGV_LOG="$test_root/fuzzel-failure-argv.log" \
  MOCK_FUZZEL_STATUS=42 /usr/bin/bash "$askpass" 'Cancelled prompt: ' \
  >"$test_root/fuzzel-failure.out" 2>"$test_root/fuzzel-failure.err"
fuzzel_failure_status=$?
set -e
((fuzzel_failure_status == 42)) || fail "Fuzzel failure status became $fuzzel_failure_status instead of 42"
[[ ! -s $test_root/fuzzel-failure.out ]] || fail 'failed Fuzzel prompt wrote password output'
[[ ! -s $test_root/fuzzel-failure.err ]] || fail 'failed Fuzzel prompt attempted or announced a fallback'

# The fixed systemd helper is an auditable clean-base fallback. Use a byte-near
# test copy so this test never opens a real host password agent.
fallback_root="$test_root/fallback-root"
fallback_helper="$fallback_root/usr/bin/systemd-ask-password"
fallback_variant="$test_root/fuzzel-askpass-with-mock-systemd"
mkdir -p "$(dirname -- "$fallback_helper")" "$test_root/empty-bin"
cat >"$fallback_helper" <<'MOCK'
#!/usr/bin/bash
set -euo pipefail
printf '%s\n' "$@" >"$MOCK_SYSTEMD_ARGV_LOG"
printf '%s\n' 'systemd-test-password'
MOCK
chmod 755 "$fallback_helper"
python - "$askpass" "$fallback_variant" "$fallback_helper" <<'PY'
from pathlib import Path
import sys
source, target, replacement = map(Path, sys.argv[1:])
data = source.read_text()
needle = "/usr/bin/systemd-ask-password"
if data.count(needle) != 1:
    raise SystemExit("askpass must contain exactly one fixed systemd helper path")
target.write_text(data.replace(needle, str(replacement)))
target.chmod(0o755)
PY

PATH="$test_root/empty-bin" MOCK_SYSTEMD_ARGV_LOG="$test_root/systemd-argv.log" \
  /usr/bin/bash "$fallback_variant" 'Fallback test prompt: ' \
  >"$test_root/systemd.out" 2>"$test_root/systemd.err"
[[ $(<"$test_root/systemd.out") == 'systemd-test-password' ]] || fail 'systemd fallback password output was not preserved'
grep -Fq '警告' "$test_root/systemd.err" || fail 'systemd fallback was silent'
grep -Fq 'fuzzel' "$test_root/systemd.err" || fail 'fallback warning did not identify missing fuzzel'
grep -Fq 'systemd-ask-password' "$test_root/systemd.err" || fail 'fallback warning did not identify systemd ask-password'
mapfile -t systemd_argv <"$test_root/systemd-argv.log"
[[ ${#systemd_argv[@]} -eq 3 ]] || fail 'systemd fallback argv length drifted'
[[ ${systemd_argv[0]} == --echo=no && ${systemd_argv[1]} == -- && ${systemd_argv[2]} == 'Fallback test prompt: ' ]] \
  || fail 'systemd fallback argv drifted'

# If neither reviewed prompt provider exists, fail closed with the conventional
# command-not-found status instead of changing privilege paths.
missing_variant="$test_root/fuzzel-askpass-without-provider"
python - "$askpass" "$missing_variant" "$test_root/missing/systemd-ask-password" <<'PY'
from pathlib import Path
import sys
source, target, replacement = map(Path, sys.argv[1:])
data = source.read_text()
needle = "/usr/bin/systemd-ask-password"
if data.count(needle) != 1:
    raise SystemExit("askpass must contain exactly one fixed systemd helper path")
target.write_text(data.replace(needle, str(replacement)))
target.chmod(0o755)
PY
set +e
PATH="$test_root/empty-bin" /usr/bin/bash "$missing_variant" 'Missing provider prompt: ' \
  >"$test_root/missing.out" 2>"$test_root/missing.err"
missing_status=$?
set -e
((missing_status == 127)) || {
  cat "$test_root/missing.err" >&2
  fail "missing prompt providers exited $missing_status instead of 127"
}
[[ ! -s $test_root/missing.out ]] || fail 'missing-provider failure wrote stdout'
grep -Fq '错误' "$test_root/missing.err" || fail 'missing-provider failure was not explicit'
grep -Fq 'fuzzel' "$test_root/missing.err" || fail 'missing-provider error omitted fuzzel'
grep -Fq 'systemd-ask-password' "$test_root/missing.err" || fail 'missing-provider error omitted systemd ask-password'

printf 'privilege wrapper tests passed\n'
