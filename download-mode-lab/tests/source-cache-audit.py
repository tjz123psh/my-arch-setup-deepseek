#!/usr/bin/env python3
"""Static, read-only audit of the current AUR source-cache helpers.

The output intentionally reports confirmed defects rather than disguising them
as passing product tests.  It does not source or execute fetch-aur-sources.sh,
so no network or cache mutation occurs.
"""
from __future__ import annotations

import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "fetch-aur-sources.sh"
RESULT = Path(__file__).resolve().parents[1] / "results" / "source-cache-audit.json"


def function_body(text: str, signature: str) -> str:
    start = text.index(signature)
    # Functions in this file use an unindented closing brace.
    end = text.index("\n}", start) + 2
    return text[start:end]


def main() -> int:
    text = SOURCE.read_text(encoding="utf-8")
    dl = function_body(text, "dl() {")
    gitm = function_body(text, "gitm() {")
    vmware = function_body(text, "dl_vmware() {")
    url_section = text[text.index('echo "== URL sources =="') : text.index('echo\necho "== Go module cache')]
    generic_calls = [line for line in url_section.splitlines() if re.match(r"^dl\s+", line)]
    checks = [
        {
            "id": "nonempty-only-skip",
            "status": "CONFIRMED_DEFECT" if 'if [[ -s "$DEST/$name" ]]' in dl else "NOT_FOUND",
            "evidence": "generic dl returns SKIP before checksum validation",
        },
        {
            "id": "no-resume-on-curl-failure",
            "status": "CONFIRMED_DEFECT" if 'rm -f "$DEST/$name.part"' in dl and "-C -" not in dl else "NOT_FOUND",
            "evidence": "generic dl removes .part after curl failure and does not use Range resume",
        },
        {
            "id": "shared-download-error-log",
            "status": "CONFIRMED_DEFECT" if "/tmp/aur-dl.err" in dl else "NOT_FOUND",
            "evidence": "all generic URL failures use one fixed temporary error path",
        },
        {
            "id": "git-failure-discards-progress",
            "status": "CONFIRMED_DEFECT" if "rm -rf \"$DEST/$name\"" in gitm else "NOT_FOUND",
            "evidence": "failed mirror is removed instead of retained as resumable diagnostic state",
        },
        {
            "id": "vmware-hash-check",
            "status": "PRESENT" if 'sha256sum "$DEST/$name"' in vmware and 'sha256sum "$DEST/$name.part"' in vmware else "MISSING",
            "evidence": "VMware helper has an explicit expected hash, unlike generic dl calls",
        },
    ]
    payload = {
        "schema": 1,
        "status": "defects_confirmed",
        "source": "fetch-aur-sources.sh",
        "generic_url_call_count": len(generic_calls),
        "generic_calls_without_explicit_hash_argument": "not safely inferable from shell text; manifest generation required",
        "checks": checks,
    }
    RESULT.parent.mkdir(parents=True, exist_ok=True)
    RESULT.write_text(json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps({"status": payload["status"], "checks": len(checks), "generic_url_call_count": len(generic_calls)}, ensure_ascii=False))
    return 0 if all(check["status"] not in {"NOT_FOUND", "MISSING"} for check in checks) else 1


if __name__ == "__main__":
    raise SystemExit(main())
