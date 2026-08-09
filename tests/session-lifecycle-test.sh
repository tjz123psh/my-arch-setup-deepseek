#!/usr/bin/env bash
# session-lifecycle-test.sh - regression for the desktop/session lifecycle
# (R5, 2026-08-09: ALIGNED WITH THE PHYSICAL MACHINE - the Round-4
# uwsm-managed Hyprland design was removed because it was never validated in
# a real VM session and failed there. The Hyprland session entry is the
# hyprland package's STOCK /usr/share/wayland-sessions/hyprland.desktop
# (Exec=/usr/bin/start-hyprland); DMS starts via the autostart daemon in
# autostart.lua. Fresh installs do NOT install uwsm).
#
# REJECTED architectures:
#   Round 2 - oneshot watcher (pgrep polling, HYPR_WATCH_TIMEOUT=43200,
#             sleep-1 loop, niri.service.d ExecStop drop-in, timeout-as-crash)
#   Round 3 - custom systemd units + launcher (hyprland.service,
#             hyprland-shutdown.target, hyprland-session, user-level
#             ~/.local/share/wayland-sessions/hyprland.desktop)
#   Round 4 - uwsm-managed Hyprland (hyprland-uwsm.desktop,
#             Exec=uwsm start -e -D Hyprland hyprland.desktop, greeter
#             memory migration to the uwsm entry)
#
# dms-greeter scans the system dirs + the greeter cache (HOME/XDG_DATA_HOME
# point at /var/cache/dms-greeter, NOT the target user's ~/.local/share), so
# a user-level desktop entry is invisible to the greeter; 08-services still
# verifies the system entry (Exec=/usr/bin/start-hyprland) and fails closed
# on a user/local hyprland.desktop override.
#
# Suites:
#   A  validator pure predicate + source-time abort
#   B  setup_progress refuses invalid desktop (no progress written)
#   C  module_selected selects NOTHING on invalid desktop
#   D  Round-2/3 custom lifecycle artifacts are ABSENT from the repo
#   E  dms-greeter real scan path (fake greeter HOME/XDG_DATA_HOME)
#   F  DESKTOP_ENV=none: no dms requirement, convergence disable, cleanup
#   G  DMS required in niri/both; stock Hyprland entry preflight
#   H  stale-cleanup safety: parent symlinks, non-regular files, backup
#   I  tool-missing is recorded UNAVAILABLE, never PASS (subshell probe)
#   J  system Hyprland entry: Exec + desktop-file-validate classification
#   K  systemd-analyze verify of dms.service (the enabled runtime chain)
#   L  sandbox inside workspace
set -Eeuo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
utils="$root/scripts/00-utils.sh"
services="$root/scripts/08-services.sh"
# all temp state lives INSIDE the workspace (Codex R3/R4.1: no /tmp)
mkdir -p "$root/download-mode-lab/fixtures/tmp"
sandbox="$(mktemp -d "$root/download-mode-lab/fixtures/tmp/session-test.XXXXXX")"
# live fake-backend pids from suite M (comm=dms sh processes); the EXIT trap
# kills them by EXACT PID only (never by process name, which could hit the
# real host dms) and waits to reap them, so no /proc comm=dms test process
# outlives the suite even if a test aborts mid-M.
live_pids=""
trap 'for p in $live_pids; do pkill -P "$p" 2>/dev/null || true; kill "$p" 2>/dev/null || true; done; for p in $live_pids; do wait "$p" 2>/dev/null || true; done; rm -rf "$sandbox"' EXIT

# real host greeter memory hash captured BEFORE any run; asserted unchanged
# at the end (R4.3: no failure path may touch /var/cache/dms-greeter)
real_mem="/var/cache/dms-greeter/.local/state/memory.json"
if [[ -e "$real_mem" || -L "$real_mem" ]]; then
  real_mem_before="$(sha256sum "$(readlink -f "$real_mem" 2>/dev/null || echo "$real_mem")" 2>/dev/null | cut -d' ' -f1 || echo unreadable)"
else
  real_mem_before="absent"
fi

pass=0
fail=0
known=0
unavail=0
check() { # check <desc> <rc> <expected_rc>
  local desc="$1" rc="$2" expected="$3"
  if [[ "$rc" -eq "$expected" ]]; then
    pass=$((pass + 1)); printf '  ok   %s\n' "$desc"
  else
    fail=$((fail + 1)); printf '  FAIL %s (rc=%s expected=%s)\n' "$desc" "$rc" "$expected"
  fi
}
assert_grep() { # assert_grep <desc> <pattern> <file>
  if grep -q "$2" "$3"; then check "$1" 0 0; else check "$1" 1 0; fi
}
assert_eq() { if [[ "$2" == "$3" ]]; then check "$1" 0 0; else check "$1" 1 0; fi }
unavail_note() { # unavail_note <desc>  (never counted as PASS)
  unavail=$((unavail + 1)); printf '  UNAVAIL %s\n' "$1"
}
lineno() { # lineno <pattern> <file> ; echoes first matching line number (empty if none)
  grep -n "$1" "$2" 2>/dev/null | head -1 | cut -d: -f1 || true
}

# exact sha256 of the Round-3 deployed artifacts + hyprland-session.target
# (recorded 2026-08-09 from the Round-3 working tree and git HEAD; the
# cleanup in 00-utils.sh matches the same constants, so drift fails loudly).
H_HYPR_SERVICE="ff6da6b7d78e0b5e4a475f58564869686486b79e6d37d25a03665c97bdb35dee"
H_HYPR_SHUTDOWN="0179017381c0f7776eaf8864b0a9e7837c5670bc4647dbb22542dc97e6748d04"
H_HYPR_LAUNCHER="1458b11f7dd66de2003b3c2420bbb9e4468e0b86a9b2a631ebf15d9f609df292"
H_HYPR_DESKTOP="87e64bd4778592375bd321e3930dcdf036f86d9f65661aeffa5fd5c6ce04e502"
H_HYPR_TARGET="3cb35ba962ada9f0298ff627b225f29b44c2e9e2757cacdbdfa21c0e55be609f"

echo "== A. desktop validator (source-time, pure predicate) =="
rc=0
DESKTOP_ENV=hyprland bash -c 'source "$0" >/dev/null 2>&1' "$utils" 2>/dev/null || rc=$?
check "DESKTOP_ENV=hyprland source aborts (exit 2)" "$rc" 2
rc=0
DESKTOP_ENV=bogus bash -c 'source "$0" >/dev/null 2>&1' "$utils" 2>/dev/null || rc=$?
check "DESKTOP_ENV=bogus source aborts (exit 2)" "$rc" 2
rc=0
DESKTOP_ENV=none bash -c 'source "$0" >/dev/null 2>&1' "$utils" 2>/dev/null || rc=$?
check "DESKTOP_ENV=none source ok" "$rc" 0
out="$(bash -c 'source "$0" >/dev/null 2>&1; validate_desktop_env niri' "$utils")"
assert_eq "validate_desktop_env prints nothing for legal value" "$out" ""

echo "== B. setup_progress refuses invalid desktop (no progress written) =="
prog="$sandbox/prog"
rc=0
PROJECT_DIR="$root" bash -c 'source "$0" >/dev/null 2>&1; DESKTOP_ENV=hyprland; PROGRESS_CONTEXT_FILE="$1"; setup_progress' "$utils" "$prog" 2>/dev/null || rc=$?
check "setup_progress rejects hyprland (exit 2)" "$rc" 2
rc=0; [[ ! -e "$prog" ]] || rc=1
check "no progress file written for invalid desktop" "$rc" 0

echo "== C. module_selected selects NOTHING on invalid desktop (incl. desktop-shared) =="
sel() { bash -c 'source "$0" >/dev/null 2>&1; DESKTOP_ENV="$1"; if module_selected x "$2"; then echo SELECT; else echo REJECT; fi' "$utils" "$1" "$2"; }
assert_eq "hyprland: wm-niri rejected" "$(sel hyprland wm-niri)" "REJECT"
assert_eq "hyprland: wm-hyprland rejected" "$(sel hyprland wm-hyprland)" "REJECT"
assert_eq "hyprland: desktop-shared rejected" "$(sel hyprland desktop-shared)" "REJECT"
assert_eq "hyprland: repository-tools rejected" "$(sel hyprland repository-tools)" "REJECT"
assert_eq "bogus: desktop-shared rejected" "$(sel bogus desktop-shared)" "REJECT"
assert_eq "both: wm-niri selected" "$(sel both wm-niri)" "SELECT"
assert_eq "both: wm-hyprland selected" "$(sel both wm-hyprland)" "SELECT"
assert_eq "both: desktop-shared selected" "$(sel both desktop-shared)" "SELECT"
assert_eq "niri: wm-hyprland rejected" "$(sel niri wm-hyprland)" "REJECT"

echo "== D. Round-2/3 custom lifecycle artifacts are ABSENT from the repo =="
for f in \
  "$root/config/home/.config/systemd/user/hyprland.service" \
  "$root/config/home/.config/systemd/user/hyprland-shutdown.target" \
  "$root/config/home/.config/systemd/user/hyprland-session.service" \
  "$root/config/home/.config/systemd/user/hyprland-session.target" \
  "$root/config/home/.config/systemd/user/niri.service.d/session-cleanup.conf" \
  "$root/config/home/.local/bin/hyprland-session" \
  "$root/config/home/.local/bin/hyprland-session-watch" \
  "$root/config/home/.local/bin/hyprland-session-start" \
  "$root/config/home/.local/share/wayland-sessions/hyprland.desktop" \
; do
  if [[ -e "$f" ]]; then check "Round-2/3 artifact absent: ${f#$root/}" 0 1; else check "Round-2/3 artifact absent: ${f#$root/}" 1 1; fi
done
if [[ -d "$root/config/home/.local/share/wayland-sessions" ]]; then
  check "wayland-sessions user dir absent" 0 1
else
  check "wayland-sessions user dir absent" 1 1
fi
# no polling watcher / fixed timeout / launcher patterns in the shipped
# config tree (helper pgrep guards in autostart are fine; a maintenance
# script's scoped `reset-failed <unit>` is legitimate and not matched)
if grep -rqE 'HYPR_WATCH_TIMEOUT|43200|systemctl --user --wait' "$root/config/home" 2>/dev/null; then
  check "no watcher/timeout/launcher patterns in config/home" 1 0
else
  check "no watcher/timeout/launcher patterns in config/home" 0 0
fi
if grep -rq 'hyprland-session\b\|hyprland-shutdown' "$root/config/home" 2>/dev/null; then
  check "no hyprland-session/hyprland-shutdown references in config/home" 1 0
else
  check "no hyprland-session/hyprland-shutdown references in config/home" 0 0
fi
# the exit-status-propagation mock (fake systemctl returning 42) is gone
# (the [R]C bracket keeps the grep from matching its own source line)
if grep -q 'FAKE_START_[R]C' "$0"; then
  check "no fake-42 exit-status mock in this suite" 1 0
else
  check "no fake-42 exit-status mock in this suite" 0 0
fi

echo "== E. dms-greeter real scan path (greeter HOME != target user HOME) =="
# Replicates dms-greeter (dank-greeter) GreeterContent.qml: sessionDirs =
# [/usr/share/wayland-sessions, /usr/share/xsessions, /usr/local/share/*,
#  $HOME/.local/share/*, XDG_DATA_DIRS/*] reversed (user dirs scanned first,
#  so same-Name entries shadow system ones), _parseDesktopFile (Name/Exec),
#  _addSession (skip if the Name is already present).
greeter_scan() { # greeter_scan <fakeroot> <greeter_home> <xdg_data_dirs>
  local froot="$1" ghome="$2" xdg_data_dirs="$3"
  local -a dirs=(
    "$froot/usr/share/wayland-sessions" "$froot/usr/share/xsessions"
    "$froot/usr/local/share/wayland-sessions" "$froot/usr/local/share/xsessions"
  )
  if [[ -n "$ghome" ]]; then
    dirs+=("$ghome/.local/share/wayland-sessions" "$ghome/.local/share/xsessions")
  fi
  if [[ -n "$xdg_data_dirs" ]]; then
    local d xparts
    IFS=':' read -r -a xparts <<< "$xdg_data_dirs"
    for d in "${xparts[@]}"; do
      [[ -n "$d" ]] && dirs+=("$d/wayland-sessions" "$d/xsessions")
    done
  fi
  local -a names=() execs=() paths=() ids=()
  local i dir f line name exec n
  for (( i=${#dirs[@]}-1; i>=0; i-- )); do
    dir="${dirs[$i]}"
    [[ -d "$dir" ]] || continue
    for f in "$dir"/*.desktop; do
      [[ -f "$f" ]] || continue
      name=""; exec=""
      while IFS= read -r line; do
        [[ -z "$name" && "$line" == Name=* ]] && name="${line#Name=}"
        [[ -z "$exec" && "$line" == Exec=* ]] && exec="${line#Exec=}"
        [[ -n "$name" && -n "$exec" ]] && break
      done < "$f"
      for n in "${names[@]}"; do [[ "$n" == "$name" ]] && name=""; done
      [[ -z "$name" || -z "$exec" ]] && continue
      names+=("$name"); execs+=("$exec"); paths+=("$f"); ids+=("$(basename "$f" .desktop)")
    done
  done
  for ((i=0; i<${#names[@]}; i++)); do
    printf '%s|%s|%s|%s\n' "${names[$i]}" "${execs[$i]}" "${paths[$i]}" "${ids[$i]}"
  done
}
froot="$sandbox/greeter-root"
mkdir -p "$froot/usr/share/wayland-sessions" "$froot/usr/local/share/wayland-sessions"
mkdir -p "$froot/home/pang/.local/share/wayland-sessions" "$froot/var/cache/dms-greeter/.local/share/wayland-sessions"
cat > "$froot/usr/share/wayland-sessions/hyprland.desktop" <<'EOF'
[Desktop Entry]
Name=Hyprland
Comment=An intelligent dynamic tiling Wayland compositor
Exec=/usr/bin/start-hyprland
Type=Application
DesktopNames=Hyprland
Keywords=tiling;wayland;compositor;
EOF
cat > "$froot/usr/share/wayland-sessions/hyprland-uwsm.desktop" <<'EOF'
[Desktop Entry]
Name=Hyprland (uwsm-managed)
Comment=An intelligent dynamic tiling Wayland compositor
Exec=uwsm start -e -D Hyprland hyprland.desktop
TryExec=uwsm
DesktopNames=Hyprland
Type=Application
EOF
cat > "$froot/usr/share/wayland-sessions/niri.desktop" <<'EOF'
[Desktop Entry]
Name=Niri
Comment=A scrollable-tiling Wayland compositor
Exec=/usr/bin/niri-session
Type=Application
EOF
# the Round-3 user-level entry at the TARGET USER's home - invisible to the
# greeter because greeter HOME is the cache dir, not /home/pang
cat > "$froot/home/pang/.local/share/wayland-sessions/hyprland.desktop" <<'EOF'
[Desktop Entry]
Name=Hyprland
Exec=/home/pang/.local/bin/hyprland-session
Type=Application
EOF
# a greeter-cache override with the same Name shadows the system entry
cat > "$froot/var/cache/dms-greeter/.local/share/wayland-sessions/hyprland.desktop" <<'EOF'
[Desktop Entry]
Name=Hyprland
Exec=/bin/echo cache-override
Type=Application
EOF
# launcher.go sets HOME=<cache> + XDG_DATA_HOME and leaves XDG_DATA_DIRS
# unset for the greeter, so the greeter cache dirs are scanned FIRST and
# same-Name entries there shadow the system ones. Scan with xdg_data_dirs="".
scan="$(greeter_scan "$froot" "$froot/var/cache/dms-greeter" "")"
if grep -q '^Hyprland (uwsm-managed)|uwsm start -e -D Hyprland hyprland.desktop|.*hyprland-uwsm.desktop|hyprland-uwsm$' <<<"$scan"; then
  check "greeter discovers hyprland-uwsm.desktop (Exec=uwsm start ...)" 0 0
else
  check "greeter discovers hyprland-uwsm.desktop (Exec=uwsm start ...)" 1 0
  echo "$scan" | sed 's/^/      /'
fi
# E2: the target user's ~/.local/share is NOT scanned (greeter HOME is the
# cache dir). Match the user desktop-dir fragment (the repo itself lives
# under /home/pang, so a bare "/home/pang" grep is wrong).
if grep -q '/home/pang/.local/share/wayland-sessions' <<<"$scan"; then
  check "target-user ~/.local/share NOT scanned by greeter" 1 0
else
  check "target-user ~/.local/share NOT scanned by greeter" 0 0
fi
cached="$(grep '^Hyprland|' <<<"$scan" || true)"
if [[ "$cached" == "Hyprland|/bin/echo cache-override|"* ]]; then
  check "greeter-cache entry shadows system hyprland.desktop by Name" 0 0
else
  check "greeter-cache entry shadows system hyprland.desktop by Name" 1 0
fi
sel_exec="$(awk -F'|' '$4=="hyprland-uwsm"{print $2}' <<<"$scan" | head -1)"
assert_eq "final Exec for hyprland-uwsm selection" "$sel_exec" "uwsm start -e -D Hyprland hyprland.desktop"

echo "== F. DESKTOP_ENV=none: no dms requirement, convergence disable, cleanup =="
mkdir -p "$sandbox/mockbin"
cat > "$sandbox/mockbin/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "systemctl $*" >> "${FAKE_SYS_LOG:?}"
[[ -n "${FAKE_STATE_DIR:-}" ]] && mkdir -p "$FAKE_STATE_DIR"
case "$*" in
  *"enable dms.service"*) exit "${FAKE_DMS_ENABLE_RC:-0}" ;;
  # LoadState query: rc + stdout are both observable (R4.3 item 3)
  *"show -p LoadState"*)
    unit="$(printf '%s' "$*" | sed -n 's/.*LoadState --value \([^ ]*\).*/\1/p')"
    if [[ "${FAKE_QUERY_RC:-0}" != "0" ]]; then
      [[ "${FAKE_QUERY_EMPTY:-0}" != "1" ]] \
        && { [[ -e "${HOME:-/nonexistent}/.config/systemd/user/${unit}" ]] && echo loaded || echo not-found; }
      exit "${FAKE_QUERY_RC}"
    fi
    [[ -e "${HOME:-/nonexistent}/.config/systemd/user/${unit}" ]] && echo loaded || echo not-found
    exit 0 ;;
  # legacy `cat` path kept so an unpatched R4.2 confirm loop still runs
  *"cat hyprland"*)
    unit="$(printf '%s' "$*" | sed -n 's/.*cat \([^ ]*\).*/\1/p')"
    [[ -e "${HOME:-/nonexistent}/.config/systemd/user/${unit}" ]] && exit 0 || exit 1 ;;
  *"disable dms.service"*)
    rc="${FAKE_DMS_DISABLE_RC:-0}"
    if [[ "$rc" -eq 0 && "${FAKE_DMS_DISABLE_KEEP:-0}" != "1" ]]; then
      touch "$FAKE_STATE_DIR/dms.disabled"
      rm -f "${HOME:-/nonexistent}/.config/systemd/user/graphical-session.target.wants/dms.service"
    fi
    exit "$rc" ;;
  *"is-enabled dms.service"*) [[ -f "$FAKE_STATE_DIR/dms.disabled" ]] && exit 1 || exit 0 ;;
  *"disable dsearch.service"*) exit "${FAKE_DSEARCH_DISABLE_RC:-0}" ;;
  *"disable greetd"*)
    rc="${FAKE_GREETD_DISABLE_RC:-0}"
    if [[ "$rc" -eq 0 ]]; then touch "$FAKE_STATE_DIR/greetd.disabled"; fi
    exit "$rc" ;;
  *"is-enabled greetd"*)
    if [[ "${FAKE_GREETD_ISENABLED_RC:-0}" != "0" ]]; then
      [[ -n "${FAKE_GREETD_ISENABLED_OUT:-}" ]] && echo "$FAKE_GREETD_ISENABLED_OUT"
      exit "$FAKE_GREETD_ISENABLED_RC"
    fi
    if [[ -f "$FAKE_STATE_DIR/greetd.disabled" ]]; then echo disabled; exit 1; fi
    echo enabled; exit 0 ;;
  *) exit 0 ;;
esac
EOF
cat > "$sandbox/mockbin/sudo" <<'EOF'
#!/usr/bin/env bash
echo "sudo $*" >> "${FAKE_SYS_LOG:?}"
# system-level systemctl calls go through `run` -> sudo -> mock systemctl
if [[ "$1" == "systemctl" ]]; then
  shift
  exec "$(dirname "$0")/systemctl" "$@"
fi
if [[ "$1" == "useradd" ]]; then exit "${FAKE_USERADD_RC:-0}"; fi
exit 0
EOF
# adversarial python shims (R4.4): a python3 that exits 42, and a dir with
# no python3 at all
mkdir -p "$sandbox/mockbin-nopython"
cat > "$sandbox/mockbin/py42" <<'EOF'
#!/usr/bin/env bash
exit 42
EOF
chmod +x "$sandbox/mockbin/py42"
# controlled PATH for the "PATH has no python3" adversarial case
toolbin="$sandbox/toolbin"
mkdir -p "$toolbin"
for t in id sed head grep cut sha256sum mkdir cp rm chmod cat date find stat touch getent readlink basename dirname tr mktemp sort wc xargs env bash sh; do
  [[ -x "/usr/bin/$t" ]] && ln -sf "/usr/bin/$t" "$toolbin/$t"
done
chmod +x "$sandbox/mockbin/systemctl" "$sandbox/mockbin/sudo"

# fake deployed home: 5 exact Round-3 artifacts (hash-removed), Round-2
# watcher set (detected + warned, never auto-deleted), custom user unit
fakehome="$sandbox/home"
mkdir -p "$fakehome/.config/systemd/user/niri.service.d" \
         "$fakehome/.local/bin" \
         "$fakehome/.local/share/wayland-sessions"
cat > "$fakehome/.config/systemd/user/hyprland.service" <<'EOF'
[Unit]
# Hyprland compositor, systemd-managed (Codex Round 3, mirrors niri.service).
#
# Hyprland 0.56.2 natively supports sd_notify (READY=1 on compositor-ready,
# STOPPING=1 on exit) and manages its OWN systemd + D-Bus activation
# environment on both sides (import on ready, unset on exit) - so this unit
# needs NO extra import/unset helpers and no polling watcher. The
# graphical-session chain is bound exactly like niri.service:
#   BindsTo graphical-session.target   (target stop -> compositor stops)
#   Wants   graphical-session-pre.target + xdg-desktop-autostart.target
#   dms.service is pulled via WantedBy=graphical-session.target, and stops
#   when the target stops (PartOf=graphical-session.target on dms.service).
#
# Started with `systemctl --user --wait start` by the hyprland-session
# launcher (greetd desktop entry); on exit the launcher starts
# hyprland-shutdown.target (Conflicts=graphical-session*) which tears the
# session chain down and propagates the real exit status.
Description=Hyprland compositor
BindsTo=graphical-session.target
Before=graphical-session.target
Wants=graphical-session-pre.target
After=graphical-session-pre.target

Wants=xdg-desktop-autostart.target
Before=xdg-desktop-autostart.target

[Service]
Slice=session.slice
Type=notify
ExecStart=/usr/bin/Hyprland
EOF
cat > "$fakehome/.config/systemd/user/hyprland-shutdown.target" <<'EOF'
[Unit]
# Hyprland shutdown target (Codex Round 3, mirrors niri-shutdown.target).
# Started by the hyprland-session launcher after the compositor exits; the
# Conflicts= forcibly stops the graphical session chain (graphical-session
# target/pre-target), which propagates to dms.service via its PartOf, and to
# any still-running xdg-desktop-autostart work via the target teardown.
Description=Shutdown running Hyprland session
DefaultDependencies=no
StopWhenUnneeded=true

Conflicts=graphical-session.target graphical-session-pre.target
After=graphical-session.target graphical-session-pre.target
EOF
cat > "$fakehome/.config/systemd/user/hyprland-session.target" <<'EOF'
[Unit]
# Hyprland session lifecycle target (review 6.2/6.3).
# start-hyprland does not touch graphical-session.target, so dms.service
# (WantedBy=graphical-session.target) never auto-starts in a Hyprland
# session. Hyprland's exec-once starts THIS target, which pulls in
# graphical-session.target (and with it dms.service, running under systemd
# with restart/status/journal) plus the XDG autostart target, mirroring the
# niri.service lifecycle (BindsTo=graphical-session.target).
Description=Hyprland session
Wants=graphical-session.target xdg-desktop-autostart.target
After=graphical-session.target xdg-desktop-autostart.target
EOF
cat > "$fakehome/.local/bin/hyprland-session" <<'EOF'
#!/usr/bin/env bash
# hyprland-session - managed Hyprland session launcher (greetd/dms-greeter
# desktop-entry Exec). Mirrors /usr/bin/niri-session:
#   systemctl --user --wait start hyprland.service
#     -> blocks until the compositor exits (normal logout OR crash)
#   systemctl --user start --job-mode=replace-irreversibly hyprland-shutdown.target
#     -> Conflicts=graphical-session* forcibly stops the session chain
#        (dms.service stops via PartOf=graphical-session.target)
#   exit with the compositor/service's REAL exit status
#
# Hyprland 0.56.2 manages its own systemd + D-Bus activation environment on
# compositor ready/exit, so no manual import/unset helper is needed here and
# no unrelated variables (token/cookie/...) are ever imported.
set -Eeuo pipefail

if systemctl --user -q is-active hyprland.service; then
  echo "A Hyprland session is already running." >&2
  exit 1
fi

systemctl --user reset-failed

# Start Hyprland and wait for it to terminate (normal or crash - sd_notify
# drops either way, systemd records the real exit status). Capture the rc
# under set -e so teardown below still runs on a crash.
if systemctl --user --wait start hyprland.service; then
  rc=0
else
  rc=$?
  echo "Hyprland exited with status ${rc}" >&2
fi

# Force stop of the graphical session chain now that the compositor is gone.
systemctl --user start --job-mode=replace-irreversibly hyprland-shutdown.target

exit "$rc"
EOF
cat > "$fakehome/.local/share/wayland-sessions/hyprland.desktop" <<'EOF'
[Desktop Entry]
# User-level Hyprland wayland-session entry (Codex Round 3).
# Overrides /usr/share/wayland-sessions/hyprland.desktop (which Execs the
# stock /usr/bin/start-hyprland) so dms-greeter's Hyprland session launches
# the managed systemd lifecycle launcher instead. User data dirs take
# precedence over /usr/share in XDG resolution.
Name=Hyprland
Comment=An intelligent dynamic tiling Wayland compositor
Exec=/home/pang/.local/bin/hyprland-session
Type=Application
Keywords=tiling;wayland;compositor;
EOF
# Round-2 watcher set: exact content was never committed - the installer must
# DETECT and WARN, never guess-and-delete (Codex R4.1)
cat > "$fakehome/.config/systemd/user/hyprland-session.service" <<'EOF'
[Unit]
Description=Hyprland session watcher (Round 2)
[Service]
Type=oneshot
Environment=HYPR_WATCH_TIMEOUT=43200
ExecStart=/home/pang/.local/bin/hyprland-session-watch
EOF
printf '#!/bin/sh\n# Round-2 watcher loop\nexec pgrep -x Hyprland\n' > "$fakehome/.local/bin/hyprland-session-watch"
printf '#!/bin/sh\n# Round-2 start helper\nexec /home/pang/.local/bin/hyprland-session-watch\n' > "$fakehome/.local/bin/hyprland-session-start"
cat > "$fakehome/.config/systemd/user/niri.service.d/session-cleanup.conf" <<'EOF'
[Service]
ExecStop=/home/pang/.local/bin/hyprland-session-watch stop
EOF
# a custom user unit that must never be touched
printf '[Unit]\nDescription=vellum\n[Service]\nExecStart=/bin/true\n' > "$fakehome/.config/systemd/user/vellum.service"

# drift guard: every embedded Round-3 literal must hash to the recorded value
for pair in \
  ".config/systemd/user/hyprland.service:$H_HYPR_SERVICE" \
  ".config/systemd/user/hyprland-shutdown.target:$H_HYPR_SHUTDOWN" \
  ".local/bin/hyprland-session:$H_HYPR_LAUNCHER" \
  ".local/share/wayland-sessions/hyprland.desktop:$H_HYPR_DESKTOP" \
  ".config/systemd/user/hyprland-session.target:$H_HYPR_TARGET" \
; do
  rel="${pair%%:*}"; want="${pair##*:}"
  got="$(sha256sum "$fakehome/$rel" | cut -d' ' -f1)"
  assert_eq "stale literal matches recorded hash: $rel" "$got" "$want"
done

paru_before="$(sha256sum /etc/paru.conf 2>/dev/null | cut -c1-16 || echo none)"
# a wants symlink so the none-mode convergence postcondition is meaningful
mkdir -p "$fakehome/.config/systemd/user/graphical-session.target.wants"
ln -s /usr/lib/systemd/user/dms.service "$fakehome/.config/systemd/user/graphical-session.target.wants/dms.service"
order="$sandbox/f4-order.log"
rc=0
PATH="$sandbox/mockbin:$PATH" FAKE_SYS_LOG="$order" FAKE_DMS_ENABLE_RC=1 \
  FAKE_STATE_DIR="$sandbox/state-f4" \
  HOME="$fakehome" PROJECT_DIR="$root" DESKTOP_ENV=none MACHINE_TYPE=vm \
  bash "$services" >>"$order" 2>&1 || rc=$?
check "none: 08-services rc 0 even though dms enable would fail" "$rc" 0
if grep -q 'enable dms.service' "$order"; then
  check "none: dms.service NOT enabled" 1 0
else
  check "none: dms.service NOT enabled" 0 0
fi
if grep -q 'enable dsearch' "$order"; then
  check "none: dsearch.service NOT enabled" 1 0
else
  check "none: dsearch.service NOT enabled" 0 0
fi
# convergence: none mode DISABLES the project-managed desktop chain; dms and
# greetd are fatal-on-failure, dsearch is optional (R4.2 item 4)
assert_grep "none: dms.service disabled (convergence)" 'disable dms.service' "$order"
assert_grep "none: dsearch.service disabled (optional)" 'disable dsearch.service' "$order"
assert_grep "none: greetd disabled (convergence)" 'disable greetd' "$order"
if [[ -e "$fakehome/.config/systemd/user/graphical-session.target.wants/dms.service" ]]; then
  check "none: dms wants symlink removed (postcondition)" 0 1
else
  check "none: dms wants symlink removed (postcondition)" 1 1
fi
assert_grep "none: greetd is-enabled checked (postcondition)" 'is-enabled greetd' "$order"
# 5 exact artifacts removed
for rel in \
  ".config/systemd/user/hyprland.service" \
  ".config/systemd/user/hyprland-shutdown.target" \
  ".config/systemd/user/hyprland-session.target" \
  ".local/bin/hyprland-session" \
  ".local/share/wayland-sessions/hyprland.desktop" \
; do
  if [[ -e "$fakehome/$rel" ]]; then check "stale removed (exact): $rel" 0 1; else check "stale removed (exact): $rel" 1 1; fi
done
# Round-2 watcher set + niri drop-in: detected + warned, NEVER deleted
for rel in \
  ".config/systemd/user/hyprland-session.service" \
  ".local/bin/hyprland-session-watch" \
  ".local/bin/hyprland-session-start" \
  ".config/systemd/user/niri.service.d/session-cleanup.conf" \
  ".config/systemd/user/vellum.service" \
; do
  if [[ -e "$fakehome/$rel" ]]; then check "Round-2/user file kept: $rel" 1 1; else check "Round-2/user file kept: $rel" 0 1; fi
done
assert_grep "warn: niri drop-in path reported" 'niri.service.d/session-cleanup.conf' "$order"
assert_grep "warn: hyprland-session.service path reported" 'hyprland-session.service' "$order"
# LoadState-based confirm (R4.2 item 3): not-found confirms; the kept unit
# (hyprland-session.service) must be reported as still-loads, not confirmed
assert_grep "confirmed via LoadState=not-found (hyprland.service)" 'confirmed: stale unit hyprland.service' "$order"
assert_grep "confirmed includes hyprland-session.target" 'confirmed: stale unit hyprland-session.target' "$order"
assert_grep "kept hyprland-session.service reported still-loads" 'still loads' "$order"
# backup created and holds a removed exact artifact
backup="$(find "$fakehome/.config/systemd/user" -maxdepth 1 -type d -name '.my-arch-stale-backup-*' | head -1)"
if [[ -n "$backup" ]] && [[ -f "$backup/.config/systemd/user/hyprland.service" ]]; then
  check "backup dir created with removed artifact" 0 0
else
  check "backup dir created with removed artifact" 1 0
fi
# ordering within the single log stream: cleanup -> confirmed (incl.
# hyprland-session.target) -> disable
a="$(lineno 'stale cleanup:' "$order")"
b="$(lineno 'confirmed: stale unit hyprland.service' "$order")"
c="$(lineno 'confirmed: stale unit hyprland-session.target' "$order")"
d="$(lineno 'disable dms.service' "$order")"
if [[ -n "$a" && -n "$b" && -n "$c" && -n "$d" && "$a" -lt "$b" && "$b" -lt "$c" && "$c" -lt "$d" ]]; then
  check "order: cleanup < confirmed(service,target) < disable" 0 0
else
  check "order: cleanup < confirmed(service,target) < disable" 1 0
fi
paru_after="$(sha256sum /etc/paru.conf 2>/dev/null | cut -c1-16 || echo none)"
assert_eq "/etc untouched (paru.conf unchanged)" "$paru_after" "$paru_before"

# F4q1: LoadState rc=125 but stdout=not-found -> must NOT be confirmed
orderq="$sandbox/f4q.log"
rc=0
PATH="$sandbox/mockbin:$PATH" FAKE_SYS_LOG="$orderq" FAKE_QUERY_RC=125 \
  FAKE_STATE_DIR="$sandbox/state-f4q" \
  HOME="$fakehome" PROJECT_DIR="$root" DESKTOP_ENV=none MACHINE_TYPE=vm \
  bash "$services" >>"$orderq" 2>&1 || rc=$?
check "query rc=125 + not-found: 08-services rc 0 (warn, non-fatal)" "$rc" 0
if grep -q 'confirmed: stale unit' "$orderq"; then
  check "query rc=125 + not-found: NOT recorded as confirmed" 1 0
else
  check "query rc=125 + not-found: NOT recorded as confirmed" 0 0
fi
assert_grep "query rc=125 + not-found: query-failed warning present" 'query failed' "$orderq"

# F4q2: LoadState rc=125 + empty stdout -> query failed, NOT confirmed
orderq2="$sandbox/f4q2.log"
rc=0
PATH="$sandbox/mockbin:$PATH" FAKE_SYS_LOG="$orderq2" FAKE_QUERY_RC=125 FAKE_QUERY_EMPTY=1 \
  FAKE_STATE_DIR="$sandbox/state-f4q2" \
  HOME="$fakehome" PROJECT_DIR="$root" DESKTOP_ENV=none MACHINE_TYPE=vm \
  bash "$services" >>"$orderq2" 2>&1 || rc=$?
check "query rc=125 + empty: 08-services rc 0 (warn, non-fatal)" "$rc" 0
if grep -q 'confirmed: stale unit' "$orderq2"; then
  check "query rc=125 + empty: NOT recorded as confirmed" 1 0
else
  check "query rc=125 + empty: NOT recorded as confirmed" 0 0
fi
assert_grep "query rc=125 + empty: query-failed warning present" 'query failed' "$orderq2"

# F4b: none + dms disable FAILS -> nonzero, dms stays enabled
fakehome_b="$sandbox/home-none-fail"
mkdir -p "$fakehome_b/.config/systemd/user/graphical-session.target.wants"
ln -s /usr/lib/systemd/user/dms.service "$fakehome_b/.config/systemd/user/graphical-session.target.wants/dms.service"
logb="$sandbox/f4b.log"
rc=0
PATH="$sandbox/mockbin:$PATH" FAKE_SYS_LOG="$logb" FAKE_DMS_ENABLE_RC=1 \
  FAKE_DMS_DISABLE_RC=1 FAKE_STATE_DIR="$sandbox/state-f4b" \
  HOME="$fakehome_b" PROJECT_DIR="$root" DESKTOP_ENV=none MACHINE_TYPE=vm \
  bash "$services" >>"$logb" 2>&1 || rc=$?
check "none: dms disable failure exits nonzero" "$rc" 1
assert_grep "none: dms disable failure error names dms" 'could not disable dms.service' "$logb"
if [[ -L "$fakehome_b/.config/systemd/user/graphical-session.target.wants/dms.service" ]]; then
  check "none: dms wants symlink intact after failed disable" 1 1
else
  check "none: dms wants symlink intact after failed disable" 0 1
fi

# F4c: none + greetd disable FAILS -> nonzero
logc="$sandbox/f4c.log"
rc=0
PATH="$sandbox/mockbin:$PATH" FAKE_SYS_LOG="$logc" FAKE_DMS_ENABLE_RC=1 \
  FAKE_GREETD_DISABLE_RC=1 FAKE_STATE_DIR="$sandbox/state-f4c" \
  HOME="$fakehome_b" PROJECT_DIR="$root" DESKTOP_ENV=none MACHINE_TYPE=vm \
  bash "$services" >>"$logc" 2>&1 || rc=$?
check "none: greetd disable failure exits nonzero" "$rc" 1
assert_grep "none: greetd disable failure error names greetd" 'could not disable greetd' "$logc"

# F4d: greetd is-enabled query rc=125 -> step nonzero, no "Service disabled"
logd="$sandbox/f4d.log"
rc=0
PATH="$sandbox/mockbin:$PATH" FAKE_SYS_LOG="$logd" FAKE_DMS_ENABLE_RC=1 \
  FAKE_GREETD_ISENABLED_RC=125 FAKE_STATE_DIR="$sandbox/state-f4d" \
  HOME="$fakehome_b" PROJECT_DIR="$root" DESKTOP_ENV=none MACHINE_TYPE=vm \
  bash "$services" >>"$logd" 2>&1 || rc=$?
check "none: greetd is-enabled rc=125 fails nonzero" "$rc" 1
if grep -q 'Service disabled: greetd' "$logd"; then
  check "none: is-enabled rc=125 does NOT print Service disabled" 1 0
else
  check "none: is-enabled rc=125 does NOT print Service disabled" 0 0
fi
assert_grep "none: is-enabled rc=125 error mentions query" 'is-enabled.*failed\|convergence NOT verified' "$logd"

# F4e: dangling dms wants symlink left after disable -> nonzero, no
# "User service disabled" (R4.3 item 3: [[ -e || -L ]] counts dangling)
fakehome_e="$sandbox/home-none-dangling"
mkdir -p "$fakehome_e/.config/systemd/user/graphical-session.target.wants"
ln -s /nonexistent "$fakehome_e/.config/systemd/user/graphical-session.target.wants/dms.service"
loge="$sandbox/f4e.log"
rc=0
PATH="$sandbox/mockbin:$PATH" FAKE_SYS_LOG="$loge" FAKE_DMS_ENABLE_RC=1 \
  FAKE_DMS_DISABLE_KEEP=1 FAKE_STATE_DIR="$sandbox/state-f4e" \
  HOME="$fakehome_e" PROJECT_DIR="$root" DESKTOP_ENV=none MACHINE_TYPE=vm \
  bash "$services" >>"$loge" 2>&1 || rc=$?
check "none: dangling dms wants symlink fails nonzero" "$rc" 1
if grep -q 'User service disabled: dms' "$loge"; then
  check "none: dangling wants symlink does NOT print User service disabled" 1 0
else
  check "none: dangling wants symlink does NOT print User service disabled" 0 0
fi

# F4g: greetd is-enabled rc=4 + stdout=not-found -> treated as converged
# (the host's real systemctl contract; R4.4 item 4)
logg="$sandbox/f4g.log"
rc=0
PATH="$sandbox/mockbin:$PATH" FAKE_SYS_LOG="$logg" FAKE_DMS_ENABLE_RC=1 \
  FAKE_GREETD_ISENABLED_RC=4 FAKE_GREETD_ISENABLED_OUT="not-found" \
  FAKE_STATE_DIR="$sandbox/state-f4g" \
  HOME="$fakehome_b" PROJECT_DIR="$root" DESKTOP_ENV=none MACHINE_TYPE=vm \
  bash "$services" >>"$logg" 2>&1 || rc=$?
check "none: greetd is-enabled rc=4+not-found passes (converged)" "$rc" 0
assert_grep "none: rc=4+not-found logged as converged" 'treated as converged' "$logg"

# F4h: is-enabled rc=4 + EMPTY stdout -> NOT converged (nonzero)
logh="$sandbox/f4h.log"
rc=0
PATH="$sandbox/mockbin:$PATH" FAKE_SYS_LOG="$logh" FAKE_DMS_ENABLE_RC=1 \
  FAKE_GREETD_ISENABLED_RC=4 FAKE_STATE_DIR="$sandbox/state-f4h" \
  HOME="$fakehome_b" PROJECT_DIR="$root" DESKTOP_ENV=none MACHINE_TYPE=vm \
  bash "$services" >>"$logh" 2>&1 || rc=$?
check "none: greetd is-enabled rc=4+empty fails nonzero" "$rc" 1
if grep -q 'Service disabled: greetd' "$logh"; then
  check "none: rc=4+empty does NOT print Service disabled" 1 0
else
  check "none: rc=4+empty does NOT print Service disabled" 0 0
fi

echo "== G. DMS required in niri/both; stock Hyprland entry preflight =="
# shared fake home for the both-mode runs: wants symlink + exact stale unit
fakehome_g="$sandbox/home-g"
mkdir -p "$fakehome_g/.config/systemd/user/graphical-session.target.wants"
ln -s /usr/lib/systemd/user/dms.service "$fakehome_g/.config/systemd/user/graphical-session.target.wants/dms.service"
# G1: both + dms enable fails -> step fails nonzero BEFORE any /etc write
log1="$sandbox/g1.log"
rc=0
PATH="$sandbox/mockbin:$PATH" FAKE_SYS_LOG="$log1" FAKE_DMS_ENABLE_RC=1 \
  GREETER_CACHE_DIR="$sandbox/greeter-cache-g" \
  HOME="$fakehome_g" PROJECT_DIR="$root" DESKTOP_ENV=both MACHINE_TYPE=vm \
  bash "$services" >>"$log1" 2>&1 || rc=$?
check "both: dms enable failure exits nonzero" "$rc" 1
paru_after_g1="$(sha256sum /etc/paru.conf 2>/dev/null | cut -c1-16 || echo none)"
assert_eq "/etc untouched in both-dms-fail (paru.conf unchanged)" "$paru_after_g1" "$paru_before"

# G2: both + system Hyprland entry missing (WAYLAND_SESSIONS_DIR empty) ->
# fail BEFORE any enable (aligned stock contract, R5).
log2="$sandbox/g2.log"
rc=0
PATH="$sandbox/mockbin:$PATH" FAKE_SYS_LOG="$log2" FAKE_DMS_ENABLE_RC=0 \
  WAYLAND_SESSIONS_DIR="$sandbox/empty-sessions" GREETER_CACHE_DIR="$sandbox/greeter-cache-g" \
  HOME="$fakehome_g" PROJECT_DIR="$root" DESKTOP_ENV=both MACHINE_TYPE=vm \
  bash "$services" >>"$log2" 2>&1 || rc=$?
check "both: missing system Hyprland entry exits nonzero" "$rc" 1
if grep -q 'system Hyprland session entry missing' "$log2"; then
  check "both: error names the missing entry" 0 0
else
  check "both: error names the missing entry" 1 0
  tail -3 "$log2" | sed 's/^/      /'
fi
if grep -q 'enable dms.service' "$log2"; then
  check "both: entry preflight fails BEFORE dms enable" 1 0
else
  check "both: entry preflight fails BEFORE dms enable" 0 0
fi

# G3: both full pass: stale exact unit present -> cleanup -> confirmed ->
#     verified -> enable dms -> greetd. Ordering is the R4.1 contract.
cat > "$fakehome_g/.config/systemd/user/hyprland.service" <<'EOF'
[Unit]
# Hyprland compositor, systemd-managed (Codex Round 3, mirrors niri.service).
#
# Hyprland 0.56.2 natively supports sd_notify (READY=1 on compositor-ready,
# STOPPING=1 on exit) and manages its OWN systemd + D-Bus activation
# environment on both sides (import on ready, unset on exit) - so this unit
# needs NO extra import/unset helpers and no polling watcher. The
# graphical-session chain is bound exactly like niri.service:
#   BindsTo graphical-session.target   (target stop -> compositor stops)
#   Wants   graphical-session-pre.target + xdg-desktop-autostart.target
#   dms.service is pulled via WantedBy=graphical-session.target, and stops
#   when the target stops (PartOf=graphical-session.target on dms.service).
#
# Started with `systemctl --user --wait start` by the hyprland-session
# launcher (greetd desktop entry); on exit the launcher starts
# hyprland-shutdown.target (Conflicts=graphical-session*) which tears the
# session chain down and propagates the real exit status.
Description=Hyprland compositor
BindsTo=graphical-session.target
Before=graphical-session.target
Wants=graphical-session-pre.target
After=graphical-session-pre.target

Wants=xdg-desktop-autostart.target
Before=xdg-desktop-autostart.target

[Service]
Slice=session.slice
Type=notify
ExecStart=/usr/bin/Hyprland
EOF
log3="$sandbox/g3.log"
rc=0
PATH="$sandbox/mockbin:$PATH" FAKE_SYS_LOG="$log3" FAKE_DMS_ENABLE_RC=0 \
  GREETER_CACHE_DIR="$sandbox/greeter-cache-g" \
  HOME="$fakehome_g" PROJECT_DIR="$root" DESKTOP_ENV=both MACHINE_TYPE=vm \
  bash "$services" >>"$log3" 2>&1 || rc=$?
check "both: full pass with stock Hyprland entry (rc 0)" "$rc" 0
assert_grep "both: stock session verified log line present" 'stock Hyprland session verified' "$log3"
assert_grep "both: dms wants symlink verified" 'Verified:.*graphical-session.target.wants/dms.service' "$log3"
a="$(lineno 'stale cleanup:' "$log3")"
b="$(lineno 'confirmed: stale unit hyprland.service' "$log3")"
c="$(lineno 'stock Hyprland session verified' "$log3")"
d="$(lineno 'enable dms.service' "$log3")"
e="$(lineno 'Configuring greetd' "$log3")"
if [[ -n "$a" && -n "$b" && -n "$c" && -n "$d" && -n "$e" \
   && "$a" -lt "$b" && "$b" -lt "$c" && "$c" -lt "$d" && "$d" -lt "$e" ]]; then
  check "order: cleanup < confirmed < verified < enable dms < greetd" 0 0
else
  check "order: cleanup < confirmed < verified < enable dms < greetd" 1 0
fi

# G4: both + user-modified hyprland.desktop override survives cleanup ->
#     effective secondary entry is NOT the system one -> FAIL CLOSED
fakehome_g4="$sandbox/home-g4"
mkdir -p "$fakehome_g4/.local/share/wayland-sessions"
cat > "$fakehome_g4/.local/share/wayland-sessions/hyprland.desktop" <<'EOF'
[Desktop Entry]
Name=Hyprland
Exec=/home/pang/.local/bin/hyprland-session
Type=Application
# user-modified copy (would shadow the system Hyprland entry in resolution)
EOF
log4="$sandbox/g4.log"
rc=0
PATH="$sandbox/mockbin:$PATH" FAKE_SYS_LOG="$log4" FAKE_DMS_ENABLE_RC=0 \
  GREETER_CACHE_DIR="$sandbox/greeter-cache-g" \
  HOME="$fakehome_g4" PROJECT_DIR="$root" DESKTOP_ENV=both MACHINE_TYPE=vm \
  bash "$services" >>"$log4" 2>&1 || rc=$?
check "both: user hyprland.desktop override fails closed (rc 1)" "$rc" 1
if grep -q 'stock Hyprland session verified' "$log4"; then
  check "both: override present -> NOT reported verified" 1 0
else
  check "both: override present -> NOT reported verified" 0 0
fi
if grep -q 'hyprland.desktop' "$log4" && grep -q 'override\|non-system\|resolves\|unusable' "$log4"; then
  check "both: error points at the shadowing entry path" 0 0
else
  check "both: error points at the shadowing entry path" 1 0
  tail -4 "$log4" | sed 's/^/      /'
fi

# G5: resolve_hyprland_desktop called DIRECTLY (production helper, R4.3
# item 2): explicit TARGET_XDG_DATA_HOME / TARGET_XDG_DATA_DIRS order; the
# first candidate that exists (lstat) is CLASSIFIED - dangling/FIFO/dir/
# unreadable/wrong-section/empty-Exec/missing-Exec-program all fail closed
# (rc=2), never skip to a lower-priority candidate.
res() { # res <target_xdg_data_home> <target_xdg_data_dirs> ; echoes "rc=<n>|<out>"
  local dh="$1" dd="$2"
  TARGET_XDG_DATA_HOME="$dh" TARGET_XDG_DATA_DIRS="$dd" bash -c '
    source "$0" >/dev/null 2>&1
    rc=0
    out="$(resolve_hyprland_desktop)" || rc=$?
    printf "rc=%s|%s\n" "$rc" "$out"
  ' "$utils"
}
rr="$sandbox/resolve-root"
mkdir -p "$rr/home/wayland-sessions" "$rr/share1/wayland-sessions" "$rr/share2/wayland-sessions"
printf '[Desktop Entry]\nName=Hyprland\nExec=/bin/true\n' > "$rr/share1/wayland-sessions/hyprland.desktop"
printf '[Desktop Entry]\nName=Hyprland\nExec=/bin/true\n' > "$rr/share2/wayland-sessions/hyprland.desktop"
# r1: explicit TARGET_XDG_DATA_HOME wins over all DATA_DIRS
printf '[Desktop Entry]\nName=Hyprland\nExec=/bin/true\n' > "$rr/home/wayland-sessions/hyprland.desktop"
r1="$(res "$rr/home" "$rr/share1:$rr/share2")"
assert_eq "r1: TARGET_XDG_DATA_HOME wins over DATA_DIRS" "$r1" "rc=0|$rr/home/wayland-sessions/hyprland.desktop"
rm -f "$rr/home/wayland-sessions/hyprland.desktop"
# r2: TARGET_XDG_DATA_DIRS entries keep original order
r2="$(res "$rr/home" "$rr/share1:$rr/share2")"
assert_eq "r2: first DATA_DIR wins (original order)" "$r2" "rc=0|$rr/share1/wayland-sessions/hyprland.desktop"
rm -f "$rr/share1/wayland-sessions/hyprland.desktop"
r2b="$(res "$rr/home" "$rr/share1:$rr/share2")"
assert_eq "r2b: second DATA_DIR fallback (original order)" "$r2b" "rc=0|$rr/share2/wayland-sessions/hyprland.desktop"
# r3: Name/Exec in the WRONG section -> rc=2 (not valid)
printf '[Other Section]\nName=Hyprland\nExec=/bin/true\n' > "$rr/home/wayland-sessions/hyprland.desktop"
r3="$(res "$rr/home" "$rr/share1:$rr/share2")"
assert_eq "r3: Name/Exec in wrong section -> rc=2" "${r3%%|*}" "rc=2"
# r4: empty Exec -> rc=2
printf '[Desktop Entry]\nName=Hyprland\nExec=\n' > "$rr/home/wayland-sessions/hyprland.desktop"
r4="$(res "$rr/home" "$rr/share1:$rr/share2")"
assert_eq "r4: empty Exec -> rc=2" "${r4%%|*}" "rc=2"
# r5: Exec first program does not exist -> rc=2
printf '[Desktop Entry]\nName=Hyprland\nExec=/nonexistent/program\n' > "$rr/home/wayland-sessions/hyprland.desktop"
r5="$(res "$rr/home" "$rr/share1:$rr/share2")"
assert_eq "r5: missing Exec program -> rc=2" "${r5%%|*}" "rc=2"
# r6: dangling symlink -> rc=2
rm -f "$rr/home/wayland-sessions/hyprland.desktop"
ln -s /nonexistent "$rr/home/wayland-sessions/hyprland.desktop"
r6="$(res "$rr/home" "$rr/share1:$rr/share2")"
assert_eq "r6: dangling symlink -> rc=2" "${r6%%|*}" "rc=2"
# r7: FIFO -> rc=2 fast (no hang)
rm -f "$rr/home/wayland-sessions/hyprland.desktop"
mkfifo "$rr/home/wayland-sessions/hyprland.desktop"
r7="$(res "$rr/home" "$rr/share1:$rr/share2")"
assert_eq "r7: FIFO -> rc=2 (no hang)" "${r7%%|*}" "rc=2"
# r8: directory -> rc=2
rm -f "$rr/home/wayland-sessions/hyprland.desktop"
mkdir -p "$rr/home/wayland-sessions/hyprland.desktop"
r8="$(res "$rr/home" "$rr/share1:$rr/share2")"
assert_eq "r8: directory -> rc=2" "${r8%%|*}" "rc=2"
# r9: unreadable -> rc=2 (not no-match)
rmdir "$rr/home/wayland-sessions/hyprland.desktop"
printf '[Desktop Entry]\nName=Hyprland\nExec=/bin/true\n' > "$rr/home/wayland-sessions/hyprland.desktop"
chmod 000 "$rr/home/wayland-sessions/hyprland.desktop"
r9="$(res "$rr/home" "$rr/share1:$rr/share2")"
assert_eq "r9: unreadable -> rc=2" "${r9%%|*}" "rc=2"
chmod 644 "$rr/home/wayland-sessions/hyprland.desktop"
# r10: no candidate -> rc=1
rm -f "$rr/home/wayland-sessions/hyprland.desktop" "$rr/share2/wayland-sessions/hyprland.desktop"
r10="$(res "$rr/home" "$rr/share1:$rr/share2")"
assert_eq "r10: no candidate -> rc=1" "$r10" "rc=1|"

# G6: desktop preflight requires greetd.service / dms-greeter / greeter
# config sources BEFORE cleanup/enable/write /etc (R4.2 item 5)
fakehome_g6="$sandbox/home-g6"
mkdir -p "$fakehome_g6/.config/systemd/user/graphical-session.target.wants"
ln -s /usr/lib/systemd/user/dms.service "$fakehome_g6/.config/systemd/user/graphical-session.target.wants/dms.service"
cp "$backup/.config/systemd/user/hyprland.service" "$fakehome_g6/.config/systemd/user/hyprland.service"
# G6a: dms-greeter binary missing
log6a="$sandbox/g6a.log"
rc=0
PATH="$sandbox/mockbin:$PATH" FAKE_SYS_LOG="$log6a" FAKE_DMS_ENABLE_RC=0 \
  GREETER_CACHE_DIR="$sandbox/greeter-cache-g" \
  DMS_GREETER_BIN="$sandbox/nonexistent-greeter" \
  HOME="$fakehome_g6" PROJECT_DIR="$root" DESKTOP_ENV=both MACHINE_TYPE=vm \
  bash "$services" >>"$log6a" 2>&1 || rc=$?
check "G6a: missing dms-greeter aborts (rc 1)" "$rc" 1
assert_grep "G6a: error names dms-greeter" 'dms-greeter' "$log6a"
rc=0; [[ -e "$fakehome_g6/.config/systemd/user/hyprland.service" ]] || rc=1
check "G6a: stale NOT cleaned before abort" "$rc" 0
if grep -q 'enable dms.service' "$log6a"; then
  check "G6a: no dms enable before abort" 1 0
else
  check "G6a: no dms enable before abort" 0 0
fi
if grep -q 'daemon-reload' "$log6a"; then
  check "G6a: no user daemon-reload before abort" 1 0
else
  check "G6a: no user daemon-reload before abort" 0 0
fi
# G6b: greetd.service unit missing
log6b="$sandbox/g6b.log"
rc=0
PATH="$sandbox/mockbin:$PATH" FAKE_SYS_LOG="$log6b" FAKE_DMS_ENABLE_RC=0 \
  GREETER_CACHE_DIR="$sandbox/greeter-cache-g" \
  GREETD_SERVICE_UNIT="$sandbox/nonexistent-greetd.service" \
  HOME="$fakehome_g6" PROJECT_DIR="$root" DESKTOP_ENV=both MACHINE_TYPE=vm \
  bash "$services" >>"$log6b" 2>&1 || rc=$?
check "G6b: missing greetd.service aborts (rc 1)" "$rc" 1
assert_grep "G6b: error names greetd" 'greetd' "$log6b"
rc=0; [[ -e "$fakehome_g6/.config/systemd/user/hyprland.service" ]] || rc=1
check "G6b: stale NOT cleaned before abort" "$rc" 0
if grep -q 'daemon-reload' "$log6b"; then
  check "G6b: no user daemon-reload before abort" 1 0
else
  check "G6b: no user daemon-reload before abort" 0 0
fi
# G6c: greeter config sources missing
log6c="$sandbox/g6c.log"
rc=0
PATH="$sandbox/mockbin:$PATH" FAKE_SYS_LOG="$log6c" FAKE_DMS_ENABLE_RC=0 \
  GREETER_CACHE_DIR="$sandbox/greeter-cache-g" \
  GREETER_CONFIG_DIR="$sandbox/nonexistent-greeter-config" \
  HOME="$fakehome_g6" PROJECT_DIR="$root" DESKTOP_ENV=both MACHINE_TYPE=vm \
  bash "$services" >>"$log6c" 2>&1 || rc=$?
check "G6c: missing greeter config sources aborts (rc 1)" "$rc" 1
assert_grep "G6c: error names greeter config" 'greetd/niri\|greeter config\|config.kdl' "$log6c"
rc=0; [[ -e "$fakehome_g6/.config/systemd/user/hyprland.service" ]] || rc=1
check "G6c: stale NOT cleaned before abort" "$rc" 0
if grep -q 'daemon-reload' "$log6c"; then
  check "G6c: no user daemon-reload before abort" 1 0
else
  check "G6c: no user daemon-reload before abort" 0 0
fi
# G6d: niri missing (greeter compositor) -> abort before cleanup/enable/
# memory/write /etc (R4.3 item 5)
log6d="$sandbox/g6d.log"
rc=0
PATH="$sandbox/mockbin:$PATH" FAKE_SYS_LOG="$log6d" FAKE_DMS_ENABLE_RC=0 \
  GREETER_CACHE_DIR="$sandbox/greeter-cache-g" \
  NIRI_BIN="$sandbox/nonexistent-niri" \
  HOME="$fakehome_g6" PROJECT_DIR="$root" DESKTOP_ENV=both MACHINE_TYPE=vm \
  bash "$services" >>"$log6d" 2>&1 || rc=$?
check "G6d: missing niri aborts (rc 1)" "$rc" 1
assert_grep "G6d: error names niri" 'niri' "$log6d"
rc=0; [[ -e "$fakehome_g6/.config/systemd/user/hyprland.service" ]] || rc=1
check "G6d: stale NOT cleaned before abort" "$rc" 0
if grep -q 'enable dms.service' "$log6d"; then
  check "G6d: no dms enable before abort" 1 0
else
  check "G6d: no dms enable before abort" 0 0
fi
if grep -q 'memory migrated\|memory.json' "$log6d"; then
  check "G6d: no memory modification before abort" 1 0
else
  check "G6d: no memory modification before abort" 0 0
fi
if grep -q 'Configuring greetd\|/etc/greetd' "$log6d"; then
  check "G6d: no greetd write before abort" 1 0
else
  check "G6d: no greetd write before abort" 0 0
fi
if grep -q 'daemon-reload' "$log6d"; then
  check "G6d: no user daemon-reload before abort" 1 0
else
  check "G6d: no user daemon-reload before abort" 0 0
fi

# G8: greeter user creation failures are fatal (R4.3 item 5)
fakehome_g8="$sandbox/home-g8"
mkdir -p "$fakehome_g8/.config/systemd/user/graphical-session.target.wants"
ln -s /usr/lib/systemd/user/dms.service "$fakehome_g8/.config/systemd/user/graphical-session.target.wants/dms.service"
# G8a: useradd fails
log8a="$sandbox/g8a.log"
rc=0
PATH="$sandbox/mockbin:$PATH" FAKE_SYS_LOG="$log8a" FAKE_DMS_ENABLE_RC=0 FAKE_USERADD_RC=1 \
  GREETER_CACHE_DIR="$sandbox/greeter-cache-g" \
  GREETER_USER_NAME="no-such-greeter-r43" \
  HOME="$fakehome_g8" PROJECT_DIR="$root" DESKTOP_ENV=both MACHINE_TYPE=vm \
  bash "$services" >>"$log8a" 2>&1 || rc=$?
check "G8a: useradd failure aborts (rc 1)" "$rc" 1
assert_grep "G8a: error names greeter user creation" 'could not create greeter user' "$log8a"
# G8b: useradd reports success but getent still misses -> fatal
log8b="$sandbox/g8b.log"
rc=0
PATH="$sandbox/mockbin:$PATH" FAKE_SYS_LOG="$log8b" FAKE_DMS_ENABLE_RC=0 FAKE_USERADD_RC=0 \
  GREETER_CACHE_DIR="$sandbox/greeter-cache-g" \
  GREETER_USER_NAME="no-such-greeter-r43" \
  HOME="$fakehome_g8" PROJECT_DIR="$root" DESKTOP_ENV=both MACHINE_TYPE=vm \
  bash "$services" >>"$log8b" 2>&1 || rc=$?
check "G8b: getent-still-missing after useradd aborts (rc 1)" "$rc" 1
assert_grep "G8b: error names missing greeter user" 'greeter.*still missing\|still missing.*greeter' "$log8b"

# PA: python validator preflight MUST run before any cleanup/backup/reload/
# enable//etc-write (R4.4 item 1). Each scenario re-creates the exact stale
# artifact so the pre-cleanup-abort contract is observable.
# PA1: PYTHON_BIN points at a nonexistent binary (python missing)
logp1="$sandbox/pa1.log"
cp "$backup/.config/systemd/user/hyprland.service" "$fakehome_g6/.config/systemd/user/hyprland.service" 2>/dev/null || true
rc=0
PATH="$sandbox/mockbin:$PATH" FAKE_SYS_LOG="$logp1" FAKE_DMS_ENABLE_RC=0 \
  GREETER_CACHE_DIR="$sandbox/greeter-cache-g" \
  PYTHON_BIN="$sandbox/mockbin-nopython/python3" \
  HOME="$fakehome_g6" PROJECT_DIR="$root" DESKTOP_ENV=both MACHINE_TYPE=vm \
  bash "$services" >>"$logp1" 2>&1 || rc=$?
check "PA1: missing python aborts (rc 1)" "$rc" 1
assert_grep "PA1: error says python/validator unavailable" 'unavailable' "$logp1"
if grep -qi 'corrupt\|unusable' "$logp1"; then
  check "PA1: NOT reported as desktop-entry corrupt" 1 0
else
  check "PA1: NOT reported as desktop-entry corrupt" 0 0
fi
rc=0; [[ -e "$fakehome_g6/.config/systemd/user/hyprland.service" ]] || rc=1
check "PA1: stale artifact intact (cleanup did NOT run)" "$rc" 0
if find "$fakehome_g6" -name '.my-arch-stale-backup-*' 2>/dev/null | grep -q .; then
  check "PA1: backup_count=0" 1 0
else
  check "PA1: backup_count=0" 0 0
fi
if grep -q 'removed project artifact' "$logp1"; then
  check "PA1: no 'removed project artifact' in log" 1 0
else
  check "PA1: no 'removed project artifact' in log" 0 0
fi
if grep -q 'enable dms.service' "$logp1"; then
  check "PA1: no dms enable before abort" 1 0
else
  check "PA1: no dms enable before abort" 0 0
fi
if grep -q 'daemon-reload' "$logp1"; then
  check "PA1: no user daemon-reload before abort" 1 0
else
  check "PA1: no user daemon-reload before abort" 0 0
fi
# PA2: PYTHON_BIN is a shim that exits 42 -> infra failure, not corrupt
logp2="$sandbox/pa2.log"
cp "$backup/.config/systemd/user/hyprland.service" "$fakehome_g6/.config/systemd/user/hyprland.service" 2>/dev/null || true
rc=0
PATH="$sandbox/mockbin:$PATH" FAKE_SYS_LOG="$logp2" FAKE_DMS_ENABLE_RC=0 \
  GREETER_CACHE_DIR="$sandbox/greeter-cache-g" \
  PYTHON_BIN="$sandbox/mockbin/py42" \
  HOME="$fakehome_g6" PROJECT_DIR="$root" DESKTOP_ENV=both MACHINE_TYPE=vm \
  bash "$services" >>"$logp2" 2>&1 || rc=$?
check "PA2: python rc=42 shim aborts (rc 1)" "$rc" 1
assert_grep "PA2: error says python/validator unavailable" 'unavailable' "$logp2"
if grep -qi 'corrupt\|unusable' "$logp2"; then
  check "PA2: NOT reported as desktop-entry corrupt" 1 0
else
  check "PA2: NOT reported as desktop-entry corrupt" 0 0
fi
rc=0; [[ -e "$fakehome_g6/.config/systemd/user/hyprland.service" ]] || rc=1
check "PA2: stale artifact intact (cleanup did NOT run)" "$rc" 0
if grep -q 'daemon-reload' "$logp2"; then
  check "PA2: no user daemon-reload before abort" 1 0
else
  check "PA2: no user daemon-reload before abort" 0 0
fi
# PA3: controlled PATH with NO python3 at all
logp3="$sandbox/pa3.log"
cp "$backup/.config/systemd/user/hyprland.service" "$fakehome_g6/.config/systemd/user/hyprland.service" 2>/dev/null || true
rc=0
PATH="$sandbox/mockbin:$sandbox/toolbin" FAKE_SYS_LOG="$logp3" FAKE_DMS_ENABLE_RC=0 \
  GREETER_CACHE_DIR="$sandbox/greeter-cache-g" \
  HOME="$fakehome_g6" PROJECT_DIR="$root" DESKTOP_ENV=both MACHINE_TYPE=vm \
  bash "$services" >>"$logp3" 2>&1 || rc=$?
check "PA3: PATH without python3 aborts (rc 1)" "$rc" 1
rc=0; [[ -e "$fakehome_g6/.config/systemd/user/hyprland.service" ]] || rc=1
check "PA3: stale artifact intact (cleanup did NOT run)" "$rc" 0
if find "$fakehome_g6" -name '.my-arch-stale-backup-*' 2>/dev/null | grep -q .; then
  check "PA3: backup_count=0" 1 0
else
  check "PA3: backup_count=0" 0 0
fi
if grep -q 'daemon-reload' "$logp3"; then
  check "PA3: no user daemon-reload before abort" 1 0
else
  check "PA3: no user daemon-reload before abort" 0 0
fi
# G6e: no secondary candidate (rc=1) must also abort BEFORE cleanup
fakehome_g6e="$sandbox/home-g6e"
mkdir -p "$fakehome_g6e/.config/systemd/user/graphical-session.target.wants" "$sandbox/empty-share"
ln -s /usr/lib/systemd/user/dms.service "$fakehome_g6e/.config/systemd/user/graphical-session.target.wants/dms.service"
cp "$backup/.config/systemd/user/hyprland.service" "$fakehome_g6e/.config/systemd/user/hyprland.service" 2>/dev/null || true
log6e="$sandbox/g6e.log"
rc=0
PATH="$sandbox/mockbin:$PATH" FAKE_SYS_LOG="$log6e" FAKE_DMS_ENABLE_RC=0 \
  GREETER_CACHE_DIR="$sandbox/greeter-cache-g" \
  TARGET_XDG_DATA_HOME="$sandbox/empty-share" TARGET_XDG_DATA_DIRS="$sandbox/empty-share" \
  HOME="$fakehome_g6e" PROJECT_DIR="$root" DESKTOP_ENV=both MACHINE_TYPE=vm \
  bash "$services" >>"$log6e" 2>&1 || rc=$?
check "G6e: no candidate aborts before cleanup (rc 1)" "$rc" 1
assert_grep "G6e: error says no candidate" 'no hyprland.desktop candidate' "$log6e"
rc=0; [[ -e "$fakehome_g6e/.config/systemd/user/hyprland.service" ]] || rc=1
check "G6e: stale NOT cleaned before abort" "$rc" 0
if grep -q 'enable dms.service' "$log6e"; then
  check "G6e: no dms enable before abort" 1 0
else
  check "G6e: no dms enable before abort" 0 0
fi
if grep -q 'daemon-reload' "$log6e"; then
  check "G6e: no user daemon-reload before abort" 1 0
else
  check "G6e: no user daemon-reload before abort" 0 0
fi


echo "== H. stale cleanup safety: parent symlinks, non-regular files, backup =="
# H1: parent-dir symlink (the Codex R4.1 repro): ~/.config and ~/.local
# point OUTSIDE the fake HOME; cleanup must NOT read/backup/delete outside.
fakehome_s="$sandbox/home-sym"
outside_c="$sandbox/outside-config"
outside_l="$sandbox/outside-local"
mkdir -p "$fakehome_s" "$outside_c/systemd/user" "$outside_l/bin"
ln -s "$outside_c" "$fakehome_s/.config"
ln -s "$outside_l" "$fakehome_s/.local"
cp "$backup/.config/systemd/user/hyprland.service" "$outside_c/systemd/user/hyprland.service"
cp "$backup/.config/systemd/user/hyprland.service" "$outside_l/bin/hyprland-session"
hash_c="$(sha256sum "$outside_c/systemd/user/hyprland.service" | cut -d' ' -f1)"
hash_l="$(sha256sum "$outside_l/bin/hyprland-session" | cut -d' ' -f1)"
rc=0
HOME="$fakehome_s" bash -c 'source "$0" >/dev/null 2>&1; stale_hypr_cleanup' "$utils" >"$sandbox/h1.out" 2>&1 || rc=$?
check "parent symlink: cleanup rc 0 (no abort)" "$rc" 0
# sentinel "MISSING" keeps the assertion running even when the R4 bug
# deleted the outside file (red side); the hash must be unchanged on green
hash_c2="$(sha256sum "$outside_c/systemd/user/hyprland.service" 2>/dev/null | cut -d' ' -f1 || echo MISSING)"
hash_l2="$(sha256sum "$outside_l/bin/hyprland-session" 2>/dev/null | cut -d' ' -f1 || echo MISSING)"
assert_eq "parent symlink: outside file hash unchanged (.config)" "$hash_c2" "$hash_c"
assert_eq "parent symlink: outside file hash unchanged (.local)" "$hash_l2" "$hash_l"
assert_grep "parent symlink: path reported in warning" 'symlink' "$sandbox/h1.out"

# H2: FIFO at a stale path must not hang and must be kept
fakehome_f="$sandbox/home-fifo"
mkdir -p "$fakehome_f/.config/systemd/user"
mkfifo "$fakehome_f/.config/systemd/user/hyprland.service"
rc=0
timeout 15 env HOME="$fakehome_f" bash -c 'source "$0" >/dev/null 2>&1; stale_hypr_cleanup' "$utils" >"$sandbox/h2.out" 2>&1 || rc=$?
check "FIFO at stale path: cleanup returns (no hang)" "$rc" 0
if [[ -p "$fakehome_f/.config/systemd/user/hyprland.service" ]]; then
  check "FIFO at stale path: kept" 1 1
else
  check "FIFO at stale path: kept" 0 1
fi

# H3: dangling symlink + directory at stale paths kept and reported
fakehome_d="$sandbox/home-dir"
mkdir -p "$fakehome_d/.config/systemd/user" "$fakehome_d/.local/bin"
ln -s /nonexistent "$fakehome_d/.config/systemd/user/hyprland-shutdown.target"
mkdir -p "$fakehome_d/.config/systemd/user/hyprland-session.target"
printf '#!/bin/sh\necho x\n' > "$fakehome_d/.local/bin/hyprland-session-watch"
rc=0
HOME="$fakehome_d" bash -c 'source "$0" >/dev/null 2>&1; stale_hypr_cleanup' "$utils" >"$sandbox/h3.out" 2>&1 || rc=$?
check "dir/dangling at stale paths: cleanup rc 0" "$rc" 0
if [[ -L "$fakehome_d/.config/systemd/user/hyprland-shutdown.target" ]] && [[ -d "$fakehome_d/.config/systemd/user/hyprland-session.target" ]]; then
  check "dir/dangling at stale paths: kept" 1 1
else
  check "dir/dangling at stale paths: kept" 0 1
fi
# R4.2 item 2: the dangling symlink is identified with lstat semantics and
# reported SEPARATELY, not satisfied by the directory/other warning
assert_grep "dangling symlink reported separately" 'dangling or left symlink' "$sandbox/h3.out"
assert_grep "directory at stale path reported" 'not a regular file' "$sandbox/h3.out"

# H4: backup dir is unique and never overwrites a previous one
fakehome_b="$sandbox/home-bak"
mkdir -p "$fakehome_b/.config/systemd/user"
cp "$backup/.config/systemd/user/hyprland.service" "$fakehome_b/.config/systemd/user/hyprland.service"
HOME="$fakehome_b" bash -c 'source "$0" >/dev/null 2>&1; stale_hypr_cleanup' "$utils" >/dev/null 2>&1
bak1="$(find "$fakehome_b/.config/systemd/user" -maxdepth 1 -type d -name '.my-arch-stale-backup-*' | head -1)"
cp "$backup/.config/systemd/user/hyprland.service" "$fakehome_b/.config/systemd/user/hyprland.service"
HOME="$fakehome_b" bash -c 'source "$0" >/dev/null 2>&1; stale_hypr_cleanup' "$utils" >/dev/null 2>&1
bak2="$(find "$fakehome_b/.config/systemd/user" -maxdepth 1 -type d -name '.my-arch-stale-backup-*' | sed -n '2p')"
if [[ -n "$bak1" && -n "$bak2" && "$bak1" != "$bak2" ]]; then
  check "backup dir unique per run (no overwrite)" 0 0
else
  check "backup dir unique per run (no overwrite)" 1 0
fi

# H5: user-modified exact-path file kept + warned
fakehome_m="$sandbox/home-mod"
mkdir -p "$fakehome_m/.config/systemd/user"
cp "$backup/.config/systemd/user/hyprland.service" "$fakehome_m/.config/systemd/user/hyprland.service"
printf '\n# USER MODIFICATION\n' >> "$fakehome_m/.config/systemd/user/hyprland.service"
HOME="$fakehome_m" bash -c 'source "$0" >/dev/null 2>&1; stale_hypr_cleanup' "$utils" >"$sandbox/h5.out" 2>&1 || true
if [[ -e "$fakehome_m/.config/systemd/user/hyprland.service" ]]; then
  check "user-modified exact-path file kept" 1 1
else
  check "user-modified exact-path file kept" 0 1
fi
assert_grep "user-modified exact-path file warned" 'content differs' "$sandbox/h5.out"

# H6: ownership (chown) failure must keep the original (R4.2 item 6)
fakehome_o="$sandbox/home-own"
mkdir -p "$fakehome_o/.config/systemd/user"
cp "$backup/.config/systemd/user/hyprland.service" "$fakehome_o/.config/systemd/user/hyprland.service"
rc=0
HOME="$fakehome_o" bash -c '
  source "$0" >/dev/null 2>&1
  # override the ownership helper: succeed for the backup DIR, fail for the
  # per-file backup -> the original must be kept (R4.2 item 6)
  stale_backup_own() { [[ "$1" == *.my-arch-stale-backup-* && -d "$1" ]] && return 0 || return 1; }
  stale_hypr_cleanup
' "$utils" >"$sandbox/h6.out" 2>&1 || rc=$?
check "chown failure: cleanup rc 0 (kept, not aborted)" "$rc" 0
rc=0; [[ -e "$fakehome_o/.config/systemd/user/hyprland.service" ]] || rc=1
check "chown failure: original file kept" "$rc" 0
assert_grep "chown failure: ownership warning present" 'ownership\|chown' "$sandbox/h6.out"

# H6b: recursive backup-tree ownership failure also keeps the original
# (R4.3 item 4: intermediate dirs must be owned too; failure -> no delete)
fakehome_t="$sandbox/home-own-tree"
mkdir -p "$fakehome_t/.config/systemd/user"
cp "$backup/.config/systemd/user/hyprland.service" "$fakehome_t/.config/systemd/user/hyprland.service"
rc=0
HOME="$fakehome_t" bash -c '
  source "$0" >/dev/null 2>&1
  # override the recursive tree owner to FAIL for every call
  stale_backup_own_tree() { return 1; }
  stale_hypr_cleanup
' "$utils" >"$sandbox/h6b.out" 2>&1 || rc=$?
check "tree-ownership failure: cleanup rc 0 (kept, not aborted)" "$rc" 0
rc=0; [[ -e "$fakehome_t/.config/systemd/user/hyprland.service" ]] || rc=1
check "tree-ownership failure: original file kept" "$rc" 0
assert_grep "tree-ownership failure: warning present" 'ownership' "$sandbox/h6b.out"
# the production code must do a narrow recursive ownership fix within the
# unique backup root (intermediate dirs), not only the root + final file
if grep -q 'chown -R' "$utils"; then
  check "recursive backup ownership fix present in 00-utils" 0 0
else
  check "recursive backup ownership fix present in 00-utils" 1 0
fi

# H7: no /home/pang hardcode in the lifecycle code paths
if grep -rn '/home/pang' "$services" "$utils" >/dev/null 2>&1; then
  check "no /home/pang hardcode in 08-services/00-utils" 1 0
else
  check "no /home/pang hardcode in 08-services/00-utils" 0 0
fi

echo "== I. tool-missing is recorded UNAVAILABLE, never PASS =="
# the UNAVAILABLE accounting mechanism, demonstrated in a subshell so the
# synthetic tool never pollutes the suite's final unavailable count (R4.1)
probe="$(bash -c 'u=0; if ! command -v definitely-not-a-real-tool-xyz >/dev/null 2>&1; then u=$((u+1)); fi; echo "$u"')"
assert_eq "missing tool bumps UNAVAILABLE in the helper (subshell, not global)" "$probe" "1"
if command -v Hyprland >/dev/null 2>&1; then
  mkdir -p "$sandbox/.config/hypr"
  cp -r "$root/config/home/.config/hypr/." "$sandbox/.config/hypr/"
  rc=0
  HOME="$sandbox" XDG_CONFIG_HOME="$sandbox/.config" timeout 30 \
    Hyprland --verify-config -c "$sandbox/.config/hypr/hyprland.lua" >/dev/null 2>&1 || rc=$?
  check "explicit -c hyprland.lua verify ok (rc=0)" "$rc" 0
  rc=0
  HOME="$sandbox" XDG_CONFIG_HOME="$sandbox/.config" timeout 30 \
    Hyprland --verify-config >/dev/null 2>&1 || rc=$?
  check "default discovery of hyprland.lua verify ok (rc=0)" "$rc" 0
else
  unavail_note "Hyprland binary missing (verify-config skipped)"
fi

echo "== J. system Hyprland entry: Exec + desktop-file-validate classification =="
if [[ -f /usr/share/wayland-sessions/hyprland.desktop ]]; then
  cp /usr/share/wayland-sessions/hyprland.desktop "$sandbox/hyprland.desktop"
  exec_line="$(sed -n 's/^Exec=//p' "$sandbox/hyprland.desktop" | head -1)"
  assert_eq "system entry Exec" "$exec_line" "/usr/bin/start-hyprland"
else
  unavail_note "host hyprland.desktop missing (parse skipped)"
fi
# desktop-file-validate classification (Codex R4.2/R4.3):
#   rc=0 -> PASS; rc=1 + every non-empty line is EXACTLY the known
#   DesktopNames diagnostic -> KNOWN (separate count, not PASS); any other
#   nonzero (incl. rc=1 empty stderr, rc=2, other keys, extra lines) -> FAIL;
#   tool missing -> UNAVAILABLE. The known diagnostic must contain all of:
#   key "DesktopNames" + group "Desktop Entry" + the X- suffix message.
KNOWN_DV_ALL=('key "DesktopNames"' 'group "Desktop Entry"' 'keys extending the format should start with "X-"')
classify_dv() { # classify_dv <rc> <errfile> ; echoes PASS|KNOWN|FAIL
  local rc="$1" err="$2" bad=0 line k
  if [[ "$rc" -eq 0 ]]; then echo PASS; return 0; fi
  if [[ "$rc" -ne 1 ]]; then echo FAIL; return 0; fi
  if [[ ! -s "$err" ]]; then echo FAIL; return 0; fi
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    for k in "${KNOWN_DV_ALL[@]}"; do
      [[ "$line" == *"$k"* ]] || { bad=1; break; }
    done
    [[ "$bad" -eq 1 ]] && break
  done < "$err"
  [[ "$bad" -eq 0 ]] && echo KNOWN || echo FAIL
}
: > "$sandbox/err0";  assert_eq "dv classify rc=0 -> PASS" "$(classify_dv 0 "$sandbox/err0")" "PASS"
printf 'x: error: file contains key "DesktopNames" in group "Desktop Entry", but keys extending the format should start with "X-"\n' > "$sandbox/err1k"
assert_eq "dv classify exact DesktopNames diagnostic -> KNOWN" "$(classify_dv 1 "$sandbox/err1k")" "KNOWN"
printf 'x: error: file contains key "OtherNames" in group "Desktop Entry", but keys extending the format should start with "X-"\n' > "$sandbox/err1o"
assert_eq "dv classify OtherNames + same X- suffix -> FAIL" "$(classify_dv 1 "$sandbox/err1o")" "FAIL"
printf 'x: error: file contains key "DesktopNames" in group "Desktop Entry", but keys extending the format should start with "X-"\ny: error: something else\n' > "$sandbox/err1x"
assert_eq "dv classify DesktopNames + extra diagnostic -> FAIL" "$(classify_dv 1 "$sandbox/err1x")" "FAIL"
: > "$sandbox/err1e"; assert_eq "dv classify rc=1 + empty stderr -> FAIL" "$(classify_dv 1 "$sandbox/err1e")" "FAIL"
: > "$sandbox/err2";  assert_eq "dv classify rc=2 + empty stderr -> FAIL" "$(classify_dv 2 "$sandbox/err2")" "FAIL"
printf 'x: error: file contains key "DesktopNames" in group "Desktop Entry", but keys extending the format should start with "X-"\n' > "$sandbox/err2k"
assert_eq "dv classify rc=2 + known msg -> FAIL (rc must be 1)" "$(classify_dv 2 "$sandbox/err2k")" "FAIL"
# real run against the system entry (host file; UNAVAILABLE if tool missing)
if command -v desktop-file-validate >/dev/null 2>&1 && [[ -f /usr/share/wayland-sessions/hyprland.desktop ]]; then
  rc=0
  # desktop-file-validate reports on STDOUT (empty stderr) - capture both
  desktop-file-validate "$sandbox/hyprland.desktop" >"$sandbox/dv.err" 2>&1 || rc=$?
  cls="$(classify_dv "$rc" "$sandbox/dv.err")"
  case "$cls" in
    PASS) check "desktop-file-validate: clean pass" 0 0 ;;
    KNOWN) known=$((known + 1)); printf '  KNOWN desktop-file-validate: known upstream DesktopNames diagnostic (rc=1, not counted as PASS)\n' ;;
    FAIL) check "desktop-file-validate: FAIL (rc=$rc)" 1 0; cat "$sandbox/dv.err" | sed 's/^/      /' ;;
  esac
elif command -v desktop-file-validate >/dev/null 2>&1; then
  unavail_note "host hyprland.desktop missing (validate skipped)"
else
  unavail_note "desktop-file-validate missing"
fi

echo "== K. systemd-analyze verify of dms.service (enabled runtime chain) =="
if command -v systemd-analyze >/dev/null 2>&1 && [[ -f /usr/lib/systemd/user/dms.service ]]; then
  rc=0
  systemd-analyze verify /usr/lib/systemd/user/dms.service >"$sandbox/analyze.out" 2>&1 || rc=$?
  check "systemd-analyze verify dms.service (rc=0)" "$rc" 0
else
  unavail_note "systemd-analyze or dms.service missing (verify skipped)"
fi

echo "== M. Hyprland DMS per-WAYLAND_DISPLAY owner (Codex R4.9; weak once-per-first-frame contract) =="
# R4.9: three-state owner model + ordering + honest weak contract.
#   - hyprland.start fires ONCE at the first frame; reload does NOT re-trigger
#     the helper, so "repeated trigger" guarantees are only about overlapping
#     executions, not arbitrary manual re-calls (Plan 1).
#   - a dms on ANOTHER display is NOT current-Hyprland readiness; systemctl's
#     user-global rc=0 is NOT a current-display owner signal.
#   - the helper (config/home/.local/bin/dms-ensure-display) classifies the
#     CURRENT display via DMS 1.5.3 runtime markers
#     ($XDG_RUNTIME_DIR/danklinux-<pid>.session/.pid/.sock):
#       plausible    = matching .session + owner alive + comm=dms (enough to
#                      NOT start a second owner; NOT bar/IPC ready)
#       absent/stale = no matching marker, or owner dead / clearly not dms
#                      (only this class may enter the direct fallback)
#       unverifiable = matching marker exists but unreadable / owner state
#                      unqueryable -> NEVER blindly start a second owner
#   - ordering: env/runtime check -> per-display flock (overlap guard) ->
#     PRE-check (plausible owner -> return WITHOUT systemctl) -> import ->
#     systemctl start -> POST-check -> fallback only when absent/stale.
autolua="$root/config/home/.config/hypr/conf/autostart.lua"
keylua="$root/config/home/.config/hypr/conf/keybinds.lua"
helper="$root/config/home/.local/bin/dms-ensure-display"
mappings="$root/manifests/config-mappings.tsv"
FAKE_TAG="dms-fake-r49"
# pgrep pattern anchored to the fakes' own `sh -c ...` cmdline (with a
# bracket trick): never matches the invoking shell/wrapper cmdline, which
# may legally contain the tag text (e.g. in report commands).
FAKE_PAT='^sh -c .*dms-fake-r4[9]'

# suite-start leak guard: no fake processes from a previous (possibly
# crashed) run may exist. Precise cmdline tag, never a name-based check.
if pgrep -f "$FAKE_PAT" >/dev/null 2>&1; then
  check "M: no leftover $FAKE_TAG processes at suite start" 1 0
else
  check "M: no leftover $FAKE_TAG processes at suite start" 0 0
fi

# --- M0: static structure (helper contract + Niri isolation + rejected forms) ---
hl_on="$(grep -n 'hl.on("hyprland.start"' "$autolua" | head -1 | cut -d: -f1 || true)"
hl_end="$(awk 'NR>'"${hl_on:-0}"' && /^end\)/ {print NR; exit}' "$autolua" 2>/dev/null || true)"
dms_cmd_ln="$(grep -n 'hl.exec_cmd(.*dms run -d' "$autolua" | head -1 || true)"
dms_ln="${dms_cmd_ln%%:*}"
if [[ -n "$hl_on" && -n "$hl_end" && -n "$dms_ln" && "$dms_ln" -gt "$hl_on" && "$dms_ln" -lt "$hl_end" ]]; then
  check "M: DMS start lives inside hl.on(hyprland.start) block" 0 0
else
  check "M: DMS start lives inside hl.on(hyprland.start) block" 1 0
fi
n_dms_cmds="$(grep -c 'hl.exec_cmd(.*dms run -d' "$autolua" || true)"
if [[ "$n_dms_cmds" -eq 1 ]]; then
  check "M: exactly one DMS-start exec_cmd (single sequential line)" 0 0
else
  check "M: exactly one DMS-start exec_cmd (single sequential line)" 1 0
fi
# R4.12: the DMS start is the physical-machine-proven form - a qs-based guard
# (bracket trick [q]s to avoid self-match) followed by `dms run -d`, on the
# same exec_cmd line. A display-blind global `pgrep -x dms` guard is rejected
# (it would suppress the current session when ANY dms exists elsewhere).
if [[ "$dms_cmd_ln" == *"[q]s"* && "$dms_cmd_ln" == *"dms run -d"* && "$dms_cmd_ln" != *"pgrep -x dms"* ]]; then
  check "M: qs-guarded dms run -d (physical-machine-aligned, no display-blind pgrep)" 0 0
else
  check "M: qs-guarded dms run -d (physical-machine-aligned, no display-blind pgrep)" 1 0
fi
# R4.11: the DMS start's stderr must be persisted to dms-ensure.log under the
# runtime dir (autostart exec redirects stdout/stderr to /dev/null, so without
# this the first real Hyprland session's DMS failures are invisible). The
# redirect must NOT wrap the command in a pipe (which would change the status).
if grep -q 'dms run -d 2>>' "$autolua" && grep -q 'dms-ensure.log' "$autolua"; then
  check "M: DMS stderr persisted to dms-ensure.log (diagnostics visible)" 0 0
else
  check "M: DMS stderr persisted to dms-ensure.log (diagnostics visible)" 1 0
fi
# the autostart must NOT depend on the helper / systemctl / dbus import - the
# proven direct-start path is self-contained (the helper stays as an optional
# diagnostic tool, called manually only). Scoped to exec_cmd lines so the
# prose comments (which may mention the tool) are not counted as commands.
if grep -q 'hl.exec_cmd(.*dms-ensure-display\|hl.exec_cmd(.*systemctl\|hl.exec_cmd(.*dbus-update' "$autolua"; then
  check "M: autostart has no helper/systemctl/dbus dependency (direct start)" 1 0
else
  check "M: autostart has no helper/systemctl/dbus dependency (direct start)" 0 0
fi
if [[ -f "$helper" && -x "$helper" ]]; then
  check "M: dms-ensure-display helper present + executable (diagnostic tool)" 0 0
else
  check "M: dms-ensure-display helper present + executable (diagnostic tool)" 1 0
fi
if [[ -f "$helper" ]] && [[ "$(head -1 "$helper")" == "#!/bin/sh" ]]; then
  check "M: helper is POSIX /bin/sh" 0 0
else
  check "M: helper is POSIX /bin/sh" 1 0
fi
row="$(grep -F "config/home/.local/bin/dms-ensure-display" "$mappings" | head -1 || true)"
if [[ -n "$row" ]]; then
  check "M: helper mapped in config-mappings.tsv" 0 0
  mod="$(printf '%s\n' "$row" | awk -F'\t' '{print $2}')"
  mode="$(printf '%s\n' "$row" | awk -F'\t' '{print $5}')"
  tgt="$(printf '%s\n' "$row" | awk -F'\t' '{print $4}')"
  if [[ "$mod" == "wm-hyprland" && "$mode" == "755" && "$tgt" == ".local/bin/dms-ensure-display" ]]; then
    check "M: mapping module=wm-hyprland mode=755 target=.local/bin" 0 0
  else
    check "M: mapping module=wm-hyprland mode=755 target=.local/bin" 1 0
  fi
else
  check "M: helper mapped in config-mappings.tsv" 1 0
  check "M: mapping module=wm-hyprland mode=755 target=.local/bin" 1 0
fi
for v in WAYLAND_DISPLAY HYPRLAND_INSTANCE_SIGNATURE XDG_CURRENT_DESKTOP XDG_SESSION_TYPE; do
  if [[ -f "$helper" ]] && grep -q "dbus-update-activation-environment" "$helper" && grep -q "$v" "$helper"; then
    check "M: helper imports env var $v" 0 0
  else
    check "M: helper imports env var $v" 1 0
  fi
done
if [[ -f "$helper" ]] && grep -q 'systemctl --user start dms.service' "$helper"; then
  check "M: helper requests systemd dms.service (primary owner)" 0 0
else
  check "M: helper requests systemd dms.service (primary owner)" 1 0
fi
n_dmsd="$(grep -c 'dms run -d' "$helper" 2>/dev/null || true)"
if [[ "$n_dmsd" -eq 1 ]]; then
  check "M: helper contains exactly one guarded dms run -d fallback" 0 0
else
  check "M: helper contains exactly one guarded dms run -d fallback" 1 0
fi
if [[ -f "$helper" ]] && ! grep -q 'pgrep' "$helper"; then
  check "M: helper has no pgrep (global dms check removed)" 0 0
else
  check "M: helper has no pgrep (global dms check removed)" 1 0
fi
if [[ -f "$helper" ]] && ! grep -q '/environ' "$helper"; then
  check "M: helper never reads /proc/<pid>/environ (privacy)" 0 0
else
  check "M: helper never reads /proc/<pid>/environ (privacy)" 1 0
fi
if [[ -f "$helper" ]] && ! grep -qE 'sleep [0-9]+|while true|HYPR_WATCH_TIMEOUT|43200' "$helper"; then
  check "M: no polling/sleep/watcher in helper" 0 0
else
  check "M: no polling/sleep/watcher in helper" 1 0
fi
if [[ -f "$helper" ]] && sh -n "$helper" 2>/dev/null; then
  check "M: helper passes sh -n syntax check" 0 0
else
  check "M: helper passes sh -n syntax check" 1 0
fi
# R4.9: three-state model present in the helper source
if [[ -f "$helper" ]] && grep -q 'plausible' "$helper" && grep -q 'absent' "$helper" && grep -q 'unverifiable' "$helper"; then
  check "M: helper implements plausible/absent/unverifiable three states" 0 0
else
  check "M: helper implements plausible/absent/unverifiable three states" 1 0
fi
# R4.9: the helper must not CLAIM bar/IPC readiness ("healthy" removed)
if [[ -f "$helper" ]] && ! grep -q 'healthy' "$helper"; then
  check "M: helper never claims healthy/ready (plausible owner only)" 0 0
else
  check "M: helper never claims healthy/ready (plausible owner only)" 1 0
fi
# R4.9 ordering: PRE-check (plausible owner -> systemd not requested) must
# come BEFORE the dbus import in the helper source
pre_ln="$(grep -n 'systemd not requested' "$helper" | head -1 | cut -d: -f1 || true)"
dbus_ln_h="$(grep -n 'dbus-update-activation-environment' "$helper" | head -1 | cut -d: -f1 || true)"
if [[ -n "$pre_ln" && -n "$dbus_ln_h" && "$pre_ln" -lt "$dbus_ln_h" ]]; then
  check "M: helper pre-check precedes dbus import (no systemctl when owner present)" 0 0
else
  check "M: helper pre-check precedes dbus import (no systemctl when owner present)" 1 0
fi
# R4.10: the PRE=unverifiable short-circuit (rc=4, no systemd) must also
# precede the dbus import, and must be distinguishable from post-systemd.
preu_ln="$(grep -n 'at PRE-check' "$helper" | head -1 | cut -d: -f1 || true)"
postu_ln="$(grep -n 'after systemd request' "$helper" | head -1 | cut -d: -f1 || true)"
if [[ -n "$preu_ln" && -n "$dbus_ln_h" && "$preu_ln" -lt "$dbus_ln_h" ]]; then
  check "M: helper PRE-unverifiable short-circuit precedes dbus import" 0 0
else
  check "M: helper PRE-unverifiable short-circuit precedes dbus import" 1 0
fi
if [[ -n "$preu_ln" && -n "$postu_ln" && "$preu_ln" -lt "$postu_ln" ]]; then
  check "M: PRE-unverifiable distinct from post-systemd unverifiable" 0 0
else
  check "M: PRE-unverifiable distinct from post-systemd unverifiable" 1 0
fi
if grep -q 'dms run -d\|systemctl --user start dms' "$root/config/home/.config/niri/config.kdl" "$root/config/home/.config/niri/dms/"*.kdl 2>/dev/null; then
  check "M: no dms daemon/direct start in Niri config" 1 0
else
  check "M: no dms daemon/direct start in Niri config" 0 0
fi
n_all_dmsd="$(grep -rc 'dms run -d' "$root/config/home" 2>/dev/null | awk -F: '{s+=$2} END{print s+0}' || true)"
# R4.12: exactly two guarded occurrences - the autostart qs-guarded line and
# the helper's three-state fallback line (both guarded, never unconditional)
if [[ "$n_all_dmsd" -eq 2 ]]; then
  check "M: dms run -d appears exactly twice in config/home (autostart guard + helper fallback)" 0 0
else
  check "M: dms run -d appears exactly twice in config/home (autostart guard + helper fallback)" 1 0
fi

# --- M1: per-display state machine with fake systemctl/dbus/dms ---
# All fakes, runtime markers, logs and PID files live inside the workspace
# sandbox; tests run the PRODUCTION helper with a fake PATH + a fake
# XDG_RUNTIME_DIR, so the real host DMS is never touched. Fake contracts:
#   dbus-update-activation-environment: rc from FAKE_DBUS_RC (default 0)
#   systemctl: rc from FAKE_SYSTEMCTL_RC; on rc=0 with FAKE_SYSTEMCTL_LIVE_PID
#              set, writes a current-display marker set (emulating systemd
#              having started dms for this display)
#   dms:       rc from FAKE_DMS_RC; `run -d` writes a current-display marker
#              set synchronously (FAKE_DMS_LIVE_PID) UNLESS FAKE_DMS_NO_MARKER
#              is set (emulating a daemon child whose markers are not yet
#              visible -> the documented weak-contract window)
mbin="$sandbox/mbin-dms"
mkdir -p "$mbin"
cat > "$mbin/dbus-update-activation-environment" <<'EOF'
#!/bin/sh
echo "dbus-update-activation-environment $*" >> "${DMS_LOG:?}"
exit "${FAKE_DBUS_RC:-0}"
EOF
cat > "$mbin/systemctl" <<'EOF'
#!/bin/sh
if [ -n "${FAKE_SYSTEMCTL_RC:-}" ] && [ "${FAKE_SYSTEMCTL_RC:-0}" != "0" ]; then
  echo "systemctl $* rc=FAIL($FAKE_SYSTEMCTL_RC)" >> "${DMS_LOG:?}"
  exit "$FAKE_SYSTEMCTL_RC"
fi
echo "systemctl $* rc=OK" >> "${DMS_LOG:?}"
if [ -n "${FAKE_SYSTEMCTL_LIVE_PID:-}" ] && [ -n "${WAYLAND_DISPLAY:-}" ] && [ -n "${XDG_RUNTIME_DIR:-}" ]; then
  printf '%s' "$WAYLAND_DISPLAY" > "$XDG_RUNTIME_DIR/danklinux-$FAKE_SYSTEMCTL_LIVE_PID.session"
  printf '%s' "$FAKE_SYSTEMCTL_LIVE_PID" > "$XDG_RUNTIME_DIR/danklinux-$FAKE_SYSTEMCTL_LIVE_PID.pid"
  : > "$XDG_RUNTIME_DIR/danklinux-$FAKE_SYSTEMCTL_LIVE_PID.sock"
fi
exit 0
EOF
# fake pgrep (R4.12: the aligned autostart uses a qs guard; without a fake the
# real host pgrep would find the REAL qs and the M-R4.11 test could never
# exercise the dms run -d branch)
cat > "$mbin/pgrep" <<'EOF'
#!/bin/sh
echo "pgrep $*" >> "${DMS_LOG:?}"
if [ -f "${FAKE_PGREP_STATE:-/nonexistent-pgrep-state}" ]; then
  echo "pgrep $* rc=OK(found)" >> "${DMS_LOG:?}"
  exit 0
fi
exit "${FAKE_PGREP_RC:-1}"
EOF
cat > "$mbin/dms" <<'EOF'
#!/bin/sh
echo "dms $*" >> "${DMS_LOG:?}"
if [ -n "${FAKE_DMS_RC:-}" ] && [ "$FAKE_DMS_RC" != "0" ]; then
  exit "$FAKE_DMS_RC"
fi
case " $* " in
  *" run -d "*)
    # stderr line so the autostart's `2>>dms-ensure.log` redirect is provable
    echo "dms run -d executed (fake)" >&2
    if [ -z "${FAKE_DMS_NO_MARKER:-}" ] && [ -n "${FAKE_DMS_LIVE_PID:-}" ] && [ -n "${WAYLAND_DISPLAY:-}" ] && [ -n "${XDG_RUNTIME_DIR:-}" ]; then
      printf '%s' "$WAYLAND_DISPLAY" > "$XDG_RUNTIME_DIR/danklinux-$FAKE_DMS_LIVE_PID.session"
      printf '%s' "$FAKE_DMS_LIVE_PID" > "$XDG_RUNTIME_DIR/danklinux-$FAKE_DMS_LIVE_PID.pid"
      : > "$XDG_RUNTIME_DIR/danklinux-$FAKE_DMS_LIVE_PID.sock"
    fi
    ;;
esac
exit 0
EOF
# fake cat: passes through to the real cat EXCEPT for the single path named
# by FAKE_CAT_FAIL (simulates a transient /proc/<owner>/comm read failure).
cat > "$mbin/cat" <<'EOF'
#!/bin/sh
for a in "$@"; do
  if [ "$a" = "${FAKE_CAT_FAIL:-/nonexistent-fake-cat}" ]; then
    echo "cat: fake failure on $a" >&2
    exit 1
  fi
done
exec /usr/bin/cat "$@"
EOF
# fake sed: passes through to the real sed EXCEPT for the single path named
# by FAKE_SED_FAIL (simulates a transient /proc/<owner>/stat read failure).
cat > "$mbin/sed" <<'EOF'
#!/bin/sh
for a in "$@"; do
  if [ "$a" = "${FAKE_SED_FAIL:-/nonexistent-fake-sed}" ]; then
    echo "sed: fake failure on $a" >&2
    exit 1
  fi
done
exec /usr/bin/sed "$@"
EOF
chmod +x "$mbin"/*
rt="$sandbox/rt-dms"
rm -rf "$rt"; mkdir -p "$rt"
# live* variables are explicitly initialized (and later assigned in the
# PARENT scope by start_live_dms via printf -v) so shellcheck sees them as
# assigned - no file-level SC2154 suppression needed.
liveC1a="" liveC1b="" liveC2="" liveC3="" liveC4=""
liveD1="" liveD2="" liveB1="" liveB2="" liveE3="" liveE4=""
# start_live_dms <varname> - starts a live process whose comm is exactly
# "dms" (no newline) and sets <varname> in the PARENT scope (no command
# substitution: live_pids must be registered in the parent so the EXIT trap
# and cleanup see it). Bounded comm init; FAIL/abort if the contract cannot
# be met - never return a pid that does not satisfy it.
start_live_dms() {
  local varname="$1" pid i=0
  sh -c 'printf "dms" >/proc/self/comm; sleep 300; :' "$FAKE_TAG" >/dev/null 2>&1 &
  pid=$!
  live_pids="$live_pids $pid"
  while [ $i -lt 100 ]; do
    [ "$(cat "/proc/$pid/comm" 2>/dev/null)" = "dms" ] && break
    i=$((i + 1))
    sleep 0.01
  done
  if [ "$(cat "/proc/$pid/comm" 2>/dev/null)" != "dms" ]; then
    echo "FATAL: start_live_dms could not initialize comm=dms for pid $pid" >&2
    exit 1
  fi
  printf -v "$varname" '%s' "$pid"
}
mkmarker() { # mkmarker <owner> <display> [pid-content]
  local x="$1" d="$2" pc="${3:-}"
  printf '%s' "$d" > "$rt/danklinux-$x.session"
  if [ -n "$pc" ]; then printf '%s' "$pc" > "$rt/danklinux-$x.pid"; fi
  : > "$rt/danklinux-$x.sock"
}
count_display_markers() { # count_display_markers <display> ; echo count
  grep -l "^$1" "$rt"/danklinux-*.session 2>/dev/null | wc -l
}
count_marker_files() { # count_marker_files ; echo count of danklinux-*.session files
  ls "$rt"/danklinux-*.session 2>/dev/null | wc -l
}
run_chain() { # run_chain <logfile> <errfile> [env overrides...]
  local log="$1" errf="$2"; shift 2
  : > "$log"; : > "$errf"
  local rc=0
  # WAYLAND_DISPLAY is FORCED to wayland-new (never inherited): the host shell
  # may carry a real WAYLAND_DISPLAY which must not leak into the fake chain.
  env PATH="$mbin:$PATH" DMS_LOG="$log" WAYLAND_DISPLAY="wayland-new" \
    XDG_RUNTIME_DIR="$rt" "$@" "$helper" >>"$errf" 2>&1 || rc=$?
  printf '%s' "$rc" > "$log.rc"
}
cleanup_fakes() { # kill + wait every registered fake pid (exact PID list only)
  local p
  for p in $live_pids; do pkill -P "$p" 2>/dev/null || true; kill "$p" 2>/dev/null || true; done
  for p in $live_pids; do wait "$p" 2>/dev/null || true; done
}

# --- C1: existing direct owner on the CURRENT display -> systemctl NOT
# called (fake systemctl would create a SECOND current-display marker set).
start_live_dms liveC1a
start_live_dms liveC1b
rm -rf "${rt:?}"/*
mkmarker "$liveC1a" wayland-new "$liveC1a"
run_chain "$sandbox/c1.log" "$sandbox/c1.err" FAKE_SYSTEMCTL_RC=0 FAKE_SYSTEMCTL_LIVE_PID="$liveC1b" FAKE_DMS_LIVE_PID="$liveC1b"
rc="$(cat "$sandbox/c1.log.rc")"
check "M-C1: existing owner -> rc 0" "$rc" 0
if grep -q 'systemctl' "$sandbox/c1.log"; then
  check "M-C1: systemctl NOT called when a current-display owner exists" 1 0
else
  check "M-C1: systemctl NOT called when a current-display owner exists" 0 0
fi
if grep -q 'dms run -d' "$sandbox/c1.log"; then
  check "M-C1: no fallback when a current-display owner exists" 1 0
else
  check "M-C1: no fallback when a current-display owner exists" 0 0
fi
if [[ "$(count_display_markers wayland-new)" -eq 1 ]]; then
  check "M-C1: exactly one current-display marker set (no second owner)" 0 0
else
  check "M-C1: exactly one current-display marker set (no second owner)" 1 0
fi

# --- C2: only ANOTHER display has a healthy owner + systemctl fails ->
# current display still gets its fallback, exactly once.
start_live_dms liveC2
rm -rf "${rt:?}"/*
mkmarker "$liveC2" wayland-old "$liveC2"
run_chain "$sandbox/c2.log" "$sandbox/c2.err" FAKE_SYSTEMCTL_RC=1
assert_grep "M-C2: systemctl failure recorded" 'systemctl --user start dms.service rc=FAIL' "$sandbox/c2.log"
n="$(grep -c 'dms run -d' "$sandbox/c2.log" || true)"
if [[ "$n" -eq 1 ]]; then
  check "M-C2: other-display owner does NOT suppress current-display fallback" 0 0
else
  check "M-C2: other-display owner does NOT suppress current-display fallback" 1 0
fi

# --- C3: systemctl rc=0 but serves ONLY another display -> current display
# still gets its own fallback request (user-global success is not readiness).
start_live_dms liveC3
rm -rf "${rt:?}"/*
mkmarker "$liveC3" wayland-old "$liveC3"
run_chain "$sandbox/c3.log" "$sandbox/c3.err" FAKE_SYSTEMCTL_RC=0
assert_grep "M-C3: systemctl user-global success recorded" 'systemctl --user start dms.service rc=OK' "$sandbox/c3.log"
n="$(grep -c 'dms run -d' "$sandbox/c3.log" || true)"
if [[ "$n" -eq 1 ]]; then
  check "M-C3: current display still gets its own owner despite systemctl rc=0" 0 0
else
  check "M-C3: current display still gets its own owner despite systemctl rc=0" 1 0
fi

# --- C4: systemctl rc=0 AND systemd actually provides the current-display
# owner (fake writes the marker) -> no direct fallback.
start_live_dms liveC4
rm -rf "${rt:?}"/*
run_chain "$sandbox/c4.log" "$sandbox/c4.err" FAKE_SYSTEMCTL_RC=0 FAKE_SYSTEMCTL_LIVE_PID="$liveC4"
assert_grep "M-C4: systemctl start invoked (primary owner)" 'systemctl --user start dms.service rc=OK' "$sandbox/c4.log"
if grep -q 'dms run -d' "$sandbox/c4.log"; then
  check "M-C4: no fallback when systemd provided the current-display owner" 1 0
else
  check "M-C4: no fallback when systemd provided the current-display owner" 0 0
fi

# --- D1: plausible owner with PARTIAL companion state (.pid missing) is
# still plausible - never misjudged as absent -> no fallback, no systemctl.
start_live_dms liveD1
rm -rf "${rt:?}"/*
mkmarker "$liveD1" wayland-new            # .session + .sock only, no .pid
run_chain "$sandbox/d1.log" "$sandbox/d1.err" FAKE_SYSTEMCTL_RC=1 FAKE_DMS_LIVE_PID="$liveD1"
if grep -q 'dms run -d' "$sandbox/d1.log"; then
  check "M-D1: live owner with partial state is NOT treated as absent" 1 0
else
  check "M-D1: live owner with partial state is NOT treated as absent" 0 0
fi
if grep -q 'systemctl' "$sandbox/d1.log"; then
  check "M-D1: partial-state live owner -> systemctl not requested" 1 0
else
  check "M-D1: partial-state live owner -> systemctl not requested" 0 0
fi

# --- D2: STALE markers (dead owner / pid reuse with comm != dms) ARE absent
# -> fallback allowed.
rm -rf "${rt:?}"/*
mkmarker 4444 wayland-new 999999          # owner pid dead (stale marker)
sleep 300 & liveD2=$!
live_pids="$live_pids $liveD2"
mkmarker "$liveD2" wayland-new "$liveD2"  # owner alive but comm="sleep" (pid reuse)
run_chain "$sandbox/d2.log" "$sandbox/d2.err" FAKE_SYSTEMCTL_RC=1
n="$(grep -c 'dms run -d' "$sandbox/d2.log" || true)"
if [[ "$n" -eq 1 ]]; then
  check "M-D2: stale/dead/pid-reuse markers are absent (fallback ran)" 0 0
else
  check "M-D2: stale/dead/pid-reuse markers are absent (fallback ran)" 1 0
fi

# --- D3: UNVERIFIABLE state at PRE-check -> rc=4, NO dbus/systemctl/dms
# calls, marker count unchanged. The fake systemctl WOULD create a second
# current-display marker if called, so any wrongful call is caught (not
# masked by FAKE_SYSTEMCTL_RC).
# (a) unreadable matching marker file.
rm -rf "${rt:?}"/*
printf '%s' "wayland-new" > "$rt/danklinux-999998.session"
chmod 000 "$rt/danklinux-999998.session"
n_before="$(count_marker_files)"
run_chain "$sandbox/d3a.log" "$sandbox/d3a.err" FAKE_SYSTEMCTL_RC=0 FAKE_SYSTEMCTL_LIVE_PID="$liveD1" FAKE_DMS_LIVE_PID="$liveD1"
rc="$(cat "$sandbox/d3a.log.rc")"
check "M-D3a: unreadable marker -> rc=4 (unverifiable)" "$rc" 4
if grep -q 'dbus-update-activation-environment' "$sandbox/d3a.log"; then
  check "M-D3a: unverifiable -> dbus NOT called" 1 0
else
  check "M-D3a: unverifiable -> dbus NOT called" 0 0
fi
if grep -q 'systemctl' "$sandbox/d3a.log"; then
  check "M-D3a: unverifiable -> systemctl NOT called" 1 0
else
  check "M-D3a: unverifiable -> systemctl NOT called" 0 0
fi
if grep -q 'dms run -d' "$sandbox/d3a.log"; then
  check "M-D3a: unverifiable state -> no blind fallback" 1 0
else
  check "M-D3a: unverifiable state -> no blind fallback" 0 0
fi
n_after="$(count_marker_files)"
check "M-D3a: unverifiable -> no second marker created" "$n_after" "$n_before"
# (b) non-numeric matching owner pid.
rm -rf "${rt:?}"/*
printf '%s' "wayland-new" > "$rt/danklinux-abc.session"
n_before="$(count_marker_files)"
run_chain "$sandbox/d3b.log" "$sandbox/d3b.err" FAKE_SYSTEMCTL_RC=0 FAKE_SYSTEMCTL_LIVE_PID="$liveD1" FAKE_DMS_LIVE_PID="$liveD1"
rc="$(cat "$sandbox/d3b.log.rc")"
check "M-D3b: non-numeric owner -> rc=4 (unverifiable)" "$rc" 4
if grep -q 'dbus-update-activation-environment\|systemctl\|dms run -d' "$sandbox/d3b.log"; then
  check "M-D3b: unqueryable owner -> no dbus/systemctl/dms calls" 1 0
else
  check "M-D3b: unqueryable owner -> no dbus/systemctl/dms calls" 0 0
fi
n_after="$(count_marker_files)"
check "M-D3b: unverifiable -> no second marker created" "$n_after" "$n_before"

# --- E1: PRE=unverifiable must short-circuit BEFORE dbus/systemctl. An
# unreadable matching current-display marker + a fake systemctl that would
# create a second owner: the helper must exit rc=4 with ZERO calls and keep
# exactly one marker. The log must say PRE-check unverifiable, not post-systemd.
rm -rf "${rt:?}"/*
printf '%s' "wayland-new" > "$rt/danklinux-999997.session"
chmod 000 "$rt/danklinux-999997.session"
n_before="$(count_marker_files)"
run_chain "$sandbox/e1.log" "$sandbox/e1.err" FAKE_SYSTEMCTL_RC=0 FAKE_SYSTEMCTL_LIVE_PID="$liveD1" FAKE_DMS_LIVE_PID="$liveD1"
rc="$(cat "$sandbox/e1.log.rc")"
check "M-E1: PRE-unverifiable -> rc=4" "$rc" 4
if grep -q 'dbus-update-activation-environment\|systemctl\|dms run -d' "$sandbox/e1.log"; then
  check "M-E1: PRE-unverifiable -> no dbus/systemctl/dms calls" 1 0
else
  check "M-E1: PRE-unverifiable -> no dbus/systemctl/dms calls" 0 0
fi
n_after="$(count_marker_files)"
check "M-E1: PRE-unverifiable -> marker count unchanged" "$n_after" "$n_before"
if grep -q 'PRE-check' "$sandbox/e1.err" && ! grep -q 'post systemd' "$sandbox/e1.err"; then
  check "M-E1: log names PRE-check (not post-systemd)" 0 0
else
  check "M-E1: log names PRE-check (not post-systemd)" 1 0
fi

# --- E2: non-numeric matching owner is PRE=unverifiable too.
rm -rf "${rt:?}"/*
printf '%s' "wayland-new" > "$rt/danklinux-abc2.session"
n_before="$(count_marker_files)"
run_chain "$sandbox/e2.log" "$sandbox/e2.err" FAKE_SYSTEMCTL_RC=0 FAKE_SYSTEMCTL_LIVE_PID="$liveD1" FAKE_DMS_LIVE_PID="$liveD1"
rc="$(cat "$sandbox/e2.log.rc")"
check "M-E2: non-numeric owner -> PRE rc=4" "$rc" 4
if grep -q 'dbus-update-activation-environment\|systemctl\|dms run -d' "$sandbox/e2.log"; then
  check "M-E2: non-numeric owner -> no dbus/systemctl/dms calls" 1 0
else
  check "M-E2: non-numeric owner -> no dbus/systemctl/dms calls" 0 0
fi
n_after="$(count_marker_files)"
check "M-E2: non-numeric owner -> marker count unchanged" "$n_after" "$n_before"

# --- E3: /proc/<owner>/comm query FAILURE (fake cat fails only on that
# path) -> PRE=unverifiable, rc=4, no calls, no second marker.
start_live_dms liveE3
rm -rf "${rt:?}"/*
mkmarker "$liveE3" wayland-new "$liveE3"
n_before="$(count_marker_files)"
run_chain "$sandbox/e3.log" "$sandbox/e3.err" FAKE_CAT_FAIL="/proc/$liveE3/comm" FAKE_SYSTEMCTL_RC=0 FAKE_SYSTEMCTL_LIVE_PID="$liveD1" FAKE_DMS_LIVE_PID="$liveD1"
rc="$(cat "$sandbox/e3.log.rc")"
check "M-E3: comm query failure -> rc=4" "$rc" 4
if grep -q 'dbus-update-activation-environment\|systemctl\|dms run -d' "$sandbox/e3.log"; then
  check "M-E3: comm query failure -> no dbus/systemctl/dms calls" 1 0
else
  check "M-E3: comm query failure -> no dbus/systemctl/dms calls" 0 0
fi
n_after="$(count_marker_files)"
check "M-E3: comm query failure -> no second marker" "$n_after" "$n_before"

# --- E4: /proc/<owner>/stat query FAILURE (fake sed fails only on that
# path) -> PRE=unverifiable, rc=4, no calls.
start_live_dms liveE4
rm -rf "${rt:?}"/*
mkmarker "$liveE4" wayland-new "$liveE4"
run_chain "$sandbox/e4.log" "$sandbox/e4.err" FAKE_SED_FAIL="/proc/$liveE4/stat" FAKE_SYSTEMCTL_RC=0 FAKE_SYSTEMCTL_LIVE_PID="$liveD1" FAKE_DMS_LIVE_PID="$liveD1"
rc="$(cat "$sandbox/e4.log.rc")"
check "M-E4: stat query failure -> rc=4" "$rc" 4
if grep -q 'dbus-update-activation-environment\|systemctl\|dms run -d' "$sandbox/e4.log"; then
  check "M-E4: stat query failure -> no dbus/systemctl/dms calls" 1 0
else
  check "M-E4: stat query failure -> no dbus/systemctl/dms calls" 0 0
fi

# --- A1: runtime dir unset + systemctl fails -> explicit nonzero (rc=2),
# never a rc=0 + no-owner + no-fallback false success.
rm -rf "${rt:?}"/*
run_chain "$sandbox/a1.log" "$sandbox/a1.err" XDG_RUNTIME_DIR="" FAKE_SYSTEMCTL_RC=1
rc="$(cat "$sandbox/a1.log.rc")"
check "M-A1: runtime unset + systemctl fail -> rc=2" "$rc" 2
if grep -q 'dms run -d' "$sandbox/a1.log"; then
  check "M-A1: no fallback when runtime unverifiable + systemd failed" 1 0
else
  check "M-A1: no fallback when runtime unverifiable + systemd failed" 0 0
fi

# --- A2: runtime dir is a regular FILE (not a dir) + systemctl fails.
printf 'not a dir' > "$sandbox/rtfile"
rm -rf "${rt:?}"/*
run_chain "$sandbox/a2.log" "$sandbox/a2.err" XDG_RUNTIME_DIR="$sandbox/rtfile" FAKE_SYSTEMCTL_RC=1
rc="$(cat "$sandbox/a2.log.rc")"
check "M-A2: runtime not-a-dir + systemctl fail -> rc=2" "$rc" 2

# --- A3: runtime unset but systemctl rc=0 -> rc=3, "requested but
# UNVERIFIED", no healthy/owner claim.
rm -rf "${rt:?}"/*
run_chain "$sandbox/a3.log" "$sandbox/a3.err" XDG_RUNTIME_DIR="" FAKE_SYSTEMCTL_RC=0
rc="$(cat "$sandbox/a3.log.rc")"
check "M-A3: runtime unset + systemctl rc=0 -> rc=3 (UNVERIFIED)" "$rc" 3
if grep -q 'UNVERIFIED' "$sandbox/a3.err"; then
  check "M-A3: UNVERIFIED state reported (no healthy claim)" 0 0
else
  check "M-A3: UNVERIFIED state reported (no healthy claim)" 1 0
fi

# --- B1: direct fallback returns BEFORE its marker is visible (delayed
# marker window) -> a second immediate call falls back again. This is the
# DOCUMENTED weak contract (Plan 1): the flock only guards OVERLAPPING
# executions; hyprland.start fires once at the first frame, so two immediate
# manual calls are outside the guarantee. The boundary is proven, not faked.
start_live_dms liveB1
rm -rf "${rt:?}"/*
run_chain "$sandbox/b1-1.log" "$sandbox/b1-1.err" FAKE_SYSTEMCTL_RC=1 FAKE_DMS_LIVE_PID="$liveB1" FAKE_DMS_NO_MARKER=1
run_chain "$sandbox/b1-2.log" "$sandbox/b1-2.err" FAKE_SYSTEMCTL_RC=1 FAKE_DMS_LIVE_PID="$liveB1" FAKE_DMS_NO_MARKER=1
d_total="$(cat "$sandbox/b1-1.log" "$sandbox/b1-2.log" | grep -c 'dms run -d' || true)"
if [[ "$d_total" -eq 2 ]]; then
  check "M-B1: delayed-marker window -> second call falls back (weak contract, documented)" 0 0
else
  check "M-B1: delayed-marker window -> second call falls back (weak contract, documented)" 1 0
fi

# --- B2: the first fallback's marker IS already visible when the second call
# runs -> the second call's PRE-check sees the owner -> no second fallback.
start_live_dms liveB2
rm -rf "${rt:?}"/*
run_chain "$sandbox/b2-1.log" "$sandbox/b2-1.err" FAKE_SYSTEMCTL_RC=1 FAKE_DMS_LIVE_PID="$liveB2"
run_chain "$sandbox/b2-2.log" "$sandbox/b2-2.err" FAKE_SYSTEMCTL_RC=1 FAKE_DMS_LIVE_PID="$liveB2"
d_total="$(cat "$sandbox/b2-1.log" "$sandbox/b2-2.log" | grep -c 'dms run -d' || true)"
if [[ "$d_total" -eq 1 ]]; then
  check "M-B2: visible marker -> second call does not re-start (pre-check)" 0 0
else
  check "M-B2: visible marker -> second call does not re-start (pre-check)" 1 0
fi
if grep -q 'systemctl' "$sandbox/b2-2.log"; then
  check "M-B2: second call short-circuits before systemctl (owner present)" 1 0
else
  check "M-B2: second call short-circuits before systemctl (owner present)" 0 0
fi

# --- B3: per-display flock OVERLAP guard - a concurrent invocation holding
# the lock means no systemctl call and no fallback (that invocation is the
# start request - not a false success).
rm -rf "${rt:?}"/*
lockfile="$rt/dms-ensure-wayland-new.lock"
( exec 9>"$lockfile"; flock -n 9 || exit 9
  run_chain "$sandbox/b3.log" "$sandbox/b3.err" FAKE_SYSTEMCTL_RC=1 FAKE_DMS_LIVE_PID="$liveB2" )
n="$(grep -c 'dms run -d' "$sandbox/b3.log" || true)"
if [[ "$n" -eq 0 ]]; then
  check "M-B3: lock busy (overlap) -> no duplicate fallback" 0 0
else
  check "M-B3: lock busy (overlap) -> no duplicate fallback" 1 0
fi
if grep -q 'systemctl' "$sandbox/b3.log"; then
  check "M-B3: lock busy -> systemctl not requested (lock precedes import)" 1 0
else
  check "M-B3: lock busy -> systemctl not requested (lock precedes import)" 0 0
fi
if grep -q 'another invocation' "$sandbox/b3.err"; then
  check "M-B3: lock busy reported" 0 0
else
  check "M-B3: lock busy reported" 1 0
fi

# --- B4: order dbus-import < systemctl < dms run -d (from the C3 log)
dbus_ln="$(lineno 'dbus-update-activation-environment' "$sandbox/c3.log")"
sysctl_ln="$(lineno 'systemctl --user start dms.service' "$sandbox/c3.log")"
dmsd_ln="$(lineno 'dms run -d' "$sandbox/c3.log")"
if [[ -n "$dbus_ln" && -n "$sysctl_ln" && -n "$dmsd_ln" && "$dbus_ln" -lt "$sysctl_ln" && "$sysctl_ln" -lt "$dmsd_ln" ]]; then
  check "M-B4: order dbus-import < systemctl < dms run -d" 0 0
else
  check "M-B4: order dbus-import < systemctl < dms run -d" 1 0
fi

# --- B5: the direct fallback command itself fails -> explicit rc=5.
rm -rf "${rt:?}"/*
run_chain "$sandbox/b5.log" "$sandbox/b5.err" FAKE_SYSTEMCTL_RC=1 FAKE_DMS_RC=127
rc="$(cat "$sandbox/b5.log.rc")"
check "M-B5: fallback failure returns rc=5" "$rc" 5
if grep -q 'fallback failed' "$sandbox/b5.err"; then
  check "M-B5: fallback failure reported" 0 0
else
  check "M-B5: fallback failure reported" 1 0
fi

# --- B6: no WAYLAND_DISPLAY -> unusable env, explicit rc=1.
rm -rf "${rt:?}"/*
run_chain "$sandbox/b6.log" "$sandbox/b6.err" WAYLAND_DISPLAY="" FAKE_SYSTEMCTL_RC=0
rc="$(cat "$sandbox/b6.log.rc")"
check "M-B6: missing WAYLAND_DISPLAY returns rc=1" "$rc" 1
if grep -q 'WAYLAND_DISPLAY not set' "$sandbox/b6.err"; then
  check "M-B6: missing WAYLAND_DISPLAY reported" 0 0
else
  check "M-B6: missing WAYLAND_DISPLAY reported" 1 0
fi

# --- R4.11/R4.12: run the autostart DMS exec_cmd end-to-end (as Hyprland
# would via /bin/sh -c) and assert the DMS start's stderr is PERSISTED to
# $XDG_RUNTIME_DIR/dms-ensure.log while the behavior (qs absent -> dms run -d)
# is unchanged. Without the redirect the log file never appears and the first
# real Hyprland session's DMS failure stays invisible.
rm -rf "${rt:?}"/*
autostart_cmd="$(grep -n 'hl.exec_cmd(.*dms run -d' "$autolua" | head -1 | sed -n 's/^[0-9]*:.*hl\.exec_cmd("\([^"]*\)").*/\1/p' || true)"
: > "$sandbox/r411-cmd.log"
env PATH="$mbin:$PATH" DMS_LOG="$sandbox/r411-cmd.log" WAYLAND_DISPLAY="wayland-new" \
  XDG_RUNTIME_DIR="$rt" FAKE_PGREP_RC=1 \
  bash -c "$autostart_cmd" >/dev/null 2>&1 || true
if [[ -s "$rt/dms-ensure.log" ]]; then
  check "M-R4.11: autostart path persists DMS diagnostics to dms-ensure.log" 0 0
else
  check "M-R4.11: autostart path persists DMS diagnostics to dms-ensure.log" 1 0
fi
n="$(grep -c 'dms run -d' "$sandbox/r411-cmd.log" || true)"
if [[ "$n" -eq 1 ]]; then
  check "M-R4.11: redirect does not change behavior (fallback still ran)" 0 0
else
  check "M-R4.11: redirect does not change behavior (fallback still ran)" 1 0
fi

# --- cleanup + residue assertions: every fake pid from this run must be
# gone (kill -0 fails) and the precise fake cmdline must not exist.
cleanup_fakes
res=0
for p in $live_pids; do
  if kill -0 "$p" 2>/dev/null; then res=1; fi
done
check "M: all fake pids reaped (kill -0 fails)" "$res" 0
if pgrep -f "$FAKE_PAT" >/dev/null 2>&1; then
  check "M: no $FAKE_TAG cmdline residue after cleanup" 1 0
else
  check "M: no $FAKE_TAG cmdline residue after cleanup" 0 0
fi
echo "== M2. keybind regression assertions (R4.7, no rewrite) =="
assert_grep "keybind: Alt+Return present" 'hl.bind("ALT + Return"' "$keylua"
assert_grep "keybind: Super+Return present" 'hl.bind(mainMod .. " + Return"' "$keylua"
assert_grep "keybind: file manager (nemo) present" 'fileManager = "nemo"' "$keylua"
assert_grep "keybind: file manager bind present" 'hl.bind(mainMod .. " + E"' "$keylua"
assert_grep "keybind: DMS IPC bind present (settings focusOrToggle)" 'dms ipc call settings focusOrToggle' "$keylua"
n_ipc="$(grep -c 'dms ipc call' "$keylua" || true)"
if [[ "$n_ipc" -ge 10 ]]; then
  check "keybind: DMS IPC binds count >= 10" 0 0
else
  check "keybind: DMS IPC binds count >= 10" 1 0
fi
if command -v luac >/dev/null 2>&1; then
  syn_bad=0
  while IFS= read -r -d '' lf; do
    luac -p "$lf" >/dev/null 2>&1 || syn_bad=1
  done < <(find "$root/config/home/.config/hypr" -name '*.lua' -print0)
  check "keybind: all hypr lua files pass luac -p" "$syn_bad" 0
else
  unavail_note "luac missing (hypr lua syntax check skipped)"
fi

echo "== L. sandbox inside workspace + real greeter memory untouched =="
case "$sandbox" in
  "$root/download-mode-lab/fixtures/tmp/"*) check "all temp state inside workspace" 0 0 ;;
  *) check "all temp state inside workspace" 1 0 ;;
esac
if [[ -e "$real_mem" || -L "$real_mem" ]]; then
  after_real="$(sha256sum "$(readlink -f "$real_mem" 2>/dev/null || echo "$real_mem")" 2>/dev/null | cut -d' ' -f1 || echo unreadable)"
  assert_eq "real greeter memory hash unchanged (never touched)" "$after_real" "$real_mem_before"
else
  if [[ "$real_mem_before" == "absent" ]]; then
    check "real greeter memory absent (nothing to touch)" 0 0
  else
    check "real greeter memory absent (nothing to touch)" 1 0
  fi
fi

echo "== M-end. fake process residue (exact PID + precise cmdline) =="
res=0
for p in $live_pids; do
  if kill -0 "$p" 2>/dev/null; then res=1; fi
done
check "M-end: all fake pids gone (kill -0 fails)" "$res" 0
if pgrep -f "dms-fake-r4[9]" >/dev/null 2>&1; then
  check "M-end: no dms-fake-r49 cmdline residue" 1 0
else
  check "M-end: no dms-fake-r49 cmdline residue" 0 0
fi

echo
echo "session lifecycle tests: $pass passed, $fail failed, $known known-upstream, $unavail unavailable"
[[ "$fail" -eq 0 ]]
