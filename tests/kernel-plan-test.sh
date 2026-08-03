#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

python - "$root" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
plan = root / "docs/kernel-plan.md"
candidates = root / "manifests/phase-c-package-candidates.tsv"
installer = root / "installer/install.sh"

if not plan.is_file() or plan.is_symlink():
    raise SystemExit("kernel plan is missing or unsafe")

plan_text = plan.read_text()
for marker in (
    "Kernels are a manual base-install input",
    "Headers follow detected kernels",
    "No automatic GRUB default change",
    "Dual-kernel ASUS baseline is confirmed",
    "No system changes were performed",
    "Failed and unavailable checks",
    "installer/kernel-support-check.py",
    "successful empty `dkms status`",
):
    if marker not in plan_text:
        raise SystemExit(f"kernel plan is missing boundary: {marker}")

rows: dict[tuple[str, str], list[str]] = {}
for raw in candidates.read_text().splitlines():
    if not raw or raw.startswith("#"):
        continue
    parts = raw.split("\t")
    rows[(parts[0], parts[1])] = parts

required = {
    ("gpu-base-kernel", "linux"): ("precondition", "asus-base-install", "base-kernel-manual"),
    ("gpu-base-kernel", "linux-headers"): ("proposed", "detected-linux", "kernel-match"),
    ("gpu-base-kernel", "linux-zen"): ("precondition", "asus-base-install", "base-kernel-manual"),
    ("gpu-base-kernel", "linux-zen-headers"): ("proposed", "detected-linux-zen", "kernel-match"),
}
for key, expected in required.items():
    if key not in rows:
        raise SystemExit(f"kernel candidate is missing: {key[1]}")
    actual = (rows[key][3], rows[key][4], rows[key][6])
    if actual != expected:
        raise SystemExit(f"kernel candidate has wrong disposition/applicability/blocker: {key[1]}")

installer_text = installer.read_text()
if "kernel-plan.md" in installer_text:
    raise SystemExit("non-executable kernel plan is referenced by installer")
if "kernel-support-check.py" in installer_text:
    raise SystemExit("read-only kernel checker is referenced by executable installer")
PY

printf 'Kernel planning checks passed.\n'
