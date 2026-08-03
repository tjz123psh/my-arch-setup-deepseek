#!/usr/bin/env bash
# shellcheck shell=bash
# Legacy alpha component retained for read-only compatibility plans and isolated
# regression fixtures. Production changing work belongs exclusively to
# full-orchestrator.py and its canonical hash-pinned stage adapters.

set -Eeuo pipefail

readonly PROJECT_NAME="my-archlinux-setup"
readonly STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/${PROJECT_NAME}"
readonly LOG_DIR="${STATE_DIR}/logs"
readonly BACKUP_DIR="${STATE_DIR}/backups"
readonly RUNS_DIR="${STATE_DIR}/runs"
readonly LATEST_RUN_FILE="${STATE_DIR}/latest-run"
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly SCRIPT_DIR
PROJECT_DIR=$(cd -- "${SCRIPT_DIR}/.." && pwd)
readonly PROJECT_DIR
readonly CONFIG_MAPPING="${PROJECT_DIR}/manifests/config-mappings.tsv"
readonly OFFICIAL_PACKAGES="${PROJECT_DIR}/manifests/official-packages.tsv"
readonly MODULE_REGISTRY="${PROJECT_DIR}/manifests/modules.tsv"
readonly PROFILE_MODULES_MANIFEST="${PROJECT_DIR}/manifests/profile-modules.tsv"
readonly WORKSTATION_PACKAGE_POLICY="${PROJECT_DIR}/manifests/workstation-packages.tsv"

PROFILE=""
PLAN_ONLY=false
APPLY_CONFIG=false
APPLY_OFFICIAL=false
APPLY_ORCHESTRATED=false
CONFIRM_CONFIG=false
CONFIRM_SYSTEM_CHANGES=false
MODE="new"
APPLY_LOG=""
RUN_LOG=""
RETRY_MODULE=""
RERUN=false
ORCHESTRATED_CONFIRMATIONS=false
OFFICIAL_PREFLIGHT_COMPLETE=false
ROOT_AVAILABLE_KIB=""
RUN_ID=""
RUN_PATH=""
RUN_STATUS=""
RUN_ATTEMPT=0
RUN_RETRY_MODULE="none"
RUN_STARTED_AT=""
RUN_UPDATED_AT=""
RUN_FAILED_STAGE="none"
RUN_FAILURE_STATUS=0
RUN_FINGERPRINT=""
RUN_PROFILE=""
RUN_MODE=""
RUN_MODULES=""
RUN_CONTEXT_ACTION=""
RUN_RESUME_STAGE="none"
LATEST_RUN_ID=""
NOW=""
declare -A RUN_STAGE_STATUS=()
MODULES_ARGUMENT=""
MODULES_ARGUMENT_SET=false
MODULE_SELECTION_SOURCE=""
CONFIG_SCOPE=""
SELECTION_BLOCKED=false
declare -a MODULE_IDS=()
declare -a PROFILE_MODULE_IDS=()
declare -a SELECTED_MODULE_IDS=()
declare -A MODULE_AVAILABILITY=()
declare -A MODULE_KIND=()
declare -A MODULE_REQUIRES_ALL=()
declare -A MODULE_REQUIRES_ANY=()
declare -A MODULE_PURPOSE=()
declare -A PROFILE_MODULE_ALLOWED=()
declare -A PROFILE_MODULE_DEFAULT=()
declare -A SELECTED_MODULE=()
declare -A MODULE_SELECTION_ORIGIN=()
declare -a OFFICIAL_MODULES=()
declare -a OFFICIAL_PACKAGE_NAMES=()
declare -a OFFICIAL_PURPOSES=()
declare -a CONFIG_MODULES=()
declare -a CONFIG_SOURCES=()
declare -a CONFIG_TARGETS=()
declare -a CONFIG_MODES=()
declare -a WORKSTATION_PACKAGE_NAMES=()
declare -a WORKSTATION_PACKAGE_CHANNELS=()
declare -a WORKSTATION_PACKAGE_REPOSITORIES=()
declare -a WORKSTATION_PACKAGE_ACQUISITIONS=()
declare -a WORKSTATION_PACKAGE_MODULES=()
declare -a WORKSTATION_PACKAGE_POLICIES=()
declare -a WORKSTATION_PACKAGE_ORIGINS=()
WORKSTATION_POLICY_ROWS=0
WORKSTATION_CURRENT_ROWS=0
WORKSTATION_DESIRED_ROWS=0
WORKSTATION_OFFICIAL_CANDIDATES=0
WORKSTATION_ARCHLINUXCN_CANDIDATES=0
WORKSTATION_ARCHLINUXCN_BOOTSTRAPS=0
WORKSTATION_AUR_CANDIDATES=0
WORKSTATION_PARU_BOOTSTRAPS=0

usage() {
  cat <<'EOF'
Usage: installer/install.sh --profile PROFILE [--modules LIST] [--plan | --apply | --apply-config | --apply-official] [OPTIONS]

Profiles:
  asus-amd-nvidia  Physical ASUS AMD + NVIDIA workstation configuration
  desktop-amd      AMD desktop configuration
  vm               Minimal official-repository Niri regression profile

Options:
  --profile NAME   Select an explicit profile.
  --modules LIST   Use this exact comma-separated module selection; dependencies
                   are added deterministically. Use `none` for an empty selection.
  --plan           Run read-only preflight and show the current plan.
  --apply          Run applicable package/config stages after all confirmations.
  --apply-config   Deploy audited configuration mappings after a visible prompt.
  --apply-official Update Arch and install the reviewed official package manifest.
  --confirm-config Skip the config prompt; valid only with --apply-config.
  --confirm-system-changes
                   Skip the package prompt; valid with --apply or --apply-official.
  --retry MODULE   Resume the latest matching failed --apply run for MODULE.
  --rerun          Intentionally create a new run for a matching prior plan.
  --mode MODE      Deployment mode: new (default) or reconcile.
  --help           Show this help.

`--apply-official` performs a visible `pacman -Syu`, then installs only the
explicit official package manifest. It does not alter services or repositories.
`--apply` collects every applicable confirmation before creating run state or
executing a stage. Any apply launched without an interactive stdin must provide
`--modules`; confirmation flags also require it.
EOF
}

log_error_if_available() {
  local message="$1"
  if [[ -n "$APPLY_LOG" ]]; then
    if ! printf 'error: %s\n' "$message" >>"$APPLY_LOG"; then
      printf 'warning: could not append the error to apply log %s\n' "$APPLY_LOG" >&2
    fi
  fi
  if [[ -n "$RUN_LOG" && "$RUN_LOG" != "$APPLY_LOG" ]]; then
    if ! printf 'error: %s\n' "$message" >>"$RUN_LOG"; then
      printf 'warning: could not append the error to run log %s\n' "$RUN_LOG" >&2
    fi
  fi
}

die() {
  printf 'error: %s\n' "$*" >&2
  log_error_if_available "$*"
  exit 1
}

die_with_status() {
  local status="$1"
  shift
  if [[ ! "$status" =~ ^[0-9]+$ ]] || ((status < 1 || status > 255)); then
    status=1
  fi
  printf 'error: %s\n' "$*" >&2
  log_error_if_available "$*"
  exit "$status"
}

log_apply_line() {
  [[ -n "$APPLY_LOG" ]] || die "internal error: apply log is not initialized"
  printf '%s\n' "$*" >>"$APPLY_LOG"
}

run_checked() {
  local description="$1" status log_status
  local -a pipeline_status=()
  shift
  log_apply_line "command: $description"
  set +e
  "$@" 2>&1 | tee -a -- "$APPLY_LOG"
  pipeline_status=("${PIPESTATUS[@]}")
  set -e
  status=${pipeline_status[0]}
  log_status=${pipeline_status[1]}
  ((log_status == 0)) || die_with_status "$log_status" "apply log write failed with exit $log_status"
  ((status == 0)) || die_with_status "$status" "$description failed with exit $status"
}

require_value() {
  [[ $# -ge 2 ]] || die "$1 requires a value"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --profile)
        require_value "$@"
        PROFILE="$2"
        shift 2
        ;;
      --modules)
        require_value "$@"
        [[ "$MODULES_ARGUMENT_SET" != true ]] || die "--modules may be provided only once"
        MODULES_ARGUMENT="$2"
        MODULES_ARGUMENT_SET=true
        shift 2
        ;;
      --plan)
        PLAN_ONLY=true
        shift
        ;;
      --apply)
        APPLY_ORCHESTRATED=true
        shift
        ;;
      --apply-config)
        APPLY_CONFIG=true
        shift
        ;;
      --apply-official)
        APPLY_OFFICIAL=true
        shift
        ;;
      --confirm-config)
        CONFIRM_CONFIG=true
        shift
        ;;
      --confirm-system-changes)
        CONFIRM_SYSTEM_CHANGES=true
        shift
        ;;
      --retry)
        require_value "$@"
        [[ -z "$RETRY_MODULE" ]] || die "--retry may be provided only once"
        RETRY_MODULE="$2"
        shift 2
        ;;
      --rerun)
        [[ "$RERUN" != true ]] || die "--rerun may be provided only once"
        RERUN=true
        shift
        ;;
      --mode)
        require_value "$@"
        MODE="$2"
        shift 2
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        die "unknown option: $1"
        ;;
    esac
  done

  [[ -n "$PROFILE" ]] || die "--profile is required"
  local action_count=0
  [[ "$PLAN_ONLY" == true ]] && ((action_count += 1))
  [[ "$APPLY_ORCHESTRATED" == true ]] && ((action_count += 1))
  [[ "$APPLY_CONFIG" == true ]] && ((action_count += 1))
  [[ "$APPLY_OFFICIAL" == true ]] && ((action_count += 1))
  ((action_count == 1)) || die "select exactly one of --plan, --apply, --apply-config, or --apply-official"
  [[ "$CONFIRM_CONFIG" != true || "$APPLY_CONFIG" == true || "$APPLY_ORCHESTRATED" == true ]] ||     die "--confirm-config requires --apply or --apply-config"
  [[ "$CONFIRM_SYSTEM_CHANGES" != true || "$APPLY_OFFICIAL" == true || "$APPLY_ORCHESTRATED" == true ]] ||     die "--confirm-system-changes requires --apply or --apply-official"
  [[ "$CONFIRM_CONFIG" != true || "$MODULES_ARGUMENT_SET" == true ]] || die "--confirm-config requires an explicit --modules selection"
  [[ "$CONFIRM_SYSTEM_CHANGES" != true || "$MODULES_ARGUMENT_SET" == true ]] || die "--confirm-system-changes requires an explicit --modules selection"
  [[ -z "$RETRY_MODULE" || "$APPLY_ORCHESTRATED" == true ]] || die "--retry requires --apply"
  [[ "$RERUN" != true || "$APPLY_ORCHESTRATED" == true ]] || die "--rerun requires --apply"
  [[ -z "$RETRY_MODULE" || "$RERUN" != true ]] || die "--retry and --rerun are mutually exclusive"
  [[ ( -z "$RETRY_MODULE" && "$RERUN" != true ) || "$MODULES_ARGUMENT_SET" == true ]] ||     die "--retry and --rerun require an explicit --modules selection"
  [[ -z "$RETRY_MODULE" || "$RETRY_MODULE" =~ ^[a-z0-9][a-z0-9-]*$ ]] ||     die "invalid retry module: $RETRY_MODULE"
  case "$PROFILE" in
    asus-amd-nvidia|desktop-amd|vm) ;;
    *) die "unsupported profile: $PROFILE" ;;
  esac
  case "$MODE" in
    new|reconcile) ;;
    *) die "unsupported mode: $MODE" ;;
  esac
  if [[ "$PLAN_ONLY" != true && "$MODULES_ARGUMENT_SET" != true ]] && [[ ! -t 0 ]]; then
    die "non-interactive apply requires an explicit --modules selection"
  fi
}

preflight() {
  [[ "$HOME" == /* ]] || die "HOME must be an absolute path"
  [[ "$STATE_DIR" == /* ]] || die "XDG_STATE_HOME must resolve to an absolute path"
  local user_id architecture status
  if user_id=$(id -u); then
    :
  else
    status=$?
    die_with_status "$status" "user identity query id -u failed with exit $status"
  fi
  [[ "$user_id" =~ ^[0-9]+$ ]] || die "user identity query returned an empty or invalid result"
  ((user_id != 0)) || die "run as an ordinary sudo-capable user, not root"
  if architecture=$(uname -m); then
    :
  else
    status=$?
    die_with_status "$status" "architecture query uname -m failed with exit $status"
  fi
  [[ "$architecture" == x86_64 ]] || die "unsupported architecture: $architecture (x86_64 is required)"
  command -v pacman >/dev/null || die "pacman was not found; this is not a supported Arch system"
  command -v systemctl >/dev/null || die "systemctl was not found; systemd is required"
  [[ -f /etc/arch-release ]] || die "unsupported distribution: /etc/arch-release is missing"
  command -v sudo >/dev/null || die "sudo is required"

  # No network request is made in plan mode. DNS configuration is only reported.
  if [[ -s /etc/resolv.conf ]]; then
    printf 'preflight: DNS configuration present\n'
  else
    printf 'preflight: DNS configuration unavailable (would block apply mode)\n'
  fi

  if [[ -e /var/lib/pacman/db.lck ]]; then
    die "pacman lock exists at /var/lib/pacman/db.lck"
  fi

  if [[ "$APPLY_OFFICIAL" == true ]]; then
    printf 'preflight: official package apply will request sudo after explicit confirmation\n'
  else
    printf 'preflight: this read-only/configuration path makes no sudo calls\n'
  fi
  printf 'preflight: passed for profile %s\n' "$PROFILE"
}

ensure_private_directory() {
  local path="$1"
  [[ ! -L "$path" ]] || die "refusing to use a symlinked installer state directory: $path"
  [[ ! -e "$path" || -d "$path" ]] || die "installer state path is not a directory: $path"
  mkdir -p -- "$path"
  [[ ! -L "$path" && -d "$path" ]] || die "installer state directory changed unexpectedly: $path"
  chmod 700 -- "$path"
}

prepare_state() {
  ensure_private_directory "$STATE_DIR"
  ensure_private_directory "$LOG_DIR"
  ensure_private_directory "$BACKUP_DIR"
}

require_manifest_schema() {
  local path="$1" expected="$2" label="$3" first_line=""
  IFS= read -r first_line <"$path" || die "$label is empty or unreadable"
  [[ "$first_line" == "$expected" ]] || die "$label has an unsupported or missing schema marker"
}

validate_dependency_field() {
  local owner="$1" relation="$2" raw="$3" dependency
  local -a dependencies=()
  declare -A seen_dependencies=()
  [[ "$raw" != "-" ]] || return 0
  [[ -n "$raw" && "$raw" != ,* && "$raw" != *, && "$raw" != *,,* ]] || \
    die "module $owner has an invalid $relation dependency list"
  IFS=, read -r -a dependencies <<<"$raw"
  for dependency in "${dependencies[@]}"; do
    [[ "$dependency" =~ ^[a-z0-9][a-z0-9-]*$ ]] || \
      die "module $owner has an invalid $relation dependency: $dependency"
    [[ -n "${MODULE_AVAILABILITY[$dependency]:-}" ]] || \
      die "module $owner references an unknown $relation dependency: $dependency"
    [[ "$dependency" != "$owner" ]] || die "module $owner depends on itself"
    [[ -z "${seen_dependencies[$dependency]:-}" ]] || \
      die "module $owner repeats the $relation dependency: $dependency"
    seen_dependencies["$dependency"]=1
  done
}

load_module_registry() {
  [[ -f "$MODULE_REGISTRY" ]] || die "module registry is missing"
  reject_symlinked_project_path "manifests/modules.tsv"
  require_manifest_schema "$MODULE_REGISTRY" "# schema=1" "module registry"

  local rows status module availability kind requires_all requires_any purpose
  if rows=$(LC_ALL=C awk -F '\t' '
    BEGIN { count = 0; failed = 0 }
    /^[[:space:]]*$/ || /^#/ { next }
    {
      if (NF != 6 || $1 == "" || $2 == "" || $3 == "" || $4 == "" || $5 == "" || $6 == "") {
        failed = 1; exit 2
      }
      if ($1 !~ /^[a-z0-9][a-z0-9-]*$/ || $2 !~ /^(available|planning|unavailable)$/ ||
          $3 !~ /^(selectable|dependency)$/ || $4 !~ /^(-|[a-z0-9][a-z0-9,-]*)$/ ||
          $5 !~ /^(-|[a-z0-9][a-z0-9,-]*)$/ || $6 ~ /[[:cntrl:]]/) {
        failed = 1; exit 2
      }
      if (seen[$1]++) { failed = 1; exit 4 }
      print
      count++
    }
    END { if (!failed && count == 0) exit 3 }
  ' "$MODULE_REGISTRY"); then
    :
  else
    status=$?
    case "$status" in
      2) die_with_status "$status" "module registry has an invalid row (awk exit $status)" ;;
      3) die_with_status "$status" "module registry has no entries (awk exit $status)" ;;
      4) die_with_status "$status" "module registry has a duplicate module (awk exit $status)" ;;
      *) die_with_status "$status" "module registry query failed (awk exit $status)" ;;
    esac
  fi

  MODULE_IDS=()
  MODULE_AVAILABILITY=()
  MODULE_KIND=()
  MODULE_REQUIRES_ALL=()
  MODULE_REQUIRES_ANY=()
  MODULE_PURPOSE=()
  while IFS=$'\t' read -r module availability kind requires_all requires_any purpose; do
    MODULE_IDS+=("$module")
    MODULE_AVAILABILITY["$module"]="$availability"
    MODULE_KIND["$module"]="$kind"
    MODULE_REQUIRES_ALL["$module"]="$requires_all"
    MODULE_REQUIRES_ANY["$module"]="$requires_any"
    MODULE_PURPOSE["$module"]="$purpose"
  done <<<"$rows"

  for module in "${MODULE_IDS[@]}"; do
    validate_dependency_field "$module" "requires-all" "${MODULE_REQUIRES_ALL[$module]}"
    validate_dependency_field "$module" "requires-any" "${MODULE_REQUIRES_ANY[$module]}"
  done
}

load_profile_modules() {
  [[ -f "$PROFILE_MODULES_MANIFEST" ]] || die "profile module manifest is missing"
  reject_symlinked_project_path "manifests/profile-modules.tsv"
  require_manifest_schema "$PROFILE_MODULES_MANIFEST" "# schema=1" "profile module manifest"

  local rows status row_profile config_scope module default_state
  local selected_profile_found=false
  declare -A profile_scopes=()
  if rows=$(LC_ALL=C awk -F '\t' '
    BEGIN { count = 0; failed = 0 }
    /^[[:space:]]*$/ || /^#/ { next }
    {
      if (NF != 4 || $1 == "" || $2 == "" || $3 == "" || $4 == "") { failed = 1; exit 2 }
      if ($1 !~ /^(asus-amd-nvidia|desktop-amd|vm)$/ ||
          $2 !~ /^(none|[a-z0-9][a-z0-9-]*)$/ ||
          $3 !~ /^[a-z0-9][a-z0-9-]*$/ || $4 !~ /^(selected|disabled)$/) {
        failed = 1; exit 2
      }
      key = $1 SUBSEP $3
      if (seen[key]++) { failed = 1; exit 4 }
      print
      count++
    }
    END { if (!failed && count == 0) exit 3 }
  ' "$PROFILE_MODULES_MANIFEST"); then
    :
  else
    status=$?
    case "$status" in
      2) die_with_status "$status" "profile module manifest has an invalid row (awk exit $status)" ;;
      3) die_with_status "$status" "profile module manifest has no entries (awk exit $status)" ;;
      4) die_with_status "$status" "profile module manifest has a duplicate profile/module row (awk exit $status)" ;;
      *) die_with_status "$status" "profile module manifest query failed (awk exit $status)" ;;
    esac
  fi

  PROFILE_MODULE_IDS=()
  PROFILE_MODULE_ALLOWED=()
  PROFILE_MODULE_DEFAULT=()
  CONFIG_SCOPE=""
  while IFS=$'\t' read -r row_profile config_scope module default_state; do
    [[ -n "${MODULE_AVAILABILITY[$module]:-}" ]] || \
      die "profile module manifest references unknown module: $module"
    [[ "${MODULE_KIND[$module]}" == "selectable" ]] || \
      die "profile module manifest exposes dependency-only module: $module"
    if [[ -n "${profile_scopes[$row_profile]:-}" && "${profile_scopes[$row_profile]}" != "$config_scope" ]]; then
      die "profile module manifest gives profile $row_profile inconsistent config scopes"
    fi
    profile_scopes["$row_profile"]="$config_scope"
    [[ "$row_profile" == "$PROFILE" ]] || continue
    selected_profile_found=true
    CONFIG_SCOPE="$config_scope"
    PROFILE_MODULE_IDS+=("$module")
    PROFILE_MODULE_ALLOWED["$module"]=1
    PROFILE_MODULE_DEFAULT["$module"]="$default_state"
  done <<<"$rows"
  [[ "$selected_profile_found" == true && -n "$CONFIG_SCOPE" ]] || \
    die "profile module manifest has no entries for profile $PROFILE"
}

select_module() {
  local module="$1" origin="$2"
  if [[ -z "${SELECTED_MODULE[$module]:-}" ]]; then
    SELECTED_MODULE["$module"]=1
    MODULE_SELECTION_ORIGIN["$module"]="$origin"
  fi
}

resolve_module_selection() {
  local module dependency required_any has_any changed
  local -a requested_modules=() dependencies=() alternatives=()
  declare -A requested_seen=()
  SELECTED_MODULE=()
  MODULE_SELECTION_ORIGIN=()
  SELECTED_MODULE_IDS=()
  SELECTION_BLOCKED=false

  if [[ "$MODULES_ARGUMENT_SET" == true ]]; then
    MODULE_SELECTION_SOURCE="explicit --modules"
    if [[ "$MODULES_ARGUMENT" == "none" ]]; then
      requested_modules=()
    else
      [[ -n "$MODULES_ARGUMENT" ]] || die "--modules requires a non-empty list or none"
      [[ "$MODULES_ARGUMENT" != ,* && "$MODULES_ARGUMENT" != *, && "$MODULES_ARGUMENT" != *,,* ]] || \
        die "invalid empty entry in --modules"
      IFS=, read -r -a requested_modules <<<"$MODULES_ARGUMENT"
    fi
    for module in "${requested_modules[@]}"; do
      [[ "$module" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "invalid module name in --modules: $module"
      [[ -n "${MODULE_AVAILABILITY[$module]:-}" ]] || die "unknown module in --modules: $module"
      [[ -z "${requested_seen[$module]:-}" ]] || die "duplicate module in --modules: $module"
      requested_seen["$module"]=1
      [[ "${MODULE_KIND[$module]}" == "selectable" ]] || die "module is not directly selectable: $module"
      [[ -n "${PROFILE_MODULE_ALLOWED[$module]:-}" ]] || die "module is not supported by profile $PROFILE: $module"
      select_module "$module" "explicit"
    done
  else
    MODULE_SELECTION_SOURCE="profile defaults"
    for module in "${PROFILE_MODULE_IDS[@]}"; do
      if [[ "${PROFILE_MODULE_DEFAULT[$module]}" == "selected" ]]; then
        select_module "$module" "default"
      fi
    done
  fi

  changed=true
  while [[ "$changed" == true ]]; do
    changed=false
    for module in "${MODULE_IDS[@]}"; do
      [[ -n "${SELECTED_MODULE[$module]:-}" ]] || continue
      [[ "${MODULE_REQUIRES_ALL[$module]}" != "-" ]] || continue
      IFS=, read -r -a dependencies <<<"${MODULE_REQUIRES_ALL[$module]}"
      for dependency in "${dependencies[@]}"; do
        if [[ -z "${SELECTED_MODULE[$dependency]:-}" ]]; then
          if [[ "${MODULE_KIND[$dependency]}" == "selectable" && -z "${PROFILE_MODULE_ALLOWED[$dependency]:-}" ]]; then
            die "profile $PROFILE cannot satisfy dependency $dependency required by $module"
          fi
          select_module "$dependency" "dependency"
          changed=true
        fi
      done
    done
  done

  for module in "${MODULE_IDS[@]}"; do
    [[ -n "${SELECTED_MODULE[$module]:-}" ]] || continue
    required_any="${MODULE_REQUIRES_ANY[$module]}"
    [[ "$required_any" != "-" ]] || continue
    has_any=false
    IFS=, read -r -a alternatives <<<"$required_any"
    for dependency in "${alternatives[@]}"; do
      if [[ -n "${SELECTED_MODULE[$dependency]:-}" ]]; then
        has_any=true
        break
      fi
    done
    [[ "$has_any" == true ]] || die "$module requires one of: $required_any"
  done

  for module in "${MODULE_IDS[@]}"; do
    [[ -n "${SELECTED_MODULE[$module]:-}" ]] || continue
    SELECTED_MODULE_IDS+=("$module")
    if [[ "${MODULE_AVAILABILITY[$module]}" != "available" ]]; then
      SELECTION_BLOCKED=true
    fi
  done
}

show_module_selection() {
  local module state origin
  for module in "${MODULE_IDS[@]}"; do
    if [[ -n "${SELECTED_MODULE[$module]:-}" ]]; then
      state="selected"
      origin="${MODULE_SELECTION_ORIGIN[$module]}"
    elif [[ -n "${PROFILE_MODULE_ALLOWED[$module]:-}" ]]; then
      state="disabled"
      if [[ "$MODULES_ARGUMENT_SET" == true && "${PROFILE_MODULE_DEFAULT[$module]}" == "selected" ]]; then
        origin="default-overridden"
      else
        origin="default-disabled"
      fi
    else
      continue
    fi
    printf '  module: %s state=%s origin=%s availability=%s — %s\n' \
      "$module" "$state" "$origin" "${MODULE_AVAILABILITY[$module]}" "${MODULE_PURPOSE[$module]}"
  done
}

selected_modules_csv() {
  local module separator=""
  if ((${#SELECTED_MODULE_IDS[@]} == 0)); then
    printf 'none'
    return
  fi
  for module in "${SELECTED_MODULE_IDS[@]}"; do
    printf '%s%s' "$separator" "$module"
    separator=,
  done
}

ensure_selection_applyable() {
  local module
  local -a blocked_modules=()
  declare -A config_effect_modules=()
  [[ "$SELECTION_BLOCKED" != true ]] || {
    if [[ "$APPLY_CONFIG" == true ]]; then
      for module in "${CONFIG_MODULES[@]}"; do
        config_effect_modules["$module"]=1
      done
    fi
    for module in "${SELECTED_MODULE_IDS[@]}"; do
      [[ "${MODULE_AVAILABILITY[$module]}" == "available" ]] && continue
      if [[ "$APPLY_CONFIG" == true && -z "${config_effect_modules[$module]:-}" ]]; then
        continue
      fi
      blocked_modules+=("$module")
    done
    ((${#blocked_modules[@]} == 0)) || \
      die "selected modules are not executable and block apply: ${blocked_modules[*]}"
  }
}

mapping_count() {
  printf '%s' "${#CONFIG_SOURCES[@]}"
}

load_official_manifest() {
  [[ -f "$OFFICIAL_PACKAGES" ]] || die "official package manifest is missing"
  reject_symlinked_project_path "manifests/official-packages.tsv"
  require_manifest_schema "$OFFICIAL_PACKAGES" "# schema=2" "official package manifest"

  local selected_rows status module package purpose
  if selected_rows=$(LC_ALL=C awk -F '\t' -v selected="$PROFILE" '
    BEGIN { selected_count = 0; failed = 0 }
    /^[[:space:]]*$/ || /^#/ { next }
    {
      if (NF != 4 || $1 == "" || $2 == "" || $3 == "" || $4 == "") { failed = 1; exit 2 }
      if ($1 !~ /^(asus-amd-nvidia|desktop-amd|vm)$/) { failed = 1; exit 2 }
      if ($2 !~ /^[a-z0-9][a-z0-9-]*$/) { failed = 1; exit 2 }
      if ($3 !~ /^[a-z0-9@._+:-]+$/) { failed = 1; exit 2 }
      if ($4 ~ /[[:cntrl:]]/) { failed = 1; exit 2 }
      if ($1 == selected) {
        if (seen[$3]++) { failed = 1; exit 4 }
        print $2 "\t" $3 "\t" $4
        selected_count++
      }
    }
    END { if (!failed && selected_count == 0) exit 3 }
  ' "$OFFICIAL_PACKAGES"); then
    :
  else
    status=$?
    case "$status" in
      2) die_with_status "$status" "official package manifest has an invalid row (awk exit $status)" ;;
      3) die_with_status "$status" "official package manifest has no entries for profile $PROFILE (awk exit $status)" ;;
      4) die_with_status "$status" "official package manifest has a duplicate package for profile $PROFILE (awk exit $status)" ;;
      *) die_with_status "$status" "official package manifest query failed (awk exit $status)" ;;
    esac
  fi

  OFFICIAL_MODULES=()
  OFFICIAL_PACKAGE_NAMES=()
  OFFICIAL_PURPOSES=()
  while IFS=$'\t' read -r module package purpose; do
    [[ -n "$module" && -n "$package" && -n "$purpose" ]] || \
      die "internal error: validated package row could not be loaded"
    [[ -n "${MODULE_AVAILABILITY[$module]:-}" ]] || \
      die "official package manifest references unknown module: $module"
    [[ -n "${SELECTED_MODULE[$module]:-}" ]] || continue
    OFFICIAL_MODULES+=("$module")
    OFFICIAL_PACKAGE_NAMES+=("$package")
    OFFICIAL_PURPOSES+=("$purpose")
  done <<<"$selected_rows"
}

show_official_packages() {
  local index
  for index in "${!OFFICIAL_PACKAGE_NAMES[@]}"; do
    printf '  [%s] %s — %s\n' \
      "${OFFICIAL_MODULES[$index]}" \
      "${OFFICIAL_PACKAGE_NAMES[$index]}" \
      "${OFFICIAL_PURPOSES[$index]}"
  done
}

reject_symlinked_project_path() {
  local relative="$1" path="$PROJECT_DIR" component
  local -a components=()
  IFS=/ read -r -a components <<<"$relative"
  for component in "${components[@]}"; do
    path="${path}/${component}"
    [[ ! -L "$path" ]] || die "approved source path contains a symlink: $relative"
  done
}

is_allowed_user_mapping_target() {
  local target_relative="$1"
  case "$target_relative" in
    .config/*|.local/share/fcitx5/rime/*|scripts/*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

validate_mapping() {
  [[ -f "$CONFIG_MAPPING" ]] || die "configuration mapping is missing"
  reject_symlinked_project_path "manifests/config-mappings.tsv"
  require_manifest_schema "$CONFIG_MAPPING" "# schema=2" "configuration mapping manifest"
  CONFIG_MODULES=()
  CONFIG_SOURCES=()
  CONFIG_TARGETS=()
  CONFIG_MODES=()

  local config_scope module source_relative target_relative extra source source_mode status
  declare -A seen_sources=()
  declare -A seen_targets=()
  declare -A seen_config_scopes=()
  while IFS=$'\t' read -r config_scope module source_relative target_relative extra; do
    [[ -n "$config_scope" && "$config_scope" != \#* ]] || continue
    [[ -n "$module" && -n "$source_relative" && -n "$target_relative" && -z "$extra" ]] || \
      die "invalid configuration mapping entry: $config_scope"
    [[ "$config_scope" =~ ^[a-z0-9][a-z0-9-]*$ ]] || \
      die "invalid configuration scope: $config_scope"
    [[ -n "${MODULE_AVAILABILITY[$module]:-}" ]] || \
      die "configuration mapping references unknown module: $module"
    seen_config_scopes["$config_scope"]=1
    [[ "$source_relative" != /* && "$target_relative" != /* ]] || \
      die "absolute mapping path is not allowed: $source_relative"
    [[ "$source_relative" =~ ^[A-Za-z0-9._/+:-]+$ && "$target_relative" =~ ^[A-Za-z0-9._/+:-]+$ ]] || \
      die "mapping path contains unsupported or control characters: $source_relative"
    [[ "/${source_relative}/" != *"/../"* && "/${target_relative}/" != *"/../"* ]] || \
      die "parent traversal is not allowed: $source_relative"
    [[ "/${source_relative}/" != *"/./"* && "/${target_relative}/" != *"/./"* && \
      "$source_relative" != *'//'* && "$target_relative" != *'//'* ]] || \
      die "mapping path is not canonical: $source_relative"
    is_allowed_user_mapping_target "$target_relative" || die "target is outside approved user config roots: $target_relative"
    [[ "$source_relative" == "config/home/${target_relative}" || \
      "$source_relative" == "config/vm/home/${target_relative}" ]] || \
      die "source must mirror target under an approved config scope root: $source_relative -> $target_relative"
    local source_key="${config_scope}:${source_relative}" target_key="${config_scope}:${target_relative}"
    [[ -z "${seen_sources[$source_key]:-}" ]] || \
      die "duplicate configuration source in scope $config_scope: $source_relative"
    [[ -z "${seen_targets[$target_key]:-}" ]] || \
      die "duplicate configuration target in scope $config_scope: $target_relative"
    seen_sources["$source_key"]=1
    seen_targets["$target_key"]=1
    source="${PROJECT_DIR}/${source_relative}"
    reject_symlinked_project_path "$source_relative"
    [[ -f "$source" ]] || die "approved source is missing or is not a regular file: $source_relative"
    if source_mode=$(stat -c '%a' -- "$source"); then
      :
    else
      status=$?
      die_with_status "$status" "could not inspect approved source mode (stat exit $status): $source_relative"
    fi
    [[ "$source_mode" == 600 || "$source_mode" == 644 || "$source_mode" == 744 || "$source_mode" == 755 ]] || \
      die "approved source mode must be 600, 644, 744 or 755: $source_relative (mode $source_mode)"

    if [[ "$CONFIG_SCOPE" == "$config_scope" && -n "${SELECTED_MODULE[$module]:-}" ]]; then
      CONFIG_MODULES+=("$module")
      CONFIG_SOURCES+=("$source_relative")
      CONFIG_TARGETS+=("$target_relative")
      CONFIG_MODES+=("$source_mode")
    fi
  done <"$CONFIG_MAPPING"
  ((${#seen_sources[@]} > 0)) || die "configuration mapping has no deployable entries"
  if [[ "$CONFIG_SCOPE" != "none" && -z "${seen_config_scopes[$CONFIG_SCOPE]:-}" ]]; then
    die "configuration mapping has no entries for scope $CONFIG_SCOPE"
  fi
}

load_workstation_package_policy() {
  [[ -f "$WORKSTATION_PACKAGE_POLICY" ]] || die "reconciled workstation package manifest is missing"
  reject_symlinked_project_path "manifests/workstation-packages.tsv"
  require_manifest_schema "$WORKSTATION_PACKAGE_POLICY" "# schema=1" \
    "reconciled workstation package manifest"

  WORKSTATION_PACKAGE_NAMES=()
  WORKSTATION_PACKAGE_CHANNELS=()
  WORKSTATION_PACKAGE_REPOSITORIES=()
  WORKSTATION_PACKAGE_ACQUISITIONS=()
  WORKSTATION_PACKAGE_MODULES=()
  WORKSTATION_PACKAGE_POLICIES=()
  WORKSTATION_PACKAGE_ORIGINS=()
  WORKSTATION_POLICY_ROWS=0
  WORKSTATION_CURRENT_ROWS=0
  WORKSTATION_DESIRED_ROWS=0
  WORKSTATION_OFFICIAL_CANDIDATES=0
  WORKSTATION_ARCHLINUXCN_CANDIDATES=0
  WORKSTATION_ARCHLINUXCN_BOOTSTRAPS=0
  WORKSTATION_AUR_CANDIDATES=0
  WORKSTATION_PARU_BOOTSTRAPS=0

  local package channel repository acquisition module restore_mode policy origin purpose extra
  local expected_policy
  declare -A seen_packages=()
  while IFS=$'\t' read -r package channel repository acquisition module restore_mode policy origin purpose extra; do
    [[ -n "$package" && "$package" != \#* ]] || continue
    [[ -n "$channel" && -n "$repository" && -n "$acquisition" && -n "$module" && -n "$restore_mode" && \
      -n "$policy" && -n "$origin" && -n "$purpose" && -z "$extra" ]] || \
      die "invalid reconciled workstation package row: $package"
    [[ "$package" =~ ^[a-z0-9@._+:-]+$ ]] || \
      die "unsafe reconciled workstation package name: $package"
    [[ -z "${seen_packages[$package]:-}" ]] || \
      die "duplicate reconciled workstation package: $package"
    case "$channel:$repository" in
      pacman:core|pacman:extra|pacman:multilib|pacman:archlinuxcn|aur:aur) ;;
      *) die "invalid reconciled package channel/repository: $package ($channel/$repository)" ;;
    esac
    case "$acquisition" in
      pacman|archlinuxcn-bootstrap|aur-build|paru-bootstrap|verify-only|deferred) ;;
      *) die "invalid workstation package acquisition: $package ($acquisition)" ;;
    esac
    [[ -n "${MODULE_AVAILABILITY[$module]:-}" ]] || \
      die "reconciled package references unknown module: $package ($module)"
    case "$restore_mode" in
      package-only|config-backed) expected_policy="install" ;;
      manual-precondition) expected_policy="verify" ;;
      deferred) expected_policy="deferred" ;;
      *) die "invalid workstation package restore mode: $package ($restore_mode)" ;;
    esac
    [[ "$policy" == "$expected_policy" ]] || \
      die "invalid workstation package policy: $package ($policy)"
    if [[ "$policy" == verify && "$acquisition" != verify-only ]]; then
      die "invalid workstation package acquisition: $package ($acquisition)"
    fi
    if [[ "$policy" == deferred && "$acquisition" != deferred ]]; then
      die "invalid workstation package acquisition: $package ($acquisition)"
    fi
    if [[ "$policy" == install && "$channel:$repository" =~ ^pacman:(core|extra|multilib)$ && "$acquisition" != pacman ]]; then
      die "invalid workstation package acquisition: $package ($acquisition)"
    fi
    if [[ "$policy" == install && "$channel" == aur && "$acquisition" != aur-build && "$acquisition" != paru-bootstrap ]]; then
      die "invalid workstation package acquisition: $package ($acquisition)"
    fi
    case "$origin" in
      current-explicit) ((WORKSTATION_CURRENT_ROWS += 1)) ;;
      confirmed-desired) ((WORKSTATION_DESIRED_ROWS += 1)) ;;
      *) die "invalid workstation package origin: $package ($origin)" ;;
    esac
    seen_packages["$package"]=1
    ((WORKSTATION_POLICY_ROWS += 1))

    # Deferred evidence remains visible even though the unavailable greeter module
    # is deliberately not exposed by an executable profile.
    if [[ "$policy" != deferred && -z "${SELECTED_MODULE[$module]:-}" ]]; then
      continue
    fi
    WORKSTATION_PACKAGE_NAMES+=("$package")
    WORKSTATION_PACKAGE_CHANNELS+=("$channel")
    WORKSTATION_PACKAGE_REPOSITORIES+=("$repository")
    WORKSTATION_PACKAGE_ACQUISITIONS+=("$acquisition")
    WORKSTATION_PACKAGE_MODULES+=("$module")
    WORKSTATION_PACKAGE_POLICIES+=("$policy")
    WORKSTATION_PACKAGE_ORIGINS+=("$origin")
    if [[ "$policy" == install ]]; then
      case "$acquisition" in
        pacman)
          if [[ "$repository" == archlinuxcn ]]; then
            ((WORKSTATION_ARCHLINUXCN_CANDIDATES += 1))
          else
            ((WORKSTATION_OFFICIAL_CANDIDATES += 1))
          fi
          ;;
        archlinuxcn-bootstrap)
          ((WORKSTATION_ARCHLINUXCN_BOOTSTRAPS += 1))
          ;;
        aur-build)
          ((WORKSTATION_AUR_CANDIDATES += 1))
          ;;
        paru-bootstrap)
          ((WORKSTATION_PARU_BOOTSTRAPS += 1))
          ;;
      esac
    fi
  done <"$WORKSTATION_PACKAGE_POLICY"
  ((WORKSTATION_POLICY_ROWS > 0)) || \
    die "reconciled workstation package manifest has no package rows"
  ((WORKSTATION_CURRENT_ROWS == 180)) || \
    die "reconciled workstation package manifest does not cover 180 current explicit packages"
  ((WORKSTATION_DESIRED_ROWS > 0)) || \
    die "reconciled workstation package manifest has no confirmed desired packages"
}

show_workstation_packages() {
  local index
  for index in "${!WORKSTATION_PACKAGE_NAMES[@]}"; do
    printf '    [%s/%s/%s/%s/%s] %s\n' \
      "${WORKSTATION_PACKAGE_POLICIES[$index]}" \
      "${WORKSTATION_PACKAGE_CHANNELS[$index]}" \
      "${WORKSTATION_PACKAGE_REPOSITORIES[$index]}" \
      "${WORKSTATION_PACKAGE_ACQUISITIONS[$index]}" \
      "${WORKSTATION_PACKAGE_MODULES[$index]}" \
      "${WORKSTATION_PACKAGE_NAMES[$index]}"
  done
}

show_workstation_package_plan() {
  if [[ "$PROFILE" != asus-amd-nvidia ]]; then
    printf '  workstation package reconciliation: selected secondary-profile rows only\n'
  else
    printf '  workstation package reconciliation: %s policy row(s) (%s current + %s confirmed desired), review only\n' \
      "$WORKSTATION_POLICY_ROWS" "$WORKSTATION_CURRENT_ROWS" "$WORKSTATION_DESIRED_ROWS"
  fi
  cat <<EOF
  workstation install candidates: official=${WORKSTATION_OFFICIAL_CANDIDATES} archlinuxcn=${WORKSTATION_ARCHLINUXCN_CANDIDATES} archlinuxcn-bootstrap=${WORKSTATION_ARCHLINUXCN_BOOTSTRAPS} AUR=${WORKSTATION_AUR_CANDIDATES} paru-bootstrap=${WORKSTATION_PARU_BOOTSTRAPS}
  selected package/config responsibility set:
$(show_workstation_packages)
  workstation policy apply integration: pending separate trust-domain stages and approval
EOF
}

show_config_targets() {
  local index
  for index in "${!CONFIG_SOURCES[@]}"; do
    printf '  [%s] %s -> %s\n' \
      "${CONFIG_MODULES[$index]}" "${CONFIG_SOURCES[$index]}" "${CONFIG_TARGETS[$index]}"
  done
}

show_plan() {
  local readiness
  if [[ "$SELECTION_BLOCKED" == true ]]; then
    readiness="blocked by non-executable selected modules"
  else
    readiness="ready for implemented component actions"
  fi
  cat <<EOF

Plan (read-only module selection)
  profile: $PROFILE
  configuration scope: $CONFIG_SCOPE
  module selection source: $MODULE_SELECTION_SOURCE
  selected modules: $(selected_modules_csv)
  module states:
$(show_module_selection)
  apply readiness: $readiness
  system update: \`--apply-official\` would run sudo pacman -Syu
  configuration targets: $(mapping_count) audited file mapping(s)
  configuration target set:
$(show_config_targets)
  official packages: ${#OFFICIAL_PACKAGE_NAMES[@]} reviewed package(s), not installed in plan mode
  official package set:
$(show_official_packages)
$(show_workstation_package_plan)
  orchestrated stages:
    official-packages: $([[ ${#OFFICIAL_PACKAGE_NAMES[@]} -gt 0 ]] && printf planned || printf not-applicable)
    user-config: $([[ "$CONFIG_SCOPE" != none && ${#CONFIG_SOURCES[@]} -gt 0 ]] && printf planned || printf not-applicable)
  AUR: disabled
  archlinuxcn: disabled
  DMS fixed-source build: unavailable (selected DMS modules block apply)
  service changes: none
  filesystem writes: none

No system, installer-state, or user-configuration changes were made.
EOF
}

precheck_official_packages() {
  ((${#OFFICIAL_PACKAGE_NAMES[@]} > 0)) || die "no official packages are selected for this component action"
  local status package
  if ROOT_AVAILABLE_KIB=$(df -Pk / | awk 'NR == 2 { print $4 }'); then
    :
  else
    status=$?
    die_with_status "$status" "root filesystem free-space query failed (exit $status)"
  fi
  [[ "$ROOT_AVAILABLE_KIB" =~ ^[0-9]+$ ]] || die "root filesystem free-space query returned an empty or invalid result"
  ((ROOT_AVAILABLE_KIB >= 5 * 1024 * 1024)) || die "less than the 5 GiB minimum free space is available on /"
  command -v getent >/dev/null || die "getent is required to check DNS"
  command -v tee >/dev/null || die "tee is required to retain the apply log"
  if getent ahosts archlinux.org >/dev/null; then
    :
  else
    status=$?
    die_with_status "$status" "DNS resolution query failed (getent exit $status)"
  fi

  for package in "${OFFICIAL_PACKAGE_NAMES[@]}"; do
    if pacman -Si -- "$package" >/dev/null 2>&1; then
      :
    else
      status=$?
      die_with_status "$status" "official package availability query failed for $package (pacman exit $status)"
    fi
  done
  OFFICIAL_PREFLIGHT_COMPLETE=true
}

apply_official_packages() {
  if [[ "$OFFICIAL_PREFLIGHT_COMPLETE" != true ]]; then
    precheck_official_packages
  fi
  local status package root_available_kib="$ROOT_AVAILABLE_KIB"
  printf 'Official package installation will perform: sudo pacman -Syu\n'
  printf 'Then it will install these explicit official packages with --needed:\n'
  show_official_packages
  printf 'Available root filesystem space: %s MiB (minimum: 5120 MiB)\n' "$((root_available_kib / 1024))"
  if [[ "$ORCHESTRATED_CONFIRMATIONS" == true ]]; then
    printf 'System-change confirmation recorded by the orchestrator.\n'
  elif [[ "$CONFIRM_SYSTEM_CHANGES" == true ]]; then
    printf 'Confirmation supplied by --confirm-system-changes.\n'
  else
    local confirmation=""
    IFS= read -r -p 'Type apply-system-changes to continue: ' confirmation || true
    [[ "$confirmation" == "apply-system-changes" ]] || die "official package installation cancelled"
  fi

  prepare_state
  local log_timestamp
  log_timestamp=$(date -u +%Y%m%dT%H%M%SZ)
  APPLY_LOG=$(mktemp "${LOG_DIR}/official-packages-${PROFILE}-${log_timestamp}-XXXXXX.log")
  chmod 600 "$APPLY_LOG"
  {
    printf 'schema=1\n'
    printf 'action=official-packages\n'
    printf 'profile=%s\n' "$PROFILE"
    printf 'started_at=%s\n' "$log_timestamp"
    printf 'root_available_mib=%s\n' "$((root_available_kib / 1024))"
    local selected_module_id
    for selected_module_id in "${SELECTED_MODULE_IDS[@]}"; do
      printf 'module=%s\n' "$selected_module_id"
    done
    for package in "${OFFICIAL_PACKAGE_NAMES[@]}"; do
      printf 'package=%s\n' "$package"
    done
  } >>"$APPLY_LOG"
  printf 'Apply log: %s\n' "$APPLY_LOG"

  run_checked "sudo -v" sudo -v
  run_checked "sudo pacman -Syu" sudo pacman -Syu
  run_checked "sudo pacman -S --needed" sudo pacman -S --needed "${OFFICIAL_PACKAGE_NAMES[@]}"

  local inventory
  if inventory=$(pacman -Q "${OFFICIAL_PACKAGE_NAMES[@]}"); then
    :
  else
    status=$?
    die_with_status "$status" "post-install inventory query pacman -Q failed with exit $status"
  fi
  [[ -n "$inventory" ]] || die "post-install inventory query returned an empty result"

  local state_file="${STATE_DIR}/official-package-state" state_tmp applied_at
  applied_at=$(date -u +%Y%m%dT%H%M%SZ)
  state_tmp=$(mktemp "${STATE_DIR}/.official-package-state.XXXXXX")
  if {
    printf 'schema=1 profile=%s applied_at=%s\n' "$PROFILE" "$applied_at"
    printf 'modules=%s\n' "$(selected_modules_csv)"
    printf '%s\n' "$inventory"
  } >"$state_tmp" && chmod 600 "$state_tmp" && mv -f -- "$state_tmp" "$state_file"; then
    :
  else
    status=$?
    rm -f -- "$state_tmp"
    die_with_status "$status" "could not write official package state (exit $status)"
  fi
  log_apply_line "completed_at=$applied_at"
  log_apply_line "result: completed"
  printf 'Official package installation completed. Service/login configuration remains unchanged.\n'
}

backup_target() {
  local target="$1" backup_root="$2"
  local relative="${target#"$HOME/"}"
  mkdir -p "${backup_root}/$(dirname -- "$relative")"
  cp -a -- "$target" "${backup_root}/${relative}"
}

reject_symlinked_target_path() {
  local target="$1" path="$HOME" relative_component link_count status
  local relative="${target#"$HOME/"}"
  local -a relative_components=()

  [[ "$target" == "$HOME/"* ]] || die "target is outside HOME: $target"
  is_allowed_user_mapping_target "$relative" || die "target is outside approved user config roots: $relative"
  [[ ! -L "$path" ]] || die "refusing to manage HOME through a symlink: $path"
  IFS=/ read -r -a relative_components <<<"$relative"
  for relative_component in "${relative_components[@]}"; do
    path="${path}/${relative_component}"
    [[ ! -L "$path" ]] || die "refusing to write through a symlinked user config target: $path"
  done

  if [[ -e "$target" ]]; then
    [[ -f "$target" ]] || die "refusing to replace a non-regular user config target: $target"
    if link_count=$(stat -c '%h' -- "$target"); then
      :
    else
      status=$?
      die_with_status "$status" "could not inspect user config target link count (stat exit $status): $target"
    fi
    [[ "$link_count" =~ ^[0-9]+$ ]] || die "invalid link count reported for user config target: $target"
    ((link_count == 1)) || die "refusing to replace a hard-linked user config target: $target"
  fi
}

precheck_config_targets() {
  [[ "$CONFIG_SCOPE" != "none" ]] || die "profile $PROFILE intentionally has no approved configuration scope"
  ((${#CONFIG_SOURCES[@]} > 0)) || die "no configuration targets are selected for this component action"
  local index
  for index in "${!CONFIG_SOURCES[@]}"; do
    reject_symlinked_target_path "${HOME}/${CONFIG_TARGETS[$index]}"
  done
}

deploy_config() {
  precheck_config_targets

  local timestamp backup_root=""
  timestamp=$(date -u +%Y%m%dT%H%M%SZ)

  printf 'Configuration deployment (%s mode) will manage these exact targets:\n' "$MODE"
  show_config_targets
  printf 'Any existing changed targets will be backed up under: %s\n' "$BACKUP_DIR"
  if [[ "$ORCHESTRATED_CONFIRMATIONS" == true ]]; then
    printf 'Config confirmation recorded by the orchestrator.\n'
  elif [[ "$CONFIRM_CONFIG" == true ]]; then
    printf 'Confirmation supplied by --confirm-config.\n'
  else
    local confirmation=""
    IFS= read -r -p 'Type apply-config to continue: ' confirmation || true
    [[ "$confirmation" == "apply-config" ]] || die "configuration deployment cancelled"
  fi

  local source_relative target_relative target source source_mode target_mode status index

  prepare_state
  for index in "${!CONFIG_SOURCES[@]}"; do
    source_relative=${CONFIG_SOURCES[$index]}
    target_relative=${CONFIG_TARGETS[$index]}
    source_mode=${CONFIG_MODES[$index]}
    source="${PROJECT_DIR}/${source_relative}"
    reject_symlinked_project_path "$source_relative"
    target="${HOME}/${target_relative}"
    [[ -f "$source" ]] || die "approved source is missing: $source_relative"
    reject_symlinked_target_path "$target"

    if [[ -e "$target" ]]; then
      if target_mode=$(stat -c '%a' -- "$target"); then
        :
      else
        status=$?
        die_with_status "$status" "could not inspect config target mode (stat exit $status): $target"
      fi
      if cmp -s -- "$source" "$target" && [[ "$target_mode" == "$source_mode" ]]; then
        printf 'config: unchanged %s\n' "$target_relative"
        continue
      fi
      if [[ -z "$backup_root" ]]; then
        backup_root=$(mktemp -d "${BACKUP_DIR}/${timestamp}-config-${PROFILE}-XXXXXX")
        chmod 700 "$backup_root"
        printf 'config: backup root %s\n' "$backup_root"
      fi
      backup_target "$target" "$backup_root"
      printf 'config: backed up %s\n' "$target_relative"
    fi
    mkdir -p "$(dirname -- "$target")"
    install -m "$source_mode" -- "$source" "$target"
    printf 'config: deployed %s\n' "$target_relative"
  done

  local config_state="${STATE_DIR}/config-state" config_state_tmp
  config_state_tmp=$(mktemp "${STATE_DIR}/.config-state.XXXXXX")
  {
    printf '%s\n' "schema=1 profile=${PROFILE} mode=${MODE} applied_at=${timestamp}"
    printf 'modules=%s\n' "$(selected_modules_csv)"
  } >"$config_state_tmp"
  chmod 600 "$config_state_tmp"
  mv -f -- "$config_state_tmp" "$config_state"
  printf 'Configuration deployment completed. Re-login if your session does not pick up environment changes.\n'
}

set_now() {
  local status
  if NOW=$(date -u +%Y%m%dT%H%M%SZ); then
    :
  else
    status=$?
    die_with_status "$status" "UTC timestamp query failed (date exit $status)"
  fi
  [[ "$NOW" =~ ^[0-9]{8}T[0-9]{6}Z$ ]] || die "UTC timestamp query returned an invalid result"
}

run_log_line() {
  [[ -n "$RUN_LOG" ]] || die "internal error: orchestrator log is not initialized"
  printf '%s\n' "$*" >>"$RUN_LOG"
}

compute_plan_fingerprint() {
  local fingerprint status index
  command -v sha256sum >/dev/null || die "sha256sum is required for resumable plan state"
  if fingerprint=$(
    {
      printf 'profile=%s\nmode=%s\nmodules=%s\n' "$PROFILE" "$MODE" "$(selected_modules_csv)"
      sha256sum -- \
        "${SCRIPT_DIR}/install.sh" \
        "$MODULE_REGISTRY" \
        "$PROFILE_MODULES_MANIFEST" \
        "$OFFICIAL_PACKAGES" \
        "$CONFIG_MAPPING"
      for index in "${!CONFIG_SOURCES[@]}"; do
        sha256sum -- "${PROJECT_DIR}/${CONFIG_SOURCES[$index]}"
      done
    } | sha256sum | awk '{ print $1 }'
  ); then
    :
  else
    status=$?
    die_with_status "$status" "plan fingerprint query failed with exit $status"
  fi
  [[ "$fingerprint" =~ ^[0-9a-f]{64}$ ]] || die "plan fingerprint query returned an empty or invalid result"
  RUN_FINGERPRINT="$fingerprint"
}

require_private_regular_file() {
  local path="$1" label="$2" links mode status
  [[ ! -L "$path" ]] || die "$label must not be a symlink: $path"
  [[ -f "$path" ]] || die "$label is missing or not a regular file: $path"
  if links=$(stat -c '%h' -- "$path") && mode=$(stat -c '%a' -- "$path"); then
    :
  else
    status=$?
    die_with_status "$status" "could not inspect $label (stat exit $status): $path"
  fi
  [[ "$links" == 1 ]] || die "$label must not be hard-linked: $path"
  [[ "$mode" == 600 ]] || die "$label must be mode 600: $path"
}

validate_existing_run_paths() {
  [[ ! -L "$STATE_DIR" ]] || die "refusing to use a symlinked installer state directory: $STATE_DIR"
  [[ ! -e "$STATE_DIR" || -d "$STATE_DIR" ]] || die "installer state path is not a directory: $STATE_DIR"
  [[ ! -L "$RUNS_DIR" ]] || die "refusing to use a symlinked installer runs directory: $RUNS_DIR"
  [[ ! -e "$RUNS_DIR" || -d "$RUNS_DIR" ]] || die "installer runs path is not a directory: $RUNS_DIR"
  if [[ -e "$LATEST_RUN_FILE" || -L "$LATEST_RUN_FILE" ]]; then
    require_private_regular_file "$LATEST_RUN_FILE" "latest run pointer"
  fi
}

read_latest_run_id() {
  LATEST_RUN_ID=""
  [[ -e "$LATEST_RUN_FILE" || -L "$LATEST_RUN_FILE" ]] || return 1
  require_private_regular_file "$LATEST_RUN_FILE" "latest run pointer"
  if IFS= read -r LATEST_RUN_ID <"$LATEST_RUN_FILE"; then
    :
  else
    local status=$?
    die_with_status "$status" "latest run pointer query failed with exit $status"
  fi
  [[ "$LATEST_RUN_ID" =~ ^[A-Za-z0-9._-]+$ ]] || die "latest run pointer contains an invalid run id"
}

load_run_state() {
  local requested_id="$1" state_file stored_run_log key value extra schema="" links mode status required
  declare -A seen_keys=()
  [[ "$requested_id" =~ ^[A-Za-z0-9._-]+$ ]] || die "invalid stored run id: $requested_id"
  RUN_ID="$requested_id"
  RUN_PATH="${RUNS_DIR}/${RUN_ID}"
  [[ ! -L "$RUN_PATH" ]] || die "stored run directory must not be a symlink: $RUN_PATH"
  [[ -d "$RUN_PATH" ]] || die "stored run directory is missing: $RUN_PATH"
  if mode=$(stat -c '%a' -- "$RUN_PATH"); then
    :
  else
    status=$?
    die_with_status "$status" "could not inspect stored run directory (stat exit $status)"
  fi
  [[ "$mode" == 700 ]] || die "stored run directory must be mode 700: $RUN_PATH"

  state_file="${RUN_PATH}/state"
  stored_run_log="${RUN_PATH}/run.log"
  require_private_regular_file "$state_file" "orchestrator state"
  require_private_regular_file "$stored_run_log" "orchestrator log"
  RUN_LOG=""

  RUN_PROFILE=""
  RUN_MODE=""
  RUN_MODULES=""
  RUN_FINGERPRINT=""
  RUN_STATUS=""
  RUN_ATTEMPT=0
  RUN_RETRY_MODULE="none"
  RUN_STARTED_AT=""
  RUN_UPDATED_AT=""
  RUN_FAILED_STAGE="none"
  RUN_FAILURE_STATUS=0
  RUN_STAGE_STATUS=()

  while IFS='=' read -r key value extra; do
    [[ -n "$key" && -n "$value" && -z "$extra" ]] || die "orchestrator state contains an invalid row"
    [[ -z "${seen_keys[$key]:-}" ]] || die "orchestrator state repeats key: $key"
    seen_keys["$key"]=1
    case "$key" in
      schema) schema="$value" ;;
      run_id) [[ "$value" == "$RUN_ID" ]] || die "orchestrator state run id mismatch" ;;
      profile) RUN_PROFILE="$value" ;;
      mode) RUN_MODE="$value" ;;
      modules) RUN_MODULES="$value" ;;
      fingerprint) RUN_FINGERPRINT="$value" ;;
      status) RUN_STATUS="$value" ;;
      attempt) RUN_ATTEMPT="$value" ;;
      retry_module) RUN_RETRY_MODULE="$value" ;;
      started_at) RUN_STARTED_AT="$value" ;;
      updated_at) RUN_UPDATED_AT="$value" ;;
      failed_stage) RUN_FAILED_STAGE="$value" ;;
      failure_status) RUN_FAILURE_STATUS="$value" ;;
      stage_official-packages) RUN_STAGE_STATUS[official-packages]="$value" ;;
      stage_user-config) RUN_STAGE_STATUS[user-config]="$value" ;;
      *) die "orchestrator state contains unknown key: $key" ;;
    esac
  done <"$state_file"

  for required in schema run_id profile mode modules fingerprint status attempt retry_module \
    started_at updated_at failed_stage failure_status stage_official-packages stage_user-config; do
    [[ -n "${seen_keys[$required]:-}" ]] || die "orchestrator state is missing key: $required"
  done
  [[ "$schema" == 1 ]] || die "unsupported orchestrator state schema: $schema"
  case "$RUN_PROFILE" in asus-amd-nvidia|desktop-amd|vm) ;; *) die "invalid stored run profile" ;; esac
  case "$RUN_MODE" in new|reconcile) ;; *) die "invalid stored run mode" ;; esac
  [[ "$RUN_MODULES" == none || "$RUN_MODULES" =~ ^[a-z0-9][a-z0-9-]*(,[a-z0-9][a-z0-9-]*)*$ ]] || \
    die "invalid stored run module list"
  [[ "$RUN_FINGERPRINT" =~ ^[0-9a-f]{64}$ ]] || die "invalid stored run fingerprint"
  case "$RUN_STATUS" in running|failed|completed) ;; *) die "invalid stored run status" ;; esac
  [[ "$RUN_ATTEMPT" =~ ^[1-9][0-9]*$ ]] || die "invalid stored run attempt"
  [[ "$RUN_RETRY_MODULE" == none || "$RUN_RETRY_MODULE" =~ ^[a-z0-9][a-z0-9-]*$ ]] || \
    die "invalid stored retry module"
  [[ "$RUN_STARTED_AT" =~ ^[0-9]{8}T[0-9]{6}Z$ && "$RUN_UPDATED_AT" =~ ^[0-9]{8}T[0-9]{6}Z$ ]] || \
    die "invalid stored run timestamp"
  case "$RUN_FAILED_STAGE" in none|official-packages|user-config) ;; *) die "invalid stored failed stage" ;; esac
  if [[ ! "$RUN_FAILURE_STATUS" =~ ^[0-9]+$ ]] || ((RUN_FAILURE_STATUS > 255)); then
    die "invalid stored failure status"
  fi
  for key in official-packages user-config; do
    case "${RUN_STAGE_STATUS[$key]:-}" in
      pending|running|passed|failed|skipped|not-applicable) ;;
      *) die "invalid stored stage status for $key" ;;
    esac
  done
}

write_run_state() {
  local state_file="${RUN_PATH}/state" state_tmp status
  set_now
  RUN_UPDATED_AT="$NOW"
  state_tmp=$(mktemp "${RUN_PATH}/.state.XXXXXX")
  if {
    printf 'schema=1\n'
    printf 'run_id=%s\n' "$RUN_ID"
    printf 'profile=%s\n' "$RUN_PROFILE"
    printf 'mode=%s\n' "$RUN_MODE"
    printf 'modules=%s\n' "$RUN_MODULES"
    printf 'fingerprint=%s\n' "$RUN_FINGERPRINT"
    printf 'status=%s\n' "$RUN_STATUS"
    printf 'attempt=%s\n' "$RUN_ATTEMPT"
    printf 'retry_module=%s\n' "$RUN_RETRY_MODULE"
    printf 'started_at=%s\n' "$RUN_STARTED_AT"
    printf 'updated_at=%s\n' "$RUN_UPDATED_AT"
    printf 'failed_stage=%s\n' "$RUN_FAILED_STAGE"
    printf 'failure_status=%s\n' "$RUN_FAILURE_STATUS"
    printf 'stage_official-packages=%s\n' "${RUN_STAGE_STATUS[official-packages]}"
    printf 'stage_user-config=%s\n' "${RUN_STAGE_STATUS[user-config]}"
  } >"$state_tmp" && chmod 600 "$state_tmp" && mv -f -- "$state_tmp" "$state_file"; then
    :
  else
    status=$?
    rm -f -- "$state_tmp"
    die_with_status "$status" "could not write orchestrator state (exit $status)"
  fi
}

write_latest_run_pointer() {
  local latest_tmp status
  if [[ -e "$LATEST_RUN_FILE" || -L "$LATEST_RUN_FILE" ]]; then
    require_private_regular_file "$LATEST_RUN_FILE" "latest run pointer"
  fi
  latest_tmp=$(mktemp "${STATE_DIR}/.latest-run.XXXXXX")
  if printf '%s\n' "$RUN_ID" >"$latest_tmp" && chmod 600 "$latest_tmp" && \
    mv -f -- "$latest_tmp" "$LATEST_RUN_FILE"; then
    :
  else
    status=$?
    rm -f -- "$latest_tmp"
    die_with_status "$status" "could not write latest run pointer (exit $status)"
  fi
}

create_new_run() {
  local run_template
  prepare_state
  ensure_private_directory "$RUNS_DIR"
  set_now
  RUN_STARTED_AT="$NOW"
  run_template="${RUNS_DIR}/${RUN_STARTED_AT}-${PROFILE}-XXXXXX"
  RUN_PATH=$(mktemp -d "$run_template")
  chmod 700 "$RUN_PATH"
  RUN_ID=$(basename -- "$RUN_PATH")
  [[ "$RUN_ID" =~ ^[A-Za-z0-9._-]+$ ]] || die "generated run id is invalid"
  RUN_LOG="${RUN_PATH}/run.log"
  : >"$RUN_LOG"
  chmod 600 "$RUN_LOG"
  RUN_PROFILE="$PROFILE"
  RUN_MODE="$MODE"
  RUN_MODULES="$(selected_modules_csv)"
  RUN_STATUS="running"
  RUN_ATTEMPT=1
  RUN_RETRY_MODULE="none"
  RUN_FAILED_STAGE="none"
  RUN_FAILURE_STATUS=0
  if ((${#OFFICIAL_PACKAGE_NAMES[@]} > 0)); then
    RUN_STAGE_STATUS[official-packages]="pending"
  else
    RUN_STAGE_STATUS[official-packages]="not-applicable"
  fi
  if [[ "$CONFIG_SCOPE" != "none" ]] && ((${#CONFIG_SOURCES[@]} > 0)); then
    RUN_STAGE_STATUS[user-config]="pending"
  else
    RUN_STAGE_STATUS[user-config]="not-applicable"
  fi
  write_run_state
  write_latest_run_pointer
  run_log_line "schema=1 run_id=$RUN_ID profile=$RUN_PROFILE mode=$RUN_MODE modules=$RUN_MODULES"
  run_log_line "attempt=1 action=$RUN_CONTEXT_ACTION started_at=$RUN_STARTED_AT"
}

module_has_stage_effect() {
  local module="$1" stage="$2" index
  case "$stage" in
    official-packages)
      for index in "${!OFFICIAL_MODULES[@]}"; do
        [[ "${OFFICIAL_MODULES[$index]}" != "$module" ]] || return 0
      done
      ;;
    user-config)
      for index in "${!CONFIG_MODULES[@]}"; do
        [[ "${CONFIG_MODULES[$index]}" != "$module" ]] || return 0
      done
      ;;
    *) return 1 ;;
  esac
  return 1
}

matching_loaded_run() {
  [[ "$RUN_PROFILE" == "$PROFILE" && "$RUN_MODE" == "$MODE" && \
    "$RUN_MODULES" == "$(selected_modules_csv)" && "$RUN_FINGERPRINT" == "$1" ]]
}

prepare_run_context() {
  local current_fingerprint candidate_stage="none"
  ((${#OFFICIAL_PACKAGE_NAMES[@]} > 0 || ${#CONFIG_SOURCES[@]} > 0)) || \
    die "the selected modules have no implemented package or config stages"
  compute_plan_fingerprint
  current_fingerprint="$RUN_FINGERPRINT"
  validate_existing_run_paths

  if read_latest_run_id; then
    load_run_state "$LATEST_RUN_ID"
    if matching_loaded_run "$current_fingerprint"; then
      if [[ -n "$RETRY_MODULE" ]]; then
        [[ "$RUN_STATUS" == "failed" || "$RUN_STATUS" == "running" ]] || \
          die "the latest matching run is not failed or interrupted; use --rerun"
        [[ -n "${SELECTED_MODULE[$RETRY_MODULE]:-}" ]] || \
          die "retry module is not selected by the current plan: $RETRY_MODULE"
        if [[ "$RUN_FAILED_STAGE" != "none" ]]; then
          candidate_stage="$RUN_FAILED_STAGE"
        elif [[ "${RUN_STAGE_STATUS[official-packages]}" != "passed" && \
          "${RUN_STAGE_STATUS[official-packages]}" != "not-applicable" ]]; then
          candidate_stage="official-packages"
        elif [[ "${RUN_STAGE_STATUS[user-config]}" != "passed" && \
          "${RUN_STAGE_STATUS[user-config]}" != "not-applicable" ]]; then
          candidate_stage="user-config"
        elif [[ "$RUN_STATUS" == "running" && \
          "${RUN_STAGE_STATUS[user-config]}" != "not-applicable" ]]; then
          candidate_stage="user-config"
        elif [[ "$RUN_STATUS" == "running" && \
          "${RUN_STAGE_STATUS[official-packages]}" != "not-applicable" ]]; then
          candidate_stage="official-packages"
        fi
        [[ "$candidate_stage" != "none" ]] || die "could not identify a retryable failed stage"
        module_has_stage_effect "$RETRY_MODULE" "$candidate_stage" || \
          die "retry module $RETRY_MODULE has no effect in failed stage $candidate_stage"
        RUN_CONTEXT_ACTION="retry"
        RUN_RESUME_STAGE="$candidate_stage"
        RUN_FINGERPRINT="$current_fingerprint"
        return
      fi
      if [[ "$RERUN" == true ]]; then
        RUN_CONTEXT_ACTION="rerun"
        RUN_FINGERPRINT="$current_fingerprint"
        return
      fi
      if [[ "$RUN_STATUS" == "completed" ]]; then
        die "the latest matching plan is already completed; use --rerun for an intentional rerun"
      fi
      die "the latest matching plan is incomplete; use --retry <module> or --rerun"
    fi
    [[ -z "$RETRY_MODULE" ]] || die "latest run does not match the current profile, modules, mode, and plan fingerprint"
    [[ "$RERUN" != true ]] || die "no matching prior run exists for --rerun"
  else
    [[ -z "$RETRY_MODULE" ]] || die "no prior run exists for --retry"
    [[ "$RERUN" != true ]] || die "no prior run exists for --rerun"
  fi

  RUN_CONTEXT_ACTION="new"
  RUN_FINGERPRINT="$current_fingerprint"
}

confirm_orchestrated_apply() {
  show_plan
  command -v tee >/dev/null || die "tee is required to retain the orchestrator log"
  if ((${#OFFICIAL_PACKAGE_NAMES[@]} > 0)); then
    precheck_official_packages
  fi
  if [[ "$CONFIG_SCOPE" != "none" ]] && ((${#CONFIG_SOURCES[@]} > 0)); then
    precheck_config_targets
  fi

  printf 'All applicable confirmations are collected before run state or stage writes.\n'
  if ((${#OFFICIAL_PACKAGE_NAMES[@]} > 0)); then
    if [[ "$CONFIRM_SYSTEM_CHANGES" == true ]]; then
      printf 'Confirmation supplied by --confirm-system-changes.\n'
    else
      local system_confirmation=""
      IFS= read -r -p 'Type apply-system-changes to approve the package stage: ' system_confirmation || true
      [[ "$system_confirmation" == "apply-system-changes" ]] || die "official package installation cancelled"
    fi
  fi
  if [[ "$CONFIG_SCOPE" != "none" ]] && ((${#CONFIG_SOURCES[@]} > 0)); then
    if [[ "$CONFIRM_CONFIG" == true ]]; then
      printf 'Confirmation supplied by --confirm-config.\n'
    else
      local config_confirmation=""
      IFS= read -r -p 'Type apply-config to approve the config stage: ' config_confirmation || true
      [[ "$config_confirmation" == "apply-config" ]] || die "configuration deployment cancelled"
    fi
  fi
  ORCHESTRATED_CONFIRMATIONS=true
}

resume_run_after_confirmation() {
  RUN_LOG="${RUN_PATH}/run.log"
  require_private_regular_file "$RUN_LOG" "orchestrator log"
  RUN_STATUS="running"
  ((RUN_ATTEMPT += 1))
  RUN_RETRY_MODULE="$RETRY_MODULE"
  RUN_FAILED_STAGE="none"
  RUN_FAILURE_STATUS=0
  case "$RUN_RESUME_STAGE" in
    official-packages)
      RUN_STAGE_STATUS[official-packages]="pending"
      if [[ "${RUN_STAGE_STATUS[user-config]}" != "not-applicable" ]]; then
        RUN_STAGE_STATUS[user-config]="pending"
      fi
      ;;
    user-config)
      RUN_STAGE_STATUS[user-config]="pending"
      ;;
    *) die "internal error: invalid resume stage $RUN_RESUME_STAGE" ;;
  esac
  write_run_state
  run_log_line "attempt=$RUN_ATTEMPT action=retry module=$RETRY_MODULE resumed_stage=$RUN_RESUME_STAGE"
}

initialize_or_resume_run() {
  case "$RUN_CONTEXT_ACTION" in
    new|rerun) create_new_run ;;
    retry) resume_run_after_confirmation ;;
    *) die "internal error: unknown run context action $RUN_CONTEXT_ACTION" ;;
  esac
}

verify_official_stage() {
  local inventory status
  ((${#OFFICIAL_PACKAGE_NAMES[@]} > 0)) || return 0
  if inventory=$(pacman -Q "${OFFICIAL_PACKAGE_NAMES[@]}"); then
    :
  else
    status=$?
    printf 'error: package stage verification query failed with exit %s\n' "$status" >&2
    return "$status"
  fi
  [[ -n "$inventory" ]] || {
    printf 'error: package stage verification returned an empty result\n' >&2
    return 1
  }
}

verify_config_stage() {
  local index source target
  ((${#CONFIG_SOURCES[@]} > 0)) || return 0
  for index in "${!CONFIG_SOURCES[@]}"; do
    source="${PROJECT_DIR}/${CONFIG_SOURCES[$index]}"
    target="${HOME}/${CONFIG_TARGETS[$index]}"
    reject_symlinked_target_path "$target"
    [[ -f "$target" ]] || die "config stage verification found a missing target: ${CONFIG_TARGETS[$index]}"
    cmp -s -- "$source" "$target" || die "config stage verification found changed content: ${CONFIG_TARGETS[$index]}"
  done
}

verify_stage() {
  case "$1" in
    official-packages) verify_official_stage ;;
    user-config) verify_config_stage ;;
    *) die "internal error: unknown stage verifier: $1" ;;
  esac
}

execute_stage_command() {
  case "$1" in
    official-packages) apply_official_packages ;;
    user-config) deploy_config ;;
    *) die "internal error: unknown stage command: $1" ;;
  esac
}

execute_stage_with_log() (
  local stage="$1" run_log_path="$RUN_LOG" command_status log_status
  local -a pipeline_status=()
  [[ -n "$run_log_path" ]] || {
    printf 'error: orchestrator log is not initialized\n' >&2
    exit 1
  }
  set +e
  RUN_LOG="" execute_stage_command "$stage" 2>&1 | tee -a -- "$run_log_path"
  pipeline_status=("${PIPESTATUS[@]}")
  command_status=${pipeline_status[0]}
  log_status=${pipeline_status[1]}
  if ((log_status != 0)); then
    printf 'error: orchestrator log write failed with exit %s\n' "$log_status" >&2
    exit "$log_status"
  fi
  exit "$command_status"
)

mark_stage_failure() {
  local stage="$1" failure_status="$2"
  RUN_STAGE_STATUS["$stage"]="failed"
  RUN_STATUS="failed"
  RUN_FAILED_STAGE="$stage"
  RUN_FAILURE_STATUS="$failure_status"
  if [[ "$stage" == "official-packages" && "${RUN_STAGE_STATUS[user-config]}" != "not-applicable" ]]; then
    RUN_STAGE_STATUS[user-config]="skipped"
  fi
  write_run_state
  run_log_line "stage=$stage status=failed exit=$failure_status"
  run_log_line "result=failed failed_stage=$stage exit=$failure_status updated_at=$RUN_UPDATED_AT"
}

run_orchestrated_stage() {
  local stage="$1" status verification_status
  case "${RUN_STAGE_STATUS[$stage]}" in
    not-applicable)
      printf 'stage %s: not applicable\n' "$stage"
      run_log_line "stage=$stage status=not-applicable"
      return 0
      ;;
    passed)
      if (verify_stage "$stage"); then
        verification_status=0
      else
        verification_status=$?
      fi
      if ((verification_status == 0)); then
        printf 'stage %s: verified; skipping\n' "$stage"
        run_log_line "stage=$stage status=passed verification=passed action=skipped"
        return 0
      fi
      printf 'stage %s: prior completion could not be verified; rerunning\n' "$stage"
      run_log_line "stage=$stage prior_status=passed verification=failed exit=$verification_status action=rerun"
      RUN_STAGE_STATUS["$stage"]="pending"
      ;;
    skipped|failed|running)
      RUN_STAGE_STATUS["$stage"]="pending"
      ;;
    pending) ;;
    *) die "internal error: invalid stage status for $stage" ;;
  esac

  RUN_STAGE_STATUS["$stage"]="running"
  write_run_state
  run_log_line "stage=$stage status=running attempt=$RUN_ATTEMPT"
  printf '\n==> stage %s: running\n' "$stage"
  if execute_stage_with_log "$stage"; then
    status=0
  else
    status=$?
  fi
  if ((status == 0)); then
    if (verify_stage "$stage"); then
      verification_status=0
    else
      verification_status=$?
    fi
    if ((verification_status != 0)); then
      status=$verification_status
    fi
  fi
  if ((status != 0)); then
    mark_stage_failure "$stage" "$status"
    return "$status"
  fi

  RUN_STAGE_STATUS["$stage"]="passed"
  write_run_state
  run_log_line "stage=$stage status=passed attempt=$RUN_ATTEMPT"
  printf '==> stage %s: passed\n' "$stage"
}

show_final_stage_report() {
  local result
  if [[ "$RUN_STATUS" == "completed" ]]; then
    result="passed"
  else
    result="failed"
  fi
  cat <<EOF

Final stage report:
  official-packages: ${RUN_STAGE_STATUS[official-packages]}
  user-config: ${RUN_STAGE_STATUS[user-config]}
  result: $result
  run-id: $RUN_ID
EOF
}

apply_orchestrated() {
  local status
  prepare_run_context
  confirm_orchestrated_apply
  initialize_or_resume_run

  if run_orchestrated_stage official-packages; then
    status=0
  else
    status=$?
  fi
  if ((status != 0)); then
    show_final_stage_report
    return "$status"
  fi

  if run_orchestrated_stage user-config; then
    status=0
  else
    status=$?
  fi
  if ((status != 0)); then
    show_final_stage_report
    return "$status"
  fi

  RUN_STATUS="completed"
  RUN_FAILED_STAGE="none"
  RUN_FAILURE_STATUS=0
  write_run_state
  run_log_line "result=completed attempt=$RUN_ATTEMPT updated_at=$RUN_UPDATED_AT"
  show_final_stage_report
}

guard_legacy_changing_action() {
  [[ "$PLAN_ONLY" == true ]] && return 0
  local test_root="${MY_ARCH_SETUP_LEGACY_TEST_ROOT:-}"
  if [[ "${MY_ARCH_SETUP_LEGACY_COMPONENT_TESTING:-}" != 1     || -z "$test_root"     || "$test_root" != /*     || "$test_root" == /     || ( "$HOME" != "$test_root" && "$HOME" != "$test_root"/* ) ]]; then
    die "legacy changing actions are disabled; use installer/full-orchestrator.py with the canonical reviewed manifests"
  fi
}

main() {
  parse_args "$@"
  guard_legacy_changing_action
  load_module_registry
  load_profile_modules
  resolve_module_selection
  preflight
  if [[ "$PLAN_ONLY" == true || "$APPLY_OFFICIAL" == true || "$APPLY_ORCHESTRATED" == true ]]; then
    load_official_manifest
  fi
  if [[ "$PLAN_ONLY" == true || "$APPLY_CONFIG" == true || "$APPLY_ORCHESTRATED" == true ]]; then
    validate_mapping
  fi
  if [[ "$PLAN_ONLY" == true ]]; then
    load_workstation_package_policy
    show_plan
  else
    ensure_selection_applyable
    if [[ "$APPLY_ORCHESTRATED" == true ]]; then
      apply_orchestrated
    elif [[ "$APPLY_CONFIG" == true ]]; then
      deploy_config
    else
      apply_official_packages
    fi
  fi
}

main "$@"
