#!/usr/bin/env python3
"""Read-only Phase C session and service acceptance checks.

This checker deliberately performs no package, service, configuration, boot, or
hardware changes.  It reports deterministic blockers separately from queries
that could not be completed, so a failed query is never treated as an empty or
healthy result.
"""

from __future__ import annotations

import argparse
import configparser
import json
import os
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable

SESSIONS = ("niri", "hyprland")
SELECTIONS = ("niri", "hyprland", "both")
PROFILES = ("physical", "vm")

PORTAL_PACKAGE_ORDER = (
    "xdg-desktop-portal",
    "xdg-desktop-portal-gnome",
    "xdg-desktop-portal-gtk",
    "xdg-desktop-portal-hyprland",
)
PORTAL_EXPECTATIONS = {
    "niri": ("gnome", "gtk"),
    "hyprland": ("hyprland", "gtk"),
}
PORTAL_PACKAGES = {
    "niri": {
        "xdg-desktop-portal",
        "xdg-desktop-portal-gnome",
        "xdg-desktop-portal-gtk",
    },
    "hyprland": {
        "xdg-desktop-portal",
        "xdg-desktop-portal-gtk",
        "xdg-desktop-portal-hyprland",
    },
    "both": set(PORTAL_PACKAGE_ORDER),
}
PORTAL_UNITS = {
    "broker": "xdg-desktop-portal.service",
    "gnome": "xdg-desktop-portal-gnome.service",
    "gtk": "xdg-desktop-portal-gtk.service",
    "hyprland": "xdg-desktop-portal-hyprland.service",
}
PORTAL_BUS_NAMES = {
    "broker": "org.freedesktop.portal.Desktop",
    "gnome": "org.freedesktop.impl.portal.desktop.gnome",
    "gtk": "org.freedesktop.impl.portal.desktop.gtk",
    "hyprland": "org.freedesktop.impl.portal.desktop.hyprland",
}

GLOBAL_USER_UNITS = (
    "pipewire.socket",
    "pipewire-pulse.socket",
    "wireplumber.service",
)
AUDIO_USER_UNITS = GLOBAL_USER_UNITS
SYSTEM_SERVICES = (
    "bluetooth.service",
    "power-profiles-daemon.service",
)
STARTUP_UNITS = (
    "xdg-desktop-autostart.target",
    "app-org.fcitx.Fcitx5@autostart.service",
    "app-blueman@autostart.service",
)
AUDIO_CONFLICT_PACKAGES = (
    "pulseaudio",
    "pipewire-media-session",
    "jack",
    "jack2",
)
POWER_CONFLICT_PACKAGES = (
    "tuned",
    "tuned-ppd",
    "tlp",
    "auto-cpufreq",
    "system76-power",
)
BASE_REQUIRED_PACKAGES = {
    "pipewire",
    "pipewire-pulse",
    "wireplumber",
    "fcitx5",
}
PHYSICAL_REQUIRED_PACKAGES = {
    "bluez",
    "bluez-utils",
    "blueman",
    "power-profiles-daemon",
}
SYSTEM_BUS_REQUIRED = (
    "org.bluez",
    "net.hadess.PowerProfiles",
    "org.freedesktop.UPower",
)
SYSTEMCTL_PROPERTIES = (
    "LoadState",
    "ActiveState",
    "SubState",
    "UnitFileState",
)


@dataclass(frozen=True)
class CommandResult:
    status: str
    returncode: int | None
    stdout: str
    stderr: str


def run_command(arguments: list[str]) -> CommandResult:
    """Run one read-only command while preserving missing/failed distinctions."""

    executable = shutil.which(arguments[0])
    if executable is None:
        return CommandResult("command-missing", None, "", "")
    try:
        command_environment = os.environ.copy()
        command_environment["LC_ALL"] = "C"
        command_environment["LANG"] = "C"
        completed = subprocess.run(
            [executable, *arguments[1:]],
            check=False,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=15,
            env=command_environment,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        return CommandResult("query-failed", None, "", str(error))
    return CommandResult(
        "ok" if completed.returncode == 0 else "query-failed",
        completed.returncode,
        completed.stdout,
        completed.stderr,
    )


def query_record(result: CommandResult, *, status: str | None = None) -> dict[str, Any]:
    record: dict[str, Any] = {
        "status": status or result.status,
        "query_exit": result.returncode,
    }
    if result.stderr.strip():
        record["error"] = result.stderr.strip().splitlines()[0][:240]
    return record


def check(status: str, detail: str) -> dict[str, str]:
    return {"status": status, "detail": detail}


def is_unavailable_record(record: dict[str, Any]) -> bool:
    return record.get("status") in {
        "command-missing",
        "query-failed",
        "malformed-output",
        "read-failed",
    }


def split_path_variable(name: str, defaults: Iterable[str]) -> list[Path]:
    raw = os.environ.get(name)
    values = raw.split(os.pathsep) if raw is not None else list(defaults)
    return [Path(value).expanduser() for value in values if value]


def deduplicate_paths(paths: Iterable[Path]) -> list[Path]:
    result: list[Path] = []
    seen: set[str] = set()
    for path in paths:
        key = str(path)
        if key in seen:
            continue
        seen.add(key)
        result.append(path)
    return result


def package_inventory(
    selection: str, profile: str
) -> tuple[dict[str, Any], set[str] | None]:
    result = run_command(["pacman", "-Qq"])
    required_names = set(BASE_REQUIRED_PACKAGES) | PORTAL_PACKAGES[selection]
    if profile == "physical":
        required_names.update(PHYSICAL_REQUIRED_PACKAGES)
    conflict_names = list(AUDIO_CONFLICT_PACKAGES)
    if profile == "physical":
        conflict_names.extend(POWER_CONFLICT_PACKAGES)
    if result.status != "ok":
        failure_status = result.status
        required = {
            name: {
                "status": failure_status,
                "query_exit": result.returncode,
            }
            for name in sorted(required_names)
        }
        conflicts = {
            name: {
                "status": failure_status,
                "query_exit": result.returncode,
            }
            for name in conflict_names
        }
        inventory = query_record(result)
        return {
            "inventory": inventory,
            "required": required,
            "conflicts": conflicts,
            "audio_conflicts": {
                name: conflicts[name] for name in AUDIO_CONFLICT_PACKAGES
            },
            "power_conflicts": {
                name: conflicts[name]
                for name in POWER_CONFLICT_PACKAGES
                if name in conflicts
            },
            "installed_count": None,
        }, None

    installed = {line.strip() for line in result.stdout.splitlines() if line.strip()}
    required = {
        name: {
            "status": "installed" if name in installed else "absent",
            "query_exit": 0,
        }
        for name in sorted(required_names)
    }
    conflicts = {
        name: {
            "status": "installed" if name in installed else "absent",
            "query_exit": 0,
        }
        for name in conflict_names
    }
    return {
        "inventory": {"status": "ok", "query_exit": 0},
        "required": required,
        "conflicts": conflicts,
        "audio_conflicts": {
            name: conflicts[name] for name in AUDIO_CONFLICT_PACKAGES
        },
        "power_conflicts": {
            name: conflicts[name]
            for name in POWER_CONFLICT_PACKAGES
            if name in conflicts
        },
        "installed_count": len(installed),
    }, installed


def parse_systemctl_show(result: CommandResult) -> dict[str, Any]:
    if result.status != "ok":
        return query_record(result)

    raw_lines = result.stdout.split("\n")
    # The fixture and some systemctl modes represent an empty UnitFileState
    # with a trailing blank line.  Preserve that field; dropping it would
    # incorrectly turn a successful four-field result into malformed output.
    if raw_lines and raw_lines[-1] == "":
        raw_lines = raw_lines[:-1]
    lines = [line.strip() for line in raw_lines]
    values: dict[str, str]
    if lines and all("=" in line for line in lines):
        values = {}
        for line in lines:
            key, value = line.split("=", 1)
            values[key] = value
        if any(property_name not in values for property_name in SYSTEMCTL_PROPERTIES):
            return {
                "status": "malformed-output",
                "query_exit": result.returncode,
            }
    elif len(lines) == len(SYSTEMCTL_PROPERTIES):
        values = dict(zip(SYSTEMCTL_PROPERTIES, lines, strict=True))
    else:
        return {
            "status": "malformed-output",
            "query_exit": result.returncode,
        }

    return {
        "status": "ok",
        "query_exit": 0,
        "load_state": values["LoadState"],
        "active_state": values["ActiveState"],
        "sub_state": values["SubState"],
        "unit_file_state": values["UnitFileState"],
    }


def systemctl_show(unit: str, *, user: bool) -> dict[str, Any]:
    arguments = ["systemctl"]
    if user:
        arguments.append("--user")
    arguments.extend(
        [
            "show",
            unit,
            "--property",
            ",".join(SYSTEMCTL_PROPERTIES),
        ]
    )
    return parse_systemctl_show(run_command(arguments))


def unit_active(record: dict[str, Any]) -> bool:
    return record.get("status") == "ok" and record.get("active_state") == "active"


def global_unit_state(unit: str) -> dict[str, Any]:
    result = run_command(["systemctl", "--global", "is-enabled", unit])
    output = result.stdout.strip().splitlines()
    state = output[0].strip() if output else ""
    if result.status == "command-missing":
        return query_record(result)
    if result.returncode == 0:
        return {
            "status": "enabled" if state == "enabled" else "enabled-other",
            "state": state,
            "query_exit": 0,
        }
    if result.returncode not in {None, 0} and state in {
        "disabled",
        "static",
        "indirect",
        "masked",
        "not-found",
        "generated",
        "transient",
    }:
        return {
            "status": state,
            "state": state,
            "query_exit": result.returncode,
        }
    return query_record(result)


def json_list_query(arguments: list[str], *, item_name_key: str | None = None) -> dict[str, Any]:
    result = run_command(arguments)
    if result.status != "ok":
        return query_record(result)
    try:
        value = json.loads(result.stdout)
    except json.JSONDecodeError:
        return {"status": "malformed-output", "query_exit": 0}
    if not isinstance(value, list):
        return {"status": "malformed-output", "query_exit": 0}
    if item_name_key is None:
        return {
            "status": "ok",
            "query_exit": 0,
            "items": value,
            "count": len(value),
        }
    names: list[str] = []
    for item in value:
        if not isinstance(item, dict) or not isinstance(item.get(item_name_key), str):
            return {"status": "malformed-output", "query_exit": 0}
        names.append(item[item_name_key])
    return {
        "status": "ok",
        "query_exit": 0,
        "names": sorted(set(names)),
        "count": len(value),
    }


def bus_query(user: bool) -> dict[str, Any]:
    result = run_command(
        ["busctl", "--user" if user else "--system", "--json=short", "list"]
    )
    if result.status != "ok":
        return query_record(result)
    try:
        value = json.loads(result.stdout)
    except json.JSONDecodeError:
        return {"status": "malformed-output", "query_exit": 0}
    if not isinstance(value, list):
        return {"status": "malformed-output", "query_exit": 0}

    names: list[str] = []
    owned_names: list[str] = []
    activatable_names: list[str] = []
    for item in value:
        if not isinstance(item, dict) or not isinstance(item.get("name"), str):
            return {"status": "malformed-output", "query_exit": 0}
        name = item["name"]
        names.append(name)
        if item.get("connection") == "(activatable)":
            activatable_names.append(name)
        else:
            # Older busctl JSON and the isolated fixture may omit ownership
            # fields.  Such records are still usable; the explicit
            # ``(activatable)`` marker is the stable negative signal.
            owned_names.append(name)
    return {
        "status": "ok",
        "query_exit": 0,
        "names": sorted(set(names)),
        "owned_names": sorted(set(owned_names)),
        "activatable_names": sorted(set(activatable_names)),
        "count": len(value),
    }


def failed_units_query(user: bool) -> dict[str, Any]:
    arguments = ["systemctl"]
    if user:
        arguments.append("--user")
    arguments.extend(["list-units", "--failed", "--output=json"])
    return json_list_query(arguments)


def portal_roots() -> tuple[list[Path], list[Path], list[Path]]:
    home = Path.home()
    config_home = Path(os.environ.get("XDG_CONFIG_HOME", home / ".config")).expanduser()
    data_home = Path(os.environ.get("XDG_DATA_HOME", home / ".local/share")).expanduser()
    config_dirs = split_path_variable("XDG_CONFIG_DIRS", ("/etc/xdg",))
    data_dirs = split_path_variable("XDG_DATA_DIRS", ("/usr/local/share", "/usr/share"))

    config_roots: list[Path] = [config_home / "xdg-desktop-portal"]
    config_roots.extend(path / "xdg-desktop-portal" for path in config_dirs)
    system_override_raw = os.environ.get("PHASE_C_SYSTEM_CONFIG_ROOTS")
    if system_override_raw is None:
        config_roots.append(Path("/etc/xdg-desktop-portal"))
    else:
        config_roots.extend(
            Path(value).expanduser()
            for value in system_override_raw.split(os.pathsep)
            if value
        )

    data_roots = [data_home / "xdg-desktop-portal"]
    data_roots.extend(path / "xdg-desktop-portal" for path in data_dirs)
    user_data_roots = [data_home / "xdg-desktop-portal"]
    return (
        deduplicate_paths(config_roots),
        deduplicate_paths(data_roots),
        deduplicate_paths(user_data_roots),
    )


def parse_portal_file(path: Path) -> dict[str, Any]:
    parser = configparser.ConfigParser(interpolation=None, strict=True)
    parser.optionxform = str
    try:
        with path.open(encoding="utf-8") as handle:
            parser.read_file(handle)
    except (OSError, UnicodeError):
        return {"status": "read-failed", "path": str(path)}
    except configparser.Error:
        return {"status": "malformed-output", "path": str(path)}
    if not parser.has_section("preferred") or not parser.has_option("preferred", "default"):
        return {"status": "malformed-output", "path": str(path)}
    raw_default = parser.get("preferred", "default")
    backends = [part.strip() for part in raw_default.split(";") if part.strip()]
    if not backends:
        return {"status": "malformed-output", "path": str(path)}
    return {
        "status": "ok",
        "path": str(path),
        "default": backends,
    }


def portal_configuration(session: str) -> dict[str, Any]:
    config_roots, data_roots, user_data_roots = portal_roots()
    expected_name = f"{session}-portals.conf"

    override_files: list[str] = []
    for root in config_roots:
        for filename in ("portals.conf", expected_name):
            candidate = root / filename
            if candidate.is_file() or candidate.is_symlink():
                override_files.append(str(candidate))
    for root in user_data_roots:
        candidate = root / expected_name
        if candidate.is_file() or candidate.is_symlink():
            override_files.append(str(candidate))

    preference_files = [
        root / expected_name
        for root in data_roots
        if (root / expected_name).is_file() and str(root / expected_name) not in override_files
    ]
    parsed = [parse_portal_file(path) for path in preference_files]
    return {
        "expected_file": expected_name,
        "config_roots": [str(path) for path in config_roots],
        "data_roots": [str(path) for path in data_roots],
        "override_files": sorted(set(override_files)),
        "preference_files": parsed,
    }


def autostart_file_candidates(filename: str) -> list[Path]:
    home = Path.home()
    config_home = Path(os.environ.get("XDG_CONFIG_HOME", home / ".config")).expanduser()
    roots = [config_home / "autostart"]
    roots.extend(
        path / "autostart"
        for path in split_path_variable("XDG_CONFIG_DIRS", ("/etc/xdg",))
    )
    # The extra data-root form is intentionally recognized for isolated fixture
    # and image validation without changing the standard XDG config locations.
    roots.extend(
        path / "xdg" / "autostart"
        for path in split_path_variable("XDG_DATA_DIRS", ("/usr/local/share", "/usr/share"))
    )
    return [root / filename for root in deduplicate_paths(roots)]


def find_autostart_file(filename: str) -> dict[str, Any]:
    candidates = autostart_file_candidates(filename)
    found = [str(path) for path in candidates if path.is_file() and not path.is_symlink()]
    return {
        "status": "present" if found else "absent",
        "paths": found,
    }


def lua_without_comments(text: str) -> str:
    """Remove Lua comments while preserving strings and line boundaries."""

    output: list[str] = []
    index = 0
    quote: str | None = None
    block_end: str | None = None
    while index < len(text):
        character = text[index]
        if block_end is not None:
            if text.startswith(block_end, index):
                index += len(block_end)
                block_end = None
            else:
                if character == "\n":
                    output.append(character)
                index += 1
            continue
        if quote is not None:
            output.append(character)
            if character == "\\" and index + 1 < len(text):
                index += 1
                output.append(text[index])
            elif character == quote:
                quote = None
            index += 1
            continue
        if text.startswith("--", index):
            long_comment = re.match(r"--\[(=*)\[", text[index:])
            if long_comment is not None:
                block_end = "]" + long_comment.group(1) + "]"
                index += long_comment.end()
                continue
            newline = text.find("\n", index)
            if newline == -1:
                break
            output.append("\n")
            index = newline + 1
            continue
        if character in {"'", '"'}:
            quote = character
        output.append(character)
        index += 1
    return "".join(output)


def hyprland_startup_has_direct_command(text: str, command: str) -> bool:
    """Require a direct command in an executable hyprland.start callback.

    A full-text substring is insufficient: comments and unreachable nested
    branches must never establish startup ownership.
    """

    start_pattern = re.compile(
        r"^\s*hl\.on\(\s*(['\"])hyprland\.start\1\s*,\s*function\s*\(\s*\)\s*$"
    )
    end_pattern = re.compile(r"^\s*end\s*\)\s*;?\s*$")
    command_pattern = re.compile(
        r"^\s*hl\.exec_cmd\(\s*(['\"])"
        + re.escape(command)
        + r"\1\s*\)\s*;?\s*$"
    )
    nested_open = re.compile(
        r"^\s*(?:if\b.*\bthen|for\b.*\bdo|while\b.*\bdo|repeat\b|do\b|"
        r"(?:local\s+)?function\b)"
    )
    nested_close = re.compile(r"^\s*(?:end\b|until\b)")

    in_startup = False
    depth = 0
    for line in lua_without_comments(text).splitlines():
        if not in_startup:
            if start_pattern.fullmatch(line):
                in_startup = True
                depth = 0
            continue
        if depth == 0 and end_pattern.fullmatch(line):
            in_startup = False
            continue
        if depth == 0 and command_pattern.fullmatch(line):
            return True
        if nested_close.match(line) and depth > 0:
            depth -= 1
        # A one-line conditional is never accepted as a direct owner; counting
        # it is unnecessary because the command check above already rejected it.
        if nested_open.match(line) and not re.search(r"\bend\s*$", line):
            depth += 1
    return False


def hyprland_startup_config(profile: str) -> dict[str, Any]:
    config_home = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")).expanduser()
    if profile == "vm":
        path = config_home / "hypr" / "hyprland.lua"
    else:
        path = config_home / "hypr" / "conf" / "autostart.lua"
    try:
        text = path.read_text(encoding="utf-8")
    except FileNotFoundError:
        return {"status": "absent", "path": str(path)}
    except (OSError, UnicodeError):
        return {"status": "read-failed", "path": str(path)}
    guards = {
        "fcitx5": hyprland_startup_has_direct_command(
            text, "pgrep -x fcitx5 >/dev/null || fcitx5 -d"
        ),
    }
    if profile == "physical":
        guards["blueman-applet"] = hyprland_startup_has_direct_command(
            text, "pgrep -x blueman-applet >/dev/null || blueman-applet"
        )
    return {
        "status": "ok",
        "path": str(path),
        "guards": guards,
    }


def process_count(name: str) -> dict[str, Any]:
    result = run_command(["pgrep", "-x", name])
    if result.status == "command-missing":
        return query_record(result)
    if result.returncode == 1 and not result.stdout.strip():
        return {"status": "ok", "query_exit": 1, "count": 0, "pids": []}
    if result.returncode != 0:
        return query_record(result)
    pids: list[int] = []
    for line in result.stdout.splitlines():
        value = line.strip()
        if not value:
            continue
        if not value.isdigit():
            return {"status": "malformed-output", "query_exit": 0}
        pids.append(int(value))
    if not pids:
        return {"status": "malformed-output", "query_exit": 0}
    return {
        "status": "ok",
        "query_exit": 0,
        "count": len(pids),
        "pids": pids,
    }


def simple_text_query(arguments: list[str]) -> dict[str, Any]:
    result = run_command(arguments)
    if result.status != "ok":
        return query_record(result)
    return {
        "status": "ok",
        "query_exit": 0,
        "nonempty": bool(result.stdout.strip()),
        "output": result.stdout.strip(),
    }


def bluetooth_controller_query() -> dict[str, Any]:
    result = run_command(["bluetoothctl", "show"])
    combined = "\n".join((result.stdout, result.stderr))
    if result.status == "command-missing":
        return query_record(result)
    if result.returncode != 0:
        if "No default controller available" in combined:
            return {
                "status": "no-controller",
                "query_exit": result.returncode,
            }
        return query_record(result)
    controllers = [
        line.strip()
        for line in result.stdout.splitlines()
        if line.strip().startswith("Controller ")
    ]
    return {
        "status": "ok" if controllers else "no-controller",
        "query_exit": 0,
        "controller_count": len(controllers),
    }


def environment_desktops(raw: str) -> list[str]:
    return [part.lower() for part in re.split(r"[:;,\s]+", raw.strip()) if part]


def build_report(session: str, selection: str, profile: str) -> dict[str, Any]:
    checks: dict[str, dict[str, str]] = {}
    expected_backends = list(PORTAL_EXPECTATIONS[session])

    current_desktop_raw = os.environ.get("XDG_CURRENT_DESKTOP", "")
    session_type = os.environ.get("XDG_SESSION_TYPE", "")
    current_desktops = environment_desktops(current_desktop_raw)
    environment = {
        "requested_session": session,
        "xdg_current_desktop": current_desktop_raw,
        "xdg_session_type": session_type,
    }
    if session not in current_desktops or session_type.lower() != "wayland":
        checks["session-environment"] = check(
            "fail",
            "the requested compositor is not the active XDG Wayland session",
        )
    else:
        checks["session-environment"] = check(
            "pass",
            "the requested compositor matches the active XDG Wayland session",
        )

    if selection != "both" and selection != session:
        checks["selection-session"] = check(
            "fail",
            "the active session is not included in the selected compositor set",
        )
    else:
        checks["selection-session"] = check(
            "pass",
            "the active session is included in the selected compositor set",
        )

    packages, installed = package_inventory(selection, profile)
    if installed is None:
        checks["package-inventory"] = check(
            "unavailable",
            "the installed package inventory query did not complete",
        )
    else:
        checks["package-inventory"] = check(
            "pass",
            "the installed package inventory query completed",
        )

    required_records = packages["required"]
    if any(is_unavailable_record(record) for record in required_records.values()):
        checks["required-packages"] = check(
            "unavailable",
            "required package presence could not be determined",
        )
    elif any(record["status"] != "installed" for record in required_records.values()):
        checks["required-packages"] = check(
            "fail",
            "one or more acceptance packages are absent",
        )
    else:
        checks["required-packages"] = check(
            "pass",
            "all acceptance packages for the selected session set are installed",
        )

    audio_conflict_records = packages["audio_conflicts"]
    if any(
        is_unavailable_record(record) for record in audio_conflict_records.values()
    ):
        checks["audio-conflict-packages"] = check(
            "unavailable",
            "the exact-name audio conflict package query did not complete",
        )
    elif any(
        record["status"] == "installed" for record in audio_conflict_records.values()
    ):
        checks["audio-conflict-packages"] = check(
            "fail",
            "one or more exact-name audio conflict packages are installed",
        )
    else:
        checks["audio-conflict-packages"] = check(
            "pass",
            "all exact-name audio conflict packages are absent",
        )

    if profile == "vm":
        checks["power-conflict-packages"] = check(
            "not-applicable",
            "physical power-owner conflict packages are outside the VM profile",
        )
    else:
        power_conflict_records = packages["power_conflicts"]
        if any(
            is_unavailable_record(record)
            for record in power_conflict_records.values()
        ):
            checks["power-conflict-packages"] = check(
                "unavailable",
                "the exact-name power conflict package query did not complete",
            )
        elif any(
            record["status"] == "installed"
            for record in power_conflict_records.values()
        ):
            checks["power-conflict-packages"] = check(
                "fail",
                "one or more exact-name power conflict packages are installed",
            )
        else:
            checks["power-conflict-packages"] = check(
                "pass",
                "all exact-name power conflict packages are absent",
            )

    portal_config = portal_configuration(session)
    preference_files = portal_config["preference_files"]
    if any(is_unavailable_record(record) for record in preference_files):
        checks["portal-preference"] = check(
            "unavailable",
            "the desktop Portal preference file could not be parsed",
        )
    elif len(preference_files) != 1:
        checks["portal-preference"] = check(
            "fail",
            "exactly one package-owned desktop Portal preference file is required",
        )
    elif preference_files[0]["default"] != expected_backends:
        checks["portal-preference"] = check(
            "fail",
            "the package-owned Portal preference does not select the expected backends",
        )
    else:
        checks["portal-preference"] = check(
            "pass",
            "the package-owned Portal preference selects the expected backends",
        )

    if portal_config["override_files"]:
        checks["portal-overrides"] = check(
            "fail",
            "a user or system Portal override exists outside the package-owned baseline",
        )
    else:
        checks["portal-overrides"] = check(
            "pass",
            "no user or system Portal override was found",
        )

    installed_matrix = (
        sorted(
            name
            for name in installed
            if name == "xdg-desktop-portal"
            or name.startswith("xdg-desktop-portal-")
        )
        if installed is not None
        else []
    )
    expected_matrix = [
        name for name in PORTAL_PACKAGE_ORDER if name in PORTAL_PACKAGES[selection]
    ]
    if installed is None:
        checks["portal-package-matrix"] = check(
            "unavailable",
            "Portal package presence could not be determined",
        )
    elif installed_matrix != expected_matrix:
        checks["portal-package-matrix"] = check(
            "fail",
            "the installed Portal package matrix differs from the selected session set",
        )
    else:
        checks["portal-package-matrix"] = check(
            "pass",
            "the selected Portal package matrix is installed",
        )

    portal_units = {
        name: systemctl_show(unit, user=True)
        for name, unit in PORTAL_UNITS.items()
    }
    user_bus = bus_query(user=True)
    active_backends = [
        backend for backend in expected_backends if unit_active(portal_units[backend])
    ]
    active_backends.extend(
        backend
        for backend in ("gnome", "gtk", "hyprland")
        if backend not in expected_backends and unit_active(portal_units[backend])
    )
    user_bus_names = set(user_bus.get("owned_names", []))
    portal_bus_prefix = "org.freedesktop.impl.portal.desktop."
    owned_bus_backends = {
        name.removeprefix(portal_bus_prefix)
        for name in user_bus_names
        if name.startswith(portal_bus_prefix)
    }
    bus_backends = [
        backend for backend in expected_backends if backend in owned_bus_backends
    ]
    bus_backends.extend(sorted(owned_bus_backends - set(expected_backends)))

    portal_query_records = list(portal_units.values()) + [user_bus]
    if any(is_unavailable_record(record) for record in portal_query_records):
        checks["portal-backend-ownership"] = check(
            "unavailable",
            "Portal unit or user-bus ownership could not be determined",
        )
    else:
        current_set = set(active_backends)
        bus_set = set(bus_backends)
        expected_set = set(expected_backends)
        broker_ready = unit_active(portal_units["broker"]) and (
            PORTAL_BUS_NAMES["broker"] in user_bus_names
        )
        if not broker_ready or current_set != expected_set or bus_set != expected_set:
            checks["portal-backend-ownership"] = check(
                "fail",
                "the active Portal unit and D-Bus backend set is not owned by this session",
            )
        else:
            checks["portal-backend-ownership"] = check(
                "pass",
                "the broker and only the expected session Portal backends are active",
            )

    if is_unavailable_record(user_bus):
        checks["user-bus"] = check(
            "unavailable",
            "the user D-Bus name query did not complete",
        )
    else:
        checks["user-bus"] = check("pass", "the user D-Bus name query completed")

    portal = {
        "expected_backends": expected_backends,
        "expected_package_matrix": expected_matrix,
        "installed_matrix": installed_matrix,
        "active_session_backends": active_backends,
        "bus_session_backends": bus_backends,
        "configuration": portal_config,
        "units": portal_units,
    }

    global_user_units = {
        unit: global_unit_state(unit) for unit in GLOBAL_USER_UNITS
    }
    if any(is_unavailable_record(record) for record in global_user_units.values()):
        checks["global-user-units"] = check(
            "unavailable",
            "one or more package-owned global user-unit queries failed",
        )
    elif any(record["status"] != "enabled" for record in global_user_units.values()):
        checks["global-user-units"] = check(
            "fail",
            "one or more package-owned global PipeWire/WirePlumber units are not enabled",
        )
    else:
        checks["global-user-units"] = check(
            "pass",
            "all package-owned global PipeWire/WirePlumber units are enabled",
        )

    audio_user_units = {
        unit: systemctl_show(unit, user=True) for unit in AUDIO_USER_UNITS
    }
    wpctl = simple_text_query(["wpctl", "status", "-n"])
    pactl = simple_text_query(["pactl", "info"])
    audio = {
        "user_units": audio_user_units,
        "wpctl": {key: value for key, value in wpctl.items() if key != "output"},
        "pactl": {key: value for key, value in pactl.items() if key != "output"},
        "pulse_server_on_pipewire": (
            pactl.get("status") == "ok"
            and "PulseAudio (on PipeWire" in pactl.get("output", "")
        ),
    }
    audio_records = list(audio_user_units.values()) + [wpctl, pactl]
    if any(is_unavailable_record(record) for record in audio_records):
        checks["pipewire-runtime"] = check(
            "unavailable",
            "PipeWire/WirePlumber runtime queries did not all complete",
        )
    elif (
        any(not unit_active(record) for record in audio_user_units.values())
        or not wpctl.get("nonempty")
        or not audio["pulse_server_on_pipewire"]
    ):
        checks["pipewire-runtime"] = check(
            "fail",
            "PipeWire/WirePlumber is not the complete active audio path",
        )
    else:
        checks["pipewire-runtime"] = check(
            "pass",
            "PipeWire/WirePlumber and the Pulse compatibility server are active",
        )

    physical_hardware = profile == "physical"
    startup_unit_names = STARTUP_UNITS if physical_hardware else STARTUP_UNITS[:2]
    startup_units = {
        unit: systemctl_show(unit, user=True) for unit in startup_unit_names
    }
    fcitx_autostart = find_autostart_file("org.fcitx.Fcitx5.desktop")
    if physical_hardware:
        blueman_autostart = find_autostart_file("blueman.desktop")
        blueman_process = process_count("blueman-applet")
    else:
        blueman_autostart = {"status": "not-applicable", "paths": []}
        blueman_process = {
            "status": "not-applicable",
            "query_exit": None,
            "count": None,
            "pids": [],
        }
    hypr_config = hyprland_startup_config(profile)
    fcitx_process = process_count("fcitx5")
    generated_active = [
        unit
        for unit in startup_unit_names[1:]
        if unit_active(startup_units[unit])
    ]
    startup = {
        "owner": "xdg-autostart" if session == "niri" else "hyprland-config",
        "detected_generated_owners": generated_active,
        "units": startup_units,
        "fcitx_autostart": fcitx_autostart,
        "blueman_autostart": blueman_autostart,
        "hyprland_config": hypr_config,
        "fcitx_process": fcitx_process,
        "blueman_process": blueman_process,
        "fcitx_process_count": fcitx_process.get("count"),
        "blueman_process_count": blueman_process.get("count"),
    }

    startup_query_records = list(startup_units.values()) + [fcitx_process]
    if physical_hardware:
        startup_query_records.append(blueman_process)
    if session == "hyprland":
        startup_query_records.append(hypr_config)

    if any(is_unavailable_record(record) for record in startup_query_records):
        checks["startup-owner"] = check(
            "unavailable",
            "startup ownership could not be completely determined",
        )
    elif fcitx_process.get("count") != 1 or (
        physical_hardware and blueman_process.get("count") != 1
    ):
        detail = (
            "Fcitx5 and Blueman must each have exactly one running process"
            if physical_hardware
            else "Fcitx5 must have exactly one running process in the VM profile"
        )
        checks["startup-owner"] = check("fail", detail)
    elif session == "niri":
        xdg_ready = (
            unit_active(startup_units["xdg-desktop-autostart.target"])
            and all(unit in generated_active for unit in startup_unit_names[1:])
            and fcitx_autostart["status"] == "present"
            and (
                not physical_hardware
                or blueman_autostart["status"] == "present"
            )
        )
        if xdg_ready:
            detail = (
                "Niri owns Fcitx5 and Blueman through generated XDG autostart units"
                if physical_hardware
                else "Niri owns Fcitx5 through its generated XDG autostart unit"
            )
            checks["startup-owner"] = check("pass", detail)
        else:
            checks["startup-owner"] = check(
                "fail",
                "Niri does not have the complete generated XDG autostart owner set",
            )
    else:
        guards = hypr_config.get("guards", {})
        required_guards = ("fcitx5", "blueman-applet") if physical_hardware else ("fcitx5",)
        if generated_active or not all(guards.get(name) for name in required_guards):
            checks["startup-owner"] = check(
                "fail",
                "Hyprland must use only its reviewed guarded configuration startup commands",
            )
        else:
            detail = (
                "Hyprland owns Fcitx5 and Blueman through guarded configuration commands"
                if physical_hardware
                else "Hyprland owns Fcitx5 through its guarded VM configuration command"
            )
            checks["startup-owner"] = check("pass", detail)

    if session == "niri":
        if any(is_unavailable_record(record) for record in startup_units.values()):
            checks["xdg-autostart-owner"] = check(
                "unavailable",
                "the generated XDG autostart owner state could not be determined",
            )
        elif checks["startup-owner"]["status"] == "pass":
            checks["xdg-autostart-owner"] = check(
                "pass",
                "the Niri XDG autostart owner is active",
            )
        else:
            checks["xdg-autostart-owner"] = check(
                "fail",
                "the required Niri XDG autostart owner is incomplete",
            )
    elif any(is_unavailable_record(record) for record in startup_units.values()):
        checks["xdg-autostart-owner"] = check(
            "unavailable",
            "the generated XDG autostart owner state could not be excluded",
        )
    elif generated_active:
        checks["xdg-autostart-owner"] = check(
            "fail",
            "a generated XDG owner is active in the plain Hyprland session",
        )
    else:
        checks["xdg-autostart-owner"] = check(
            "not-applicable",
            "plain Hyprland uses guarded compositor configuration instead of XDG autostart",
        )

    if profile == "vm":
        system_services = {
            unit: {"status": "not-applicable", "query_exit": None}
            for unit in SYSTEM_SERVICES
        }
        checks["system-services"] = check(
            "not-applicable",
            "Bluetooth and power-profile services are physical-profile checks",
        )
        system_bus = {
            "status": "not-applicable",
            "query_exit": None,
            "names": [],
            "owned_names": [],
            "activatable_names": [],
            "count": 0,
        }
        checks["system-bus"] = check(
            "not-applicable",
            "Bluetooth and power-profile D-Bus owners are physical-profile checks",
        )
        power_profiles_public = {"status": "not-applicable", "query_exit": None}
        checks["power-profiles"] = check(
            "not-applicable",
            "power profiles are outside the VM profile",
        )
        bluetooth = {"status": "not-applicable", "query_exit": None}
        checks["bluetooth-controller"] = check(
            "not-applicable",
            "Bluetooth hardware is outside the VM profile",
        )
    else:
        system_services = {
            unit: systemctl_show(unit, user=False) for unit in SYSTEM_SERVICES
        }
        if any(is_unavailable_record(record) for record in system_services.values()):
            checks["system-services"] = check(
                "unavailable",
                "Bluetooth or power service state could not be queried",
            )
        elif any(
            not unit_active(record) or record.get("unit_file_state") != "enabled"
            for record in system_services.values()
        ):
            checks["system-services"] = check(
                "fail",
                "Bluetooth and power-profile services must be enabled and active",
            )
        else:
            checks["system-services"] = check(
                "pass",
                "Bluetooth and power-profile services are enabled and active",
            )

        system_bus = bus_query(user=False)
        if is_unavailable_record(system_bus):
            checks["system-bus"] = check(
                "unavailable",
                "the system D-Bus name query did not complete",
            )
        else:
            missing_names = [
                name
                for name in SYSTEM_BUS_REQUIRED
                if name not in set(system_bus["owned_names"])
            ]
            if missing_names:
                checks["system-bus"] = check(
                    "fail",
                    "one or more Bluetooth, power-profile, or UPower D-Bus names are absent",
                )
            else:
                checks["system-bus"] = check(
                    "pass",
                    "Bluetooth, power-profile, and UPower D-Bus names are present",
                )

        power_profiles = simple_text_query(["powerprofilesctl", "list"])
        power_profiles_public = {
            key: value for key, value in power_profiles.items() if key != "output"
        }
        if is_unavailable_record(power_profiles):
            checks["power-profiles"] = check(
                "unavailable",
                "the power profile query did not complete",
            )
        elif not power_profiles.get("nonempty"):
            checks["power-profiles"] = check(
                "fail",
                "the power profile query returned no profiles",
            )
        else:
            checks["power-profiles"] = check(
                "pass",
                "the power profile query returned available profiles",
            )

        bluetooth = bluetooth_controller_query()
        if is_unavailable_record(bluetooth):
            checks["bluetooth-controller"] = check(
                "unavailable",
                "the Bluetooth controller query did not complete",
            )
        elif bluetooth["status"] == "no-controller":
            checks["bluetooth-controller"] = check(
                "not-applicable",
                "the successful Bluetooth query reported no controller",
            )
        else:
            checks["bluetooth-controller"] = check(
                "pass",
                "a Bluetooth controller is available",
            )

    failed_user_units = failed_units_query(user=True)
    failed_system_units = failed_units_query(user=False)
    for name, record, label in (
        ("failed-user-units", failed_user_units, "user"),
        ("failed-system-units", failed_system_units, "system"),
    ):
        if is_unavailable_record(record):
            checks[name] = check(
                "unavailable",
                f"the failed {label} unit query did not complete",
            )
        elif record["count"]:
            checks[name] = check(
                "fail",
                f"one or more failed {label} units are present",
            )
        else:
            checks[name] = check(
                "pass",
                f"the failed {label} unit query succeeded with an empty result",
            )

    blockers = [name for name, result in checks.items() if result["status"] == "fail"]
    unavailable = [
        name for name, result in checks.items() if result["status"] == "unavailable"
    ]
    warnings = [
        name for name, result in checks.items() if result["status"] == "warning"
    ]
    if unavailable:
        overall_result = "unavailable"
        exit_code = 2
    elif blockers:
        overall_result = "blocked"
        exit_code = 1
    else:
        overall_result = "ready"
        exit_code = 0

    return {
        "safety": {
            "read_only": True,
            "installer_apply_integration": False,
            "system_changes": False,
            "manual_interactive_checks": False,
        },
        "overall": {
            "result": overall_result,
            "exit_code": exit_code,
            "blockers": blockers,
            "unavailable_checks": unavailable,
            "warnings": warnings,
        },
        "profile": profile,
        "session": session,
        "selection": selection,
        "environment": environment,
        "portal": portal,
        "startup": startup,
        "packages": packages,
        "global_user_units": global_user_units,
        "audio": audio,
        "system_services": system_services,
        "user_bus": user_bus,
        "system_bus": system_bus,
        "power_profiles": power_profiles_public,
        "bluetooth": bluetooth,
        "failed_units": {
            "user": failed_user_units,
            "system": failed_system_units,
        },
        "checks": checks,
    }


def render_text(report: dict[str, Any]) -> str:
    checks = report["checks"]
    lines = [
        "Phase C session/service acceptance (read-only)",
        f"profile: {report['profile']}",
        f"session: {report['session']}",
        f"selection: {report['selection']}",
        f"result: {report['overall']['result']} (exit {report['overall']['exit_code']})",
        f"portal backend ownership: {checks['portal-backend-ownership']['status']}",
        f"startup owner: {report['startup']['owner']}",
        f"startup ownership check: {checks['startup-owner']['status']}",
        f"audio conflict packages: {checks['audio-conflict-packages']['status']}",
        f"power conflict packages: {checks['power-conflict-packages']['status']}",
        f"global user units: {checks['global-user-units']['status']}",
        f"user bus: {report['user_bus']['status']}",
    ]
    if report["overall"]["blockers"]:
        lines.append("blockers: " + ", ".join(report["overall"]["blockers"]))
    if report["overall"]["unavailable_checks"]:
        lines.append(
            "unavailable checks: "
            + ", ".join(report["overall"]["unavailable_checks"])
        )
    lines.extend(
        [
            "manual playback, recording, pairing, suspend/resume, and GPU checks remain outside this report",
            "completion gate: this report never authorizes package, service, configuration, boot, or installer apply changes",
        ]
    )
    return "\n".join(lines) + "\n"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run read-only Phase C session/service acceptance checks."
    )
    parser.add_argument("--profile", choices=PROFILES, default="physical")
    parser.add_argument("--session", required=True, choices=SESSIONS)
    parser.add_argument("--selection", choices=SELECTIONS)
    parser.add_argument("--json", action="store_true", dest="json_output")
    return parser.parse_args()


def main() -> int:
    arguments = parse_args()
    selection = arguments.selection or arguments.session
    report = build_report(arguments.session, selection, arguments.profile)
    if arguments.json_output:
        json.dump(report, sys.stdout, indent=2, sort_keys=True)
        sys.stdout.write("\n")
    else:
        sys.stdout.write(render_text(report))
    return int(report["overall"]["exit_code"])


if __name__ == "__main__":
    raise SystemExit(main())
