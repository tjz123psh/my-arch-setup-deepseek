#!/usr/bin/env bash
# Run the local download-mode experiment suite.  No host configuration, package
# database, service, or VM is touched; network mirror probes are intentionally
# separate and must be invoked explicitly.
set -Eeuo pipefail
LAB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

printf '== Python syntax ==\n'
python3 -m py_compile "${LAB_DIR}"/bin/*.py "${LAB_DIR}"/tests/*.py
printf 'PASS python syntax\n\n'

printf '== Atomic download failure injection ==\n'
python3 "${LAB_DIR}/tests/download-integrity-test.py"
printf '\n== AUR prefetch queue model ==\n'
python3 "${LAB_DIR}/tests/aur-prefetch-queue-test.py"
printf '\n== Pacman native stall timeout ==\n'
bash "${LAB_DIR}/tests/pacman-native-stall-test.sh"

printf '\n== Existing source-cache static audit ==\n'
# This command returns zero when the expected defect patterns are found; its
# JSON status is deliberately `defects_confirmed`, not a product-health PASS.
python3 "${LAB_DIR}/tests/source-cache-audit.py"
printf '\nLocal experiment suite finished. See FINAL.md and results/.\n'
