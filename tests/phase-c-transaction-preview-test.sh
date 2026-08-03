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
tool = root / "installer/phase-c-transaction-preview.py"
if not tool.is_file() or tool.is_symlink():
    raise SystemExit("Phase C transaction preview is missing or unsafe")


def write_executable(path: Path, body: str) -> None:
    path.write_text(f"#!{sys.executable}\n{body}")
    path.chmod(0o755)


def make_fixture(base: Path, scenario: str = "ready") -> tuple[Path, dict[str, str], Path]:
    bin_dir = base / "bin"
    sync_dir = base / "sync"
    bin_dir.mkdir(parents=True)
    sync_dir.mkdir()
    now = 2_000_000_000
    for name in ("core.db", "extra.db"):
        path = sync_dir / name
        path.write_text("fixture")
        os.utime(path, (now - 3600, now - 3600))

    write_executable(
        bin_dir / "pacman-conf",
        r'''import os
import sys

args = sys.argv[1:]
if args == ["--repo-list"]:
    print("core")
    print("extra")
    raise SystemExit(0)
if args == ["DBPath"]:
    print(os.environ["MOCK_DBPATH"])
    raise SystemExit(0)
raise SystemExit(9)
''',
    )
    write_executable(
        bin_dir / "pacman",
        r'''import os
import sys

scenario = os.environ.get("MOCK_SCENARIO", "ready")
args = sys.argv[1:]
requested = {
    "pipewire", "pipewire-alsa", "pipewire-audio", "pipewire-pulse",
    "wireplumber", "xdg-desktop-portal", "xdg-desktop-portal-gnome",
    "xdg-desktop-portal-gtk",
}
installed = {"pipewire"}
if scenario == "successful-empty":
    installed = set(requested)
if scenario in {"conflict", "conflict-and-service-failure", "wrapped-conflict"}:
    installed.add("conflicting-audio")

metadata = {
    "pipewire": ("extra", "1.0-1", "None", "10.00 KiB", "30.00 KiB"),
    "pipewire-alsa": ("extra", "1.0-1", "pipewire", "11.00 KiB", "31.00 KiB"),
    "pipewire-audio": ("extra", "1.0-1", "pipewire", "12.00 KiB", "32.00 KiB"),
    "pipewire-pulse": ("extra", "1.0-1", "pipewire", "13.00 KiB", "33.00 KiB"),
    "wireplumber": ("extra", "1.0-1", "pipewire", "14.00 KiB", "34.00 KiB"),
    "xdg-desktop-portal": ("extra", "1.0-1", "None", "15.00 KiB", "35.00 KiB"),
    "xdg-desktop-portal-gnome": ("extra", "1.0-1", "xdg-desktop-portal", "16.00 KiB", "36.00 KiB"),
    "xdg-desktop-portal-gtk": ("extra", "1.0-1", "xdg-desktop-portal", "17.00 KiB", "37.00 KiB"),
    "dep-runtime": ("core", "2.0-1", "None", "18.00 KiB", "38 B"),
}
if scenario == "query-failed":
    metadata.pop("pipewire")
if scenario == "target-not-found":
    metadata.pop("xdg-desktop-portal-gtk")


def emit_info(package: str) -> int:
    if scenario == "dependency-target-not-found" and package == "dep-runtime":
        print(f"error: target not found: {package}", file=sys.stderr)
        return 1
    if scenario == "all-metadata-query-failed":
        print("error: sync database query failed", file=sys.stderr)
        return 2
    if scenario == "query-failed" and package == "pipewire":
        print("error: sync database query failed", file=sys.stderr)
        return 2
    if package not in metadata:
        print(f"error: target not found: {package}", file=sys.stderr)
        return 1
    repo, version, depends, download, installed_size = metadata[package]
    if package == "pipewire-pulse" and scenario in {"conflict", "conflict-and-service-failure"}:
        conflicts = "conflicting-audio"
    elif package == "pipewire-pulse" and scenario == "wrapped-conflict":
        conflicts = "harmless-conflict"
    else:
        conflicts = "None"
    print(f"Repository      : {repo}")
    print(f"Name            : {package}")
    print(f"Version         : {version}")
    print(f"Depends On      : {depends}")
    print(f"Conflicts With  : {conflicts}")
    if package == "pipewire-pulse" and scenario == "wrapped-conflict":
        print("                  conflicting-audio")
    print(f"Download Size   : {download}")
    print(f"Installed Size  : {installed_size}")
    return 0

if args[:1] == ["-Si"] and len(args) == 2:
    raise SystemExit(emit_info(args[1]))
if args == ["-Qq"]:
    if scenario == "installed-query-failed":
        print("error: local package database unavailable", file=sys.stderr)
        raise SystemExit(2)
    for package in sorted(installed):
        print(package)
    raise SystemExit(0)
if len(args) == 2 and args[0] == "-Qo":
    path = args[1]
    owners = {
        "/usr/lib/systemd/user/pipewire.socket": "pipewire 1.0-1",
        "/usr/lib/systemd/user/pipewire-pulse.socket": "pipewire-pulse 1.0-1",
        "/usr/lib/systemd/user/wireplumber.service": "wireplumber 1.0-1",
        "/usr/lib/systemd/user/xdg-desktop-portal.service": "xdg-desktop-portal 1.0-1",
        "/usr/lib/systemd/user/xdg-desktop-portal-gnome.service": "xdg-desktop-portal-gnome 1.0-1",
        "/usr/lib/systemd/user/xdg-desktop-portal-gtk.service": "xdg-desktop-portal-gtk 1.0-1",
        "/usr/share/xdg-desktop-portal/gtk-portals.conf": "xdg-desktop-portal-gtk 1.0-1",
    }
    if scenario == "ownership-query-failed" and path.endswith("wireplumber.service"):
        print("error: local package database unavailable", file=sys.stderr)
        raise SystemExit(2)
    if path not in owners:
        print(f"error: No package owns {path}", file=sys.stderr)
        raise SystemExit(1)
    print(f"{path} is owned by {owners[path]}")
    raise SystemExit(0)
if args[:1] == ["-Sp"]:
    if "-S" in args and "-p" not in args:
        print("apply path invoked", file=sys.stderr)
        raise SystemExit(99)
    if scenario == "successful-empty":
        raise SystemExit(0)
    packages = [item for item in args if item in requested]
    if scenario == "resolution-query-failed":
        print("error: failed to prepare transaction", file=sys.stderr)
        raise SystemExit(2)
    records = {
        "pipewire-pulse": "pipewire-pulse\t1.0-1\textra\t13312\thttps://example.invalid/pipewire-pulse.pkg.tar.zst",
        "dep-runtime": "dep-runtime\t2.0-1\tcore\t18432\thttps://example.invalid/dep-runtime.pkg.tar.zst",
        "xdg-desktop-portal-gtk": "xdg-desktop-portal-gtk\t1.0-1\textra\t17408\thttps://example.invalid/gtk.pkg.tar.zst",
    }
    if scenario == "target-not-found":
        packages = [package for package in packages if package != "xdg-desktop-portal-gtk"]
    def emit_record(record):
        print(record.replace("\t", r"\t") if scenario == "literal-separators" else record)

    for package in packages:
        if package == "pipewire":
            continue
        if package in records:
            emit_record(records[package])
    if "pipewire-pulse" in packages:
        emit_record(records["dep-runtime"])
    raise SystemExit(0)
if any(item in {"-S", "-R", "-U", "--refresh", "-y"} for item in args):
    print("forbidden mutating pacman operation", file=sys.stderr)
    raise SystemExit(99)
raise SystemExit(9)
''',
    )
    write_executable(
        bin_dir / "systemctl",
        r'''import os
import sys

scenario = os.environ.get("MOCK_SCENARIO", "ready")
args = sys.argv[1:]
if args[:2] == ["--global", "is-enabled"]:
    if scenario in {"service-query-failed", "conflict-and-service-failure"}:
        print("global unit query failed", file=sys.stderr)
        raise SystemExit(2)
    print("enabled")
    raise SystemExit(0)
user = bool(args[:1] == ["--user"])
if user:
    args = args[1:]
if len(args) == 5 and args[0] == "show" and args[2] == "--property":
    if scenario in {"service-query-failed", "conflict-and-service-failure"} and args[1] == "pipewire-pulse.socket":
        print("user manager unavailable", file=sys.stderr)
        raise SystemExit(2)
    print("LoadState=loaded")
    print("ActiveState=active")
    print("UnitFileState=enabled")
    print("FragmentPath=/usr/lib/systemd/user/example.service" if user else "FragmentPath=/usr/lib/systemd/system/example.service")
    raise SystemExit(0)
raise SystemExit(9)
''',
    )
    env = os.environ.copy()
    env.update(
        {
            "PATH": f"{bin_dir}:{env['PATH']}",
            "LC_ALL": "C",
            "LANG": "C",
            "MOCK_SCENARIO": scenario,
            "MOCK_DBPATH": str(sync_dir),
        }
    )
    return bin_dir, env, sync_dir


def run_tool(env: dict[str, str], sync_dir: Path, *extra: str) -> subprocess.CompletedProcess[str]:
    args = [
        sys.executable,
        str(tool),
        "--profile",
        "vm",
        "--json",
        "--sync-db-dir",
        str(sync_dir),
        "--now-epoch",
        "2000000000",
        "--max-sync-db-age-hours",
        "24",
        *extra,
    ]
    return subprocess.run(args, check=False, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)


with tempfile.TemporaryDirectory() as temporary:
    base = Path(temporary)
    _bin, env, sync_dir = make_fixture(base)
    ready_result = run_tool(env, sync_dir)
    if ready_result.returncode != 0:
        raise SystemExit(f"ready fixture failed before implementation: rc={ready_result.returncode} stderr={ready_result.stderr}")
    ready = json.loads(ready_result.stdout)
    if ready["safety"] != {
        "read_only": True,
        "apply_authorized": False,
        "installer_apply_integration": False,
        "system_changes": False,
    }:
        raise SystemExit(f"unexpected safety block: {ready['safety']}")
    transaction = ready["transaction"]
    if transaction["requested_packages"] != [
        "pipewire", "pipewire-alsa", "pipewire-audio", "pipewire-pulse",
        "wireplumber", "xdg-desktop-portal", "xdg-desktop-portal-gnome",
        "xdg-desktop-portal-gtk",
    ]:
        raise SystemExit(f"unexpected requested package set: {transaction['requested_packages']}")
    resolved = {item["package"]: item for item in transaction["resolved_packages"]}
    if resolved["pipewire-pulse"]["kind"] != "requested":
        raise SystemExit("direct package was not classified as requested")
    if resolved["dep-runtime"]["kind"] != "dependency":
        raise SystemExit("dependency package was not classified as dependency")
    if resolved["dep-runtime"]["download_size_bytes"] != 18432 or resolved["dep-runtime"]["installed_size_bytes"] != 38:
        raise SystemExit(f"dependency size parsing is wrong: {resolved['dep-runtime']}")
    if transaction["sizes"] != {
        "download_size_bytes": 49152,
        "installed_size_bytes": 71718,
    }:
        raise SystemExit(f"unexpected transaction sizes: {transaction['sizes']}")
    if transaction["installed_packages"] != ["pipewire"]:
        raise SystemExit(f"installed direct package state lost: {transaction['installed_packages']}")
    if "pipewire-pulse" not in transaction["missing_packages"]:
        raise SystemExit("missing direct package state was not reported")
    if transaction["query_failed_packages"]:
        raise SystemExit(f"ready fixture has failed package queries: {transaction['query_failed_packages']}")
    if ready["repository_query"]["status"] != "ok":
        raise SystemExit(f"repository metadata should be available: {ready['repository_query']}")
    if ready["repository_query"]["stale_databases"]:
        raise SystemExit("fresh fixture was incorrectly marked stale")
    if ready["prior_state"]["system_units"]["bluetooth.service"]["status"] != "ok":
        raise SystemExit("system service prior state was not captured")
    if ready["prior_state"]["user_units"]["pipewire.socket"]["status"] != "ok":
        raise SystemExit("user service prior state was not captured")
    if not ready["prior_state"]["package_owned_paths"]["/usr/lib/systemd/user/pipewire.socket"]["owner"].startswith("pipewire"):
        raise SystemExit("package ownership was not captured")
    if not ready["rollback"]["notes"] or not ready["post_checks"]:
        raise SystemExit("rollback notes and post-check list are required")
    if ready["apply"]["command"] is not None or ready["apply"]["authorized"]:
        raise SystemExit("transaction preview exposed an apply command/authorization")
    if "pacman -S" in ready_result.stdout or "systemctl enable" in ready_result.stdout:
        raise SystemExit("preview output contains an apply command")

    _bin, empty_env, empty_sync = make_fixture(base / "successful-empty", "successful-empty")
    empty_result = run_tool(empty_env, empty_sync)
    if empty_result.returncode != 0:
        raise SystemExit(f"successful empty resolution did not stay ready: rc={empty_result.returncode} stderr={empty_result.stderr}")
    empty = json.loads(empty_result.stdout)
    if empty["transaction"]["resolution"] != {
        "status": "ok",
        "resolved_count": 0,
        "successful_empty": True,
    } or empty["transaction"]["sizes"] != {
        "download_size_bytes": 0,
        "installed_size_bytes": 0,
    }:
        raise SystemExit(f"successful empty resolution was conflated with failure: {empty['transaction']}")

    _bin, literal_env, literal_sync = make_fixture(base / "literal-separators", "literal-separators")
    literal_result = run_tool(literal_env, literal_sync)
    if literal_result.returncode != 0:
        raise SystemExit(f"literal print-format separators were not parsed: rc={literal_result.returncode} stderr={literal_result.stderr}")
    literal = json.loads(literal_result.stdout)
    if literal["transaction"]["resolution"] != {
        "status": "ok",
        "resolved_count": 3,
        "successful_empty": False,
    }:
        raise SystemExit(f"literal separator resolution was malformed: {literal['transaction']['resolution']}")

    for scenario, expected_result, expected_exit in (
        ("target-not-found", "blocked", 1),
        ("query-failed", "unavailable", 2),
        ("all-metadata-query-failed", "unavailable", 2),
        ("resolution-query-failed", "unavailable", 2),
        ("dependency-target-not-found", "unavailable", 2),
        ("installed-query-failed", "unavailable", 2),
        ("service-query-failed", "unavailable", 2),
        ("ownership-query-failed", "unavailable", 2),
    ):
        _bin, scenario_env, scenario_sync = make_fixture(base / scenario, scenario)
        result = run_tool(scenario_env, scenario_sync)
        if result.returncode != expected_exit:
            raise SystemExit(f"{scenario}: expected exit {expected_exit}, got {result.returncode}; stderr={result.stderr}")
        report = json.loads(result.stdout)
        if report["overall"]["result"] != expected_result:
            raise SystemExit(f"{scenario}: expected {expected_result}, got {report['overall']}")
        if scenario == "target-not-found":
            record = report["repository_query"]["packages"]["xdg-desktop-portal-gtk"]
            if record["status"] != "target-not-found":
                raise SystemExit(f"target-not-found was collapsed into another state: {record}")
            if "xdg-desktop-portal-gtk" not in report["overall"]["blockers"]:
                raise SystemExit("target-not-found blocker was not preserved")
        else:
            if not report["overall"]["unavailable_checks"]:
                raise SystemExit(f"{scenario}: unavailable evidence was dropped")
            if scenario == "all-metadata-query-failed" and report["transaction"]["resolution"] != {
                "status": "unavailable",
                "resolved_count": 0,
                "successful_empty": False,
            }:
                raise SystemExit(f"failed metadata queries became an empty successful resolution: {report['transaction']['resolution']}")
            if scenario == "installed-query-failed" and (
                report["transaction"]["installed_packages"]
                or report["transaction"]["missing_packages"]
                or report["transaction"]["query_failed_packages"] != report["transaction"]["requested_packages"]
            ):
                raise SystemExit(f"failed installed inventory became an empty result: {report['transaction']}")
            if scenario == "resolution-query-failed" and (
                report["transaction"]["resolution_query"]["status"] != "query-failed"
                or report["transaction"]["resolution_query"]["query_exit"] != 2
            ):
                raise SystemExit(f"dependency resolution exit status was lost: {report['transaction']['resolution_query']}")

    _bin, mixed_env, mixed_sync = make_fixture(base / "conflict-and-service-failure", "conflict-and-service-failure")
    mixed_result = run_tool(mixed_env, mixed_sync)
    if mixed_result.returncode != 2:
        raise SystemExit(f"unavailable must take precedence over blockers: rc={mixed_result.returncode}")
    mixed = json.loads(mixed_result.stdout)
    if mixed["overall"]["result"] != "unavailable" or not mixed["overall"]["blockers"] or not mixed["overall"]["unavailable_checks"]:
        raise SystemExit(f"mixed blocker/unavailable evidence was lost: {mixed['overall']}")

    _bin, wrapped_env, wrapped_sync = make_fixture(base / "wrapped-conflict", "wrapped-conflict")
    wrapped_result = run_tool(wrapped_env, wrapped_sync)
    if wrapped_result.returncode != 1:
        raise SystemExit(f"wrapped repository metadata conflict was lost: rc={wrapped_result.returncode}")
    wrapped = json.loads(wrapped_result.stdout)
    if not any(item["conflict_package"] == "conflicting-audio" and item["status"] == "blocked" for item in wrapped["conflicts"]):
        raise SystemExit(f"wrapped conflict continuation was not parsed: {wrapped['conflicts']}")

    _bin, conflict_env, conflict_sync = make_fixture(base / "conflict", "conflict")
    conflict_result = run_tool(conflict_env, conflict_sync)
    if conflict_result.returncode != 1:
        raise SystemExit(f"conflict fixture should block: rc={conflict_result.returncode}")
    conflict = json.loads(conflict_result.stdout)
    if not conflict["conflicts"] or conflict["conflicts"][0]["status"] != "blocked":
        raise SystemExit(f"installed package conflict was not reported: {conflict['conflicts']}")

    invalid_threshold = run_tool(env, sync_dir, "--max-sync-db-age-hours", "nan")
    if invalid_threshold.returncode != 2:
        raise SystemExit(f"non-finite freshness threshold bypassed validation: rc={invalid_threshold.returncode}")

    mixed_db_base = base / "mixed-database-state"
    _bin, mixed_db_env, mixed_db_sync = make_fixture(mixed_db_base, "ready")
    os.utime(mixed_db_sync / "core.db", (1_999_000_000, 1_999_000_000))
    (mixed_db_sync / "extra.db").unlink()
    mixed_db_result = run_tool(mixed_db_env, mixed_db_sync)
    if mixed_db_result.returncode != 2:
        raise SystemExit(f"missing sync database must make the preview unavailable: rc={mixed_db_result.returncode}")
    mixed_db = json.loads(mixed_db_result.stdout)
    if "stale-sync-database:core" not in mixed_db["overall"]["blockers"] or "sync-db:extra" not in mixed_db["overall"]["unavailable_checks"]:
        raise SystemExit(f"mixed stale/unavailable repository evidence was lost: {mixed_db['overall']}")

    stale_base = base / "stale"
    _bin, stale_env, stale_sync = make_fixture(stale_base, "ready")
    for path in stale_sync.glob("*.db"):
        os.utime(path, (1_999_000_000, 1_999_000_000))
    stale_result = run_tool(stale_env, stale_sync)
    if stale_result.returncode != 1:
        raise SystemExit(f"stale repository metadata should block: rc={stale_result.returncode}")
    stale = json.loads(stale_result.stdout)
    if stale["repository_query"]["status"] != "stale" or not stale["repository_query"]["stale_databases"]:
        raise SystemExit(f"stale and empty repository states were conflated: {stale['repository_query']}")

print("Phase C transaction preview checks passed.")
PY
