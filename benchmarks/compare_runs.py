#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import shutil
import tempfile
import zipfile
from pathlib import Path
from typing import Any

from acceptance import build as build_acceptance
from status import build as build_status, metadata


def load_json(path: Path) -> dict[str, Any]:
    try:
        raw = json.loads(path.read_text())
        return raw if isinstance(raw, dict) else {}
    except Exception:
        return {}


def safe_extract(archive: Path, dest: Path) -> None:
    root = dest.resolve()
    with zipfile.ZipFile(archive) as zf:
        for info in zf.infolist():
            target = (dest / info.filename).resolve()
            if target != root and root not in target.parents:
                raise ValueError(f"unsafe zip member: {info.filename}")
        zf.extractall(dest)


def find_run_root(root: Path) -> Path:
    markers = ("run-metadata.txt", "full-suite/benchmark-report.json", "benchmark-status.json")
    candidates = [root]
    candidates.extend(p for p in root.rglob("*") if p.is_dir())
    for candidate in sorted(candidates, key=lambda p: len(p.parts)):
        if any((candidate / marker).exists() for marker in markers):
            return candidate
    raise ValueError(f"cannot find benchmark run root under {root}")


def open_input(path: Path, temp_root: Path) -> Path:
    if path.is_dir():
        return find_run_root(path.resolve())
    if path.is_file() and zipfile.is_zipfile(path):
        dest = temp_root / f"zip-{len(list(temp_root.iterdir()))}"
        dest.mkdir(parents=True)
        safe_extract(path.resolve(), dest)
        return find_run_root(dest)
    raise ValueError(f"unsupported benchmark input: {path}")


def choose_workload(report: dict[str, Any]) -> dict[str, Any]:
    rows = report.get("results") if isinstance(report.get("results"), list) else []
    dict_rows = [r for r in rows if isinstance(r, dict)]
    for row in dict_rows:
        if row.get("points") == 100000 and row.get("dimension") == 768:
            return row
    if dict_rows:
        return max(dict_rows, key=lambda r: (int(r.get("points") or 0), int(r.get("dimension") or 0)))
    return {}


def build_row(run_dir: Path, label: str) -> dict[str, Any]:
    meta = metadata(run_dir / "run-metadata.txt")
    status = load_json(run_dir / "benchmark-status.json") or build_status(run_dir)
    acceptance = load_json(run_dir / "benchmark-acceptance.json") or build_acceptance(run_dir)
    report = load_json(run_dir / "full-suite" / "benchmark-report.json")
    workload = choose_workload(report)
    monitor = load_json(run_dir / "resource-monitor-summary.json")
    runtime = report.get("runtime") if isinstance(report.get("runtime"), dict) else {}
    host = report.get("host") if isinstance(report.get("host"), dict) else {}
    platform = meta.get("platform") or host.get("platform_detected") or "unknown"
    profile = meta.get("resource_profile") or meta.get("profile") or runtime.get("profile") or "unknown"
    eligible = bool(status.get("ready_for_ranking")) and bool(acceptance.get("accepted_for_comparison"))
    return {
        "input": label,
        "run_dir": str(run_dir),
        "platform": platform,
        "profile": profile,
        "memory_total_mb": _number(meta.get("memory_total_mb") or host.get("memory_total_mb")),
        "memory_effective_mb": _number(meta.get("memory_effective_mb")),
        "overall_status": status.get("overall_status", "UNKNOWN"),
        "source_integrity": status.get("source_integrity", "UNKNOWN"),
        "comparability": status.get("comparability", "UNVERIFIED"),
        "acceptance_verdict": acceptance.get("verdict", "UNKNOWN"),
        "eligible_for_ranking": eligible,
        "points": workload.get("points"),
        "dimension": workload.get("dimension"),
        "cold_p50_ms": workload.get("cold_p50_ms"),
        "cold_p95_ms": workload.get("cold_p95_ms"),
        "warm_p50_ms": workload.get("warm_p50_ms"),
        "warm_p95_ms": workload.get("warm_p95_ms"),
        "http_ingestion_points_per_second": workload.get("http_ingestion_points_per_second_median"),
        "benchmark_qdrant_peak_rss_mb": _div(workload.get("qdrant_peak_sampled_rss_kb"), 1024),
        "benchmark_min_available_memory_mb": workload.get("minimum_available_memory_mb"),
        "monitor_qdrant_peak_rss_mb": monitor.get("maximum_qdrant_rss_mb"),
        "monitor_min_available_memory_mb": monitor.get("minimum_mem_available_mb"),
        "monitor_telemetry_continuity": monitor.get("telemetry_continuity"),
        "monitor_sample_gap_events": monitor.get("sample_gap_events"),
        "monitor_maximum_sample_gap_seconds": monitor.get("maximum_sample_gap_seconds"),
        "monitor_missing_seconds": monitor.get("missing_monitor_seconds"),
        "monitor_host_pause_or_stall_suspected": monitor.get("host_pause_or_monitor_stall_suspected"),
        "monitor_swap_at_start_mb": monitor.get("swap_at_start_mb"),
        "monitor_max_swap_used_mb": monitor.get("maximum_swap_used_mb"),
        "monitor_swap_growth_mb": monitor.get("swap_growth_mb"),
        "monitor_pressure_samples": monitor.get("pressure_samples"),
        "monitor_pressure_event_count": monitor.get("pressure_event_count"),
        "monitor_qdrant_zombies_at_start": monitor.get("qdrant_zombies_at_start"),
        "monitor_qdrant_zombies_at_end": monitor.get("qdrant_zombies_at_end"),
        "monitor_max_qdrant_zombies": monitor.get("maximum_qdrant_zombie_processes"),
        "monitor_qdrant_zombie_growth": monitor.get("qdrant_zombie_growth"),
    }


def _number(value: Any) -> float | int | None:
    if value is None or value == "":
        return None
    try:
        v = float(value)
        return int(v) if v.is_integer() else v
    except (TypeError, ValueError):
        return None


def _div(value: Any, divisor: float) -> float | None:
    n = _number(value)
    return round(float(n) / divisor, 3) if n is not None else None


def sort_key(row: dict[str, Any]) -> tuple[float, float]:
    cold = _number(row.get("cold_p50_ms"))
    warm = _number(row.get("warm_p50_ms"))
    return (float("inf") if cold is None else float(cold), float("inf") if warm is None else float(warm))


def markdown(result: dict[str, Any]) -> str:
    lines = [
        "# Cross-host benchmark comparison",
        "",
        "Only runs accepted as clean comparable baselines are ranked.",
        "",
        "| Eligible | Platform | Profile | Status | Comparability | Cold p50 ms | Cold p95 ms | Warm p50 ms | HTTP ingest pts/s | Monitor min RAM MB | Monitor peak Qdrant MB | Continuity | Max gap s | Missing s | Swap start/max/growth MB | Pressure samples/events | Zombies start/max/growth |",
        "|:---:|---|---|---|---|---:|---:|---:|---:|---:|---:|---|---:|---:|---|---|---:|",
    ]
    for r in result["runs"]:
        lines.append("| {eligible} | {platform} | {profile} | {status} | {comp} | {cold} | {cold95} | {warm} | {ingest} | {mem} | {rss} | {continuity} | {max_gap} | {missing} | {swap_start}/{swap_max}/{swap_growth} | {pressure}/{pressure_events} | {zombie_start}/{zombies}/{zombie_growth} |".format(
            eligible="yes" if r["eligible_for_ranking"] else "no",
            platform=r["platform"], profile=r["profile"], status=r["overall_status"], comp=r["comparability"],
            cold=_fmt(r["cold_p50_ms"]), cold95=_fmt(r["cold_p95_ms"]), warm=_fmt(r["warm_p50_ms"]),
            ingest=_fmt(r["http_ingestion_points_per_second"]), mem=_fmt(r["monitor_min_available_memory_mb"]),
            rss=_fmt(r["monitor_qdrant_peak_rss_mb"]), continuity=r["monitor_telemetry_continuity"] or "unknown",
            max_gap=_fmt(r["monitor_maximum_sample_gap_seconds"]), missing=_fmt(r["monitor_missing_seconds"]),
            swap_start=_fmt(r["monitor_swap_at_start_mb"]), swap_max=_fmt(r["monitor_max_swap_used_mb"]),
            swap_growth=_fmt(r["monitor_swap_growth_mb"]), pressure=_fmt(r["monitor_pressure_samples"]),
            pressure_events=_fmt(r["monitor_pressure_event_count"]),
            zombie_start=_fmt(r["monitor_qdrant_zombies_at_start"]), zombies=_fmt(r["monitor_max_qdrant_zombies"]),
            zombie_growth=_fmt(r["monitor_qdrant_zombie_growth"])))
    excluded = [r for r in result["runs"] if not r["eligible_for_ranking"]]
    if excluded:
        lines += ["", "## Excluded from ranking", ""]
        for r in excluded:
            lines.append(f"- `{r['platform']}` / `{r['profile']}`: status={r['overall_status']}, comparability={r['comparability']}, acceptance={r['acceptance_verdict']}")
    if result["ranking"]:
        lines += ["", "## Comparable ranking by cold p50", ""]
        for idx, r in enumerate(result["ranking"], 1):
            lines.append(f"{idx}. `{r['platform']}` / `{r['profile']}` — cold p50 `{_fmt(r['cold_p50_ms'])} ms`, warm p50 `{_fmt(r['warm_p50_ms'])} ms`")
    lines.append("")
    return "\n".join(lines)


def _fmt(value: Any) -> str:
    if value is None:
        return "n/a"
    if isinstance(value, float):
        return f"{value:.3f}".rstrip("0").rstrip(".")
    return str(value)


def main() -> int:
    p = argparse.ArgumentParser(description="Compare multiple Qdrant benchmark run directories or ZIP artifacts")
    p.add_argument("inputs", nargs="+")
    p.add_argument("--json-output")
    p.add_argument("--markdown-output")
    p.add_argument("--require-comparable", type=int, default=0, metavar="N")
    a = p.parse_args()
    with tempfile.TemporaryDirectory(prefix="qdrant-compare-") as td:
        temp_root = Path(td)
        rows = [build_row(open_input(Path(value), temp_root), value) for value in a.inputs]
        eligible = [r for r in rows if r["eligible_for_ranking"]]
        ranking = sorted(eligible, key=sort_key)
        result = {
            "schema_version": 2,
            "runs": rows,
            "eligible_runs": eligible,
            "ranking": ranking,
        }
        text = json.dumps(result, indent=2) + "\n"
        if a.json_output:
            Path(a.json_output).write_text(text)
        else:
            print(text, end="")
        if a.markdown_output:
            Path(a.markdown_output).write_text(markdown(result))
        if a.require_comparable and len(eligible) < a.require_comparable:
            return 6
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
