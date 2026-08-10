#!/usr/bin/env python3
"""Local regression tests for the dynamic mirror planner.

The fixtures model repeated official/archlinuxcn observations and deliberate
failures.  No network, pacman configuration, package database, or host file is
used.  Every failure-path assertion checks both the report status and the
subprocess exit code so a caller cannot mistake a review-only result for an
applyable plan.
"""
from __future__ import annotations

from datetime import datetime, timezone
import json
import os
from pathlib import Path
import runpy
import subprocess
import sys
import tempfile
from unittest.mock import patch

LAB = Path(__file__).resolve().parents[1]
PLANNER = LAB / "bin" / "mirror-plan.py"
RESULT = Path(os.environ.get("RESULT_DIR", str(LAB / "results"))) / "mirror-plan-test.json"
NOW = "2026-08-08T12:00:00+00:00"


def row(
    repo: str,
    base: str,
    speed: float,
    *,
    status: str = "OK",
    http_status: str = "206",
    exit_code: int | None = None,
    error_tail: str = "",
    range_supported: bool | None = None,
) -> dict:
    successful = status == "OK"
    if exit_code is None:
        exit_code = 0 if status in {"OK", "RANGE_UNSUPPORTED"} else 28
    if range_supported is None:
        if status == "OK" and http_status == "206":
            range_supported = True
        elif status == "RANGE_UNSUPPORTED" or http_status == "200" or status == "UNAVAILABLE":
            range_supported = False
    result = {
        "repo": repo,
        "base": base,
        "status": status,
        "http_status": http_status,
        "exit_code": exit_code,
        "range_supported": range_supported,
        "bytes": 1048576 if speed > 0 else 0,
        "seconds": round(1 / speed, 6) if speed > 0 else 4.0,
        "mib_per_second": speed if speed > 0 else 0,
        "error_tail": error_tail if error_tail else ("timeout/range unsupported" if not successful else ""),
    }
    return result


def write_input(
    path: Path,
    rows: list[dict],
    *,
    generated_at: str = NOW,
    measurement: str = "bounded package HTTP range",
) -> None:
    path.write_text(
        json.dumps({"generated_at": generated_at, "measurement": measurement, "results": rows}, indent=2)
        + "\n",
        encoding="utf-8",
    )


def run(
    input_paths: list[Path],
    output: Path,
    *,
    now: str = NOW,
    max_age: int = 86400,
    fallbacks: int = 2,
    allow_degraded: bool = False,
    future_skew: float = 300,
) -> tuple[int, dict]:
    cmd = [
        sys.executable,
        str(PLANNER),
        "--output",
        str(output),
        "--now",
        now,
        "--max-age-seconds",
        str(max_age),
        "--min-fallbacks",
        str(fallbacks),
        "--max-future-skew-seconds",
        str(future_skew),
    ]
    if allow_degraded:
        cmd.append("--allow-degraded")
    for path in input_paths:
        cmd += ["--input", str(path)]
    cp = subprocess.run(cmd, capture_output=True, text=True, check=False)
    if not output.exists():
        raise RuntimeError(f"planner did not write output (rc={cp.returncode}, stderr={cp.stderr})")
    return cp.returncode, json.loads(output.read_text(encoding="utf-8"))


def brief(plan: dict) -> str:
    repos = {
        repo: {
            "status": data.get("status"),
            "primary": data.get("primary"),
            "family": data.get("preferred_family"),
            "servers": len(data.get("servers", [])),
        }
        for repo, data in plan.get("repos", {}).items()
    }
    return json.dumps({"status": plan.get("status"), "applyable": plan.get("applyable"), "repos": repos}, sort_keys=True)


def check(checks: list[dict], name: str, condition: bool, evidence: str = "") -> None:
    checks.append({"name": name, "status": "PASS" if condition else "FAIL", "evidence": evidence[:500]})


def main() -> int:
    temp_root = LAB / "fixtures" / "tmp"
    temp_root.mkdir(parents=True, exist_ok=True)
    checks: list[dict] = []
    with tempfile.TemporaryDirectory(prefix="mirror-plan-", dir=temp_root) as raw:
        root = Path(raw)
        official = "https://mirror.example/archlinux"
        ustc = "https://ustc.example/archlinux"
        tsinghua = "https://tsinghua.example/archlinux"
        zju = "https://zju.example/archlinux"
        cn_aliyun = "https://mirror.example/archlinuxcn"
        cn_tencent = "https://tencent.example/archlinuxcn"
        cn_ustc = "https://ustc.example/archlinuxcn"
        cn_lzu = "https://lzu.example/archlinuxcn"
        rows_a = [
            row("official", official, 2.0),
            row("official", official, 20.0),  # median must reject this one-sample spike
            row("official", official, 2.0),
            row("official", ustc, 1.5),
            row("official", ustc, 1.4),
            row("official", tsinghua, 0.9),
            row("official", zju, 0, status="UNAVAILABLE", http_status="000"),
            row("archlinuxcn", cn_aliyun, 0.8),
            row("archlinuxcn", cn_aliyun, 0.9),
            row("archlinuxcn", cn_tencent, 0.5),
            row("archlinuxcn", cn_tencent, 0.4),
            row("archlinuxcn", cn_ustc, 0.3),
            row("archlinuxcn", cn_lzu, 0, status="UNAVAILABLE", http_status="000"),
        ]
        rows_b = [row("official", official, 2.1), row("archlinuxcn", cn_aliyun, 0.85)]
        first = root / "probe-a.json"
        second = root / "probe-b.json"
        write_input(first, rows_a)
        write_input(second, rows_b)
        output = root / "plan.json"
        rc, plan = run([first, second], output)
        check(checks, "valid repeated observations produce an OK plan", rc == 0 and plan["status"] == "ok" and plan["applyable"], brief(plan))
        check(checks, "official primary is the fastest stable median", plan["repos"]["official"]["primary"] == official, brief(plan))
        check(checks, "archlinuxcn primary is selected independently", plan["repos"]["archlinuxcn"]["primary"] == cn_aliyun, brief(plan))
        check(checks, "official server template is pacman-compatible", plan["repos"]["official"]["servers"][0]["server"] == f"{official}/$repo/os/$arch")
        check(checks, "archlinuxcn server template is pacman-compatible", plan["repos"]["archlinuxcn"]["servers"][0]["server"] == f"{cn_aliyun}/$arch")
        unavailable = plan["repos"]["official"]["unavailable_candidates"] + plan["repos"]["archlinuxcn"]["unavailable_candidates"]
        check(checks, "unavailable observations remain visible", any(item["base"] in {zju, cn_lzu} for item in unavailable))
        check(checks, "minimum fallback count is enforced", len(plan["repos"]["official"]["servers"]) >= 3 and len(plan["repos"]["archlinuxcn"]["servers"]) >= 3)
        check(checks, "raw diagnostic text is not copied", all("timeout/range unsupported" not in json.dumps(item) for item in unavailable))
        # The same fixed input and fixed --now must produce byte-equivalent JSON.
        second_output = root / "plan-again.json"
        rc_again, plan_again = run([first, second], second_output)
        check(checks, "same observations produce deterministic ordering", rc_again == 0 and plan == plan_again)

        stale = root / "stale.json"
        write_input(stale, [row("official", official, 2.0)], generated_at="2020-01-01T00:00:00+00:00")
        stale_rc, stale_plan = run([stale], root / "stale-plan.json", max_age=60)
        check(checks, "stale observations fail closed", stale_rc != 0 and stale_plan["status"] == "stale" and not stale_plan.get("repos"), brief(stale_plan))

        future = root / "future.json"
        write_input(future, [row("official", official, 2.0)], generated_at="2099-01-01T00:00:00+00:00")
        future_rc, future_plan = run([future], root / "future-plan.json", max_age=60)
        check(checks, "future observations fail closed", future_rc != 0 and future_plan["status"] == "future" and not future_plan.get("repos"), brief(future_plan))

        unavailable = root / "unavailable.json"
        write_input(unavailable, [row("official", zju, 0, status="UNAVAILABLE", http_status="000")])
        unavailable_rc, unavailable_plan = run([unavailable], root / "unavailable-plan.json", fallbacks=0)
        check(checks, "all mirrors unavailable never produce an empty success plan", unavailable_rc != 0 and unavailable_plan["status"] == "unavailable" and not unavailable_plan["repos"]["official"]["servers"], brief(unavailable_plan))

        degraded = root / "degraded.json"
        write_input(degraded, [row("official", official, 2.0)])
        degraded_rc, degraded_plan = run([degraded], root / "degraded-plan.json", fallbacks=2)
        degraded_allowed_rc, degraded_allowed_plan = run([degraded], root / "degraded-allowed-plan.json", fallbacks=2, allow_degraded=True)
        check(checks, "degraded plan is nonzero and non-applyable by default", degraded_rc != 0 and degraded_plan["status"] == "degraded" and not degraded_plan["applyable"], brief(degraded_plan))
        check(checks, "degraded plan requires explicit allow flag", degraded_allowed_rc == 0 and degraded_allowed_plan["status"] == "degraded" and not degraded_allowed_plan["applyable"], brief(degraded_allowed_plan))

        # Database and package throughput are not interchangeable.  The fast
        # database sample must not override the slower, package-representative
        # lane when both files are supplied.
        package_file = root / "package.json"
        database_file = root / "database.json"
        write_input(package_file, [row("official", official, 1.0), row("official", ustc, 2.0)])
        write_input(
            database_file,
            [row("official", official, 50.0), row("official", ustc, 0.5)],
            measurement="bounded HTTP range to /dev/null",
        )
        mixed_rc, mixed_plan = run([database_file, package_file], root / "mixed-plan.json", fallbacks=0)
        other = mixed_plan["repos"]["official"]["other_measurement_candidates"]
        check(checks, "package lane wins over database lane", mixed_rc == 0 and mixed_plan["repos"]["official"]["primary"] == ustc and mixed_plan["repos"]["official"]["preferred_family"] == "package", brief(mixed_plan))
        check(checks, "nonselected measurement is not mislabeled unavailable", not any(item["measurement_family"] == "database-range" for item in mixed_plan["repos"]["official"]["unavailable_candidates"]) and any(item["measurement_family"] == "database-range" for item in other))

        unsupported = root / "unsupported-range.json"
        write_input(
            unsupported,
            [
                row("official", official, 3.0, status="RANGE_UNSUPPORTED", http_status="200"),
                row("official", ustc, 2.0, status="RANGE_UNSUPPORTED", http_status="200"),
                row("official", tsinghua, 1.0, status="RANGE_UNSUPPORTED", http_status="200"),
            ],
        )
        unsupported_rc, unsupported_plan = run([unsupported], root / "unsupported-plan.json", fallbacks=2)
        check(checks, "Range-unsupported servers never satisfy fallback", unsupported_rc != 0 and unsupported_plan["status"] == "unavailable" and not unsupported_plan["repos"]["official"]["servers"], brief(unsupported_plan))
        check(
            checks,
            "Range support is represented as a separate failure state",
            all(
                observation["status"] == "RANGE_UNSUPPORTED"
                for item in unsupported_plan["repos"]["official"]["candidates"]
                for observation in item["observations"]
            ),
        )

        range_conflict = root / "range-conflict.json"
        write_input(
            range_conflict,
            [
                row(
                    "official",
                    official,
                    1.0,
                    status="RANGE_UNSUPPORTED",
                    http_status="206",
                    range_supported=True,
                )
            ],
        )
        range_conflict_rc, range_conflict_plan = run(
            [range_conflict], root / "range-conflict-plan.json", fallbacks=0
        )
        check(
            checks,
            "contradictory RANGE_UNSUPPORTED fields fail closed",
            range_conflict_rc != 0 and range_conflict_plan["status"] == "invalid",
            brief(range_conflict_plan),
        )

        numeric_range = root / "numeric-range.json"
        numeric_row = row("official", official, 1.0)
        numeric_row["range_supported"] = 0
        write_input(numeric_range, [numeric_row])
        numeric_range_rc, numeric_range_plan = run([numeric_range], root / "numeric-range-plan.json", fallbacks=0)
        check(checks, "numeric Range flag cannot bypass the boolean contract", numeric_range_rc != 0 and numeric_range_plan["status"] == "invalid", brief(numeric_range_plan))

        missing_range = root / "missing-range.json"
        missing_range_row = row("official", official, 1.0, status="RANGE_UNSUPPORTED", http_status="200")
        del missing_range_row["range_supported"]
        write_input(missing_range, [missing_range_row])
        missing_range_rc, missing_range_plan = run([missing_range], root / "missing-range-plan.json", fallbacks=0)
        check(checks, "explicit RANGE_UNSUPPORTED requires the complete probe schema", missing_range_rc != 0 and missing_range_plan["status"] == "invalid", brief(missing_range_plan))

        inconsistent_http = root / "inconsistent-http.json"
        write_input(inconsistent_http, [row("official", official, 1.0, http_status="500", exit_code=0)])
        inconsistent_http_rc, inconsistent_http_plan = run([inconsistent_http], root / "inconsistent-http-plan.json")
        check(checks, "successful probe with bad HTTP fails closed", inconsistent_http_rc != 0 and inconsistent_http_plan["status"] == "invalid", brief(inconsistent_http_plan))

        inconsistent_exit = root / "inconsistent-exit.json"
        write_input(inconsistent_exit, [row("official", official, 1.0, http_status="206", exit_code=28)])
        inconsistent_exit_rc, inconsistent_exit_plan = run([inconsistent_exit], root / "inconsistent-exit-plan.json")
        check(checks, "successful probe with nonzero exit fails closed", inconsistent_exit_rc != 0 and inconsistent_exit_plan["status"] == "invalid", brief(inconsistent_exit_plan))

        unsafe = root / "unsafe.json"
        unsafe_rows = [
            row("official", "https://user:secret@example.invalid/archlinux", 1.0),
        ]
        unsafe.write_text(json.dumps({"generated_at": NOW, "results": unsafe_rows}) + "\n", encoding="utf-8")
        unsafe_rc, unsafe_plan = run([unsafe], root / "unsafe-plan.json")
        check(checks, "mirror userinfo is rejected without disclosure", unsafe_rc != 0 and unsafe_plan["status"] == "invalid" and "secret" not in json.dumps(unsafe_plan), brief(unsafe_plan))

        for label, bad_base in {
            "control": "https://mirror.example/archlinux\nInclude = /tmp/extra",
            "query": "https://mirror.example/archlinux?x=1",
            "fragment": "https://mirror.example/archlinux#fragment",
            "malformed": "https://[malformed",
            "surrogate": "https://mirror.example/arch\ud800linux",
        }.items():
            bad = root / f"{label}.json"
            bad.write_text(json.dumps({"generated_at": NOW, "results": [row("official", bad_base, 1.0)]}) + "\n", encoding="utf-8")
            bad_rc, bad_plan = run([bad], root / f"{label}-plan.json")
            check(checks, f"{label} mirror URL fails closed", bad_rc != 0 and bad_plan["status"] == "invalid" and "Include =" not in json.dumps(bad_plan), brief(bad_plan))

        diagnostic = root / "diagnostic.json"
        diagnostic.write_text(
            json.dumps(
                {
                    "generated_at": NOW,
                    "measurement": "bounded package HTTP range",
                    "results": [
                        row("official", zju, 0, status="UNAVAILABLE", http_status="000", exit_code=28, error_tail="Bearer SECRET_TOKEN timeout")
                    ],
                }
            )
            + "\n",
            encoding="utf-8",
        )
        diagnostic_rc, diagnostic_plan = run([diagnostic], root / "diagnostic-plan.json", fallbacks=0)
        diagnostic_text = json.dumps(diagnostic_plan)
        check(checks, "diagnostics are reduced to a safe error class", diagnostic_rc != 0 and "SECRET_TOKEN" not in diagnostic_text and diagnostic_plan["repos"]["official"]["candidates"][0]["observations"][0]["error_class"] == "timeout")

        unknown = root / "unknown-repo.json"
        write_input(unknown, [row("custom", official, 1.0)])
        unknown_rc, unknown_plan = run([unknown], root / "unknown-repo-plan.json")
        check(checks, "unknown repository names are rejected", unknown_rc != 0 and unknown_plan["status"] == "invalid", brief(unknown_plan))

        bad_now = root / "bad-now.json"
        write_input(bad_now, [row("official", official, 1.0)])
        bad_now_rc, bad_now_plan = run([bad_now], root / "bad-now-plan.json", now="not-a-timestamp")
        check(checks, "invalid planner clock input writes an invalid report", bad_now_rc != 0 and bad_now_plan["status"] == "invalid", brief(bad_now_plan))

        nan_age_rc, nan_age_plan = run([first], root / "nan-age-plan.json", max_age=float("nan"))
        inf_skew_rc, inf_skew_plan = run([first], root / "inf-skew-plan.json", future_skew=float("inf"))
        check(checks, "non-finite age limits fail closed", nan_age_rc != 0 and nan_age_plan["status"] == "invalid" and inf_skew_rc != 0 and inf_skew_plan["status"] == "invalid")

        bad_utf8 = root / "bad-utf8.json"
        bad_utf8.write_bytes(b"{\"generated_at\": \"" + NOW.encode() + b"\", \"results\": []}\xff")
        bad_utf8_rc, bad_utf8_plan = run([bad_utf8], root / "bad-utf8-plan.json")
        check(checks, "invalid UTF-8 input writes an invalid report", bad_utf8_rc != 0 and bad_utf8_plan["status"] == "invalid", brief(bad_utf8_plan))

        huge_integer = root / "huge-integer.json"
        huge_integer.write_text(
            '{"generated_at": "' + NOW + '", "results": [], "unused": ' + ("1" * 5000) + "}\n",
            encoding="utf-8",
        )
        huge_integer_rc, huge_integer_plan = run([huge_integer], root / "huge-integer-plan.json")
        check(checks, "JSON integer conversion errors write an invalid report", huge_integer_rc != 0 and huge_integer_plan["status"] == "invalid", brief(huge_integer_plan))

        deep_json = root / "deep-json.json"
        deep_json.write_text('{"generated_at": "' + NOW + '", "results": ' + ("[" * 2000) + ("]" * 2000) + '}\n', encoding="utf-8")
        deep_json_rc, deep_json_plan = run([deep_json], root / "deep-json-plan.json")
        check(checks, "deep JSON recursion errors write an invalid report", deep_json_rc != 0 and deep_json_plan["status"] == "invalid", brief(deep_json_plan))

        overflow = root / "overflow.json"
        overflow_row = row("official", official, 1.0)
        overflow_row["seconds"] = 5e-324
        overflow_row["mib_per_second"] = 0
        write_input(overflow, [overflow_row])
        overflow_rc, overflow_plan = run([overflow], root / "overflow-plan.json", fallbacks=0)
        check(checks, "derived infinite throughput writes an invalid report", overflow_rc != 0 and overflow_plan["status"] == "invalid", brief(overflow_plan))

        boundary_now_rc, boundary_now_plan = run(
            [first], root / "boundary-now-plan.json", now="9999-12-31T23:59:59-14:00"
        )
        check(checks, "UTC conversion overflow writes an invalid report", boundary_now_rc != 0 and boundary_now_plan["status"] == "invalid", brief(boundary_now_plan))

        expiry = root / "expiry.json"
        expiry_now = "9999-12-31T23:59:59+00:00"
        write_input(expiry, [row("official", official, 1.0)], generated_at=expiry_now)
        expiry_rc, expiry_plan = run([expiry], root / "expiry-plan.json", now=expiry_now, max_age=60, fallbacks=0)
        check(checks, "expiration overflow writes an invalid report", expiry_rc != 0 and expiry_plan["status"] == "invalid", brief(expiry_plan))

        # Direct probe -> planner contract without network.  Patch curl's
        # CompletedProcess at the two real probe entry points rather than
        # reimplementing their status mapping in the test.
        class FakeCompleted:
            def __init__(self, returncode: int, http: str, size: int, seconds: float, stderr: str = "") -> None:
                self.returncode = returncode
                self.stdout = f"status={http}\ntotal={seconds}\nbytes={size}\n"
                self.stderr = stderr

        range_ns = runpy.run_path(str(LAB / "bin" / "probe-ranges.py"))
        package_ns = runpy.run_path(str(LAB / "bin" / "probe-package-ranges.py"))
        probe_shapes: list[tuple[dict, dict, str]] = []
        for expected, fake in [
            ("OK", FakeCompleted(0, "206", 1048576, 1.0)),
            ("RANGE_UNSUPPORTED", FakeCompleted(0, "200", 1048576, 1.0)),
            ("UNAVAILABLE", FakeCompleted(28, "000", 0, 4.0, "curl timeout")),
        ]:
            with patch.object(range_ns["subprocess"], "run", return_value=fake):
                range_row = range_ns["one"](("official", f"https://{expected.lower()}.range.example/archlinux"), 1048575, 4, 20)
            with patch.object(package_ns["subprocess"], "run", return_value=fake):
                package_row = package_ns["probe"](
                    ("official", f"https://{expected.lower()}.package.example/archlinux", "core/os/x86_64/example.pkg.tar.zst"),
                    1048575,
                    20,
                )
            probe_shapes.append((range_row, package_row, expected))
        check(
            checks,
            "range probe emits the strict 206/200/failure contract",
            all(
                range_row["status"] == expected
                and range_row["range_supported"] is (expected == "OK")
                and package_row["status"] == expected
                and package_row["range_supported"] is (expected == "OK")
                for range_row, package_row, expected in probe_shapes
            ),
        )
        contract_input = root / "probe-contract.json"
        write_input(contract_input, [package_row for _, package_row, _ in probe_shapes])
        contract_rc, contract_plan = run([contract_input], root / "probe-contract-plan.json", fallbacks=0)
        contract_servers = contract_plan["repos"]["official"]["servers"]
        check(
            checks,
            "real probe rows feed planner without re-enabling unsupported/failure rows",
            contract_rc == 0
            and len(contract_servers) == 1
            and contract_servers[0]["base"] == "https://ok.package.example/archlinux",
            brief(contract_plan),
        )

        summary = {
            "schema": 2,
            "test": "mirror-plan-test",
            "passed": all(item["status"] == "PASS" for item in checks),
            "checks": checks,
        }
        RESULT.parent.mkdir(parents=True, exist_ok=True)
        RESULT.write_text(json.dumps(summary, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        print(json.dumps({"passed": summary["passed"], "checks": len(checks)}, ensure_ascii=False))
        if not summary["passed"]:
            for item in checks:
                if item["status"] != "PASS":
                    print(f"FAIL: {item['name']}: {item['evidence']}", file=sys.stderr)
            return 1
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
