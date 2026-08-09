#!/usr/bin/env bash
# install.sh - main installer.
#
#   select desktop -> select machine type -> diagnostics -> update
#   -> stepwise modules (resume via .install_progress) -> done
#
# Runs as a normal user; privileged steps prompt for sudo when needed.

set -Eeuo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="${BASE_DIR}/scripts"

# shellcheck source=scripts/00-utils.sh
source "${SCRIPTS_DIR}/00-utils.sh"

DESKTOP_ENV="${DESKTOP_ENV:-}"
MACHINE_TYPE="${MACHINE_TYPE:-}"
TEST_PROFILE="${TEST_PROFILE:-}"
ASSUME_YES="${ASSUME_YES:-false}"
FORCE_REFRESH="${FORCE_REFRESH:-0}"
FZF_AVAILABLE=1
MODULES=()

# Temporary scoped sudo drop-in used during the install. Scoped to pacman
# only (see main pre-flight); removed on EVERY exit path via the EXIT trap
# AND by 99-cleanup, so an interrupted/failed run never leaves a
# passwordless grant behind (review C-01).
SUDOERS_DROPIN=/etc/sudoers.d/99-install-nopasswd

cleanup_install_sudoers() {
  if [[ -f "${SUDOERS_DROPIN}" ]]; then
    if [[ "$(id -u)" -eq 0 ]]; then
      rm -f "${SUDOERS_DROPIN}"
    else
      sudo rm -f "${SUDOERS_DROPIN}" 2>/dev/null || true
    fi
  fi
}
trap cleanup_install_sudoers EXIT

usage() {
  cat <<'EOF'
Usage: install.sh [options]

One-click Arch desktop restore (Niri/Hyprland). Interactively select desktop and machine type;
flags can specify them directly to skip the prompts.

Options:
  -d, --desktop niri|both|none
            (pure hyprland is intentionally removed: Hyprland only runs as
             part of "both", selectable from the greetd/dms-greeter session menu)
  -t, --machine vm|physical
      --test-profile physical-sim-vmware   run the physical branch in a VMware guest,
                                           marking hardware-only effects NOT_APPLICABLE_SIMULATED
      --force-refresh    repair mode: full database refresh (-Syyu) instead of -Syu
                         in the single 02-system upgrade (NOT the default)
  -y, --assume-yes   auto-reboot without prompting after install
  -h, --help
EOF
}

parse_args() {
  while (( $# > 0 )); do
    case "$1" in
      -d|--desktop)
        case "$2" in
          niri|both|none) DESKTOP_ENV="$2" ;;
          hyprland) die "invalid --desktop value: hyprland (no longer supported; use 'both' and pick Hyprland from the greetd session menu)" ;;
          *) die "invalid --desktop value: $2 (niri|both|none)" ;;
        esac
        shift 2 ;;
      -t|--machine)
        case "$2" in
          vm|physical) MACHINE_TYPE="$2" ;;
          *) die "invalid --machine value: $2 (vm|physical)" ;;
        esac
        shift 2 ;;
      --test-profile)
        case "$2" in
          physical-sim-vmware)
            TEST_PROFILE="$2"
            # The simulated-physical profile forces the physical branch even
            # when running inside a VMware guest; it must be combined with
            # -t physical (checked in main).
            ;;
          *) die "invalid --test-profile value: $2 (physical-sim-vmware)" ;;
        esac
        shift 2 ;;
      -h|--help) usage; exit 0 ;;
      # flag args take no value: shift exactly once. Without the shift the
      # while loop re-matches $1 forever (100% CPU spin) - caught by the
      # fresh-VM install run (2026-08-10) and regression-tested in
      # installer-behavior-test.sh (parse_args with -y / --force-refresh).
      --force-refresh) FORCE_REFRESH="1"; shift ;;
      -y|--assume-yes) ASSUME_YES="true"; shift ;;
      *) die "unknown argument: $1 (see --help)" ;;
    esac
  done
}

ensure_fzf_ui() {
  # fzf is only needed for interactive selection; if missing we fall back to
  # plain prompts (no pacman sync before mirror config, download-mode D-05).
  FZF_AVAILABLE=1
  if [[ -z "${DESKTOP_ENV}" || -z "${MACHINE_TYPE}" ]]; then
    if ! ensure_fzf; then
      FZF_AVAILABLE=0
    fi
  fi
}

select_desktop() {
  [[ -n "${DESKTOP_ENV}" ]] && return
  section "Select desktop environment"
  local selected
  if [[ "${FZF_AVAILABLE:-1}" == "1" ]]; then
    selected="$(printf 'Niri (recommended)\nNiri + Hyprland (both)\nNo desktop (packages and config only)\n' \
      | fzf --layout=reverse --border=rounded \
          --header=' Select desktop (J/K move, Enter confirm) ' \
          --bind 'j:down,k:up,esc:abort,ctrl-c:abort')" || true
  else
    printf '1) Niri (recommended)\n2) Niri + Hyprland (both)\n3) No desktop (packages and config only)\n'
    printf 'Select [1-3]: '
    if ! read -r selected; then
      die "Selection cancelled (EOF / no input)"
    fi
    case "${selected}" in
      1) selected="Niri" ;;
      2) selected="Hyprland (both)" ;;
      3) selected="No desktop" ;;
      *) die "Invalid selection: ${selected}" ;;
    esac
  fi
  [[ -z "${selected}" ]] && die "Cancelled"
  case "${selected}" in
    *"Hyprland (both)"*) DESKTOP_ENV="both" ;;
    *"No desktop"*) DESKTOP_ENV="none" ;;
    *) DESKTOP_ENV="niri" ;;
  esac
  log "Desktop: ${DESKTOP_ENV}"
}

select_machine() {
  [[ -n "${MACHINE_TYPE}" ]] && return
  section "Select machine type"
  local selected
  if [[ "${FZF_AVAILABLE:-1}" == "1" ]]; then
    selected="$(printf 'Physical machine (ASUS, full config)\nVirtual machine (same config, drivers skipped)\n' \
      | fzf --layout=reverse --border=rounded \
          --header=' Select machine type (J/K move, Enter confirm) ' \
          --bind 'j:down,k:up,esc:abort,ctrl-c:abort')" || true
  else
    printf '1) Physical machine (ASUS, full config)\n2) Virtual machine (same config, drivers skipped)\n'
    printf 'Select [1-2]: '
    if ! read -r selected; then
      die "Selection cancelled (EOF / no input)"
    fi
    case "${selected}" in
      1) selected="Physical machine" ;;
      2) selected="Virtual machine" ;;
      *) die "Invalid selection: ${selected}" ;;
    esac
  fi
  [[ -z "${selected}" ]] && die "Cancelled"
  case "${selected}" in
    *"Virtual machine"*) MACHINE_TYPE="vm" ;;
    *) MACHINE_TYPE="physical" ;;
  esac
  log "Machine: ${MACHINE_TYPE}"
}

build_modules() {
  MODULES=(01-mirror.sh 02-system.sh 03-packages.sh)
  # drivers before desktop (physical only; the script itself skips on vm)
  MODULES+=(04-drivers.sh)
  case "${DESKTOP_ENV}" in
    niri) MODULES+=(05-niri.sh) ;;
    both) MODULES+=(05-niri.sh 05-hyprland.sh) ;;
    none) log "Skipping desktop environment" ;;
  esac
  MODULES+=(06-aur.sh 07-config.sh 08-services.sh 09-settings.sh 99-cleanup.sh)
}

main() {
  parse_args "$@"
  check_root
  # Desktop whitelist (fail closed): pure hyprland is removed; a stale
  # DESKTOP_ENV=hyprland from the environment (or an unknown value) must
  # never be silently accepted as "both". Resume is additionally guarded by
  # the progress context binding (desktop is part of the context hash).
  case "${DESKTOP_ENV}" in
    ""|niri|both|none) ;;
    hyprland) die "DESKTOP_ENV=hyprland is no longer supported; use 'both' and pick Hyprland from the greetd session menu" ;;
    *) die "unknown DESKTOP_ENV=${DESKTOP_ENV} (niri|both|none)" ;;
  esac
  if [[ -n "${TEST_PROFILE}" ]] && [[ "${MACHINE_TYPE}" != "physical" ]]; then
    die "--test-profile physical-sim-vmware requires -t physical"
  fi
  # P0-2 (review): physical-sim-vmware must ONLY run inside a real VMware
  # guest. A bare `-t physical` on the physical host (or in KVM/QEMU) must
  # never be able to masquerade as a simulated-physical acceptance run.
  if [[ "${TEST_PROFILE}" == "physical-sim-vmware" ]]; then
    if [[ "$(systemd-detect-virt 2>/dev/null || true)" != "vmware" ]]; then
      die "--test-profile physical-sim-vmware requires systemd-detect-virt == vmware (detected: $(systemd-detect-virt 2>/dev/null || echo unknown))"
    fi
    log "physical-sim-vmware preflight: systemd-detect-virt=vmware confirmed"
  fi
  ensure_fzf_ui
  select_machine
  select_desktop
  build_modules
  sys_dashboard

  # Module scripts run as child processes; export the selections so they
  # can read MACHINE_TYPE/DESKTOP_ENV without re-prompting. TARGET_USER/
  # TARGET_HOME (resolved in 00-utils) are exported for the root/strap path.
  export MACHINE_TYPE DESKTOP_ENV TARGET_USER TARGET_HOME
  [[ -n "${TEST_PROFILE}" ]] && export TEST_PROFILE

  # Bind the resume file to this install context (desktop/machine/user/
  # commit/manifest hashes); a mismatched stale progress file aborts here
  # instead of resume-skipping modules (review H-02).
  setup_progress

  # Step 2 (download-mode-lab D-00): apply mirror config BEFORE the first
  # sync/upgrade so the first pacman transaction uses the optimized
  # mirrorlist. 01-mirror.sh is idempotent and performs NO pacman sync or
  # package install by itself; 02-system.sh owns the single official sync/
  # upgrade (-Syu, or -Syyu only under --force-refresh). The old default
  # `pacman -Syyu` here is gone (D-03): it forced a full db refresh and
  # re-synced the database before the mirror config existed.
  section "Pre-Flight" "Mirror configuration"
  bash "${PROJECT_DIR}/scripts/01-mirror.sh"
  # Step 2 (follow-up 1): 01-mirror.sh already ran in pre-flight; mark it
  # done so the module loop below skips it instead of running it twice.
  mark_done 01-mirror.sh

  export FORCE_REFRESH

  # One password for the whole install: extend the sudo timestamp AND grant a
  # SCOPED NOPASSWD for /usr/bin/pacman only. makepkg deliberately runs every
  # pacman call as `sudo -k` (clearing the timestamp cache), so the AUR step
  # would otherwise re-prompt for every missing dependency. Scoping the grant
  # to pacman (instead of ALL) keeps the blast radius to package management;
  # every other privileged step (systemctl/useradd/grub-mkconfig/...) still
  # needs the timestamp. The drop-in is removed by the EXIT trap above AND by
  # 99-cleanup, restoring stock sudo on every exit path.
  if [[ "$(id -u)" -ne 0 ]]; then
    # Stale drop-in from an interrupted previous run: validate its syntax and
    # remove it before creating a fresh one. Never reuse an untested sudoers
    # file, and never leave an old ALL grant lying around.
    if [[ -f "${SUDOERS_DROPIN}" ]]; then
      log "Removing stale ${SUDOERS_DROPIN} from a previous run..."
      run bash -c "visudo -cf '${SUDOERS_DROPIN}' && rm -f '${SUDOERS_DROPIN}'" \
        || warn "could not remove stale ${SUDOERS_DROPIN}; remove it manually: sudo rm -f ${SUDOERS_DROPIN}"
    fi
    run bash -c "printf 'Defaults timestamp_timeout=240\n${TARGET_USER} ALL=(ALL) NOPASSWD: /usr/bin/pacman\n' > '${SUDOERS_DROPIN}' && chmod 440 '${SUDOERS_DROPIN}' && visudo -cf '${SUDOERS_DROPIN}'" \
      || { error "could not create scoped sudoers drop-in"; exit 1; }
    log "Scoped sudo grant active (pacman only, auto-removed on exit)"
  fi

  local total="${#MODULES[@]}" current=0
  for module in "${MODULES[@]}"; do
    [[ -z "${module}" ]] && continue
    current=$((current + 1))
    local script_path="${SCRIPTS_DIR}/${module}"
    if [[ ! -f "${script_path}" ]]; then
      error "Missing required script: ${module}"
      exit 1
    fi
    if is_done "${module}"; then
      log "Module ${module} already done, skipping"
      continue
    fi
    section "Step ${current}/${total}" "${module}"
    # shellcheck disable=SC1090
    bash "${script_path}"
    local rc=$?
    if (( rc == 0 )); then
      mark_done "${module}"
      success "Done: ${module}"
    else
      error "Module ${module} failed (exit ${rc}); rerun install.sh to resume"
      exit "${rc}"
    fi
  done

  section "Done"
  success "Installation complete. A reboot is recommended."
  echo
  echo -e "${H_YELLOW}>>> A system reboot is required.${NC}"
  echo
  # Auto-reboot: -y skips the prompt and reboots immediately; otherwise ask
  # on an interactive tty. Never reboot when stdin is not a tty (e.g. CI/log).
  if [[ "${ASSUME_YES}" == "true" ]]; then
    log "Auto-rebooting (--assume-yes)..."
    sleep 3
    run systemctl reboot
  elif [[ -t 0 ]]; then
    printf '%s' '[install] Reboot now? [Y/n]: '
    local answer
    read -r answer
    if [[ -z "${answer}" || "${answer,,}" == "y" || "${answer,,}" == "yes" ]]; then
      log "Rebooting..."
      sleep 3
      run systemctl reboot
    else
      log "Skipping reboot; run 'sudo systemctl reboot' when ready."
    fi
  else
    log "Non-interactive session; run 'sudo systemctl reboot' when ready."
  fi
}

main "$@"
