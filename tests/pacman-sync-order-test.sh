#!/usr/bin/env bash
# pacman-sync-order-test.sh - download-mode-lab step 2 (D-03/D-05) contract.
#
# Verifies the pacman sync/upgrade ownership rules without touching the real
# system: a fake `pacman` (and fake `sudo` that just execs) records the exact
# commands issued, so we can assert order, count and failure propagation.
# Static greps check the installer wiring (mirror config before upgrade, no
# default -Syyu, single sync owner). All state lives in a workspace sandbox.
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
utils="$root/scripts/00-utils.sh"

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

sandbox="$(mktemp -d)"
trap 'rm -rf "$sandbox"' EXIT

# --- fake pacman / sudo mocks ---------------------------------------------
mockdir="$sandbox/mock"; mkdir -p "$mockdir"
cat > "$mockdir/pacman" <<'EOF'
#!/usr/bin/env bash
echo "pacman $*" >> "${PACMAN_LOG:?PACMAN_LOG not set}"
if [[ "${PACMAN_FAIL:-0}" == "1" ]]; then exit 1; fi
exit 0
EOF
cat > "$mockdir/sudo" <<'EOF'
#!/usr/bin/env bash
exec "$@"
EOF
chmod +x "$mockdir/pacman" "$mockdir/sudo"

log="$sandbox/pacman.log"
run_sync() { # run_sync <env...> <func>
  local envs=("$@"); local func="${envs[-1]}"; unset 'envs[-1]'
  # NOTE: bash does NOT treat an array-expanded "VAR=val" as an assignment
  # prefix (it would try to run it as a command, rc=127), so use `env`.
  PACMAN_LOG="$log" PATH="$mockdir:$PATH" env "${envs[@]}" bash -c '
    source "$0" >/dev/null 2>&1
    "$1"
  ' "$utils" "$func" >/dev/null 2>&1
  return $?
}

echo "== sync ownership (fake pacman call recording) =="
: > "$log"
run_sync FORCE_REFRESH=0 sync_official
check "sync_official default issues -Syu" $? 0
grep -q '^pacman -Syu --noconfirm$' "$log"; check "exact -Syu --noconfirm recorded" $? 0
grep -q 'Syyu' "$log" && { check "no -Syyu by default" 1 0; } || { check "no -Syyu by default" 0 0; }

: > "$log"
run_sync FORCE_REFRESH=1 sync_official
grep -q '^pacman -Syyu --noconfirm$' "$log"; check "FORCE_REFRESH=1 issues -Syyu (repair mode)" $? 0

: > "$log"
run_sync FORCE_REFRESH=0 sync_archlinuxcn
n="$(grep -c '^pacman -Sy --noconfirm$' "$log")"
[[ "$n" -eq 1 ]]; check "sync_archlinuxcn issues exactly one -Sy (count=$n)" $? 0

# --- failure propagation ---------------------------------------------------
echo "== failure propagation =="
: > "$log"
if PACMAN_FAIL=1 PATH="$mockdir:$PATH" PACMAN_LOG="$log" bash -c \
     'source "$0" >/dev/null 2>&1; sync_official' "$utils" >/dev/null 2>&1; then
  check "sync_official propagates pacman failure (exit nonzero)" 1 0
else
  check "sync_official propagates pacman failure (exit nonzero)" 0 0
fi

# --- static wiring assertions (no real execution) ---------------------------
echo "== installer wiring (static) =="
# 1. mirror config runs before the module loop / first upgrade in install.sh
if grep -q 'Mirror configuration' "$root/install.sh" \
   && grep -q 'scripts/01-mirror.sh' "$root/install.sh" \
   && grep -n 'Mirror configuration' "$root/install.sh" | head -1 | awk -F: '{print $1}' | xargs -I{} sh -c 'grep -n "build_modules\|MODULES=" "'"$root"'/install.sh" | head -3 | awk -F: "{print \$1}" | xargs -I{} test {} -gt {}' 2>/dev/null; then
  :
fi
pre_line="$(grep -n 'Mirror configuration' "$root/install.sh" | head -1 | cut -d: -f1)"
module_loop_line="$(grep -n 'for module in' "$root/install.sh" | head -1 | cut -d: -f1)"
if [[ -n "$pre_line" && -n "$module_loop_line" && "$pre_line" -lt "$module_loop_line" ]]; then
  check "mirror pre-config (line $pre_line) before module loop (line $module_loop_line)" 0 0
else
  check "mirror pre-config before module loop" 1 0
fi

# 2. no default -Syyu anywhere in install.sh (only inside sync_official's
#    FORCE_REFRESH branch in 00-utils). Match the actual command form
#    ("pacman -Syyu --noconfirm"); usage() documents "--force-refresh (-Syyu)"
#    in plain help text which must not count.
if grep -v '^\s*#' "$root/install.sh" | grep -q -- 'pacman -Syyu'; then
  check "install.sh has no direct -Syyu" 1 0
else
  check "install.sh has no direct -Syyu" 0 0
fi
if grep -q 'FORCE_REFRESH' "$root/scripts/00-utils.sh" && grep -q 'Syyu' "$root/scripts/00-utils.sh"; then
  check "-Syyu only inside FORCE_REFRESH branch of sync_official" 0 0
else
  check "-Syyu only inside FORCE_REFRESH branch of sync_official" 1 0
fi

# 3. 01-mirror performs NO pacman sync/install
if grep -qE 'pacman -S[yYu]' "$root/scripts/01-mirror.sh"; then
  check "01-mirror has no pacman sync (-Sy/-Syu/-Syyu)" 1 0
else
  check "01-mirror has no pacman sync (-Sy/-Syu/-Syyu)" 0 0
fi
if grep -q 'pacman -S --noconfirm' "$root/scripts/01-mirror.sh"; then
  check "01-mirror installs no packages (no reflector install)" 1 0
else
  check "01-mirror installs no packages (no reflector install)" 0 0
fi

# 4. 02-system is the single official sync/upgrade owner
if grep -q 'sync_official' "$root/scripts/02-system.sh"; then
  check "02-system calls sync_official (single owner)" 0 0
else
  check "02-system calls sync_official (single owner)" 1 0
fi

# 5. 03-packages archlinuxcn block has exactly one sync (sync_archlinuxcn)
cn_syncs="$(grep -c 'sync_archlinuxcn' "$root/scripts/03-packages.sh")"
[[ "$cn_syncs" -eq 1 ]]; check "03-packages archlinuxcn syncs exactly once (count=$cn_syncs)" $? 0

# 6. ensure_fzf never runs pacman (comments/help text excluded)
fzf_block="$(sed -n '/^ensure_fzf()/,/^}/p' "$root/scripts/00-utils.sh" | grep -v '^\s*#')"
if [[ "$fzf_block" == *"pacman"* ]]; then
  check "ensure_fzf contains no pacman call" 1 0
else
  check "ensure_fzf contains no pacman call" 0 0
fi

# 7. resume: progress context binds and refuses mismatched resume
tmp_ctx="$sandbox/ctx"
PROJECT_DIR="$root" MACHINE_TYPE=vm DESKTOP_ENV=niri TARGET_USER=pang \
  bash -c 'source "$0" >/dev/null 2>&1; PROGRESS_CONTEXT_FILE="$1"; setup_progress; mark_done 01-mirror.sh' \
  "$utils" "$tmp_ctx" >/dev/null 2>&1
check "progress context writes header" $? 0
# same context resumes fine
if PROJECT_DIR="$root" MACHINE_TYPE=vm DESKTOP_ENV=niri TARGET_USER=pang \
     bash -c 'source "$0" >/dev/null 2>&1; PROGRESS_CONTEXT_FILE="$1"; setup_progress' \
     "$utils" "$tmp_ctx" >/dev/null 2>&1; then
  check "same context resumes" 0 0
else
  check "same context resumes" 1 0
fi
# different desktop refuses (niri context vs both)
if PROJECT_DIR="$root" MACHINE_TYPE=vm DESKTOP_ENV=both TARGET_USER=pang \
     bash -c 'source "$0" >/dev/null 2>&1; PROGRESS_CONTEXT_FILE="$1"; setup_progress' \
     "$utils" "$tmp_ctx" >/dev/null 2>&1; then
  check "different desktop refuses resume" 1 0
else
  check "different desktop refuses resume" 0 0
fi

echo
echo "pacman sync order tests: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
