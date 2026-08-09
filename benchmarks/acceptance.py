#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

from status import build as build_status

REQUIRED_BASE = [
    "run-metadata.txt",
    "source-integrity.json",
    "system-info.log",
    "doctor.log",
    "health.log",
    "security-check.log",
    "auth-check.log",
    "resource-monitor.csv",
    "resource-monitor-summary.json",
]


def load_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text())
        return value if isinstance(value, dict) else {}
    except Exception:
        return {}


def load_status(run_dir: Path) -> dict[str, Any]:
    status_path = run_dir / "benchmark-status.json"
    if status_path.is_file():
        raw = load_json(status_path)
        if raw:
            return raw
    return build_status(run_dir)


def build(run_dir: Path) -> dict[str, Any]:
    status = load_status(run_dir)
    required = list(REQUIRED_BASE)
    if status.get("quick_status") not in {None, "NOT_REQUESTED"}:
        required.append("quick-suite/benchmark-report.json")
    if status.get("full_requested", True):
        required.append("full-suite/benchmark-report.json")

    missing = [rel for rel in required if not (run_dir / rel).is_file()]
    failed: list[str] = []
    auth_path = run_dir / "auth-check.log"
    if auth_path.is_file():
        auth_text = auth_path.read_text(errors="replace").lower()
        if "runtime authorization check passed" not in auth_text:
            failed.append("runtime authorization check did not report success")

    monitor = load_json(run_dir / "resource-monitor-summary.json")
    if (run_dir / "resource-monitor-summary.json").is_file() and not monitor:
        failed.append("resource monitor summary is invalid JSON")

    warnings: list[str] = []
    zombie_max = int(monitor.get("maximum_qdrant_zombie_processes") or 0)
    zombie_start_raw = monitor.get("qdrant_zombies_at_start")
    zombie_end_raw = monitor.get("qdrant_zombies_at_end")
    zombie_growth_raw = monitor.get("qdrant_zombie_growth")
    zombie_start = int(zombie_start_raw or 0)
    zombie_end = int(zombie_end_raw or 0)
    zombie_growth = int(zombie_growth_raw or 0)
    pressure = int(monitor.get("pressure_samples") or 0)
    pressure_events = int(monitor.get("pressure_event_count") or 0)
    max_swap = float(monitor.get("maximum_swap_used_mb") or 0)
    swap_start_raw = monitor.get("swap_at_start_mb")
    swap_growth_raw = monitor.get("swap_growth_mb")
    swap_start = float(swap_start_raw or 0)
    swap_growth = float(swap_growth_raw or 0)
    telemetry_continuity = str(monitor.get("telemetry_continuity") or "UNKNOWN")
    sample_gap_events = int(monitor.get("sample_gap_events") or 0)
    maximum_sample_gap_seconds = float(monitor.get("maximum_sample_gap_seconds") or 0)
    missing_monitor_seconds = float(monitor.get("missing_monitor_seconds") or 0)
    host_pause_or_monitor_stall_suspected = bool(monitor.get("host_pause_or_monitor_stall_suspected"))
    if telemetry_continuity == "GAPPED" or sample_gap_events:
        detail = (
            f"continuous telemetry gap detected ({sample_gap_events} gap event(s), "
            f"max={maximum_sample_gap_seconds:g}s, missing≈{missing_monitor_seconds:g}s)"
        )
        if host_pause_or_monitor_stall_suspected:
            detail += "; host pause or resource-monitor stall suspected"
        warnings.append(detail)
    if zombie_growth_raw is not None and zombie_growth > 0:
        warnings.append(
            f"continuous monitor observed Qdrant zombie growth of {zombie_growth} during the benchmark "
            f"(start={zombie_start}, end={zombie_end}, max={zombie_max}); live RSS excludes zombies"
        )
    elif zombie_start_raw is not None and zombie_start > 0:
        warnings.append(
            f"pre-existing zombie Qdrant processes were present at benchmark start ({zombie_start}) "
            f"with no zombie growth during the benchmark (end={zombie_end}, max={zombie_max}); "
            "live RSS excludes zombies"
        )
    elif zombie_growth_raw is None and zombie_max > 0:
        warnings.append(
            f"observed up to {zombie_max} zombie Qdrant process(es) "
            "(legacy summary; growth unknown); live RSS excludes zombies"
        )
    if pressure:
        suffix = f" across {pressure_events} deduplicated event(s)" if pressure_events else ""
        warnings.append(f"continuous monitor recorded {pressure} resource-pressure sample(s){suffix}")
    if swap_growth_raw is not None and swap_growth > 0:
        warnings.append(
            f"continuous monitor observed swap growth of {swap_growth:g} MB during the benchmark "
            f"(start={swap_start:g} MB, max={max_swap:g} MB)"
        )
    elif swap_start_raw is not None and swap_start > 0:
        warnings.append(
            f"pre-existing swap was present at benchmark start ({swap_start:g} MB) with no benchmark-observed swap growth"
        )
    elif swap_growth_raw is None and max_swap > 0:
        # Backward-compatible interpretation for older resource summaries that
        # did not distinguish starting swap from benchmark-window growth.
        warnings.append(f"continuous monitor observed swap usage up to {max_swap:g} MB (legacy summary; growth unknown)")

    comparable_status = bool(status.get("ready_for_ranking"))
    accepted = comparable_status and not missing and not failed
    if missing or failed:
        verdict = "INCOMPLETE"
    elif not comparable_status:
        verdict = "NOT_COMPARABLE"
    elif warnings:
        verdict = "ACCEPTED_WITH_WARNINGS"
    else:
        verdict = "ACCEPTED_BASELINE"

    return {
        "schema_version": 3,
        "run_dir": str(run_dir),
        "verdict": verdict,
        "accepted_for_comparison": accepted,
        "status": status,
        "missing_required_artifacts": missing,
        "failed_checks": failed,
        "warnings": warnings,
        "telemetry": {
            "samples": monitor.get("samples"),
            "telemetry_continuity": monitor.get("telemetry_continuity"),
            "expected_sample_interval_seconds": monitor.get("expected_sample_interval_seconds"),
            "sample_gap_tolerance_seconds": monitor.get("sample_gap_tolerance_seconds"),
            "sample_gap_events": monitor.get("sample_gap_events"),
            "maximum_sample_gap_seconds": monitor.get("maximum_sample_gap_seconds"),
            "missing_monitor_seconds": monitor.get("missing_monitor_seconds"),
            "host_pause_or_monitor_stall_suspected": monitor.get("host_pause_or_monitor_stall_suspected"),
            "memory_pressure_duration_complete": monitor.get("memory_pressure_duration_complete"),
            "minimum_mem_available_mb": monitor.get("minimum_mem_available_mb"),
            "mem_available_p01_mb": monitor.get("mem_available_p01_mb"),
            "mem_available_p05_mb": monitor.get("mem_available_p05_mb"),
            "mem_available_median_mb": monitor.get("mem_available_median_mb"),
            "seconds_below_mem_available_threshold": monitor.get("seconds_below_mem_available_threshold"),
            "longest_mem_pressure_duration_seconds": monitor.get("longest_mem_pressure_duration_seconds"),
            "swap_at_start_mb": monitor.get("swap_at_start_mb"),
            "swap_at_end_mb": monitor.get("swap_at_end_mb"),
            "maximum_swap_used_mb": monitor.get("maximum_swap_used_mb"),
            "swap_growth_mb": monitor.get("swap_growth_mb"),
            "swap_growth_events": monitor.get("swap_growth_events"),
            "swap_present_samples": monitor.get("swap_present_samples"),
            "maximum_qdrant_rss_mb": monitor.get("maximum_qdrant_rss_mb"),
            "maximum_benchmark_rss_mb": monitor.get("maximum_benchmark_rss_mb"),
            "maximum_qdrant_processes": monitor.get("maximum_qdrant_processes"),
            "qdrant_zombies_at_start": monitor.get("qdrant_zombies_at_start"),
            "qdrant_zombies_at_end": monitor.get("qdrant_zombies_at_end"),
            "maximum_qdrant_zombie_processes": monitor.get("maximum_qdrant_zombie_processes"),
            "qdrant_zombie_growth": monitor.get("qdrant_zombie_growth"),
            "pressure_samples": monitor.get("pressure_samples"),
            "pressure_event_count": monitor.get("pressure_event_count"),
        },
    }


def markdown(x: dict[str, Any]) -> str:
    status = x["status"]
    lines = [
        "# Benchmark acceptance",
        "",
        f"- Verdict: **{x['verdict']}**",
        f"- Accepted for comparison: `{str(x['accepted_for_comparison']).lower()}`",
        f"- Benchmark status: `{status.get('overall_status', 'UNKNOWN')}`",
        f"- Source integrity: `{status.get('source_integrity', 'UNKNOWN')}`",
        f"- Comparability: `{status.get('comparability', 'UNVERIFIED')}`",
        "",
    ]
    if x["missing_required_artifacts"]:
        lines += ["## Missing required artifacts", ""] + [f"- `{v}`" for v in x["missing_required_artifacts"]] + [""]
    if x["failed_checks"]:
        lines += ["## Failed checks", ""] + [f"- {v}" for v in x["failed_checks"]] + [""]
    if x["warnings"]:
        lines += ["## Warnings", ""] + [f"- {v}" for v in x["warnings"]] + [""]
    lines += [
        "## Interpretation",
        "",
        "Only an accepted run is eligible for clean cross-host ranking. Warnings remain visible because shared-cloud pressure or zombie processes can matter even when the benchmark is otherwise comparable.",
        "",
    ]
    return "\n".join(lines)


def main() -> int:
    p = argparse.ArgumentParser(description="Validate whether a benchmark artifact is a comparison-grade baseline")
    p.add_argument("--run-dir", required=True)
    p.add_argument("--json-output")
    p.add_argument("--markdown-output")
    p.add_argument("--require-accepted", action="store_true")
    a = p.parse_args()
    run_dir = Path(a.run_dir).resolve()
    if not run_dir.is_dir():
        p.error(f"run directory does not exist: {run_dir}")
    result = build(run_dir)
    text = json.dumps(result, indent=2) + "\n"
    if a.json_output:
        Path(a.json_output).write_text(text)
    else:
        sys.stdout.write(text)
    if a.markdown_output:
        Path(a.markdown_output).write_text(markdown(result))
    if a.require_accepted and not result["accepted_for_comparison"]:
        return 5
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
