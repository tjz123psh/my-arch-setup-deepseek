#!/usr/bin/env python3
"""Plan or build declared fixed AUR recipes in an official-only clean chroot."""

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
import tempfile
import time
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any

PACKAGE_RE = re.compile(r"[a-z0-9@._+:-]+")
HEX64_RE = re.compile(r"[0-9a-f]{64}")
SAFE_REL_RE = re.compile(r"[A-Za-z0-9._/+:-]+")


@dataclass(frozen=True)
class BuildPolicy:
    backend: str
    architecture: str
    chroot_relative: str
    bootstrap_packages: str
    pacman_config: str
    host_prerequisite: str
    authorization: str
    root_authorization: str
    root_helper: str
    artifact_roots: str
    purpose: str


@dataclass(frozen=True)
class Recipe:
    package: str
    pkgbase: str
    role: str
    module: str
    pkgver: str
    pkgrel: str
    arch: str
    aur_commit: str
    tree_sha256: str
    source_policy: str
    external_source: str
    executes_source: str
    review_state: str
    review_note: str


class PlanError(Exception):
    pass


class BuildFailure(Exception):
    def __init__(self, status: int, message: str):
        super().__init__(message)
        self.status = status
        self.message = message


def external_status(status: int) -> int:
    if status < 0:
        return min(255, 128 + abs(status))
    return min(255, status)


def safe_lines(path: Path, schema: str, label: str) -> list[str]:
    if not path.is_file() or path.is_symlink():
        raise PlanError(f"{label} is missing or unsafe")
    try:
        lines = path.read_text().splitlines()
    except OSError as error:
        raise PlanError(f"could not read {label}: {error}") from error
    if not lines or lines[0] != schema:
        raise PlanError(f"{label} has an unsupported schema")
    return lines


def load_build_policy(project_root: Path) -> BuildPolicy:
    lines = safe_lines(project_root / "manifests/aur-build-policy.tsv", "# schema=1", "AUR build policy")
    rows = [parts for parts in csv.reader(lines[1:], delimiter="\t") if parts and parts[0] and not parts[0].startswith("#")]
    if len(rows) != 1 or len(rows[0]) != 11 or not all(rows[0]):
        raise PlanError("AUR build policy must contain exactly one complete row")
    policy = BuildPolicy(*rows[0])
    if policy.backend != "clean-chroot" or policy.architecture != "x86_64":
        raise PlanError("AUR build policy lost the x86_64 clean-chroot boundary")
    if policy.chroot_relative.startswith("/") or SAFE_REL_RE.fullmatch(policy.chroot_relative) is None or ".." in Path(policy.chroot_relative).parts:
        raise PlanError("AUR chroot path is unsafe")
    if policy.bootstrap_packages.split(",") != ["base-devel", "rust"]:
        raise PlanError("AUR chroot bootstrap package set changed")
    if policy.host_prerequisite != "devtools":
        raise PlanError("AUR build host prerequisite changed")
    if policy.authorization != "aur" or policy.root_authorization != "system-changes":
        raise PlanError("AUR build authorization boundaries changed")
    if policy.root_helper != "gsudo":
        raise PlanError("AUR build policy permits an unexpected root helper")
    if set(policy.artifact_roots.split(",")) != {"usr", "opt", "etc"}:
        raise PlanError("AUR artifact root allowlist changed")
    template = project_root / policy.pacman_config
    if not template.is_file() or template.is_symlink():
        raise PlanError("AUR chroot pacman template is missing or unsafe")
    template_text = template.read_text()
    effective_template = "\n".join(
        line for line in template_text.splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    )
    for section in ("[core]", "[extra]", "[multilib]"):
        if section not in effective_template:
            raise PlanError(f"AUR chroot pacman template omits {section}")
    if "archlinuxcn" in effective_template.lower() or "SigLevel = Required DatabaseOptional" not in effective_template:
        raise PlanError("AUR chroot pacman template lost official-only signature policy")
    return policy


def load_recipes(project_root: Path) -> dict[str, Recipe]:
    lines = safe_lines(project_root / "manifests/aur-recipes.tsv", "# schema=2", "AUR recipe manifest")
    recipes: dict[str, Recipe] = {}
    for line_number, parts in enumerate(csv.reader(lines[1:], delimiter="\t"), 2):
        if not parts or not parts[0] or parts[0].startswith("#"):
            continue
        if len(parts) != 14 or not all(parts):
            raise PlanError(f"invalid AUR recipe row at line {line_number}")
        recipe = Recipe(*parts)
        if PACKAGE_RE.fullmatch(recipe.package) is None or PACKAGE_RE.fullmatch(recipe.pkgbase) is None:
            raise PlanError(f"unsafe AUR identity at line {line_number}")
        if recipe.package in recipes:
            raise PlanError(f"duplicate AUR recipe: {recipe.package}")
        if recipe.arch != "x86_64" or recipe.review_state not in {"reviewed", "precondition"}:
            raise PlanError(f"AUR recipe is not build-eligible: {recipe.package}")
        if not HEX64_RE.fullmatch(recipe.tree_sha256):
            raise PlanError(f"invalid recipe tree hash: {recipe.package}")
        recipes[recipe.package] = recipe
    if len(recipes) != 15:
        raise PlanError(f"expected 15 build recipes, found {len(recipes)}")
    return recipes


def validate_devtools_target(project_root: Path, expected: str) -> None:
    lines = safe_lines(project_root / "manifests/workstation-packages.tsv", "# schema=1", "workstation package policy")
    matches = []
    for parts in csv.reader(lines[1:], delimiter="\t"):
        if parts and parts[0] == expected:
            matches.append(parts)
    if len(matches) != 1 or len(matches[0]) != 9:
        raise PlanError("devtools clean-chroot prerequisite is absent or duplicated")
    row = matches[0]
    if row[1:8] != ["pacman", "extra", "pacman", "build-foundation", "package-only", "install", "confirmed-desired"]:
        raise PlanError("devtools prerequisite has an unexpected target policy")


def parse_selection(value: str | None, recipes: dict[str, Recipe]) -> list[str]:
    if value is None or value == "all":
        return sorted(recipes, key=lambda name: (recipes[name].role != "paru-bootstrap", name))
    result: list[str] = []
    seen: set[str] = set()
    for name in value.split(","):
        if not name:
            raise PlanError("empty package in --packages")
        if name in seen:
            raise PlanError(f"duplicate package in --packages: {name}")
        if name not in recipes:
            raise PlanError(f"undeclared package in --packages: {name}")
        seen.add(name)
        result.append(name)
    return result


def lexical_absolute(path: Path) -> Path:
    return Path(os.path.abspath(os.fspath(path.expanduser())))


def first_symlink(path: Path) -> Path | None:
    current = Path(path.anchor)
    for part in path.parts[1:]:
        current /= part
        if current.is_symlink():
            return current
    return None


def command_state(command: str, planned_prerequisite: bool) -> dict[str, Any]:
    resolved = shutil.which(command)
    if resolved is not None:
        return {"command": command, "state": "available", "path": resolved}
    if planned_prerequisite:
        return {"command": command, "state": "planned-prerequisite", "package": "devtools"}
    return {"command": command, "state": "missing"}


def expected_root_helper(home: Path) -> tuple[Path, Path]:
    directory = home / "scripts/desktop"
    return directory / "gsudo", directory / "fuzzel-askpass"


def inspect_root_helper(home: Path) -> dict[str, Any]:
    helper, askpass = expected_root_helper(home)
    for path, label in ((helper, "gsudo"), (askpass, "fuzzel-askpass")):
        if path.is_symlink() or not path.is_file():
            return {"state": "missing-or-unsafe", "path": str(helper), "reason": f"{label} is missing or unsafe"}
        if not os.access(path, os.X_OK):
            return {"state": "not-executable", "path": str(helper), "reason": f"{label} is not executable"}
    return {"state": "available", "path": str(helper), "askpass": str(askpass)}


def inspect_chroot(path: Path) -> dict[str, Any]:
    symlink = first_symlink(path)
    if symlink is not None:
        return {"state": "conflict", "path": str(path), "reason": "chroot path contains a symlink"}
    root = path / "root"
    if not path.exists():
        return {"state": "absent", "path": str(path)}
    if not path.is_dir() or path.is_symlink():
        return {"state": "conflict", "path": str(path), "reason": "chroot base is not a directory"}
    if not root.exists():
        return {"state": "incomplete", "path": str(path), "reason": "chroot root is missing"}
    if root.is_symlink() or not root.is_dir():
        return {"state": "conflict", "path": str(path), "reason": "chroot root is unsafe"}
    required = [root / ".arch-chroot", root / "usr/bin/pacman", root / "usr/bin/rustc"]
    missing = [str(item.relative_to(root)) for item in required if not item.exists()]
    if missing:
        return {"state": "incomplete", "path": str(path), "missing": missing, "reason": "chroot markers/tools are incomplete"}
    return {"state": "ready", "path": str(path)}


def run_aur_plan(project_root: Path, source_cache: Path, selected: list[str]) -> tuple[dict[str, Any] | None, int, str | None]:
    command = [
        sys.executable,
        str(project_root / "installer/aur-plan.py"),
        "--project-root", str(project_root),
        "--source-cache", str(source_cache),
        "--packages", ",".join(selected),
        "--json",
    ]
    try:
        result = subprocess.run(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    except OSError as error:
        return None, 2, f"AUR source planner could not execute ({type(error).__name__})"
    if result.returncode not in {0, 1, 2}:
        return None, 2, f"AUR source planner returned unexpected exit {result.returncode}"
    try:
        report = json.loads(result.stdout)
    except json.JSONDecodeError:
        return None, 2, "AUR source planner returned malformed JSON"
    return report, result.returncode, None


def hash_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def inspect_existing_artifact(build_root: Path, recipe: Recipe) -> dict[str, Any]:
    directory = build_root / "artifacts" / recipe.package / recipe.tree_sha256
    state = directory / "artifact.json"
    if not directory.exists():
        return {"state": "absent", "directory": str(directory)}
    if directory.is_symlink() or not directory.is_dir() or state.is_symlink() or not state.is_file():
        return {"state": "conflict", "directory": str(directory), "reason": "artifact state path is incomplete or unsafe"}
    try:
        metadata = json.loads(state.read_text())
    except (OSError, json.JSONDecodeError):
        return {"state": "query-failed", "directory": str(directory), "reason": "artifact metadata query failed"}
    artifact = directory / metadata.get("filename", "")
    if (
        metadata.get("package") != recipe.package
        or metadata.get("pkgbase") != recipe.pkgbase
        or metadata.get("version") != f"{recipe.pkgver}-{recipe.pkgrel}"
        or metadata.get("arch") != "x86_64"
        or not artifact.is_file()
        or artifact.is_symlink()
    ):
        return {"state": "conflict", "directory": str(directory), "reason": "artifact metadata identity mismatch"}
    try:
        actual = hash_file(artifact)
    except OSError:
        return {"state": "query-failed", "directory": str(directory), "reason": "artifact hash query failed"}
    if actual != metadata.get("sha256"):
        return {"state": "conflict", "directory": str(directory), "reason": "artifact SHA-256 mismatch"}
    return {"state": "verified", "directory": str(directory), "artifact": str(artifact), "sha256": actual}


def build_plan(
    project_root: Path,
    policy: BuildPolicy,
    recipes: dict[str, Recipe],
    selected: list[str],
    source_cache: Path,
    build_root: Path,
    state_root: Path,
    post_official: bool,
) -> dict[str, Any]:
    blockers: list[str] = []
    unavailable: list[str] = []
    if os.geteuid() == 0:
        blockers.append("AUR build orchestration must run as an ordinary user")
    for path, label in ((source_cache, "source cache"), (build_root, "build root"), (state_root, "state root")):
        symlink = first_symlink(path)
        if symlink is not None:
            blockers.append(f"{label} path contains a symlink")

    source_report, source_exit, source_error = run_aur_plan(project_root, source_cache, selected)
    if source_error is not None:
        unavailable.append(source_error)
    elif source_exit == 2:
        unavailable.extend(source_report["overall"]["unavailable_checks"] or ["AUR source planning unavailable"])
    elif source_exit == 1:
        blockers.extend(source_report["overall"]["blockers"])

    commands = [command_state("makepkg", False)]
    for command in ("mkarchroot", "makechrootpkg", "arch-nspawn"):
        state = command_state(command, not post_official)
        commands.append(state)
        if state["state"] == "missing":
            unavailable.append(f"required clean-chroot command is missing after official stage: {command}")
    if commands[0]["state"] == "missing":
        unavailable.append("makepkg is missing")

    root_helper = inspect_root_helper(Path.home())
    if root_helper["state"] != "available":
        if post_official:
            unavailable.append(f"audited gsudo root helper unavailable: {root_helper['reason']}")
        else:
            root_helper["state"] = "required-before-apply"

    chroot = inspect_chroot(state_root / policy.chroot_relative)
    if chroot["state"] in {"conflict", "incomplete"}:
        blockers.append(f"AUR build chroot is {chroot['state']}: {chroot.get('reason', '')}".rstrip())

    package_reports = []
    for name in selected:
        recipe = recipes[name]
        artifact = inspect_existing_artifact(build_root, recipe)
        if artifact["state"] == "conflict":
            blockers.append(f"{name}: {artifact['reason']}")
        elif artifact["state"] == "query-failed":
            unavailable.append(f"{name}: {artifact['reason']}")
        source_state = None
        if source_report is not None:
            source_state = next(item["status"] for item in source_report["recipes"] if item["package"] == name)
        package_reports.append({**asdict(recipe), "source_status": source_state, "artifact": artifact})

    if unavailable:
        status, exit_code = "unavailable", 2
    elif blockers:
        status, exit_code = "blocked", 1
    else:
        status, exit_code = "ready", 0
    effects = []
    if chroot["state"] == "absent":
        effects.append({"id": "initialize-official-clean-chroot", "packages": policy.bootstrap_packages.split(",")})
    elif chroot["state"] == "ready":
        effects.append({"id": "update-official-clean-chroot"})
    for report in package_reports:
        if report["artifact"]["state"] != "verified":
            effects.append({"id": "verify-source-and-build", "package": report["package"], "executes_source": report["executes_source"] == "yes"})
    return {
        "schema": 1,
        "policy": asdict(policy),
        "selection": {"packages": selected},
        "paths": {"source_cache": str(source_cache), "build_root": str(build_root), "state_root": str(state_root)},
        "source_plan": source_report,
        "commands": commands,
        "root_helper": root_helper,
        "chroot": chroot,
        "packages": package_reports,
        "effects": effects,
        "overall": {"status": status, "exit_code": exit_code, "blockers": blockers, "unavailable_checks": unavailable},
        "confirmation": {"required_flags": ["--confirm-aur", "--confirm-system-changes"]},
        "apply": {"authorized": False, "commands": None},
        "rollback": [
            "No host package, repository, service or boot rollback is automatic.",
            "Failed workspaces and private logs are retained for review.",
            "The dedicated chroot is retained; removal is a separate scoped confirmed action.",
            "Verified package artifacts are never installed by this build command.",
        ],
        "safety": {
            "system_changes": False,
            "host_package_changes": False,
            "artifact_install": False,
            "official_only_chroot": True,
            "build_user_unprivileged": True,
            "network_during_package_build": False,
        },
    }


def private_directory(path: Path) -> None:
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    if path.is_symlink() or not path.is_dir():
        raise BuildFailure(1, f"private directory is unsafe: {path}")
    os.chmod(path, 0o700)


def create_log(build_root: Path) -> Path:
    logs = build_root / "logs"
    private_directory(logs)
    stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    path = logs / f"aur-build-{stamp}-{os.getpid()}.log"
    fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    os.close(fd)
    return path


def append_log(path: Path, text: str) -> None:
    with path.open("a", encoding="utf-8", errors="replace") as handle:
        handle.write(text)
        if text and not text.endswith("\n"):
            handle.write("\n")


def run_logged(command: list[str], log: Path, label: str, *, cwd: Path | None = None, env: dict[str, str] | None = None) -> int:
    append_log(log, f"start: {label}")
    try:
        result = subprocess.run(command, cwd=cwd, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, check=False)
    except OSError as error:
        append_log(log, f"command unavailable: {label}: {type(error).__name__}")
        return 127
    append_log(log, result.stdout)
    append_log(log, f"exit: {label}: {result.returncode}")
    return result.returncode


def root_command(helper: Path, command: list[str]) -> list[str]:
    return [str(helper), "--", *command]


def cleanup_failed_chroot_initialization(helper: Path, chroot: Path, log: Path) -> bool:
    """Remove only known partial mkarchroot paths so an external failure can retry."""

    try:
        base_info = chroot.lstat()
    except FileNotFoundError:
        return True
    except OSError as error:
        append_log(log, f"cleanup failed: could not inspect chroot base: {type(error).__name__}")
        return False
    if (
        chroot.is_symlink()
        or not stat.S_ISDIR(base_info.st_mode)
        or base_info.st_uid != os.geteuid()
        or stat.S_IMODE(base_info.st_mode) != 0o700
    ):
        append_log(log, "cleanup refused: chroot base ownership/type/mode is unsafe")
        return False

    root = chroot / "root"
    lock = chroot / "root.lock"
    if root.exists() or root.is_symlink() or lock.exists() or lock.is_symlink():
        status = run_logged(
            root_command(
                helper,
                [
                    "/usr/bin/rm",
                    "-rf",
                    "--one-file-system",
                    "--preserve-root=all",
                    "--",
                    str(root),
                    str(lock),
                ],
            ),
            log,
            "remove known partial clean-chroot initialization paths",
        )
        if status != 0:
            append_log(log, f"cleanup failed: partial clean-chroot removal exited {status}")
            return False
    try:
        chroot.rmdir()
    except FileNotFoundError:
        return True
    except OSError as error:
        append_log(
            log,
            f"cleanup failed: chroot base retained for review: {type(error).__name__}",
        )
        return False
    append_log(log, "cleanup passed: failed clean-chroot initialization left no retry blocker")
    return True


def copy_recipe(project_root: Path, recipe: Recipe, workspace: Path, source_cache: Path) -> None:
    source = project_root / "third_party/aur" / recipe.package
    private_directory(workspace)
    for entry in source.iterdir():
        if entry.is_symlink() or not entry.is_file():
            raise BuildFailure(1, f"{recipe.package}: recipe contains an unsafe entry")
        shutil.copy2(entry, workspace / entry.name)
    if recipe.external_source != "-":
        external = source_cache / recipe.package / recipe.external_source
        if external.is_symlink() or not external.is_file():
            raise BuildFailure(1, f"{recipe.package}: fixed external source is missing or unsafe")
        shutil.copy2(external, workspace / recipe.external_source)


def parse_pkginfo(raw: str) -> dict[str, list[str]]:
    values: dict[str, list[str]] = {}
    for line in raw.splitlines():
        if not line or line.startswith("#"):
            continue
        if " = " not in line:
            raise BuildFailure(1, "artifact .PKGINFO contains a malformed row")
        key, value = line.split(" = ", 1)
        values.setdefault(key, []).append(value)
    return values


def verify_artifact(staging: Path, recipe: Recipe, allowed_roots: set[str]) -> dict[str, Any]:
    candidates = [
        path for path in staging.iterdir()
        if path.is_file() and not path.is_symlink() and ".pkg.tar" in path.name and not path.name.startswith(f"{recipe.package}-debug-")
    ]
    if len(candidates) != 1:
        raise BuildFailure(1, f"{recipe.package}: expected exactly one primary artifact, found {len(candidates)}")
    artifact = candidates[0]
    bsdtar = shutil.which("bsdtar")
    if bsdtar is None:
        raise BuildFailure(127, "bsdtar is unavailable for artifact verification")
    info = subprocess.run([bsdtar, "-xOf", str(artifact), ".PKGINFO"], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    if info.returncode != 0:
        raise BuildFailure(info.returncode, f"{recipe.package}: artifact .PKGINFO query failed")
    metadata = parse_pkginfo(info.stdout)
    expected = {
        "pkgname": recipe.package,
        "pkgbase": recipe.pkgbase,
        "pkgver": f"{recipe.pkgver}-{recipe.pkgrel}",
        "arch": "x86_64",
        "packager": "my-archlinux-setup fixed AUR recipe",
    }
    for key, value in expected.items():
        if metadata.get(key) != [value]:
            raise BuildFailure(1, f"{recipe.package}: artifact {key} identity mismatch")
    listing = subprocess.run([bsdtar, "-tf", str(artifact)], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    if listing.returncode != 0:
        raise BuildFailure(listing.returncode, f"{recipe.package}: artifact file-list query failed")
    files = [line.rstrip("/") for line in listing.stdout.splitlines() if line]
    for name in files:
        path = Path(name)
        if path.is_absolute() or ".." in path.parts:
            raise BuildFailure(1, f"{recipe.package}: artifact contains an unsafe path")
        if name.startswith("."):
            if name not in {".BUILDINFO", ".MTREE", ".PKGINFO"}:
                raise BuildFailure(1, f"{recipe.package}: artifact contains unexpected metadata path {name}")
        elif path.parts and path.parts[0] not in allowed_roots:
            raise BuildFailure(1, f"{recipe.package}: artifact writes outside reviewed roots: {path.parts[0]}")
    return {
        "package": recipe.package,
        "pkgbase": recipe.pkgbase,
        "version": f"{recipe.pkgver}-{recipe.pkgrel}",
        "arch": "x86_64",
        "filename": artifact.name,
        "sha256": hash_file(artifact),
        "bytes": artifact.stat().st_size,
        "file_count": len(files),
        "files": files,
    }


def atomic_json(path: Path, value: dict[str, Any]) -> None:
    temporary = path.with_name(f".{path.name}.tmp-{os.getpid()}")
    fd = os.open(temporary, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump(value, handle, indent=2, sort_keys=True)
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temporary, path)


def build_one(
    project_root: Path,
    policy: BuildPolicy,
    recipe: Recipe,
    source_cache: Path,
    build_root: Path,
    chroot: Path,
    helper: Path,
    log: Path,
) -> dict[str, Any]:
    existing = inspect_existing_artifact(build_root, recipe)
    if existing["state"] == "verified":
        append_log(log, f"skip: {recipe.package}: verified artifact already exists")
        return existing
    workspaces = build_root / "workspaces" / recipe.package
    private_directory(workspaces)
    workspace = workspaces / f"{recipe.tree_sha256}-{int(time.time())}-{os.getpid()}"
    copy_recipe(project_root, recipe, workspace, source_cache)
    home = workspace / ".source-home"
    private_directory(home)
    environment = os.environ.copy()
    environment.update({"HOME": str(home), "SRCDEST": str(workspace), "LC_ALL": "C"})
    status = run_logged(["makepkg", "--verifysource", "--noconfirm"], log, f"{recipe.package} source verification", cwd=workspace, env=environment)
    if status != 0:
        raise BuildFailure(external_status(status), f"{recipe.package}: source verification failed with exit {status}")
    staging = build_root / "staging" / recipe.package / f"{recipe.tree_sha256}-{os.getpid()}"
    private_directory(staging)
    logs = workspace / "makepkg-logs"
    private_directory(logs)
    command = root_command(
        helper,
        [
            "env",
            f"PKGDEST={staging}",
            f"SRCDEST={workspace}",
            f"LOGDEST={logs}",
            "PACKAGER=my-archlinux-setup fixed AUR recipe",
            "makechrootpkg",
            "-c",
            "-r",
            str(chroot),
            "--",
            "--noconfirm",
        ],
    )
    status = run_logged(command, log, f"{recipe.package} clean-chroot build", cwd=workspace)
    if status != 0:
        raise BuildFailure(external_status(status), f"{recipe.package}: clean-chroot build failed with exit {status}")
    metadata = verify_artifact(staging, recipe, set(policy.artifact_roots.split(",")))
    final = build_root / "artifacts" / recipe.package / recipe.tree_sha256
    if final.exists():
        raise BuildFailure(1, f"{recipe.package}: refusing to overwrite existing artifact directory")
    private_directory(final.parent)
    final.mkdir(mode=0o700)
    source_artifact = staging / metadata["filename"]
    destination = final / metadata["filename"]
    os.replace(source_artifact, destination)
    os.chmod(destination, 0o600)
    atomic_json(final / "artifact.json", metadata)
    append_log(log, f"passed: {recipe.package}: artifact verified sha256={metadata['sha256']}")
    return {"state": "verified", "directory": str(final), "artifact": str(destination), "sha256": metadata["sha256"]}


def apply_build(
    project_root: Path,
    policy: BuildPolicy,
    recipes: dict[str, Recipe],
    selected: list[str],
    source_cache: Path,
    build_root: Path,
    state_root: Path,
) -> tuple[list[dict[str, Any]], Path, int]:
    private_directory(build_root)
    private_directory(state_root)
    helper, _askpass = expected_root_helper(Path.home())
    helper_report = inspect_root_helper(Path.home())
    if helper_report["state"] != "available":
        raise BuildFailure(127, f"audited gsudo root helper unavailable: {helper_report['reason']}")
    log = create_log(build_root)
    chroot = state_root / policy.chroot_relative
    chroot_report = inspect_chroot(chroot)
    if chroot_report["state"] == "absent":
        # Current devtools resolves the working directory with readlink -f
        # before creating it, so the immediate parent of <chroot>/root must
        # already exist. Create only the ordinary-user-owned private base;
        # mkarchroot remains solely responsible for the root subtree.
        private_directory(chroot)
        status = run_logged(
            root_command(
                helper,
                [
                    "mkarchroot",
                    "-C", str(project_root / policy.pacman_config),
                    str(chroot / "root"),
                    *policy.bootstrap_packages.split(","),
                ],
            ),
            log,
            "initialize official-only AUR clean chroot",
        )
        if status != 0:
            cleanup = cleanup_failed_chroot_initialization(helper, chroot, log)
            cleanup_state = "passed" if cleanup else "failed; partial state retained for review"
            raise BuildFailure(
                external_status(status),
                f"clean-chroot initialization failed with exit {status}; cleanup {cleanup_state}",
            )
    elif chroot_report["state"] != "ready":
        raise BuildFailure(1, f"clean chroot is not usable: {chroot_report['state']}")
    status = run_logged(
        root_command(helper, ["arch-nspawn", str(chroot / "root"), "pacman", "-Syu", "--noconfirm"]),
        log,
        "update official-only AUR clean chroot",
    )
    if status != 0:
        raise BuildFailure(external_status(status), f"clean-chroot update failed with exit {status}")

    results: list[dict[str, Any]] = []
    final_status = 0
    for name in selected:
        try:
            artifact = build_one(project_root, policy, recipes[name], source_cache, build_root, chroot, helper, log)
        except BuildFailure as error:
            append_log(log, f"failed: {name}: {error.message} exit={error.status}")
            results.append({"package": name, "status": "failed", "exit": error.status, "message": error.message})
            if final_status == 0:
                final_status = error.status
        else:
            results.append({"package": name, "status": "passed", "exit": 0, "artifact": artifact})
    return results, log, final_status


def render_text(plan: dict[str, Any]) -> None:
    print("Fixed AUR clean-chroot build plan")
    print(f"Status: {plan['overall']['status']}")
    print(f"Chroot: {plan['chroot']['state']} — {plan['chroot']['path']}")
    for package in plan["packages"]:
        print(f"  [{package['source_status']}/{package['artifact']['state']}] {package['package']} {package['pkgver']}-{package['pkgrel']}")
    if plan["overall"]["blockers"]:
        print("Blockers:")
        for item in plan["overall"]["blockers"]:
            print(f"  - {item}")
    if plan["overall"]["unavailable_checks"]:
        print("Unavailable checks:")
        for item in plan["overall"]["unavailable_checks"]:
            print(f"  - {item}")
    print("Build/apply: disabled in this plan; artifacts are not packages installed on the host.")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    action = parser.add_mutually_exclusive_group()
    action.add_argument("--plan", action="store_true")
    action.add_argument("--build", action="store_true")
    parser.add_argument("--packages")
    parser.add_argument("--confirm-aur", action="store_true")
    parser.add_argument("--confirm-system-changes", action="store_true")
    parser.add_argument("--post-official", action="store_true", help="require devtools commands to already be installed")
    parser.add_argument("--source-cache", type=Path, default=Path(os.environ.get("XDG_CACHE_HOME", str(Path.home() / ".cache"))) / "my-archlinux-setup/aur-sources")
    parser.add_argument("--build-root", type=Path, default=Path(os.environ.get("XDG_STATE_HOME", str(Path.home() / ".local/state"))) / "my-archlinux-setup/builds/aur")
    parser.add_argument("--state-root", type=Path, default=Path(os.environ.get("XDG_STATE_HOME", str(Path.home() / ".local/state"))) / "my-archlinux-setup")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--project-root", type=Path, help=argparse.SUPPRESS)
    args = parser.parse_args()
    if (args.confirm_aur or args.confirm_system_changes) and not args.build:
        parser.error("confirmation flags are valid only with --build")
    if args.build and (not args.confirm_aur or not args.confirm_system_changes):
        parser.error("--build requires both --confirm-aur and --confirm-system-changes")
    project_root = (args.project_root or Path(__file__).resolve().parent.parent).resolve()
    source_cache = lexical_absolute(args.source_cache)
    build_root = lexical_absolute(args.build_root)
    state_root = lexical_absolute(args.state_root)
    try:
        policy = load_build_policy(project_root)
        validate_devtools_target(project_root, policy.host_prerequisite)
        recipes = load_recipes(project_root)
        selected = parse_selection(args.packages, recipes)
        plan = build_plan(project_root, policy, recipes, selected, source_cache, build_root, state_root, args.post_official)
    except PlanError as error:
        print(f"aur-build: {error}", file=sys.stderr)
        raise SystemExit(2) from error
    if not args.build:
        if args.json:
            json.dump(plan, sys.stdout, indent=2, sort_keys=True)
            print()
        else:
            render_text(plan)
        raise SystemExit(plan["overall"]["exit_code"])
    if plan["overall"]["status"] != "ready":
        print("aur-build: build plan is not ready", file=sys.stderr)
        raise SystemExit(plan["overall"]["exit_code"])
    try:
        results, log, status = apply_build(project_root, policy, recipes, selected, source_cache, build_root, state_root)
    except BuildFailure as error:
        print(f"aur-build: {error.message}", file=sys.stderr)
        raise SystemExit(error.status) from error
    report = {"results": results, "private_log": str(log), "status": "passed" if status == 0 else "failed", "exit_code": status, "artifact_install": False}
    if args.json:
        json.dump(report, sys.stdout, indent=2, sort_keys=True)
        print()
    else:
        print(f"AUR clean-chroot build result: {report['status']}; private log: {log}")
    raise SystemExit(status)


if __name__ == "__main__":
    main()
