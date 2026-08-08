#!/usr/bin/env python3
"""Read-only bounded package range throughput probe."""
from __future__ import annotations

import argparse
import concurrent.futures
import json
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

MIRRORS = {
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


def probe(item: tuple[str, str, str], end: int, timeout: int) -> dict[str, Any]:
    repo, base, relative = item
    url = f"{base}/{relative}"
    fmt = "status=%{http_code}\ntotal=%{time_total}\nbytes=%{size_download}\n"
    started = time.monotonic()
    cp = subprocess.run(
        [
            "curl", "--silent", "--show-error", "--location", "--fail",
            "--range", f"0-{end}", "--max-filesize", str(end + 1 + 1024 * 1024),
            "--connect-timeout", "4", "--max-time", str(timeout),
            "--output", "/dev/null", "--write-out", fmt, url,
        ], text=True, capture_output=True, check=False
    )
    elapsed = time.monotonic() - started
    vals = {}
    for line in cp.stdout.splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            vals[key] = value
    seconds = float(vals.get("total", f"{elapsed:.3f}") or elapsed)
    size = int(float(vals.get("bytes", "0") or 0))
    return {
        "repo": repo, "base": base, "relative": relative, "url": url,
        "status": "OK" if cp.returncode == 0 and vals.get("status") in {"200", "206"} else "UNAVAILABLE",
        "exit_code": cp.returncode, "http_status": vals.get("status", ""),
        "bytes": size, "seconds": seconds,
        "mib_per_second": round(size / 1048576 / seconds, 3) if size and seconds else 0,
        "error_tail": cp.stderr.strip().splitlines()[-1] if cp.stderr.strip() else "",
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('--output', type=Path, required=True)
    ap.add_argument('--official-relative', required=True)
    ap.add_argument('--archlinuxcn-relative', required=True)
    ap.add_argument('--end', type=int, default=1048575)
    ap.add_argument('--workers', type=int, default=8)
    ap.add_argument('--timeout', type=int, default=25)
    args = ap.parse_args()
    items = [("official", b, args.official_relative) for b in MIRRORS["official"]]
    items += [("archlinuxcn", b, args.archlinuxcn_relative) for b in MIRRORS["archlinuxcn"]]
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.workers) as pool:
        rows = list(pool.map(lambda x: probe(x, args.end, args.timeout), items))
    rows.sort(key=lambda row: (row['repo'], row['base']))
    payload = {
        'generated_at': datetime.now(timezone.utc).isoformat(),
        'range_end': args.end, 'workers': args.workers,
        'measurement': 'bounded package HTTP range to /dev/null', 'results': rows,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + '\n')
    for row in rows:
        print(f"{row['status']:12} {row['repo']:12} {row['seconds']:>8}s {row['bytes']:>9} B {row['mib_per_second']:>7} MiB/s {row['base']}")
    return 0 if any(row['status'] == 'OK' for row in rows) else 2


if __name__ == '__main__':
    raise SystemExit(main())
