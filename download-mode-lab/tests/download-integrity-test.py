#!/usr/bin/env python3
"""Failure-injection tests for the download-mode lab candidate.

The test server is local-only.  It deliberately exercises the cases that are
usually hidden by a simple ``curl -o`` loop: transient HTTP failure, an
interrupted body, a server that ignores Range, checksum mismatch, a stale
partial, a valid cache hit, bounded concurrency, and non-zero failure status.
"""
from __future__ import annotations

from collections import defaultdict
import hashlib
import http.server
import json
import os
from pathlib import Path
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
from typing import Any

LAB = Path(__file__).resolve().parents[1]
DOWNLOADER = LAB / "bin" / "batch-download.py"
RESULT = LAB / "results" / "download-integrity.json"


class Route:
    def __init__(
        self,
        data: bytes,
        *,
        fail_first: int = 0,
        truncate_first: int | None = None,
        ignore_range: bool = False,
        delay: float = 0.0,
    ) -> None:
        self.data = data
        self.fail_first = fail_first
        self.truncate_first = truncate_first
        self.ignore_range = ignore_range
        self.delay = delay


class State:
    def __init__(self, routes: dict[str, Route]) -> None:
        self.routes = routes
        self.counts: defaultdict[str, int] = defaultdict(int)
        self.range_headers: defaultdict[str, list[str]] = defaultdict(list)
        self.active = 0
        self.max_active = 0
        self.lock = threading.Lock()

    def start(self, path: str, range_header: str) -> tuple[Route | None, int]:
        with self.lock:
            self.counts[path] += 1
            count = self.counts[path]
            self.range_headers[path].append(range_header)
            self.active += 1
            self.max_active = max(self.max_active, self.active)
            return self.routes.get(path), count

    def finish(self) -> None:
        with self.lock:
            self.active -= 1


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, _format: str, *_args: Any) -> None:
        return

    def do_GET(self) -> None:  # noqa: N802 - stdlib handler API
        path = self.path.split("?", 1)[0]
        range_header = self.headers.get("Range", "")
        route, count = self.server.state.start(path, range_header)  # type: ignore[attr-defined]
        try:
            if route is None:
                self.send_response(404)
                self.send_header("Content-Length", "0")
                self.send_header("Connection", "close")
                self.end_headers()
                return
            if count <= route.fail_first:
                self.send_response(503)
                self.send_header("Content-Length", "0")
                self.send_header("Connection", "close")
                self.end_headers()
                return

            start = 0
            status = 200
            if range_header and not route.ignore_range:
                match = re.fullmatch(r"bytes=(\d+)-", range_header)
                if match is None:
                    self.send_response(416)
                    self.send_header("Content-Range", f"bytes */{len(route.data)}")
                    self.send_header("Content-Length", "0")
                    self.send_header("Connection", "close")
                    self.end_headers()
                    return
                start = int(match.group(1))
                if start >= len(route.data):
                    self.send_response(416)
                    self.send_header("Content-Range", f"bytes */{len(route.data)}")
                    self.send_header("Content-Length", "0")
                    self.send_header("Connection", "close")
                    self.end_headers()
                    return
                status = 206

            body = route.data[start:]
            self.send_response(status)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Connection", "close")
            if status == 206:
                self.send_header("Content-Range", f"bytes {start}-{len(route.data) - 1}/{len(route.data)}")
            self.end_headers()

            if route.truncate_first is not None and count == 1 and not range_header:
                partial = body[: route.truncate_first]
                try:
                    self.wfile.write(partial)
                    self.wfile.flush()
                    self.connection.shutdown(socket.SHUT_WR)
                except (BrokenPipeError, ConnectionResetError, OSError):
                    pass
                return

            for offset in range(0, len(body), 16 * 1024):
                try:
                    self.wfile.write(body[offset : offset + 16 * 1024])
                    self.wfile.flush()
                except (BrokenPipeError, ConnectionResetError, OSError):
                    return
                if route.delay:
                    time.sleep(route.delay)
        finally:
            self.server.state.finish()  # type: ignore[attr-defined]


class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, state: State) -> None:
        super().__init__(("127.0.0.1", 0), Handler)
        self.state = state


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def write_manifest(path: Path, entries: list[dict[str, Any]]) -> None:
    path.write_text(json.dumps(entries, indent=2) + "\n", encoding="utf-8")


def run_batch(manifest: Path, dest: Path, report: Path, *, jobs: int = 3, attempts: int = 2) -> tuple[int, dict[str, Any]]:
    env = os.environ.copy()
    # A local test must not accidentally traverse a workstation proxy.
    for key in ("HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy"):
        env.pop(key, None)
    env["NO_PROXY"] = "127.0.0.1,localhost"
    cp = subprocess.run(
        [
            sys.executable,
            str(DOWNLOADER),
            "--manifest",
            str(manifest),
            "--dest",
            str(dest),
            "--report",
            str(report),
            "--jobs",
            str(jobs),
            "--attempts",
            str(attempts),
            "--timeout",
            "5",
            "--retry-delay",
            "0.01",
        ],
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )
    if not report.exists():
        raise RuntimeError(f"downloader did not write report (rc={cp.returncode}, stderr={cp.stderr[-1000:]})")
    return cp.returncode, json.loads(report.read_text(encoding="utf-8"))


def check(checks: list[dict[str, Any]], name: str, condition: bool, evidence: str = "") -> None:
    checks.append({"name": name, "status": "PASS" if condition else "FAIL", "evidence": evidence})


def main() -> int:
    # Distinct deterministic payloads make accidental concatenation and stale
    # cache reuse visible in the final digest.
    retry_data = bytes((i * 11 + 3) % 256 for i in range(128 * 1024))
    slow_a = bytes((i * 7 + 19) % 256 for i in range(384 * 1024))
    slow_b = bytes((i * 13 + 23) % 256 for i in range(384 * 1024))
    interrupt_data = bytes((i * 17 + 29) % 256 for i in range(512 * 1024))
    restart_data = bytes((i * 5 + 31) % 256 for i in range(256 * 1024))
    stale_data = bytes((i * 3 + 37) % 256 for i in range(192 * 1024))
    mismatch_data = bytes((i * 23 + 41) % 256 for i in range(96 * 1024))
    expected_mismatch = bytes((i * 31 + 53) % 256 for i in range(96 * 1024))
    old_data = bytes((i * 29 + 47) % 256 for i in range(96 * 1024))

    routes = {
        "/retry.bin": Route(retry_data, fail_first=1),
        "/slow-a.bin": Route(slow_a, delay=0.02),
        "/slow-b.bin": Route(slow_b, delay=0.02),
        "/interrupt.bin": Route(interrupt_data, truncate_first=100_000),
        "/restart.bin": Route(restart_data, ignore_range=True),
        "/stale.bin": Route(stale_data),
        "/mismatch.bin": Route(mismatch_data),
    }
    state = State(routes)
    server = Server(state)
    thread = threading.Thread(target=server.serve_forever, name="download-lab-http", daemon=True)
    thread.start()
    base = f"http://127.0.0.1:{server.server_port}"
    checks: list[dict[str, Any]] = []

    try:
        temp_root = LAB / "fixtures" / "tmp"
        temp_root.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="download-integrity-", dir=temp_root) as raw:
            root = Path(raw)
            dest = root / "cache"
            dest.mkdir()
            manifest = root / "batch.json"
            report = root / "batch-report.json"
            # A valid final file must be a zero-request cache hit.
            cached_data = b"already complete cache\n"
            (dest / "cached.bin").write_bytes(cached_data)
            protected = dest / "mismatch.bin"
            protected.write_bytes(old_data)
            entries = [
                {"name": "cached.bin", "url": f"{base}/cache-probe.bin", "sha256": digest(cached_data), "size": len(cached_data)},
                {"name": "retry.bin", "url": f"{base}/retry.bin", "sha256": digest(retry_data), "size": len(retry_data)},
                {"name": "slow-a.bin", "url": f"{base}/slow-a.bin", "sha256": digest(slow_a), "size": len(slow_a)},
                {"name": "slow-b.bin", "url": f"{base}/slow-b.bin", "sha256": digest(slow_b), "size": len(slow_b)},
                {"name": "missing.bin", "url": f"{base}/missing.bin", "sha256": digest(b"missing"), "size": 7},
                # The existing old final must survive a checksum failure.
                {"name": "mismatch.bin", "url": f"{base}/mismatch.bin", "sha256": digest(expected_mismatch), "size": len(mismatch_data)},
            ]
            write_manifest(manifest, entries)

            observed_invalid_final: list[str] = []
            stop_watch = threading.Event()

            def watch_finals() -> None:
                expected = {"slow-a.bin": slow_a, "slow-b.bin": slow_b}
                while not stop_watch.is_set():
                    for name, payload in expected.items():
                        path = dest / name
                        if path.exists():
                            try:
                                if path.read_bytes() != payload:
                                    observed_invalid_final.append(name)
                            except OSError:
                                pass
                    time.sleep(0.002)

            watcher = threading.Thread(target=watch_finals, name="download-lab-watch", daemon=True)
            watcher.start()
            rc, batch_report = run_batch(manifest, dest, report, jobs=3, attempts=2)
            stop_watch.set()
            watcher.join(timeout=2)

            by_name = {entry["name"]: entry for entry in batch_report["items"]}
            check(checks, "mixed batch returns non-zero when an item fails", rc != 0, f"rc={rc}")
            check(checks, "valid final cache is reused", by_name["cached.bin"]["status"] == "cached")
            check(checks, "cache hit made no HTTP request", state.counts["/cache-probe.bin"] == 0, f"cache_probe_requests={state.counts['/cache-probe.bin']}")
            check(checks, "transient HTTP failure is retried", by_name["retry.bin"]["status"] == "downloaded" and by_name["retry.bin"]["attempts"] == 2, str(by_name["retry.bin"]))
            check(checks, "successful files are complete and hashed", (dest / "retry.bin").read_bytes() == retry_data and (dest / "slow-a.bin").read_bytes() == slow_a and (dest / "slow-b.bin").read_bytes() == slow_b)
            check(checks, "successful files leave no .part artifacts", not any((dest / name).with_name(name + ".part").exists() for name in ("retry.bin", "slow-a.bin", "slow-b.bin")))
            check(checks, "bounded worker concurrency is observed", 2 <= state.max_active <= 3, f"max_active={state.max_active}")
            check(checks, "atomic publication never exposes a partial final", not observed_invalid_final, repr(observed_invalid_final))
            check(checks, "checksum failure is reported", by_name["mismatch.bin"].get("error_code") == "integrity", str(by_name["mismatch.bin"]))
            check(checks, "checksum failure does not replace old final", protected.read_bytes() == old_data and not (dest / "mismatch.bin.part").exists())
            check(checks, "permanent HTTP failure remains failed", by_name["missing.bin"].get("error_code") == "http_404" and not (dest / "missing.bin").exists(), str(by_name["missing.bin"]))

            # A body interruption must leave a resumable prefix, not a fake
            # complete cache.  The second invocation should use Range.
            interrupt_manifest = root / "interrupt.json"
            interrupt_report_1 = root / "interrupt-report-1.json"
            write_manifest(
                interrupt_manifest,
                # Deliberately omit size: the downloader must use the server's
                # Content-Length while still requiring the manifest checksum.
                [{"name": "interrupt.bin", "url": f"{base}/interrupt.bin", "sha256": digest(interrupt_data)}],
            )
            rc1, rep1 = run_batch(interrupt_manifest, dest, interrupt_report_1, jobs=1, attempts=1)
            part = dest / "interrupt.bin.part"
            check(checks, "interrupted first attempt fails", rc1 != 0 and rep1["items"][0]["status"] == "failed")
            check(checks, "interrupted transfer leaves only a partial file", part.exists() and part.stat().st_size == 100_000 and not (dest / "interrupt.bin").exists(), f"part={part.stat().st_size if part.exists() else 0}")
            rc2, rep2 = run_batch(interrupt_manifest, dest, root / "interrupt-report-2.json", jobs=1, attempts=2)
            ranges = state.range_headers["/interrupt.bin"]
            check(checks, "partial transfer resumes with HTTP Range", rc2 == 0 and rep2["items"][0]["status"] == "downloaded" and ranges[-1] == "bytes=100000-", repr(ranges))
            check(checks, "resumed file is verified and .part is removed", (dest / "interrupt.bin").read_bytes() == interrupt_data and not part.exists())

            # A server that ignores Range must cause a safe restart, not an
            # append that corrupts the object.
            restart_part = dest / "restart.bin.part"
            restart_part.write_bytes(restart_data[:17_000])
            restart_manifest = root / "restart.json"
            write_manifest(
                restart_manifest,
                [{"name": "restart.bin", "url": f"{base}/restart.bin", "sha256": digest(restart_data), "size": len(restart_data)}],
            )
            rc3, rep3 = run_batch(restart_manifest, dest, root / "restart-report.json", jobs=1, attempts=1)
            check(checks, "Range-ignoring server triggers safe restart", rc3 == 0 and rep3["items"][0]["status"] == "downloaded" and (dest / "restart.bin").read_bytes() == restart_data, repr(state.range_headers["/restart.bin"]))
            check(checks, "safe restart removes stale .part", not restart_part.exists())

            # A full-sized corrupt partial is restarted from zero rather than
            # issuing a nonsensical Range at EOF.
            stale_part = dest / "stale.bin.part"
            stale_part.write_bytes(b"x" * len(stale_data))
            stale_manifest = root / "stale.json"
            write_manifest(
                stale_manifest,
                [{"name": "stale.bin", "url": f"{base}/stale.bin", "sha256": digest(stale_data), "size": len(stale_data)}],
            )
            rc4, rep4 = run_batch(stale_manifest, dest, root / "stale-report.json", jobs=1, attempts=1)
            check(checks, "full-sized corrupt partial restarts", rc4 == 0 and rep4["items"][0]["status"] == "downloaded" and (dest / "stale.bin").read_bytes() == stale_data, repr(state.range_headers["/stale.bin"]))
            check(checks, "full-sized corrupt partial is not ranged", state.range_headers["/stale.bin"][-1] == "")

            # Invalid names are rejected before any outside path can be used;
            # this also gives the caller a distinct non-zero validation status.
            invalid_manifest = root / "invalid.json"
            invalid_report = root / "invalid-report.json"
            write_manifest(
                invalid_manifest,
                [{"name": "../escaped.bin", "url": f"{base}/stale.bin", "sha256": digest(stale_data), "size": len(stale_data)}],
            )
            rc5, invalid_rep = run_batch(invalid_manifest, dest, invalid_report, jobs=1, attempts=1)
            check(checks, "unsafe manifest path fails closed", rc5 == 2 and invalid_rep["status"] == "invalid_manifest" and not (root / "escaped.bin").exists(), str(invalid_rep))

            summary = {
                "schema": 1,
                "test": "download-integrity-test",
                "passed": all(entry["status"] == "PASS" for entry in checks),
                "checks": checks,
                "server_max_concurrency": state.max_active,
                "request_counts": dict(sorted(state.counts.items())),
                "range_requests": {key: value for key, value in sorted(state.range_headers.items()) if any(value)},
            }
            RESULT.parent.mkdir(parents=True, exist_ok=True)
            RESULT.write_text(json.dumps(summary, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
            print(json.dumps({"passed": summary["passed"], "checks": len(checks), "server_max_concurrency": state.max_active}, ensure_ascii=False))
            if not summary["passed"]:
                for entry in checks:
                    if entry["status"] != "PASS":
                        print(f"FAIL: {entry['name']}: {entry['evidence']}", file=sys.stderr)
                return 1
            return 0
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)


if __name__ == "__main__":
    raise SystemExit(main())
