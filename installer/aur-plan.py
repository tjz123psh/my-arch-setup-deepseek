#!/usr/bin/env python3
"""Validate and render the declared fixed AUR recipe/source plan without applying it."""

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
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any
from urllib.parse import urlsplit

SCHEMA = 1
PACKAGE_RE = re.compile(r"[a-z0-9@._+:-]+")
HEX40_RE = re.compile(r"[0-9a-f]{40}")
HEX64_RE = re.compile(r"[0-9a-f]{64}")
SAFE_FILE_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._+@:-]*")
SOURCE_POLICIES = {"remote-fixed", "local-fixed", "domain-blocked"}
REVIEW_STATES = {"reviewed", "precondition", "blocked"}
ROLES = {"aur-build", "paru-bootstrap"}
CHECKSUM_LENGTHS = {"sha256sums": 64, "sha512sums": 128}
MOVING_SOURCE_PATTERNS = (
    re.compile(r"/(?:refs/heads|archive)/(?:main|master)(?:[./]|$)", re.IGNORECASE),
    re.compile(r"raw\.githubusercontent\.com/[^/]+/[^/]+/(?:main|master)/", re.IGNORECASE),
    re.compile(r"/(?:latest|releases/latest)/", re.IGNORECASE),
)
NETWORK_COMMAND_PATTERNS = (
    ("curl", re.compile(r"(?m)^[^#\n]*\bcurl\b")),
    ("wget", re.compile(r"(?m)^[^#\n]*\bwget\b")),
    ("git-network", re.compile(r"(?m)^[^#\n]*\bgit\s+(?:clone|fetch|pull|submodule)\b")),
    ("cargo-network", re.compile(r"(?m)^[^#\n]*\bcargo\s+(?:fetch|update|install)\b")),
    ("node-network", re.compile(r"(?m)^[^#\n]*\b(?:npm|pnpm|yarn|bun)\s+(?:install|add|update|upgrade)\b")),
    ("python-network", re.compile(r"(?m)^[^#\n]*\b(?:pip|pip3|uv\s+pip)\s+install\b")),
    ("go-network", re.compile(r"(?m)^[^#\n]*\bgo\s+(?:get|install)\b")),
)
NETWORK_FAILURE_PATTERNS = (
    "could not resolve host",
    "failed to connect",
    "connection timed out",
    "network is unreachable",
    "the requested url returned error",
    "failure while downloading",
    "download failed",
    "curl:",
)
CHECKSUM_FAILURE_PATTERNS = (
    "did not pass the validity check",
    "one or more files did not pass",
    "integrity checks (",
)


@dataclass(frozen=True)
class RecipePolicy:
    package: str
    pkgbase: str
    role: str
    module: str
    pkgver: str
    pkgrel: str
    arch: str
    aur_commit: str
    recipe_tree_sha256: str
    source_policy: str
    external_source: str
    executes_source: str
    review_state: str
    review_note: str


@dataclass(frozen=True)
class WorkstationTarget:
    package: str
    role: str
    module: str


class PolicyError(Exception):
    pass


def project_paths(project_root: Path) -> dict[str, Path]:
    return {
        "manifest": project_root / "manifests/aur-recipes.tsv",
        "policy": project_root / "manifests/workstation-packages.tsv",
        "inventory": project_root / "manifests/workstation-package-inventory.tsv",
        "recipes": project_root / "third_party/aur",
    }


def safe_lines(path: Path, schema: str, label: str) -> list[str]:
    if not path.is_file() or path.is_symlink():
        raise PolicyError(f"{label} is missing or unsafe")
    try:
        lines = path.read_text().splitlines()
    except OSError as error:
        raise PolicyError(f"could not read {label}: {error}") from error
    if not lines or lines[0] != schema:
        raise PolicyError(f"{label} has an unsupported schema")
    return lines


def load_recipe_policy(path: Path) -> dict[str, RecipePolicy]:
    lines = safe_lines(path, "# schema=2", "AUR recipe manifest")
    records: dict[str, RecipePolicy] = {}
    for line_number, parts in enumerate(csv.reader(lines[1:], delimiter="\t"), 2):
        if not parts or not parts[0] or parts[0].startswith("#"):
            continue
        if len(parts) != 14 or not all(parts):
            raise PolicyError(f"invalid AUR recipe row at line {line_number}")
        record = RecipePolicy(*parts)
        if PACKAGE_RE.fullmatch(record.package) is None:
            raise PolicyError(f"unsafe package name at line {line_number}: {record.package}")
        if PACKAGE_RE.fullmatch(record.pkgbase) is None:
            raise PolicyError(f"unsafe package base at line {line_number}: {record.pkgbase}")
        if record.package in records:
            raise PolicyError(f"duplicate AUR recipe row: {record.package}")
        if record.role not in ROLES:
            raise PolicyError(f"invalid AUR recipe role for {record.package}: {record.role}")
        if record.arch != "x86_64":
            raise PolicyError(f"AUR recipe is not x86_64-only: {record.package}")
        if HEX40_RE.fullmatch(record.aur_commit) is None:
            raise PolicyError(f"invalid AUR commit for {record.package}")
        if HEX64_RE.fullmatch(record.recipe_tree_sha256) is None:
            raise PolicyError(f"invalid recipe tree SHA-256 for {record.package}")
        if record.source_policy not in SOURCE_POLICIES:
            raise PolicyError(f"invalid source policy for {record.package}: {record.source_policy}")
        if record.review_state not in REVIEW_STATES:
            raise PolicyError(f"invalid review state for {record.package}: {record.review_state}")
        if record.executes_source not in {"yes", "no"}:
            raise PolicyError(f"invalid executes-source value for {record.package}")
        if record.source_policy == "local-fixed":
            if SAFE_FILE_RE.fullmatch(record.external_source) is None:
                raise PolicyError(f"invalid external source filename for {record.package}")
            if record.review_state != "precondition":
                raise PolicyError(f"local fixed source must retain precondition state: {record.package}")
        elif record.external_source != "-":
            raise PolicyError(f"unexpected external source for {record.package}")
        if record.source_policy == "domain-blocked" and record.review_state != "blocked":
            raise PolicyError(f"blocked source domain lost blocked review state: {record.package}")
        if any(ord(character) < 32 for character in record.review_note):
            raise PolicyError(f"control character in review note for {record.package}")
        records[record.package] = record
    if len(records) != 13:
        raise PolicyError(f"expected 13 executable AUR/bootstrap recipe rows, found {len(records)}")
    return records


def load_workstation_targets(path: Path) -> dict[str, WorkstationTarget]:
    lines = safe_lines(path, "# schema=1", "workstation package policy")
    targets: dict[str, WorkstationTarget] = {}
    for line_number, parts in enumerate(csv.reader(lines[1:], delimiter="\t"), 2):
        if not parts or not parts[0] or parts[0].startswith("#"):
            continue
        if len(parts) != 9 or not all(parts):
            raise PolicyError(f"invalid workstation package policy row at line {line_number}")
        package, channel, repository, acquisition, module, _mode, policy, _origin, _purpose = parts
        if acquisition not in ROLES:
            continue
        if channel != "aur" or repository != "aur" or policy != "install":
            raise PolicyError(f"executable AUR target has inconsistent policy: {package}")
        if package in targets:
            raise PolicyError(f"duplicate executable AUR target: {package}")
        targets[package] = WorkstationTarget(package, acquisition, module)
    roles = {role: sum(target.role == role for target in targets.values()) for role in ROLES}
    if roles != {"aur-build": 12, "paru-bootstrap": 1}:
        raise PolicyError(f"expected 12 regular AUR targets plus one Paru bootstrap, found {roles}")
    return targets


def load_inventory_versions(path: Path) -> dict[str, str]:
    lines = safe_lines(path, "# schema=1", "workstation package inventory")
    versions: dict[str, str] = {}
    for line_number, parts in enumerate(csv.reader(lines[1:], delimiter="\t"), 2):
        if not parts or not parts[0] or parts[0].startswith("#"):
            continue
        if len(parts) != 6 or not all(parts):
            raise PolicyError(f"invalid workstation inventory row at line {line_number}")
        package, version = parts[0], parts[1]
        if package in versions:
            raise PolicyError(f"duplicate workstation inventory package: {package}")
        versions[package] = version
    return versions


def recipe_tree_hash(directory: Path) -> tuple[str, list[str]]:
    if not directory.is_dir() or directory.is_symlink():
        raise PolicyError(f"recipe directory is missing or unsafe: {directory.name}")
    entries = sorted(directory.iterdir(), key=lambda item: os.fsencode(item.name))
    digest = hashlib.sha256()
    files: list[str] = []
    for entry in entries:
        if entry.is_symlink():
            raise PolicyError(f"recipe contains a symlink: {directory.name}/{entry.name}")
        if not entry.is_file():
            raise PolicyError(f"recipe contains a non-file entry: {directory.name}/{entry.name}")
        try:
            file_stat = entry.stat()
            data = entry.read_bytes()
        except OSError as error:
            raise PolicyError(f"could not read recipe file {directory.name}/{entry.name}: {error}") from error
        if file_stat.st_size > 1024 * 1024:
            raise PolicyError(f"recipe static file exceeds 1 MiB: {directory.name}/{entry.name}")
        mode = stat.S_IMODE(file_stat.st_mode)
        file_digest = hashlib.sha256(data).hexdigest()
        digest.update(entry.name.encode())
        digest.update(b"\0")
        digest.update(f"{mode:04o}".encode())
        digest.update(b"\0")
        digest.update(file_digest.encode())
        digest.update(b"\n")
        files.append(entry.name)
    return digest.hexdigest(), files


def parse_srcinfo(path: Path) -> dict[str, list[str]]:
    if not path.is_file() or path.is_symlink():
        raise PolicyError(f"committed .SRCINFO is missing or unsafe: {path.parent.name}")
    values: dict[str, list[str]] = {}
    try:
        lines = path.read_text().splitlines()
    except OSError as error:
        raise PolicyError(f"could not read .SRCINFO for {path.parent.name}: {error}") from error
    for line_number, raw in enumerate(lines, 1):
        line = raw.strip()
        if not line:
            continue
        if " = " not in line:
            raise PolicyError(f"invalid .SRCINFO line for {path.parent.name} at {line_number}")
        key, value = line.split(" = ", 1)
        if not key or not value or any(ord(character) < 32 for character in value):
            raise PolicyError(f"invalid .SRCINFO value for {path.parent.name} at {line_number}")
        values.setdefault(key, []).append(value)
    return values


def one_value(values: dict[str, list[str]], key: str, package: str) -> str:
    found = values.get(key, [])
    if len(found) != 1:
        raise PolicyError(f"recipe {package} must declare exactly one {key}")
    return found[0]


def source_url(source: str) -> str | None:
    candidate = source.split("::", 1)[1] if "::" in source else source
    parsed = urlsplit(candidate)
    if parsed.scheme:
        return candidate
    return None


def source_filename(source: str) -> str:
    if "::" in source:
        return source.split("::", 1)[0]
    url = source_url(source)
    if url is not None:
        return Path(urlsplit(url).path).name
    return Path(source).name


def validate_remote_url(package: str, url: str) -> list[str]:
    blockers: list[str] = []
    parsed = urlsplit(url)
    if parsed.scheme != "https" or not parsed.netloc:
        blockers.append(f"{package}: source is not an HTTPS fixed download")
    if parsed.scheme.startswith(("git+", "hg+", "svn+", "bzr+")) or ".git#" in url:
        blockers.append(f"{package}: VCS sources are not permitted")
    if "$" in url or any(pattern.search(url) for pattern in MOVING_SOURCE_PATTERNS):
        blockers.append(f"{package}: source URL names a moving branch/latest target")
    return blockers


def digest_file(path: Path, algorithm: str) -> str:
    hasher = hashlib.new(algorithm)
    with path.open("rb") as handle:
        while chunk := handle.read(1024 * 1024):
            hasher.update(chunk)
    return hasher.hexdigest()


def first_symlink_component(path: Path) -> Path | None:
    if not path.is_absolute():
        raise ValueError("symlink-component inspection requires an absolute path")
    current = Path(path.anchor)
    for part in path.parts[1:]:
        current /= part
        if current.is_symlink():
            return current
    return None


def inspect_sources(
    record: RecipePolicy,
    directory: Path,
    srcinfo: dict[str, list[str]],
    source_cache: Path,
) -> tuple[list[dict[str, Any]], list[str], list[str], bool]:
    sources_report: list[dict[str, Any]] = []
    blockers: list[str] = []
    unavailable: list[str] = []
    external_seen = False
    source_groups = sorted(key for key in srcinfo if key == "source" or key == "source_x86_64")
    if not source_groups:
        blockers.append(f"{record.package}: recipe has no source declarations")
        return sources_report, blockers, unavailable, external_seen

    for group in source_groups:
        sources = srcinfo[group]
        suffix = group[len("source") :]
        candidate_keys = [f"{base}{suffix}" for base in CHECKSUM_LENGTHS if f"{base}{suffix}" in srcinfo]
        unsupported_keys = [
            key for key in srcinfo
            if key.endswith(f"sums{suffix}") and key not in candidate_keys
        ]
        if unsupported_keys:
            blockers.append(f"{record.package}: unsupported checksum field {unsupported_keys[0]}")
            continue
        if len(candidate_keys) != 1:
            blockers.append(f"{record.package}: source group {group} must use exactly one SHA-256/SHA-512 list")
            continue
        checksum_key = candidate_keys[0]
        checksums = srcinfo[checksum_key]
        if len(sources) != len(checksums):
            blockers.append(f"{record.package}: {group}/{checksum_key} count mismatch")
            continue
        algorithm = checksum_key.split("sums", 1)[0]
        expected_length = CHECKSUM_LENGTHS[checksum_key.split("_", 1)[0]]
        for source, expected in zip(sources, checksums, strict=True):
            filename = source_filename(source)
            item: dict[str, Any] = {
                "declaration": source,
                "filename": filename,
                "checksum_algorithm": algorithm,
                "expected_checksum": expected,
            }
            if expected == "SKIP" or not re.fullmatch(f"[0-9a-f]{{{expected_length}}}", expected):
                item["state"] = "invalid-checksum"
                blockers.append(f"{record.package}: source {filename} has an invalid or skipped checksum")
                sources_report.append(item)
                continue
            url = source_url(source)
            if url is not None:
                item["kind"] = "remote"
                item["state"] = "declared-unverified"
                item["url"] = url
                blockers.extend(validate_remote_url(record.package, url))
                if record.role == "paru-bootstrap" and urlsplit(url).netloc.lower().endswith("archlinuxcn.org"):
                    blockers.append(
                        f"{record.package}: Paru bootstrap source crosses into archlinuxcn instead of the declared fixed bootstrap domain"
                    )
            else:
                item["kind"] = "local"
                if Path(source).name != source or SAFE_FILE_RE.fullmatch(source) is None:
                    item["state"] = "unsafe-local-name"
                    blockers.append(f"{record.package}: local source path is not a safe basename: {source}")
                    sources_report.append(item)
                    continue
                if source == record.external_source:
                    external_seen = True
                    candidate = source_cache / record.package / source
                    item["cache_path"] = str(candidate)
                else:
                    candidate = directory / source
                    item["repository_path"] = str(candidate)
                symlink_component = first_symlink_component(candidate.absolute())
                if symlink_component is not None:
                    item["state"] = "unsafe"
                    item["unsafe_component"] = str(symlink_component)
                    blockers.append(f"{record.package}: local source path contains a symlink: {source}")
                    sources_report.append(item)
                    continue
                if not candidate.exists():
                    item["state"] = "missing"
                    blockers.append(f"{record.package}: required fixed local source is missing: {source}")
                elif candidate.is_symlink() or not candidate.is_file():
                    item["state"] = "unsafe"
                    blockers.append(f"{record.package}: local source is not a safe regular file: {source}")
                else:
                    try:
                        actual = digest_file(candidate, algorithm)
                    except OSError as error:
                        item["state"] = "query-failed"
                        item["error"] = type(error).__name__
                        unavailable.append(f"{record.package}: could not hash local source {source}")
                    else:
                        item["actual_checksum"] = actual
                        if actual != expected:
                            item["state"] = "checksum-mismatch"
                            blockers.append(f"{record.package}: local source checksum mismatch: {source}")
                        else:
                            item["state"] = "verified"
            sources_report.append(item)
    return sources_report, blockers, unavailable, external_seen


def scan_pkgbuild(package: str, path: Path) -> tuple[list[str], list[str]]:
    blockers: list[str] = []
    unavailable: list[str] = []
    if not path.is_file() or path.is_symlink():
        return [f"{package}: PKGBUILD is missing or unsafe"], unavailable
    try:
        text = path.read_text()
    except OSError as error:
        return blockers, [f"{package}: could not read PKGBUILD ({type(error).__name__})"]
    if re.search(r"(?<![A-Za-z0-9_])SKIP(?![A-Za-z0-9_])", text):
        blockers.append(f"{package}: PKGBUILD contains a skipped checksum")
    for label, pattern in NETWORK_COMMAND_PATTERNS:
        if pattern.search(text):
            blockers.append(f"{package}: PKGBUILD contains prohibited build-time network command ({label})")
    return blockers, unavailable


def run_vercmp(installed: str, proposed: str) -> tuple[int | None, dict[str, Any]]:
    command = shutil.which("vercmp")
    if command is None:
        return None, {"status": "command-missing", "query_exit": None}
    try:
        result = subprocess.run(
            [command, proposed, installed],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env={**os.environ, "LC_ALL": "C"},
            check=False,
        )
    except OSError as error:
        return None, {"status": "command-failed", "query_exit": None, "error": type(error).__name__}
    raw = result.stdout.strip()
    if result.returncode != 0 or raw not in {"-1", "0", "1"}:
        return None, {"status": "query-failed", "query_exit": result.returncode}
    return int(raw), {"status": "ok", "query_exit": result.returncode, "comparison": int(raw)}


def verify_recipe_sources(directory: Path, record: RecipePolicy, source_cache: Path) -> dict[str, Any]:
    makepkg = shutil.which("makepkg")
    if makepkg is None:
        return {"status": "unavailable", "query_exit": None, "reason": "makepkg is missing"}
    with tempfile.TemporaryDirectory(prefix=f"myarch-aur-{record.package}-") as temporary:
        temp_root = Path(temporary)
        work = temp_root / "recipe"
        shutil.copytree(directory, work)
        if record.external_source != "-":
            external = source_cache / record.package / record.external_source
            if external.is_file() and not external.is_symlink():
                shutil.copy2(external, work / record.external_source)
        home = temp_root / "home"
        source_dest = temp_root / "sources"
        home.mkdir(mode=0o700)
        source_dest.mkdir(mode=0o700)
        environment = os.environ.copy()
        environment.update({"HOME": str(home), "SRCDEST": str(source_dest), "LC_ALL": "C"})
        try:
            result = subprocess.run(
                [makepkg, "--verifysource", "--noconfirm"],
                cwd=work,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                env=environment,
                check=False,
            )
        except OSError as error:
            return {
                "status": "unavailable",
                "query_exit": None,
                "reason": f"makepkg could not execute ({type(error).__name__})",
            }
        combined = (result.stdout + "\n" + result.stderr).lower()
        if result.returncode == 0:
            return {"status": "verified", "query_exit": 0}
        if any(pattern in combined for pattern in CHECKSUM_FAILURE_PATTERNS):
            return {"status": "blocked", "query_exit": result.returncode, "reason": "source checksum verification failed"}
        if any(pattern in combined for pattern in NETWORK_FAILURE_PATTERNS):
            return {"status": "unavailable", "query_exit": result.returncode, "reason": "source download query failed"}
        return {"status": "unavailable", "query_exit": result.returncode, "reason": "makepkg source verification failed"}


def parse_selection(value: str | None, known: set[str]) -> list[str]:
    if value is None or value == "all":
        return sorted(known)
    selected: list[str] = []
    seen: set[str] = set()
    for package in value.split(","):
        if not package:
            raise PolicyError("empty package in --packages")
        if package in seen:
            raise PolicyError(f"duplicate package in --packages: {package}")
        if package not in known:
            raise PolicyError(f"undeclared package in --packages: {package}")
        seen.add(package)
        selected.append(package)
    return selected


def build_plan(
    project_root: Path,
    source_cache: Path,
    selected_names: list[str],
    verify_sources: bool,
) -> dict[str, Any]:
    paths = project_paths(project_root)
    records = load_recipe_policy(paths["manifest"])
    targets = load_workstation_targets(paths["policy"])
    inventory = load_inventory_versions(paths["inventory"])
    if set(records) != set(targets):
        missing = sorted(set(targets) - set(records))
        extra = sorted(set(records) - set(targets))
        raise PolicyError(f"AUR recipe/policy set mismatch (missing={missing}, extra={extra})")
    recipe_directories = {
        item.name for item in paths["recipes"].iterdir()
        if item.is_dir() and not item.is_symlink()
    } if paths["recipes"].is_dir() and not paths["recipes"].is_symlink() else set()
    if recipe_directories != set(records):
        missing = sorted(set(records) - recipe_directories)
        extra = sorted(recipe_directories - set(records))
        raise PolicyError(f"AUR recipe directory set mismatch (missing={missing}, extra={extra})")

    recipes_report: list[dict[str, Any]] = []
    all_blockers: list[str] = []
    all_unavailable: list[str] = []
    for package in selected_names:
        record = records[package]
        target = targets[package]
        package_blockers: list[str] = []
        package_unavailable: list[str] = []
        directory = paths["recipes"] / package
        if record.role != target.role or record.module != target.module:
            package_blockers.append(f"{package}: recipe role/module differs from workstation policy")
        if package not in inventory:
            package_blockers.append(f"{package}: package is absent from the observed inventory")
            observed_version = None
            comparison_report = {"status": "not-run", "query_exit": None}
        else:
            observed_version = inventory[package]
            comparison, comparison_report = run_vercmp(observed_version, f"{record.pkgver}-{record.pkgrel}")
            if comparison is None:
                package_unavailable.append(f"{package}: version comparison query unavailable")
            elif comparison < 0:
                package_blockers.append(
                    f"{package}: fixed recipe {record.pkgver}-{record.pkgrel} regresses observed {observed_version}"
                )

        try:
            tree_hash, tree_files = recipe_tree_hash(directory)
        except PolicyError as error:
            package_blockers.append(str(error))
            tree_hash, tree_files = None, []
        else:
            if tree_hash != record.recipe_tree_sha256:
                package_blockers.append(f"{package}: recipe tree SHA-256 differs from the reviewed manifest")

        try:
            commit = (directory / "AUR_COMMIT").read_text().strip()
        except OSError as error:
            commit = None
            package_unavailable.append(f"{package}: could not read AUR_COMMIT ({type(error).__name__})")
        else:
            if commit != record.aur_commit or HEX40_RE.fullmatch(commit) is None:
                package_blockers.append(f"{package}: AUR_COMMIT differs from the reviewed manifest")

        try:
            srcinfo = parse_srcinfo(directory / ".SRCINFO")
        except PolicyError as error:
            srcinfo = {}
            package_blockers.append(str(error))
            source_report: list[dict[str, Any]] = []
            external_seen = False
        else:
            for key, expected in (
                ("pkgbase", record.pkgbase),
                ("pkgname", package),
                ("pkgver", record.pkgver),
                ("pkgrel", record.pkgrel),
            ):
                try:
                    actual = one_value(srcinfo, key, package)
                except PolicyError as error:
                    package_blockers.append(str(error))
                else:
                    if actual != expected:
                        package_blockers.append(f"{package}: .SRCINFO {key} differs from reviewed manifest")
            arches = srcinfo.get("arch", [])
            if arches != ["x86_64"]:
                package_blockers.append(f"{package}: .SRCINFO is not exactly x86_64-only")
            source_report, source_blockers, source_unavailable, external_seen = inspect_sources(
                record, directory, srcinfo, source_cache
            )
            package_blockers.extend(source_blockers)
            package_unavailable.extend(source_unavailable)
        if record.external_source != "-" and not external_seen:
            package_blockers.append(f"{package}: declared external source is absent from .SRCINFO")
        if record.review_state == "blocked":
            package_blockers.append(f"{package}: recipe review state is blocked — {record.review_note}")
        pkgbuild_blockers, pkgbuild_unavailable = scan_pkgbuild(package, directory / "PKGBUILD")
        package_blockers.extend(pkgbuild_blockers)
        package_unavailable.extend(pkgbuild_unavailable)

        has_remote_sources = any(item.get("kind") == "remote" for item in source_report)
        if verify_sources and not package_blockers and not package_unavailable:
            verification = verify_recipe_sources(directory, record, source_cache)
            if verification["status"] == "blocked":
                package_blockers.append(f"{package}: {verification['reason']}")
            elif verification["status"] == "unavailable":
                package_unavailable.append(f"{package}: {verification['reason']}")
            elif verification["status"] == "verified":
                for source_item in source_report:
                    if source_item.get("kind") == "remote":
                        source_item["state"] = "verified-by-makepkg"
        elif has_remote_sources and not verify_sources:
            verification = {"status": "not-run", "query_exit": None, "required_for_apply": True}
        else:
            verification = {"status": "not-requested", "query_exit": None}

        if package_unavailable:
            status = "unavailable"
        elif package_blockers:
            status = "blocked"
        elif has_remote_sources and not verify_sources:
            status = "static-ready"
        else:
            status = "ready"
        all_blockers.extend(package_blockers)
        all_unavailable.extend(package_unavailable)
        recipes_report.append(
            {
                **asdict(record),
                "observed_version": observed_version,
                "version_comparison": comparison_report,
                "actual_recipe_tree_sha256": tree_hash,
                "recipe_files": tree_files,
                "sources": source_report,
                "source_verification": verification,
                "status": status,
                "blockers": package_blockers,
                "unavailable_checks": package_unavailable,
            }
        )

    static_ready = [item["package"] for item in recipes_report if item["status"] == "static-ready"]
    if all_unavailable:
        overall_status = "unavailable"
        exit_code = 2
    elif all_blockers:
        overall_status = "blocked"
        exit_code = 1
    elif static_ready:
        overall_status = "static-ready"
        exit_code = 0
    else:
        overall_status = "ready"
        exit_code = 0
    return {
        "schema": SCHEMA,
        "selection": {"source": "all" if len(selected_names) == len(records) else "explicit", "packages": selected_names},
        "counts": {
            "selected": len(selected_names),
            "aur_build": sum(records[name].role == "aur-build" for name in selected_names),
            "paru_bootstrap": sum(records[name].role == "paru-bootstrap" for name in selected_names),
            "ready": sum(item["status"] == "ready" for item in recipes_report),
            "static_ready": sum(item["status"] == "static-ready" for item in recipes_report),
            "blocked": sum(item["status"] == "blocked" for item in recipes_report),
            "unavailable": sum(item["status"] == "unavailable" for item in recipes_report),
        },
        "recipes": recipes_report,
        "build_policy": {
            "ordinary_user": True,
            "isolated_build_required": True,
            "network_during_prepare_build_package": False,
            "downloaded_source_execution_requires_isolation": True,
            "arbitrary_packages_allowed": False,
        },
        "overall": {
            "status": overall_status,
            "exit_code": exit_code,
            "blockers": all_blockers,
            "unavailable_checks": all_unavailable,
            "source_verification_required": static_ready,
        },
        "apply": {"authorized": False, "commands": None},
        "safety": {
            "read_only_system": True,
            "source_downloads": verify_sources,
            "executes_downloaded_sources": False,
            "system_changes": False,
            "installer_apply_integration": False,
        },
    }


def render_text(plan: dict[str, Any]) -> None:
    counts = plan["counts"]
    print("Declared fixed AUR recipe plan")
    print(f"Selection: {counts['selected']} packages ({counts['aur_build']} regular AUR, {counts['paru_bootstrap']} Paru bootstrap)")
    print(f"Status: {plan['overall']['status']}")
    if plan["overall"]["source_verification_required"]:
        print("Remote-source status: declarations/hash policy only; --verify-sources is required before apply.")
    for recipe in plan["recipes"]:
        suffix = ""
        if recipe["external_source"] != "-":
            suffix = f"; external source={recipe['external_source']}"
        print(
            f"  [{recipe['status']}/{recipe['role']}/{recipe['module']}] "
            f"{recipe['package']} {recipe['pkgver']}-{recipe['pkgrel']}{suffix}"
        )
    if plan["overall"]["blockers"]:
        print("Blockers:")
        for blocker in plan["overall"]["blockers"]:
            print(f"  - {blocker}")
    if plan["overall"]["unavailable_checks"]:
        print("Unavailable checks:")
        for check in plan["overall"]["unavailable_checks"]:
            print(f"  - {check}")
    print("Apply: disabled; no package, source-cache, repository, or system change was made.")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--json", action="store_true", help="emit structured JSON")
    parser.add_argument("--packages", help="exact comma-separated declared package subset, or all")
    parser.add_argument(
        "--source-cache",
        type=Path,
        default=Path.home() / ".cache/my-archlinux-setup/aur-sources",
        help="read-only lookup root for fixed local-source preconditions",
    )
    parser.add_argument(
        "--verify-sources",
        action="store_true",
        help="download into temporary directories and run makepkg --verifysource; never builds or installs",
    )
    parser.add_argument("--project-root", type=Path, help=argparse.SUPPRESS)
    arguments = parser.parse_args()
    project_root = (arguments.project_root or Path(__file__).resolve().parent.parent).resolve()
    try:
        records = load_recipe_policy(project_paths(project_root)["manifest"])
        selected = parse_selection(arguments.packages, set(records))
        plan = build_plan(
            project_root,
            Path(os.path.abspath(os.fspath(arguments.source_cache.expanduser()))),
            selected,
            arguments.verify_sources,
        )
    except PolicyError as error:
        print(f"aur-plan: {error}", file=sys.stderr)
        raise SystemExit(2) from error
    if arguments.json:
        json.dump(plan, sys.stdout, indent=2, sort_keys=True)
        print()
    else:
        render_text(plan)
    raise SystemExit(plan["overall"]["exit_code"])


if __name__ == "__main__":
    main()
