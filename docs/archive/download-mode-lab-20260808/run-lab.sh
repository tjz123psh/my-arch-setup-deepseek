#!/usr/bin/env bash
# Run the local download-mode experiment suite.  No host configuration, package
# database, service, or VM is touched; network mirror probes are intentionally
# separate and must be invoked explicitly.
set -Eeuo pipefail
LAB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# Step 2 (2026-08-08): re-running the suite must NOT rewrite the committed
# timing JSONs under results/ (they are a reviewed snapshot). Route every
# test's result file into a throwaway dir INSIDE the workspace
# (fixtures/tmp/, which is git-ignored) - never /tmp or outside the repo.
mkdir -p "${LAB_DIR}/fixtures/tmp"
RUN_RESULTS="$(mktemp -d "${LAB_DIR}/fixtures/tmp/download-mode-lab-results.XXXXXX")"
export RESULT_DIR="${RUN_RESULTS}"
trap 'rm -rf "${RUN_RESULTS}"' EXIT

printf '== Python syntax ==\n'
python3 -m py_compile "${LAB_DIR}"/bin/*.py "${LAB_DIR}"/tests/*.py
printf 'PASS python syntax\n\n'

printf '== Atomic download failure injection ==\n'
python3 "${LAB_DIR}/tests/download-integrity-test.py"
printf '\n== AUR prefetch queue model ==\n'
python3 "${LAB_DIR}/tests/aur-prefetch-queue-test.py"
printf '\n== Pacman native stall timeout ==\n'
bash "${LAB_DIR}/tests/pacman-native-stall-test.sh"

printf '\n== Dynamic mirror plan ==\n'
python3 "${LAB_DIR}/tests/mirror-plan-test.py"

printf '\n== Existing source-cache static audit ==\n'
# This command returns zero when the expected defect patterns are found; its
# JSON status is deliberately `defects_confirmed`, not a product-health PASS.
python3 "${LAB_DIR}/tests/source-cache-audit.py"
printf '\nLocal experiment suite finished. See FINAL.md and results/.\n'
