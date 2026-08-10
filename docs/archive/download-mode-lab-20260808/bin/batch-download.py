#!/usr/bin/env python3
"""Small, auditable concurrent downloader for the download-mode lab.

This is a lab candidate, not part of the production installer.  It models the
properties a future AUR/source prefetch stage would need:

* bounded concurrency;
* resumable ``.part`` files when the server honours HTTP Range;
* checksum/size verification before publication;
* atomic publication with ``os.replace``;
* per-item failure reporting and a non-zero process status on any failure.

It intentionally uses only Python's standard library so the experiment does
not assume that aria2/axel/parallel is already installed.
"""
from __future__ import annotations

import argparse
import concurrent.futures
import hashlib
import http.client
import json
import os
from pathlib import Path, PurePosixPath
import re
import socket
import tempfile
import time
from dataclasses import dataclass
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

_CHUNK_SIZE = 64 * 1024
_SHA256_RE = re.compile(r"^[0-9a-fA-F]{64}$")
_CONTENT_RANGE_RE = re.compile(r"^bytes\s+(\d+)-(\d+)/(\d+|\*)$")


class DownloadFailure(Exception):
    """An expected download failure, annotated with retry policy."""

    def __init__(self, code: str, message: str, *, retryable: bool) -> None:
        super().__init__(message)
        self.code = code
        self.retryable = retryable


@dataclass(frozen=True)
class Item:
    name: str
    url: str
    sha256: str
    size: int | None


def _safe_name(name: str) -> Path:
    """Return a safe relative path, rejecting traversal and platform tricks."""
    if not isinstance(name, str) or not name or "\\" in name:
        raise ValueError("name must be a non-empty POSIX relative path")
    p = PurePosixPath(name)
    if not p.parts or p.is_absolute() or any(part in {"", ".", ".."} for part in p.parts):
        raise ValueError(f"unsafe manifest name: {name!r}")
    return Path(*p.parts)


def load_manifest(path: Path) -> list[Item]:
    raw = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(raw, list):
        raise ValueError("manifest must be a JSON array")
    items: list[Item] = []
    seen: set[str] = set()
    for index, entry in enumerate(raw):
        if not isinstance(entry, dict):
            raise ValueError(f"manifest entry {index} is not an object")
        try:
            name = entry["name"]
            url = entry["url"]
            sha256 = entry["sha256"].lower()
            size = entry.get("size")
        except (KeyError, AttributeError) as exc:
            raise ValueError(f"manifest entry {index} is missing required fields") from exc
        safe = _safe_name(name)
        if str(safe) in seen:
            raise ValueError(f"duplicate manifest name: {name!r}")
        seen.add(str(safe))
        if not isinstance(url, str) or not (url.startswith("http://") or url.startswith("https://")):
            raise ValueError(f"manifest entry {index} has an unsupported URL")
        if not isinstance(sha256, str) or not _SHA256_RE.fullmatch(sha256):
            raise ValueError(f"manifest entry {index} has an invalid sha256")
        if size is not None and (not isinstance(size, int) or isinstance(size, bool) or size < 0):
            raise ValueError(f"manifest entry {index} has an invalid size")
        items.append(Item(str(safe), url, sha256, size))
    return items


def _paths(dest: Path, item: Item) -> tuple[Path, Path]:
    root = dest.resolve()
    final = (root / _safe_name(item.name)).resolve()
    try:
        common = os.path.commonpath((str(root), str(final)))
    except ValueError as exc:
        raise DownloadFailure("unsafe_path", str(exc), retryable=False) from exc
    if common != str(root):
        raise DownloadFailure("unsafe_path", f"path escapes destination: {item.name!r}", retryable=False)
    final.parent.mkdir(parents=True, exist_ok=True)
    if final.is_symlink():
        raise DownloadFailure("unsafe_path", f"refusing symlink destination: {item.name!r}", retryable=False)
    part = final.with_name(final.name + ".part")
    if part.is_symlink():
        raise DownloadFailure("unsafe_path", f"refusing symlink partial: {item.name!r}", retryable=False)
    return final, part


def _hash_file(path: Path) -> tuple[int, str]:
    digest = hashlib.sha256()
    size = 0
    with path.open("rb") as stream:
        while True:
            chunk = stream.read(_CHUNK_SIZE)
            if not chunk:
                break
            digest.update(chunk)
            size += len(chunk)
    return size, digest.hexdigest()


def _verify(path: Path, item: Item) -> tuple[bool, str]:
    if not path.is_file() or path.is_symlink():
        return False, "missing"
    try:
        size, digest = _hash_file(path)
    except OSError as exc:
        return False, f"stat/read error: {exc}"
    if item.size is not None and size != item.size:
        return False, f"size mismatch: got {size}, want {item.size}"
    if digest != item.sha256:
        return False, f"sha256 mismatch: got {digest}, want {item.sha256}"
    return True, "ok"


def _http_error(exc: HTTPError) -> DownloadFailure:
    status = int(exc.code)
    try:
        exc.close()
    except Exception:
        pass
    retryable = status in {408, 425, 429} or status >= 500
    return DownloadFailure(f"http_{status}", f"HTTP status {status}", retryable=retryable)


def _open_response(item: Item, offset: int, timeout: float):
    headers = {"Accept-Encoding": "identity", "User-Agent": "download-mode-lab/1"}
    if offset > 0:
        headers["Range"] = f"bytes={offset}-"
    request = Request(item.url, headers=headers, method="GET")
    try:
        response = urlopen(request, timeout=timeout)
    except HTTPError as exc:
        raise _http_error(exc) from exc
    except (URLError, socket.timeout, TimeoutError, OSError) as exc:
        # Do not echo a URL (which could contain userinfo) into the report.
        raise DownloadFailure("network", type(exc).__name__, retryable=True) from exc

    status = int(getattr(response, "status", response.getcode()))
    if status >= 400:
        try:
            response.close()
        finally:
            raise DownloadFailure(
                f"http_{status}",
                f"HTTP status {status}",
                retryable=status in {408, 425, 429, 416} or status >= 500,
            )

    if offset > 0 and status == 206:
        content_range = response.headers.get("Content-Range", "")
        match = _CONTENT_RANGE_RE.fullmatch(content_range)
        if match is not None and int(match.group(1)) == offset:
            return response, "ab", offset
        # A broken Range response must not be appended to a partial file.
        response.close()
        raise DownloadFailure("bad_content_range", "server returned an invalid Content-Range", retryable=True)

    if offset > 0 and status == 200:
        # A server that ignores Range is safe only if we restart from byte zero.
        return response, "wb", 0

    if status not in {200, 206}:
        response.close()
        raise DownloadFailure("http_status", f"unexpected HTTP status {status}", retryable=True)
    return response, "wb", 0


def _response_total(response: Any) -> int | None:
    """Return the remote object's total size when the server advertises it."""
    content_range = response.headers.get("Content-Range", "")
    match = _CONTENT_RANGE_RE.fullmatch(content_range)
    if match is not None and match.group(3) != "*":
        return int(match.group(3))
    raw_length = response.headers.get("Content-Length")
    if raw_length and raw_length.isdigit():
        return int(raw_length)
    return None


def _fsync_directory(directory: Path) -> None:
    try:
        fd = os.open(directory, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    except OSError:
        return
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def _download_once(item: Item, final: Path, part: Path, timeout: float) -> int:
    # A complete-sized but invalid partial must be restarted, not ranged from
    # its end (which would usually produce a 416 and obscure the real error).
    offset = part.stat().st_size if part.exists() else 0
    if item.size is not None and offset >= item.size:
        try:
            part.unlink()
        except FileNotFoundError:
            pass
        offset = 0

    response = None
    remote_total: int | None = None
    try:
        try:
            response, mode, effective_offset = _open_response(item, offset, timeout)
            remote_total = _response_total(response)
        except DownloadFailure as exc:
            # A stale partial can be rejected with 416 after the remote object
            # changed.  Discard only that partial and restart from zero; do not
            # turn a server-side range refusal into an endless retry loop.
            if offset > 0 and exc.code == "http_416":
                try:
                    part.unlink()
                except FileNotFoundError:
                    pass
                response, mode, effective_offset = _open_response(item, 0, timeout)
                remote_total = _response_total(response)
            else:
                raise
        with response:
            with part.open(mode) as stream:
                while True:
                    chunk = response.read(_CHUNK_SIZE)
                    if not chunk:
                        break
                    stream.write(chunk)
                stream.flush()
                os.fsync(stream.fileno())
    except DownloadFailure:
        raise
    except (http.client.IncompleteRead, socket.timeout, TimeoutError, URLError, OSError) as exc:
        # Keep the report credential-free; the code and part_bytes carry the
        # actionable state without echoing a potentially sensitive exception.
        raise DownloadFailure("interrupted", type(exc).__name__, retryable=True) from exc
    except Exception as exc:  # Keep an unexpected worker failure visible.
        raise DownloadFailure("unexpected", type(exc).__name__, retryable=False) from exc

    valid, reason = _verify(part, item)
    if not valid:
        # A short body is a resumable interruption: keep the prefix so the
        # next attempt can issue Range.  Prefer the manifest size, but fall
        # back to Content-Length/Content-Range when a source manifest has only
        # a checksum.  A full-sized/hash-invalid body is not a trustworthy
        # prefix and is removed before reporting failure.
        actual_size = part.stat().st_size if part.exists() else 0
        expected_total = item.size if item.size is not None else remote_total
        if expected_total is not None and actual_size < expected_total:
            raise DownloadFailure("incomplete", reason, retryable=True)
        try:
            part.unlink()
        except FileNotFoundError:
            pass
        raise DownloadFailure("integrity", reason, retryable=False)

    # The only operation that publishes a successful download.  Readers see
    # either the old complete file or the new complete file, never .part.
    os.replace(part, final)
    _fsync_directory(final.parent)
    return effective_offset


def _one(item: Item, dest: Path, attempts: int, timeout: float, retry_delay: float) -> dict[str, Any]:
    started = time.monotonic()
    final, part = _paths(dest, item)
    result: dict[str, Any] = {
        "name": item.name,
        "status": "failed",
        "attempts": 0,
        "elapsed_seconds": 0.0,
        "part_exists": False,
        "part_bytes": 0,
        "final_exists": final.exists(),
        "final_valid": False,
    }

    try:
        if final.exists():
            valid, reason = _verify(final, item)
            if valid:
                result.update(status="cached", attempts=0, final_exists=True, final_valid=True)
                return _finish(result, started)
            result["existing_final_error"] = reason

        last: DownloadFailure | None = None
        for attempt in range(1, attempts + 1):
            result["attempts"] = attempt
            try:
                _download_once(item, final, part, timeout)
                result.update(status="downloaded", final_exists=True, final_valid=True, error=None)
                return _finish(result, started)
            except DownloadFailure as exc:
                last = exc
                if not exc.retryable or attempt >= attempts:
                    break
                if retry_delay > 0:
                    time.sleep(retry_delay * (2 ** (attempt - 1)))
        assert last is not None
        result.update(error_code=last.code, error=str(last))
    except DownloadFailure as exc:
        result.update(error_code=exc.code, error=str(exc))
    except Exception as exc:  # Make worker exceptions part of the report.
        result.update(error_code="unexpected", error=type(exc).__name__)

    try:
        result["part_exists"] = part.is_file()
        result["part_bytes"] = part.stat().st_size if part.is_file() else 0
        result["final_exists"] = final.exists()
        if final.exists():
            result["final_valid"] = _verify(final, item)[0]
    except OSError:
        result["part_exists"] = False
    return _finish(result, started)


def _finish(result: dict[str, Any], started: float) -> dict[str, Any]:
    result["elapsed_seconds"] = round(time.monotonic() - started, 4)
    # Do not expose source URLs or local absolute paths in the report.
    return result


def _write_report(path: Path, report: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temp_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(report, stream, ensure_ascii=False, indent=2, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temp_name, path)
        _fsync_directory(path.parent)
    finally:
        try:
            os.unlink(temp_name)
        except FileNotFoundError:
            pass


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--dest", type=Path, required=True)
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--jobs", type=int, default=3)
    parser.add_argument("--attempts", type=int, default=3)
    parser.add_argument("--timeout", type=float, default=15.0)
    parser.add_argument("--retry-delay", type=float, default=0.2)
    args = parser.parse_args(argv)
    if args.jobs < 1 or args.attempts < 1 or args.timeout <= 0 or args.retry_delay < 0:
        parser.error("jobs/attempts must be >= 1; timeout must be > 0; retry-delay must be >= 0")

    report: dict[str, Any] = {
        "schema": 1,
        "status": "failed",
        "jobs": args.jobs,
        "items": [],
    }
    try:
        items = load_manifest(args.manifest)
        args.dest.mkdir(parents=True, exist_ok=True)
        started = time.monotonic()
        with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as pool:
            futures = [
                pool.submit(_one, item, args.dest, args.attempts, args.timeout, args.retry_delay)
                for item in items
            ]
            results = [future.result() for future in futures]
        report["items"] = results
        report["elapsed_seconds"] = round(time.monotonic() - started, 4)
        failed = [item for item in results if item.get("status") not in {"cached", "downloaded"}]
        report["status"] = "failed" if failed else "ok"
        report["failed_count"] = len(failed)
        _write_report(args.report, report)
        return 1 if failed else 0
    except Exception as exc:
        report.update(status="invalid_manifest", error=repr(exc), failed_count=1)
        try:
            _write_report(args.report, report)
        except Exception:
            pass
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
