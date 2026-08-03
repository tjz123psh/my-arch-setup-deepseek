#!/usr/bin/env python3
"""Plan or install verified fixed AUR artifacts with independent authorization."""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any

ABSENT_RE_TEMPLATE = r"^error: package '{package}' was not found\s*$"
PACKAGE_RE = re.compile(r"[a-z0-9@._+:-]+")
HEX64_RE = re.compile(r"[0-9a-f]{64}")
PACKAGER = "my-archlinux-setup fixed AUR recipe"


@dataclass(frozen=True)
class Recipe:
    package: str
    pkgbase: str
    role: str
    module: str
    pkgver: str
    pkgrel: str
    tree_sha256: str


class PlanError(Exception):
    pass


class InstallFailure(Exception):
    def __init__(self, status: int, message: str):
        super().__init__(message)
        self.status = status
        self.message = message


def safe_lines(path: Path, schema: str, label: str) -> list[str]:
    if not path.is_file() or path.is_symlink():
        raise PlanError(f"{label} is missing or unsafe")
    lines = path.read_text().splitlines()
    if not lines or lines[0] != schema:
        raise PlanError(f"{label} has an unsupported schema")
    return lines


def load_recipes(project_root: Path) -> dict[str, Recipe]:
    lines = safe_lines(project_root / "manifests/aur-recipes.tsv", "# schema=2", "AUR recipe manifest")
    result: dict[str, Recipe] = {}
    for line_number, parts in enumerate(csv.reader(lines[1:], delimiter="\t"), 2):
        if not parts or not parts[0] or parts[0].startswith("#"):
            continue
        if len(parts) != 14 or not all(parts):
            raise PlanError(f"invalid AUR recipe row at line {line_number}")
        package, pkgbase, role, module, pkgver, pkgrel, arch, _commit, tree = parts[:9]
        review_state = parts[12]
        if (
            PACKAGE_RE.fullmatch(package) is None
            or PACKAGE_RE.fullmatch(pkgbase) is None
            or package in result
            or arch != "x86_64"
            or review_state not in {"reviewed", "precondition"}
            or HEX64_RE.fullmatch(tree) is None
        ):
            raise PlanError(f"invalid build-eligible AUR recipe at line {line_number}")
        result[package] = Recipe(package, pkgbase, role, module, pkgver, pkgrel, tree)
    if len(result) != 15:
        raise PlanError(f"expected 15 AUR install targets, found {len(result)}")
    return result


def parse_selection(value: str | None, recipes: dict[str, Recipe]) -> list[str]:
    if value is None or value == "all":
        return sorted(recipes, key=lambda name: (recipes[name].role != "paru-bootstrap", name))
    selected: list[str] = []
    seen: set[str] = set()
    for name in value.split(","):
        if not name:
            raise PlanError("empty package in --packages")
        if name in seen:
            raise PlanError(f"duplicate package in --packages: {name}")
        if name not in recipes:
            raise PlanError(f"undeclared package in --packages: {name}")
        seen.add(name)
        selected.append(name)
    return selected


def lexical_absolute(path: Path) -> Path:
    return Path(os.path.abspath(os.fspath(path.expanduser())))


def first_symlink(path: Path) -> Path | None:
    current = Path(path.anchor)
    for part in path.parts[1:]:
        current /= part
        if current.is_symlink():
            return current
    return None


def hash_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def load_artifact(build_root: Path, recipe: Recipe) -> tuple[dict[str, Any] | None, str | None, str | None]:
    directory = build_root / "artifacts" / recipe.package / recipe.tree_sha256
    state = directory / "artifact.json"
    if not directory.exists():
        return None, f"{recipe.package}: verified artifact directory is missing", None
    if directory.is_symlink() or not directory.is_dir() or state.is_symlink() or not state.is_file():
        return None, f"{recipe.package}: artifact state is incomplete or unsafe", None
    try:
        metadata = json.loads(state.read_text())
    except (OSError, json.JSONDecodeError):
        return None, None, f"{recipe.package}: artifact metadata query failed"
    expected = {
        "package": recipe.package,
        "pkgbase": recipe.pkgbase,
        "version": f"{recipe.pkgver}-{recipe.pkgrel}",
        "arch": "x86_64",
    }
    if any(metadata.get(key) != value for key, value in expected.items()):
        return None, f"{recipe.package}: artifact metadata identity mismatch", None
    filename = metadata.get("filename")
    sha256 = metadata.get("sha256")
    if not isinstance(filename, str) or Path(filename).name != filename or not HEX64_RE.fullmatch(str(sha256)):
        return None, f"{recipe.package}: artifact metadata filename/hash is invalid", None
    artifact = directory / filename
    if artifact.is_symlink() or not artifact.is_file():
        return None, f"{recipe.package}: artifact file is missing or unsafe", None
    try:
        actual = hash_file(artifact)
    except OSError:
        return None, None, f"{recipe.package}: artifact hash query failed"
    if actual != sha256:
        return None, f"{recipe.package}: artifact SHA-256 mismatch", None
    return {**metadata, "path": str(artifact), "recipe_tree_sha256": recipe.tree_sha256}, None, None


def require_private_state(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {"schema": 1, "packages": {}}
    if path.is_symlink() or not path.is_file():
        raise PlanError("AUR install state is missing or unsafe")
    file_stat = path.stat()
    if stat.S_IMODE(file_stat.st_mode) != 0o600 or file_stat.st_nlink != 1:
        raise PlanError("AUR install state must be mode 600 with one hard link")
    try:
        value = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise PlanError("AUR install state is malformed or unreadable") from error
    if not isinstance(value, dict) or value.get("schema") != 1 or not isinstance(value.get("packages"), dict):
        raise PlanError("AUR install state has an unsupported schema")
    for package, record in value["packages"].items():
        if PACKAGE_RE.fullmatch(package) is None or not isinstance(record, dict):
            raise PlanError("AUR install state contains an invalid package row")
        if not HEX64_RE.fullmatch(str(record.get("artifact_sha256", ""))) or not HEX64_RE.fullmatch(str(record.get("recipe_tree_sha256", ""))):
            raise PlanError(f"AUR install state contains an invalid hash for {package}")
    return value


def query_installed(package: str) -> dict[str, Any]:
    pacman = shutil.which("pacman")
    if pacman is None:
        return {"state": "query-failed", "query_exit": None, "reason": "pacman is missing"}
    result = subprocess.run(
        [pacman, "-Q", "--", package],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env={**os.environ, "LC_ALL": "C"},
        check=False,
    )
    if result.returncode == 0:
        parts = result.stdout.strip().split()
        if len(parts) != 2 or parts[0] != package:
            return {"state": "query-failed", "query_exit": 0, "reason": "pacman returned malformed installed metadata"}
        return {"state": "installed", "version": parts[1], "query_exit": 0}
    absent_re = re.compile(ABSENT_RE_TEMPLATE.format(package=re.escape(package)))
    if result.returncode == 1 and absent_re.fullmatch(result.stderr.strip()):
        return {"state": "missing", "query_exit": 1}
    return {"state": "query-failed", "query_exit": result.returncode, "reason": "installed-package query failed"}


def compare_versions(proposed: str, installed: str) -> dict[str, Any]:
    vercmp = shutil.which("vercmp")
    if vercmp is None:
        return {"state": "query-failed", "query_exit": None, "reason": "vercmp is missing"}
    result = subprocess.run([vercmp, proposed, installed], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    raw = result.stdout.strip()
    if result.returncode != 0 or raw not in {"-1", "0", "1"}:
        return {"state": "query-failed", "query_exit": result.returncode, "reason": "version comparison failed"}
    return {"state": "ok", "query_exit": 0, "comparison": int(raw)}


def root_helper(home: Path) -> dict[str, Any]:
    helper = home / "scripts/desktop/gsudo"
    askpass = home / "scripts/desktop/fuzzel-askpass"
    for path, label in ((helper, "gsudo"), (askpass, "fuzzel-askpass")):
        if path.is_symlink() or not path.is_file() or not os.access(path, os.X_OK):
            return {"state": "unavailable", "path": str(helper), "reason": f"{label} is missing, unsafe, or not executable"}
    return {"state": "available", "path": str(helper), "askpass": str(askpass)}


def build_plan(recipes: dict[str, Recipe], selected: list[str], build_root: Path, state_path: Path) -> tuple[dict[str, Any], dict[str, Any]]:
    blockers: list[str] = []
    unavailable: list[str] = []
    if os.geteuid() == 0:
        blockers.append("AUR artifact installation must run as an ordinary user")
    for path, label in ((build_root, "build root"), (state_path, "install state")):
        if first_symlink(path) is not None:
            blockers.append(f"{label} path contains a symlink")
    try:
        state = require_private_state(state_path)
    except PlanError as error:
        blockers.append(str(error))
        state = {"schema": 1, "packages": {}}
    helper = root_helper(Path.home())
    if helper["state"] != "available":
        unavailable.append(f"audited gsudo root helper unavailable: {helper['reason']}")
    if shutil.which("pacman") is None:
        unavailable.append("pacman is missing")

    reports = []
    effects = []
    for name in selected:
        recipe = recipes[name]
        artifact, artifact_blocker, artifact_unavailable = load_artifact(build_root, recipe)
        if artifact_blocker:
            blockers.append(artifact_blocker)
        if artifact_unavailable:
            unavailable.append(artifact_unavailable)
        installed = query_installed(name)
        if installed["state"] == "query-failed":
            unavailable.append(f"{name}: {installed['reason']} (exit={installed['query_exit']})")
            action = "unavailable"
            comparison = None
        elif artifact is None:
            action = "blocked"
            comparison = None
        elif installed["state"] == "missing":
            action = "install"
            comparison = None
            effects.append({"package": name, "action": action, "artifact": artifact["path"]})
        else:
            comparison = compare_versions(artifact["version"], installed["version"])
            if comparison["state"] == "query-failed":
                unavailable.append(f"{name}: {comparison['reason']} (exit={comparison['query_exit']})")
                action = "unavailable"
            elif comparison["comparison"] < 0:
                blockers.append(f"{name}: installed version {installed['version']} is newer than fixed artifact {artifact['version']}; automatic downgrade is forbidden")
                action = "blocked-newer-installed"
            else:
                prior = state["packages"].get(name)
                provenance_matches = bool(
                    prior
                    and prior.get("version") == artifact["version"]
                    and prior.get("artifact_sha256") == artifact["sha256"]
                    and prior.get("recipe_tree_sha256") == artifact["recipe_tree_sha256"]
                )
                if comparison["comparison"] == 0 and provenance_matches:
                    action = "verified-skip"
                elif comparison["comparison"] == 0:
                    action = "reinstall-establish-provenance"
                    effects.append({"package": name, "action": action, "artifact": artifact["path"]})
                else:
                    action = "upgrade"
                    effects.append({"package": name, "action": action, "artifact": artifact["path"]})
        reports.append(
            {
                "package": name,
                "module": recipe.module,
                "target_version": f"{recipe.pkgver}-{recipe.pkgrel}",
                "artifact": artifact,
                "installed": installed,
                "version_comparison": comparison,
                "action": action,
            }
        )
    if unavailable:
        overall, exit_code = "unavailable", 2
    elif blockers:
        overall, exit_code = "blocked", 1
    else:
        overall, exit_code = "ready", 0
    plan = {
        "schema": 1,
        "selection": {"packages": selected},
        "records": reports,
        "effects": effects,
        "root_helper": helper,
        "overall": {"status": overall, "exit_code": exit_code, "blockers": blockers, "unavailable_checks": unavailable},
        "confirmation": {"required_flags": ["--confirm-aur", "--confirm-system-changes"]},
        "apply": {"authorized": False, "commands": None},
        "rollback": [
            "No package is automatically removed or downgraded.",
            "Prior installed versions and exact artifact hashes are retained in the private log/state.",
            "Recovery is a separately reviewed pacman transaction or snapshot rollback when available.",
        ],
        "safety": {"system_changes": False, "package_changes": False, "arbitrary_artifacts": False, "automatic_downgrade": False},
    }
    return plan, state


def private_directory(path: Path) -> None:
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    if path.is_symlink() or not path.is_dir():
        raise InstallFailure(1, f"private directory is unsafe: {path}")
    os.chmod(path, 0o700)


def private_log(state_root: Path) -> Path:
    logs = state_root / "logs"
    private_directory(logs)
    stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    path = logs / f"aur-install-{stamp}-{os.getpid()}.log"
    fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    os.close(fd)
    return path


def log(path: Path, text: str) -> None:
    with path.open("a", encoding="utf-8") as handle:
        handle.write(text + "\n")


def atomic_state(path: Path, value: dict[str, Any]) -> None:
    private_directory(path.parent)
    temporary = path.with_name(f".{path.name}.tmp-{os.getpid()}")
    fd = os.open(temporary, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump(value, handle, indent=2, sort_keys=True)
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temporary, path)


def apply_install(plan: dict[str, Any], state: dict[str, Any], state_path: Path, state_root: Path) -> tuple[Path, int]:
    effects = plan["effects"]
    log_path = private_log(state_root)
    log(log_path, "authorization: independent AUR and system-change confirmations received")
    for record in plan["records"]:
        log(log_path, f"prior: {record['package']} state={record['installed']['state']} version={record['installed'].get('version', '-')} action={record['action']}")
    if effects:
        helper = Path(plan["root_helper"]["path"])
        command = [str(helper), "--", "pacman", "-U", "--noconfirm", "--", *[effect["artifact"] for effect in effects]]
        try:
            result = subprocess.run(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, check=False)
        except OSError as error:
            log(log_path, f"install command unavailable: {type(error).__name__}")
            raise InstallFailure(127, "audited AUR artifact install command could not execute") from error
        log(log_path, result.stdout.rstrip())
        log(log_path, f"pacman-install-exit={result.returncode}")
        if result.returncode != 0:
            status = result.returncode if 1 <= result.returncode <= 125 else 1
            raise InstallFailure(status, f"AUR artifact installation failed with exit {result.returncode}")
    now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    for record in plan["records"]:
        installed = query_installed(record["package"])
        if installed["state"] != "installed" or installed.get("version") != record["target_version"]:
            raise InstallFailure(1, f"post-check failed for {record['package']}")
        artifact = record["artifact"]
        state["packages"][record["package"]] = {
            "version": record["target_version"],
            "artifact_sha256": artifact["sha256"],
            "recipe_tree_sha256": artifact["recipe_tree_sha256"],
            "installed_at": now,
            "packager": PACKAGER,
        }
        log(log_path, f"post-check: {record['package']} {record['target_version']} passed")
    atomic_state(state_path, state)
    return log_path, 0


def render_text(plan: dict[str, Any]) -> None:
    print("Verified fixed AUR artifact installation plan")
    print(f"Status: {plan['overall']['status']}")
    for record in plan["records"]:
        print(f"  [{record['action']}/{record['module']}] {record['package']} -> {record['target_version']}")
    if plan["overall"]["blockers"]:
        print("Blockers:")
        for item in plan["overall"]["blockers"]:
            print(f"  - {item}")
    if plan["overall"]["unavailable_checks"]:
        print("Unavailable checks:")
        for item in plan["overall"]["unavailable_checks"]:
            print(f"  - {item}")
    print("Apply: disabled; no package or system change was made.")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    action = parser.add_mutually_exclusive_group()
    action.add_argument("--plan", action="store_true")
    action.add_argument("--install", action="store_true")
    parser.add_argument("--packages")
    parser.add_argument("--confirm-aur", action="store_true")
    parser.add_argument("--confirm-system-changes", action="store_true")
    parser.add_argument("--build-root", type=Path, default=Path(os.environ.get("XDG_STATE_HOME", str(Path.home() / ".local/state"))) / "my-archlinux-setup/builds/aur")
    parser.add_argument("--state-root", type=Path, default=Path(os.environ.get("XDG_STATE_HOME", str(Path.home() / ".local/state"))) / "my-archlinux-setup")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--project-root", type=Path, help=argparse.SUPPRESS)
    args = parser.parse_args()
    if (args.confirm_aur or args.confirm_system_changes) and not args.install:
        parser.error("confirmation flags are valid only with --install")
    if args.install and (not args.confirm_aur or not args.confirm_system_changes):
        parser.error("--install requires both --confirm-aur and --confirm-system-changes")
    project_root = (args.project_root or Path(__file__).resolve().parent.parent).resolve()
    build_root = lexical_absolute(args.build_root)
    state_root = lexical_absolute(args.state_root)
    state_path = state_root / "aur-installed.json"
    try:
        recipes = load_recipes(project_root)
        selected = parse_selection(args.packages, recipes)
        plan, state = build_plan(recipes, selected, build_root, state_path)
    except PlanError as error:
        print(f"aur-install: {error}", file=sys.stderr)
        raise SystemExit(2) from error
    if not args.install:
        if args.json:
            json.dump(plan, sys.stdout, indent=2, sort_keys=True)
            print()
        else:
            render_text(plan)
        raise SystemExit(plan["overall"]["exit_code"])
    if plan["overall"]["status"] != "ready":
        print("aur-install: install plan is not ready", file=sys.stderr)
        raise SystemExit(plan["overall"]["exit_code"])
    try:
        log_path, status = apply_install(plan, state, state_path, state_root)
    except InstallFailure as error:
        print(f"aur-install: {error.message}", file=sys.stderr)
        raise SystemExit(error.status) from error
    result = {"status": "passed", "exit_code": status, "private_log": str(log_path), "state": str(state_path)}
    if args.json:
        json.dump(result, sys.stdout, indent=2, sort_keys=True)
        print()
    else:
        print(f"AUR artifact installation passed; private log: {log_path}")


if __name__ == "__main__":
    main()
