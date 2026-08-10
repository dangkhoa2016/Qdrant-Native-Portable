#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


def load_json(path: Path) -> dict[str, Any]:
    try:
        return json.loads(path.read_text())
    except Exception:
        return {}


def load_meta(path: Path) -> dict[str, str]:
    out: dict[str, str] = {}
    if not path.is_file():
        return out
    for line in path.read_text(errors="replace").splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            out[k.strip()] = v.strip()
    return out


def nested(d: dict[str, Any], *keys: str) -> Any:
    cur: Any = d
    for key in keys:
        if not isinstance(cur, dict):
            return None
        cur = cur.get(key)
    return cur


def as_int(value: str | None) -> int | None:
    try:
        return int(value) if value is not None else None
    except ValueError:
        return None


def row_for(path: Path) -> dict[str, Any]:
    doc = load_json(path)
    ag = doc.get("aggregate") or {}
    b = doc.get("benchmark") or {}
    runtime = doc.get("runtime") or {}
    meta = load_meta(path.parent / "run-metadata.txt")
    monitor = load_json(path.parent / "resource-monitor-summary.json")
    cold = ag.get("query_ms_cold_combined") or {}
    warm = ag.get("query_ms_warm_combined") or ag.get("query_ms_combined") or {}
    throughput = ag.get("median_throughput_points_per_second") or {}
    peak_kb = ag.get("qdrant_peak_sampled_rss_kb")
    return {
        "path": str(path),
        "cycle": as_int(meta.get("cycle")),
        "position": as_int(meta.get("position")),
        "profile": meta.get("profile") or runtime.get("profile") or "unknown",
        "points": b.get("points"),
        "dimension": b.get("dimension"),
        "repeat": b.get("repeat"),
        "status": "READY" if bool(ag.get("all_runs_benchmark_ready", ag.get("all_runs_settled"))) else "PROVISIONAL",
        "benchmark_ready_runs": ag.get("benchmark_ready_runs"),
        "fully_indexed_runs": ag.get("fully_indexed_runs"),
        "cold_p50_ms": cold.get("p50"),
        "cold_p95_ms": cold.get("p95"),
        "warm_p50_ms": warm.get("p50"),
        "warm_p95_ms": warm.get("p95"),
        "http_ingestion_points_per_second": throughput.get("http_ingestion"),
        "benchmark_min_available_memory_mb": ag.get("system_minimum_sampled_available_memory_mb"),
        "benchmark_max_qdrant_rss_mb": None if peak_kb is None else round(float(peak_kb) / 1024.0, 3),
        "monitor_min_available_memory_mb": monitor.get("minimum_mem_available_mb"),
        "monitor_telemetry_continuity": monitor.get("telemetry_continuity"),
        "monitor_sample_gap_events": monitor.get("sample_gap_events"),
        "monitor_maximum_sample_gap_seconds": monitor.get("maximum_sample_gap_seconds"),
        "monitor_missing_seconds": monitor.get("missing_monitor_seconds"),
        "monitor_host_pause_or_stall_suspected": monitor.get("host_pause_or_monitor_stall_suspected"),
        "monitor_max_qdrant_rss_mb": monitor.get("maximum_qdrant_rss_mb"),
        "monitor_max_benchmark_rss_mb": monitor.get("maximum_benchmark_rss_mb"),
        "monitor_pressure_samples": monitor.get("pressure_samples"),
        "monitor_pressure_event_count": monitor.get("pressure_event_count"),
        "monitor_swap_at_start_mb": monitor.get("swap_at_start_mb"),
        "monitor_max_swap_used_mb": monitor.get("maximum_swap_used_mb"),
        "monitor_swap_growth_mb": monitor.get("swap_growth_mb"),
        "monitor_max_qdrant_processes": monitor.get("maximum_qdrant_processes"),
        "monitor_qdrant_zombies_at_start": monitor.get("qdrant_zombies_at_start"),
        "monitor_qdrant_zombies_at_end": monitor.get("qdrant_zombies_at_end"),
        "monitor_max_qdrant_zombie_processes": monitor.get("maximum_qdrant_zombie_processes"),
        "monitor_qdrant_zombie_growth": monitor.get("qdrant_zombie_growth"),
    }


def fmt(v: Any, digits: int = 3) -> str:
    if v is None:
        return "n/a"
    if isinstance(v, float):
        return f"{v:.{digits}f}"
    return str(v)


def markdown(report: dict[str, Any]) -> str:
    lines = [
        "# Qdrant profile comparison",
        "",
        "Continuous resource-monitor measurements are shown separately from benchmark checkpoint samples.",
        "",
        "| Cycle | Pos | Profile | Status | Cold p50 | Cold p95 | Warm p50 | Warm p95 | HTTP ingest | Benchmark Min RAM | Monitor Min RAM | Benchmark Qdrant RSS | Monitor Qdrant RSS | Continuity | Max gap s | Missing s | Pressure samples/events | Swap start/max/growth | Zombie start/max/growth |",
        "|---:|---:|---|:---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|---:|---:|---|---|---:|",
    ]
    for r in report["runs"]:
        lines.append(
            "| {cycle} | {pos} | {profile} | {status} | {cp50} | {cp95} | {wp50} | {wp95} | {ing} | {bmem} | {mmem} | {brss} | {mrss} | {continuity} | {max_gap} | {missing} | {pressure}/{pressure_events} | {swap_start}/{swap_max}/{swap_growth} | {zombie_start}/{zombies}/{zombie_growth} |".format(
                cycle=fmt(r["cycle"]), pos=fmt(r["position"]), profile=r["profile"], status=r["status"],
                cp50=fmt(r["cold_p50_ms"]), cp95=fmt(r["cold_p95_ms"]),
                wp50=fmt(r["warm_p50_ms"]), wp95=fmt(r["warm_p95_ms"]),
                ing=fmt(r["http_ingestion_points_per_second"]),
                bmem=fmt(r["benchmark_min_available_memory_mb"]), mmem=fmt(r["monitor_min_available_memory_mb"]),
                brss=fmt(r["benchmark_max_qdrant_rss_mb"]), mrss=fmt(r["monitor_max_qdrant_rss_mb"]),
                continuity=r["monitor_telemetry_continuity"] or "unknown",
                max_gap=fmt(r["monitor_maximum_sample_gap_seconds"]), missing=fmt(r["monitor_missing_seconds"]),
                pressure=fmt(r["monitor_pressure_samples"]), pressure_events=fmt(r["monitor_pressure_event_count"]),
                swap_start=fmt(r["monitor_swap_at_start_mb"]), swap_max=fmt(r["monitor_max_swap_used_mb"]),
                swap_growth=fmt(r["monitor_swap_growth_mb"]), zombie_start=fmt(r["monitor_qdrant_zombies_at_start"]),
                zombies=fmt(r["monitor_max_qdrant_zombie_processes"]), zombie_growth=fmt(r["monitor_qdrant_zombie_growth"]),
            )
        )
    lines += [
        "",
        f"READY profiles observed: `{', '.join(report['ready_profiles']) or 'none'}`",
        "",
        "A PROVISIONAL run remains useful evidence but must not be ranked as equivalent to READY. Monitor Min RAM is the continuous minimum and can reveal host-wide pressure missed by benchmark checkpoints. GAPPED telemetry is surfaced explicitly because pressure duration and host wall-clock interpretation are incomplete across unobserved intervals.",
        "",
    ]
    return "\n".join(lines)


def main() -> int:
    p = argparse.ArgumentParser(description="Compare profile A/B benchmark runs")
    p.add_argument("--root", required=True)
    p.add_argument("--json-output", required=True)
    p.add_argument("--markdown-output", required=True)
    a = p.parse_args()
    root = Path(a.root).resolve()
    paths = sorted(root.rglob("benchmark.json"))
    runs = [row_for(path) for path in paths]
    runs.sort(key=lambda r: (r["cycle"] or 0, r["position"] or 0, r["profile"]))
    report = {
        "schema_version": 3,
        "runs": runs,
        "ready_profiles": sorted({r["profile"] for r in runs if r["status"] == "READY"}),
        "provisional_profiles": sorted({r["profile"] for r in runs if r["status"] != "READY"}),
    }
    Path(a.json_output).write_text(json.dumps(report, indent=2) + "\n")
    Path(a.markdown_output).write_text(markdown(report))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
