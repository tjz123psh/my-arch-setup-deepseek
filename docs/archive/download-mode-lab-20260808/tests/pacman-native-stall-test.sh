#!/usr/bin/env bash
# Verify the pacman native downloader fails a zero-byte stall instead of
# hanging indefinitely.  This is an isolated local mock; a non-zero pacman
# result is the expected product behavior and is asserted below.
set -Eeuo pipefail
LAB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# RESULT_DIR redirects the committed results/ snapshot (step 2, 2026-08-08):
# running the suite must never rewrite tracked timing JSONs.
result="${RESULT_DIR:-${LAB_DIR}/results}/pacman-native-stall.json"
stdout="${LAB_DIR}/fixtures/stall-test.stdout"
stderr="${LAB_DIR}/fixtures/stall-test.stderr"

set +e
timeout 30 python3 "${LAB_DIR}/bin/run-pacman-mock.py" \
  --mode native --parallel 3 --delay 12 --output "${result}" \
  >"${stdout}" 2>"${stderr}"
rc=$?
set -e

if (( rc == 124 )); then
  printf 'FAIL native stall harness itself timed out (rc=124)\n' >&2
  exit 1
fi
if (( rc == 0 )); then
  printf 'FAIL native pacman unexpectedly succeeded against a zero-byte stall\n' >&2
  exit 1
fi
python3 - "${result}" <<'PY'
import json
import sys
from pathlib import Path

result = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
if result.get("sync_exit_code") == 0:
    raise SystemExit("sync unexpectedly returned zero")
if float(result.get("sync_elapsed_seconds", 0)) < 9:
    raise SystemExit(f"native timeout fired too early or was not measured: {result!r}")
needle = "Operation too slow"
stderr = result.get("sync_stderr_tail", "")
if needle not in stderr:
    raise SystemExit(f"expected low-speed timeout text missing: {stderr!r}")
print(f"native stall timeout verified: sync_elapsed={result['sync_elapsed_seconds']}s rc={result['sync_exit_code']}")
PY
