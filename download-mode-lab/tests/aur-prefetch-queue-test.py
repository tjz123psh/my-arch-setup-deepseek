#!/usr/bin/env python3
"""Compare serial and bounded-concurrency source prefetch in a local model.

This is deliberately not a real AUR build benchmark.  It isolates the network
queue only: six independent source objects are served with identical latency,
then the lab candidate is run with one worker (the current fetch script's
call-by-call shape) and three workers (a bounded prefetch proposal).
"""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time

LAB = Path(__file__).resolve().parents[1]
SERVER = LAB / "bin" / "mock-repo-server.py"
DOWNLOADER = LAB / "bin" / "batch-download.py"
RESULT = LAB / "results" / "aur-queue-model.json"


def wait_port(path: Path, timeout: float = 5.0) -> int:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if path.exists():
            return int(path.read_text(encoding="utf-8").strip())
        time.sleep(0.02)
    raise RuntimeError(f"server port file did not appear: {path}")


def run_downloader(manifest: Path, dest: Path, report: Path, jobs: int) -> tuple[int, float, dict]:
    env = os.environ.copy()
    for key in ("HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy"):
        env.pop(key, None)
    env["NO_PROXY"] = "127.0.0.1,localhost"
    started = time.monotonic()
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
            "1",
            "--timeout",
            "5",
            "--retry-delay",
            "0",
        ],
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )
    elapsed = time.monotonic() - started
    if not report.exists():
        raise RuntimeError(f"missing report for jobs={jobs}: {cp.stderr[-1000:]}")
    return cp.returncode, elapsed, json.loads(report.read_text(encoding="utf-8"))


def main() -> int:
    temp_root = LAB / "fixtures" / "tmp"
    temp_root.mkdir(parents=True, exist_ok=True)
    server_proc: subprocess.Popen[str] | None = None
    try:
        with tempfile.TemporaryDirectory(prefix="aur-queue-", dir=temp_root) as raw:
            root = Path(raw)
            source_dir = root / "source"
            source_dir.mkdir()
            payloads: list[tuple[str, bytes]] = []
            for index in range(6):
                name = f"source-{index}.dat"
                payload = bytes((index * 17 + offset * 7) % 256 for offset in range(64 * 1024))
                (source_dir / name).write_bytes(payload)
                payloads.append((name, payload))

            port_file = root / "server.port"
            server_log = root / "server.json"
            server_proc = subprocess.Popen(
                [
                    sys.executable,
                    str(SERVER),
                    "--directory",
                    str(source_dir),
                    "--port-file",
                    str(port_file),
                    "--log-file",
                    str(server_log),
                    "--delay",
                    "0.25",
                ],
                text=True,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.PIPE,
            )
            port = wait_port(port_file)
            manifest = root / "manifest.json"
            manifest.write_text(
                json.dumps(
                    [
                        {
                            "name": name,
                            "url": f"http://127.0.0.1:{port}/{name}",
                            "sha256": hashlib.sha256(payload).hexdigest(),
                            "size": len(payload),
                        }
                        for name, payload in payloads
                    ],
                    indent=2,
                )
                + "\n",
                encoding="utf-8",
            )

            serial_rc, serial_elapsed, serial_report = run_downloader(
                manifest, root / "serial", root / "serial-report.json", jobs=1
            )
            parallel_rc, parallel_elapsed, parallel_report = run_downloader(
                manifest, root / "parallel", root / "parallel-report.json", jobs=3
            )
            server_proc.send_signal(signal.SIGINT)
            server_proc.wait(timeout=5)
            server_proc = None
            server_data = json.loads(server_log.read_text(encoding="utf-8"))

            serial_ok = serial_rc == 0 and serial_report.get("status") == "ok"
            parallel_ok = parallel_rc == 0 and parallel_report.get("status") == "ok"
            speedup = serial_elapsed / parallel_elapsed if parallel_elapsed else 0.0
            checks = [
                {"name": "serial model succeeds", "passed": serial_ok, "evidence": f"rc={serial_rc}"},
                {"name": "bounded model succeeds", "passed": parallel_ok, "evidence": f"rc={parallel_rc}"},
                {
                    "name": "bounded model overlaps requests",
                    "passed": server_data.get("max_active", 0) >= 3,
                    "evidence": f"max_active={server_data.get('max_active')}",
                },
                {
                    "name": "bounded model materially reduces queue time",
                    "passed": parallel_elapsed < serial_elapsed * 0.75,
                    "evidence": f"serial={serial_elapsed:.3f}s parallel={parallel_elapsed:.3f}s speedup={speedup:.2f}x",
                },
            ]
            result = {
                "schema": 1,
                "test": "aur-prefetch-queue-model",
                "passed": all(check["passed"] for check in checks),
                "delay_seconds_per_request": 0.25,
                "source_count": len(payloads),
                "serial_jobs": 1,
                "bounded_jobs": 3,
                "serial_elapsed_seconds": round(serial_elapsed, 3),
                "bounded_elapsed_seconds": round(parallel_elapsed, 3),
                "speedup": round(speedup, 2),
                "server_max_active": server_data.get("max_active"),
                "checks": checks,
            }
            RESULT.parent.mkdir(parents=True, exist_ok=True)
            RESULT.write_text(json.dumps(result, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
            print(json.dumps({k: result[k] for k in ("passed", "serial_elapsed_seconds", "bounded_elapsed_seconds", "speedup", "server_max_active")}, ensure_ascii=False))
            if not result["passed"]:
                for check in checks:
                    if not check["passed"]:
                        print(f"FAIL: {check['name']}: {check['evidence']}", file=sys.stderr)
                return 1
            return 0
    finally:
        if server_proc is not None and server_proc.poll() is None:
            server_proc.terminate()
            try:
                server_proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                server_proc.kill()
                server_proc.wait()


if __name__ == "__main__":
    raise SystemExit(main())
