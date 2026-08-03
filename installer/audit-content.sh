#!/usr/bin/env bash
# shellcheck shell=bash
# Creates a private, value-redacted content-risk report for explicitly allowed
# desktop/dev configuration roots or a caller-supplied file list. It records
# only paths, SHA-256 digests, and category findings, never source lines or
# matched values.

set -Eeuo pipefail

readonly PROJECT_NAME="my-archlinux-setup"
readonly STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/${PROJECT_NAME}"
readonly AUDIT_DIR="${STATE_DIR}/audits"
REPORT_TIMESTAMP=$(date -u +%Y%m%dT%H%M%SZ)
readonly REPORT_TIMESTAMP
REPORT_TMP=""
AUDIT_MODE="roots"
SELECTED_LIST=""
declare -a TEMP_FILES=()
declare -a SELECTED_RELATIVES=()
declare -a SELECTED_PATHS=()

# These roots are plausible reusable desktop/developer configuration. Browser,
# chat, note, credential, cache, state, database, and media content is excluded.
declare -a REVIEW_ROOTS=(
  "alacritty" "autostart" "btop" "cava" "dankcal" "DankMaterialShell"
  "danksearch" "environment.d" "fcitx5" "fish" "fuzzel" "gtk-3.0" "gtk-4.0"
  "hypr" "kitty" "mako" "matugen" "mpv" "nemo" "niri" "nvim" "paru"
  "rog" "starship.toml" "systemd/user"
)
declare -a EXCLUDED_BASENAMES=(
  ".env" ".envrc" "fish_variables" "cookie" "cookies" "login.data" "login.json"
  "tokens.json" "credentials" "credentials.json" "auth.json" "secrets.json"
  "*.db" "*.sqlite" "*.sqlite3" "*.bak" "*.bak-*" "*.log" "*.cache"
  "*.png" "*.jpg" "*.jpeg" "*.gif" "*.webp" "*.avif" "*.bmp" "*.ico"
  "*.svg" "*.mp3" "*.ogg" "*.opus" "*.flac" "*.wav" "*.m4a" "*.mp4"
  "*.mkv" "*.webm" "*.mov" "*.woff" "*.woff2" "*.ttf" "*.otf"
)
declare -a EXCLUDED_RELATIVE_PATHS=(
  ".config/systemd/user/openai-oauth.service"
)
declare -a SELECTED_REVIEW_ROOTS=(
  ".config/niri/"
  ".config/hypr/"
  ".config/fcitx5/"
  ".config/DankMaterialShell/"
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

is_excluded_name() {
  local basename="$1" pattern
  for pattern in "${EXCLUDED_BASENAMES[@]}"; do
    # shellcheck disable=SC2053 # Exclusion entries intentionally use globs.
    [[ "${basename,,}" == $pattern ]] && return 0
  done
  return 1
}

is_excluded_path() {
  local relative="$1" excluded
  for excluded in "${EXCLUDED_RELATIVE_PATHS[@]}"; do
    [[ "$relative" == "$excluded" ]] && return 0
  done
  return 1
}

parse_arguments() {
  if (($# == 0)); then
    return 0
  fi
  if (($# == 2)) && [[ "$1" == "--files-from" ]]; then
    AUDIT_MODE="selected"
    SELECTED_LIST="$2"
    return 0
  fi
  printf 'error: usage: %s [--files-from FILE]\n' "${0##*/}" >&2
  return 2
}

is_selected_root() {
  local relative="$1" root
  for root in "${SELECTED_REVIEW_ROOTS[@]}"; do
    [[ "$relative" == "$root"* ]] && return 0
  done
  return 1
}

reject_symlink_components() {
  local relative="$1" current="$HOME" component
  local -a components=()
  IFS='/' read -r -a components <<<"$relative"
  for component in "${components[@]}"; do
    current+="/$component"
    if [[ -L "$current" ]]; then
      printf 'error: refusing selected path with symlink component: %s\n' "$relative" >&2
      return 2
    fi
  done
}

load_selected_files() {
  local relative path status root_matched
  local -a requested=()
  local -A seen=()

  [[ -n "$SELECTED_LIST" ]] || {
    printf 'error: --files-from requires a non-empty path\n' >&2
    return 2
  }
  if [[ -L "$SELECTED_LIST" ]]; then
    printf 'error: refusing symlinked selected-file list: %s\n' "$SELECTED_LIST" >&2
    return 2
  fi
  if [[ ! -f "$SELECTED_LIST" ]]; then
    printf 'error: selected-file list is not a regular file: %s\n' "$SELECTED_LIST" >&2
    return 2
  fi
  if mapfile -t requested <"$SELECTED_LIST"; then
    :
  else
    status=$?
    return_query_failure "$status" "could not read selected-file list $SELECTED_LIST"
  fi
  ((${#requested[@]} > 0)) || {
    printf 'error: selected-file list is empty\n' >&2
    return 2
  }

  for relative in "${requested[@]}"; do
    if [[ -z "$relative" || "$relative" == /* || "$relative" == *$'\r'* || \
          "$relative" == *$'\t'* || "$relative" == *'|'* || "$relative" == *'`'* ]]; then
      printf 'error: invalid selected relative path\n' >&2
      return 2
    fi
    if [[ "$relative" == *'//'* || "$relative" == */ || "$relative" == ./* || \
          "$relative" == *'/./'* || "$relative" == *'/../'* || "$relative" == */.. ]]; then
      printf 'error: selected path is not normalized: %s\n' "$relative" >&2
      return 2
    fi
    root_matched=false
    if is_selected_root "$relative"; then
      root_matched=true
    fi
    if [[ "$root_matched" != true ]]; then
      printf 'error: selected path is outside the authorized roots: %s\n' "$relative" >&2
      return 2
    fi
    if [[ -v 'seen[$relative]' ]]; then
      printf 'error: duplicate selected path: %s\n' "$relative" >&2
      return 2
    fi
    seen["$relative"]=1
    reject_symlink_components "$relative"
    path="$HOME/$relative"
    if [[ ! -f "$path" ]]; then
      printf 'error: selected path is not a regular file: %s\n' "$relative" >&2
      return 2
    fi
    SELECTED_RELATIVES+=("$relative")
    SELECTED_PATHS+=("$path")
  done
}

classify_file() {
  local path="$1" relative="$2" bytes sha_output sha status grep_status
  local -a findings=()
  if bytes=$(stat -c '%s' -- "$path"); then
    :
  else
    status=$?
    return_query_failure "$status" "stat size query failed for $relative"
  fi
  if sha_output=$(sha256sum -- "$path"); then
    sha="${sha_output%% *}"
  else
    status=$?
    return_query_failure "$status" "SHA-256 query failed for $relative"
  fi

  [[ "$bytes" -gt 1048576 ]] && findings+=("large-file")
  [[ "$relative" == *"/monitors."* || "$relative" == *"/outputs."* || "$relative" == *"monitors.json"* ]] && findings+=("machine-display-binding")
  [[ "$relative" == *"/autostart/"* || "$relative" == *"/systemd/user/"* || "$relative" == *"autostart."* ]] && findings+=("startup-behavior")
  [[ -x "$path" ]] && findings+=("executable-review")

  # Search only for pattern presence. Status 1 means no match; status >1 is a
  # failed content query and aborts the report without publishing a partial file.
  if grep -Eqi -- '(api[_-]?key|access[_-]?token|secret|password|authorization:|bearer[[:space:]]+)' "$path"; then
    findings+=("possible-secret-pattern")
  else
    grep_status=$?
    ((grep_status == 1)) || return_query_failure "$grep_status" "secret-pattern query failed for $relative"
  fi
  if grep -Eqi -- '(/home/[^/[:space:]"]+|/run/user/[0-9]+|[A-Za-z0-9._-]+@[^[:space:]"]+)' "$path"; then
    findings+=("personal-path-or-identity")
  else
    grep_status=$?
    ((grep_status == 1)) || return_query_failure "$grep_status" "identity-pattern query failed for $relative"
  fi

  ((${#findings[@]} > 0)) || findings+=("manual-review")
  # shellcheck disable=SC2016 # Markdown uses literal backticks around %s.
  printf '| `%s` | %s | `%s` | %s |\n' "$relative" "$bytes" "$sha" "${findings[*]}"
}

new_listing_file() {
  local __result_variable="$1" generated_listing
  generated_listing=$(mktemp "${AUDIT_DIR}/.candidate-list.XXXXXX")
  TEMP_FILES+=("$generated_listing")
  printf -v "$__result_variable" '%s' "$generated_listing"
}

write_root_content_risks() {
  local root_path="$1" display_root="$2"
  local entry basename relative listing status
  new_listing_file listing
  if find "$root_path" -xdev -type f -print0 | sort -z >"$listing"; then
    :
  else
    status=$?
    return_query_failure "$status" "content candidate traversal failed for $display_root"
  fi
  while IFS= read -r -d '' entry; do
    [[ ! -L "$entry" ]] || continue
    basename="${entry##*/}"
    is_excluded_name "$basename" && continue
    relative="${entry#"$HOME/"}"
    is_excluded_path "$relative" && continue
    classify_file "$entry" "$relative"
  done <"$listing"
  rm -f -- "$listing"
}

main() {
  parse_arguments "$@"
  [[ "$HOME" == /* ]] || {
    printf 'error: HOME must be an absolute path\n' >&2
    return 2
  }
  [[ "$STATE_DIR" == /* ]] || {
    printf 'error: XDG_STATE_HOME must resolve to an absolute path\n' >&2
    return 2
  }
  if [[ "$AUDIT_MODE" == "selected" ]]; then
    load_selected_files
  fi

  umask 077
  ensure_private_directory "$STATE_DIR"
  ensure_private_directory "$AUDIT_DIR"
  REPORT_TMP=$(mktemp "${AUDIT_DIR}/.candidate-content-risk-${REPORT_TIMESTAMP}-XXXXXX.md")
  local report_final="${REPORT_TMP%/*}/${REPORT_TMP##*/.}"

  {
    if [[ "$AUDIT_MODE" == "selected" ]]; then
      cat <<EOF_REPORT
# Local selected-file content-risk audit

- Generated: $(date -u +%FT%TZ)
- Scope: only the explicit normalized files supplied through \`--files-from\`;
  no directory traversal is performed.
- Selected files: ${#SELECTED_RELATIVES[@]}
- Authorized roots: \`.config/niri/\`, \`.config/hypr/\`, \`.config/fcitx5/\`,
  and \`.config/DankMaterialShell/\`.
- Stored data: relative paths, byte size, SHA-256, and category findings only.
- Not stored: source text, matching lines, tokens, passwords, or other values.
- Repository writes/uploads: none.

Categories are review prompts, not proof that an item is safe or unsafe.

| Relative path | Bytes | SHA-256 | Review categories |
| --- | ---: | --- | --- |
EOF_REPORT
    else
      cat <<EOF_REPORT
# Local candidate content-risk audit

- Generated: $(date -u +%FT%TZ)
- Scope: explicitly allowed configuration candidates only; excluded app/state
  roots and media content are not read.
- Stored data: relative paths, byte size, SHA-256, and category findings only.
- Not stored: source text, matching lines, tokens, passwords, or other values.
- Repository writes/uploads: none.

Categories are review prompts, not proof that an item is safe or unsafe.

| Relative path | Bytes | SHA-256 | Review categories |
| --- | ---: | --- | --- |
EOF_REPORT
    fi
    local root root_path basename relative index
    if [[ "$AUDIT_MODE" == "selected" ]]; then
      for index in "${!SELECTED_PATHS[@]}"; do
        classify_file "${SELECTED_PATHS[$index]}" "${SELECTED_RELATIVES[$index]}"
      done
    else
      for root in "${REVIEW_ROOTS[@]}"; do
        root_path="$HOME/.config/$root"
        [[ -e "$root_path" || -L "$root_path" ]] || continue
        if [[ -L "$root_path" ]]; then
          printf 'error: refusing to inspect symlinked review root: .config/%s\n' "$root" >&2
          return 2
        fi
        if [[ -f "$root_path" ]]; then
          basename="${root_path##*/}"
          relative=".config/$root"
          is_excluded_name "$basename" && continue
          is_excluded_path "$relative" && continue
          classify_file "$root_path" "$relative"
        elif [[ -d "$root_path" ]]; then
          write_root_content_risks "$root_path" ".config/$root"
        else
          printf 'error: review root is not a regular file or directory: .config/%s\n' "$root" >&2
          return 2
        fi
      done
    fi

    cat <<'EOF_REPORT'

## Required disposition

For every reviewed candidate, choose exactly one before it can enter the public
repository: `public-include`, `sanitized-include`, `template`, or `exclude`.
Files with `possible-secret-pattern`, `personal-path-or-identity`,
`machine-display-binding`, or `startup-behavior` require focused review before
any public use. The report is private evidence only, not deployment approval.
EOF_REPORT
  } >"$REPORT_TMP"

  chmod 600 "$REPORT_TMP"
  mv -- "$REPORT_TMP" "$report_final"
  REPORT_TMP=""
  printf 'Wrote private content-risk audit report: %s\n' "$report_final"
}

main "$@"
