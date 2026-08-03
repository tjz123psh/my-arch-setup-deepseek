#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

python - "$root" <<'PY'
from pathlib import Path
import json
import os
import subprocess
import sys
import tempfile

root = Path(sys.argv[1])
tool = root / "installer/phase-c-session-check.py"
if not tool.is_file() or tool.is_symlink():
    raise SystemExit("Phase C session checker is missing or unsafe")


def write_executable(path: Path, body: str) -> None:
    path.write_text(f"#!{sys.executable}\n{body}")
    path.chmod(0o755)


def make_fixture(base: Path) -> tuple[Path, Path, Path, dict[str, str]]:
    bin_dir = base / "bin"
    data_root = base / "data"
    config_home = base / "config"
    bin_dir.mkdir()
    config_home.mkdir()

    portal_dir = data_root / "xdg-desktop-portal"
    autostart_dir = data_root / "xdg" / "autostart"
    portal_dir.mkdir(parents=True)
    autostart_dir.mkdir(parents=True)
    (config_home / "hypr" / "conf").mkdir(parents=True)
    (config_home / "hypr" / "hyprland.lua").write_text(
        'hl.on("hyprland.start", function()\n'
        '    hl.exec_cmd("pgrep -x fcitx5 >/dev/null || fcitx5 -d")\n'
        'end)\n'
    )
    (portal_dir / "niri-portals.conf").write_text(
        "[preferred]\n"
        "default=gnome;gtk;\n"
        "org.freedesktop.impl.portal.Access=gtk;\n"
        "org.freedesktop.impl.portal.Notification=gtk;\n"
    )
    (portal_dir / "hyprland-portals.conf").write_text(
        "[preferred]\n"
        "default=hyprland;gtk;\n"
    )
    (autostart_dir / "org.fcitx.Fcitx5.desktop").write_text(
        "[Desktop Entry]\nType=Application\nExec=/usr/bin/fcitx5\n"
    )
    (autostart_dir / "blueman.desktop").write_text(
        "[Desktop Entry]\nType=Application\nExec=blueman-applet\n"
    )
    (config_home / "hypr" / "conf" / "autostart.lua").write_text(
        'hl.on("hyprland.start", function()\n'
        '    hl.exec_cmd("pgrep -x fcitx5 >/dev/null || fcitx5 -d")\n'
        '    hl.exec_cmd("pgrep -x blueman-applet >/dev/null || blueman-applet")\n'
        'end)\n'
    )

    write_executable(
        bin_dir / "systemctl",
        r'''import os
import sys

scenario = os.environ.get("MOCK_SCENARIO", "niri-ready")
profile = os.environ.get("MOCK_PROFILE", "physical")
desktop = os.environ.get("XDG_CURRENT_DESKTOP", "niri").strip().lower()
args = sys.argv[1:]

if args[:2] == ["--global", "is-enabled"]:
    unit = args[2]
    if scenario == "global-query-failed" and unit == "wireplumber.service":
        print("failed to query global state", file=sys.stderr)
        raise SystemExit(2)
    if scenario == "global-disabled" and unit == "wireplumber.service":
        print("disabled")
        raise SystemExit(1)
    if scenario == "global-not-found" and unit == "wireplumber.service":
        print("not-found")
        raise SystemExit(4)
    if unit in {"pipewire.socket", "pipewire-pulse.socket", "wireplumber.service"}:
        print("enabled")
        raise SystemExit(0)
    print("disabled")
    raise SystemExit(1)

if args and args[0] == "--user":
    args = args[1:]
    scope = "user"
else:
    scope = "system"

if args == ["list-units", "--failed", "--output=json"]:
    if scenario == "failed-units-json-malformed" and scope == "user":
        print("{not-json")
        raise SystemExit(0)
    print("[]")
    raise SystemExit(0)

if len(args) == 4 and args[0] == "show" and args[2] == "--property" and args[3] == "LoadState,ActiveState,SubState,UnitFileState":
    unit = args[1]
    if scenario == "systemctl-query-failed" and unit == "xdg-desktop-portal.service":
        print("user manager unavailable", file=sys.stderr)
        raise SystemExit(1)
    if scope == "system":
        if profile == "vm":
            raise SystemExit(88)
        states = {
            "bluetooth.service": ("loaded", "active", "running", "enabled"),
            "power-profiles-daemon.service": ("loaded", "active", "running", "enabled"),
        }
    else:
        common = {
            "xdg-desktop-portal.service": ("loaded", "active", "running", "static"),
            "xdg-desktop-portal-gtk.service": ("loaded", "active", "running", "static"),
            "pipewire.socket": ("loaded", "active", "listening", "enabled"),
            "pipewire-pulse.socket": ("loaded", "active", "listening", "enabled"),
            "wireplumber.service": ("loaded", "active", "running", "enabled"),
        }
        if desktop == "hyprland":
            states = common | {
                "xdg-desktop-portal-gnome.service": ("loaded", "inactive", "dead", "static"),
                "xdg-desktop-portal-hyprland.service": ("loaded", "active", "running", "static"),
                "xdg-desktop-autostart.target": ("loaded", "inactive", "dead", "static"),
                "app-org.fcitx.Fcitx5@autostart.service": ("not-found", "inactive", "dead", ""),
                "app-blueman@autostart.service": ("not-found", "inactive", "dead", ""),
            }
        else:
            states = common | {
                "xdg-desktop-portal-gnome.service": ("loaded", "active", "running", "static"),
                "xdg-desktop-portal-hyprland.service": ("not-found", "inactive", "dead", ""),
                "xdg-desktop-autostart.target": ("loaded", "active", "active", "static"),
                "app-org.fcitx.Fcitx5@autostart.service": ("loaded", "active", "running", "generated"),
                "app-blueman@autostart.service": ("loaded", "active", "running", "generated"),
            }
        if scenario == "wrong-portal" and desktop == "niri" and unit == "xdg-desktop-portal-gnome.service":
            states[unit] = ("loaded", "inactive", "dead", "static")
        if scenario == "duplicate-owner" and desktop == "hyprland" and unit == "app-org.fcitx.Fcitx5@autostart.service":
            states[unit] = ("loaded", "active", "running", "generated")
        if scenario == "duplicate-owner" and desktop == "hyprland" and unit == "app-blueman@autostart.service":
            states[unit] = ("loaded", "active", "running", "generated")
    state = states.get(unit, ("not-found", "inactive", "dead", ""))
    print("\n".join(state))
    raise SystemExit(0)

raise SystemExit(9)
''',
    )

    write_executable(
        bin_dir / "pacman",
        r'''import os
import sys

scenario = os.environ.get("MOCK_SCENARIO", "niri-ready")
selection = os.environ.get("MOCK_SELECTION", "niri")
profile = os.environ.get("MOCK_PROFILE", "physical")
installed = {
    "xdg-desktop-portal", "xdg-desktop-portal-gtk", "pipewire", "pipewire-pulse",
    "wireplumber", "fcitx5"
}
if profile == "physical":
    installed.update({"power-profiles-daemon", "blueman", "bluez", "bluez-utils"})
if selection in {"niri", "both"}:
    installed.add("xdg-desktop-portal-gnome")
if selection in {"hyprland", "both"}:
    installed.add("xdg-desktop-portal-hyprland")
if scenario in {"installed-conflict", "installed-audio-conflict"}:
    installed.add("pulseaudio")
if scenario == "installed-power-conflict":
    installed.add("tuned")
if scenario == "unexpected-portal-package":
    installed.add("xdg-desktop-portal-wlr")
args = sys.argv[1:]
if args == ["-Qq"]:
    if scenario == "conflict-query-failed":
        print("error: local database unavailable", file=sys.stderr)
        raise SystemExit(1)
    print("\n".join(sorted(installed)))
    raise SystemExit(0)
raise SystemExit(9)
''',
    )

    write_executable(
        bin_dir / "pgrep",
        r'''import os
import sys

scenario = os.environ.get("MOCK_SCENARIO", "niri-ready")
profile = os.environ.get("MOCK_PROFILE", "physical")
name = sys.argv[-1]
if profile == "vm" and name == "blueman-applet":
    raise SystemExit(88)
counts = {"fcitx5": 1, "blueman-applet": 1}
if scenario == "missing-fcitx-process" and name == "fcitx5":
    counts[name] = 0
if scenario == "duplicate-process" and name == "fcitx5":
    counts[name] = 2
if scenario == "missing-process" and name == "blueman-applet":
    counts[name] = 0
for index in range(counts.get(name, 0)):
    print(1000 + index)
raise SystemExit(0 if counts.get(name, 0) else 1)
''',
    )

    write_executable(
        bin_dir / "busctl",
        r'''import json
import os
import sys

scenario = os.environ.get("MOCK_SCENARIO", "niri-ready")
profile = os.environ.get("MOCK_PROFILE", "physical")
desktop = os.environ.get("XDG_CURRENT_DESKTOP", "niri").strip().lower()
if scenario == "bus-query-failed":
    print("bus unavailable", file=sys.stderr)
    raise SystemExit(1)
if sys.argv[1:] == ["--user", "--json=short", "list"]:
    if scenario == "bus-json-malformed":
        print("{not-json")
        raise SystemExit(0)
    names = [
        "org.freedesktop.portal.Desktop",
        "org.freedesktop.impl.portal.desktop.gtk",
        "org.freedesktop.portal.Fcitx",
    ]
    if desktop == "hyprland":
        names.append("org.freedesktop.impl.portal.desktop.hyprland")
    else:
        names.append("org.freedesktop.impl.portal.desktop.gnome")
    records = [{"name": name, "connection": f":1.{index + 10}"} for index, name in enumerate(names)]
    if scenario == "activatable-extra-portal" and desktop == "niri":
        records.append({
            "name": "org.freedesktop.impl.portal.desktop.hyprland",
            "connection": "(activatable)",
        })
    if scenario == "active-extra-portal" and desktop == "niri":
        records.append({
            "name": "org.freedesktop.impl.portal.desktop.wlr",
            "connection": ":1.99",
        })
    print(json.dumps(records))
    raise SystemExit(0)
if sys.argv[1:] == ["--system", "--json=short", "list"]:
    if profile == "vm":
        raise SystemExit(88)
    names = ["org.bluez", "net.hadess.PowerProfiles", "org.freedesktop.UPower"]
    print(json.dumps([{"name": name} for name in names]))
    raise SystemExit(0)
raise SystemExit(9)
''',
    )

    write_executable(
        bin_dir / "wpctl",
        r'''import os
import sys
if os.environ.get("MOCK_SCENARIO") == "wpctl-query-failed":
    raise SystemExit(2)
if sys.argv[1:] == ["status", "-n"]:
    print("PipeWire 'pipewire-0'\nAudio\n Sinks:\n Sources:")
    raise SystemExit(0)
raise SystemExit(9)
''',
    )

    write_executable(
        bin_dir / "pactl",
        r'''import os
import sys
if os.environ.get("MOCK_SCENARIO") == "pactl-query-failed":
    raise SystemExit(1)
if sys.argv[1:] == ["info"]:
    print("Server Name: PulseAudio (on PipeWire 1.6.8)")
    raise SystemExit(0)
raise SystemExit(9)
''',
    )

    write_executable(
        bin_dir / "powerprofilesctl",
        r'''import os
import sys
if os.environ.get("MOCK_PROFILE") == "vm":
    raise SystemExit(88)
if sys.argv[1:] == ["list"]:
    print("* balanced:\n  power-saver:")
    raise SystemExit(0)
raise SystemExit(9)
''',
    )

    write_executable(
        bin_dir / "bluetoothctl",
        r'''import os
import sys
if os.environ.get("MOCK_PROFILE") == "vm":
    raise SystemExit(88)
if sys.argv[1:] == ["show"]:
    if os.environ.get("MOCK_SCENARIO") == "no-bluetooth-controller":
        print("No default controller available", file=sys.stderr)
        raise SystemExit(1)
    print("Controller 00:11:22:33:44:55 Fixture")
    raise SystemExit(0)
raise SystemExit(9)
''',
    )

    env = os.environ.copy()
    env["PATH"] = str(bin_dir)
    env["LC_ALL"] = "C"
    env["XDG_CONFIG_DIRS"] = str(base / "config-dirs")
    env["XDG_DATA_DIRS"] = str(data_root)
    env["XDG_DATA_HOME"] = str(base / "data-home")
    env["XDG_CONFIG_HOME"] = str(config_home)
    env["PHASE_C_SYSTEM_CONFIG_ROOTS"] = str(base / "system-config")
    return bin_dir, data_root, config_home, env


def run_tool(
    env: dict[str, str],
    *,
    session: str,
    scenario: str,
    selection: str | None = None,
    json_output: bool = True,
    active_desktop: str | None = None,
    path_override: str | None = None,
    profile: str | None = None,
) -> subprocess.CompletedProcess[str]:
    call_env = env.copy()
    call_env["MOCK_SCENARIO"] = scenario
    call_env["MOCK_SELECTION"] = selection or session
    call_env["MOCK_PROFILE"] = profile or "physical"
    call_env["XDG_CURRENT_DESKTOP"] = active_desktop or session
    call_env["XDG_SESSION_TYPE"] = "wayland"
    if path_override is not None:
        call_env["PATH"] = path_override
    args = [sys.executable, str(tool), "--session", session]
    if profile is not None:
        args.extend(["--profile", profile])
    if selection is not None:
        args.extend(["--selection", selection])
    if json_output:
        args.append("--json")

    portal_file = (
        Path(env["XDG_DATA_DIRS"])
        / "xdg-desktop-portal"
        / f"{session}-portals.conf"
    )
    override_file = Path(env["PHASE_C_SYSTEM_CONFIG_ROOTS"]) / "portals.conf"
    original_portal = portal_file.read_text()
    override_existed = override_file.exists()
    original_override = override_file.read_text() if override_existed else None
    if scenario == "malformed-portal":
        portal_file.write_text("[preferred\ndefault=broken")
    if scenario == "portal-override":
        override_file.parent.mkdir(parents=True, exist_ok=True)
        override_file.write_text("[preferred]\ndefault=gtk;\n")
    try:
        return subprocess.run(
            args,
            check=False,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=call_env,
        )
    finally:
        portal_file.write_text(original_portal)
        if override_existed:
            override_file.write_text(original_override or "")
        elif override_file.exists():
            override_file.unlink()


with tempfile.TemporaryDirectory() as temporary:
    _bin_dir, _data_root, _config_home, env = make_fixture(Path(temporary))

    niri_result = run_tool(env, session="niri", scenario="niri-ready")
    if niri_result.returncode != 0:
        raise SystemExit(f"ready Niri fixture failed: rc={niri_result.returncode} stderr={niri_result.stderr}")
    niri = json.loads(niri_result.stdout)
    if niri["safety"] != {
        "read_only": True,
        "installer_apply_integration": False,
        "system_changes": False,
        "manual_interactive_checks": False,
    }:
        raise SystemExit(f"unexpected safety block: {niri['safety']}")
    if niri["overall"] != {
        "result": "ready",
        "exit_code": 0,
        "blockers": [],
        "unavailable_checks": [],
        "warnings": [],
    }:
        raise SystemExit(f"unexpected ready result: {niri['overall']}")
    if niri["portal"]["expected_backends"] != ["gnome", "gtk"]:
        raise SystemExit(f"unexpected Niri portal expectation: {niri['portal']}")
    if niri["startup"]["owner"] != "xdg-autostart" or niri["startup"]["fcitx_process_count"] != 1:
        raise SystemExit(f"unexpected Niri startup evidence: {niri['startup']}")
    if niri["checks"]["audio-conflict-packages"]["status"] != "pass":
        raise SystemExit("clean Niri fixture should pass audio conflict checks")
    if niri["checks"]["power-conflict-packages"]["status"] != "pass":
        raise SystemExit("clean physical Niri fixture should pass power conflict checks")

    vm_niri_result = run_tool(
        env, session="niri", scenario="niri-ready", profile="vm"
    )
    if vm_niri_result.returncode != 0:
        raise SystemExit(
            f"ready VM Niri fixture failed: rc={vm_niri_result.returncode} "
            f"stderr={vm_niri_result.stderr}"
        )
    vm_niri = json.loads(vm_niri_result.stdout)
    if vm_niri.get("profile") != "vm" or vm_niri["overall"]["result"] != "ready":
        raise SystemExit(f"unexpected VM Niri result: {vm_niri.get('overall')}")
    physical_packages = {"bluez", "bluez-utils", "blueman", "power-profiles-daemon"}
    if physical_packages & set(vm_niri["packages"]["required"]):
        raise SystemExit("VM checker retained physical-only package requirements")
    for check_id in (
        "system-services", "system-bus", "power-profiles", "bluetooth-controller"
    ):
        if vm_niri["checks"][check_id]["status"] != "not-applicable":
            raise SystemExit(f"VM checker did not defer {check_id}")
    if vm_niri["startup"]["fcitx_process_count"] != 1:
        raise SystemExit("VM Niri checker lost the Fcitx owner")
    if vm_niri["startup"]["blueman_process"]["status"] != "not-applicable":
        raise SystemExit("VM Niri checker queried physical Blueman ownership")
    if vm_niri["checks"]["startup-owner"]["status"] != "pass":
        raise SystemExit("VM Niri startup owner did not pass")

    vm_hypr_result = run_tool(
        env, session="hyprland", scenario="hyprland-ready", profile="vm"
    )
    if vm_hypr_result.returncode != 0:
        raise SystemExit(
            f"ready VM Hyprland fixture failed: rc={vm_hypr_result.returncode} "
            f"stderr={vm_hypr_result.stderr}"
        )
    vm_hypr = json.loads(vm_hypr_result.stdout)
    if vm_hypr.get("profile") != "vm" or vm_hypr["overall"]["result"] != "ready":
        raise SystemExit(f"unexpected VM Hyprland result: {vm_hypr.get('overall')}")
    if vm_hypr["startup"]["hyprland_config"]["status"] != "ok":
        raise SystemExit("VM Hyprland startup config was not inspected")
    if vm_hypr["startup"]["hyprland_config"]["guards"] != {"fcitx5": True}:
        raise SystemExit("VM Hyprland startup guard set differs")
    if vm_hypr["checks"]["startup-owner"]["status"] != "pass":
        raise SystemExit("VM Hyprland startup owner did not pass")

    hyprland_path = _config_home / "hypr" / "hyprland.lua"
    valid_hyprland = hyprland_path.read_text()
    for label, invalid_text in (
        ("comment-only", '-- disabled: hl.exec_cmd("pgrep -x fcitx5 >/dev/null || fcitx5 -d")\n'),
        (
            "unreachable-branch",
            'hl.on("hyprland.start", function()\n'
            '    if false then\n'
            '        hl.exec_cmd("pgrep -x fcitx5 >/dev/null || fcitx5 -d")\n'
            '    end\n'
            'end)\n',
        ),
    ):
        hyprland_path.write_text(invalid_text)
        invalid_result = run_tool(
            env, session="hyprland", scenario="hyprland-ready", profile="vm"
        )
        if invalid_result.returncode != 1:
            raise SystemExit(f"{label} Hyprland guard should block with exit 1")
        invalid_report = json.loads(invalid_result.stdout)
        if invalid_report["startup"]["hyprland_config"]["guards"] != {"fcitx5": False}:
            raise SystemExit(f"{label} Hyprland guard was treated as executable")
        if invalid_report["checks"]["startup-owner"]["status"] != "fail":
            raise SystemExit(f"{label} Hyprland startup ownership did not fail")
    hyprland_path.write_text(valid_hyprland)

    vm_selected_query_failure = run_tool(
        env, session="niri", scenario="wpctl-query-failed", profile="vm"
    )
    if vm_selected_query_failure.returncode != 2:
        raise SystemExit("VM profile hid an applicable audio query failure")

    vm_missing_fcitx = run_tool(
        env, session="niri", scenario="missing-fcitx-process", profile="vm"
    )
    if vm_missing_fcitx.returncode != 1:
        raise SystemExit("VM profile did not block a missing Fcitx process")
    vm_missing_fcitx_report = json.loads(vm_missing_fcitx.stdout)
    if vm_missing_fcitx_report["checks"]["startup-owner"]["status"] != "fail":
        raise SystemExit("VM Fcitx startup failure was not retained")

    vm_power_conflict = run_tool(
        env, session="niri", scenario="installed-power-conflict", profile="vm"
    )
    if vm_power_conflict.returncode != 0:
        raise SystemExit("VM profile applied an unselected physical power conflict")
    vm_power_report = json.loads(vm_power_conflict.stdout)
    if vm_power_report["checks"]["audio-conflict-packages"]["status"] != "pass":
        raise SystemExit("VM power fixture did not keep audio conflicts applicable")
    if vm_power_report["checks"]["power-conflict-packages"]["status"] != "not-applicable":
        raise SystemExit("VM power conflicts were reported as passing instead of not-applicable")
    if vm_power_report["packages"]["power_conflicts"]:
        raise SystemExit("VM package evidence retained nonapplicable power conflict records")

    vm_audio_conflict = run_tool(
        env, session="niri", scenario="installed-audio-conflict", profile="vm"
    )
    if vm_audio_conflict.returncode != 1:
        raise SystemExit("VM profile hid an applicable audio owner conflict")
    vm_audio_report = json.loads(vm_audio_conflict.stdout)
    if vm_audio_report["checks"]["audio-conflict-packages"]["status"] != "fail":
        raise SystemExit("VM audio conflict did not fail its applicable check")
    if vm_audio_report["checks"]["power-conflict-packages"]["status"] != "not-applicable":
        raise SystemExit("VM audio fixture applied the physical power check")

    missing_process_result = run_tool(env, session="niri", scenario="missing-process")
    if missing_process_result.returncode != 1:
        raise SystemExit(f"successful empty pgrep result should still block, got {missing_process_result.returncode}")
    missing_process = json.loads(missing_process_result.stdout)
    if missing_process["startup"]["blueman_process"] != {
        "status": "ok",
        "query_exit": 1,
        "count": 0,
        "pids": [],
    }:
        raise SystemExit(f"empty pgrep result was misclassified: {missing_process['startup']['blueman_process']}")

    disabled_result = run_tool(env, session="niri", scenario="global-disabled")
    if disabled_result.returncode != 1:
        raise SystemExit(f"disabled global unit should block with exit 1, got {disabled_result.returncode}")
    disabled = json.loads(disabled_result.stdout)
    if disabled["global_user_units"]["wireplumber.service"]["status"] != "disabled":
        raise SystemExit("disabled global unit was confused with a failed query")

    not_found_result = run_tool(env, session="niri", scenario="global-not-found")
    if not_found_result.returncode != 1:
        raise SystemExit(
            f"not-found global unit should block with exit 1, got {not_found_result.returncode}"
        )
    not_found = json.loads(not_found_result.stdout)
    if not_found["global_user_units"]["wireplumber.service"] != {
        "status": "not-found",
        "state": "not-found",
        "query_exit": 4,
    }:
        raise SystemExit("not-found global unit was confused with a failed query")

    malformed_portal_result = run_tool(env, session="niri", scenario="malformed-portal")
    if malformed_portal_result.returncode != 2:
        raise SystemExit(f"malformed Portal config should be unavailable, got {malformed_portal_result.returncode}")
    malformed_portal = json.loads(malformed_portal_result.stdout)
    if malformed_portal["checks"]["portal-preference"]["status"] != "unavailable":
        raise SystemExit("malformed Portal config was not preserved as unavailable")

    override_result = run_tool(env, session="niri", scenario="portal-override")
    if override_result.returncode != 1:
        raise SystemExit(f"Portal override should block with exit 1, got {override_result.returncode}")
    override = json.loads(override_result.stdout)
    if override["checks"]["portal-overrides"]["status"] != "fail":
        raise SystemExit("Portal override was not treated as a deterministic blocker")

    mismatch_result = run_tool(
        env, session="niri", scenario="niri-ready", active_desktop="hyprland"
    )
    if mismatch_result.returncode != 1:
        raise SystemExit(f"session mismatch should block with exit 1, got {mismatch_result.returncode}")
    mismatch = json.loads(mismatch_result.stdout)
    if mismatch["checks"]["session-environment"]["status"] != "fail":
        raise SystemExit("active session mismatch was not blocked")

    missing_command_result = run_tool(
        env,
        session="niri",
        scenario="niri-ready",
        path_override=str(Path(env["PATH"]) / "does-not-exist"),
    )
    if missing_command_result.returncode != 2:
        raise SystemExit(f"missing command set should be unavailable, got {missing_command_result.returncode}")
    missing_command = json.loads(missing_command_result.stdout)
    if missing_command["bluetooth"]["status"] != "command-missing":
        raise SystemExit("missing bluetoothctl command was not preserved")

    text_result = run_tool(env, session="niri", scenario="niri-ready", json_output=False)
    if text_result.returncode != 0:
        raise SystemExit(f"ready text fixture failed: rc={text_result.returncode}")
    for marker in (
        "Phase C session/service acceptance (read-only)",
        "session: niri",
        "portal backend ownership: pass",
        "startup owner: xdg-autostart",
        "completion gate: this report never authorizes",
    ):
        if marker not in text_result.stdout:
            raise SystemExit(f"text output is missing marker: {marker}")

    hypr_result = run_tool(env, session="hyprland", scenario="hyprland-ready")
    if hypr_result.returncode != 0:
        raise SystemExit(f"ready Hyprland fixture failed: rc={hypr_result.returncode} stderr={hypr_result.stderr}")
    hypr = json.loads(hypr_result.stdout)
    if hypr["portal"]["expected_backends"] != ["hyprland", "gtk"]:
        raise SystemExit(f"unexpected Hyprland portal expectation: {hypr['portal']}")
    if hypr["startup"]["owner"] != "hyprland-config":
        raise SystemExit(f"unexpected Hyprland startup owner: {hypr['startup']}")
    if hypr["checks"]["xdg-autostart-owner"]["status"] != "not-applicable":
        raise SystemExit("plain Hyprland should not require the Niri XDG autostart owner")

    both_result = run_tool(env, session="niri", scenario="niri-ready", selection="both")
    if both_result.returncode != 0:
        raise SystemExit(f"both-WM Niri fixture failed: rc={both_result.returncode}")
    both = json.loads(both_result.stdout)
    if both["selection"] != "both" or both["portal"]["installed_matrix"] != [
        "xdg-desktop-portal",
        "xdg-desktop-portal-gnome",
        "xdg-desktop-portal-gtk",
        "xdg-desktop-portal-hyprland",
    ]:
        raise SystemExit(f"both-WM package matrix was not preserved: {both['portal']}")
    if both["portal"]["active_session_backends"] != ["gnome", "gtk"]:
        raise SystemExit("both-WM selection must still use only the active Niri backend set")

    activatable_extra_result = run_tool(
        env, session="niri", scenario="activatable-extra-portal"
    )
    if activatable_extra_result.returncode != 0:
        raise SystemExit(
            f"inactive activatable backend should not count as active, got {activatable_extra_result.returncode}"
        )
    activatable_extra = json.loads(activatable_extra_result.stdout)
    if activatable_extra["portal"]["bus_session_backends"] != ["gnome", "gtk"]:
        raise SystemExit("activatable-only backend was confused with an active D-Bus owner")

    active_extra_result = run_tool(env, session="niri", scenario="active-extra-portal")
    if active_extra_result.returncode != 1:
        raise SystemExit(
            f"active unknown Portal backend should block, got {active_extra_result.returncode}"
        )
    active_extra = json.loads(active_extra_result.stdout)
    if active_extra["portal"]["bus_session_backends"] != ["gnome", "gtk", "wlr"]:
        raise SystemExit("active unknown Portal backend was omitted from ownership evidence")

    unexpected_package_result = run_tool(
        env, session="niri", scenario="unexpected-portal-package"
    )
    if unexpected_package_result.returncode != 1:
        raise SystemExit(
            f"unexpected single-WM Portal package should block, got {unexpected_package_result.returncode}"
        )
    unexpected_package = json.loads(unexpected_package_result.stdout)
    if unexpected_package["checks"]["portal-package-matrix"]["status"] != "fail":
        raise SystemExit("unexpected Portal package did not fail the exact matrix gate")

    wrong_result = run_tool(env, session="niri", scenario="wrong-portal", selection="both")
    if wrong_result.returncode != 1:
        raise SystemExit(f"wrong active portal should block with exit 1, got {wrong_result.returncode}")
    wrong = json.loads(wrong_result.stdout)
    if wrong["checks"]["portal-backend-ownership"]["status"] != "fail":
        raise SystemExit(f"wrong active portal was not blocked: {wrong['checks']['portal-backend-ownership']}")

    duplicate_owner_result = run_tool(env, session="hyprland", scenario="duplicate-owner")
    if duplicate_owner_result.returncode != 1:
        raise SystemExit(f"duplicate startup owner should block with exit 1, got {duplicate_owner_result.returncode}")
    duplicate_owner = json.loads(duplicate_owner_result.stdout)
    if duplicate_owner["checks"]["startup-owner"]["status"] != "fail":
        raise SystemExit("duplicate Hyprland/Niri startup ownership was not blocked")

    conflict_result = run_tool(env, session="niri", scenario="installed-conflict")
    if conflict_result.returncode != 1:
        raise SystemExit(f"installed package conflict should block with exit 1, got {conflict_result.returncode}")
    conflict = json.loads(conflict_result.stdout)
    if conflict["packages"]["conflicts"]["pulseaudio"]["status"] != "installed":
        raise SystemExit("installed conflict package was not preserved")
    if conflict["checks"]["audio-conflict-packages"]["status"] != "fail":
        raise SystemExit("installed audio conflict should fail the audio conflict gate")
    if conflict["checks"]["power-conflict-packages"]["status"] != "pass":
        raise SystemExit("clean physical power conflicts should pass independently")

    conflict_failed_result = run_tool(env, session="niri", scenario="conflict-query-failed")
    if conflict_failed_result.returncode != 2:
        raise SystemExit(f"failed conflict query should exit 2, got {conflict_failed_result.returncode}")
    conflict_failed = json.loads(conflict_failed_result.stdout)
    record = conflict_failed["packages"]["conflicts"]["pulseaudio"]
    if record["status"] != "query-failed" or record["query_exit"] != 1:
        raise SystemExit(f"failed conflict query was misreported: {record}")
    if conflict_failed["overall"]["result"] != "unavailable":
        raise SystemExit("failed conflict query should make acceptance unavailable")
    if conflict_failed["checks"]["audio-conflict-packages"]["status"] != "unavailable":
        raise SystemExit("failed inventory did not make audio conflicts unavailable")
    if conflict_failed["checks"]["power-conflict-packages"]["status"] != "unavailable":
        raise SystemExit("failed physical inventory did not make power conflicts unavailable")

    global_failed_result = run_tool(env, session="niri", scenario="global-query-failed")
    if global_failed_result.returncode != 2:
        raise SystemExit(f"failed global unit query should exit 2, got {global_failed_result.returncode}")
    global_failed = json.loads(global_failed_result.stdout)
    if global_failed["global_user_units"]["wireplumber.service"]["status"] != "query-failed":
        raise SystemExit("failed global unit query was not preserved")

    systemctl_failed_result = run_tool(
        env, session="niri", scenario="systemctl-query-failed"
    )
    if systemctl_failed_result.returncode != 2:
        raise SystemExit(
            f"failed systemctl unit query should exit 2, got {systemctl_failed_result.returncode}"
        )
    systemctl_failed = json.loads(systemctl_failed_result.stdout)
    if systemctl_failed["portal"]["units"]["broker"]["status"] != "query-failed":
        raise SystemExit("failed systemctl unit query was not preserved")

    bus_failed_result = run_tool(env, session="niri", scenario="bus-query-failed")
    if bus_failed_result.returncode != 2:
        raise SystemExit(f"failed bus query should exit 2, got {bus_failed_result.returncode}")
    bus_failed = json.loads(bus_failed_result.stdout)
    if bus_failed["user_bus"]["status"] != "query-failed":
        raise SystemExit("failed bus query was not preserved")

    bus_malformed_result = run_tool(env, session="niri", scenario="bus-json-malformed")
    if bus_malformed_result.returncode != 2:
        raise SystemExit(f"malformed bus JSON should exit 2, got {bus_malformed_result.returncode}")
    bus_malformed = json.loads(bus_malformed_result.stdout)
    if bus_malformed["user_bus"]["status"] != "malformed-output":
        raise SystemExit("malformed bus JSON was not preserved")

    failed_units_malformed_result = run_tool(
        env, session="niri", scenario="failed-units-json-malformed"
    )
    if failed_units_malformed_result.returncode != 2:
        raise SystemExit(
            f"malformed failed-unit JSON should exit 2, got {failed_units_malformed_result.returncode}"
        )
    failed_units_malformed = json.loads(failed_units_malformed_result.stdout)
    if failed_units_malformed["checks"]["failed-user-units"]["status"] != "unavailable":
        raise SystemExit("malformed failed-unit JSON was not preserved")

    wpctl_failed_result = run_tool(env, session="niri", scenario="wpctl-query-failed")
    if wpctl_failed_result.returncode != 2:
        raise SystemExit(f"failed wpctl query should exit 2, got {wpctl_failed_result.returncode}")
    wpctl_failed = json.loads(wpctl_failed_result.stdout)
    if wpctl_failed["audio"]["wpctl"]["status"] != "query-failed":
        raise SystemExit("failed wpctl query was not preserved")

    pactl_failed_result = run_tool(env, session="niri", scenario="pactl-query-failed")
    if pactl_failed_result.returncode != 2:
        raise SystemExit(f"failed pactl query should exit 2, got {pactl_failed_result.returncode}")
    pactl_failed = json.loads(pactl_failed_result.stdout)
    if pactl_failed["audio"]["pactl"]["status"] != "query-failed":
        raise SystemExit("failed pactl query was not preserved")

    no_controller_result = run_tool(
        env, session="niri", scenario="no-bluetooth-controller"
    )
    if no_controller_result.returncode != 0:
        raise SystemExit(
            f"successful no-controller result should be not-applicable, got {no_controller_result.returncode}"
        )
    no_controller = json.loads(no_controller_result.stdout)
    if no_controller["checks"]["bluetooth-controller"]["status"] != "not-applicable":
        raise SystemExit("successful no-controller result was not preserved as not-applicable")

    process_result = run_tool(env, session="niri", scenario="duplicate-process")
    if process_result.returncode != 1:
        raise SystemExit(f"duplicate Fcitx process should block with exit 1, got {process_result.returncode}")
    process = json.loads(process_result.stdout)
    if process["startup"]["fcitx_process_count"] != 2:
        raise SystemExit("duplicate process count was not preserved")
PY

printf 'Phase C session checker tests passed.\n'
