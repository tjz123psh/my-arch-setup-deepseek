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
    log "fzf is not installed yet; using built-in numbered prompts (expected on a fresh base; package operations start after mirror setup)"
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
# R5 (2026-08-09, aligned with the physical machine): Hyprland uses the
# hyprland package's STOCK system session entry
# /usr/share/wayland-sessions/hyprland.desktop (Exec=/usr/bin/start-hyprland).
# The Round-2/3 custom systemd units + launcher and the Round-4 uwsm-managed
# entry are all gone from the repo. Earlier rounds deployed custom files into
# the target HOME; deleting them from the repo does not remove them from an
# existing install.
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

# --- Hyprland session entry resolution (R5, aligned with the physical
# machine's STOCK entry) ---
# Resolves hyprland.desktop in the target session's XDG_DATA_HOME then
# XDG_DATA_DIRS, in order (the same order the removed uwsm-managed entry
# used; kept so a user/local override that shadows the system entry is
# detected and fails closed). The target-session values are explicit
# (TARGET_XDG_DATA_HOME / TARGET_XDG_DATA_DIRS, defaulting to the XDG spec
# defaults) and are NOT the installer process's own XDG_* environment. The
# FIRST candidate that exists (lstat) is CLASSIFIED: dangling/FIFO/dir/
# unreadable/wrong-section/empty-Exec/missing-Exec-program all fail closed
# (rc 2), never skipped to a lower-priority candidate. rc: 0=usable entry
# echoed, 1=no candidate, 2=first existing candidate unusable (path echoed),
# 3=python/validator unavailable or interpreter/infra failure (42/126/127/...
# are NEVER folded into rc=2 - they mean the validator could not run, not
# that the entry is corrupt; R4.4).
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

# --- VMware guest graphics workaround (upstream Hyprland#7658) ---
# Hyprland (aquamarine) cannot import client dma-bufs produced by mesa's EGL
# on the VMware SVGA3D (vmwgfx) driver: every GL client dies with
# "wl_surface.attach: invalid arguments" (kitty, quickshell/DMS and GTK apps
# alike; upstream hyprwm/Hyprland#7658, unfixed - vaxerski attributes it to
# mesa). Forcing software GL makes mesa hand wl_shm buffers to the compositor
# instead, which imports fine, so terminals and DMS work inside the VM.
# Applied ONLY when the installer runs inside VMware (matches install.sh's
# physical-sim-vmware preflight); bare-metal installs keep hardware GL.
# SYSTEMD_DETECT_VIRT is injectable for tests (same pattern as UWSM_BIN).
is_vmware_guest() {
  local virt="${SYSTEMD_DETECT_VIRT:-$(systemd-detect-virt 2>/dev/null || true)}"
  [[ "${virt}" == "vmware" ]]
}
apply_vmware_graphics_workaround() { # apply_vmware_graphics_workaround [env-file]
  local envf="${1:-/etc/environment}"
  if ! is_vmware_guest; then
    return 0
  fi
  # idempotent: never duplicate the line if a previous run (or the operator)
  # already set it. Match exactly "=1" so an operator's deliberate
  # LIBGL_ALWAYS_SOFTWARE=0 (disable the workaround) is NOT treated as
  # already-applied - 09-settings verifies "=1" and would otherwise abort
  # (found 2026-08-10 swarm audit).
  grep -q '^LIBGL_ALWAYS_SOFTWARE=1' "${envf}" 2>/dev/null && return 0
  if [[ -w "${envf}" ]]; then
    # writable from this context (root/strap path, or tests with a temp file)
    printf 'LIBGL_ALWAYS_SOFTWARE=1\n' >> "${envf}"
  else
    # normal-user ./install.sh path: /etc/environment is root-owned, so the
    # write must go through run() (sudo). A direct append died with
    # "Permission denied" at 09-settings on the user's run (2026-08-10).
    run bash -c "grep -q '^LIBGL_ALWAYS_SOFTWARE=1' '${envf}' 2>/dev/null || printf 'LIBGL_ALWAYS_SOFTWARE=1\n' >> '${envf}'"
  fi
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
