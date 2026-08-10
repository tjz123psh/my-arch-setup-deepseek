#!/usr/bin/env bash
# bootstrap-mirror-plan-test.sh - mock regression for bootstrap-mirror-plan.sh.
# Round 2 contract: exit codes ok=0/invalid=2/unavailable=3/degraded=4/
# timeout=124; allowlist subset; workspace-only atomic outputs; partial TSV on
# timeout; sort by weight then REAL time then base. Red tests first: speed
# ordering (zfast/mmid/aslow) and exit-code contract must FAIL against the
# old -k5/exit-0 implementation before the fix.
# shellcheck disable=SC2016  # expected Server lines intentionally contain literal $repo/$arch
set -Eeuo pipefail

LAB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
bin="$LAB_DIR/bin/bootstrap-mirror-plan.sh"
# sandbox MUST live under fixtures/tmp/ (workspace), never /tmp
mkdir -p "$LAB_DIR/fixtures/tmp"
sandbox="$(mktemp -d "$LAB_DIR/fixtures/tmp/bmp-test.XXXXXX")"
trap 'rm -rf "$sandbox"' EXIT

pass=0
fail=0
check() { # check <desc> <rc> <expected_rc>
  local desc="$1" rc="$2" expected="$3"
  if [[ "$rc" -eq "$expected" ]]; then
    pass=$((pass + 1)); printf '  ok   %s\n' "$desc"
  else
    fail=$((fail + 1)); printf '  FAIL %s (rc=%s expected=%s)\n' "$desc" "$rc" "$expected"
  fi
}

# --- fake curl: delays + distinct bytes so time-order and byte-order differ --
cat > "$sandbox/curl" <<'EOF'
#!/usr/bin/env bash
url="${@: -1}"
case "$url" in
  *"aslow"*)  sleep 0.20; echo "206 100" ;;
  *"mmid"*)   sleep 0.10; echo "206 200" ;;
  *"zfast"*)  sleep 0.01; echo "206 300" ;;
  # distinct fixed latencies: total_seconds is stable and sortable
  *"fast1"*) sleep 0.01; echo "206 262144" ;;
  *"fast2"*) sleep 0.02; echo "206 262144" ;;
  *"fast3"*) sleep 0.03; echo "206 262144" ;;
  *"fast4"*) sleep 0.04; echo "206 262144" ;;
  *"slow200"*) sleep 0.05; echo "200 262144" ;;
  *"dns1"*|*"dns2"*) exit 6 ;;
  *"tls1"*) exit 35 ;;
  *"http500"*) echo "500 0" ;;
  *"slowtimeout"*) sleep "${FAKE_SLEEP:-0.3}"; exit 28 ;;
  *) exit 7 ;;
esac
EOF
chmod +x "$sandbox/curl"

# --- test-only allowlist (real allowlist FILE, not a regex) ---
cat > "$sandbox/allowlist" <<'EOF'
# test allowlist for bootstrap-mirror-plan mock
https://m/fast1
https://m/fast2
https://m/fast3
https://m/fast4
https://m/slow200
https://m/dns1
https://m/dns2
https://m/tls1
https://m/http500
https://m/slowtimeout1
https://m/slowtimeout2
https://m/slowtimeout3
https://m/slowtimeout4
https://m/slowtimeout5
https://m/slowtimeout6
https://m/slowtimeout7
https://m/slowtimeout8
https://m/zfast
https://m/mmid
https://m/aslow
EOF

# run_plan <expected_rc> <bases> [extra args...] ; fresh outputs each time
run_plan() {
  local expected="$1" bases="$2"; shift 2
  rm -f "$sandbox/out.tsv" "$sandbox/out.servers"
  local rc=0
  PATH="$sandbox:$PATH" FAKE_SLEEP="${FAKE_SLEEP:-0.3}" \
    bash "$bin" --allowlist "$sandbox/allowlist" --bases "$bases" \
      --output-tsv "$sandbox/out.tsv" --output-servers "$sandbox/out.servers" "$@" \
      >"$sandbox/r.out" 2>&1 || rc=$?
  check "rc=$expected (bases='$bases')" "$rc" "$expected"
}
assert_grep() { # assert_grep <desc> -P <pattern> <file> | <desc> <pattern> <file>
  local desc="$1"
  if [[ "$2" == "-P" ]]; then
    if grep -qP "$3" "$4"; then check "$desc" 0 0; else check "$desc" 1 0; fi
  else
    if grep -q "$2" "$3"; then check "$desc" 0 0; else check "$desc" 1 0; fi
  fi
}
assert_empty() { if [[ ! -s "$2" ]]; then check "$1" 0 0; else check "$1" 1 0; fi }
assert_not_exists() { if [[ ! -e "$2" ]]; then check "$1" 0 0; else check "$1" 1 0; fi }
assert_eq() { if [[ "$2" == "$3" ]]; then check "$1" 0 0; else check "$1" 1 0; fi }
servers_base() { sed -n "${1}p" "$sandbox/out.servers" | cut -d' ' -f3 | cut -d/ -f1-4; }

echo "== 1. deps: each missing dep -> unavailable exit 3 =="
mkdir -p "$sandbox/minbin"
for t in date sort awk timeout xargs mktemp grep tr cut cp rm sed realpath; do
  ln -sf "$(command -v "$t")" "$sandbox/minbin/$t" 2>/dev/null || true
done
for dep in curl date sort awk timeout xargs mktemp grep tr cut cp rm sed realpath; do
  rm -f "$sandbox/minbin/$dep"
  rc=0
  PATH="$sandbox/minbin" "$(command -v bash)" "$bin" \
    --allowlist "$sandbox/allowlist" --output-tsv "$sandbox/o1.tsv" --output-servers "$sandbox/o1.sv" \
    >"$sandbox/d.out" 2>&1 || rc=$?
  assert_grep "missing $dep -> unavailable" "STATUS unavailable missing_dep=.*${dep}" "$sandbox/d.out"
  check "missing $dep exit 3" "$rc" 3
  ln -sf "$(command -v "$dep")" "$sandbox/minbin/$dep" 2>/dev/null || true
done

echo "== 2. four+ healthy -> ok exit 0, 4 servers =="
run_plan 0 "https://m/fast1 https://m/fast2 https://m/fast3 https://m/fast4"
assert_grep "status ok ok=4" 'STATUS ok ok=4' "$sandbox/r.out"
assert_eq "4 server lines" "$(wc -l < "$sandbox/out.servers")" "4"

echo "== 3. 206/200 mix: 200 ranked after all 206 =="
run_plan 0 "https://m/slow200 https://m/fast1 https://m/fast2"
assert_eq "fast1 first (206)" "$(servers_base 1)" "https://m/fast1"
assert_eq "slow200 last (200 fallback)" "$(servers_base 3)" "https://m/slow200"

echo "== 4. only 1-2 usable -> degraded, exit 4, no servers (RED: old rc=0) =="
run_plan 4 "https://m/fast1 https://m/fast2 https://m/slowtimeout1 https://m/slowtimeout2"
assert_grep "degraded status" 'STATUS degraded' "$sandbox/r.out"
assert_not_exists "degraded emits no servers" "$sandbox/out.servers"

echo "== 5. all timeout -> unavailable, exit 3, no servers (RED: old rc=0) =="
run_plan 3 "https://m/slowtimeout1 https://m/slowtimeout2 https://m/slowtimeout3 https://m/slowtimeout4"
assert_grep "unavailable status" 'STATUS unavailable' "$sandbox/r.out"
assert_not_exists "unavailable emits no servers" "$sandbox/out.servers"

echo "== 6. DNS/TLS/HTTP failures preserved =="
run_plan 0 "https://m/fast1 https://m/fast2 https://m/fast3 https://m/dns1 https://m/tls1 https://m/http500"
assert_grep "dns rc=6 row" -P 'dns1\t6\t000' "$sandbox/out.tsv"
assert_grep "tls rc=35 row" -P 'tls1\t35\t000' "$sandbox/out.tsv"
assert_grep "http500 row" -P 'http500\t0\t500' "$sandbox/out.tsv"

echo "== 7. dup dedup + base not in allowlist -> invalid exit 2 =="
run_plan 4 "https://m/fast1 https://m/fast1 https://m/fast2 https://m/dns1"
assert_grep "dup dedup -> 2 usable -> degraded" 'STATUS degraded' "$sandbox/r.out"
run_plan 2 "https://m/fast1 https://m/fast2 https://m/evil.example.com"
assert_grep "arbitrary-but-valid URL not in allowlist rejected" 'STATUS invalid base_not_in_allowlist' "$sandbox/r.out"

echo "== 8. exact Server lines (literal \$repo/\$arch, no extra/dup) =="
run_plan 0 "https://m/fast1 https://m/fast2 https://m/fast3"
n_lines="$(wc -l < "$sandbox/out.servers")"
assert_eq "exactly 3 lines" "$n_lines" "3"
# shellcheck disable=SC2016  # expected Server lines use literal $repo/$arch
assert_eq "line1 exact" "$(sed -n 1p "$sandbox/out.servers")" 'Server = https://m/fast1/$repo/os/$arch'
assert_eq "line2 exact" "$(sed -n 2p "$sandbox/out.servers")" 'Server = https://m/fast2/$repo/os/$arch'
assert_eq "line3 exact" "$(sed -n 3p "$sandbox/out.servers")" 'Server = https://m/fast3/$repo/os/$arch'
assert_eq "no duplicate lines" "$(sort "$sandbox/out.servers" | uniq -d | wc -l)" "0"
assert_eq "no missing placeholder" "$(grep -c '\$repo/os/\$arch' "$sandbox/out.servers")" "3"

echo "== 9. hard budget -> timeout exit 124, partial TSV, no servers =="
rc=0
rm -f "$sandbox/out.tsv" "$sandbox/out.servers"
# FAKE_SLEEP=0.7: first P4 batch (0.7s) fits under budget 1s, two batches
# (1.4s) exceed it -> timeout with a partial (not all 8) TSV, stably.
PATH="$sandbox:$PATH" FAKE_SLEEP=0.7 HARD_BUDGET=1 \
  bash "$bin" --allowlist "$sandbox/allowlist" \
    --bases "https://m/slowtimeout1 https://m/slowtimeout2 https://m/slowtimeout3 https://m/slowtimeout4 https://m/slowtimeout5 https://m/slowtimeout6 https://m/slowtimeout7 https://m/slowtimeout8" \
    --output-tsv "$sandbox/out.tsv" --output-servers "$sandbox/out.servers" \
    >"$sandbox/r.out" 2>&1 || rc=$?
check "timeout exit 124" "$rc" 124
assert_grep "timeout status" 'STATUS timeout' "$sandbox/r.out"
assert_grep "partial TSV written" 'partial_tsv_written=1' "$sandbox/r.out"
assert_not_exists "timeout never writes servers" "$sandbox/out.servers"
rows="$(wc -l < "$sandbox/out.tsv")"
if (( rows < 8 )); then
  check "partial TSV is partial (rows=$rows/8)" 0 0
else
  check "partial TSV is partial (got $rows, want <8)" 1 0
fi

echo "== 10. deterministic output =="
run_plan 0 "https://m/fast1 https://m/fast2 https://m/slow200"
cp "$sandbox/out.servers" "$sandbox/s1"
run_plan 0 "https://m/fast1 https://m/fast2 https://m/slow200"
if diff -q "$sandbox/s1" "$sandbox/out.servers" >/dev/null; then
  check "identical input -> identical servers" 0 0
else
  check "identical input -> identical servers" 1 0
fi

echo "== 11. RED: real-time ordering zfast < mmid < aslow (old -k5 sorts bytes) =="
run_plan 0 "https://m/aslow https://m/mmid https://m/zfast"
assert_eq "first is zfast (fastest)" "$(servers_base 1)" "https://m/zfast"
assert_eq "second is mmid" "$(servers_base 2)" "https://m/mmid"
assert_eq "third is aslow (slowest)" "$(servers_base 3)" "https://m/aslow"

echo "== 12. config validation: JOBS/budget bounds -> invalid exit 2 =="
for bad in "JOBS=0" "JOBS=-1" "JOBS=abc" "JOBS=99" "HARD_BUDGET=0" "HARD_BUDGET=1000" "MAX_TIME=-5"; do
  rc=0
  env $bad PATH="$sandbox:$PATH" \
    bash "$bin" --allowlist "$sandbox/allowlist" --bases "https://m/fast1" \
      --output-tsv "$sandbox/o2.tsv" --output-servers "$sandbox/o2.sv" \
      >"$sandbox/v.out" 2>&1 || rc=$?
  check "invalid $bad -> exit 2" "$rc" 2
done

echo "== 13. output path guards -> invalid exit 2 =="
# outside workspace
rc=0
PATH="$sandbox:$PATH" bash "$bin" --allowlist "$sandbox/allowlist" --bases "https://m/fast1" \
  --output-tsv "/tmp/evil.tsv" --output-servers "$sandbox/out.sv" >"$sandbox/o3.out" 2>&1 || rc=$?
check "outside-workspace tsv -> invalid" "$rc" 2
assert_grep "outside flagged" 'STATUS invalid tsv_outside_workspace' "$sandbox/o3.out"
# same path
rc=0
PATH="$sandbox:$PATH" bash "$bin" --allowlist "$sandbox/allowlist" --bases "https://m/fast1" \
  --output-tsv "$sandbox/same.tsv" --output-servers "$sandbox/same.tsv" >"$sandbox/o4.out" 2>&1 || rc=$?
check "same output path -> invalid" "$rc" 2
assert_grep "same path flagged" 'STATUS invalid same_output_path' "$sandbox/o4.out"
# pre-existing output file
: > "$sandbox/preexists.tsv"
rc=0
PATH="$sandbox:$PATH" bash "$bin" --allowlist "$sandbox/allowlist" --bases "https://m/fast1" \
  --output-tsv "$sandbox/preexists.tsv" --output-servers "$sandbox/out.sv" >"$sandbox/o5.out" 2>&1 || rc=$?
check "pre-existing tsv -> invalid" "$rc" 2
assert_grep "pre-existing flagged" 'STATUS invalid tsv_already_exists' "$sandbox/o5.out"
# symlinked parent dir
mkdir -p "$sandbox/realparent"
ln -s "$sandbox/realparent" "$sandbox/linkparent"
rc=0
PATH="$sandbox:$PATH" bash "$bin" --allowlist "$sandbox/allowlist" --bases "https://m/fast1" \
  --output-tsv "$sandbox/linkparent/o.tsv" --output-servers "$sandbox/out.sv" >"$sandbox/o6.out" 2>&1 || rc=$?
check "symlinked parent -> invalid" "$rc" 2
assert_grep "symlink parent flagged" 'STATUS invalid tsv_parent_is_symlink' "$sandbox/o6.out"

echo
echo "bootstrap mirror plan tests: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
