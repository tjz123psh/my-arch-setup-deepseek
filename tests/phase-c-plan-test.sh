#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

python - "$root" <<'PY'
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])
manifest = root / "manifests/phase-c-package-candidates.tsv"
plan = root / "docs/phase-c-plan.md"

if not manifest.is_file() or manifest.is_symlink():
    raise SystemExit("Phase C candidate manifest is missing or unsafe")
if not plan.is_file() or plan.is_symlink():
    raise SystemExit("Phase C plan is missing or unsafe")

lines = manifest.read_text().splitlines()
if not lines or lines[0] != "# schema=1":
    raise SystemExit("unsupported or missing Phase C candidate schema")

sources = {"official", "unavailable-official", "archlinuxcn"}
dispositions = {
    "precondition",
    "proposed",
    "optional",
    "pending-decision",
    "transitive",
    "excluded",
    "blocked-third-party",
}
token = re.compile(r"[a-z0-9][a-z0-9@._:+,-]*")
rows: dict[tuple[str, str], tuple[str, str, str, str, str]] = {}

for line_number, raw in enumerate(lines, 1):
    if not raw or raw.startswith("#"):
        continue
    parts = raw.split("\t")
    if len(parts) != 8 or not all(parts):
        raise SystemExit(f"invalid Phase C candidate row at line {line_number}")
    module, package, source, disposition, applicability, service_action, blocker, purpose = parts
    for label, value in (
        ("module", module),
        ("package", package),
        ("applicability", applicability),
        ("service action", service_action),
    ):
        if not token.fullmatch(value):
            raise SystemExit(f"unsafe {label} at line {line_number}: {value}")
    if source not in sources:
        raise SystemExit(f"invalid source at line {line_number}: {source}")
    if disposition not in dispositions:
        raise SystemExit(f"invalid disposition at line {line_number}: {disposition}")
    if blocker != "-" and not token.fullmatch(blocker):
        raise SystemExit(f"unsafe blocker at line {line_number}: {blocker}")
    if source == "archlinuxcn" and disposition != "blocked-third-party":
        raise SystemExit(f"third-party candidate is not blocked at line {line_number}")
    if source == "unavailable-official" and disposition != "excluded":
        raise SystemExit(f"unavailable official candidate is not excluded at line {line_number}")
    if disposition in {"precondition", "proposed", "optional", "pending-decision", "transitive"} and source != "official":
        raise SystemExit(f"actionable candidate is not official at line {line_number}")
    if any(ord(character) < 32 for character in purpose):
        raise SystemExit(f"control character in purpose at line {line_number}")
    key = (module, package)
    if key in rows:
        raise SystemExit(f"duplicate Phase C candidate at line {line_number}: {module}/{package}")
    rows[key] = (source, disposition, applicability, service_action, blocker)

required = {
    ("portal-common", "xdg-desktop-portal"): ("official", "proposed"),
    ("portal-common", "xdg-desktop-portal-gtk"): ("official", "proposed"),
    ("portal-niri", "xdg-desktop-portal-gnome"): ("official", "proposed"),
    ("portal-hyprland", "xdg-desktop-portal-hyprland"): ("official", "proposed"),
    ("hyprland-session", "uwsm"): ("official", "excluded"),
    ("audio-pipewire", "pipewire-audio"): ("official", "proposed"),
    ("bluetooth", "bluez-utils"): ("official", "proposed"),
    ("power-profiles", "power-profiles-daemon"): ("official", "proposed"),
    ("input-fcitx-rime", "fcitx5-rime"): ("official", "proposed"),
    ("input-fcitx-rime", "rime-ice-git"): ("archlinuxcn", "blocked-third-party"),
    ("gpu-amd", "mesa"): ("official", "proposed"),
    ("gpu-amd", "libva-mesa-driver"): ("unavailable-official", "excluded"),
    ("gpu-nvidia-open", "nvidia-open-dkms"): ("official", "proposed"),
    ("asus-controls", "asusctl"): ("archlinuxcn", "blocked-third-party"),
    ("asus-controls", "supergfxctl"): ("archlinuxcn", "blocked-third-party"),
}
for key, expected in required.items():
    if key not in rows:
        raise SystemExit(f"missing required Phase C candidate: {key[0]}/{key[1]}")
    if rows[key][:2] != expected:
        raise SystemExit(f"incorrect Phase C source/disposition: {key[0]}/{key[1]}")

portal_keys = (
    ("portal-common", "xdg-desktop-portal"),
    ("portal-common", "xdg-desktop-portal-gtk"),
    ("portal-niri", "xdg-desktop-portal-gnome"),
    ("portal-hyprland", "xdg-desktop-portal-hyprland"),
)
for key in portal_keys:
    if rows[key][4] != "portal-session-validation":
        raise SystemExit(f"portal candidate does not use the session validation gate: {key[0]}/{key[1]}")
if rows[("hyprland-session", "uwsm")][4] != "plain-session-selected":
    raise SystemExit("UWSM exclusion does not record the plain-session decision")
if any(row[4] in {"portal-choice-open", "session-choice-open"} for row in rows.values()):
    raise SystemExit("closed Portal/session choice blocker remains in the Phase C manifest")

closed_service_rows = {
    ("audio-pipewire", "pipewire"): ("package-global-enable", "-"),
    ("audio-pipewire", "pipewire-audio"): ("none", "-"),
    ("audio-pipewire", "pipewire-alsa"): ("none", "-"),
    ("audio-pipewire", "pipewire-pulse"): ("package-global-enable", "-"),
    ("audio-pipewire", "wireplumber"): ("package-global-enable", "-"),
    ("audio-pipewire", "pipewire-jack"): ("none", "-"),
    ("bluetooth", "blueman"): ("session-startup-map", "-"),
    ("power-profiles", "power-profiles-daemon"): ("enable-power-profiles-daemon.service", "-"),
    ("input-fcitx-rime", "fcitx5"): ("session-startup-map", "-"),
}
for key, expected in closed_service_rows.items():
    actual = rows.get(key)
    if actual is None:
        raise SystemExit(f"missing closed service/startup candidate: {key[0]}/{key[1]}")
    if actual[3:] != expected:
        raise SystemExit(
            f"incorrect service action/blocker for {key[0]}/{key[1]}: {actual[3:]}"
        )
if rows[("input-fcitx-rime", "fcitx5-rime")][3:] != ("none", "rime-ice-config"):
    raise SystemExit("Fcitx Rime engine must not claim a second desktop startup owner")

closed_blockers = {
    "clean-vm-preset-check",
    "conflicts-pulseaudio",
    "conflicts-pipewire-media-session",
    "conflicts-jack-jack2",
    "conflicts-power-daemons",
    "desktop-startup-owner",
}
stale_closed = sorted({row[4] for row in rows.values()} & closed_blockers)
if stale_closed:
    raise SystemExit(f"closed audio/power/startup blocker remains in Phase C: {stale_closed}")

hypr_autostart = (root / "config/home/.config/hypr/conf/autostart.lua").read_text()
for command in (
    'hl.exec_cmd("pgrep -x fcitx5 >/dev/null || fcitx5 -d")',
    'hl.exec_cmd("pgrep -x blueman-applet >/dev/null || blueman-applet")',
):
    if hypr_autostart.count(command) != 1:
        raise SystemExit(f"plain Hyprland startup owner is missing or duplicated: {command}")
niri_config = (root / "config/home/.config/niri/config.kdl").read_text()
niri_commands = "\n".join(
    line for line in niri_config.splitlines() if not line.lstrip().startswith("//")
)
if re.search(r"\b(fcitx5|blueman-applet)\b", niri_commands):
    raise SystemExit("Niri config duplicates package-owned XDG autostart for Fcitx5/Blueman")

official_runtime = (root / "manifests/official-packages.tsv").read_text()
installer_text = (root / "installer/install.sh").read_text()
if "phase-c-package-candidates.tsv" in installer_text:
    raise SystemExit("Phase C planning manifest is referenced by the installer")
if "phase-c-plan.py" in installer_text:
    raise SystemExit("Phase C planning tool is referenced by the installer")
for forbidden in ("asusctl", "supergfxctl", "rog-control-center", "rime-ice-git"):
    if re.search(rf"\t{re.escape(forbidden)}\t", official_runtime):
        raise SystemExit(f"third-party package entered executable official manifest: {forbidden}")

plan_text = plan.read_text()
for marker in (
    "No Phase C row is executable",
    "`review_transaction`",
    "`install_command=null`",
    "Portal decision is closed",
    "Plain Hyprland session is selected",
    "No global Portal override is generated",
    "`systemctl --global enable`",
    "`pacman -Qq` exact-name set",
    "one startup owner per active session",
    "`xdg-desktop-autostart.target`",
    "`config/home/.config/hypr/conf/autostart.lua`",
    "No automatic conflict removal",
    "Rime Ice configuration mismatch",
    "ASUS controls are third-party on this host",
    "No system changes were performed",
    "Failed and unavailable checks",
):
    if marker not in plan_text:
        raise SystemExit(f"Phase C plan is missing boundary: {marker}")
for stale_marker in (
    "Portal decision remains open",
    "Plain Hyprland versus UWSM remains open",
):
    if stale_marker in plan_text:
        raise SystemExit(f"Phase C plan retains closed decision text: {stale_marker}")
PY


python - "$root" <<'PY'
from pathlib import Path
import json
import os
import subprocess
import sys
import tempfile

root = Path(sys.argv[1])
tool = root / "installer/phase-c-plan.py"
if not tool.is_file() or tool.is_symlink():
    raise SystemExit("Phase C review tool is missing or unsafe")


def run_tool(*args: str, env: dict[str, str] | None = None, expect_success: bool = True) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(
        ["python", str(tool), *args],
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=env,
    )
    if expect_success and result.returncode != 0:
        raise SystemExit(f"Phase C tool failed for {args}: {result.stderr}")
    if not expect_success and result.returncode == 0:
        raise SystemExit(f"Phase C tool accepted invalid arguments: {args}")
    return result


asus_text = run_tool("--profile", "asus-amd-nvidia").stdout
for marker in (
    "Phase C review plan (read-only)",
    "safety: planning only; no package, service, /etc, boot, driver or repository changes",
    "installer integration: none; installer/install.sh must not consume this manifest",
    "manifest rows: 48",
    "applicable rows: 45",
    "blocked-third-party=4",
    "review transaction (NOT executable)",
    "apply authorized: no",
    "installer integration: no",
    "install command: not generated",
    "proposed official packages (24):",
    "future service/config actions listed but NOT executed",
    "completion gate: generate a separate exact transaction",
):
    if marker not in asus_text:
        raise SystemExit(f"Phase C tool text output is missing marker: {marker}")

asus = json.loads(run_tool("--profile", "asus-amd-nvidia", "--json").stdout)
if asus["safety"] != {
    "planning_only": True,
    "installer_apply_integration": False,
    "system_changes": False,
}:
    raise SystemExit(f"unexpected safety block: {asus['safety']}")
counts = asus["counts"]
if counts["manifest_rows"] != 48 or counts["applicable_rows"] != 45:
    raise SystemExit(f"unexpected ASUS counts: {counts}")
if counts["by_disposition"].get("blocked-third-party") != 4:
    raise SystemExit("ASUS plan should keep four third-party rows blocked")
if counts["by_source"] != {"archlinuxcn": 4, "official": 40, "unavailable-official": 1}:
    raise SystemExit(f"unexpected ASUS source counts: {counts['by_source']}")
if any(row["installed_status"] != "not-queried" for row in asus["applicable_candidates"]):
    raise SystemExit("default JSON run should not query live package state")

transaction = asus["review_transaction"]
for key, expected in {
    "apply_authorized": False,
    "installer_integration": False,
    "install_command": None,
    "installed_state_checked": False,
}.items():
    if transaction.get(key) != expected:
        raise SystemExit(f"unexpected review transaction safety field {key}: {transaction.get(key)!r}")
expected_proposed = [
    "amd-ucode",
    "blueman",
    "bluez",
    "bluez-utils",
    "fcitx5",
    "fcitx5-gtk",
    "fcitx5-qt",
    "fcitx5-rime",
    "linux-headers",
    "linux-zen-headers",
    "mesa",
    "nvidia-open-dkms",
    "pipewire",
    "pipewire-alsa",
    "pipewire-audio",
    "pipewire-pulse",
    "power-profiles-daemon",
    "sof-firmware",
    "vulkan-radeon",
    "wireplumber",
    "xdg-desktop-portal",
    "xdg-desktop-portal-gnome",
    "xdg-desktop-portal-gtk",
    "xdg-desktop-portal-hyprland",
]
if transaction.get("proposed_official_packages") != expected_proposed:
    raise SystemExit(f"unexpected ASUS proposed transaction: {transaction.get('proposed_official_packages')}")
expected_bucket_counts = {
    "precondition_packages": 2,
    "dependency_only_packages": 3,
    "pending_decision_packages": 1,
    "optional_packages": 4,
    "blocked_third_party_packages": 4,
    "excluded_packages": 7,
}
for key, expected in expected_bucket_counts.items():
    actual = len(transaction.get(key, []))
    if actual != expected:
        raise SystemExit(f"unexpected ASUS review transaction count for {key}: {actual}")
if transaction.get("installed_proposed_packages") != []:
    raise SystemExit("default review transaction should not claim installed proposed packages")
if transaction.get("missing_proposed_packages") != []:
    raise SystemExit("default review transaction should not claim missing proposed packages")
if transaction.get("query_failed_proposed_packages") != []:
    raise SystemExit("default review transaction should not claim failed proposed package queries")
gates = transaction.get("unresolved_proposed_gates", {})
if gates.get("kernel-match") != ["linux-headers", "linux-zen-headers"]:
    raise SystemExit(f"unexpected kernel-match gate: {gates.get('kernel-match')}")
expected_portal_gate = [
    "xdg-desktop-portal",
    "xdg-desktop-portal-gnome",
    "xdg-desktop-portal-gtk",
    "xdg-desktop-portal-hyprland",
]
if gates.get("portal-session-validation") != expected_portal_gate:
    raise SystemExit(f"unexpected portal-session-validation gate: {gates.get('portal-session-validation')}")
closed_gate_names = {
    "clean-vm-preset-check",
    "conflicts-pulseaudio",
    "conflicts-pipewire-media-session",
    "conflicts-power-daemons",
    "desktop-startup-owner",
}
remaining_closed_gates = sorted(set(gates) & closed_gate_names)
if remaining_closed_gates:
    raise SystemExit(f"closed audio/power/startup gate remains unresolved: {remaining_closed_gates}")
if "portal-choice-open" in gates or "session-choice-open" in gates:
    raise SystemExit(f"closed Portal/session choice appears as an unresolved proposed gate: {gates}")
if transaction.get("pending_decision_packages") != ["switcheroo-control"]:
    raise SystemExit(f"unexpected remaining pending decision: {transaction.get('pending_decision_packages')}")
if "uwsm" not in transaction.get("excluded_packages", []):
    raise SystemExit("plain Hyprland decision did not move uwsm into excluded packages")
if "pacman -S" in asus_text:
    raise SystemExit("Phase C review transaction must not generate an install command")

desktop = json.loads(run_tool("--profile", "desktop-amd", "--json").stdout)
desktop_counts = desktop["counts"]
if desktop_counts["manifest_rows"] != 48 or desktop_counts["applicable_rows"] != 31:
    raise SystemExit(f"unexpected desktop-amd counts: {desktop_counts}")
if desktop_counts["by_source"] != {"archlinuxcn": 1, "official": 29, "unavailable-official": 1}:
    raise SystemExit(f"unexpected desktop-amd source counts: {desktop_counts['by_source']}")
if "wm-hyprland" in desktop["applicability_tokens"]:
    raise SystemExit("desktop-amd default should not select Hyprland applicability")

def selected_portals(plan: dict[str, object]) -> list[str]:
    transaction = plan["review_transaction"]
    return [
        package
        for package in transaction["proposed_official_packages"]
        if package.startswith("xdg-desktop-portal")
    ]

expected_niri_portals = [
    "xdg-desktop-portal",
    "xdg-desktop-portal-gnome",
    "xdg-desktop-portal-gtk",
]
if selected_portals(desktop) != expected_niri_portals:
    raise SystemExit(f"unexpected Niri-only Portal set: {selected_portals(desktop)}")
if desktop["review_transaction"]["unresolved_proposed_gates"].get("portal-session-validation") != expected_niri_portals:
    raise SystemExit("Niri-only Portal validation gate does not match its package set")

hyprland = json.loads(
    run_tool(
        "--profile",
        "desktop-amd",
        "--modules",
        "desktop-shared,wm-hyprland",
        "--json",
    ).stdout
)
expected_hyprland_portals = [
    "xdg-desktop-portal",
    "xdg-desktop-portal-gtk",
    "xdg-desktop-portal-hyprland",
]
if selected_portals(hyprland) != expected_hyprland_portals:
    raise SystemExit(f"unexpected Hyprland-only Portal set: {selected_portals(hyprland)}")
if hyprland["review_transaction"]["unresolved_proposed_gates"].get("portal-session-validation") != expected_hyprland_portals:
    raise SystemExit("Hyprland-only Portal validation gate does not match its package set")
if "uwsm" not in hyprland["review_transaction"]["excluded_packages"]:
    raise SystemExit("Hyprland-only review must retain plain-session UWSM exclusion")

vm = json.loads(run_tool("--profile", "vm", "--json").stdout)
vm_counts = vm["counts"]
if vm_counts["manifest_rows"] != 48 or vm_counts["applicable_rows"] != 10:
    raise SystemExit(f"unexpected VM counts: {vm_counts}")
if vm_counts["by_source"] != {"official": 10}:
    raise SystemExit(f"unexpected VM source counts: {vm_counts['by_source']}")
if "physical" in vm["applicability_tokens"]:
    raise SystemExit("vm profile should not select physical applicability")

for bad_modules in ("wm-niri,wm-niri", "wm-niri,does-not-exist", ""):
    run_tool("--modules", bad_modules, expect_success=False)

with tempfile.TemporaryDirectory() as mock_dir:
    pacman = Path(mock_dir) / "pacman"
    pacman.write_text(
        """#!/usr/bin/env bash
set -eu
if [[ $# -ne 2 || $1 != '-Qq' ]]; then exit 9; fi
case "$2" in
  pipewire) exit 0 ;;
  wireplumber) exit 2 ;;
  *) exit 1 ;;
esac
"""
    )
    pacman.chmod(0o755)
    env = os.environ.copy()
    env["PATH"] = f"{mock_dir}:{env['PATH']}"
    checked = json.loads(run_tool("--profile", "vm", "--check-installed", "--json", env=env).stdout)
    statuses = {
        row["package"]: (row["installed_status"], row["query_exit"])
        for row in checked["applicable_candidates"]
    }
    expected = {
        "pipewire": ("installed", 0),
        "wireplumber": ("query-failed", 2),
        "xdg-desktop-portal": ("missing", 1),
    }
    for package, expected_status in expected.items():
        actual = statuses.get(package)
        if actual != expected_status:
            raise SystemExit(f"unexpected mocked pacman status for {package}: {actual}")
    checked_transaction = checked["review_transaction"]
    if checked_transaction.get("installed_state_checked") is not True:
        raise SystemExit("checked review transaction did not record installed-state query")
    if checked_transaction.get("installed_proposed_packages") != ["pipewire"]:
        raise SystemExit(
            f"unexpected installed proposed packages: {checked_transaction.get('installed_proposed_packages')}"
        )
    if "xdg-desktop-portal" not in checked_transaction.get("missing_proposed_packages", []):
        raise SystemExit("missing proposed package was not classified in the review transaction")
    if checked_transaction.get("query_failed_proposed_packages") != ["wireplumber"]:
        raise SystemExit(
            f"unexpected failed proposed package queries: {checked_transaction.get('query_failed_proposed_packages')}"
        )
    classified = (
        checked_transaction.get("installed_proposed_packages", [])
        + checked_transaction.get("missing_proposed_packages", [])
        + checked_transaction.get("query_failed_proposed_packages", [])
    )
    if "alsa-utils" in classified:
        raise SystemExit("optional packages must not leak into proposed installed-state buckets")
    if sorted(classified) != checked_transaction.get("proposed_official_packages"):
        raise SystemExit("checked proposed status buckets must classify every proposed package exactly once")
PY

printf 'Phase C planning checks passed.\n'
