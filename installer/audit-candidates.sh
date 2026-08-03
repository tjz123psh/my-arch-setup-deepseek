#!/usr/bin/env bash
# shellcheck shell=bash
# Produces a metadata-only local audit report. It intentionally never reads
# candidate file contents, copies files, or writes into the project repository.

set -Eeuo pipefail

readonly PROJECT_NAME="my-archlinux-setup"
readonly STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/${PROJECT_NAME}"
readonly AUDIT_DIR="${STATE_DIR}/audits"
REPORT_TIMESTAMP=$(date -u +%Y%m%dT%H%M%SZ)
readonly REPORT_TIMESTAMP
REPORT_TMP=""
declare -a TEMP_FILES=()
declare -a EXCLUDED=(
  "google-chrome" "MusicFree" "QQ" "obsidian" "Typora" "opencode" "dconf"
  "pulse" "ibus" "fcitx" "go" "libvirt" "JetBrains" "gh" "git"
  "io.github.clash-verge-rev.clash-verge-rev" "com.ccswitch.desktop" "menus"
)
declare -a EXCLUDED_BASENAMES=(
  ".env" ".envrc" "fish_variables" "cookie" "cookies" "login.data" "login.json"
  "tokens.json" "credentials" "credentials.json" "auth.json" "secrets.json"
)

cleanup() {
  local status=$?
  trap - EXIT
  if ((${#TEMP_FILES[@]} > 0)); then
    rm -f -- "${TEMP_FILES[@]}" 2>/dev/null || true
  fi
  [[ -z "$REPORT_TMP" ]] || rm -f -- "$REPORT_TMP" 2>/dev/null || true
  exit "$status"
}
trap cleanup EXIT

return_query_failure() {
  local status="$1"
  shift
  printf 'error: %s (exit %s)\n' "$*" "$status" >&2
  return "$status"
}

ensure_private_directory() {
  local path="$1" status
  if [[ -L "$path" ]]; then
    printf 'error: refusing to use a symlinked audit state directory: %s\n' "$path" >&2
    return 2
  fi
  if [[ -e "$path" && ! -d "$path" ]]; then
    printf 'error: audit state path is not a directory: %s\n' "$path" >&2
    return 2
  fi
  if mkdir -p -- "$path"; then
    :
  else
    status=$?
    return_query_failure "$status" "could not create audit state directory $path"
  fi
  if [[ -L "$path" || ! -d "$path" ]]; then
    printf 'error: audit state directory changed unexpectedly: %s\n' "$path" >&2
    return 2
  fi
  if chmod 700 -- "$path"; then
    :
  else
    status=$?
    return_query_failure "$status" "could not restrict audit state directory $path"
  fi
}

metadata_line() {
  local path="$1" relative="$2" kind="file" mode size status
  [[ -d "$path" ]] && kind="directory"
  [[ -L "$path" ]] && kind="symlink"
  if mode=$(stat -c '%a' -- "$path"); then
    :
  else
    status=$?
    return_query_failure "$status" "stat mode query failed for $relative"
  fi
  if size=$(stat -c '%s' -- "$path"); then
    :
  else
    status=$?
    return_query_failure "$status" "stat size query failed for $relative"
  fi
  # shellcheck disable=SC2016 # Markdown uses literal backticks around %s.
  printf '| `%s` | %s | %s | %s |\n' "$relative" "$kind" "$mode" "$size"
}

new_listing_file() {
  local __result_variable="$1" generated_listing
  generated_listing=$(mktemp "${AUDIT_DIR}/.candidate-list.XXXXXX")
  TEMP_FILES+=("$generated_listing")
  printf -v "$__result_variable" '%s' "$generated_listing"
}

write_tree_metadata() {
  local root="$1" display_root="$2"
  local entry basename excluded_basename listing status
  metadata_line "$root" "$display_root"
  new_listing_file listing
  if find "$root" -xdev -mindepth 1 -print0 | sort -z >"$listing"; then
    :
  else
    status=$?
    return_query_failure "$status" "candidate metadata traversal failed for $display_root"
  fi
  while IFS= read -r -d '' entry; do
    local excluded_name=false
    basename="${entry##*/}"
    for excluded_basename in "${EXCLUDED_BASENAMES[@]}"; do
      [[ "${basename,,}" == "$excluded_basename" ]] && excluded_name=true && break
    done
    [[ "$excluded_name" == false ]] || continue
    metadata_line "$entry" "${entry#"$HOME/"}"
  done <"$listing"
  rm -f -- "$listing"
}

write_scripts_metadata() {
  local entry basename excluded_basename listing status
  new_listing_file listing
  if find "$HOME/scripts" -xdev \
    \( -name .git -o -name .ssh \) -prune -o -print0 | sort -z >"$listing"; then
    :
  else
    status=$?
    return_query_failure "$status" "personal script metadata traversal failed"
  fi
  while IFS= read -r -d '' entry; do
    local excluded_name=false
    basename="${entry##*/}"
    for excluded_basename in "${EXCLUDED_BASENAMES[@]}"; do
      [[ "${basename,,}" == "$excluded_basename" ]] && excluded_name=true && break
    done
    [[ "$excluded_name" == false ]] || continue
    metadata_line "$entry" "${entry#"$HOME/"}"
  done <"$listing"
  rm -f -- "$listing"
}

main() {
  (($# == 0)) || {
    printf 'error: this audit tool accepts no arguments\n' >&2
    return 2
  }
  [[ "$HOME" == /* ]] || {
    printf 'error: HOME must be an absolute path\n' >&2
    return 2
  }
  [[ "$STATE_DIR" == /* ]] || {
    printf 'error: XDG_STATE_HOME must resolve to an absolute path\n' >&2
    return 2
  }

  umask 077
  ensure_private_directory "$STATE_DIR"
  ensure_private_directory "$AUDIT_DIR"
  REPORT_TMP=$(mktemp "${AUDIT_DIR}/.candidate-metadata-${REPORT_TIMESTAMP}-XXXXXX.md")
  local report_final="${REPORT_TMP%/*}/${REPORT_TMP##*/.}"

  {
    cat <<EOF_REPORT
# Local candidate metadata audit

- Generated: $(date -u +%FT%TZ)
- Scope: metadata only. No file contents were read, copied, or uploaded.
- Repository writes: none.
- Classification: **candidate only**; an item is not approved for personal
  restoration or deployment until its functional role and secret boundary have
  been separately reviewed.

## Candidate desktop configuration

| Relative path | Type | Mode | Bytes |
| --- | --- | ---: | ---: |
EOF_REPORT
    # Broadly inventory ~/.config so that safe desktop configuration is not
    # artificially restricted to a small hand-picked list. Sensitive/state
    # roots are excluded before any recursive metadata walk.
    local candidate candidate_path excluded excluded_root
    for candidate_path in "$HOME/.config"/* "$HOME/.config"/.[!.]*; do
      [[ -e "$candidate_path" || -L "$candidate_path" ]] || continue
      candidate="${candidate_path#"$HOME/.config/"}"
      excluded=false
      for excluded_root in "${EXCLUDED[@]}"; do
        [[ "$candidate" == "$excluded_root" ]] && excluded=true && break
      done
      if [[ "$excluded" == false ]]; then
        write_tree_metadata "$candidate_path" ".config/$candidate"
      fi
    done

    cat <<'EOF_REPORT'

## Deliberately excluded without content inspection

| Relative path | Reason |
| --- | --- |
EOF_REPORT
    for candidate in "${EXCLUDED[@]}"; do
      if [[ -e "$HOME/.config/$candidate" || -L "$HOME/.config/$candidate" ]]; then
        # shellcheck disable=SC2016 # Markdown uses literal backticks.
        printf '| `.config/%s` | browser/session/state/credential/cache or separately managed configuration |\n' "$candidate"
      fi
    done

    cat <<'EOF_REPORT'

## Personal scripts (metadata only)

Scripts are candidates only. They require content review for secrets, unsafe
destructive behavior, command dependencies, and intended module ownership.
Machine-bound paths are acceptable for the primary same-machine restore profile.

| Relative path | Type | Mode | Bytes |
| --- | --- | ---: | ---: |
EOF_REPORT
    if [[ -d "$HOME/scripts" && ! -L "$HOME/scripts" ]]; then
      write_scripts_metadata
    elif [[ -L "$HOME/scripts" ]]; then
      printf 'error: refusing to traverse symlinked scripts root: %s\n' "$HOME/scripts" >&2
      return 2
    fi

    cat <<'EOF_REPORT'

## Next steps

1. Review this private report.
2. Select files for content review; do not authorize whole directories blindly.
3. Classify each reviewed file first as personal-restore include or exclude;
   record public portability only as an optional second label.
4. Only then add explicit module-owned copy mappings and package manifests.
EOF_REPORT
  } >"$REPORT_TMP"

  chmod 600 "$REPORT_TMP"
  mv -- "$REPORT_TMP" "$report_final"
  REPORT_TMP=""
  printf 'Wrote metadata-only private audit report: %s\n' "$report_final"
}

main "$@"
