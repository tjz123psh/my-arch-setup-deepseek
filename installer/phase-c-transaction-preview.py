#!/usr/bin/env python3
"""Produce a read-only, reviewable Phase C package transaction preview.

This tool deliberately stops at observation.  It resolves repository metadata,
reports the proposed package set and dependencies, inspects selected prior
state, and emits no executable apply command.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import re
import shutil
import subprocess
import sys
import time
from decimal import Decimal
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parent.parent
PLANNER = ROOT / "installer/phase-c-plan.py"

SYSTEM_UNITS = (
    "bluetooth.service",
    "power-profiles-daemon.service",
)
USER_UNITS = (
    "pipewire.socket",
    "pipewire-pulse.socket",
    "wireplumber.service",
)
PORTAL_USER_UNITS = (
    "xdg-desktop-portal.service",
    "xdg-desktop-portal-gnome.service",
    "xdg-desktop-portal-gtk.service",
    "xdg-desktop-portal-hyprland.service",
)
PACKAGE_PATHS = {
    "pipewire": ("/usr/lib/systemd/user/pipewire.socket",),
    "pipewire-pulse": ("/usr/lib/systemd/user/pipewire-pulse.socket",),
    "wireplumber": ("/usr/lib/systemd/user/wireplumber.service",),
    "xdg-desktop-portal": ("/usr/lib/systemd/user/xdg-desktop-portal.service",),
    "xdg-desktop-portal-gnome": (
        "/usr/lib/systemd/user/xdg-desktop-portal-gnome.service",
    ),
    "xdg-desktop-portal-gtk": (
        "/usr/lib/systemd/user/xdg-desktop-portal-gtk.service",
        "/usr/share/xdg-desktop-portal/gtk-portals.conf",
    ),
    "xdg-desktop-portal-hyprland": (
        "/usr/lib/systemd/user/xdg-desktop-portal-hyprland.service",
    ),
    "bluez": ("/usr/lib/systemd/system/bluetooth.service",),
    "power-profiles-daemon": (
        "/usr/lib/systemd/system/power-profiles-daemon.service",
    ),
    "fcitx5": ("/etc/xdg/autostart/org.fcitx.Fcitx5.desktop",),
    "blueman": ("/etc/xdg/autostart/blueman.desktop",),
}
SIZE_RE = re.compile(
    r"^\s*([0-9]+(?:\.[0-9]+)?)\s*([KMGTPE]?i?B)\s*$", re.IGNORECASE
)
PACKAGE_NAME_RE = re.compile(r"^[a-z0-9@._+:-]+$")
REPOSITORY_NAME_RE = re.compile(r"^[A-Za-z0-9@._+-]+$")


def command_result(arguments: list[str], *, timeout: int = 30) -> dict[str, Any]:
    executable = shutil.which(arguments[0])
    if executable is None:
        return {"status": "command-missing", "returncode": None, "stdout": "", "stderr": ""}
    environment = os.environ.copy()
    environment["LC_ALL"] = "C"
    environment["LANG"] = "C"
    try:
        completed = subprocess.run(
            [executable, *arguments[1:]],
            check=False,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=timeout,
            env=environment,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        return {
            "status": "query-failed",
            "returncode": None,
            "stdout": "",
            "stderr": str(error),
        }
    return {
        "status": "ok" if completed.returncode == 0 else "query-failed",
        "returncode": completed.returncode,
        "stdout": completed.stdout,
        "stderr": completed.stderr,
    }


def error_record(result: dict[str, Any], *, status: str | None = None) -> dict[str, Any]:
    record: dict[str, Any] = {
        "status": status or result["status"],
        "query_exit": result["returncode"],
    }
    message = str(result.get("stderr", "")).strip()
    if message:
        record["error"] = message.splitlines()[0][:240]
    return record


def parse_size(value: str) -> int | None:
    if value.strip() in {"None", "0", "0 B"}:
        return 0
    match = SIZE_RE.match(value)
    if not match:
        return None
    number = Decimal(match.group(1))
    unit = match.group(2).lower()
    units = {"b": 1, "kb": 1000, "kib": 1024, "mb": 1000**2, "mib": 1024**2,
             "gb": 1000**3, "gib": 1024**3, "tb": 1000**4, "tib": 1024**4,
             "pb": 1000**5, "pib": 1024**5, "eb": 1000**6, "eib": 1024**6}
    multiplier = units.get(unit)
    if multiplier is None:
        return None
    return int(number * multiplier)


def parse_pacman_info(result: dict[str, Any], package: str) -> dict[str, Any]:
    if result["status"] != "ok":
        stderr = str(result.get("stderr", ""))
        if "target not found" in stderr.lower():
            return error_record(result, status="target-not-found")
        return error_record(result)
    fields: dict[str, str] = {}
    current_key: str | None = None
    for line in str(result["stdout"]).splitlines():
        if " : " in line:
            key, value = line.split(" : ", 1)
            current_key = key.strip()
            fields[current_key] = value.strip()
        elif current_key is not None and line[:1].isspace() and line.strip():
            fields[current_key] = f"{fields[current_key]} {line.strip()}"
        else:
            current_key = None
    required = ("Repository", "Name", "Version", "Depends On", "Conflicts With", "Download Size", "Installed Size")
    if any(key not in fields for key in required) or fields["Name"] != package:
        return {"status": "malformed-output", "query_exit": result["returncode"]}
    download = parse_size(fields["Download Size"])
    installed = parse_size(fields["Installed Size"])
    if download is None or installed is None:
        return {"status": "malformed-output", "query_exit": result["returncode"]}
    depends = [] if fields["Depends On"] == "None" else fields["Depends On"].split()
    conflicts = [] if fields["Conflicts With"] == "None" else fields["Conflicts With"].split()
    return {
        "status": "ok",
        "query_exit": result["returncode"],
        "repository": fields["Repository"],
        "name": fields["Name"],
        "version": fields["Version"],
        "depends": depends,
        "conflicts": conflicts,
        "download_size_bytes": download,
        "installed_size_bytes": installed,
    }


def planner_packages(profile: str, modules: str | None) -> tuple[list[str], dict[str, Any] | None]:
    arguments = [sys.executable, str(PLANNER), "--profile", profile, "--json"]
    if modules is not None:
        arguments.extend(["--modules", modules])
    try:
        completed = subprocess.run(
            arguments,
            check=False,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env={**os.environ, "LC_ALL": "C", "LANG": "C"},
            timeout=30,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        return [], {"status": "query-failed", "query_exit": None, "error": str(error)}
    if completed.returncode != 0:
        return [], {
            "status": "query-failed",
            "query_exit": completed.returncode,
            "error": completed.stderr.strip().splitlines()[0][:240] if completed.stderr.strip() else "planner failed",
        }
    try:
        plan = json.loads(completed.stdout)
        packages = plan["review_transaction"]["proposed_official_packages"]
        if not isinstance(packages, list) or not all(isinstance(package, str) and package for package in packages):
            raise ValueError("invalid proposed package list")
    except (ValueError, KeyError, TypeError, json.JSONDecodeError) as error:
        return [], {
            "status": "malformed-output",
            "query_exit": completed.returncode,
            "error": str(error),
        }
    return sorted(set(packages)), {
        "status": "ok",
        "query_exit": completed.returncode,
        "planner_profile": plan.get("profile"),
        "selected_modules": plan.get("selected_modules"),
    }


def repository_query(sync_db_dir: str | None, max_age_hours: float, now_epoch: float) -> tuple[dict[str, Any], list[str]]:
    unavailable: list[str] = []
    repos_result = command_result(["pacman-conf", "--repo-list"])
    if repos_result["status"] != "ok":
        return {**error_record(repos_result), "repositories": [], "packages": {}, "stale_databases": []}, ["repository-list"]
    repositories = [
        line.strip() for line in str(repos_result["stdout"]).splitlines() if line.strip()
    ]
    if not repositories or len(repositories) != len(set(repositories)) or any(
        REPOSITORY_NAME_RE.fullmatch(repository) is None for repository in repositories
    ):
        return {"status": "malformed-output", "repositories": [], "packages": {}, "stale_databases": []}, ["repository-list"]
    if sync_db_dir is None:
        db_result = command_result(["pacman-conf", "DBPath"])
        if db_result["status"] != "ok" or not db_result["stdout"].strip():
            return {**error_record(db_result, status=db_result["status"]), "repositories": repositories, "packages": {}, "stale_databases": []}, ["database-path"]
        database_dir = Path(db_result["stdout"].strip()) / "sync"
    else:
        database_dir = Path(sync_db_dir)
    stale: list[str] = []
    database_records: dict[str, Any] = {}
    for repository in repositories:
        path = database_dir / f"{repository}.db"
        try:
            stat = path.stat()
        except OSError as error:
            database_records[repository] = {"status": "read-failed", "path": str(path), "error": str(error)[:240]}
            unavailable.append(f"sync-db:{repository}")
            continue
        age_seconds = max(0.0, now_epoch - stat.st_mtime)
        record = {"status": "ok", "path": str(path), "mtime_epoch": stat.st_mtime, "age_hours": round(age_seconds / 3600, 3)}
        if age_seconds > max_age_hours * 3600:
            record["status"] = "stale"
            stale.append(repository)
        database_records[repository] = record
    status = "unavailable" if unavailable else ("stale" if stale else "ok")
    return {
        "status": status,
        "repositories": repositories,
        "database_dir": str(database_dir),
        "databases": database_records,
        "stale_databases": stale,
        "packages": {},
    }, unavailable


def resolve_packages(
    packages: list[str], metadata: dict[str, dict[str, Any]]
) -> tuple[list[dict[str, Any]], list[str], list[str], dict[str, Any]]:
    available = [package for package in packages if metadata.get(package, {}).get("status") == "ok"]
    if not available:
        return [], [], [], {
            "status": "not-required" if not packages else "not-run",
            "query_exit": None,
            "queryable_targets": 0,
        }
    result = command_result(["pacman", "-Sp", "--needed", "--print-format", "%n\\t%v\\t%r\\t%s\\t%l", *available])
    if result["status"] != "ok":
        missing_targets = re.findall(r"target not found:\s*([^\s]+)", str(result.get("stderr", "")), re.IGNORECASE)
        if missing_targets:
            return (
                [],
                sorted(set(missing_targets)),
                [],
                error_record(result, status="target-not-found"),
            )
        return [], [], ["dependency-resolution"], error_record(result)
    records: list[dict[str, Any]] = []
    seen_packages: set[str] = set()
    malformed = False
    for line in str(result["stdout"]).splitlines():
        # pacman prints the backslash escape literally for this format on the
        # current host; fixtures may emit actual tab bytes. Accept both exact
        # representations and reject every other shape.
        parts = line.split("\t") if "\t" in line else line.split("\\t")
        if len(parts) != 5 or not all(parts):
            malformed = True
            continue
        name, version, repository, size_text, location = parts
        try:
            size = int(size_text)
        except ValueError:
            malformed = True
            continue
        if (
            size < 0
            or PACKAGE_NAME_RE.fullmatch(name) is None
            or REPOSITORY_NAME_RE.fullmatch(repository) is None
            or name in seen_packages
        ):
            malformed = True
            continue
        seen_packages.add(name)
        records.append({
            "package": name,
            "version": version,
            "repository": repository,
            "download_size_bytes": size,
            "location": location,
            "kind": "requested" if name in packages else "dependency",
        })
    if malformed:
        return records, [], ["dependency-resolution-output"], {
            "status": "malformed-output",
            "query_exit": result["returncode"],
            "output_rows": len(records),
        }
    # A successful --needed query may omit an already-installed requested item;
    # it is therefore not an error when a requested name has no output row.
    return records, [], [], {
        "status": "ok",
        "query_exit": result["returncode"],
        "output_rows": len(records),
    }


def installed_packages() -> tuple[set[str] | None, dict[str, Any]]:
    result = command_result(["pacman", "-Qq"])
    if result["status"] != "ok":
        return None, error_record(result)
    return {line.strip() for line in str(result["stdout"]).splitlines() if line.strip()}, {"status": "ok", "query_exit": result["returncode"]}


def parse_unit(result: dict[str, Any]) -> dict[str, Any]:
    if result["status"] != "ok":
        return error_record(result)
    values: dict[str, str] = {}
    for line in str(result["stdout"]).splitlines():
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key] = value
    required = ("LoadState", "ActiveState", "UnitFileState", "FragmentPath")
    if any(key not in values for key in required):
        return {"status": "malformed-output", "query_exit": result["returncode"]}
    return {"status": "ok", "query_exit": result["returncode"], "load_state": values["LoadState"], "active_state": values["ActiveState"], "unit_file_state": values["UnitFileState"], "fragment_path": values["FragmentPath"]}


def query_units(units: tuple[str, ...], *, user: bool) -> tuple[dict[str, Any], list[str]]:
    records: dict[str, Any] = {}
    unavailable: list[str] = []
    for unit in units:
        args = ["systemctl"] + (["--user"] if user else []) + ["show", unit, "--property", "LoadState,ActiveState,UnitFileState,FragmentPath", "--no-pager"]
        record = parse_unit(command_result(args))
        records[unit] = record
        if record["status"] in {"command-missing", "query-failed", "malformed-output"}:
            unavailable.append(f"user-unit:{unit}" if user else f"system-unit:{unit}")
    return records, unavailable


def query_global_units(units: tuple[str, ...]) -> tuple[dict[str, Any], list[str]]:
    records: dict[str, Any] = {}
    unavailable: list[str] = []
    for unit in units:
        result = command_result(["systemctl", "--global", "is-enabled", unit])
        if result["status"] == "command-missing":
            record = error_record(result)
        elif result["returncode"] == 0:
            state = str(result["stdout"]).strip().splitlines()
            record = {"status": "ok", "state": state[0] if state else "enabled", "query_exit": 0}
        else:
            state_lines = str(result["stdout"]).strip().splitlines()
            state = state_lines[0].strip() if state_lines else ""
            if state in {"disabled", "static", "indirect", "masked", "not-found", "generated", "transient"}:
                record = {"status": "ok", "state": state, "query_exit": result["returncode"]}
            else:
                record = error_record(result)
        records[unit] = record
        if record["status"] in {"command-missing", "query-failed", "malformed-output"}:
            unavailable.append(f"global-user-unit:{unit}")
    return records, unavailable


def query_ownership(
    packages: set[str], installed: set[str] | None
) -> tuple[dict[str, Any], list[str], list[str]]:
    records: dict[str, Any] = {}
    unavailable: list[str] = []
    blockers: list[str] = []
    expected_owners: dict[str, str] = {}
    for package in sorted(packages):
        for package_path in PACKAGE_PATHS.get(package, ()):
            expected_owners[package_path] = package
    for path in sorted(expected_owners):
        result = command_result(["pacman", "-Qo", path])
        if result["status"] == "ok":
            line = str(result["stdout"]).strip().splitlines()
            owner = line[0].split(" is owned by ", 1)[1] if line and " is owned by " in line[0] else ""
            if not owner:
                records[path] = {"status": "malformed-output", "query_exit": result["returncode"]}
                unavailable.append(f"ownership:{path}")
            else:
                expected_owner = expected_owners[path]
                owner_package = owner.split(maxsplit=1)[0]
                if owner_package != expected_owner:
                    records[path] = {
                        "status": "blocked",
                        "query_exit": result["returncode"],
                        "owner": owner,
                        "expected_owner": expected_owner,
                    }
                    blockers.append(f"ownership-mismatch:{path}")
                else:
                    records[path] = {
                        "status": "ok",
                        "query_exit": result["returncode"],
                        "owner": owner,
                    }
        elif "no package owns" in str(result.get("stderr", "")).lower():
            expected_owner = expected_owners[path]
            if installed is not None and expected_owner not in installed:
                records[path] = {
                    **error_record(result, status="not-installed"),
                    "expected_owner": expected_owner,
                }
            else:
                records[path] = {
                    **error_record(result, status="unowned"),
                    "expected_owner": expected_owner,
                }
                blockers.append(f"unowned:{path}")
        else:
            records[path] = error_record(result)
            unavailable.append(f"ownership:{path}")
    return records, unavailable, blockers


def text_report(report: dict[str, Any]) -> None:
    overall = report["overall"]
    print(f"Phase C transaction preview: {overall['result']}")
    print(f"Requested packages: {len(report['transaction']['requested_packages'])}")
    print(f"Resolved packages: {len(report['transaction']['resolved_packages'])}")
    if overall["blockers"]:
        print("Blockers:")
        for blocker in overall["blockers"]:
            print(f"- {blocker}")
    if overall["unavailable_checks"]:
        print("Unavailable checks:")
        for check in overall["unavailable_checks"]:
            print(f"- {check}")
    print("Read-only preview; no apply action is exposed.")


def build_report(args: argparse.Namespace) -> tuple[dict[str, Any], int]:
    blockers: list[str] = []
    unavailable: list[str] = []
    requested, planner_record = planner_packages(args.profile, args.modules)
    if planner_record is None or planner_record.get("status") != "ok":
        unavailable.append("phase-c-plan")
    repository, repository_unavailable = repository_query(args.sync_db_dir, args.max_sync_db_age_hours, args.now_epoch)
    unavailable.extend(repository_unavailable)
    blockers.extend(
        f"stale-sync-database:{name}" for name in repository["stale_databases"]
    )
    metadata: dict[str, dict[str, Any]] = {}
    for package in requested:
        info = parse_pacman_info(command_result(["pacman", "-Si", package]), package)
        metadata[package] = info
        repository["packages"][package] = info
        if info["status"] in {"query-failed", "command-missing", "malformed-output", "read-failed"}:
            unavailable.append(f"package-metadata:{package}")
        elif info["status"] == "target-not-found":
            blockers.append(package)
    resolved, resolution_blockers, resolution_unavailable, resolution_query = resolve_packages(
        requested, metadata
    )
    blockers.extend(resolution_blockers)
    unavailable.extend(resolution_unavailable)
    # Fill installed sizes from -Si for dependency rows and retain the exact
    # download bytes emitted by the transaction preview command.
    for item in resolved:
        name = item["package"]
        if name not in metadata:
            metadata[name] = parse_pacman_info(command_result(["pacman", "-Si", name]), name)
        info = metadata[name]
        item["metadata"] = info
        if info.get("status") == "ok":
            item["installed_size_bytes"] = info["installed_size_bytes"]
            item["conflicts"] = info["conflicts"]
        else:
            item["installed_size_bytes"] = None
            item["conflicts"] = []
            if info.get("status") == "target-not-found":
                unavailable.append(f"resolved-package-metadata-inconsistent:{name}")
            elif info.get("status") in {
                "query-failed",
                "command-missing",
                "malformed-output",
                "read-failed",
            }:
                unavailable.append(f"package-metadata:{name}")
    requested_metadata_unavailable = any(
        record.get("status") in {"query-failed", "command-missing", "malformed-output", "read-failed"}
        for package, record in metadata.items()
        if package in requested
    )
    resolved_metadata_unavailable = any(
        metadata[item["package"]].get("status") != "ok" for item in resolved
    )
    if planner_record is None or planner_record.get("status") != "ok":
        resolution_status = "not-run"
    elif resolution_unavailable or requested_metadata_unavailable or resolved_metadata_unavailable:
        resolution_status = "unavailable"
    elif resolution_blockers or any(
        record.get("status") == "target-not-found" for record in metadata.values()
    ):
        resolution_status = "blocked"
    else:
        resolution_status = "ok"

    installed, installed_record = installed_packages()
    metadata_failed = sorted(
        package
        for package, record in metadata.items()
        if package in requested and record.get("status") in {"query-failed", "command-missing", "malformed-output", "read-failed"}
    )
    if installed is None:
        unavailable.append("installed-package-inventory")
        installed_list: list[str] = []
        missing_list: list[str] = []
        failed_list = sorted(set(requested) | set(metadata_failed))
    else:
        installed_list = sorted(package for package in requested if package in installed)
        missing_list = sorted(package for package in requested if package not in installed)
        failed_list = metadata_failed
    resolved_names = {item["package"] for item in resolved}
    download_total = sum(item["download_size_bytes"] for item in resolved)
    installed_total = sum(item["installed_size_bytes"] or 0 for item in resolved)
    conflicts: list[dict[str, Any]] = []
    for item in resolved:
        for conflict in item.get("conflicts", []):
            conflict_package = re.split(r"[<>=]", conflict, maxsplit=1)[0]
            matched_installed = installed is not None and conflict_package in installed
            matched_transaction = conflict_package in resolved_names and conflict_package != item["package"]
            status = "blocked" if matched_installed or matched_transaction else "ok"
            record = {
                "package": item["package"],
                "conflict": conflict,
                "conflict_package": conflict_package,
                "matched_installed": matched_installed,
                "matched_transaction": matched_transaction,
                "status": status,
            }
            conflicts.append(record)
            if status == "blocked":
                blockers.append(f"conflict:{item['package']}:{conflict_package}")
    system_units, system_unavailable = query_units(SYSTEM_UNITS, user=False)
    user_units, user_unavailable = query_units(USER_UNITS + PORTAL_USER_UNITS, user=True)
    global_units, global_unavailable = query_global_units(USER_UNITS)
    unavailable.extend(system_unavailable + user_unavailable + global_unavailable)
    owned_paths, ownership_unavailable, ownership_blockers = query_ownership(resolved_names | set(requested), installed)
    unavailable.extend(ownership_unavailable)
    blockers.extend(ownership_blockers)
    if repository["status"] == "unavailable":
        unavailable.append("repository-metadata")
    unavailable = sorted(set(unavailable))
    blockers = sorted(set(blockers))
    if unavailable:
        overall_result = "unavailable"
        exit_code = 2
    elif blockers:
        overall_result = "blocked"
        exit_code = 1
    else:
        overall_result = "ready"
        exit_code = 0
    report = {
        "schema": 1,
        "profile": args.profile,
        "selected_modules": planner_record.get("selected_modules") if planner_record and planner_record.get("status") == "ok" else None,
        "planning_query": planner_record,
        "safety": {
            "read_only": True,
            "apply_authorized": False,
            "installer_apply_integration": False,
            "system_changes": False,
        },
        "repository_query": repository,
        "transaction": {
            "requested_packages": requested,
            "resolved_packages": sorted(resolved, key=lambda item: item["package"]),
            "installed_packages": installed_list,
            "missing_packages": missing_list,
            "query_failed_packages": failed_list,
            "sizes": {"download_size_bytes": download_total, "installed_size_bytes": installed_total},
            "installed_inventory": installed_record,
            "resolution_query": resolution_query,
            "resolution": {
                "status": resolution_status,
                "resolved_count": len(resolved),
                "successful_empty": resolution_status == "ok" and not resolved,
            },
        },
        "prior_state": {
            "system_units": system_units,
            "user_units": user_units,
            "global_user_units": global_units,
            "package_owned_paths": owned_paths,
        },
        "conflicts": sorted(conflicts, key=lambda item: (item["package"], item["conflict"])),
        "rollback": {"notes": ["No system state was changed; discard this report to roll back the preview.", "Any future apply must be separately reviewed and authorized."]},
        "post_checks": ["Re-run the read-only package and ownership queries after any separately authorized change.", "Verify service states and portal selection in the target session.", "Compare installed packages against the approved plan and record remaining manual items."],
        "apply": {"authorized": False, "command": None},
        "overall": {"result": overall_result, "blockers": blockers, "unavailable_checks": unavailable},
    }
    return report, exit_code


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Generate a read-only Phase C transaction preview.")
    parser.add_argument("--profile", default="asus-amd-nvidia", choices=("asus-amd-nvidia", "desktop-amd", "vm"))
    parser.add_argument("--modules", help="comma-separated module selection passed to the Phase C planner")
    parser.add_argument("--sync-db-dir", help="override the sync database directory for review fixtures or an audited snapshot")
    parser.add_argument("--max-sync-db-age-hours", type=float, default=24.0)
    parser.add_argument("--now-epoch", type=float, default=None, help="override current epoch for deterministic review fixtures")
    parser.add_argument("--json", action="store_true", help="emit machine-readable JSON")
    args = parser.parse_args(argv)
    if not math.isfinite(args.max_sync_db_age_hours) or args.max_sync_db_age_hours < 0:
        parser.error("--max-sync-db-age-hours must be finite and non-negative")
    if args.now_epoch is None:
        args.now_epoch = time.time()
    elif not math.isfinite(args.now_epoch):
        parser.error("--now-epoch must be finite")
    report, exit_code = build_report(args)
    if args.json:
        json.dump(report, sys.stdout, indent=2, sort_keys=True)
        print()
    else:
        text_report(report)
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
