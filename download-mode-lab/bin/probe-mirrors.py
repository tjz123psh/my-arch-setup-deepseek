#!/usr/bin/env python3
"""Read-only mirror latency probe for the download-mode experiment.

The probe fetches only response headers, concurrently, and records every
attempt as OK or UNAVAILABLE with the subprocess exit status. It never edits
pacman configuration or package databases.
"""
from __future__ import annotations

import argparse
import concurrent.futures
import json
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

OFFICIAL = [
    "https://mirrors.aliyun.com/archlinux",
    "https://mirrors.ustc.edu.cn/archlinux",
    "https://mirrors.tuna.tsinghua.edu.cn/archlinux",
    "https://mirrors.cloud.tencent.com/archlinux",
    "https://mirrors.huaweicloud.com/archlinux",
    "https://mirrors.163.com/archlinux",
    "https://mirrors.lzu.edu.cn/archlinux",
    "https://mirrors.zju.edu.cn/archlinux",
]
ARCHLINUXCN = [
    "https://mirrors.aliyun.com/archlinuxcn",
    "https://mirrors.ustc.edu.cn/archlinuxcn",
    "https://mirrors.tuna.tsinghua.edu.cn/archlinuxcn",
    "https://mirrors.cloud.tencent.com/archlinuxcn",
    "https://mirrors.huaweicloud.com/archlinuxcn",
    "https://mirrors.lzu.edu.cn/archlinuxcn",
    "https://mirrors.zju.edu.cn/archlinuxcn",
]


def probe(item: tuple[str, str, str], connect_timeout: int, max_time: int) -> dict[str, Any]:
    repo, base, relative = item
    url = f"{base}/{relative}"
    fmt = "status=%{http_code}\nconnect=%{time_connect}\nstart=%{time_starttransfer}\ntotal=%{time_total}\nsize=%{size_download}\nip=%{remote_ip}\n"
    started = time.monotonic()
    proc = subprocess.run(
        [
            "curl",
            "--head",
            "--silent",
            "--show-error",
            "--location",
            "--fail",
            "--connect-timeout",
            str(connect_timeout),
            "--max-time",
            str(max_time),
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
    for line in proc.stdout.splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            values[key] = value
    return {
        "repo": repo,
        "base": base,
        "url": url,
        "status": "OK" if proc.returncode == 0 and values.get("status") == "200" else "UNAVAILABLE",
        "exit_code": proc.returncode,
        "http_status": values.get("status", ""),
        "connect_seconds": values.get("connect", ""),
        "starttransfer_seconds": values.get("start", ""),
        "total_seconds": values.get("total", f"{elapsed:.3f}"),
        "size_bytes": values.get("size", ""),
        "remote_ip": values.get("ip", ""),
        "error_tail": proc.stderr.strip().splitlines()[-1] if proc.stderr.strip() else "",
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--workers", type=int, default=8)
    parser.add_argument("--connect-timeout", type=int, default=4)
    parser.add_argument("--max-time", type=int, default=12)
    args = parser.parse_args()

    items = [("official", base, "core/os/x86_64/core.db") for base in OFFICIAL]
    items += [("archlinuxcn", base, "x86_64/archlinuxcn.db") for base in ARCHLINUXCN]
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.workers) as pool:
        rows = list(pool.map(lambda x: probe(x, args.connect_timeout, args.max_time), items))
    rows.sort(key=lambda row: (row["repo"], row["base"]))
    payload = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "workers": args.workers,
        "connect_timeout": args.connect_timeout,
        "max_time": args.max_time,
        "measurement": "HEAD only; no package or database installation",
        "results": rows,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n")
    for row in rows:
        print(
            f"{row['status']:12} {row['repo']:12} {row['total_seconds']:>8}s "
            f"rc={row['exit_code']} {row['base']}"
        )
    return 0 if any(row["status"] == "OK" for row in rows) else 2


if __name__ == "__main__":
    raise SystemExit(main())
