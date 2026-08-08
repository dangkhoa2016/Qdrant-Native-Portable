#!/usr/bin/env python3
from __future__ import annotations
import argparse
import json
from pathlib import Path
from typing import Any


def load(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text())


def fmt(value: Any, digits: int = 2) -> str:
    if value is None:
        return "n/a"
    if isinstance(value, float):
        return f"{value:.{digits}f}"
    return str(value)


def seconds_human(value: float | int | None) -> str:
    if value is None:
        return "n/a"
    total = int(round(float(value)))
    minutes, seconds = divmod(total, 60)
    hours, minutes = divmod(minutes, 60)
    if hours:
        return f"{hours}h {minutes}m {seconds}s"
    if minutes:
        return f"{minutes}m {seconds}s"
    return f"{seconds}s"


def main() -> int:
    p = argparse.ArgumentParser(description="Build JSON and Markdown summary from Qdrant benchmark result files")
    p.add_argument("files", nargs="+")
    p.add_argument("--json-output", required=True)
    p.add_argument("--markdown-output", required=True)
    p.add_argument("--suite-wall-seconds", type=float)
    a = p.parse_args()

    docs = [(Path(name), load(Path(name))) for name in a.files]
    rows = []
    for path, doc in docs:
        b = doc.get("benchmark", {})
        ag = doc.get("aggregate", {})
        cold = ag.get("query_ms_cold_combined") or {}
        warm = ag.get("query_ms_warm_combined") or ag.get("query_ms_combined") or {}
        throughput = ag.get("median_throughput_points_per_second", {})
        median_timing = ag.get("median_timing_seconds", {})
        total_timing = ag.get("total_timing_seconds", {})
        ready = bool(ag.get("all_runs_benchmark_ready", ag.get("all_runs_settled")))
        rows.append({
            "file": str(path),
            "points": b.get("points"),
            "dimension": b.get("dimension"),
            "repeat": b.get("repeat"),
            "http_ingestion_points_per_second_median": throughput.get("http_ingestion"),
            "pipeline_points_per_second_median": throughput.get("end_to_end_pipeline"),
            "cold_p50_ms": cold.get("p50"),
            "cold_p95_ms": cold.get("p95"),
            "cold_max_ms": cold.get("max"),
            "warm_p50_ms": warm.get("p50"),
            "warm_p95_ms": warm.get("p95"),
            "warm_p99_ms": warm.get("p99"),
            "warm_max_ms": warm.get("max"),
            "qdrant_peak_sampled_rss_kb": ag.get("qdrant_peak_sampled_rss_kb"),
            "minimum_available_memory_mb": ag.get("system_minimum_sampled_available_memory_mb"),
            "benchmark_ready_runs": ag.get("benchmark_ready_runs"),
            "fully_indexed_runs": ag.get("fully_indexed_runs"),
            "extended_timeout_runs": ag.get("extended_timeout_runs", 0),
            "all_runs_benchmark_ready": ready,
            "status": "READY" if ready else "PROVISIONAL",
            "median_settle_seconds": median_timing.get("settle_wait"),
            "total_settle_seconds": total_timing.get("settle_wait"),
            "median_run_wall_seconds": median_timing.get("run_wall"),
            "total_run_wall_seconds": total_timing.get("run_wall"),
        })

    first = docs[0][1]
    provisional = [r for r in rows if not r["all_runs_benchmark_ready"]]
    report = {
        "schema_version": 3,
        "runtime": first.get("runtime", {}),
        "host": first.get("host_before", {}),
        "suite_wall_seconds": a.suite_wall_seconds,
        "suite_status": "READY" if not provisional else "PROVISIONAL",
        "provisional_workloads": [
            {"points": r["points"], "dimension": r["dimension"]} for r in provisional
        ],
        "results": rows,
        "source_files": [str(path) for path, _ in docs],
    }
    Path(a.json_output).write_text(json.dumps(report, indent=2) + "\n")

    lines = [
        "# Qdrant benchmark report", "",
        f"- Project version: `{report['runtime'].get('project_version', 'unknown')}`",
        f"- Qdrant: `{report['runtime'].get('qdrant_version_running', 'unknown')}`",
        f"- Platform: `{report['host'].get('platform_detected', 'unknown')}`",
        f"- Profile: `{report['runtime'].get('profile', 'unknown')}`",
        f"- Process/deployment: `{report['runtime'].get('process_mode', 'unknown')}` / `{report['runtime'].get('deployment_mode', 'unknown')}`",
        f"- CPU: `{report['host'].get('cpu_model', 'unknown')}` ({report['host'].get('cpu_threads', 'unknown')} threads)",
        f"- RAM: `{report['host'].get('memory_total_mb', 'unknown')} MB`",
        f"- Suite wall time: `{seconds_human(a.suite_wall_seconds)}`",
        f"- Suite status: **{report['suite_status']}**", "",
        "| Status | Points | Dim | Repeats | HTTP ingest pts/s | Pipeline pts/s | Cold p50 | Cold p95 | Warm p50 | Warm p95 | Warm p99 | Peak RSS MB | Min RAM MB | Settle total | Run wall total | Extended | Ready runs | Indexed runs |",
        "|:---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|",
    ]
    for r in rows:
        peak_mb = (r["qdrant_peak_sampled_rss_kb"] / 1024) if r["qdrant_peak_sampled_rss_kb"] is not None else None
        lines.append(
            "| {status} | {points} | {dimension} | {repeat} | {ingest} | {pipeline} | {cp50} | {cp95} | {wp50} | {wp95} | {wp99} | {rss} | {mem} | {settle} | {wall} | {extended} | {ready_runs} | {indexed_runs} |".format(
                status=r["status"], points=fmt(r["points"], 0), dimension=fmt(r["dimension"], 0), repeat=fmt(r["repeat"], 0),
                ingest=fmt(r["http_ingestion_points_per_second_median"]), pipeline=fmt(r["pipeline_points_per_second_median"]),
                cp50=fmt(r["cold_p50_ms"], 3), cp95=fmt(r["cold_p95_ms"], 3),
                wp50=fmt(r["warm_p50_ms"], 3), wp95=fmt(r["warm_p95_ms"], 3), wp99=fmt(r["warm_p99_ms"], 3),
                rss=fmt(peak_mb), mem=fmt(r["minimum_available_memory_mb"]),
                settle=seconds_human(r["total_settle_seconds"]), wall=seconds_human(r["total_run_wall_seconds"]),
                extended=fmt(r["extended_timeout_runs"], 0), ready_runs=fmt(r["benchmark_ready_runs"], 0), indexed_runs=fmt(r["fully_indexed_runs"], 0),
            )
        )

    if provisional:
        lines += ["", "## Provisional workloads", ""]
        for r in provisional:
            lines.append(
                f"- **{r['points']} × {r['dimension']}**: only {r['benchmark_ready_runs']}/{r['repeat']} runs were benchmark-ready. "
                "Treat latency/throughput as provisional and inspect the per-run `settle` objects before comparing hosts."
            )

    lines += [
        "", "## Interpretation notes", "",
        "- `Cold` latency is measured before warm-up; it intentionally exposes disk/page-cache costs on on-disk profiles.",
        "- `Warm` latency is measured after warming the same deterministic query set, so it represents hot-cache behavior more directly.",
        "- `HTTP ingest pts/s` excludes client vector generation and JSON encoding; `Pipeline pts/s` includes them.",
        "- `Settle total` is cumulative time spent waiting for Qdrant readiness across repeats. The benchmark may extend a bounded timeout when indexing is visibly progressing or only stable polls are missing.",
        "- `PROVISIONAL` means at least one repeat was not fully benchmark-ready; do not rank it equally with a fully `READY` workload.",
        "- Peak RSS is sampled at checkpoints and is not total machine memory usage; `Min RAM MB` uses Linux `MemAvailable`.",
        "- This is a development benchmark, not a substitute for representative concurrent production load testing.", "",
    ]
    Path(a.markdown_output).write_text("\n".join(lines))
    print(f"Saved: {a.json_output}")
    print(f"Saved: {a.markdown_output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
