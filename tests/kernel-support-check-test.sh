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
tool = root / "installer/kernel-support-check.py"
if not tool.is_file() or tool.is_symlink():
    raise SystemExit("kernel support checker is missing or unsafe")


def write_executable(path: Path, body: str) -> None:
    path.write_text(f"#!{sys.executable}\n{body}")
    path.chmod(0o755)


def make_fixture(base: Path) -> tuple[Path, Path, dict[str, str]]:
    bin_dir = base / "bin"
    modules_root = base / "modules"
    bin_dir.mkdir()
    for release in ("7.1.5-arch1-2", "7.1.5-zen1-2-zen"):
        (modules_root / release / "build").mkdir(parents=True)

    write_executable(
        bin_dir / "pacman",
        r'''import os
import sys

scenario = os.environ.get("MOCK_SCENARIO", "ready")
versions = {
    "linux": "7.1.5.arch1-2",
    "linux-headers": "7.1.5.arch1-2",
    "linux-zen": "7.1.5.zen1-2",
    "linux-zen-headers": "7.1.5.zen1-2",
    "nvidia-open-dkms": "610.43.03-5",
}
releases = {
    "linux": "7.1.5-arch1-2",
    "linux-zen": "7.1.5-zen1-2-zen",
}
args = sys.argv[1:]
if args == ["-Q", "linux"] and scenario == "pacman-query-failed":
    raise SystemExit(2)
if args == ["-Q", "linux"] and scenario == "pacman-exit1-error":
    print("error: local package database is unavailable", file=sys.stderr)
    raise SystemExit(1)
if args == ["-Q", "linux-zen-headers"] and scenario == "missing-header":
    print("error: package 'linux-zen-headers' was not found", file=sys.stderr)
    raise SystemExit(1)
if len(args) == 2 and args[0] == "-Q":
    package = args[1]
    if package not in versions:
        raise SystemExit(1)
    version = versions[package]
    if scenario == "version-mismatch" and package == "linux-zen-headers":
        version = "7.1.4.zen1-1"
    print(f"{package} {version}")
    raise SystemExit(0)
if len(args) == 2 and args[0] == "-Qql":
    package = args[1]
    if package not in releases:
        raise SystemExit(1)
    release = releases[package]
    print("/usr/lib/modules/")
    print(f"/usr/lib/modules/{release}/")
    print(f"/usr/lib/modules/{release}/kernel/example.ko.zst")
    raise SystemExit(0)
raise SystemExit(9)
''',
    )
    write_executable(
        bin_dir / "uname",
        r'''import os
import sys

if sys.argv[1:] != ["-r"]:
    raise SystemExit(9)
print(os.environ.get("MOCK_RUNNING_RELEASE", "7.1.5-zen1-2-zen"))
''',
    )
    write_executable(
        bin_dir / "dkms",
        r'''import os
import sys

if sys.argv[1:] != ["status"]:
    raise SystemExit(9)
scenario = os.environ.get("MOCK_SCENARIO", "ready")
if scenario == "dkms-query-failed":
    raise SystemExit(2)
if scenario == "empty-dkms":
    raise SystemExit(0)
if scenario == "unparsed-dkms":
    print("this is not a DKMS status record")
    raise SystemExit(0)
print("nvidia/610.43.03, 7.1.5-arch1-2, x86_64: installed")
print("nvidia/610.43.03, 7.1.5-zen1-2-zen, x86_64: installed")
''',
    )
    env = os.environ.copy()
    env["PATH"] = f"{bin_dir}:{env['PATH']}"
    env["LC_ALL"] = "C"
    return bin_dir, modules_root, env


def run_tool(modules_root: Path, env: dict[str, str], *, json_output: bool = True) -> subprocess.CompletedProcess[str]:
    args = [
        sys.executable,
        str(tool),
        "--profile",
        "asus-amd-nvidia",
        "--modules-root",
        str(modules_root),
    ]
    if json_output:
        args.append("--json")
    return subprocess.run(
        args,
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=env,
    )


with tempfile.TemporaryDirectory() as temporary:
    _bin_dir, modules_root, env = make_fixture(Path(temporary))

    ready_result = run_tool(modules_root, env)
    if ready_result.returncode != 0:
        raise SystemExit(f"ready fixture failed: rc={ready_result.returncode} stderr={ready_result.stderr}")
    ready = json.loads(ready_result.stdout)
    if ready["safety"] != {
        "planning_only": True,
        "installer_apply_integration": False,
        "system_changes": False,
        "boot_changes": False,
    }:
        raise SystemExit(f"unexpected safety block: {ready['safety']}")
    if ready["overall"] != {
        "result": "ready",
        "exit_code": 0,
        "blockers": [],
        "unavailable_checks": [],
        "warnings": [],
    }:
        raise SystemExit(f"unexpected ready result: {ready['overall']}")
    if [kernel["package"] for kernel in ready["kernels"]] != ["linux", "linux-zen"]:
        raise SystemExit(f"unexpected kernel order: {ready['kernels']}")
    if not all(kernel["header_version_match"] is True for kernel in ready["kernels"]):
        raise SystemExit("ready fixture should have exact kernel/header version matches")
    if ready["dkms"]["status"] != "ok" or ready["dkms"]["empty_result"]:
        raise SystemExit(f"unexpected ready DKMS query: {ready['dkms']}")
    if ready["checks"]["dkms-coverage"]["status"] != "pass":
        raise SystemExit("ready fixture should cover both supported kernel releases")

    text_result = run_tool(modules_root, env, json_output=False)
    for marker in (
        "Kernel/header/DKMS review (read-only)",
        "overall: ready (exit 0)",
        "boot changes: none",
        "linux -> linux-headers: pass",
        "linux-zen -> linux-zen-headers: pass",
        "DKMS nvidia coverage: pass",
    ):
        if marker not in text_result.stdout:
            raise SystemExit(f"text output is missing marker: {marker}")

    mismatch_env = env.copy()
    mismatch_env["MOCK_SCENARIO"] = "version-mismatch"
    mismatch_result = run_tool(modules_root, mismatch_env)
    if mismatch_result.returncode != 1:
        raise SystemExit(f"version mismatch should block with exit 1, got {mismatch_result.returncode}")
    mismatch = json.loads(mismatch_result.stdout)
    if mismatch["overall"]["result"] != "blocked":
        raise SystemExit(f"version mismatch was not blocked: {mismatch['overall']}")
    zen = next(kernel for kernel in mismatch["kernels"] if kernel["package"] == "linux-zen")
    if zen["header_version_match"] is not False:
        raise SystemExit(f"version mismatch was not preserved: {zen}")
    if mismatch["checks"]["header-version-match"]["status"] != "fail":
        raise SystemExit("header version mismatch check should fail")

    failed_env = env.copy()
    failed_env["MOCK_SCENARIO"] = "pacman-query-failed"
    failed_result = run_tool(modules_root, failed_env)
    if failed_result.returncode != 2:
        raise SystemExit(f"failed pacman query should exit 2, got {failed_result.returncode}")
    failed = json.loads(failed_result.stdout)
    linux_package = failed["packages"]["linux"]
    if linux_package["status"] != "query-failed" or linux_package["query_exit"] != 2:
        raise SystemExit(f"failed pacman query was misreported: {linux_package}")
    if linux_package["status"] == "missing":
        raise SystemExit("failed pacman query must not be reported as missing")
    if failed["overall"]["result"] != "unavailable":
        raise SystemExit(f"failed query should make readiness unavailable: {failed['overall']}")

    exit1_error_env = env.copy()
    exit1_error_env["MOCK_SCENARIO"] = "pacman-exit1-error"
    exit1_error_result = run_tool(modules_root, exit1_error_env)
    if exit1_error_result.returncode != 2:
        raise SystemExit(f"non-not-found pacman exit 1 should exit 2, got {exit1_error_result.returncode}")
    exit1_error = json.loads(exit1_error_result.stdout)
    exit1_linux = exit1_error["packages"]["linux"]
    if exit1_linux["status"] != "query-failed" or exit1_linux["query_exit"] != 1:
        raise SystemExit(f"non-not-found pacman exit 1 was misreported: {exit1_linux}")
    if exit1_error["overall"]["result"] != "unavailable":
        raise SystemExit("non-not-found pacman exit 1 should make readiness unavailable")

    missing_env = env.copy()
    missing_env["MOCK_SCENARIO"] = "missing-header"
    missing_result = run_tool(modules_root, missing_env)
    if missing_result.returncode != 1:
        raise SystemExit(f"known missing header should block with exit 1, got {missing_result.returncode}")
    missing = json.loads(missing_result.stdout)
    missing_header = missing["packages"]["linux-zen-headers"]
    if missing_header["status"] != "missing" or missing_header["query_exit"] != 1:
        raise SystemExit(f"known missing header was not preserved: {missing_header}")
    if missing["overall"]["result"] != "blocked" or missing["overall"]["unavailable_checks"]:
        raise SystemExit(f"known missing header should be a blocker, not unavailable: {missing['overall']}")

    empty_env = env.copy()
    empty_env["MOCK_SCENARIO"] = "empty-dkms"
    empty_result = run_tool(modules_root, empty_env)
    if empty_result.returncode != 1:
        raise SystemExit(f"successful empty DKMS query should block with exit 1, got {empty_result.returncode}")
    empty = json.loads(empty_result.stdout)
    if empty["dkms"]["status"] != "ok" or empty["dkms"]["empty_result"] is not True:
        raise SystemExit(f"successful empty DKMS query was not preserved: {empty['dkms']}")
    if empty["checks"]["dkms-query"]["status"] != "pass":
        raise SystemExit("successful empty DKMS query is an available query")
    if empty["checks"]["dkms-coverage"]["status"] != "fail":
        raise SystemExit("empty DKMS result should fail coverage")
    if empty["overall"]["unavailable_checks"]:
        raise SystemExit("successful empty DKMS query must not be reported unavailable")

    unparsed_env = env.copy()
    unparsed_env["MOCK_SCENARIO"] = "unparsed-dkms"
    unparsed_result = run_tool(modules_root, unparsed_env)
    if unparsed_result.returncode != 2:
        raise SystemExit(f"unparsed DKMS output should exit 2, got {unparsed_result.returncode}")
    unparsed = json.loads(unparsed_result.stdout)
    if unparsed["dkms"]["status"] != "parse-failed" or unparsed["dkms"]["unparsed_line_count"] != 1:
        raise SystemExit(f"unparsed DKMS output was not preserved: {unparsed['dkms']}")
    if unparsed["overall"]["result"] != "unavailable":
        raise SystemExit("unparsed DKMS output should make readiness unavailable")
PY

printf 'Kernel support checker tests passed.\n'
