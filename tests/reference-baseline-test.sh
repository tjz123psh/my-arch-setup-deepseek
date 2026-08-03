#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

python - "$root" <<'PY'
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])
reference = root / "docs/reference-baseline.md"
decisions = root / "docs/confirmed-decisions.md"
handoff = root / "docs/handoff-20260730.md"
modules = root / "manifests/modules.tsv"
installer = root / "installer/install.sh"

for path in (reference, decisions, handoff, modules, installer):
    if not path.is_file() or path.is_symlink():
        raise SystemExit(f"reference baseline input is missing or unsafe: {path.relative_to(root)}")

reference_text = reference.read_text()
for marker in (
    "Private manual is evidence, not executable input",
    "Live workstation is a mutable reference baseline",
    "dms-shell is now official",
    "greetd-dms-greeter-git remains untrusted",
    "Current mapped config is intentionally incomplete",
    "No system changes were performed",
    "Failed and unavailable checks",
):
    if marker not in reference_text:
        raise SystemExit(f"reference baseline is missing boundary: {marker}")

if re.search(r"/home/[^/\s]+", reference_text):
    raise SystemExit("reference baseline publishes a workstation home path")

decision_text = decisions.read_text()
for marker in ("DEC-REF-01", "DEC-REF-02", "DEC-REF-03"):
    if marker not in decision_text:
        raise SystemExit(f"confirmed decisions are missing reference contract: {marker}")

handoff_text = handoff.read_text()
for marker in ("reference-baseline.md", "private manual-install note", "mutable live-workstation baseline"):
    if marker not in handoff_text:
        raise SystemExit(f"handoff is missing durable reference context: {marker}")
private_artifact_patterns = {
    "private session export identifier": r"session-ses_[A-Za-z0-9]",
    "private temporary evidence path": r"/tmp/my-arch-setup-(?:phase-c|reference|session)",
}
for markdown in (root / "docs").rglob("*.md"):
    text = markdown.read_text()
    for label, pattern in private_artifact_patterns.items():
        if re.search(pattern, text):
            raise SystemExit(f"{markdown.relative_to(root)} publishes {label}")
if re.search(r"\b[0-9a-f]{64}\b", handoff_text):
    raise SystemExit("handoff publishes a private content hash")

for path in (root / "docs/implementation-status.md", root / "docs/modules.md", handoff):
    text = path.read_text()
    if "dms-shell" not in text or "unavailable" not in text:
        raise SystemExit(f"{path.relative_to(root)} loses the official-shell/profile-excluded-greeter distinction")

module_rows = {
    raw.split("\t", 1)[0]: raw.split("\t")
    for raw in modules.read_text().splitlines()
    if raw and not raw.startswith("#")
}
for module in ("dms-greetd", "dms-niri-greeter"):
    if module_rows.get(module, [None, None])[1] != "unavailable":
        raise SystemExit(f"unresolved DMS evidence is no longer marked unavailable: {module}")

installer_text = installer.read_text()
if "reference-baseline.md" in installer_text:
    raise SystemExit("reference evidence is directly consumed by the installer")
PY

printf 'Reference baseline checks passed.\n'
