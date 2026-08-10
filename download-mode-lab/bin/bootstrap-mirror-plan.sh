#!/usr/bin/env bash
# bootstrap-mirror-plan.sh - curl-only database probe + rank (prototype).
# download-mode-lab step 3 (plan A): no python, no root, no /etc writes.
# Writes reviewable TSV + Server lines ONLY to caller-specified paths under
# the workspace, via target-directory temp file + atomic rename. No backups,
# no pacman, no installs.
#
# Contract (review 2026-08-08 round 2):
#   exit codes: ok=0 invalid=2 unavailable=3 degraded=4 timeout=124
#   deps: curl date sort awk timeout xargs mktemp grep tr cut cp rm sed realpath
#   allowlist: --allowlist <file>; --bases must be a subset of it
#   outputs: parent dir must realpath inside the workspace; no symlink, no
#     existing file, no same-path; written via same-dir temp + atomic mv
#   timeout: still publishes structured partial TSV; never a Server file
# shellcheck disable=SC2016  # literal $repo/$arch placeholders in the Server template
set -Eeuo pipefail

LAB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
WORKSPACE_ROOT="$(cd -- "${LAB_DIR}/.." && pwd)"

# --- 3. dependency check (fail closed, never installs) ---
DEPS="curl date sort awk timeout xargs mktemp grep tr cut cp rm sed realpath"
MISSING=""
for dep in ${DEPS}; do
  command -v "$dep" >/dev/null 2>&1 || MISSING="${MISSING} ${dep}"
done
[[ -z "${MISSING}" ]] || { echo "STATUS unavailable missing_dep=${MISSING# }"; exit 3; }

# --- 4. config validation (finite positive ints, upper bound, no JOBS=0) ---
validate_posint() { # validate_posint <name> <value> <max>
  local name="$1" v="$2" max="$3"
  if [[ ! "${v}" =~ ^[0-9]+$ ]] || (( v < 1 || v > max )); then
    echo "STATUS invalid ${name}=${v} (must be integer 1..${max})"
    exit 2
  fi
}
JOBS="${JOBS:-4}";              validate_posint JOBS "$JOBS" 16
CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-4}"; validate_posint CONNECT_TIMEOUT "$CONNECT_TIMEOUT" 60
MAX_TIME="${MAX_TIME:-8}";      validate_posint MAX_TIME "$MAX_TIME" 60
HARD_BUDGET="${HARD_BUDGET:-25}"; validate_posint HARD_BUDGET "$HARD_BUDGET" 120

OUT_TSV=""; OUT_SERVERS=""; BASES_ARG=""; ALLOWLIST=""
while (( $# > 0 )); do
  case "$1" in
    --output-tsv) OUT_TSV="$2"; shift 2 ;;
    --output-servers) OUT_SERVERS="$2"; shift 2 ;;
    --bases) BASES_ARG="$2"; shift 2 ;;
    --allowlist) ALLOWLIST="$2"; shift 2 ;;
    -h|--help)
      echo "usage: bootstrap-mirror-plan.sh --allowlist <file> --output-tsv <p> --output-servers <p> [--bases 'url ...']"; exit 0 ;;
    *) echo "STATUS invalid unknown_arg=$1"; exit 2 ;;
  esac
done

# --- 2. output path validation ---
[[ -n "${OUT_TSV}" && -n "${OUT_SERVERS}" ]] || { echo "STATUS invalid missing_output"; exit 2; }
[[ -f "${ALLOWLIST}" ]] || { echo "STATUS invalid missing_allowlist=${ALLOWLIST}"; exit 2; }
validate_output() { # validate_output <path> <label>
  local p="$1" label="$2" dir realdir
  [[ -n "${p}" ]] || { echo "STATUS invalid ${label}_missing"; exit 2; }
  [[ ! -L "${p}" ]] || { echo "STATUS invalid ${label}_is_symlink"; exit 2; }
  [[ ! -e "${p}" ]] || { echo "STATUS invalid ${label}_already_exists"; exit 2; }
  dir="${p%/*}"; [[ "${dir}" == "${p}" ]] && dir="."
  [[ ! -L "${dir}" ]] || { echo "STATUS invalid ${label}_parent_is_symlink"; exit 2; }
  realdir="$(realpath -m "${dir}" 2>/dev/null)"
  case "${realdir}" in
    "${WORKSPACE_ROOT}"|"${WORKSPACE_ROOT}"/*) ;;
    *) echo "STATUS invalid ${label}_outside_workspace: ${realdir}"; exit 2 ;;
  esac
}
validate_output "${OUT_TSV}" "tsv"
validate_output "${OUT_SERVERS}" "servers"
[[ "${OUT_TSV}" != "${OUT_SERVERS}" ]] || { echo "STATUS invalid same_output_path"; exit 2; }

# --- 5. allowlist loading; --bases must be a subset ---
mapfile -t ALLOWED < <(grep -vE '^#|^[[:space:]]*$' "${ALLOWLIST}")
[[ "${#ALLOWED[@]}" -gt 0 ]] || { echo "STATUS invalid empty_allowlist"; exit 2; }
declare -A allowed_map=()
for b in "${ALLOWED[@]}"; do allowed_map["${b}"]=1; done

if [[ -n "${BASES_ARG}" ]]; then
  mapfile -t BASES < <(printf '%s\n' "${BASES_ARG}" | tr ' ' '\n' | grep -v '^$' || true)
else
  BASES=("${ALLOWED[@]}")
fi
[[ "${#BASES[@]}" -gt 0 ]] || { echo "STATUS invalid empty_bases"; exit 2; }

declare -A seen=()
UNIQ=()
for b in "${BASES[@]}"; do
  [[ -n "${allowed_map[$b]:-}" ]] || { echo "STATUS invalid base_not_in_allowlist=${b}"; exit 2; }
  [[ -n "${seen[$b]:-}" ]] && continue
  seen[$b]=1
  UNIQ+=("${b}")
done

# --- probe_one: structured per-mirror result ---
# shellcheck disable=SC2329  # probe_one is export -f'd and invoked by xargs child bash
probe_one() {
  local base="$1"
  local start_ns end_ns total rc out http_code bytes status range_supported
  start_ns="$(date +%s%N)"
  set +e
  out="$(curl -sS --range 0-262143 \
           --connect-timeout "${CONNECT_TIMEOUT}" --max-time "${MAX_TIME}" \
           -o /dev/null -w '%{http_code} %{size_download}' \
           "${base}/core/os/x86_64/core.db" 2>/dev/null)"
  rc=$?
  set -e
  end_ns="$(date +%s%N)"
  total="$(awk -v s="$start_ns" -v e="$end_ns" 'BEGIN{printf "%.3f", (e-s)/1e9}')"
  http_code="${out%% *}"
  bytes="${out##* }"
  [[ "${bytes}" =~ ^[0-9]+$ ]] || bytes=0
  case "$rc" in
    0)
      case "$http_code" in
        206) status="ok";           range_supported="true" ;;
        200) status="fallback";     range_supported="false" ;;
        *)   status="http_error";   range_supported="false" ;;
      esac ;;
    6)  status="dns_failure";      range_supported="false" ;;
    7)  status="connect_failure";  range_supported="false" ;;
    28) status="timeout";          range_supported="false" ;;
    35) status="tls_failure";      range_supported="false" ;;
    *)  status="curl_error_${rc}"; range_supported="false" ;;
  esac
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$base" "$rc" "${http_code:-000}" "$bytes" "$total" "$range_supported" "$status"
}
export -f probe_one
export CONNECT_TIMEOUT MAX_TIME JOBS

# --- 1. workspace-internal temp dir (never /tmp) ---
mkdir -p "${LAB_DIR}/fixtures/tmp"
tmp="$(mktemp -d "${LAB_DIR}/fixtures/tmp/bmp.XXXXXX")"
trap 'rm -rf "${tmp}"' EXIT
export TMP_RAW="${tmp}/raw.tsv"

# --- bounded parallel probe with overall hard budget ---
if ! timeout "${HARD_BUDGET}" bash -c '
    printf "%s\n" "$@" | xargs -P"${JOBS}" -n1 bash -c '\''probe_one "$1"'\'' _ \
      > "${TMP_RAW}" 2>/dev/null
  ' _ "${UNIQ[@]}"; then
  # 6. timeout still publishes structured PARTIAL TSV; never a Server file.
  # TMP_RAW is ${tmp}/raw.tsv already (same file) - do not cp onto itself.
  STATUS="timeout"
  cp "${TMP_RAW}" "${OUT_TSV}.tmp.$$" && mv -f "${OUT_TSV}.tmp.$$" "${OUT_TSV}"
  echo "STATUS timeout hard_budget=${HARD_BUDGET}s partial_tsv_written=1"
  exit 124
fi

# --- rank: weight (ok=0, fallback=1) then REAL time (col 6) then base ---
awk -F'\t' '
  !seen[$1]++ {
    if ($7=="ok") w=0; else if ($7=="fallback") w=1; else next;
    printf "%d\t%s\n", w, $0
  }' "${tmp}/raw.tsv" \
  | sort -t$'\t' -k1,1n -k6,6n -k2,2 \
  | cut -f2- > "${tmp}/ranked.tsv"

n_ok="$(awk -F'\t' '$7=="ok" {c++} END{print c+0}' "${tmp}/ranked.tsv")"
n_fb="$(awk -F'\t' '$7=="fallback" {c++} END{print c+0}' "${tmp}/ranked.tsv")"
n_bad="$(( ${#UNIQ[@]} - n_ok - n_fb ))"

# --- exact server lines (literal $repo/$arch) ---
# printf with %s + literal placeholders (no $ expansion in the format string)
repo_lit='$repo'
arch_lit='$arch'
while IFS=$'\t' read -r base _rest; do
  printf 'Server = %s/%s/os/%s\n' "${base}" "${repo_lit}" "${arch_lit}"
done < "${tmp}/ranked.tsv" > "${tmp}/servers.out"

# --- 7. atomic output write; non-ok never produces a Server file ---
cp "${tmp}/raw.tsv" "${OUT_TSV}.tmp.$$" && mv -f "${OUT_TSV}.tmp.$$" "${OUT_TSV}"
if (( n_ok + n_fb >= 3 )); then
  STATUS="ok"
  cp "${tmp}/servers.out" "${OUT_SERVERS}.tmp.$$" && mv -f "${OUT_SERVERS}.tmp.$$" "${OUT_SERVERS}"
elif (( n_ok + n_fb >= 1 )); then
  STATUS="degraded"
else
  STATUS="unavailable"
fi
echo "STATUS ${STATUS} ok=${n_ok} fallback=${n_fb} failed=${n_bad} total=${#UNIQ[@]}"

# --- exit-code contract: ok=0 invalid=2 unavailable=3 degraded=4 timeout=124 ---
case "${STATUS}" in
  ok)        exit 0 ;;
  degraded)  exit 4 ;;
  unavailable) exit 3 ;;
  *)         exit 1 ;;
esac
