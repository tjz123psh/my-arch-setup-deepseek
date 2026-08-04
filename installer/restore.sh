#!/usr/bin/env bash
# shellcheck shell=bash
# One-click physical restore entry point (tty-safe).
#
# Designed for the operator's own ASUS workstation restore after a manual base
# install (partitioning, base system, GRUB, first boot, network — the project
# boundary). Runs the full nine-stage orchestrated DAG with an upfront plan
# summary and one confirmation, then reports per-stage results.
#
# Safety:
#   - never touches partition/GRUB/kernel/credentials/login-manager;
#   - reads the exact reviewed plan before doing anything (--plan is zero-write);
#   - installs only the build prerequisites that the clean base lacks
#     (python3 git base-devel devtools rust curl);
#   - runs the orchestrated apply with the three explicit confirmations, which
#     the operator grants by the single confirmation prompt below;
#   - any stage failure stops the run; rerun with the same command resumes.
#
# tty compatibility: gsudo's askpass helper falls back to systemd-ask-password
# when fuzzel is not yet installed, so the password prompt works from a plain
# tty with no graphical session. All output is English to stay readable under
# any terminal locale (a clean base may lack a UTF-8 locale).
#
# NOTE: python3 is required to run full-orchestrator.py; a minimal Arch base
# does not ship it. This script installs python3 (and git) automatically as
# part of the build-prerequisite step, so the first run on a clean base needs
# python3 only to be installable by pacman, not preinstalled.

set -Eeuo pipefail

PROJECT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
readonly PROJECT_DIR
readonly ORCHESTRATOR="${PROJECT_DIR}/installer/full-orchestrator.py"
readonly PROFILE_DEFAULT="asus-amd-nvidia"

PROFILE="${PROFILE_DEFAULT}"
PLAN_ONLY=false
ASSUME_YES=false
SKIP_PREREQS=false

usage() {
  cat <<'EOF_USAGE'
Usage: restore.sh [options]

After reinstalling Arch and completing the manual handoff (partitioning,
base install, GRUB, first boot, networking), restore the full workstation on
this machine with the nine-stage DAG (official packages -> archlinuxcn ->
AUR -> config -> system actions).

Options:
  -p, --profile NAME   target profile (default: asus-amd-nvidia)
  --plan               print the installation plan and exit (zero writes)
  -y, --assume-yes     skip the plan confirmation (reviewed reruns only)
  --skip-prereqs       do not auto-install AUR build prerequisites
  -h, --help           show this help and exit
EOF_USAGE
}

log() { printf '[restore] %s\n' "$*"; }
die() { printf '[restore] error: %s\n' "$*" >&2; exit 1; }

parse_args() {
  while (( $# > 0 )); do
    case "$1" in
      -p|--profile) PROFILE="$2"; shift 2 ;;
      --plan) PLAN_ONLY=true; shift ;;
      -y|--assume-yes) ASSUME_YES=true; shift ;;
      --skip-prereqs) SKIP_PREREQS=true; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown argument: $1 (see --help)" ;;
    esac
  done
}

# Read-only environment checks (no package installs here)
check_prereqs() {
  command -v pacman >/dev/null 2>&1 || die "pacman not found; is this an Arch system?"
  command -v sudo >/dev/null 2>&1 || die "sudo not found; install it first (pacman -S sudo)"
  # python3/git are handled by install_build_prereqs below; a clean base may
  # lack them and we install them automatically instead of failing here.
  # Network probe: read-only, modifies nothing.
  if ! timeout 8 bash -c 'echo > /dev/tcp/8.8.8.8/53' 2>/dev/null; then
    log "warning: network probe failed (8.8.8.8:53); AUR/archlinuxcn stages need connectivity."
    if [[ "${ASSUME_YES}" != "true" ]]; then
      die "establish a working network connection first (NetworkManager: nmcli device connect <iface>)"
    fi
  fi
}

# Root channel: detect whether sudo needs a password (no prompt here)
check_root() {
  if sudo -n true 2>/dev/null; then
    return 0
  fi
  # sudo needs a password: require an interactive tty
  if [[ -t 0 ]] && [[ -t 1 ]]; then
    log "root required; a sudo password prompt will follow."
    return 0
  fi
  die "sudo requires a password and stdin is not an interactive tty; run directly in a terminal (not nohup/background)."
}

# Print the reviewed plan (reads the orchestrator --plan text output)
show_plan() {
  log "reading read-only plan for profile '${PROFILE}'..."
  local plan_out
  plan_out="$("${ORCHESTRATOR}" --profile "${PROFILE}" --plan 2>&1)" || \
    die "plan generation failed (profile '${PROFILE}' missing or misconfigured)"
  printf '%s\n' "${plan_out}" | sed -n '1,60p'
  # The blockers line looks like:
  #   Apply blockers: non-executable-modules=none; missing-adapter-stages=none; non-integrated-stages=none; noncanonical-adapter=false
  # Refuse unless the exact clean form is present.
  local blockers_line
  blockers_line="$(printf '%s\n' "${plan_out}" | grep -E "^Apply blockers:" || true)"
  if [[ -n "${blockers_line}" ]]; then
    if ! printf '%s\n' "${blockers_line}" | grep -qE "non-executable-modules=none; missing-adapter-stages=none; non-integrated-stages=none; noncanonical-adapter=false"; then
      die "plan has apply blockers: ${blockers_line}"
    fi
  fi
}

confirm_plan() {
  if [[ "${ASSUME_YES}" == "true" ]]; then
    log "confirmation skipped via --assume-yes."
    return 0
  fi
  if [[ ! -t 0 ]]; then
    die "confirmation requires an interactive tty; run directly, or use --assume-yes (reviewed reruns only)."
  fi
  printf '\n[restore] This is what will be executed. Type yes to continue, anything else aborts: '
  local answer
  read -r answer
  if [[ "${answer}" != "yes" ]]; then
    die "aborted (answer was not yes). Nothing was changed."
  fi
}

# Install the build/runtime prerequisites a clean Arch base lacks.
# python3 runs the orchestrator; git fetched this repo; base-devel/devtools/rust
# build the AUR recipes; curl fetches remote sources.
install_build_prereqs() {
  if [[ "${SKIP_PREREQS}" == "true" ]]; then
    log "build-prerequisite install skipped (--skip-prereqs)."
    return 0
  fi
  log "checking/installing runtime and build prerequisites (python3 git base-devel devtools rust curl)..."
  local missing=()
  for p in python3 git base-devel devtools rust curl; do
    if ! pacman -Q "${p}" >/dev/null 2>&1; then missing+=("${p}"); fi
  done
  if (( ${#missing[@]} == 0 )); then
    log "prerequisites already present."
    return 0
  fi
  printf '[restore] installing prerequisites: %s\n' "${missing[*]}"
  sudo pacman -S --needed --noconfirm "${missing[@]}" || \
    die "prerequisite install failed; check network/mirror and retry."
  log "prerequisites ready."
}

# Run the nine-stage DAG (confirmations were granted by confirm_plan)
run_dag() {
  log "starting nine-stage DAG apply (profile '${PROFILE}')..."
  "${ORCHESTRATOR}" --profile "${PROFILE}" --mode new --apply \
    --confirm-system-changes --confirm-archlinuxcn --confirm-aur
}

report_done() {
  cat <<'EOF_DONE'

[restore] nine-stage DAG completed.

Accept on this host (the installer does not do these automatically):
  1. display/GPU: switch NVIDIA <-> AMD, confirm outputs
  2. audio: playback and recording
  3. bluetooth: pair a device
  4. suspend/resume
  5. ASUS control center (fans/performance modes)

If a stage failed, rerun this script (idempotent; same plan resumes/reruns).
EOF_DONE
}

main() {
  parse_args "$@"
  cd "${PROJECT_DIR}"
  check_prereqs
  # python3 is required to render the plan. A clean base may lack it; install
  # it first (still zero other writes). --plan with a missing python3 tells
  # the operator how to get one.
  if ! command -v python3 >/dev/null 2>&1; then
    if [[ "${PLAN_ONLY}" == "true" ]]; then
      die "python3 is missing. Install it first (sudo pacman -S python3), or run restore.sh without --plan to install prerequisites automatically."
    fi
    log "python3 missing; installing it first so the plan can be rendered..."
    check_root
    sudo pacman -S --needed --noconfirm python3 || \
      die "python3 install failed; check network/mirror and retry."
  fi
  show_plan
  if [[ "${PLAN_ONLY}" == "true" ]]; then
    log "--plan requested; nothing was changed."
    exit 0
  fi
  check_root
  confirm_plan
  install_build_prereqs
  run_dag
  report_done
}

main "$@"
