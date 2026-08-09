#!/usr/bin/env bash
# 00-utils.sh - shared helpers for the step scripts.
# Sourced by install.sh; expected to run as a normal user with sudo prompts.

set -Eeuo pipefail

# --- desktop value validator (fail closed, review 2026-08-08 / Codex R3) ---
# Legal values are ONLY niri|both|none. Pure hyprland was removed; unknown
# values must never fall back to "both". Pure predicate: returns 0/1, prints
# nothing (callers decide whether to die or reject a single module).
validate_desktop_env() { # validate_desktop_env <value> ; rc 0=legal 1=illegal
  case "${1:-}" in
    ""|niri|both|none) return 0 ;;
    *) return 1 ;;
  esac
}
# Source-time guard: abort BEFORE any side effect (covers env-var injection
# into install.sh and every directly-executable step script).
if [[ -n "${DESKTOP_ENV:-}" ]] && ! validate_desktop_env "${DESKTOP_ENV}"; then
  echo "error: invalid DESKTOP_ENV=${DESKTOP_ENV} (legal: niri|both|none; pure hyprland removed)" >&2
  exit 2
fi

# --- colors (plain text; disabled when not a tty) ---
if [[ -t 1 ]]; then
  H_RED=$'\e[31m'; H_GREEN=$'\e[32m'; H_YELLOW=$'\e[33m'
  H_CYAN=$'\e[36m'; BOLD=$'\e[1m'; DIM=$'\e[2m'; NC=$'\e[0m'
else
  H_RED=""; H_GREEN=""; H_YELLOW=""; H_CYAN=""; BOLD=""; DIM=""; NC=""
fi

# --- state ---
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly PROJECT_DIR

# --- progress state with install context (review H-02) ---
# The resume file binds machine/desktop/user/commit/manifest hashes so a
# stale progress file from a different install configuration can never
# resume-skip modules. Context mismatch => refuse to resume (the operator
# must clear .install_progress explicitly to start fresh).
PROGRESS_CONTEXT_FILE="${PROJECT_DIR}/.install_progress"

progress_context() {
  local commit="dirty"
  if command -v git >/dev/null 2>&1 && git -C "${PROJECT_DIR}" rev-parse HEAD >/dev/null 2>&1; then
    commit="$(git -C "${PROJECT_DIR}" rev-parse --short HEAD 2>/dev/null || echo dirty)"
    if [[ -n "$(git -C "${PROJECT_DIR}" diff --stat 2>/dev/null | tail -1)" ]]; then
      commit="${commit}+dirty"
    fi
  fi
  local ph="-" mh="-" rh="-"
  [[ -f "${PROJECT_DIR}/manifests/workstation-packages.tsv" ]] && ph="$(sha256sum "${PROJECT_DIR}/manifests/workstation-packages.tsv" | cut -c1-12)"
  [[ -f "${PROJECT_DIR}/manifests/config-mappings.tsv" ]] && mh="$(sha256sum "${PROJECT_DIR}/manifests/config-mappings.tsv" | cut -c1-12)"
  [[ -f "${PROJECT_DIR}/manifests/aur-recipes.tsv" ]] && rh="$(sha256sum "${PROJECT_DIR}/manifests/aur-recipes.tsv" | cut -c1-12)"
  # P1-2: bind the profile, installer scripts, shipped config tree, recipes
  # and the AUR source-cache manifest (when present) as well, so a change in
  # any of them invalidates the resume context instead of silently resuming
  # with a different payload.
  local sh="-" cfh="-" rch="-" cach="-"
  if compgen -G "${PROJECT_DIR}/scripts/*.sh" >/dev/null 2>&1; then
    sh="$(find "${PROJECT_DIR}/scripts" -maxdepth 1 -name '*.sh' -print0 2>/dev/null | sort -z | xargs -0 sha256sum 2>/dev/null | sha256sum | cut -c1-12)"
  fi
  if [[ -d "${PROJECT_DIR}/config" ]]; then
    cfh="$(find "${PROJECT_DIR}/config" -type f -print0 2>/dev/null | sort -z | xargs -0 sha256sum 2>/dev/null | sha256sum | cut -c1-12)"
  fi
  if compgen -G "${PROJECT_DIR}/third_party/aur/*/PKGBUILD" >/dev/null 2>&1; then
    rch="$(find "${PROJECT_DIR}/third_party/aur" -maxdepth 2 \( -name PKGBUILD -o -name .SRCINFO \) -print0 2>/dev/null | sort -z | xargs -0 sha256sum 2>/dev/null | sha256sum | cut -c1-12)"
  fi
  if [[ -f "${PROJECT_DIR}/.aur-sources/manifest.sha256" ]]; then
    cach="$(sha256sum "${PROJECT_DIR}/.aur-sources/manifest.sha256" | cut -c1-12)"
  fi
  printf 'desktop=%s machine=%s user=%s profile=%s commit=%s packages=%s mappings=%s recipes=%s scripts=%s config=%s aur=%s cache=%s' \
    "${DESKTOP_ENV:-none}" "${MACHINE_TYPE:-physical}" "${TARGET_USER:-}" "${TEST_PROFILE:-none}" \
    "${commit}" "${ph}" "${mh}" "${rh}" "${sh}" "${cfh}" "${rch}" "${cach}"
}

setup_progress() {
  # fail closed: never write a progress file for an invalid desktop value
  if ! validate_desktop_env "${DESKTOP_ENV:-}"; then
    error "invalid DESKTOP_ENV=${DESKTOP_ENV:-} (legal: niri|both|none)"
    exit 2
  fi
  local ctx
  ctx="$(progress_context)"
  if [[ -f "${PROGRESS_CONTEXT_FILE}" ]]; then
    local header
    header="$(head -1 "${PROGRESS_CONTEXT_FILE}")"
    if [[ "${header}" != "# context: ${ctx}" ]]; then
      error "Existing progress file does not match this install context:"
      error "  expected: # context: ${ctx}"
      error "  found:    ${header}"
      error "Refusing to resume; remove ${PROGRESS_CONTEXT_FILE} to start fresh."
      exit 1
    fi
    log "Progress file matches install context; resuming."
  else
    printf '# context: %s\n' "${ctx}" > "${PROGRESS_CONTEXT_FILE}"
  fi
}

mark_done() {
  local module="$1"
  echo "${module}" >> "${PROGRESS_CONTEXT_FILE}"
}

is_done() {
  local module="$1"
  grep -q "^${module}$" "${PROGRESS_CONTEXT_FILE}"
}

# --- target user resolution ---
# The installer may run as root (strap.sh path) or as the desktop user.
# Config deployment and user services must target the real desktop user's
# HOME, never /root. TARGET_USER/TARGET_HOME resolve that user.
if [[ "$(id -u)" -eq 0 ]]; then
  if [[ -n "${SUDO_USER:-}" ]]; then
    TARGET_USER="${SUDO_USER}"
  else
    # first real (uid>=1000) login user
    TARGET_USER="$(awk -F: '$3>=1000 && $7!~/nologin|false/{print $1; exit}' /etc/passwd)"
  fi
  [[ -n "${TARGET_USER:-}" ]] || TARGET_USER="root"
  TARGET_HOME="$(getent passwd "${TARGET_USER}" | cut -d: -f6)"
else
  TARGET_USER="${USER:-$(id -un)}"
  TARGET_HOME="${HOME}"
fi
readonly TARGET_USER TARGET_HOME

log()    { echo -e "  ${DIM}->${NC} $*"; }
section(){ echo; echo -e "${H_CYAN}===[ $* ]${NC}"; }
success(){ echo -e "  ${H_GREEN}✔${NC} $*"; }
warn()   { echo -e "  ${H_YELLOW}!${NC} $*"; }
error()  { echo -e "  ${H_RED}✘${NC} $*" >&2; }

die() { error "$*"; exit 1; }

check_root() {
  # We run as a normal user; all privileged steps go through sudo -A-style
  # prompts. This is a no-op here but kept for symmetry with the entry point.
  true
}

# run a command with sudo, prompting for password when needed
run() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

ensure_fzf() {
  # Step 2 (D-05): fzf must NEVER trigger a pacman sync before the mirror
  # config exists. If fzf is missing we just report it; the interactive
  # selectors (install.sh) fall back to a plain read-prompt. No network, no
  # pacman here.
  if ! command -v fzf >/dev/null 2>&1; then
    warn "fzf not available; interactive selection will use plain prompts (install it later if you want the menu)"
    return 1
  fi
  return 0
}

# --- pacman sync/upgrade ownership (download-mode-lab D-03, step 2) ---
# 02-system.sh is the ONLY owner of the official-repo sync+upgrade. These
# helpers make the call sequence explicit and testable: sync_official runs
# -Syu by default; FORCE_REFRESH=1 switches to -Syyu as an explicit repair
# mode (never the default). sync_archlinuxcn runs exactly one -Sy AFTER
# [archlinuxcn] is configured (03-packages).
sync_official() {
  if [[ "${FORCE_REFRESH:-0}" == "1" ]]; then
    log "FORCE_REFRESH=1: pacman -Syyu (full database refresh, repair mode)"
    run pacman -Syyu --noconfirm
  else
    run pacman -Syu --noconfirm
  fi
}

sync_archlinuxcn() {
  # exactly one database sync, only called after [archlinuxcn] is written
  run pacman -Sy --noconfirm
}

# --- stale Round-2/Round-3 Hyprland session artifacts (Codex R4/R4.1) ---
# The Round-4 design (uwsm-managed Hyprland, 2026-08-09) ships NO custom
# systemd units or launcher for Hyprland; the hyprland package's SYSTEM
# session entry /usr/share/wayland-sessions/hyprland-uwsm.desktop drives the
# lifecycle via `uwsm start -e -D Hyprland hyprland.desktop`. Earlier rounds
# deployed custom files into the target HOME; deleting them from the repo
# does not remove them from an existing install.
#
# stale_hypr_cleanup backs up and removes ONLY files whose content exactly
# matches what this project deployed (sha256, recorded 2026-08-09 from the
# Round-3 working tree and git HEAD):
#   - every path component from TARGET_HOME down to the file is lstat-checked;
#     a symlink ANYWHERE in the path (e.g. ~/.config -> elsewhere) means the
#     file is NOT project-managed here and is never read/backed up/deleted
#     (Codex R4.1 path-traversal fix);
#   - only regular files are handled; directories/FIFOs/sockets/devices/
#     dangling symlinks are kept and reported;
#   - backup happens first (unique mktemp dir), never overwriting; a failed
#     or unsafe backup aborts the removal;
#   - on the root/strap path the backup is chowned to TARGET_USER.
# The Round-2 watcher set (hyprland-session.service/watch/start, the niri
# service.d ExecStop drop-in) was NEVER committed, so its exact content is
# unknown: it is detected and WARNED about, never guess-deleted (R4.1).
# --- backup ownership (Codex R4.2 item 6) ---
# On the root/strap path the backup must be owned by TARGET_USER's real
# uid/gid; any ownership failure must prevent deletion of the original.
stale_backup_own() { # stale_backup_own <path> ; 0=ok 1=ownership failed
  local p="$1"
  if [[ "$(id -u)" -ne 0 ]]; then return 0; fi
  local tuid tgid
  tuid="$(id -u "${TARGET_USER}" 2>/dev/null || true)"
  tgid="$(id -g "${TARGET_USER}" 2>/dev/null || true)"
  [[ -n "${tuid}" && -n "${tgid}" ]] || return 1
  chown "${tuid}:${tgid}" "${p}" 2>/dev/null || return 1
  return 0
}
# narrow RECURSIVE ownership fix of the unique backup root (intermediate
# directories created by mkdir -p would otherwise stay root-owned on the
# root/strap path); never operates outside the backup root (R4.3 item 4).
stale_backup_own_tree() { # stale_backup_own_tree <backup_root> ; 0=ok 1=failed
  local root="$1"
  if [[ "$(id -u)" -ne 0 ]]; then return 0; fi
  local tuid tgid
  tuid="$(id -u "${TARGET_USER}" 2>/dev/null || true)"
  tgid="$(id -g "${TARGET_USER}" 2>/dev/null || true)"
  [[ -n "${tuid}" && -n "${tgid}" ]] || return 1
  chown -R "${tuid}:${tgid}" "${root}" 2>/dev/null || return 1
  return 0
}

stale_hypr_cleanup() {
  # exact-content project artifacts (relpath|sha256)
  local -a exact=(
    ".config/systemd/user/hyprland-session.target|3cb35ba962ada9f0298ff627b225f29b44c2e9e2757cacdbdfa21c0e55be609f"
    ".config/systemd/user/hyprland.service|ff6da6b7d78e0b5e4a475f58564869686486b79e6d37d25a03665c97bdb35dee"
    ".config/systemd/user/hyprland-shutdown.target|0179017381c0f7776eaf8864b0a9e7837c5670bc4647dbb22542dc97e6748d04"
    ".local/bin/hyprland-session|1458b11f7dd66de2003b3c2420bbb9e4468e0b86a9b2a631ebf15d9f609df292"
    ".local/share/wayland-sessions/hyprland.desktop|87e64bd4778592375bd321e3930dcdf036f86d9f65661aeffa5fd5c6ce04e502"
  )
  # Round-2 watcher set: detect + warn only
  local -a r2_watch=(
    ".config/systemd/user/hyprland-session.service"
    ".local/bin/hyprland-session-watch"
    ".local/bin/hyprland-session-start"
    ".config/systemd/user/niri.service.d/session-cleanup.conf"
  )

  local backup_root="" removed=0 kept=0 warned=0
  local entry path want file ondisk
  for entry in "${exact[@]}"; do
    path="${entry%%|*}"; want="${entry##*|}"
    file="${TARGET_HOME}/${path}"
    # lstat existence: a dangling symlink IS "present" and gets its own
    # dedicated keep+report (R4.2 item 2), never silently skipped
    if [[ -L "${file}" ]]; then
      warn "stale cleanup: keeping ${path} (dangling or left symlink; not project-managed)"
      kept=$((kept + 1)); continue
    fi
    [[ -e "${file}" ]] || continue
    if ! stale_regular_file "${path}"; then
      warn "stale cleanup: keeping ${path} (path contains a symlink or is not a regular file)"
      kept=$((kept + 1)); continue
    fi
    ondisk="$(sha256sum "${file}" | cut -d' ' -f1)"
    if [[ "${ondisk}" != "${want}" ]]; then
      warn "stale cleanup: keeping ${path} (content differs from project-deployed file)"
      kept=$((kept + 1)); continue
    fi
    # backup first; no safe backup -> no deletion (R4.1 "verify before delete")
    if [[ -z "${backup_root}" ]]; then
      if ! path_no_symlink_components ".config/systemd/user"; then
        warn "stale cleanup: backup parent unsafe (symlink in ~/.config/systemd/user); NOT removing project artifacts"
        return 1
      fi
      mkdir -p "${TARGET_HOME}/.config/systemd/user"
      if ! backup_root="$(mktemp -d "${TARGET_HOME}/.config/systemd/user/.my-arch-stale-backup-XXXXXX")"; then
        warn "stale cleanup: could not create backup dir; NOT removing project artifacts"
        return 1
      fi
      if ! stale_backup_own "${backup_root}"; then
        warn "stale cleanup: could not set backup dir ownership; NOT removing project artifacts"
        return 1
      fi
    fi
    if ! mkdir -p "$(dirname "${backup_root}/${path}")" 2>/dev/null \
       || ! cp -a "${file}" "${backup_root}/${path}" 2>/dev/null; then
      warn "stale cleanup: could not back up ${path}; NOT removing original"
      kept=$((kept + 1)); continue
    fi
    if ! stale_backup_own "${backup_root}/${path}"; then
      warn "stale cleanup: could not set backup ownership for ${path}; NOT removing original"
      kept=$((kept + 1)); continue
    fi
    # recursive fix of intermediate dirs within the unique backup root;
    # any ownership failure keeps the original (R4.3 item 4)
    if ! stale_backup_own_tree "${backup_root}"; then
      warn "stale cleanup: could not fix recursive backup ownership; NOT removing ${path}"
      kept=$((kept + 1)); continue
    fi
    rm -f "${file}"
    log "stale cleanup: removed project artifact ${path} (backed up)"
    removed=$((removed + 1))
  done
  for path in "${r2_watch[@]}"; do
    if [[ -e "${TARGET_HOME}/${path}" || -L "${TARGET_HOME}/${path}" ]]; then
      warn "stale cleanup: Round-2 artifact present at ${TARGET_HOME}/${path}; its exact content was never committed, so it is NOT auto-removed - review and remove it manually"
      warned=$((warned + 1))
    fi
  done
  if (( removed > 0 || kept > 0 || warned > 0 )); then
    log "stale cleanup: ${removed} removed, ${kept} kept, ${warned} Round-2 warnings (backup: ${backup_root:-none})"
  fi
}

# --- path safety (Codex R4.1) ---
# lstat every component of a TARGET_HOME-relative path; a symlink anywhere
# makes the path unsafe (writing through ~/.config -> elsewhere would
# modify files outside TARGET_HOME). Also rejects absolute paths and "..".
path_no_symlink_components() { # path_no_symlink_components <relpath> ; 0=safe
  local rel="$1"
  [[ "${rel}" == /* || "${rel}" == *".."* ]] && return 1
  local cur="${TARGET_HOME}"
  [[ -L "${cur}" ]] && return 1
  local -a comps
  IFS='/' read -r -a comps <<< "${rel}"
  local last="${comps[${#comps[@]}-1]}"
  local n comp
  for (( n=0; n < ${#comps[@]}-1; n++ )); do
    comp="${comps[$n]}"
    cur="${cur}/${comp}"
    [[ -L "${cur}" ]] && return 1
    [[ -d "${cur}" ]] || return 1
  done
  cur="${cur}/${last}"
  [[ -L "${cur}" ]] && return 1
  return 0
}
stale_regular_file() { # stale_regular_file <rel> ; 0=safe regular file
  path_no_symlink_components "$1" || return 1
  [[ -f "${TARGET_HOME}/$1" ]] || return 1
  return 0
}

# --- UWSM secondary resolution (Codex R4.2/R4.3/R4.4) ---
# `uwsm start -e -D Hyprland hyprland.desktop` re-resolves hyprland.desktop
# in the target session's XDG_DATA_HOME then XDG_DATA_DIRS, in order. The
# target-session values are explicit (TARGET_XDG_DATA_HOME /
# TARGET_XDG_DATA_DIRS, defaulting to the XDG spec defaults) and are NOT the
# installer process's own XDG_* environment. The FIRST candidate that exists
# (lstat) is CLASSIFIED: dangling/FIFO/dir/unreadable/wrong-section/
# empty-Exec/missing-Exec-program all fail closed (rc 2), never skipped to a
# lower-priority candidate. rc: 0=usable entry echoed, 1=no candidate,
# 2=first existing candidate unusable (path echoed), 3=python/validator
# unavailable or interpreter/infra failure (42/126/127/... are NEVER folded
# into rc=2 - they mean the validator could not run, not that the entry is
# corrupt; R4.4).
TARGET_XDG_DATA_HOME="${TARGET_XDG_DATA_HOME:-${TARGET_HOME}/.local/share}"
TARGET_XDG_DATA_DIRS="${TARGET_XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
PYTHON_BIN="${PYTHON_BIN:-python3}"

# structured desktop-entry validation (Python stdlib): regular file with a
# [Desktop Entry] section, non-empty Name and Exec (other sections do not
# count), Exec first program resolvable/existing. Exit 0=valid 2=invalid
# 3=validator infrastructure failure.
desktop_entry_ok() { # desktop_entry_ok <file> ; 0=valid 2=invalid 3=infra
  local rc=0
  "${PYTHON_BIN}" - "$1" <<'PYEOF' 2>/dev/null || rc=$?
import os, shlex, shutil, stat, sys
path = sys.argv[1]
try:
    lst = os.lstat(path)
except OSError:
    sys.exit(2)
if stat.S_ISLNK(lst.st_mode):
    sys.exit(2)
if not stat.S_ISREG(lst.st_mode):
    sys.exit(2)
try:
    with open(path, 'r', encoding='utf-8', errors='strict') as fh:
        text = fh.read()
except (OSError, UnicodeError):
    sys.exit(2)
name = None
exec_ = None
section = None
for line in text.splitlines():
    line = line.strip()
    if line.startswith('[') and line.endswith(']'):
        section = line[1:-1]
        continue
    if section != 'Desktop Entry' or '=' not in line:
        continue
    k, _, v = line.partition('=')
    k = k.strip(); v = v.strip()
    if k == 'Name' and name is None:
        name = v
    elif k == 'Exec' and exec_ is None:
        exec_ = v
if not name or not exec_:
    sys.exit(2)
try:
    argv = shlex.split(exec_)
except ValueError:
    sys.exit(2)
if not argv:
    sys.exit(2)
prog = argv[0]
if '/' in prog:
    if not (os.path.isfile(prog) and os.access(prog, os.X_OK)):
        sys.exit(2)
else:
    if shutil.which(prog) is None:
        sys.exit(2)
sys.exit(0)
PYEOF
  case "$rc" in
    0) return 0 ;;
    2) return 2 ;;
    *) return 3 ;;   # 42/126/127/other = interpreter/validator failure
  esac
}

resolve_hyprland_desktop() {
  if ! command -v "${PYTHON_BIN}" >/dev/null 2>&1; then
    echo "python/validator unavailable (${PYTHON_BIN} not found)"
    return 3
  fi
  local -a candidates=("${TARGET_XDG_DATA_HOME}/wayland-sessions/hyprland.desktop")
  local -a dirs=()
  IFS=':' read -r -a dirs <<< "${TARGET_XDG_DATA_DIRS}"
  local d
  for d in "${dirs[@]}"; do
    [[ -n "${d}" ]] && candidates+=("${d}/wayland-sessions/hyprland.desktop")
  done
  local c vrc
  for c in "${candidates[@]}"; do
    if [[ -e "${c}" || -L "${c}" ]]; then
      vrc=0
      desktop_entry_ok "${c}" || vrc=$?
      if [[ "${vrc}" -eq 2 ]]; then
        echo "${c}"
        return 2
      fi
      if [[ "${vrc}" -ne 0 ]]; then
        echo "python/validator unavailable while validating ${c}"
        return 3
      fi
      echo "${c}"
      return 0
    fi
  done
  return 1
}
# --- dms-greeter session memory migration (Codex R4.2..R4.6) ---
# dms-greeter's remembered session lives ONLY in
# <GREETER_CACHE_DIR>/.local/state/memory.json (fields lastSessionId /
# lastSessionDesktopId / lastSuccessfulUser). DMS theme/session files
# (~/.local/state/DankMaterialShell/session.json, <cache>/session.json,
# <cache>/users/*/session.json) are NEVER scanned or modified. R4.4: anchored
# with dir_fd + O_NOFOLLOW (no TOCTOU path re-resolution). R4.5:
# transactional with explicit states; a VERIFIED backup is never deleted;
# fd-based metadata ops. R4.6: the original memory identity is re-confirmed
# immediately before the commit (and the parent before AND after the commit);
# post-replace failures are unified: identity-confirmed -> auto-restore
# (rc 5/6), identity-unknown -> never modify/restore (rc 7); the verified
# backup keeps an open fd + recorded dev/inode and is re-identified before
# any report; all user-visible backup paths are absolute.
migrate_greeter_memory() {
  local cache="${GREETER_CACHE_DIR:-/var/cache/dms-greeter}"
  local mem_force="${GREETER_MEMORY_FORCE_FAILCLOSED:-0}"
  if ! command -v "${PYTHON_BIN}" >/dev/null 2>&1; then
    warn "python missing; greeter memory migration unavailable (${cache}/.local/state/memory.json)"
    return 1
  fi
  local rc=0
  "${PYTHON_BIN}" - "${cache}" "${mem_force}" <<'PYEOF' || rc=$?
import json, os, random, stat, string, sys, time

def fail(reason):
    print("greeter memory fail-closed: %s (%s)" % (sys.argv[1], reason), file=sys.stderr)
    sys.exit(3)

def read_all(fd):
    chunks = []
    while True:
        b = os.read(fd, 65536)
        if not b:
            break
        chunks.append(b)
    return b"".join(chunks)

def hook(name):
    if os.environ.get("MY_ARCH_TEST_MODE", "") != "1":
        return False
    return os.environ.get(name, "") == "1"

def main():
    cache = sys.argv[1]
    force = sys.argv[2] == "1"
    WS_TMP = "/download-mode-lab/fixtures/tmp/"

    # --- 1) cache path absolute + normal ---
    if not cache.startswith("/"):
        fail("GREETER_CACHE_DIR must be absolute")
    parts = [c for c in cache.split("/") if c != ""]
    if not parts:
        fail("GREETER_CACHE_DIR must not be /")
    for c in parts:
        if c in (".", "..") or c == "":
            fail("non-normal path component: %r" % c)
    parts = parts + [".local", "state", "memory.json"]
    full = "/" + "/".join(parts)
    parent_path = "/" + "/".join(parts[:-1])

    txn = "none"
    tmp_fd = None
    tmp_name = None
    bak_fd = None
    bak_name = None
    st_bak = None
    st_tmp = None
    st0_dev = None
    st0_ino = None
    mode = None
    uid = None
    gid = None

    def bak_abs():
        return parent_path + "/" + (bak_name if bak_name is not None else "")

    def restore_failed(stage):
        print("greeter memory: AUTO-RESTORE FAILED at %s; the original memory is NOT restored and its current state cannot be treated as restored; verified backup preserved at %s; recover manually from that backup: %s" % (stage, bak_abs(), full), file=sys.stderr)
        sys.exit(6)

    def postreplace_unknown(reason):
        print("greeter memory: after the replace the final object could not be confirmed as the committed file (%s); the current object was NOT modified; auto-restore NOT executed; verified backup preserved at %s; verify manually: %s" % (reason, bak_abs(), full), file=sys.stderr)
        sys.exit(7)

    def memory_changed_after_read():
        print("greeter memory: memory changed after it was read; migration not committed; verified backup preserved at %s; the newer file at %s was left untouched" % (bak_abs(), full), file=sys.stderr)
        sys.exit(8)

    def parent_changed_before_commit():
        print("greeter memory: parent path changed after the memory was read; migration NOT committed; verified backup preserved at %s: %s" % (bak_abs(), full), file=sys.stderr)
        sys.exit(9)

    def excl_open(parent_fd, prefix):
        for _ in range(100):
            name = prefix + "".join(random.choices(string.ascii_letters + string.digits, k=8))
            try:
                return os.open(name, os.O_RDWR | os.O_CREAT | os.O_EXCL, 0o600, dir_fd=parent_fd), name
            except FileExistsError:
                continue
        fail("cannot allocate unique name under %s" % parent_path)

    def ensure_backup_identity(cname, cst):
        # the NAME must still resolve to the verified inode; otherwise a
        # fresh verified backup is created from the originally-read raw
        vb = None
        try:
            vb = os.open(cname, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent_fd)
        except OSError:
            vb = None
        if vb is not None:
            vst = os.fstat(vb)
            os.close(vb)
            if (vst.st_dev, vst.st_ino) == (cst.st_dev, cst.st_ino):
                return cname, cst
        nfd, nname = excl_open(parent_fd, ".memory-backup-")
        os.write(nfd, raw.encode("utf-8"))
        os.fsync(nfd)
        os.fchmod(nfd, mode)
        try:
            os.fchown(nfd, uid, gid)
        except OSError as e:
            os.close(nfd)
            fail("fresh backup ownership cannot be preserved (%s)" % e)
        nst = os.fstat(nfd)
        os.lseek(nfd, 0, os.SEEK_SET)
        if read_all(nfd).decode("utf-8") != raw or (stat.S_IMODE(nst.st_mode), nst.st_uid, nst.st_gid) != (mode, uid, gid):
            os.close(nfd)
            fail("fresh backup verification failed")
        os.close(nfd)
        return nname, nst

    def do_rollback(reason):
        nonlocal txn
        # category A: the final object IS the committed tmp -> auto-restore
        if hook("GREETER_MEMORY_TEST_RESTORE_CREATE_FAIL"):
            restore_failed("restore temp creation (simulated)")
        rfd, rname = excl_open(parent_fd, ".memory-restore-")
        try:
            os.write(rfd, raw.encode("utf-8"))
            os.fsync(rfd)
            st_rest = os.fstat(rfd)
            os.fchmod(rfd, mode)
            if hook("GREETER_MEMORY_TEST_RESTORE_OWN_FAIL"):
                restore_failed("restore ownership (simulated)")
            try:
                os.fchown(rfd, uid, gid)
            except OSError as e:
                restore_failed("restore ownership (%s)" % e)
            os.lseek(rfd, 0, os.SEEK_SET)
            if read_all(rfd).decode("utf-8") != raw:
                restore_failed("restore content verification")
            if hook("GREETER_MEMORY_TEST_RESTORE_REPLACE_FAIL"):
                restore_failed("restore replace (simulated)")
            os.replace(rname, parts[-1], src_dir_fd=parent_fd, dst_dir_fd=parent_fd)
            rname = None
            os.close(rfd); rfd = None
            rf = os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent_fd)
            rst = os.fstat(rf)
            if (rst.st_dev, rst.st_ino) != (st_rest.st_dev, st_rest.st_ino):
                os.close(rf)
                restore_failed("restore identity verification")
            rb = read_all(rf).decode("utf-8")
            os.close(rf)
            if rb != raw or (stat.S_IMODE(rst.st_mode), rst.st_uid, rst.st_gid) != (mode, uid, gid):
                restore_failed("restore verification")
            if hook("GREETER_MEMORY_TEST_RESTORE_VERIFY_FAIL"):
                restore_failed("restore verification (simulated)")
            txn = "rollback_succeeded"
            print("greeter memory: %s; rolled back successfully from the verified backup at %s: %s" % (reason, bak_abs(), full), file=sys.stderr)
            sys.exit(5)
        finally:
            if rfd is not None:
                try:
                    os.close(rfd)
                except OSError:
                    pass
            if rname is not None:
                try:
                    os.unlink(rname, dir_fd=parent_fd)
                except OSError:
                    pass

    # --- 2) anchored walk from "/" ---
    def open_child(parent_fd, name, flags):
        try:
            return os.open(name, flags, dir_fd=parent_fd)
        except FileNotFoundError:
            return None
        except OSError as e:
            fail("cannot open %s: %s" % (name, e))

    fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
    parent_fd = None
    try:
        for name in parts[:-1]:
            nfd = open_child(fd, name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
            if nfd is None:
                sys.exit(0)
            os.close(fd)
            fd = nfd
        parent_fd = fd
        parent_devino = (os.fstat(parent_fd).st_dev, os.fstat(parent_fd).st_ino)

        # walk-time failpoint handshake (test-only) + parent identity check
        fp = ""
        if os.environ.get("MY_ARCH_TEST_MODE", "") == "1":
            cand = os.environ.get("GREETER_MEMORY_TEST_FAILPOINT", "")
            if cand:
                if WS_TMP not in cand:
                    fail("failpoint path outside workspace fixtures/tmp")
                fp = cand
        if fp:
            with open(fp + ".ready", "w") as fh:
                fh.write("ready\n")
            deadline = time.time() + 20
            while not os.path.exists(fp + ".go"):
                if time.time() > deadline:
                    fail("failpoint go timeout")
                time.sleep(0.05)
        try:
            st_path = os.lstat(parent_path)
        except OSError:
            fail("parent path cannot be lstat'd during migration")
        if (st_path.st_dev, st_path.st_ino) != parent_devino:
            fail("parent path changed during migration (race detected)")

        # --- 3) final memory: lstat-classify, open, BIND fd to lstat ---
        try:
            lst = os.lstat(parts[-1], dir_fd=parent_fd)
        except FileNotFoundError:
            sys.exit(0)
        except OSError as e:
            fail("cannot lstat %s: %s" % (parts[-1], e))
        if stat.S_ISLNK(lst.st_mode):
            fail("final component is a symlink")
        if not stat.S_ISREG(lst.st_mode):
            fail("final component is not a regular file")
        if hook("GREETER_MEMORY_TEST_FINAL_SWAP"):
            sfd, sname = excl_open(parent_fd, ".final-swap-")
            os.write(sfd, b"SENTINEL-SWAP\n")
            os.close(sfd)
            os.replace(sname, parts[-1], src_dir_fd=parent_fd, dst_dir_fd=parent_fd)
        mfd = os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent_fd)
        st = os.fstat(mfd)
        if (st.st_dev, st.st_ino) != (lst.st_dev, lst.st_ino):
            os.close(mfd)
            fail("final file identity changed between lstat and open")
        if not stat.S_ISREG(st.st_mode):
            os.close(mfd)
            fail("final is not a regular file")
        raw = read_all(mfd).decode("utf-8")
        os.close(mfd)
        # save the initially-read identity + metadata (R4.6 一)
        st0_dev = st.st_dev
        st0_ino = st.st_ino
        mode = stat.S_IMODE(st.st_mode)
        uid, gid = st.st_uid, st.st_gid

        # --- 4) structured parse ---
        try:
            data = json.loads(raw)
        except ValueError as e:
            fail("invalid JSON: %s" % e)
        if not isinstance(data, dict):
            fail("not a JSON object")

        # --- 5) exact-case changes (only the two session-selection fields) ---
        def migrate_desktop_id(v):
            return "hyprland-uwsm.desktop" if v == "hyprland.desktop" else v

        def migrate_session_id(v):
            if v == "hyprland.desktop":
                return "hyprland-uwsm.desktop"
            base = os.path.basename(v)
            if base == "hyprland.desktop" and "wayland-sessions" in v.split("/"):
                return os.path.join(os.path.dirname(v), "hyprland-uwsm.desktop")
            return v

        changed = False
        if isinstance(data.get("lastSessionDesktopId"), str):
            nv = migrate_desktop_id(data["lastSessionDesktopId"])
            if nv != data["lastSessionDesktopId"]:
                data["lastSessionDesktopId"] = nv
                changed = True
        if isinstance(data.get("lastSessionId"), str):
            nv = migrate_session_id(data["lastSessionId"])
            if nv != data["lastSessionId"]:
                data["lastSessionId"] = nv
                changed = True
        if not changed:
            sys.exit(0)
        if force:
            print("greeter memory references old hyprland.desktop but conservative mode is set; NOT modifying: %s" % full, file=sys.stderr)
            sys.exit(4)
        new_content = json.dumps(data, ensure_ascii=False, indent=2) + "\n"

        # --- 6) backup (fd kept open to the end; verified dev/ino recorded) ---
        bak_fd, bak_name = excl_open(parent_fd, ".memory-backup-")
        txn = "backup_created"
        os.write(bak_fd, raw.encode("utf-8"))
        os.fsync(bak_fd)
        os.fchmod(bak_fd, mode)
        try:
            os.fchown(bak_fd, uid, gid)
        except OSError as e:
            os.close(bak_fd); bak_fd = None
            fail("backup ownership cannot be preserved (%s)" % e)
        st_bak = os.fstat(bak_fd)
        if hook("GREETER_MEMORY_TEST_BACKUP_FAIL"):
            with os.fdopen(os.open(bak_name, os.O_WRONLY | os.O_TRUNC, dir_fd=parent_fd), "w", encoding="utf-8") as fh:
                fh.write(raw[: max(1, len(raw) // 2)])
        os.lseek(bak_fd, 0, os.SEEK_SET)
        bak_bytes = read_all(bak_fd)
        if bak_bytes.decode("utf-8") != raw or (stat.S_IMODE(st_bak.st_mode), st_bak.st_uid, st_bak.st_gid) != (mode, uid, gid):
            fail("backup verification failed (bytes or metadata)")
        txn = "backup_verified"
        if hook("GREETER_MEMORY_TEST_BACKUP_OWN_FAIL"):
            fail("backup ownership verification failed (simulated)")
        if hook("GREETER_MEMORY_TEST_BACKUP_SWAP"):
            os.rename(bak_name, bak_name + "-swapped", src_dir_fd=parent_fd, dst_dir_fd=parent_fd)

        # --- 7) tmp (fd kept; verify) ---
        tmp_fd, tmp_name = excl_open(parent_fd, ".memory-migrate-")
        os.write(tmp_fd, new_content.encode("utf-8"))
        os.fsync(tmp_fd)
        st_tmp = os.fstat(tmp_fd)
        os.fchmod(tmp_fd, mode)
        try:
            os.fchown(tmp_fd, uid, gid)
        except OSError as e:
            fail("temp ownership cannot be preserved (%s)" % e)
        os.lseek(tmp_fd, 0, os.SEEK_SET)
        if read_all(tmp_fd).decode("utf-8") != new_content:
            fail("tmp content verification failed")
        vtmp = os.open(tmp_name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent_fd)
        vtmp_st = os.fstat(vtmp)
        os.close(vtmp)
        if (vtmp_st.st_dev, vtmp_st.st_ino) != (st_tmp.st_dev, st_tmp.st_ino):
            fail("tmp identity changed before replace")

        # --- 8) pre-commit: backup identity, parent identity, memory identity ---
        bak_name, st_bak = ensure_backup_identity(bak_name, st_bak)
        fp2 = ""
        if os.environ.get("MY_ARCH_TEST_MODE", "") == "1":
            cand2 = os.environ.get("GREETER_MEMORY_TEST_PARENT_FAILPOINT", "")
            if cand2:
                if WS_TMP not in cand2:
                    fail("parent failpoint path outside workspace fixtures/tmp")
                fp2 = cand2
        if fp2:
            with open(fp2 + ".ready", "w") as fh:
                fh.write("ready\n")
            deadline = time.time() + 20
            while not os.path.exists(fp2 + ".go"):
                if time.time() > deadline:
                    fail("parent failpoint go timeout")
                time.sleep(0.05)
        try:
            st_path = os.lstat(parent_path)
        except OSError:
            parent_changed_before_commit()
        if (st_path.st_dev, st_path.st_ino) != parent_devino:
            parent_changed_before_commit()
        if hook("GREETER_MEMORY_TEST_PRECOMMIT_SWAP"):
            pfd, pname = excl_open(parent_fd, ".precommit-")
            os.write(pfd, b"SENTINEL-PRECOMMIT\n")
            os.close(pfd)
            os.replace(pname, parts[-1], src_dir_fd=parent_fd, dst_dir_fd=parent_fd)
        # the final name must STILL be the initially-read object
        try:
            pf = os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent_fd)
        except OSError:
            memory_changed_after_read()
        pst = os.fstat(pf)
        os.close(pf)
        if (pst.st_dev, pst.st_ino) != (st0_dev, st0_ino):
            memory_changed_after_read()

        # --- 9) commit (anchored, atomic) ---
        txn = "replace_started"
        os.replace(tmp_name, parts[-1], src_dir_fd=parent_fd, dst_dir_fd=parent_fd)
        tmp_name = None
        os.close(tmp_fd); tmp_fd = None

        # --- 10) unified post-replace handling (R4.6 二/三) ---
        if hook("GREETER_MEMORY_TEST_POSTSTAT_FAIL"):
            os.chmod(parts[-1], (mode | 0o020) & 0o7777, dir_fd=parent_fd)
        if hook("GREETER_MEMORY_TEST_POSTSWAP"):
            sfd2, sname2 = excl_open(parent_fd, ".postswap-")
            os.write(sfd2, b"SENTINEL-POSTSWAP\n")
            os.close(sfd2)
            os.replace(sname2, parts[-1], src_dir_fd=parent_fd, dst_dir_fd=parent_fd)
        if hook("GREETER_MEMORY_TEST_FINAL_OPEN_FAIL"):
            os.chmod(parts[-1], 0o000, dir_fd=parent_fd)
        try:
            nfd = os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent_fd)
        except OSError as e:
            postreplace_unknown("final open failed: %s" % e)
        try:
            nst = os.fstat(nfd)
        except OSError as e:
            os.close(nfd)
            postreplace_unknown("final fstat failed: %s" % e)
        if (nst.st_dev, nst.st_ino) != (st_tmp.st_dev, st_tmp.st_ino):
            os.close(nfd)
            postreplace_unknown("final identity differs from the committed tmp")
        try:
            new_bytes = read_all(nfd).decode("utf-8")
        except (OSError, UnicodeError) as e:
            os.close(nfd)
            postreplace_unknown("final read/decode failed: %s" % e)
        os.close(nfd)
        if new_bytes != new_content or (stat.S_IMODE(nst.st_mode), nst.st_uid, nst.st_gid) != (mode, uid, gid):
            do_rollback("post-replace verification failed")
        # post-commit parent check: before reporting success
        try:
            st_path = os.lstat(parent_path)
        except OSError:
            postreplace_unknown("parent path cannot be lstat'd after commit")
        if (st_path.st_dev, st_path.st_ino) != parent_devino:
            do_rollback("parent path changed after commit")
        print("greeter memory migrated: %s (hyprland.desktop -> hyprland-uwsm.desktop)" % full, file=sys.stderr)
        sys.exit(0)
    finally:
        for f in (tmp_fd, bak_fd):
            if f is not None:
                try:
                    os.close(f)
                except OSError:
                    pass
        if tmp_name is not None:
            try:
                os.unlink(tmp_name, dir_fd=parent_fd)
            except OSError:
                pass
        if bak_name is not None and txn == "backup_created":
            try:
                os.unlink(bak_name, dir_fd=parent_fd)
            except OSError:
                pass
        try:
            os.close(fd)
        except OSError:
            pass

main()
PYEOF
  if (( rc != 0 )); then
    warn "greeter memory migration failed for ${cache}/.local/state/memory.json (rc=${rc}; see messages above)"
  fi
  return "${rc}"
}

# --- module selection (shared by 03-packages.sh and 07-config.sh) ---
# One selection function drives BOTH package install and config deployment so
# a desktop/machine role can never be half-installed (review H-07).
#
# Machine-role modules follow MACHINE_TYPE (vmware-host on physical,
# vmware-guest on vm); hardware modules (graphics-*/hardware-tools/
# asus-hardware) are installed ONLY by the dedicated 04-drivers step
# (physical) and therefore excluded from the general package/config path on
# both machine types; desktop modules follow DESKTOP_ENV
# (niri|both|none; pure hyprland was removed 2026-08-08 - Hyprland only runs
# via "both", selectable from the greetd session menu. install.sh validates
# the value fail-closed before this is ever called; "both" stays the fallback
# for any other value only because this function cannot die itself).
module_selected() {
  local pkg="$1" module="$2" ctx="${3:-package}"
  # fail closed: an INVALID desktop value selects NOTHING - not just the wm
  # modules, but also desktop-shared and machine-role modules (Codex R3).
  if ! validate_desktop_env "${DESKTOP_ENV:-both}"; then
    return 1
  fi
  case "${module}" in
    virtualization-vmware-host)
      [[ "${MACHINE_TYPE}" == "physical" ]] || return 1 ;;
    virtualization-vmware-guest)
      [[ "${MACHINE_TYPE}" == "vm" ]] || return 1 ;;
    graphics-amd|graphics-nvidia|hardware-tools|asus-hardware)
      # P1-1: package rows for hardware modules are 04-drivers' job and are
      # excluded from the general package path on BOTH machine types. Config
      # rows (ctx=config) are different: hardware configs (e.g.
      # rog-control-center.cfg) must deploy on physical, only skip on vm.
      if [[ "${ctx}" == "package" ]]; then
        return 1
      fi
      [[ "${MACHINE_TYPE}" == "physical" ]] || return 1
      ;;
  esac
  # only an EXPLICIT "both" selects both WMs (niri/none exclude the other)
  case "${DESKTOP_ENV:-both}" in
    niri) [[ "${module}" == "wm-hyprland" ]] && return 1 ;;
    none) [[ "${module}" == "wm-niri" || "${module}" == "wm-hyprland" ]] && return 1 ;;
  esac
  return 0
}

# --- diagnostics panel (plain text) ---
sys_dashboard() {
  section "System"
  echo "  Kernel   : $(uname -r)"
  echo "  User     : $(whoami)"
  echo "  Desktop  : ${DESKTOP_ENV:-none}"
  echo "  Machine  : ${MACHINE_TYPE:-physical}"
  echo "  Modules  : ${#MODULES[@]} step(s) selected"
}
