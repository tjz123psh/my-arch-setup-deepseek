#!/usr/bin/env python3
"""Build a reviewable, per-repository mirror plan from probe observations.

This is deliberately a *planner*, not an installer.  It reads JSON produced by
probe-mirrors/probe-ranges/probe-package-ranges, aggregates repeated samples,
keeps unavailable observations visible, and writes a plan to a caller-selected
path.  It never edits pacman.conf or /etc/pacman.d/mirrorlist.

Only observations from the same measurement lane are aggregated.  Package
Range measurements are preferred over repository-database Range measurements,
which are preferred over generic throughput and HEAD latency.  This prevents a
fast database response from making a slow package mirror look healthy.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timedelta, timezone
import json
import math
from pathlib import Path
import re
import statistics
import tempfile
from typing import Any
from urllib.parse import urlsplit


class PlanError(Exception):
    """Input data cannot safely produce a mirror plan."""


KNOWN_REPOS = frozenset({"official", "archlinuxcn"})
FAMILY_PRIORITY = {
    "package": 4,
    "database-range": 3,
    "throughput": 2,
    "latency": 1,
}
DEFAULT_FUTURE_SKEW_SECONDS = 300.0
MAX_AGE_SECONDS = 7 * 24 * 60 * 60
MAX_FUTURE_SKEW_SECONDS = 24 * 60 * 60
_MAX_ERROR_CLASS_INPUT = 512


def _safe_path_label(path: Path) -> str:
    text = str(path)
    try:
        text.encode("utf-8", errors="strict")
    except UnicodeError:
        return "<input>"
    return text


def _parse_time(value: Any) -> datetime:
    if not isinstance(value, str) or not value:
        raise PlanError("missing or invalid generated_at")
    # Only a terminal Z is an ISO-8601 UTC marker.  Replacing every Z would
    # silently corrupt an otherwise malformed timestamp.
    normalized = value[:-1] + "+00:00" if value.endswith("Z") else value
    try:
        parsed = datetime.fromisoformat(normalized)
    except (TypeError, ValueError, OverflowError) as exc:
        raise PlanError("invalid generated_at") from exc
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    try:
        return parsed.astimezone(timezone.utc)
    except (OverflowError, OSError, ValueError) as exc:
        raise PlanError("invalid generated_at") from exc


def _safe_base(value: Any) -> str:
    """Return a pacman-safe mirror base, never echoing an unsafe URL."""
    if not isinstance(value, str) or not value:
        raise PlanError("invalid mirror base")
    try:
        value.encode("utf-8", errors="strict")
    except UnicodeError as exc:
        raise PlanError("mirror base is not valid UTF-8") from exc
    # Mirror bases are later rendered as one line in a pacman configuration.
    # Reject all whitespace/control/config-significant characters before URL
    # parsing; urlsplit() otherwise strips some newlines silently.
    if any(ch.isspace() or ord(ch) < 0x20 or ord(ch) == 0x7F for ch in value):
        raise PlanError("mirror base contains whitespace or control characters")
    if any(ch in value for ch in ('"', "'", "\\", "$")):
        raise PlanError("mirror base contains a forbidden configuration character")
    if not value.startswith(("http://", "https://")):
        raise PlanError("mirror base must use http or https")
    try:
        parts = urlsplit(value)
        # Accessing .port forces validation of malformed numeric ports.
        _ = parts.port
        hostname = parts.hostname
    except ValueError as exc:
        raise PlanError("malformed mirror URL") from exc
    if parts.scheme not in {"http", "https"} or not hostname:
        raise PlanError("mirror URL has no valid host")
    if parts.username is not None or parts.password is not None:
        raise PlanError("mirror URL userinfo is not allowed")
    if parts.query or parts.fragment:
        raise PlanError("mirror URL query and fragment are not allowed")
    return value.rstrip("/")


def _number(row: dict[str, Any], *keys: str) -> float | None:
    for key in keys:
        value = row.get(key)
        if value in (None, ""):
            continue
        try:
            number = float(value)
        except (TypeError, ValueError, OverflowError):
            continue
        if math.isfinite(number) and number >= 0:
            return number
    return None


def _exit_code(row: dict[str, Any]) -> int | None:
    value = row.get("exit_code")
    if value in (None, ""):
        return None
    try:
        number = float(value)
    except (TypeError, ValueError, OverflowError) as exc:
        raise PlanError("invalid probe exit code") from exc
    if not math.isfinite(number) or not number.is_integer() or abs(number) > 255:
        raise PlanError("invalid probe exit code")
    return int(number)


def _int_number(row: dict[str, Any], *keys: str) -> int:
    value = _number(row, *keys)
    return int(value or 0)


def _http_status(row: dict[str, Any]) -> str:
    value = row.get("http_status", "")
    if value in (None, ""):
        return ""
    status = str(value).strip()
    if not re.fullmatch(r"\d{3}", status):
        raise PlanError("invalid HTTP status")
    return status


def _measurement_family(measurement: Any, row: dict[str, Any] | None = None) -> str:
    """Map probe descriptions to a small, non-sensitive aggregation lane."""
    text = measurement.casefold() if isinstance(measurement, str) else ""
    row = row or {}
    relative = row.get("relative")
    relative_text = relative.casefold() if isinstance(relative, str) else ""
    # The HEAD probe description contains the word "package" in its note
    # ("no package ... installation"), so detect the latency lane first.
    if "head" in text:
        return "latency"
    if "package" in text or ".pkg.tar" in relative_text:
        return "package"
    if "range" in text:
        return "database-range"
    if _number(row, "mib_per_second") is not None or _int_number(row, "bytes", "size_bytes") > 0:
        return "throughput"
    return "latency"


def _load_file(path: Path) -> tuple[datetime, list[dict[str, Any]], str]:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, ValueError, RecursionError) as exc:
        raise PlanError(f"cannot read JSON input {type(exc).__name__}") from exc
    if isinstance(payload, dict):
        generated = _parse_time(payload.get("generated_at", ""))
        rows = payload.get("results")
        measurement = payload.get("measurement", "")
    elif isinstance(payload, list):
        # A list is accepted for small hand-built/repeated fixtures, but it
        # must carry generated_at on every row so freshness remains auditable.
        rows = payload
        timestamps = {
            _parse_time(row.get("generated_at", ""))
            for row in rows
            if isinstance(row, dict)
        }
        if not timestamps:
            raise PlanError("list input has no generated_at")
        if len(timestamps) != 1:
            raise PlanError("list input has mixed generated_at values")
        generated = timestamps.pop()
        measurement = ""
    else:
        raise PlanError("input must be an object or array")
    if not isinstance(rows, list):
        raise PlanError("input has no results array")
    normalized: list[dict[str, Any]] = []
    families: set[str] = set()
    for index, raw in enumerate(rows):
        if not isinstance(raw, dict):
            raise PlanError(f"input row {index} is not an object")
        row = dict(raw)
        family = _measurement_family(row.get("measurement", measurement), row)
        row["_measurement_family"] = family
        row["_source_file"] = _safe_path_label(path)
        families.add(family)
        normalized.append(row)
    file_family = next(iter(families)) if len(families) == 1 else "mixed"
    return generated, normalized, file_family


def _seconds(row: dict[str, Any]) -> float | None:
    return _number(row, "seconds", "total_seconds", "connect_seconds")


def _throughput(row: dict[str, Any]) -> float | None:
    direct = _number(row, "mib_per_second")
    if direct is not None and direct > 0:
        return direct
    size = _int_number(row, "bytes", "size_bytes")
    seconds = _seconds(row)
    if size > 0 and seconds and seconds > 0:
        value = size / 1048576 / seconds
        if not math.isfinite(value) or value <= 0:
            raise PlanError("derived throughput is not finite")
        return value
    return None


def _range_supported(row: dict[str, Any]) -> bool | None:
    if "range_supported" in row:
        value = row["range_supported"]
        if isinstance(value, bool):
            return value
        if isinstance(value, str) and value:
            normalized = value.casefold()
            if normalized in {"true", "yes", "1", "206"}:
                return True
            if normalized in {"false", "no", "0", "200"}:
                return False
        # Numeric 0/1 and all other representations are rejected instead of
        # silently falling back to the HTTP code.  JSON booleans are required.
        raise PlanError("invalid range support flag")
    http = _http_status(row)
    return http == "206" if http else None


def _safe_error_class(
    status: str,
    http_status: str,
    exit_code: int | None,
    raw_tail: Any,
    family: str,
) -> str:
    """Return a bounded diagnostic category, never the raw stderr text."""
    tail = str(raw_tail or "")[:_MAX_ERROR_CLASS_INPUT].casefold()
    if status == "RANGE_UNSUPPORTED" or (
        family in {"package", "database-range"} and http_status == "200"
    ):
        return "range_unsupported"
    if exit_code == 28 or "timeout" in tail or "timed out" in tail:
        return "timeout"
    if http_status.isdigit() and int(http_status) >= 400:
        return f"http_{http_status}"
    if exit_code not in (None, 0):
        return f"probe_exit_{abs(exit_code)}"
    if status != "OK":
        return "probe_failed"
    return ""


def _normalize_observation(row: dict[str, Any], family: str) -> dict[str, Any]:
    repo = row.get("repo")
    if not isinstance(repo, str) or repo not in KNOWN_REPOS:
        raise PlanError("unsupported repository")
    base = _safe_base(row.get("base"))
    status = str(row.get("status", "UNAVAILABLE")).strip().upper()
    if status not in {"OK", "UNAVAILABLE", "RANGE_UNSUPPORTED"}:
        raise PlanError("unsupported probe status")
    http_status = _http_status(row)
    exit_code = _exit_code(row)
    seconds = _seconds(row)
    throughput = _throughput(row)
    range_supported = _range_supported(row)
    is_range_lane = family in {"package", "database-range"}

    # Validate successful rows instead of trusting a caller-controlled status
    # string.  HTTP 200 on a range probe is accepted as a legacy spelling of
    # RANGE_UNSUPPORTED; it is never eligible for health scoring.
    range_field_present = "range_supported" in row
    if status == "OK":
        if exit_code not in (None, 0):
            raise PlanError("successful probe has a nonzero exit code")
        if family == "latency":
            if http_status and http_status != "200":
                raise PlanError("successful latency probe has an unexpected HTTP status")
            if seconds is None or seconds <= 0:
                raise PlanError("successful latency probe has no positive duration")
        else:
            if seconds is None or seconds <= 0 or throughput is None or throughput <= 0:
                raise PlanError("successful throughput probe has incomplete metrics")
            if is_range_lane:
                if exit_code != 0 or http_status not in {"200", "206"}:
                    raise PlanError("range probe has incomplete success fields")
                if http_status == "206":
                    if range_supported is not True:
                        raise PlanError("HTTP 206 probe does not claim Range support")
                else:
                    # Legacy probe snapshots used status=OK for HTTP 200.  They
                    # remain reviewable as RANGE_UNSUPPORTED, never as healthy.
                    if range_field_present and range_supported is not False:
                        raise PlanError("HTTP 200 probe has contradictory Range support")
                    status = "RANGE_UNSUPPORTED"
            elif http_status and http_status not in {"200", "206"}:
                raise PlanError("successful throughput probe has an unexpected HTTP status")
    elif status == "RANGE_UNSUPPORTED":
        if not is_range_lane:
            raise PlanError("range-unsupported status on a non-range probe")
        if exit_code != 0 or http_status != "200" or not range_field_present or range_supported is not False:
            raise PlanError("range-unsupported probe has incomplete or contradictory fields")
    elif status == "UNAVAILABLE":
        # A row that says failure while simultaneously claiming a successful
        # request is contradictory; reject it rather than allowing forged speed
        # data into a plan.  Missing exit/http fields remain valid failure data.
        if exit_code == 0 and http_status in {"200", "206"}:
            raise PlanError("unavailable probe has successful status fields")

    return {
        "repo": repo,
        "base": base,
        "status": status,
        "kind": "latency" if family == "latency" else "throughput",
        "measurement_family": family,
        "seconds": seconds,
        "throughput_mib_s": throughput,
        "range_supported": range_supported if is_range_lane else None,
        "http_status": http_status,
        "exit_code": exit_code,
        "error_class": _safe_error_class(status, http_status, exit_code, row.get("error_tail"), family),
        "source_file": str(row.get("_source_file", "<input>")),
    }



def _validate_payload(payload: dict[str, Any]) -> None:
    """Guarantee strict JSON and UTF-8 serialization before replacing output."""
    try:
        json.dumps(payload, ensure_ascii=False, sort_keys=True, allow_nan=False).encode(
            "utf-8", errors="strict"
        )
    except (TypeError, ValueError, UnicodeError, OverflowError) as exc:
        raise PlanError("plan payload is not safely serializable") from exc

def _atomic_write(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temp_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with open(fd, "w", encoding="utf-8", closefd=True) as stream:
            json.dump(payload, stream, ensure_ascii=False, indent=2, sort_keys=True, allow_nan=False)
            stream.write("\n")
            stream.flush()
        Path(temp_name).replace(path)
    finally:
        try:
            Path(temp_name).unlink()
        except FileNotFoundError:
            pass


def _failure_report(error: str, *, status: str = "invalid", **extra: Any) -> dict[str, Any]:
    report: dict[str, Any] = {
        "schema": 1,
        "status": status,
        "applyable": False,
        "error": error,
        "repos": {},
    }
    report.update(extra)
    return report


def _candidate(repo: str, base: str, family: str, rows: list[dict[str, Any]]) -> dict[str, Any]:
    total = len(rows)
    kind = "latency" if family == "latency" else "throughput"
    requires_range = family in {"package", "database-range"}
    if kind == "throughput":
        # `measured` counts successful byte measurements even when a server
        # ignored Range.  `valid` is the subset safe for the selected lane.
        # Keeping the two denominators separate makes the documented score
        # (throughput × availability × range support) auditable.
        measured = [
            row
            for row in rows
            if row["status"] in {"OK", "RANGE_UNSUPPORTED"}
            and row["seconds"] is not None
            and row["seconds"] > 0
            and row["throughput_mib_s"] is not None
            and row["throughput_mib_s"] > 0
        ]
        valid = [
            row
            for row in measured
            if row["status"] == "OK"
            and (not requires_range or row["range_supported"] is True)
        ]
        values = [row["throughput_mib_s"] for row in valid]
        median_value = statistics.median(values) if values else 0.0
        availability = len(measured) / total if total else 0.0
        range_ratio = len(valid) / len(measured) if requires_range and measured else None
        score = median_value * availability
        if range_ratio is not None:
            score *= range_ratio
        metric = "median_throughput_mib_s"
    else:
        valid = [
            row
            for row in rows
            if row["status"] == "OK"
            and row["seconds"] is not None
            and row["seconds"] > 0
        ]
        values = [row["seconds"] for row in valid]
        median_value = statistics.median(values) if values else 0.0
        availability = len(valid) / total if total else 0.0
        range_ratio = None
        try:
            score = (1 / median_value * availability) if median_value else 0.0
        except (OverflowError, ZeroDivisionError) as exc:
            raise PlanError("latency score is not finite") from exc
        metric = "inverse_median_latency"
    if not all(math.isfinite(value) for value in (median_value, availability, score)):
        raise PlanError("candidate metric is not finite")
    if range_ratio is not None and not math.isfinite(range_ratio):
        raise PlanError("candidate Range ratio is not finite")
    return {
        "base": base,
        "server": _server_template(repo, base),
        "kind": kind,
        "measurement_family": family,
        "score": round(score, 6),
        "metric_value": round(median_value, 6),
        "availability": round(availability, 6),
        "range_support": round(range_ratio, 6) if range_ratio is not None else None,
        "sample_count": total,
        "valid_count": len(valid),
        "metric": metric,
        "observations": [
            {
                "status": row["status"],
                "http_status": row["http_status"],
                "exit_code": row["exit_code"],
                "seconds": row["seconds"],
                "throughput_mib_s": row["throughput_mib_s"],
                "range_supported": row["range_supported"],
                "error_class": row["error_class"],
                "measurement_family": row["measurement_family"],
                "source_file": row["source_file"],
            }
            for row in rows
        ],
    }


def _server_template(repo: str, base: str) -> str:
    if repo == "archlinuxcn":
        return f"{base}/$arch"
    return f"{base}/$repo/os/$arch"


def build_plan(
    inputs: list[Path],
    *,
    now: datetime,
    max_age_seconds: float,
    min_fallbacks: int,
    max_future_skew_seconds: float = DEFAULT_FUTURE_SKEW_SECONDS,
) -> dict[str, Any]:
    if (
        not math.isfinite(max_age_seconds)
        or max_age_seconds <= 0
        or max_age_seconds > MAX_AGE_SECONDS
        or not math.isfinite(max_future_skew_seconds)
        or max_future_skew_seconds < 0
        or max_future_skew_seconds > MAX_FUTURE_SKEW_SECONDS
        or min_fallbacks < 0
    ):
        raise PlanError("invalid planner age or fallback limits")
    if not isinstance(now, datetime):
        raise PlanError("invalid planner clock")
    try:
        if now.tzinfo is None:
            now = now.replace(tzinfo=timezone.utc)
        else:
            now = now.astimezone(timezone.utc)
    except (OverflowError, OSError, ValueError) as exc:
        raise PlanError("invalid planner clock") from exc
    observations: list[dict[str, Any]] = []
    input_meta: list[dict[str, Any]] = []
    stale_inputs: list[str] = []
    future_inputs: list[str] = []
    errors: list[str] = []

    for path in inputs:
        path_label = _safe_path_label(path)
        generated, rows, file_family = _load_file(path)
        age = (now - generated).total_seconds()
        if age > max_age_seconds:
            stale_inputs.append(path_label)
        elif age < -max_future_skew_seconds:
            future_inputs.append(path_label)
        input_meta.append(
            {
                "path": path_label,
                "generated_at": generated.isoformat(),
                "age_seconds": round(age, 3),
                "measurement_family": file_family,
            }
        )
        for row in rows:
            try:
                observations.append(_normalize_observation(row, row["_measurement_family"]))
            except PlanError as exc:
                errors.append(f"{path_label}: {exc}")

    if errors:
        return _failure_report(
            "one or more probe rows are invalid; refusing to build a plan",
            errors=errors,
            inputs=input_meta,
            stale_inputs=stale_inputs,
            future_inputs=future_inputs,
        )
    if future_inputs:
        return _failure_report(
            "one or more probe inputs are from the future; refusing to build a plan",
            status="future",
            inputs=input_meta,
            stale_inputs=stale_inputs,
            future_inputs=future_inputs,
        )
    if stale_inputs:
        return _failure_report(
            "one or more probe inputs exceeded max-age; refusing to apply a stale plan",
            status="stale",
            inputs=input_meta,
            stale_inputs=stale_inputs,
            future_inputs=future_inputs,
        )
    if not observations:
        return _failure_report("no probe observations")

    grouped: dict[tuple[str, str, str], list[dict[str, Any]]] = {}
    for observation in observations:
        key = (
            observation["repo"],
            observation["base"],
            observation["measurement_family"],
        )
        grouped.setdefault(key, []).append(observation)

    repos: dict[str, dict[str, Any]] = {}
    for (repo, base, family), rows in grouped.items():
        repos.setdefault(repo, {"candidates": []})["candidates"].append(
            _candidate(repo, base, family, rows)
        )

    output_repos: dict[str, Any] = {}
    degraded = False
    unavailable = False
    for repo, data in sorted(repos.items()):
        candidates = data["candidates"]
        candidates.sort(key=lambda item: (-FAMILY_PRIORITY[item["measurement_family"]], item["base"]))
        preferred_family = None
        for family in sorted(FAMILY_PRIORITY, key=FAMILY_PRIORITY.get, reverse=True):
            if any(item["measurement_family"] == family and item["valid_count"] for item in candidates):
                preferred_family = family
                break
        if preferred_family is None:
            unavailable = True
            output_repos[repo] = {
                "status": "unavailable",
                "servers": [],
                "preferred_family": None,
                "candidates": candidates,
            }
            continue
        selected = [
            item
            for item in candidates
            if item["measurement_family"] == preferred_family and item["valid_count"]
        ]
        selected.sort(key=lambda item: (-item["score"], -item["metric_value"], item["base"]))
        repo_status = "ok" if len(selected) >= min_fallbacks + 1 else "degraded"
        degraded = degraded or repo_status == "degraded"
        output_repos[repo] = {
            "status": repo_status,
            "preferred_family": preferred_family,
            "metric": selected[0]["metric"],
            "primary": selected[0]["base"],
            "servers": selected,
            # Only candidates in the selected lane belong in this list.  A
            # latency/database observation rejected in favor of package data is
            # not an unavailable mirror and must not be mislabelled as one.
            "unavailable_candidates": [
                item
                for item in candidates
                if item["measurement_family"] == preferred_family and not item["valid_count"]
            ],
            "other_measurement_candidates": [
                item
                for item in candidates
                if item["measurement_family"] != preferred_family
            ],
        }

    status = "unavailable" if unavailable else ("degraded" if degraded else "ok")
    try:
        expires_at = (now + timedelta(seconds=max_age_seconds)).isoformat()
    except (OverflowError, OSError, ValueError) as exc:
        raise PlanError("planner expiration is out of range") from exc
    return {
        "schema": 1,
        "status": status,
        "applyable": status == "ok",
        "generated_at": now.isoformat(),
        "expires_at": expires_at,
        "max_age_seconds": max_age_seconds,
        "max_future_skew_seconds": max_future_skew_seconds,
        "min_fallbacks": min_fallbacks,
        "selection_policy": "package > database-range > throughput > latency; lanes are never mixed",
        "inputs": input_meta,
        "stale_inputs": stale_inputs,
        "future_inputs": future_inputs,
        "repos": output_repos,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", action="append", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--max-age-seconds", type=float, default=86400.0)
    parser.add_argument("--max-future-skew-seconds", type=float, default=DEFAULT_FUTURE_SKEW_SECONDS)
    parser.add_argument("--min-fallbacks", type=int, default=2)
    parser.add_argument("--allow-degraded", action="store_true", help="return zero for a review-only degraded plan")
    parser.add_argument("--now", help="UTC ISO timestamp, useful for deterministic tests")
    args = parser.parse_args(argv)
    try:
        if (
            not math.isfinite(args.max_age_seconds)
            or args.max_age_seconds <= 0
            or args.max_age_seconds > MAX_AGE_SECONDS
            or not math.isfinite(args.max_future_skew_seconds)
            or args.max_future_skew_seconds < 0
            or args.max_future_skew_seconds > MAX_FUTURE_SKEW_SECONDS
            or args.min_fallbacks < 0
        ):
            raise PlanError("invalid planner age or fallback limits")
        now = _parse_time(args.now) if args.now else datetime.now(timezone.utc)
        plan = build_plan(
            args.input,
            now=now,
            max_age_seconds=args.max_age_seconds,
            min_fallbacks=args.min_fallbacks,
            max_future_skew_seconds=args.max_future_skew_seconds,
        )
    except PlanError as exc:
        plan = _failure_report(str(exc))
    try:
        _validate_payload(plan)
    except PlanError as exc:
        plan = _failure_report(str(exc))
        _validate_payload(plan)
    _atomic_write(args.output, plan)
    print(
        json.dumps(
            {"status": plan.get("status"), "applyable": plan.get("applyable", False), "repos": sorted(plan.get("repos", {}))},
            ensure_ascii=False,
        )
    )
    if plan.get("status") == "ok":
        return 0
    if plan.get("status") == "degraded" and args.allow_degraded:
        return 0
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
