#!/usr/bin/env python3
from __future__ import annotations

from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parent.parent
markdown_files = sorted(root.rglob("*.md"))
errors: list[str] = []

for path in markdown_files:
    text = path.read_text()
    relative = path.relative_to(root)
    for match in re.finditer(r"\[[^\]]*\]\(([^)]+)\)", text):
        destination = match.group(1).strip()
        if not destination or destination.startswith(("#", "http://", "https://", "mailto:")):
            continue
        destination = destination.split("#", 1)[0]
        target = (path.parent / destination).resolve()
        try:
            target.relative_to(root.resolve())
        except ValueError:
            errors.append(f"{relative}: local link escapes repository: {match.group(1)}")
            continue
        if not target.exists():
            errors.append(f"{relative}: broken local link: {match.group(1)}")

mapping = root / "manifests/config-mappings.tsv"
mapping_count = sum(
    1
    for raw in mapping.read_text().splitlines()
    if raw and not raw.startswith("#")
)
nvim_count = sum(1 for path in (root / "config/home/.config/nvim").rglob("*") if path.is_file())

count_contracts = [
    (root / "README.md", rf"显式映射\s*{mapping_count}\s*个配置文件", "mapping count"),
    (root / "README.md", rf"Neovim 配置共\s*{nvim_count}\s*个文件", "Neovim count"),
    (root / "docs/configuration.md", rf"current set contains {mapping_count} files", "mapping count"),
    (root / "docs/configuration.md", rf"a {nvim_count}-file Neovim", "Neovim count"),
]
for path, pattern, label in count_contracts:
    normalized_content = " ".join(path.read_text().split())
    if not re.search(pattern, normalized_content):
        errors.append(f"{path.relative_to(root)}: documented {label} does not match current manifests")

readiness_counts = {"available": 0, "planning": 0, "unavailable": 0}
for raw in (root / "manifests/production-module-readiness.tsv").read_text().splitlines():
    if not raw or raw.startswith("#"):
        continue
    parts = raw.split("\t")
    if len(parts) != 3 or parts[1] not in readiness_counts:
        errors.append("manifests/production-module-readiness.tsv: malformed readiness row")
        continue
    readiness_counts[parts[1]] += 1
readiness_separator = r"(?:\s*,\s*(?:and\s+)?|\s+and\s+|\s*[、，]\s*)"
readiness_pattern = re.compile(
    rf"\b{readiness_counts['available']}\s+(?:个\s+)?`?available`?{readiness_separator}"
    rf"{readiness_counts['planning']}\s+(?:个\s+)?`?planning`?{readiness_separator}"
    rf"{readiness_counts['unavailable']}\s+(?:个\s+)?`?unavailable`?"
)
for path in (
    root / "README.md",
    root / "docs/modules.md",
    root / "docs/implementation-status.md",
    root / "docs/confirmed-decisions.md",
):
    if not readiness_pattern.search(" ".join(path.read_text().split())):
        errors.append(
            f"{path.relative_to(root)}: production readiness counts do not match current manifest"
        )

profile_counts: dict[str, int] = {}
for raw in (root / "manifests/official-packages.tsv").read_text().splitlines():
    if not raw or raw.startswith("#"):
        continue
    profile = raw.split("\t", 1)[0]
    profile_counts[profile] = profile_counts.get(profile, 0) + 1
manifest_docs = " ".join((root / "manifests/README.md").read_text().split())
for profile, count in sorted(profile_counts.items()):
    if not re.search(rf"{re.escape(str(count))} for `{re.escape(profile)}`", manifest_docs):
        errors.append(f"manifests/README.md: package count for {profile} does not match TSV")

decision_doc = (root / "docs/confirmed-decisions.md").read_text()
normalized_decision_doc = " ".join(decision_doc.split())
status_doc = (root / "docs/implementation-status.md").read_text()
critical_decision_markers = {
    "exact post-network handoff": (
        "DEC-SCOPE-05",
        "The installer begins with the workstation configuration that follows the manual network bootstrap",
    ),
    "dual-WM default and cancellation": (
        "DEC-WM-01",
        "DEFAULTS to both Niri and Hyprland",
    ),
    "selected WM config boundary": (
        "DEC-CONFIG-01",
        "Selecting Niri must not implicitly deploy Hyprland-only config",
    ),
    "greeter excluded from executable profiles": (
        "DEC-DMS-02",
        "Greeter installation is deferred and MUST NOT block",
    ),
    "no automatic SDDM fallback": (
        "DEC-DMS-04",
        "MUST NOT be reintroduced",
    ),
    "module selection requirement": (
        "DEC-UX-03",
        "Profiles choose defaults; modules remain the actual selectable units",
    ),
}
for label, (decision_id, required) in critical_decision_markers.items():
    if decision_id not in decision_doc or required not in normalized_decision_doc:
        errors.append(f"docs/confirmed-decisions.md: missing critical decision contract: {label}")
for stale_statement in (
    "The ASUS defaults retain `dms-greetd`",
    "apply readiness as blocked",
):
    if stale_statement in decision_doc:
        errors.append(
            "docs/confirmed-decisions.md: stale pre-decision greeter default remains: "
            f"{stale_statement}"
        )
for path in (root / "README.md", root / "docs/handoff-20260730.md", root / "docs/modules.md"):
    content = path.read_text()
    for required_link in ("confirmed-decisions.md", "implementation-status.md"):
        if required_link not in content:
            errors.append(f"{path.relative_to(root)}: missing durable context link to {required_link}")
if "Requirements source: [`confirmed-decisions.md`](confirmed-decisions.md)" not in status_doc:
    errors.append("docs/implementation-status.md: missing requirements-source declaration")

# A controlled source failure must itself carry the stop boundary. The earlier
# archlinuxcn stop is a one-command option, not durable run state; omitting this
# flag from the resume command lets independent later branches execute.
vm_execution_text = (root / "docs/vm-execution-plan-20260801.md").read_text().replace("\\\n", " ")
vm_execution_doc = " ".join(vm_execution_text.split())
controlled_source_commands = {
    "controlled AUR-source failure resume": (
        "--mode new --apply --resume --stop-after-stage aur-source-acquisition "
        "--confirm-system-changes --confirm-archlinuxcn --confirm-aur"
    ),
    "controlled AUR-source retry": (
        "--mode new --apply --retry-stage aur-source-acquisition "
        "--stop-after-stage aur-source-acquisition --confirm-system-changes "
        "--confirm-archlinuxcn --confirm-aur"
    ),
}
for label, command in controlled_source_commands.items():
    if command not in vm_execution_doc:
        errors.append(
            f"docs/vm-execution-plan-20260801.md: {label} omits its hard stop boundary"
        )

vm_validation_doc = " ".join((root / "docs/vm-validation.md").read_text().split())
vm_session_commands = (
    "python installer/phase-c-session-check.py --profile vm --session niri --json",
    "python installer/phase-c-session-check.py --profile vm --session hyprland --json",
    "python installer/phase-c-session-check.py --profile vm --session niri --selection both --json",
    "python installer/phase-c-session-check.py --profile vm --session hyprland --selection both --json",
)
for command in vm_session_commands:
    if command not in vm_validation_doc:
        errors.append(
            f"docs/vm-validation.md: VM session acceptance omits exact command: {command}"
        )

if errors:
    for error in errors:
        print(error, file=sys.stderr)
    raise SystemExit(1)
print("Documentation checks passed.")
