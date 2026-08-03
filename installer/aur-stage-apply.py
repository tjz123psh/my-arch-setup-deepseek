#!/usr/bin/env python3
"""Fingerprint-bound full-orchestrator adapter for the two reviewed AUR stages.

The public entry point intentionally has no package-selection CLI.  Its exact
package set is reconstructed from the FULL_ORCHESTRATOR_* environment and the
reviewed workstation policy.  Preflight and verify paths are read-only; only
execute dispatches the existing fixed AUR acquisition/build/install tools.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import os
import platform
import re
import shutil
import stat
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any, NoReturn, Sequence
from urllib.parse import urlsplit

PROJECT_ROOT = Path(__file__).resolve().parent.parent

AUDITED_GSUDO_SHA256 = "7a63f2b74c6ab2d005dd84d03851148b129dbd530c753453f1c1f680414253b7"
AUDITED_ASKPASS_SHA256 = "4396717f5a63e25ebff7d64aeb49b2b1fb26956da0f22e1aed7a34ad768edb8a"
AUR_PLAN_SHA256 = "5609a3b6c7df5bf39b14265b0f92e8e1ada006f750224934e028b13fa6e4b6e6"
AUR_SOURCE_ACQUIRE_SHA256 = "c524adff22e69f8827154625f826ad19ff6b2db25f1b6d4b7a9859c8b640d6e2"
AUR_BUILD_SHA256 = "d95d99ce7ee40e6a0565ea26dc067bae42de6419c8ff6d30fe335e3e96ce1bc0"
AUR_INSTALL_SHA256 = "fca99216d7a93581e1abd9b3ff49929a9cd7970d35eaf1786797c92bb7fe9c93"

STATE_DIRECTORY = Path("my-archlinux-setup")
SOURCE_CACHE_DIRECTORY = Path("my-archlinux-setup/aur-sources")
PROVENANCE_NAME = "aur-source-provenance.json"
INSTALL_STATE_NAME = "aur-installed.json"
MAX_EFFECTS_JSON = 256 * 1024
MAX_RECIPE_FILE_BYTES = 1024 * 1024
PACKAGER = "my-archlinux-setup fixed AUR recipe"

PACKAGE_RE = re.compile(r"[a-z0-9][a-z0-9@._+:-]*")
TOKEN_RE = re.compile(r"[a-z0-9][a-z0-9-]*")
SAFE_FILE_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._+@:-]*")
SAFE_REL_RE = re.compile(r"[A-Za-z0-9._/+:-]+")
HEX40_RE = re.compile(r"[0-9a-f]{40}")
HEX64_RE = re.compile(r"[0-9a-f]{64}")
RUN_ID_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:-]{0,127}")
ROLES = frozenset({"aur-build", "paru-bootstrap"})
SOURCE_POLICIES = frozenset({"remote-fixed", "local-fixed", "domain-blocked"})
SOURCE_METHODS = frozenset({"direct-download", "signed-url-download", "cargo-vendor"})
SOURCE_METHOD_COMMANDS = {
    "direct-download": ("curl",),
    "signed-url-download": ("curl",),
    "cargo-vendor": ("curl", "cargo", "tar", "zstd"),
}
DEVTOOLS_COMMANDS = ("mkarchroot", "makechrootpkg", "arch-nspawn")
BASE_SOURCE_COMMANDS = ("makepkg", "vercmp", "sudo")
BASE_BUILD_COMMANDS = ("pacman", "bsdtar")


class AdapterFailure(Exception):
    """A classified adapter failure whose status can be returned unchanged."""

    def __init__(self, status: int, message: str):
        super().__init__(message)
        self.status = normalize_status(status)
        self.message = message


@dataclass(frozen=True)
class WorkstationRow:
    package: str
    channel: str
    repository: str
    acquisition: str
    module: str
    restore_mode: str
    policy: str
    origin: str
    purpose: str

    def effect(self, prefix: str) -> dict[str, str]:
        return {
            "detail": (
                f"package={self.package} channel={self.channel} "
                f"repository={self.repository} acquisition={self.acquisition}"
            ),
            "id": f"{prefix}{self.package}",
            "module": self.module,
        }


@dataclass(frozen=True)
class RecipeRow:
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

    @property
    def version(self) -> str:
        return f"{self.pkgver}-{self.pkgrel}"


@dataclass(frozen=True)
class SourcePolicyRow:
    package: str
    method: str
    output: str
    output_sha256: str
    expected_bytes: str
    primary_url: str
    primary_sha256: str
    lock_sha256: str
    bootstrap_url: str
    auxiliary_url: str
    allowed_host: str
    authorization: str
    purpose: str


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
class PolicyBundle:
    workstation_rows: tuple[WorkstationRow, ...]
    aur_rows: tuple[WorkstationRow, ...]
    recipes: dict[str, RecipeRow]
    source_policies: dict[str, SourcePolicyRow]
    build_policy: BuildPolicy
    workstation_sha256: str
    recipe_sha256: str
    source_sha256: str
    build_sha256: str
    template_sha256: str


@dataclass(frozen=True)
class StageContext:
    action: str
    stage: str
    profile: str
    selected_modules: tuple[str, ...]
    stage_modules: tuple[str, ...]
    effects: tuple[dict[str, str], ...]
    plan_fingerprint: str
    run_id: str
    attempt: int
    rows: tuple[WorkstationRow, ...]
    recipes: tuple[RecipeRow, ...]
    local_sources: tuple[SourcePolicyRow, ...]

    @property
    def packages(self) -> tuple[str, ...]:
        return tuple(row.package for row in self.rows)


@dataclass(frozen=True)
class RuntimePaths:
    home: Path
    cache_base: Path
    state_base: Path
    source_cache: Path
    state_root: Path
    build_root: Path
    provenance: Path
    install_state: Path
    chroot: Path
    gsudo: Path
    askpass: Path


@dataclass(frozen=True)
class ToolPaths:
    plan: Path
    source_acquire: Path
    build: Path
    install: Path


@dataclass(frozen=True)
class CommandResult:
    argv: tuple[str, ...]
    status: int
    stdout: str
    stderr: str


@dataclass(frozen=True)
class ArtifactRecord:
    package: str
    path: Path
    sha256: str
    version: str
    tree_sha256: str


def normalize_status(status: int) -> int:
    if status < 0:
        return min(255, 128 + abs(status))
    if status == 0:
        return 0
    return min(255, status)


def fail(status: int, message: str) -> NoReturn:
    raise AdapterFailure(status, message)


def has_control(value: str) -> bool:
    return any(ord(character) < 32 or ord(character) == 127 for character in value)


def canonical_bytes(value: Any, *, pretty: bool = False) -> bytes:
    if pretty:
        text = json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
    else:
        text = json.dumps(value, ensure_ascii=False, separators=(",", ":"), sort_keys=True)
    return text.encode("utf-8")


def canonical_digest(value: Any) -> str:
    return hashlib.sha256(canonical_bytes(value)).hexdigest()


def hash_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def hash_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def lexical_absolute(path: Path) -> Path:
    return Path(os.path.abspath(os.fspath(path.expanduser())))


def first_symlink(path: Path) -> Path | None:
    absolute = lexical_absolute(path)
    current = Path(absolute.anchor)
    for part in absolute.parts[1:]:
        current /= part
        try:
            info = current.lstat()
        except FileNotFoundError:
            continue
        except OSError as error:
            fail(2, f"could not inspect path component {current}: {error}")
        if stat.S_ISLNK(info.st_mode):
            return current
    return None


def validate_path_components(path: Path, label: str) -> None:
    if not path.is_absolute():
        fail(2, f"{label} must be absolute: {path}")
    symlink = first_symlink(path)
    if symlink is not None:
        fail(1, f"{label} path contains a symlink: {symlink}")
    current = Path(path.anchor)
    for part in path.parts[1:-1]:
        current /= part
        try:
            info = current.lstat()
        except FileNotFoundError:
            continue
        except OSError as error:
            fail(2, f"could not inspect {label} component {current}: {error}")
        if not stat.S_ISDIR(info.st_mode):
            fail(1, f"{label} path has a non-directory component: {current}")


def safe_regular_file(
    path: Path,
    label: str,
    *,
    executable: bool = False,
    private: bool = False,
    expected_sha256: str | None = None,
    missing_status: int = 2,
) -> tuple[bytes, os.stat_result]:
    path = lexical_absolute(path)
    validate_path_components(path, label)
    try:
        info = path.lstat()
    except FileNotFoundError:
        fail(missing_status, f"{label} is missing: {path}")
    except OSError as error:
        fail(2, f"could not inspect {label} {path}: {error}")
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
        fail(1, f"{label} is not a safe regular file: {path}")
    if info.st_nlink != 1:
        fail(1, f"{label} must have exactly one hard link: {path}")
    if info.st_uid != os.geteuid():
        fail(1, f"{label} is not owned by the invoking user: {path}")
    mode = stat.S_IMODE(info.st_mode)
    if private:
        if mode != 0o600:
            fail(1, f"{label} must be mode 600: {path}")
    elif mode & 0o022:
        fail(1, f"{label} is group/world writable: {path}")
    if executable and not mode & 0o111:
        fail(missing_status, f"{label} is not executable: {path}")
    try:
        data = path.read_bytes()
    except OSError as error:
        fail(2, f"could not read {label} {path}: {error}")
    if len(data) != info.st_size:
        fail(2, f"{label} changed while it was being read: {path}")
    digest = hash_bytes(data)
    if expected_sha256 is not None and digest != expected_sha256:
        fail(1, f"{label} SHA-256 differs from the reviewed payload: {path}")
    return data, info


def safe_regular_info(
    path: Path,
    label: str,
    *,
    executable: bool = False,
    private: bool = False,
    missing_status: int = 2,
) -> os.stat_result:
    """Inspect a regular file without loading a potentially huge payload."""
    path = lexical_absolute(path)
    validate_path_components(path, label)
    try:
        info = path.lstat()
    except FileNotFoundError:
        fail(missing_status, f"{label} is missing: {path}")
    except OSError as error:
        fail(2, f"could not inspect {label} {path}: {error}")
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
        fail(1, f"{label} is not a safe regular file: {path}")
    if info.st_nlink != 1:
        fail(1, f"{label} must have exactly one hard link: {path}")
    if info.st_uid != os.geteuid():
        fail(1, f"{label} is not owned by the invoking user: {path}")
    mode = stat.S_IMODE(info.st_mode)
    if private:
        if mode != 0o600:
            fail(1, f"{label} must be mode 600: {path}")
    elif mode & 0o022:
        fail(1, f"{label} is group/world writable: {path}")
    if executable and not mode & 0o111:
        fail(missing_status, f"{label} is not executable: {path}")
    return info


def safe_directory(path: Path, label: str, *, private: bool = False) -> os.stat_result:
    path = lexical_absolute(path)
    validate_path_components(path, label)
    try:
        info = path.lstat()
    except FileNotFoundError:
        fail(1, f"{label} is missing: {path}")
    except OSError as error:
        fail(2, f"could not inspect {label} {path}: {error}")
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
        fail(1, f"{label} is not a safe directory: {path}")
    if info.st_uid != os.geteuid():
        fail(1, f"{label} is not owned by the invoking user: {path}")
    mode = stat.S_IMODE(info.st_mode)
    if private and mode != 0o700:
        fail(1, f"{label} must be mode 700: {path}")
    if not private and mode & 0o022:
        fail(1, f"{label} is group/world writable: {path}")
    return info


def read_manifest(path: Path, schema: str, label: str) -> tuple[list[str], str]:
    data, _info = safe_regular_file(path, label)
    try:
        text = data.decode("utf-8")
    except UnicodeError as error:
        fail(2, f"{label} is not valid UTF-8: {error}")
    lines = text.splitlines()
    if not lines or lines[0] != schema:
        fail(2, f"{label} has an unsupported schema")
    return lines, hash_bytes(data)


def tsv_rows(lines: Sequence[str], fields: int, label: str) -> list[tuple[int, list[str]]]:
    result: list[tuple[int, list[str]]] = []
    for line_number, parts in enumerate(csv.reader(lines[1:], delimiter="\t"), 2):
        if not parts or not parts[0] or parts[0].startswith("#"):
            continue
        if len(parts) != fields or not all(parts):
            fail(2, f"{label} has an invalid row at line {line_number}")
        if any(has_control(value) for value in parts):
            fail(2, f"{label} has a control character at line {line_number}")
        result.append((line_number, parts))
    if not result:
        fail(2, f"{label} has no data rows")
    return result


def recipe_tree_hash(directory: Path) -> str:
    safe_directory(directory, f"AUR recipe directory {directory.name}")
    try:
        entries = sorted(directory.iterdir(), key=lambda item: os.fsencode(item.name))
    except OSError as error:
        fail(2, f"could not list AUR recipe directory {directory}: {error}")
    if not entries:
        fail(1, f"AUR recipe directory is empty: {directory.name}")
    digest = hashlib.sha256()
    for entry in entries:
        try:
            info = entry.lstat()
        except OSError as error:
            fail(2, f"could not inspect recipe entry {entry}: {error}")
        if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
            fail(1, f"recipe contains a non-regular/symlink entry: {directory.name}/{entry.name}")
        if info.st_nlink != 1:
            fail(1, f"recipe entry has an unsafe hard-link count: {directory.name}/{entry.name}")
        if info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) & 0o022:
            fail(1, f"recipe entry has unsafe ownership/mode: {directory.name}/{entry.name}")
        if info.st_size > MAX_RECIPE_FILE_BYTES:
            fail(1, f"recipe entry exceeds 1 MiB: {directory.name}/{entry.name}")
        try:
            data = entry.read_bytes()
        except OSError as error:
            fail(2, f"could not read recipe entry {entry}: {error}")
        if len(data) != info.st_size:
            fail(2, f"recipe entry changed while being read: {directory.name}/{entry.name}")
        digest.update(entry.name.encode())
        digest.update(b"\0")
        digest.update(f"{stat.S_IMODE(info.st_mode):04o}".encode())
        digest.update(b"\0")
        digest.update(hash_bytes(data).encode())
        digest.update(b"\n")
    return digest.hexdigest()


def load_workstation_policy() -> tuple[tuple[WorkstationRow, ...], tuple[WorkstationRow, ...], str]:
    path = PROJECT_ROOT / "manifests/workstation-packages.tsv"
    lines, digest = read_manifest(path, "# schema=1", "workstation package policy")
    rows: list[WorkstationRow] = []
    seen: set[str] = set()
    for line_number, parts in tsv_rows(lines, 9, "workstation package policy"):
        row = WorkstationRow(*parts)
        if PACKAGE_RE.fullmatch(row.package) is None or TOKEN_RE.fullmatch(row.module) is None:
            fail(2, f"workstation package policy has an unsafe identity at line {line_number}")
        if row.package in seen:
            fail(2, f"workstation package policy repeats package {row.package}")
        seen.add(row.package)
        if row.acquisition in ROLES and not (
            row.channel == "aur"
            and row.repository == "aur"
            and row.policy == "install"
            and row.restore_mode in {"package-only", "config-backed"}
        ):
            fail(2, f"executable AUR workstation row is inconsistent: {row.package}")
        rows.append(row)
    aur_rows = tuple(sorted((row for row in rows if row.acquisition in ROLES), key=lambda row: row.package))
    if not aur_rows:
        fail(2, "workstation package policy has no executable AUR rows")
    return tuple(rows), aur_rows, digest


def load_recipes(aur_rows: tuple[WorkstationRow, ...]) -> tuple[dict[str, RecipeRow], str]:
    manifest = PROJECT_ROOT / "manifests/aur-recipes.tsv"
    lines, digest = read_manifest(manifest, "# schema=2", "AUR recipe policy")
    recipes: dict[str, RecipeRow] = {}
    for line_number, parts in tsv_rows(lines, 14, "AUR recipe policy"):
        row = RecipeRow(*parts)
        if PACKAGE_RE.fullmatch(row.package) is None or PACKAGE_RE.fullmatch(row.pkgbase) is None:
            fail(2, f"AUR recipe policy has an unsafe identity at line {line_number}")
        if row.package in recipes:
            fail(2, f"AUR recipe policy repeats package {row.package}")
        if row.role not in ROLES or row.arch != "x86_64":
            fail(2, f"AUR recipe has an unsupported role/architecture: {row.package}")
        if HEX40_RE.fullmatch(row.aur_commit) is None or HEX64_RE.fullmatch(row.tree_sha256) is None:
            fail(2, f"AUR recipe has an invalid reviewed hash: {row.package}")
        if row.source_policy not in SOURCE_POLICIES:
            fail(2, f"AUR recipe has an invalid source policy: {row.package}")
        if row.executes_source not in {"yes", "no"}:
            fail(2, f"AUR recipe has an invalid executes-source value: {row.package}")
        if row.review_state not in {"reviewed", "precondition"}:
            fail(1, f"AUR recipe is not build-eligible: {row.package}")
        if row.source_policy == "local-fixed":
            if SAFE_FILE_RE.fullmatch(row.external_source) is None or row.review_state != "precondition":
                fail(2, f"AUR local-fixed recipe has an unsafe precondition: {row.package}")
        elif row.external_source != "-":
            fail(2, f"AUR non-local recipe unexpectedly names an external source: {row.package}")
        recipes[row.package] = row

    policy_by_package = {row.package: row for row in aur_rows}
    if set(recipes) != set(policy_by_package):
        missing = sorted(set(policy_by_package) - set(recipes))
        extra = sorted(set(recipes) - set(policy_by_package))
        fail(2, f"AUR recipe/workstation set mismatch (missing={missing}, extra={extra})")
    for package, recipe in recipes.items():
        policy = policy_by_package[package]
        if recipe.role != policy.acquisition or recipe.module != policy.module:
            fail(2, f"AUR recipe role/module differs from workstation policy: {package}")

    recipe_root = PROJECT_ROOT / "third_party/aur"
    safe_directory(recipe_root, "AUR recipe root")
    try:
        entries = tuple(recipe_root.iterdir())
    except OSError as error:
        fail(2, f"could not list AUR recipe root: {error}")
    directory_names: set[str] = set()
    for entry in entries:
        try:
            info = entry.lstat()
        except OSError as error:
            fail(2, f"could not inspect AUR recipe root entry {entry}: {error}")
        if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
            fail(1, f"AUR recipe root contains a non-directory/symlink entry: {entry.name}")
        directory_names.add(entry.name)
    if directory_names != set(recipes):
        missing = sorted(set(recipes) - directory_names)
        extra = sorted(directory_names - set(recipes))
        fail(1, f"AUR recipe directory set drifted (missing={missing}, extra={extra})")
    for package, recipe in recipes.items():
        actual = recipe_tree_hash(recipe_root / package)
        if actual != recipe.tree_sha256:
            fail(1, f"{package}: recipe tree SHA-256 differs from aur-recipes.tsv")
    return recipes, digest


def validate_https(url: str, package: str, label: str) -> None:
    parsed = urlsplit(url)
    if (
        parsed.scheme != "https"
        or not parsed.hostname
        or parsed.username is not None
        or parsed.password is not None
        or any(ord(character) < 33 for character in url)
    ):
        fail(2, f"{package}: {label} is not an unauthenticated HTTPS URL")


def load_source_policies(recipes: dict[str, RecipeRow]) -> tuple[dict[str, SourcePolicyRow], str]:
    path = PROJECT_ROOT / "manifests/aur-source-acquisition.tsv"
    lines, digest = read_manifest(path, "# schema=1", "AUR source acquisition policy")
    policies: dict[str, SourcePolicyRow] = {}
    for line_number, parts in tsv_rows(lines, 13, "AUR source acquisition policy"):
        row = SourcePolicyRow(*parts)
        if PACKAGE_RE.fullmatch(row.package) is None or row.package in policies:
            fail(2, f"AUR source policy has an invalid/duplicate package at line {line_number}")
        if row.method not in SOURCE_METHODS or SAFE_FILE_RE.fullmatch(row.output) is None:
            fail(2, f"AUR source policy has an unsafe method/output: {row.package}")
        if HEX64_RE.fullmatch(row.output_sha256) is None or HEX64_RE.fullmatch(row.primary_sha256) is None:
            fail(2, f"AUR source policy has an invalid fixed SHA-256: {row.package}")
        if row.expected_bytes != "-" and (not row.expected_bytes.isdigit() or int(row.expected_bytes) <= 0):
            fail(2, f"AUR source policy has an invalid expected size: {row.package}")
        validate_https(row.primary_url, row.package, "primary URL")
        if urlsplit(row.primary_url).hostname != row.allowed_host:
            fail(2, f"AUR source policy primary host differs from its allowlist: {row.package}")
        if row.authorization != "aur" or TOKEN_RE.fullmatch(row.allowed_host.replace(".", "-")) is None:
            fail(2, f"AUR source policy has an invalid authorization/host: {row.package}")
        if row.method == "signed-url-download":
            validate_https(row.bootstrap_url, row.package, "bootstrap URL")
            validate_https(row.auxiliary_url, row.package, "auxiliary URL")
            if row.lock_sha256 != "-":
                fail(2, f"signed URL source unexpectedly has a lock hash: {row.package}")
        elif row.method == "cargo-vendor":
            if HEX64_RE.fullmatch(row.lock_sha256) is None or row.bootstrap_url != "-" or row.auxiliary_url != "-":
                fail(2, f"cargo-vendor source policy is incomplete: {row.package}")
        elif row.lock_sha256 != "-" or row.bootstrap_url != "-" or row.auxiliary_url != "-":
            fail(2, f"direct source policy has unexpected auxiliary fields: {row.package}")
        policies[row.package] = row

    expected = {package for package, recipe in recipes.items() if recipe.source_policy == "local-fixed"}
    if set(policies) != expected:
        missing = sorted(expected - set(policies))
        extra = sorted(set(policies) - expected)
        fail(2, f"AUR source/recipe local-fixed set mismatch (missing={missing}, extra={extra})")
    for package, policy in policies.items():
        if recipes[package].external_source != policy.output:
            fail(2, f"AUR source output differs from recipe external source: {package}")
    return policies, digest


def load_build_policy(workstation_rows: tuple[WorkstationRow, ...]) -> tuple[BuildPolicy, str, str]:
    path = PROJECT_ROOT / "manifests/aur-build-policy.tsv"
    lines, digest = read_manifest(path, "# schema=1", "AUR build policy")
    rows = tsv_rows(lines, 11, "AUR build policy")
    if len(rows) != 1:
        fail(2, "AUR build policy must contain exactly one row")
    policy = BuildPolicy(*rows[0][1])
    if policy.backend != "clean-chroot" or policy.architecture != "x86_64":
        fail(2, "AUR build policy lost the x86_64 clean-chroot boundary")
    relative = Path(policy.chroot_relative)
    if (
        relative.is_absolute()
        or ".." in relative.parts
        or SAFE_REL_RE.fullmatch(policy.chroot_relative) is None
        or policy.chroot_relative != "builds/aur/chroot"
    ):
        fail(2, "AUR build policy has an unsafe/unexpected chroot path")
    if policy.bootstrap_packages != "base-devel,rust":
        fail(2, "AUR build bootstrap package set changed")
    if policy.host_prerequisite != "devtools":
        fail(2, "AUR build host prerequisite changed")
    if policy.authorization != "aur" or policy.root_authorization != "system-changes":
        fail(2, "AUR build authorization boundaries changed")
    if policy.root_helper != "gsudo":
        fail(1, "AUR build policy permits a root helper other than audited gsudo")
    if set(policy.artifact_roots.split(",")) != {"usr", "opt", "etc"}:
        fail(2, "AUR artifact root allowlist changed")
    if policy.pacman_config != "config/templates/aur-build-pacman.conf":
        fail(2, "AUR build pacman template path changed")

    matches = [row for row in workstation_rows if row.package == policy.host_prerequisite]
    if len(matches) != 1:
        fail(2, "devtools clean-chroot prerequisite is absent or duplicated")
    devtools = matches[0]
    if (
        devtools.channel,
        devtools.repository,
        devtools.acquisition,
        devtools.module,
        devtools.restore_mode,
        devtools.policy,
        devtools.origin,
    ) != ("pacman", "extra", "pacman", "build-foundation", "package-only", "install", "confirmed-desired"):
        fail(2, "devtools prerequisite has an unexpected workstation policy")

    template_path = PROJECT_ROOT / policy.pacman_config
    template, _info = safe_regular_file(template_path, "official-only AUR pacman template")
    try:
        text = template.decode("utf-8")
    except UnicodeError as error:
        fail(2, f"AUR pacman template is not UTF-8: {error}")
    effective = "\n".join(
        line for line in text.splitlines() if line.strip() and not line.lstrip().startswith("#")
    )
    if any(section not in effective for section in ("[core]", "[extra]", "[multilib]")):
        fail(2, "AUR pacman template omits an official repository")
    if "archlinuxcn" in effective.lower() or "SigLevel = Required DatabaseOptional" not in effective:
        fail(1, "AUR pacman template lost its official-only signature policy")
    return policy, digest, hash_bytes(template)


def load_policy_bundle() -> PolicyBundle:
    workstation, aur_rows, workstation_digest = load_workstation_policy()
    recipes, recipe_digest = load_recipes(aur_rows)
    source_policies, source_digest = load_source_policies(recipes)
    build_policy, build_digest, template_digest = load_build_policy(workstation)
    return PolicyBundle(
        workstation,
        aur_rows,
        recipes,
        source_policies,
        build_policy,
        workstation_digest,
        recipe_digest,
        source_digest,
        build_digest,
        template_digest,
    )


def required_env(name: str) -> str:
    value = os.environ.get(name)
    if value is None or value == "":
        fail(2, f"required orchestrator environment is missing: {name}")
    if "\x00" in value:
        fail(2, f"orchestrator environment contains NUL: {name}")
    return value


def parse_modules(raw: str, label: str) -> tuple[str, ...]:
    if raw == "none":
        return ()
    values = tuple(raw.split(","))
    if not values or any(TOKEN_RE.fullmatch(value) is None for value in values):
        fail(2, f"{label} is malformed")
    if len(values) != len(set(values)):
        fail(2, f"{label} contains a duplicate module")
    return values


def parse_effects(raw: str) -> tuple[dict[str, str], ...]:
    if len(raw.encode("utf-8")) > MAX_EFFECTS_JSON:
        fail(2, "FULL_ORCHESTRATOR_EFFECTS_JSON exceeds the safety limit")
    try:
        value: Any = json.loads(raw)
    except json.JSONDecodeError as error:
        fail(2, f"FULL_ORCHESTRATOR_EFFECTS_JSON is malformed: {error}")
    if not isinstance(value, list):
        fail(2, "FULL_ORCHESTRATOR_EFFECTS_JSON is not an array")
    effects: list[dict[str, str]] = []
    for index, item in enumerate(value):
        if not isinstance(item, dict) or set(item) != {"detail", "id", "module"}:
            fail(2, f"orchestrator effect {index} has malformed fields")
        if not all(isinstance(item[key], str) and item[key] and not has_control(item[key]) for key in item):
            fail(2, f"orchestrator effect {index} has an unsafe field")
        effects.append({key: item[key] for key in ("detail", "id", "module")})
    return tuple(effects)


def load_context(bundle: PolicyBundle) -> StageContext:
    action = required_env("FULL_ORCHESTRATOR_ACTION")
    stage = required_env("FULL_ORCHESTRATOR_STAGE")
    profile = required_env("FULL_ORCHESTRATOR_PROFILE")
    selected_modules = parse_modules(required_env("FULL_ORCHESTRATOR_MODULES"), "FULL_ORCHESTRATOR_MODULES")
    stage_modules = parse_modules(
        required_env("FULL_ORCHESTRATOR_STAGE_MODULES"), "FULL_ORCHESTRATOR_STAGE_MODULES"
    )
    effects = parse_effects(required_env("FULL_ORCHESTRATOR_EFFECTS_JSON"))
    fingerprint = required_env("FULL_ORCHESTRATOR_PLAN_FINGERPRINT")
    run_id = required_env("FULL_ORCHESTRATOR_RUN_ID")
    attempt_raw = required_env("FULL_ORCHESTRATOR_ATTEMPT")

    if action not in {"preflight", "execute", "verify"}:
        fail(2, f"unsupported FULL_ORCHESTRATOR_ACTION: {action}")
    if stage not in {"aur-source-acquisition", "aur-build-install"}:
        fail(2, f"unsupported FULL_ORCHESTRATOR_STAGE: {stage}")
    if TOKEN_RE.fullmatch(profile) is None:
        fail(2, "FULL_ORCHESTRATOR_PROFILE is unsafe")
    if not selected_modules or not stage_modules or not set(stage_modules).issubset(selected_modules):
        fail(2, "applicable AUR stage modules are empty or not a selection subset")
    if HEX64_RE.fullmatch(fingerprint) is None:
        fail(2, "FULL_ORCHESTRATOR_PLAN_FINGERPRINT is malformed")
    if RUN_ID_RE.fullmatch(run_id) is None:
        fail(2, "FULL_ORCHESTRATOR_RUN_ID is unsafe")
    if not attempt_raw.isdigit() or int(attempt_raw) < 1:
        fail(2, "FULL_ORCHESTRATOR_ATTEMPT is malformed")

    selected_set = set(selected_modules)
    rows = tuple(row for row in bundle.aur_rows if row.module in selected_set)
    if not rows:
        fail(2, "applicable AUR stage has no workstation-policy package rows")
    effect_modules = {row.module for row in rows}
    expected_stage_modules = tuple(module for module in selected_modules if module in effect_modules)
    if stage_modules != expected_stage_modules:
        fail(2, "FULL_ORCHESTRATOR_STAGE_MODULES does not exactly reproduce selected AUR modules")
    prefix = "acquire-source:" if stage == "aur-source-acquisition" else "build-install:"
    expected_effects = tuple(row.effect(prefix) for row in rows)
    if effects != expected_effects:
        fail(2, "FULL_ORCHESTRATOR_EFFECTS_JSON does not exactly reproduce sorted selected AUR policy rows")

    recipes = tuple(bundle.recipes[row.package] for row in rows)
    local_sources = tuple(bundle.source_policies[row.package] for row in rows if row.package in bundle.source_policies)
    return StageContext(
        action,
        stage,
        profile,
        selected_modules,
        stage_modules,
        effects,
        fingerprint,
        run_id,
        int(attempt_raw),
        rows,
        recipes,
        local_sources,
    )


def parse_base_path(name: str, default: Path, home: Path) -> Path:
    raw = os.environ.get(name)
    if raw is not None and (not raw or has_control(raw)):
        fail(2, f"{name} is empty or contains control characters")
    value = Path(raw) if raw else default
    if not value.is_absolute() or ".." in value.parts:
        fail(2, f"{name} must be a lexical absolute path without '..'")
    result = lexical_absolute(value)
    if result == Path("/") or result == home:
        fail(1, f"{name} is too broad for private AUR state")
    validate_path_components(result, name)
    return result


def load_runtime_paths(bundle: PolicyBundle) -> RuntimePaths:
    home_raw = required_env("HOME")
    if has_control(home_raw):
        fail(2, "HOME contains control characters")
    home_input = Path(home_raw)
    if not home_input.is_absolute() or ".." in home_input.parts:
        fail(2, "HOME must be a lexical absolute path without '..'")
    home = lexical_absolute(home_input)
    safe_directory(home, "HOME")
    cache_base = parse_base_path("XDG_CACHE_HOME", home / ".cache", home)
    state_base = parse_base_path("XDG_STATE_HOME", home / ".local/state", home)
    source_cache = cache_base / SOURCE_CACHE_DIRECTORY
    state_root = state_base / STATE_DIRECTORY
    build_root = state_root / "builds/aur"
    chroot = state_root / bundle.build_policy.chroot_relative
    if chroot != build_root / "chroot":
        fail(2, "AUR build policy chroot does not remain inside the fixed build root")
    if source_cache == state_root or source_cache.is_relative_to(state_root) or state_root.is_relative_to(source_cache):
        fail(1, "AUR source cache and state roots overlap")
    return RuntimePaths(
        home,
        cache_base,
        state_base,
        source_cache,
        state_root,
        build_root,
        state_root / PROVENANCE_NAME,
        state_root / INSTALL_STATE_NAME,
        chroot,
        home / "scripts/desktop/gsudo",
        home / "scripts/desktop/fuzzel-askpass",
    )


def tool_paths() -> ToolPaths:
    return ToolPaths(
        PROJECT_ROOT / "installer/aur-plan.py",
        PROJECT_ROOT / "installer/aur-source-acquire.py",
        PROJECT_ROOT / "installer/aur-build.py",
        PROJECT_ROOT / "installer/aur-install.py",
    )


def inspect_installed_privilege_payloads(paths: RuntimePaths, *, allow_both_absent: bool) -> str:
    entries = (
        (paths.gsudo, "installed audited gsudo wrapper", AUDITED_GSUDO_SHA256),
        (paths.askpass, "installed audited fuzzel-askpass helper", AUDITED_ASKPASS_SHA256),
    )
    inspect_creation_boundary(paths.gsudo.parent, "privilege-wrapper target directory")
    missing: list[str] = []
    for path, label, _digest in entries:
        validate_path_components(path, label)
        try:
            info = path.lstat()
        except FileNotFoundError:
            missing.append(label)
            continue
        except OSError as error:
            fail(2, f"could not inspect {label} {path}: {error}")
        if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
            fail(1, f"{label} is not a safe regular file: {path}")

    if missing:
        if len(missing) != len(entries):
            fail(1, "installed privilege wrapper/helper are only partially present")
        if not allow_both_absent:
            fail(127, "installed audited gsudo wrapper and fuzzel-askpass helper are both missing")
        return "absent"

    for path, label, digest in entries:
        safe_regular_file(
            path,
            label,
            executable=True,
            expected_sha256=digest,
            missing_status=127,
        )
    return "matching"


def audit_runtime_files(paths: RuntimePaths, *, preflight: bool) -> tuple[ToolPaths, str]:
    if os.geteuid() == 0:
        fail(1, "AUR stage adapter must run as the invoking ordinary user, not root")
    if platform.machine() != "x86_64":
        fail(1, f"unsupported architecture: {platform.machine()} (x86_64 is required)")

    # These repository payloads are the trust anchor for an earlier globally
    # preflighted privilege-wrapper stage. They must always match the fixed
    # production digests, including when HOME has not received them yet.
    payload_gsudo = PROJECT_ROOT / "config/home/scripts/desktop/gsudo"
    payload_askpass = PROJECT_ROOT / "config/home/scripts/desktop/fuzzel-askpass"
    safe_regular_file(
        payload_gsudo,
        "reviewed project gsudo payload",
        executable=True,
        expected_sha256=AUDITED_GSUDO_SHA256,
    )
    safe_regular_file(
        payload_askpass,
        "reviewed project fuzzel-askpass payload",
        executable=True,
        expected_sha256=AUDITED_ASKPASS_SHA256,
    )
    privilege_state = inspect_installed_privilege_payloads(paths, allow_both_absent=preflight)

    tools = tool_paths()
    for path, label, digest in (
        (tools.plan, "reviewed AUR source planner", AUR_PLAN_SHA256),
        (tools.source_acquire, "reviewed AUR source acquisition tool", AUR_SOURCE_ACQUIRE_SHA256),
        (tools.build, "reviewed AUR clean-chroot build tool", AUR_BUILD_SHA256),
        (tools.install, "reviewed AUR artifact install tool", AUR_INSTALL_SHA256),
    ):
        safe_regular_file(path, label, executable=True, expected_sha256=digest, missing_status=127)
    return tools, privilege_state


def check_commands(context: StageContext) -> tuple[str, ...]:
    required = set(BASE_SOURCE_COMMANDS)
    for policy in context.local_sources:
        required.update(SOURCE_METHOD_COMMANDS[policy.method])
    if context.stage == "aur-build-install":
        required.update(BASE_BUILD_COMMANDS)
    missing = tuple(sorted(command for command in required if shutil.which(command) is None))
    if missing:
        fail(127, "required base AUR tools are missing: " + ",".join(missing))

    pending: list[str] = []
    if context.stage == "aur-build-install":
        missing_devtools = [command for command in DEVTOOLS_COMMANDS if shutil.which(command) is None]
        if missing_devtools:
            devtools_selected = "build-foundation" in context.selected_modules
            if context.action == "preflight" and devtools_selected:
                pending.extend(missing_devtools)
            else:
                fail(127, "required post-official devtools commands are missing: " + ",".join(missing_devtools))
    return tuple(pending)


def nearest_existing(path: Path) -> Path:
    current = path
    while True:
        try:
            current.lstat()
        except FileNotFoundError:
            if current == current.parent:
                return current
            current = current.parent
            continue
        except OSError as error:
            fail(2, f"could not inspect creation ancestor {current}: {error}")
        return current


def inspect_creation_boundary(path: Path, label: str) -> None:
    validate_path_components(path, label)
    ancestor = nearest_existing(path)
    try:
        info = ancestor.lstat()
    except OSError as error:
        fail(2, f"could not inspect nearest existing {label} ancestor {ancestor}: {error}")
    if not stat.S_ISDIR(info.st_mode):
        fail(1, f"nearest existing {label} ancestor is not a directory: {ancestor}")
    if info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) & 0o022:
        fail(1, f"nearest existing {label} ancestor is not a private user-controlled boundary: {ancestor}")


def inspect_private_base(path: Path, label: str) -> None:
    validate_path_components(path, label)
    try:
        info = path.lstat()
    except FileNotFoundError:
        inspect_creation_boundary(path, label)
        return
    except OSError as error:
        fail(2, f"could not inspect {label} {path}: {error}")
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
        fail(1, f"{label} conflicts with a non-directory/symlink: {path}")
    if info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) & 0o022:
        fail(1, f"{label} is not a user-controlled non-writable boundary: {path}")


def optional_private_directory(path: Path, label: str) -> bool:
    inspect_creation_boundary(path, label)
    try:
        info = path.lstat()
    except FileNotFoundError:
        return False
    except OSError as error:
        fail(2, f"could not inspect {label} {path}: {error}")
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
        fail(1, f"{label} conflicts with a non-directory/symlink: {path}")
    if info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) != 0o700:
        fail(1, f"{label} must be current-user-owned mode 700: {path}")
    return True


def ensure_private_directory(path: Path, label: str) -> None:
    path = lexical_absolute(path)
    inspect_creation_boundary(path, label)
    missing: list[Path] = []
    current = path
    while True:
        try:
            current.lstat()
        except FileNotFoundError:
            missing.append(current)
            if current == current.parent:
                fail(1, f"cannot establish private {label} below a missing filesystem root")
            current = current.parent
            continue
        except OSError as error:
            fail(2, f"could not inspect {label} ancestor {current}: {error}")
        break
    for directory in reversed(missing):
        try:
            os.mkdir(directory, 0o700)
        except FileExistsError:
            pass
        except OSError as error:
            fail(1, f"could not create private {label} directory {directory}: {error}")
        try:
            os.chmod(directory, 0o700, follow_symlinks=False)
        except OSError as error:
            fail(1, f"could not secure private {label} directory {directory}: {error}")
    safe_directory(path, label, private=True)


def inspect_sources(
    context: StageContext,
    paths: RuntimePaths,
    *,
    require_complete: bool,
) -> tuple[str, ...]:
    root_exists = optional_private_directory(paths.source_cache, "AUR source cache root")
    pending: list[str] = []
    for policy in context.local_sources:
        package_dir = paths.source_cache / policy.package
        target = package_dir / policy.output
        if not root_exists:
            pending.append(policy.package)
            continue
        directory_exists = optional_private_directory(package_dir, f"AUR source cache package {policy.package}")
        if not directory_exists:
            pending.append(policy.package)
            continue
        try:
            entries = tuple(package_dir.iterdir())
        except OSError as error:
            fail(2, f"could not list source cache package directory for {policy.package}: {error}")
        unexpected = sorted(entry.name for entry in entries if entry.name != policy.output)
        if unexpected:
            fail(1, f"{policy.package}: source cache contains conflicting entries: {unexpected}")
        try:
            info = safe_regular_info(target, f"fixed source cache file for {policy.package}", private=True)
        except AdapterFailure as error:
            if error.status in {1, 2} and " is missing:" in error.message:
                pending.append(policy.package)
                continue
            raise
        try:
            actual = hash_file(target)
        except OSError as error:
            fail(2, f"{policy.package}: fixed source cache hash query failed: {error}")
        if actual != policy.output_sha256:
            fail(1, f"{policy.package}: fixed source cache SHA-256 mismatch")
        if policy.expected_bytes != "-" and info.st_size != int(policy.expected_bytes):
            fail(1, f"{policy.package}: fixed source cache size mismatch")
    if require_complete and pending:
        fail(1, "required fixed local AUR sources are missing: " + ",".join(pending))
    return tuple(pending)


def inspect_chroot(paths: RuntimePaths) -> str:
    validate_path_components(paths.chroot, "AUR clean chroot")
    try:
        info = paths.chroot.lstat()
    except FileNotFoundError:
        # The unprivileged private build root is the creation boundary before
        # mkarchroot creates its deliberately root-owned chroot subtree.
        inspect_creation_boundary(paths.chroot, "AUR clean chroot")
        return "absent"
    except OSError as error:
        fail(2, f"could not inspect AUR clean chroot: {error}")
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
        fail(1, "AUR clean chroot conflicts with a non-directory/symlink")
    if info.st_uid not in {0, os.geteuid()} or stat.S_IMODE(info.st_mode) & 0o022:
        fail(1, "AUR clean chroot has unsafe ownership/mode")
    root = paths.chroot / "root"
    try:
        root_info = root.lstat()
    except FileNotFoundError:
        fail(1, "AUR clean chroot is incomplete: root is missing")
    except OSError as error:
        fail(2, f"could not inspect AUR clean chroot root: {error}")
    if stat.S_ISLNK(root_info.st_mode) or not stat.S_ISDIR(root_info.st_mode):
        fail(1, "AUR clean chroot root is unsafe")
    if root_info.st_uid not in {0, os.geteuid()} or stat.S_IMODE(root_info.st_mode) & 0o022:
        fail(1, "AUR clean chroot root has unsafe ownership/mode")
    for relative in (Path(".arch-chroot"), Path("usr/bin/pacman"), Path("usr/bin/rustc")):
        marker = root / relative
        try:
            marker_info = marker.lstat()
        except FileNotFoundError:
            fail(1, f"AUR clean chroot is incomplete: {relative} is missing")
        except OSError as error:
            fail(2, f"could not inspect AUR clean chroot marker {relative}: {error}")
        if stat.S_ISLNK(marker_info.st_mode) or not stat.S_ISREG(marker_info.st_mode):
            fail(1, f"AUR clean chroot marker is unsafe: {relative}")
    return "ready"


def inspect_artifact(recipe: RecipeRow, paths: RuntimePaths) -> ArtifactRecord | None:
    package_dir = paths.build_root / "artifacts" / recipe.package
    directory = package_dir / recipe.tree_sha256
    package_exists = optional_private_directory(package_dir, f"artifact package directory for {recipe.package}")
    if not package_exists:
        return None
    try:
        package_entries = tuple(package_dir.iterdir())
    except OSError as error:
        fail(2, f"could not list artifact package directory for {recipe.package}: {error}")
    unexpected_trees = sorted(entry.name for entry in package_entries if entry.name != recipe.tree_sha256)
    if unexpected_trees:
        fail(1, f"{recipe.package}: artifact package directory has conflicting recipe trees: {unexpected_trees}")
    if not optional_private_directory(directory, f"artifact directory for {recipe.package}"):
        return None
    state_path = directory / "artifact.json"
    state_data, _state_info = safe_regular_file(
        state_path, f"artifact metadata for {recipe.package}", private=True
    )
    try:
        metadata = json.loads(state_data)
    except (UnicodeError, json.JSONDecodeError) as error:
        fail(1, f"{recipe.package}: artifact metadata is malformed: {error}")
    if not isinstance(metadata, dict):
        fail(1, f"{recipe.package}: artifact metadata is not an object")
    expected_identity = {
        "package": recipe.package,
        "pkgbase": recipe.pkgbase,
        "version": recipe.version,
        "arch": "x86_64",
    }
    if any(metadata.get(key) != value for key, value in expected_identity.items()):
        fail(1, f"{recipe.package}: artifact metadata identity mismatch")
    filename = metadata.get("filename")
    expected_hash = metadata.get("sha256")
    if (
        not isinstance(filename, str)
        or Path(filename).name != filename
        or SAFE_FILE_RE.fullmatch(filename) is None
        or ".pkg.tar" not in filename
        or not isinstance(expected_hash, str)
        or HEX64_RE.fullmatch(expected_hash) is None
    ):
        fail(1, f"{recipe.package}: artifact metadata filename/hash is invalid")
    artifact = directory / filename
    artifact_info = safe_regular_info(
        artifact, f"verified artifact for {recipe.package}", private=True
    )
    try:
        actual_hash = hash_file(artifact)
    except OSError as error:
        fail(2, f"{recipe.package}: artifact hash query failed: {error}")
    if actual_hash != expected_hash:
        fail(1, f"{recipe.package}: artifact SHA-256 mismatch")
    if isinstance(metadata.get("bytes"), int) and metadata["bytes"] != artifact_info.st_size:
        fail(1, f"{recipe.package}: artifact byte count mismatch")
    try:
        entries = tuple(directory.iterdir())
    except OSError as error:
        fail(2, f"could not list artifact directory for {recipe.package}: {error}")
    unexpected = sorted(entry.name for entry in entries if entry.name not in {"artifact.json", filename})
    if unexpected:
        fail(1, f"{recipe.package}: artifact directory contains conflicting entries: {unexpected}")
    return ArtifactRecord(recipe.package, artifact, expected_hash, recipe.version, recipe.tree_sha256)


def inspect_artifacts(
    context: StageContext,
    paths: RuntimePaths,
    *,
    require_all: bool,
) -> tuple[dict[str, ArtifactRecord], tuple[str, ...]]:
    build_exists = optional_private_directory(paths.build_root, "AUR build root")
    if not build_exists:
        pending = context.packages
        if require_all:
            fail(1, "verified AUR build root is missing")
        return {}, pending
    artifact_root = paths.build_root / "artifacts"
    root_exists = optional_private_directory(artifact_root, "AUR artifact root")
    if not root_exists:
        pending = context.packages
        if require_all:
            fail(1, "verified AUR artifact root is missing")
        return {}, pending
    records: dict[str, ArtifactRecord] = {}
    pending: list[str] = []
    for recipe in context.recipes:
        artifact = inspect_artifact(recipe, paths)
        if artifact is None:
            pending.append(recipe.package)
        else:
            records[recipe.package] = artifact
    if require_all and pending:
        fail(1, "verified AUR artifacts are missing: " + ",".join(pending))
    return records, tuple(pending)


def inspect_private_json(path: Path, label: str) -> dict[str, Any] | None:
    validate_path_components(path, label)
    try:
        path.lstat()
    except FileNotFoundError:
        return None
    except OSError as error:
        fail(2, f"could not inspect {label}: {error}")
    data, _info = safe_regular_file(path, label, private=True)
    try:
        value = json.loads(data)
    except (UnicodeError, json.JSONDecodeError) as error:
        fail(1, f"{label} is malformed: {error}")
    if not isinstance(value, dict):
        fail(1, f"{label} is not a JSON object")
    return value


def inspect_install_state(paths: RuntimePaths) -> dict[str, Any] | None:
    value = inspect_private_json(paths.install_state, "AUR install provenance state")
    if value is None:
        return None
    if value.get("schema") != 1 or not isinstance(value.get("packages"), dict):
        fail(1, "AUR install provenance state has an unsupported schema")
    for package, record in value["packages"].items():
        if PACKAGE_RE.fullmatch(str(package)) is None or not isinstance(record, dict):
            fail(1, "AUR install provenance state contains an invalid package row")
        for field in ("artifact_sha256", "recipe_tree_sha256"):
            if HEX64_RE.fullmatch(str(record.get(field, ""))) is None:
                fail(1, f"AUR install provenance has an invalid {field} for {package}")
    return value


def expected_provenance(context: StageContext, bundle: PolicyBundle) -> dict[str, Any]:
    selection = [
        {
            "module": recipe.module,
            "package": recipe.package,
            "recipe_tree_sha256": recipe.tree_sha256,
            "role": recipe.role,
        }
        for recipe in context.recipes
    ]
    fixed_sources = [
        {
            "filename": policy.output,
            "package": policy.package,
            "sha256": policy.output_sha256,
        }
        for policy in context.local_sources
    ]
    return {
        "schema": 1,
        "kind": "aur-source-verification",
        "plan_fingerprint": context.plan_fingerprint,
        "selection": selection,
        "selection_sha256": canonical_digest(selection),
        "fixed_local_sources": fixed_sources,
        "workstation_policy_sha256": bundle.workstation_sha256,
        "recipe_policy_sha256": bundle.recipe_sha256,
        "source_policy_sha256": bundle.source_sha256,
    }


def provenance_state(
    context: StageContext,
    bundle: PolicyBundle,
    paths: RuntimePaths,
    *,
    require_exact: bool,
) -> str:
    value = inspect_private_json(paths.provenance, "AUR source provenance state")
    if value is None:
        if require_exact:
            fail(1, "exact AUR source provenance state is missing")
        return "absent"
    expected = expected_provenance(context, bundle)
    if value != expected:
        if require_exact:
            fail(1, "AUR source provenance does not exactly match the selected policy/hashes")
        return "stale"
    return "matching"


def atomic_private_json(path: Path, value: dict[str, Any]) -> None:
    ensure_private_directory(path.parent, "AUR provenance state root")
    existing = inspect_private_json(path, "AUR source provenance state")
    if existing == value:
        return
    temporary = path.with_name(f".{path.name}.tmp-{os.getpid()}")
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(temporary, flags, 0o600)
        os.fchmod(descriptor, 0o600)
        payload = canonical_bytes(value, pretty=True)
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        directory_fd = os.open(path.parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    except OSError as error:
        try:
            temporary.unlink(missing_ok=True)
        except OSError:
            pass
        fail(1, f"could not atomically write private AUR source provenance: {error}")
    safe_regular_file(path, "AUR source provenance state", private=True)


def environment() -> dict[str, str]:
    result = os.environ.copy()
    result["LC_ALL"] = "C"
    return result


def run_command(argv: Sequence[str], label: str) -> CommandResult:
    if not argv or not all(isinstance(value, str) and value and "\x00" not in value for value in argv):
        fail(2, f"internal error: unsafe argv for {label}")
    try:
        completed = subprocess.run(
            list(argv),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
            errors="replace",
            env=environment(),
            check=False,
        )
    except OSError as error:
        status = 127 if isinstance(error, FileNotFoundError) else 2
        fail(status, f"could not execute {label}: {error}")
    return CommandResult(tuple(argv), normalize_status(completed.returncode), completed.stdout, completed.stderr)


def emit_child_output(result: CommandResult, label: str, *, include_stdout: bool = False) -> None:
    if include_stdout and result.stdout:
        print(result.stdout, end="" if result.stdout.endswith("\n") else "\n")
    if result.stderr:
        print(result.stderr, end="" if result.stderr.endswith("\n") else "\n", file=sys.stderr)
    if result.status != 0:
        print(f"aur-stage-apply: {label} failed with exit {result.status}", file=sys.stderr)


def parse_json_result(result: CommandResult, label: str) -> dict[str, Any] | None:
    if not result.stdout.strip():
        if result.status == 0:
            fail(2, f"{label} succeeded empty instead of returning its JSON plan")
        return None
    try:
        value = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        if result.status == 0:
            fail(2, f"{label} returned malformed JSON with exit 0: {error}")
        return None
    if not isinstance(value, dict):
        if result.status == 0:
            fail(2, f"{label} returned a non-object JSON plan")
        return None
    return value


def report_plan_failure(result: CommandResult, document: dict[str, Any] | None, label: str) -> NoReturn:
    emit_child_output(result, label)
    if document is not None:
        overall = document.get("overall")
        if isinstance(overall, dict):
            for key in ("blockers", "unavailable_checks"):
                values = overall.get(key)
                if isinstance(values, list):
                    for item in values:
                        if isinstance(item, str):
                            print(f"aur-stage-apply: {label}: {item}", file=sys.stderr)
    fail(result.status, f"{label} did not pass")


def planner_argv(
    tools: ToolPaths,
    context: StageContext,
    paths: RuntimePaths,
    *,
    verify_sources: bool,
) -> list[str]:
    argv = [sys.executable, str(tools.plan)]
    if verify_sources:
        argv.append("--verify-sources")
    argv.extend(
        (
            "--packages",
            ",".join(context.packages),
            "--source-cache",
            str(paths.source_cache),
            "--project-root",
            str(PROJECT_ROOT),
            "--json",
        )
    )
    return argv


def validate_plan_identity(context: StageContext, document: dict[str, Any], label: str) -> list[dict[str, Any]]:
    if document.get("schema") != 1:
        fail(2, f"{label} returned an unsupported schema")
    selection = document.get("selection")
    if not isinstance(selection, dict) or selection.get("packages") != list(context.packages):
        fail(2, f"{label} did not report the exact sorted selected package set")
    reports = document.get("recipes")
    if not isinstance(reports, list) or len(reports) != len(context.recipes):
        fail(2, f"{label} did not return one recipe record per selected package")
    for recipe, report in zip(context.recipes, reports, strict=True):
        if not isinstance(report, dict):
            fail(2, f"{label} returned a malformed recipe record")
        expected = {
            "package": recipe.package,
            "pkgbase": recipe.pkgbase,
            "role": recipe.role,
            "module": recipe.module,
            "pkgver": recipe.pkgver,
            "pkgrel": recipe.pkgrel,
            "recipe_tree_sha256": recipe.tree_sha256,
            "actual_recipe_tree_sha256": recipe.tree_sha256,
        }
        if any(report.get(key) != value for key, value in expected.items()):
            fail(1, f"{label} recipe identity/tree mismatch for {recipe.package}")
    return reports


def run_static_source_plan(
    tools: ToolPaths,
    context: StageContext,
    paths: RuntimePaths,
    pending_sources: tuple[str, ...],
) -> None:
    result = run_command(planner_argv(tools, context, paths, verify_sources=False), "static AUR recipe/cache plan")
    document = parse_json_result(result, "static AUR recipe/cache plan")
    if document is None:
        report_plan_failure(result, None, "static AUR recipe/cache plan")
    reports = validate_plan_identity(context, document, "static AUR recipe/cache plan")
    expected_blockers = {
        f"{policy.package}: required fixed local source is missing: {policy.output}"
        for policy in context.local_sources
        if policy.package in set(pending_sources)
    }
    observed_blockers: list[str] = []
    observed_unavailable: list[str] = []
    for report in reports:
        blockers = report.get("blockers")
        unavailable = report.get("unavailable_checks")
        if not isinstance(blockers, list) or not all(isinstance(item, str) for item in blockers):
            fail(2, "static AUR plan has malformed recipe blockers")
        if not isinstance(unavailable, list) or not all(isinstance(item, str) for item in unavailable):
            fail(2, "static AUR plan has malformed unavailable checks")
        observed_blockers.extend(blockers)
        observed_unavailable.extend(unavailable)
        package = str(report.get("package"))
        if package in pending_sources:
            if report.get("status") != "blocked":
                fail(2, f"static AUR plan did not classify pending source for {package} as blocked")
        elif report.get("status") not in {"ready", "static-ready"}:
            fail(1, f"static AUR plan did not validate recipe/cache state for {package}")
    overall = document.get("overall")
    if not isinstance(overall, dict):
        fail(2, "static AUR plan omitted overall status")
    overall_unavailable = overall.get("unavailable_checks")
    overall_blockers = overall.get("blockers")
    if not isinstance(overall_unavailable, list) or not isinstance(overall_blockers, list):
        fail(2, "static AUR plan has malformed overall findings")
    if observed_unavailable or overall_unavailable:
        if result.status != 0:
            report_plan_failure(result, document, "static AUR recipe/cache plan")
        fail(2, "static AUR plan reported unavailable checks despite exit 0")
    if set(observed_blockers) != expected_blockers or set(overall_blockers) != expected_blockers:
        if result.status != 0:
            report_plan_failure(result, document, "static AUR recipe/cache plan")
        fail(1, "static AUR plan reported a blocker other than an expected-pending fixed source")
    expected_status = 1 if expected_blockers else 0
    expected_overall = "blocked" if expected_blockers else {"ready", "static-ready"}
    if expected_blockers:
        overall_consistent = overall.get("status") == expected_overall and overall.get("exit_code") == 1
    else:
        overall_consistent = overall.get("status") in expected_overall and overall.get("exit_code") == 0
    if result.status != expected_status or not overall_consistent:
        if result.status != 0:
            report_plan_failure(result, document, "static AUR recipe/cache plan")
        fail(2, "static AUR plan exit/status is inconsistent with its findings")


def run_dynamic_source_plan(tools: ToolPaths, context: StageContext, paths: RuntimePaths) -> None:
    result = run_command(planner_argv(tools, context, paths, verify_sources=True), "dynamic AUR source verification")
    document = parse_json_result(result, "dynamic AUR source verification")
    if result.status != 0:
        report_plan_failure(result, document, "dynamic AUR source verification")
    if document is None:
        fail(2, "dynamic AUR source verification omitted JSON")
    reports = validate_plan_identity(context, document, "dynamic AUR source verification")
    for report in reports:
        if report.get("status") != "ready" or report.get("blockers") != [] or report.get("unavailable_checks") != []:
            fail(1, f"dynamic source verification did not pass for {report.get('package')}")
        sources = report.get("sources")
        verification = report.get("source_verification")
        if (
            not isinstance(sources, list)
            or not all(isinstance(item, dict) and item.get("kind") in {"local", "remote"} for item in sources)
            or not isinstance(verification, dict)
        ):
            fail(2, "dynamic source verification returned malformed source records")
        if any(item.get("kind") == "local" and item.get("state") != "verified" for item in sources):
            fail(1, f"local source verification did not pass for {report.get('package')}")
        has_remote = any(item.get("kind") == "remote" for item in sources)
        if has_remote:
            if verification.get("status") != "verified" or any(
                not isinstance(item, dict)
                or (item.get("kind") == "remote" and item.get("state") != "verified-by-makepkg")
                for item in sources
            ):
                fail(1, f"remote source verification did not pass for {report.get('package')}")
        elif verification.get("status") not in {"not-requested", "verified"}:
            fail(1, f"local-only source verification is inconsistent for {report.get('package')}")
    overall = document.get("overall")
    if (
        not isinstance(overall, dict)
        or overall.get("status") != "ready"
        or overall.get("blockers") != []
        or overall.get("unavailable_checks") != []
        or overall.get("source_verification_required") != []
    ):
        fail(1, "dynamic AUR source plan did not verify the entire selected set")


def inspect_runtime(
    context: StageContext,
    bundle: PolicyBundle,
    paths: RuntimePaths,
    *,
    require_sources: bool,
    require_artifacts: bool,
    require_provenance: bool,
) -> tuple[ToolPaths, tuple[str, ...], tuple[str, ...], str, str, tuple[str, ...], str]:
    tools, privilege_state = audit_runtime_files(paths, preflight=context.action == "preflight")
    pending_devtools = check_commands(context)
    inspect_private_base(paths.cache_base, "XDG cache base")
    inspect_private_base(paths.state_base, "XDG state base")
    optional_private_directory(paths.state_root, "AUR private state root")
    pending_sources = inspect_sources(context, paths, require_complete=require_sources)
    _artifacts, pending_artifacts = inspect_artifacts(context, paths, require_all=require_artifacts)
    chroot = inspect_chroot(paths)
    source_state = provenance_state(context, bundle, paths, require_exact=require_provenance)
    inspect_install_state(paths)
    return (
        tools,
        pending_sources,
        pending_artifacts,
        chroot,
        source_state,
        pending_devtools,
        privilege_state,
    )


def revalidate_bundle(original: PolicyBundle, context: StageContext) -> PolicyBundle:
    current = load_policy_bundle()
    if (
        current.workstation_sha256 != original.workstation_sha256
        or current.recipe_sha256 != original.recipe_sha256
        or current.source_sha256 != original.source_sha256
        or current.build_sha256 != original.build_sha256
        or current.template_sha256 != original.template_sha256
    ):
        fail(1, "AUR policy/template inputs changed during stage execution")
    current_context = load_context(current)
    if current_context.rows != context.rows or current_context.recipes != context.recipes:
        fail(1, "selected AUR policy identity changed during stage execution")
    return current


def source_acquire_argv(
    tools: ToolPaths,
    context: StageContext,
    paths: RuntimePaths,
) -> list[str]:
    return [
        sys.executable,
        str(tools.source_acquire),
        "--apply",
        "--confirm-aur",
        "--packages",
        ",".join(policy.package for policy in context.local_sources),
        "--cache-root",
        str(paths.source_cache),
        "--project-root",
        str(PROJECT_ROOT),
    ]


def execute_source(
    context: StageContext,
    bundle: PolicyBundle,
    paths: RuntimePaths,
    tools: ToolPaths,
) -> int:
    ensure_private_directory(paths.state_root, "AUR private state root")
    tools, _privilege_state = audit_runtime_files(paths, preflight=False)
    if context.local_sources:
        ensure_private_directory(paths.source_cache, "AUR source cache root")
        result = run_command(source_acquire_argv(tools, context, paths), "fixed local AUR source acquisition")
        emit_child_output(result, "fixed local AUR source acquisition", include_stdout=True)
        if result.status != 0:
            return result.status
    inspect_sources(context, paths, require_complete=True)
    tools, _privilege_state = audit_runtime_files(paths, preflight=False)
    run_dynamic_source_plan(tools, context, paths)
    current = revalidate_bundle(bundle, context)
    atomic_private_json(paths.provenance, expected_provenance(context, current))
    print(
        f"aur-stage-apply: source acquisition/verification passed for {len(context.packages)} exact package(s)"
    )
    return 0


def build_argv(tools: ToolPaths, context: StageContext, paths: RuntimePaths, *, plan: bool) -> list[str]:
    argv = [sys.executable, str(tools.build)]
    if plan:
        argv.extend(("--plan", "--post-official"))
    else:
        argv.extend(("--build", "--post-official", "--confirm-aur", "--confirm-system-changes"))
    argv.extend(
        (
            "--packages",
            ",".join(context.packages),
            "--source-cache",
            str(paths.source_cache),
            "--build-root",
            str(paths.build_root),
            "--state-root",
            str(paths.state_root),
            "--project-root",
            str(PROJECT_ROOT),
        )
    )
    if plan:
        argv.append("--json")
    return argv


def install_argv(tools: ToolPaths, context: StageContext, paths: RuntimePaths, *, plan: bool) -> list[str]:
    argv = [sys.executable, str(tools.install)]
    if plan:
        argv.append("--plan")
    else:
        argv.extend(("--install", "--confirm-aur", "--confirm-system-changes"))
    argv.extend(
        (
            "--packages",
            ",".join(context.packages),
            "--build-root",
            str(paths.build_root),
            "--state-root",
            str(paths.state_root),
            "--project-root",
            str(PROJECT_ROOT),
        )
    )
    if plan:
        argv.append("--json")
    return argv


def execute_build_install(
    context: StageContext,
    bundle: PolicyBundle,
    paths: RuntimePaths,
    tools: ToolPaths,
) -> int:
    provenance_state(context, bundle, paths, require_exact=True)
    ensure_private_directory(paths.state_root, "AUR private state root")
    ensure_private_directory(paths.build_root, "AUR build root")
    ensure_private_directory(paths.build_root / "artifacts", "AUR artifact root")
    for recipe in context.recipes:
        ensure_private_directory(
            paths.build_root / "artifacts" / recipe.package,
            f"artifact package directory for {recipe.package}",
        )

    tools, _privilege_state = audit_runtime_files(paths, preflight=False)
    build_result = run_command(build_argv(tools, context, paths, plan=False), "clean-chroot AUR build")
    emit_child_output(build_result, "clean-chroot AUR build", include_stdout=True)
    if build_result.status != 0:
        return build_result.status

    revalidate_bundle(bundle, context)
    inspect_chroot(paths)
    inspect_artifacts(context, paths, require_all=True)
    tools, _privilege_state = audit_runtime_files(paths, preflight=False)
    install_result = run_command(install_argv(tools, context, paths, plan=False), "verified AUR artifact install")
    emit_child_output(install_result, "verified AUR artifact install", include_stdout=True)
    if install_result.status != 0:
        return install_result.status
    inspect_install_state(paths)
    return 0


def validate_build_plan(
    context: StageContext,
    paths: RuntimePaths,
    result: CommandResult,
    document: dict[str, Any] | None,
    artifacts: dict[str, ArtifactRecord],
) -> None:
    if result.status != 0:
        report_plan_failure(result, document, "AUR artifact build plan")
    if document is None:
        fail(2, "AUR artifact build plan omitted JSON")
    if document.get("schema") != 1:
        fail(2, "AUR artifact build plan has an unsupported schema")
    selection = document.get("selection")
    if not isinstance(selection, dict) or selection.get("packages") != list(context.packages):
        fail(2, "AUR artifact build plan did not report the exact package set")
    policy = document.get("policy")
    if not isinstance(policy, dict) or policy.get("backend") != "clean-chroot" or policy.get("root_helper") != "gsudo":
        fail(1, "AUR artifact build plan lost its clean-chroot/gsudo policy")
    reports = document.get("packages")
    if not isinstance(reports, list) or len(reports) != len(context.recipes):
        fail(2, "AUR artifact build plan has a malformed package set")
    for recipe, report in zip(context.recipes, reports, strict=True):
        if not isinstance(report, dict):
            fail(2, "AUR artifact build plan has a malformed package record")
        expected = {
            "package": recipe.package,
            "pkgbase": recipe.pkgbase,
            "role": recipe.role,
            "module": recipe.module,
            "pkgver": recipe.pkgver,
            "pkgrel": recipe.pkgrel,
            "tree_sha256": recipe.tree_sha256,
        }
        if any(report.get(key) != value for key, value in expected.items()):
            fail(1, f"AUR artifact plan identity/tree mismatch for {recipe.package}")
        artifact = report.get("artifact")
        expected_artifact = artifacts[recipe.package]
        if (
            not isinstance(artifact, dict)
            or artifact.get("state") != "verified"
            or artifact.get("sha256") != expected_artifact.sha256
            or artifact.get("artifact") != str(expected_artifact.path)
        ):
            fail(1, f"AUR artifact plan did not verify {recipe.package}")
    chroot = document.get("chroot")
    if not isinstance(chroot, dict) or chroot.get("state") != "ready":
        fail(1, "AUR artifact build plan did not verify the clean chroot")
    commands = document.get("commands")
    if not isinstance(commands, list) or any(
        not isinstance(item, dict) or item.get("state") != "available" for item in commands
    ):
        fail(1, "AUR artifact build plan did not verify all build commands")
    overall = document.get("overall")
    if (
        not isinstance(overall, dict)
        or overall.get("status") != "ready"
        or overall.get("blockers") != []
        or overall.get("unavailable_checks") != []
    ):
        fail(1, "AUR artifact build plan is not fully verified")


def query_failure_diagnostic(document: dict[str, Any] | None) -> None:
    if document is None:
        return
    records = document.get("records")
    if not isinstance(records, list):
        return
    for record in records:
        if not isinstance(record, dict):
            continue
        installed = record.get("installed")
        if not isinstance(installed, dict) or installed.get("state") != "query-failed":
            continue
        query_exit = installed.get("query_exit")
        package = record.get("package", "unknown")
        reason = installed.get("reason", "installed-package query failed")
        if query_exit == 0:
            print(
                f"aur-stage-apply: {package}: installed-package query succeeded empty/malformed "
                f"(exit=0): {reason}",
                file=sys.stderr,
            )
        elif isinstance(query_exit, int):
            print(
                f"aur-stage-apply: {package}: installed-package query failed with exit {query_exit}: {reason}",
                file=sys.stderr,
            )
        else:
            print(f"aur-stage-apply: {package}: installed-package query unavailable: {reason}", file=sys.stderr)


def validate_install_plan(
    context: StageContext,
    result: CommandResult,
    document: dict[str, Any] | None,
    artifacts: dict[str, ArtifactRecord],
    install_state: dict[str, Any] | None,
) -> None:
    if result.status != 0:
        query_failure_diagnostic(document)
        report_plan_failure(result, document, "AUR install provenance plan")
    if document is None:
        fail(2, "AUR install provenance plan omitted JSON")
    if document.get("schema") != 1:
        fail(2, "AUR install provenance plan has an unsupported schema")
    selection = document.get("selection")
    if not isinstance(selection, dict) or selection.get("packages") != list(context.packages):
        fail(2, "AUR install provenance plan did not report the exact package set")
    records = document.get("records")
    if not isinstance(records, list) or len(records) != len(context.recipes):
        fail(2, "AUR install provenance plan has a malformed record set")
    if install_state is None:
        fail(1, "AUR install provenance state is missing")
    for recipe, report in zip(context.recipes, records, strict=True):
        if not isinstance(report, dict):
            fail(2, "AUR install provenance plan contains a malformed record")
        installed = report.get("installed")
        if isinstance(installed, dict) and installed.get("state") == "query-failed":
            query_failure_diagnostic({"records": [report]})
            fail(2, f"installed-package query was unavailable for {recipe.package}")
        artifact = report.get("artifact")
        expected_artifact = artifacts[recipe.package]
        if (
            report.get("package") != recipe.package
            or report.get("module") != recipe.module
            or report.get("target_version") != recipe.version
            or report.get("action") != "verified-skip"
            or not isinstance(installed, dict)
            or installed.get("state") != "installed"
            or installed.get("version") != recipe.version
            or not isinstance(artifact, dict)
            or artifact.get("sha256") != expected_artifact.sha256
            or artifact.get("recipe_tree_sha256") != recipe.tree_sha256
            or artifact.get("path") != str(expected_artifact.path)
        ):
            fail(1, f"AUR install plan is not an exact verified-skip for {recipe.package}")
        prior = install_state["packages"].get(recipe.package)
        if not isinstance(prior, dict) or (
            prior.get("version") != recipe.version
            or prior.get("artifact_sha256") != expected_artifact.sha256
            or prior.get("recipe_tree_sha256") != recipe.tree_sha256
            or prior.get("packager") != PACKAGER
        ):
            fail(1, f"AUR install provenance does not match artifact/recipe for {recipe.package}")
    if document.get("effects") != []:
        fail(1, "AUR install verification still proposes package effects")
    overall = document.get("overall")
    if (
        not isinstance(overall, dict)
        or overall.get("status") != "ready"
        or overall.get("blockers") != []
        or overall.get("unavailable_checks") != []
    ):
        fail(1, "AUR install provenance plan is not ready")


def verify_build_install(
    context: StageContext,
    bundle: PolicyBundle,
    paths: RuntimePaths,
    tools: ToolPaths,
) -> int:
    provenance_state(context, bundle, paths, require_exact=True)
    artifacts, _pending = inspect_artifacts(context, paths, require_all=True)
    tools, _privilege_state = audit_runtime_files(paths, preflight=False)
    build_result = run_command(build_argv(tools, context, paths, plan=True), "AUR artifact build plan")
    build_document = parse_json_result(build_result, "AUR artifact build plan")
    validate_build_plan(context, paths, build_result, build_document, artifacts)

    tools, _privilege_state = audit_runtime_files(paths, preflight=False)
    install_result = run_command(install_argv(tools, context, paths, plan=True), "AUR install provenance plan")
    install_document = parse_json_result(install_result, "AUR install provenance plan")
    install_state = inspect_install_state(paths)
    validate_install_plan(context, install_result, install_document, artifacts, install_state)
    print(f"aur-stage-apply: build/install verification passed for {len(context.packages)} exact package(s)")
    return 0


def preflight(
    context: StageContext,
    paths: RuntimePaths,
    tools: ToolPaths,
    pending_sources: tuple[str, ...],
    pending_artifacts: tuple[str, ...],
    chroot_state: str,
    provenance: str,
    pending_devtools: tuple[str, ...],
    privilege_state: str,
) -> int:
    run_static_source_plan(tools, context, paths, pending_sources)
    pending = []
    if pending_sources:
        pending.append(f"sources={','.join(pending_sources)}")
    if pending_artifacts:
        pending.append(f"artifacts={','.join(pending_artifacts)}")
    if chroot_state == "absent":
        pending.append("chroot=absent")
    if provenance != "matching":
        pending.append(f"source-provenance={provenance}")
    if pending_devtools:
        pending.append(f"devtools={','.join(pending_devtools)}")
    if privilege_state == "absent":
        pending.append("privilege-wrapper=absent")
    suffix = " expected-pending: " + " ".join(pending) if pending else ""
    print(f"aur-stage-apply: {context.stage} read-only preflight passed;{suffix}".rstrip(";"))
    return 0


def parser() -> argparse.ArgumentParser:
    return argparse.ArgumentParser(
        description="Execute/verify exact full-orchestrator AUR stage effects; no package CLI is supported."
    )


def main(argv: Sequence[str] | None = None) -> int:
    parser().parse_args(argv)
    try:
        bundle = load_policy_bundle()
        context = load_context(bundle)
        paths = load_runtime_paths(bundle)
        require_sources = context.action == "verify" or (
            context.stage == "aur-build-install" and context.action == "execute"
        )
        require_artifacts = context.stage == "aur-build-install" and context.action == "verify"
        require_provenance = context.action == "verify" or (
            context.stage == "aur-build-install" and context.action == "execute"
        )
        (
            tools,
            pending_sources,
            pending_artifacts,
            chroot,
            source_state,
            pending_devtools,
            privilege_state,
        ) = inspect_runtime(
            context,
            bundle,
            paths,
            require_sources=require_sources,
            require_artifacts=require_artifacts,
            require_provenance=require_provenance,
        )
        if context.action == "preflight":
            return preflight(
                context,
                paths,
                tools,
                pending_sources,
                pending_artifacts,
                chroot,
                source_state,
                pending_devtools,
                privilege_state,
            )
        if context.stage == "aur-source-acquisition":
            if context.action == "execute":
                return execute_source(context, bundle, paths, tools)
            run_static_source_plan(tools, context, paths, ())
            provenance_state(context, bundle, paths, require_exact=True)
            print(
                "aur-stage-apply: source provenance verification passed for "
                f"{len(context.packages)} exact package(s)"
            )
            return 0
        if context.action == "execute":
            return execute_build_install(context, bundle, paths, tools)
        return verify_build_install(context, bundle, paths, tools)
    except AdapterFailure as error:
        print(f"aur-stage-apply: {error.message}", file=sys.stderr)
        return error.status
    except KeyboardInterrupt:
        print("aur-stage-apply: interrupted", file=sys.stderr)
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
