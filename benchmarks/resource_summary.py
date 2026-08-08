#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import json
from pathlib import Path
from typing import Any

EPSILON_MB = 0.001


def f(row: dict[str, str], key: str) -> float | None:
    raw = row.get(key, "").strip()
    if raw in {"", "n/a", "null", "None"}:
        return None
    try:
        return float(raw)
    except ValueError:
        return None


def values(rows: list[dict[str, str]], key: str) -> list[float]:
    return [x for row in rows if (x := f(row, key)) is not None]


def maxv(rows: list[dict[str, str]], key: str) -> float | None:
    vals = values(rows, key)
    return max(vals) if vals else None


def minv(rows: list[dict[str, str]], key: str) -> float | None:
    vals = values(rows, key)
    return min(vals) if vals else None


def firstv(rows: list[dict[str, str]], key: str) -> float | None:
    for row in rows:
        value = f(row, key)
        if value is not None:
            return value
    return None


def lastv(rows: list[dict[str, str]], key: str) -> float | None:
    for row in reversed(rows):
        value = f(row, key)
        if value is not None:
            return value
    return None


def percentile(vals: list[float], q: float) -> float | None:
    if not vals:
        return None
    ordered = sorted(vals)
    if len(ordered) == 1:
        return ordered[0]
    pos = (len(ordered) - 1) * q
    low = int(pos)
    high = min(low + 1, len(ordered) - 1)
    fraction = pos - low
    return ordered[low] + (ordered[high] - ordered[low]) * fraction


def r3(v: float | None) -> float | None:
    return None if v is None else round(v, 3)


def epoch_deltas(rows: list[dict[str, str]]) -> list[float]:
    deltas: list[float] = []
    for index in range(len(rows) - 1):
        start = f(rows[index], "epoch")
        end = f(rows[index + 1], "epoch")
        if start is None or end is None:
            continue
        delta = end - start
        if delta > 0:
            deltas.append(delta)
    return deltas


def sampling_interval(rows: list[dict[str, str]], configured: float | None) -> float | None:
    if configured is not None and configured > 0:
        return configured
    deltas = epoch_deltas(rows)
    # Median is robust against the exact long-gap anomaly this summary is
    # trying to detect. One normal 2-second interval on each side of a pause
    # should still infer the intended 2-second cadence.
    return percentile(deltas, 0.50)


def memory_pressure_durations(
    rows: list[dict[str, str]], threshold: float, gap_tolerance: float | None
) -> tuple[float, float]:
    total = 0.0
    longest = 0.0
    current = 0.0
    for index, row in enumerate(rows[:-1]):
        avail = f(row, "mem_available_mb")
        start = f(row, "epoch")
        end = f(rows[index + 1], "epoch")
        delta = max(0.0, (end or 0.0) - (start or 0.0)) if start is not None and end is not None else 0.0
        # A long interval without samples is unobserved time. Never attribute
        # the whole gap to the state of the sample immediately before it.
        if gap_tolerance is not None and delta > gap_tolerance:
            current = 0.0
            continue
        if avail is not None and avail < threshold:
            total += delta
            current += delta
            longest = max(longest, current)
        else:
            current = 0.0
    return total, longest


def build(
    rows: list[dict[str, str]], expected_interval_seconds: float | None = None
) -> tuple[dict[str, Any], list[str]]:
    mem_total = maxv(rows, "mem_total_mb")
    threshold = max(512.0, (mem_total or 0.0) * 0.10)
    mem_vals = values(rows, "mem_available_mb")

    expected_interval = sampling_interval(rows, expected_interval_seconds)
    gap_tolerance = expected_interval * 3.0 if expected_interval is not None else None
    deltas = epoch_deltas(rows)
    gaps = [delta for delta in deltas if gap_tolerance is not None and delta > gap_tolerance]
    maximum_gap = max(deltas) if deltas else 0.0
    missing_monitor_seconds = sum(max(0.0, delta - (expected_interval or 0.0)) for delta in gaps)
    telemetry_continuity = "GAPPED" if gaps else "CONTINUOUS"
    host_pause_or_monitor_stall_suspected = bool(
        gaps
        and expected_interval is not None
        and max(gaps) >= max(60.0, expected_interval * 10.0)
    )

    swap_start = firstv(rows, "swap_used_mb") or 0.0
    swap_end = lastv(rows, "swap_used_mb") or 0.0
    swap_max = maxv(rows, "swap_used_mb") or 0.0
    swap_growth = max(0.0, swap_max - swap_start)
    swap_present_samples = sum(1 for row in rows if (f(row, "swap_used_mb") or 0.0) > EPSILON_MB)

    zombie_start = int(firstv(rows, "qdrant_zombie_processes") or 0)
    zombie_end = int(lastv(rows, "qdrant_zombie_processes") or 0)
    zombie_max = int(maxv(rows, "qdrant_zombie_processes") or 0)
    zombie_growth = max(0, zombie_max - zombie_start)

    pressure_lines: list[str] = []
    pressure_samples = 0
    pressure_event_count = 0
    swap_growth_events = 0
    low_mem_active = False

    previous_swap: float | None = None
    previous_cgroup: dict[str, float | None] = {
        "oom": None,
        "high": None,
        "max": None,
    }
    cgroup_growth_events = {"oom": 0, "high": 0, "max": 0}

    for index, row in enumerate(rows):
        ts = row.get("timestamp_utc", "unknown")
        sample_pressure = False

        if index > 0 and gap_tolerance is not None:
            previous_epoch = f(rows[index - 1], "epoch")
            current_epoch = f(row, "epoch")
            if previous_epoch is not None and current_epoch is not None:
                delta = max(0.0, current_epoch - previous_epoch)
                if delta > gap_tolerance:
                    missing = max(0.0, delta - (expected_interval or 0.0))
                    pressure_lines.append(
                        f"{ts} telemetry-gap gap_seconds={delta:.3f} "
                        f"expected_interval_seconds={(expected_interval or 0.0):.3f} "
                        f"missing_monitor_seconds={missing:.3f}"
                    )
                    # State continuity is unknown across the gap. Reset the
                    # transition tracker so a post-gap normal sample does not
                    # falsely claim it cleared pressure for the whole gap.
                    low_mem_active = False

        avail = f(row, "mem_available_mb")
        low_now = avail is not None and avail < threshold
        if low_now:
            sample_pressure = True
        if low_now and not low_mem_active:
            pressure_lines.append(f"{ts} memory-pressure-entered available_mb={avail:.3f} threshold_mb={threshold:.3f}")
            pressure_event_count += 1
        elif not low_now and low_mem_active:
            rendered = "n/a" if avail is None else f"{avail:.3f}"
            pressure_lines.append(f"{ts} memory-pressure-cleared available_mb={rendered} threshold_mb={threshold:.3f}")
            pressure_event_count += 1
        low_mem_active = low_now

        swap = f(row, "swap_used_mb") or 0.0
        if previous_swap is not None and swap > previous_swap + EPSILON_MB:
            delta = swap - previous_swap
            swap_growth_events += 1
            pressure_event_count += 1
            sample_pressure = True
            pressure_lines.append(
                f"{ts} swap-growth delta_mb={delta:.3f} swap_used_mb={swap:.3f} start_mb={swap_start:.3f}"
            )
        previous_swap = swap

        for key, csv_key in (("oom", "cgroup_oom_events"), ("high", "cgroup_high_events"), ("max", "cgroup_max_events")):
            current = f(row, csv_key)
            previous = previous_cgroup[key]
            if current is not None and previous is not None and current > previous:
                delta = int(current - previous)
                cgroup_growth_events[key] += 1
                pressure_event_count += 1
                sample_pressure = True
                pressure_lines.append(f"{ts} cgroup-{key}-growth delta={delta} count={int(current)}")
            if current is not None:
                previous_cgroup[key] = current

        if sample_pressure:
            pressure_samples += 1

    pressure_seconds, longest_pressure_seconds = memory_pressure_durations(rows, threshold, gap_tolerance)

    result = {
        "schema_version": 5,
        "samples": len(rows),
        "pressure_threshold_mem_available_mb": round(threshold, 3),
        "pressure_samples": pressure_samples,
        "pressure_event_count": pressure_event_count,
        "expected_sample_interval_seconds": r3(expected_interval),
        "sample_gap_tolerance_seconds": r3(gap_tolerance),
        "sample_gap_events": len(gaps),
        "maximum_sample_gap_seconds": r3(maximum_gap),
        "missing_monitor_seconds": r3(missing_monitor_seconds),
        "telemetry_continuity": telemetry_continuity,
        "host_pause_or_monitor_stall_suspected": host_pause_or_monitor_stall_suspected,
        "memory_pressure_duration_complete": not gaps,
        "minimum_mem_available_mb": r3(minv(rows, "mem_available_mb")),
        "mem_available_p01_mb": r3(percentile(mem_vals, 0.01)),
        "mem_available_p05_mb": r3(percentile(mem_vals, 0.05)),
        "mem_available_median_mb": r3(percentile(mem_vals, 0.50)),
        "seconds_below_mem_available_threshold": r3(pressure_seconds),
        "longest_mem_pressure_duration_seconds": r3(longest_pressure_seconds),
        "swap_at_start_mb": r3(swap_start),
        "swap_at_end_mb": r3(swap_end),
        "maximum_swap_used_mb": r3(swap_max),
        "swap_growth_mb": r3(swap_growth),
        "swap_growth_events": swap_growth_events,
        "swap_present_samples": swap_present_samples,
        "maximum_qdrant_processes": int(maxv(rows, "qdrant_processes") or 0),
        "qdrant_zombies_at_start": zombie_start,
        "qdrant_zombies_at_end": zombie_end,
        "maximum_qdrant_zombie_processes": zombie_max,
        "qdrant_zombie_growth": zombie_growth,
        "maximum_qdrant_rss_mb": r3(maxv(rows, "qdrant_rss_mb")),
        "maximum_benchmark_rss_mb": r3(maxv(rows, "benchmark_rss_mb")),
        "maximum_cgroup_memory_current_mb": r3(maxv(rows, "cgroup_memory_current_mb")),
        "cgroup_memory_limit_mb": r3(maxv(rows, "cgroup_memory_limit_mb")),
        "maximum_cgroup_oom_events": int(maxv(rows, "cgroup_oom_events") or 0),
        "maximum_cgroup_high_events": int(maxv(rows, "cgroup_high_events") or 0),
        "maximum_cgroup_max_events": int(maxv(rows, "cgroup_max_events") or 0),
        "cgroup_oom_growth_events": cgroup_growth_events["oom"],
        "cgroup_high_growth_events": cgroup_growth_events["high"],
        "cgroup_max_growth_events": cgroup_growth_events["max"],
    }
    return result, pressure_lines


def markdown(summary: dict[str, Any]) -> str:
    def val(key: str) -> str:
        x = summary.get(key)
        return "n/a" if x is None else str(x)
    return "\n".join([
        "# Resource monitor summary",
        "",
        f"- Samples: `{val('samples')}`",
        f"- Telemetry continuity: `{val('telemetry_continuity')}`",
        f"- Expected sample interval / gap tolerance: `{val('expected_sample_interval_seconds')} / {val('sample_gap_tolerance_seconds')} s`",
        f"- Sampling gaps / maximum gap / missing monitor time: `{val('sample_gap_events')} / {val('maximum_sample_gap_seconds')} s / {val('missing_monitor_seconds')} s`",
        f"- Host pause or monitor stall suspected: `{val('host_pause_or_monitor_stall_suspected')}`",
        f"- Minimum MemAvailable: `{val('minimum_mem_available_mb')} MB`",
        f"- MemAvailable p01 / p05 / median: `{val('mem_available_p01_mb')} / {val('mem_available_p05_mb')} / {val('mem_available_median_mb')} MB`",
        f"- Time below memory-pressure threshold: `{val('seconds_below_mem_available_threshold')} s`",
        f"- Longest observed memory-pressure duration: `{val('longest_mem_pressure_duration_seconds')} s`",
        f"- Memory-pressure duration complete: `{val('memory_pressure_duration_complete')}`",
        f"- Swap at start / end / maximum: `{val('swap_at_start_mb')} / {val('swap_at_end_mb')} / {val('maximum_swap_used_mb')} MB`",
        f"- Benchmark-window swap growth: `{val('swap_growth_mb')} MB` across `{val('swap_growth_events')}` growth event(s)",
        f"- Samples with any swap present: `{val('swap_present_samples')}`",
        f"- Maximum live Qdrant processes: `{val('maximum_qdrant_processes')}`",
        f"- Zombie Qdrant processes at start / end / maximum: `{val('qdrant_zombies_at_start')} / {val('qdrant_zombies_at_end')} / {val('maximum_qdrant_zombie_processes')}`",
        f"- Benchmark-window zombie growth: `{val('qdrant_zombie_growth')}`",
        f"- Maximum live Qdrant RSS: `{val('maximum_qdrant_rss_mb')} MB`",
        f"- Maximum benchmark-client RSS: `{val('maximum_benchmark_rss_mb')} MB`",
        f"- Maximum cgroup memory.current: `{val('maximum_cgroup_memory_current_mb')} MB`",
        f"- Cgroup memory limit: `{val('cgroup_memory_limit_mb')} MB`",
        f"- Pressure samples: `{val('pressure_samples')}`",
        f"- Deduplicated pressure events: `{val('pressure_event_count')}`",
        f"- Maximum cgroup OOM events: `{val('maximum_cgroup_oom_events')}`",
        "",
        "Pre-existing swap is reported separately from swap growth observed during the benchmark window. Pressure-event logs are transition/delta oriented rather than repeating unchanged state every poll.",
        "Long sampling gaps are reported as unobserved telemetry time and are excluded from memory-pressure duration instead of being attributed to the last observed sample.",
        "Zombie Qdrant processes are reported with start/end/maximum counts so pre-existing zombies are distinguishable from benchmark-window growth; zombies are excluded from live Qdrant RSS.",
        "",
    ])


def main() -> int:
    p = argparse.ArgumentParser(description="Summarize Qdrant benchmark resource-monitor CSV")
    p.add_argument("--csv", required=True)
    p.add_argument("--json-output", required=True)
    p.add_argument("--markdown-output", required=True)
    p.add_argument("--pressure-log", required=True)
    p.add_argument("--expected-interval-seconds", type=float, default=None)
    a = p.parse_args()
    if a.expected_interval_seconds is not None and a.expected_interval_seconds <= 0:
        p.error("--expected-interval-seconds must be greater than zero")
    with Path(a.csv).open(newline="") as fh:
        rows = list(csv.DictReader(fh))
    summary, pressure = build(rows, a.expected_interval_seconds)
    Path(a.json_output).write_text(json.dumps(summary, indent=2) + "\n")
    Path(a.markdown_output).write_text(markdown(summary))
    Path(a.pressure_log).write_text("\n".join(pressure) + ("\n" if pressure else ""))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
