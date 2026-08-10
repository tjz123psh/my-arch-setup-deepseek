#!/usr/bin/env python3
"""Read-only bounded range probe; writes no files outside the requested output."""
from __future__ import annotations

import argparse
import concurrent.futures
import json
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

BASES = {
    "official": [
        "https://mirrors.aliyun.com/archlinux",
        "https://mirrors.ustc.edu.cn/archlinux",
        "https://mirrors.tuna.tsinghua.edu.cn/archlinux",
        "https://mirrors.cloud.tencent.com/archlinux",
        "https://mirrors.huaweicloud.com/archlinux",
        "https://mirrors.163.com/archlinux",
        "https://mirrors.lzu.edu.cn/archlinux",
        "https://mirrors.zju.edu.cn/archlinux",
    ],
    "archlinuxcn": [
        "https://mirrors.aliyun.com/archlinuxcn",
        "https://mirrors.ustc.edu.cn/archlinuxcn",
        "https://mirrors.tuna.tsinghua.edu.cn/archlinuxcn",
        "https://mirrors.cloud.tencent.com/archlinuxcn",
        "https://mirrors.huaweicloud.com/archlinuxcn",
        "https://mirrors.lzu.edu.cn/archlinuxcn",
        "https://mirrors.zju.edu.cn/archlinuxcn",
    ],
}
RELATIVE = {
    "official": "core/os/x86_64/core.db",
    "archlinuxcn": "x86_64/archlinuxcn.db",
}


def one(item: tuple[str, str], end: int, connect_timeout: int, max_time: int) -> dict[str, Any]:
    repo, base = item
    url = f"{base}/{RELATIVE[repo]}"
    fmt = "status=%{http_code}\ntotal=%{time_total}\nbytes=%{size_download}\n"
    started = time.monotonic()
    cp = subprocess.run(
        [
            "curl",
            "--silent",
            "--show-error",
            "--location",
            "--fail",
            "--range",
            f"0-{end}",
            "--max-filesize",
            str(end + 1 + 1024 * 1024),
            "--connect-timeout",
            str(connect_timeout),
            "--max-time",
            str(max_time),
            "--output",
            "/dev/null",
            "--write-out",
            fmt,
            url,
        ],
        text=True,
        capture_output=True,
        check=False,
    )
    elapsed = time.monotonic() - started
    values: dict[str, str] = {}
    for line in cp.stdout.splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            values[k] = v
    size = int(float(values.get("bytes", "0") or 0))
    total = float(values.get("total", f"{elapsed:.3f}") or elapsed)
    return {
        "repo": repo,
        "base": base,
        "url": url,
        "status": (
            "OK"
            if cp.returncode == 0 and values.get("status") == "206"
            else "RANGE_UNSUPPORTED"
            if cp.returncode == 0 and values.get("status") == "200"
            else "UNAVAILABLE"
        ),
        "exit_code": cp.returncode,
        "http_status": values.get("status", ""),
        "range_supported": cp.returncode == 0 and values.get("status") == "206",
        "bytes": size,
        "seconds": total,
        "mib_per_second": round(size / 1048576 / total, 3) if size and total else 0,
        "error_tail": cp.stderr.strip().splitlines()[-1] if cp.stderr.strip() else "",
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--output", type=Path, required=True)
    ap.add_argument("--end", type=int, default=262143, help="last byte of bounded range")
    ap.add_argument("--workers", type=int, default=8)
    ap.add_argument("--connect-timeout", type=int, default=4)
    ap.add_argument("--max-time", type=int, default=20)
    args = ap.parse_args()
    items = [(repo, base) for repo, bases in BASES.items() for base in bases]
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.workers) as pool:
        rows = list(pool.map(lambda item: one(item, args.end, args.connect_timeout, args.max_time), items))
    rows.sort(key=lambda row: (row["repo"], row["base"]))
    payload = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "range_end": args.end,
        "workers": args.workers,
        "measurement": "bounded HTTP range to /dev/null; servers that ignore Range may be marked unavailable",
        "results": rows,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n")
    for row in rows:
        print(f"{row['status']:12} {row['repo']:12} {row['seconds']:>8}s {row['bytes']:>9} B {row['mib_per_second']:>7} MiB/s {row['base']}")
    return 0 if any(row["status"] == "OK" for row in rows) else 2


if __name__ == "__main__":
    raise SystemExit(main())
