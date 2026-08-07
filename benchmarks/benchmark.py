#!/usr/bin/env python3
"""Dependency-free Qdrant benchmark for constrained development hosts.

The benchmark separates client vector generation/JSON encoding from HTTP ingestion,
waits for a stable collection state, and reports cold and warmed query latency
separately. It is intentionally a development benchmark rather than a concurrent
production load generator.
"""
from __future__ import annotations

import argparse
import json
import math
import os
import platform
import random
import resource
import shutil
import socket
import statistics
import subprocess
import time
import urllib.request
from pathlib import Path
from typing import Any


def utc_stamp() -> str:
    return time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())


def read_text(path: str) -> str:
    try:
        return Path(path).read_text(errors="replace")
    except Exception:
        return ""


def meminfo_mb(key: str) -> float | None:
    for line in read_text("/proc/meminfo").splitlines():
        if line.startswith(f"{key}:"):
            try:
                return round(int(line.split()[1]) / 1024, 2)
            except Exception:
                return None
    return None


def cpu_model() -> str:
    for line in read_text("/proc/cpuinfo").splitlines():
        if line.lower().startswith("model name"):
            return line.split(":", 1)[1].strip()
    return platform.processor() or "unknown"


def filesystem_type(path: Path) -> str:
    try:
        proc = subprocess.run(["df", "-T", str(path)], capture_output=True, text=True, check=True, timeout=5)
        lines = [x for x in proc.stdout.splitlines() if x.strip()]
        if len(lines) >= 2:
            return lines[-1].split()[1]
    except Exception:
        pass
    return "unknown"


def disk_snapshot(path: Path) -> dict[str, Any]:
    path.mkdir(parents=True, exist_ok=True)
    usage = shutil.disk_usage(path)
    return {
        "filesystem": filesystem_type(path),
        "total_mb": round(usage.total / 1024 / 1024, 2),
        "used_mb": round(usage.used / 1024 / 1024, 2),
        "free_mb": round(usage.free / 1024 / 1024, 2),
    }


def directory_size_bytes(path: Path) -> int:
    total = 0
    if not path.exists():
        return 0
    for root, _, files in os.walk(path):
        for name in files:
            try:
                total += (Path(root) / name).stat().st_size
            except OSError:
                pass
    return total


def process_rss_kb(pid: str | int | None) -> int | None:
    if not pid:
        return None
    try:
        for line in Path(f"/proc/{pid}/status").read_text().splitlines():
            if line.startswith("VmRSS:"):
                return int(line.split()[1])
    except Exception:
        return None
    return None


def percentile(values: list[float], pct: float) -> float:
    ordered = sorted(values)
    if len(ordered) == 1:
        return ordered[0]
    rank = (len(ordered) - 1) * pct / 100.0
    lo, hi = math.floor(rank), math.ceil(rank)
    if lo == hi:
        return ordered[lo]
    frac = rank - lo
    return ordered[lo] * (1 - frac) + ordered[hi] * frac


def latency_summary(values: list[float], include_raw: bool = True) -> dict[str, Any] | None:
    if not values:
        return None
    result: dict[str, Any] = {
        "count": len(values),
        "min": round(min(values), 3),
        "p50": round(percentile(values, 50), 3),
        "p90": round(percentile(values, 90), 3),
        "p95": round(percentile(values, 95), 3),
        "p99": round(percentile(values, 99), 3),
        "median": round(statistics.median(values), 3),
        "mean": round(statistics.mean(values), 3),
        "max": round(max(values), 3),
        "stddev": round(statistics.pstdev(values), 3) if len(values) > 1 else 0.0,
    }
    if include_raw:
        result["raw"] = [round(x, 3) for x in values]
    return result


def vector(i: int, dim: int) -> list[float]:
    rng = random.Random(i * 1000003 + dim)
    vals = [rng.random() - 0.5 for _ in range(dim)]
    norm = math.sqrt(sum(x * x for x in vals)) or 1.0
    return [round(x / norm, 6) for x in vals]


class QdrantHTTP:
    def __init__(self) -> None:
        self.base = os.environ["QDRANT_URL"].rstrip("/")
        self.api_key = os.environ["QDRANT_API_KEY"]

    def request(self, method: str, path: str, body: Any = None, timeout: int = 180) -> dict[str, Any]:
        payload = None if body is None else json.dumps(body, separators=(",", ":")).encode()
        req = urllib.request.Request(
            self.base + path, data=payload, method=method,
            headers={"api-key": self.api_key, "Content-Type": "application/json"},
        )
        with urllib.request.urlopen(req, timeout=timeout) as response:
            raw = response.read()
            return json.loads(raw) if raw else {}

    def timed_request(self, method: str, path: str, body: Any = None, timeout: int = 180) -> tuple[dict[str, Any], float, float]:
        encode_start = time.perf_counter()
        payload = None if body is None else json.dumps(body, separators=(",", ":")).encode()
        encode_s = time.perf_counter() - encode_start
        req = urllib.request.Request(
            self.base + path, data=payload, method=method,
            headers={"api-key": self.api_key, "Content-Type": "application/json"},
        )
        http_start = time.perf_counter()
        with urllib.request.urlopen(req, timeout=timeout) as response:
            raw = response.read()
        http_s = time.perf_counter() - http_start
        return (json.loads(raw) if raw else {}), encode_s, http_s


def optimizer_is_ok(value: Any) -> bool:
    if value == "ok":
        return True
    if isinstance(value, dict):
        return value.get("status") == "ok" or value.get("ok") is True
    return False


def collection_state(client: QdrantHTTP, collection: str) -> dict[str, Any]:
    response = client.request("GET", f"/collections/{collection}")
    result = response.get("result") or {}
    return {
        "status": result.get("status"),
        "optimizer_status": result.get("optimizer_status"),
        "points_count": result.get("points_count"),
        "indexed_vectors_count": result.get("indexed_vectors_count"),
        "segments_count": result.get("segments_count"),
    }


def fully_indexed(state: dict[str, Any]) -> bool | None:
    points, indexed = state.get("points_count"), state.get("indexed_vectors_count")
    if not isinstance(points, int) or not isinstance(indexed, int):
        return None
    return indexed >= points


def state_signature(state: dict[str, Any]) -> tuple[Any, ...]:
    opt = state.get("optimizer_status")
    if isinstance(opt, dict):
        opt = json.dumps(opt, sort_keys=True, separators=(",", ":"))
    return (
        state.get("status"), opt, state.get("points_count"),
        state.get("indexed_vectors_count"), state.get("segments_count"),
    )


def wait_for_settle(
    client: QdrantHTTP,
    collection: str,
    timeout_s: int,
    max_timeout_s: int,
    poll_s: float,
    stable_polls_required: int,
    require_full_index: bool,
) -> dict[str, Any]:
    started = time.perf_counter()
    last: dict[str, Any] = {}
    previous_signature: tuple[Any, ...] | None = None
    stable_polls = 0
    best_indexed = -1
    last_index_progress_at: float | None = None
    timeout_extended = False
    extension_reason: str | None = None
    max_timeout_s = max(timeout_s, max_timeout_s)

    while True:
        last = collection_state(client, collection)
        status_ok = last.get("status") == "green"
        optimizer_ok = optimizer_is_ok(last.get("optimizer_status"))
        full = fully_indexed(last)
        readiness = status_ok and optimizer_ok and (full is True if require_full_index else True)
        signature = state_signature(last)

        indexed = last.get("indexed_vectors_count")
        points = last.get("points_count")
        if isinstance(indexed, int):
            if best_indexed >= 0 and indexed > best_indexed:
                last_index_progress_at = time.perf_counter()
            best_indexed = max(best_indexed, indexed)

        if readiness:
            stable_polls = stable_polls + 1 if signature == previous_signature else 1
        else:
            stable_polls = 0
        previous_signature = signature

        ready = readiness and stable_polls >= stable_polls_required
        now = time.perf_counter()
        elapsed = now - started
        seconds_since_index_progress = (
            None if last_index_progress_at is None else max(0.0, now - last_index_progress_at)
        )
        recent_progress_window_s = max(10.0, min(60.0, timeout_s * 0.20))
        recent_index_progress = (
            seconds_since_index_progress is not None
            and seconds_since_index_progress <= recent_progress_window_s
        )
        base = {
            "settled": ready,  # backwards-compatible alias
            "benchmark_ready": ready,
            "operational_green": status_ok,
            "optimizer_idle": optimizer_ok,
            "fully_indexed": full,
            "require_full_index": require_full_index,
            "stable_polls_required": stable_polls_required,
            "stable_polls_observed": stable_polls,
            "initial_timeout_seconds": timeout_s,
            "max_timeout_seconds": max_timeout_s,
            "timeout_extended": timeout_extended,
            "extension_reason": extension_reason,
            "seconds_since_index_progress": (
                None if seconds_since_index_progress is None else round(seconds_since_index_progress, 3)
            ),
            "recent_index_progress": recent_index_progress,
            "recent_progress_window_seconds": round(recent_progress_window_s, 3),
            "wait_seconds": round(elapsed, 3),
            **last,
        }
        if ready:
            return base

        if elapsed >= timeout_s and not timeout_extended:
            near_full = (
                isinstance(indexed, int) and isinstance(points, int) and points > 0
                and indexed >= int(points * 0.90)
            )
            # Do not extend merely because indexing is near complete. Shared
            # hosts can stall for minutes at 90-99%, and extending that state
            # only wastes benchmark wall time. An extension is justified when
            # indexing moved recently, or when the collection is already ready
            # and only needs the configured stable-poll confirmation.
            if max_timeout_s > timeout_s and (readiness or recent_index_progress):
                timeout_extended = True
                if readiness:
                    extension_reason = "ready-state-needs-stable-polls"
                elif near_full:
                    extension_reason = "indexing-near-complete-recent-progress"
                else:
                    extension_reason = "indexing-progress-recent"
                continue
            return base

        if timeout_extended and elapsed >= max_timeout_s:
            base["wait_seconds"] = round(elapsed, 3)
            base["timeout_extended"] = True
            base["extension_reason"] = extension_reason
            return base
        time.sleep(poll_s)


def host_metadata(base_dir: Path) -> dict[str, Any]:
    return {
        "hostname": socket.gethostname(),
        "platform_detected": os.environ.get("QDRANT_PLATFORM_DETECTED", "unknown"),
        "os": platform.platform(),
        "kernel": platform.release(),
        "architecture": platform.machine(),
        "cpu_model": cpu_model(),
        "cpu_threads": os.cpu_count(),
        "memory_total_mb": meminfo_mb("MemTotal"),
        "memory_available_mb": meminfo_mb("MemAvailable"),
        "base_directory": str(base_dir),
        "disk": disk_snapshot(base_dir),
    }


def runtime_metadata(client: QdrantHTTP) -> dict[str, Any]:
    try:
        actual_version = client.request("GET", "/").get("version") or "unknown"
    except Exception:
        actual_version = "unknown"
    return {
        "project_version": os.environ.get("QDRANT_PROJECT_VERSION", "unknown"),
        "qdrant_version_configured": os.environ.get("QDRANT_VERSION", "unknown"),
        "qdrant_version_running": actual_version,
        "profile": os.environ.get("QDRANT_PROFILE", "unknown"),
        "process_mode": os.environ.get("PROCESS_MODE", "unknown"),
        "deployment_mode": os.environ.get("DEPLOYMENT_MODE", "unknown"),
        "public_mode": os.environ.get("PUBLIC_MODE", "unknown"),
        "grpc_enabled": os.environ.get("QDRANT_ENABLE_GRPC", "0") == "1",
        "strict_mode": os.environ.get("QDRANT_STRICT_MODE", "unknown"),
    }


def query_ids(points: int, count: int) -> list[int]:
    # Spread deterministic query sources across the collection instead of only
    # touching the first N points. The same set is reused for warm-up and warm
    # measurement so page-cache effects are intentional and measurable.
    return [((17 + i * 7919) % points) for i in range(count)]


def measure_queries(client: QdrantHTTP, collection: str, dimension: int, ids: list[int]) -> list[float]:
    latencies: list[float] = []
    for idx in ids:
        q = vector(idx, dimension)
        started = time.perf_counter()
        result = client.request(
            "POST", f"/collections/{collection}/points/query",
            {"query": q, "limit": 10, "with_payload": False},
        )
        latencies.append((time.perf_counter() - started) * 1000)
        if not (result.get("result") or {}).get("points"):
            raise RuntimeError("query returned no points")
    return latencies


def run_once(client: QdrantHTTP, args: argparse.Namespace, run_number: int, qdrant_pid: str, storage: Path) -> dict[str, Any]:
    run_wall_started = time.perf_counter()
    collection = args.collection if args.repeat == 1 else f"{args.collection}_r{run_number}"
    try:
        client.request("DELETE", f"/collections/{collection}")
    except Exception:
        pass
    client.request("PUT", f"/collections/{collection}", {"vectors": {"size": args.dimension, "distance": "Cosine"}})

    rss_before = process_rss_kb(qdrant_pid)
    mem_before = meminfo_mb("MemAvailable")
    disk_before = disk_snapshot(storage.parent if storage.parent.exists() else storage)
    storage_before = directory_size_bytes(storage)

    generation_s = encoding_s = ingestion_http_s = qdrant_reported_s = 0.0
    wall_start = time.perf_counter()
    for start in range(0, args.points, args.batch_size):
        end = min(start + args.batch_size, args.points)
        generation_start = time.perf_counter()
        points = [{"id": i, "vector": vector(i, args.dimension), "payload": {"group": i % 10}} for i in range(start, end)]
        generation_s += time.perf_counter() - generation_start
        response, encode_s, http_s = client.timed_request(
            "PUT", f"/collections/{collection}/points?wait=true", {"points": points}
        )
        encoding_s += encode_s
        ingestion_http_s += http_s
        try:
            qdrant_reported_s += float(response.get("time") or 0.0)
        except (TypeError, ValueError):
            pass
    upload_wall_s = time.perf_counter() - wall_start

    rss_after_upload = process_rss_kb(qdrant_pid)
    mem_after_upload = meminfo_mb("MemAvailable")

    if args.skip_settle:
        state = collection_state(client, collection)
        settle = {
            "settled": None, "benchmark_ready": None,
            "operational_green": state.get("status") == "green",
            "optimizer_idle": optimizer_is_ok(state.get("optimizer_status")),
            "fully_indexed": fully_indexed(state),
            "require_full_index": args.require_full_index,
            "stable_polls_required": args.stable_polls,
            "stable_polls_observed": 0,
            "initial_timeout_seconds": args.settle_timeout,
            "max_timeout_seconds": args.settle_max_timeout,
            "timeout_extended": False,
            "extension_reason": None,
            "wait_seconds": 0.0, **state,
        }
    else:
        settle = wait_for_settle(
            client, collection, args.settle_timeout, args.settle_max_timeout, args.settle_poll,
            args.stable_polls, args.require_full_index,
        )

    rss_after_settle = process_rss_kb(qdrant_pid)
    mem_after_settle = meminfo_mb("MemAvailable")

    measured_ids = query_ids(args.points, args.queries)
    cold_ids = measured_ids[: min(args.cold_queries, len(measured_ids))]
    cold_latencies = measure_queries(client, collection, args.dimension, cold_ids) if cold_ids else []
    rss_after_cold = process_rss_kb(qdrant_pid)
    mem_after_cold = meminfo_mb("MemAvailable")

    # Warm the exact measured query set. If warmup > measured query count, cycle
    # through it repeatedly. Recommended suite default is warmup == queries.
    for i in range(args.warmup):
        idx = measured_ids[i % len(measured_ids)]
        result = client.request(
            "POST", f"/collections/{collection}/points/query",
            {"query": vector(idx, args.dimension), "limit": 10, "with_payload": False},
        )
        if not (result.get("result") or {}).get("points"):
            raise RuntimeError("warm-up query returned no points")

    warm_latencies = measure_queries(client, collection, args.dimension, measured_ids)
    rss_after_query = process_rss_kb(qdrant_pid)
    mem_after_query = meminfo_mb("MemAvailable")
    storage_after = directory_size_bytes(storage)
    disk_after = disk_snapshot(storage.parent if storage.parent.exists() else storage)
    final_state = collection_state(client, collection)

    rss_samples = [rss_before, rss_after_upload, rss_after_settle, rss_after_cold, rss_after_query]
    mem_samples = [mem_before, mem_after_upload, mem_after_settle, mem_after_cold, mem_after_query]
    result: dict[str, Any] = {
        "run": run_number,
        "collection": collection,
        "points": args.points,
        "dimension": args.dimension,
        "batch_size": args.batch_size,
        "cold_queries": len(cold_ids),
        "warmup_queries": args.warmup,
        "measured_queries": args.queries,
        "timing_seconds": {
            "run_wall": round(time.perf_counter() - run_wall_started, 4),
            "settle_wait": settle.get("wait_seconds"),
            "vector_generation": round(generation_s, 4),
            "json_encoding": round(encoding_s, 4),
            "ingestion_http": round(ingestion_http_s, 4),
            "qdrant_reported": round(qdrant_reported_s, 4),
            "upload_pipeline_wall": round(upload_wall_s, 4),
        },
        "throughput_points_per_second": {
            "http_ingestion": round(args.points / ingestion_http_s, 2) if ingestion_http_s else None,
            "end_to_end_pipeline": round(args.points / upload_wall_s, 2) if upload_wall_s else None,
        },
        "settle": settle,
        "query_ms_cold": latency_summary(cold_latencies, include_raw=not args.no_raw_latencies),
        "query_ms_warm": latency_summary(warm_latencies, include_raw=not args.no_raw_latencies),
        "query_ms": latency_summary(warm_latencies, include_raw=not args.no_raw_latencies),  # compatibility alias
        "qdrant_rss_kb": {
            "before": rss_before,
            "after_upload": rss_after_upload,
            "after_settle": rss_after_settle,
            "after_cold_queries": rss_after_cold,
            "after_warm_queries": rss_after_query,
            "after_queries": rss_after_query,
            "peak_sampled": max(x for x in rss_samples if x is not None) if any(x is not None for x in rss_samples) else None,
        },
        "system_memory_available_mb": {
            "before": mem_before,
            "after_upload": mem_after_upload,
            "after_settle": mem_after_settle,
            "after_cold_queries": mem_after_cold,
            "after_warm_queries": mem_after_query,
            "after_queries": mem_after_query,
            "minimum_sampled": min(x for x in mem_samples if x is not None) if any(x is not None for x in mem_samples) else None,
        },
        "storage": {
            "qdrant_storage_bytes_before": storage_before,
            "qdrant_storage_bytes_after": storage_after,
            "qdrant_storage_growth_bytes": storage_after - storage_before,
            "disk_before": disk_before,
            "disk_after": disk_after,
        },
        "collection_state_after_queries": final_state,
        "client_max_rss_kb": resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,
        "kept": args.keep,
    }
    if not args.keep:
        client.request("DELETE", f"/collections/{collection}")
    return result


def median_metric(runs: list[dict[str, Any]], path: tuple[str, ...]) -> float | None:
    values: list[float] = []
    for run in runs:
        value: Any = run
        for key in path:
            if not isinstance(value, dict):
                value = None
                break
            value = value.get(key)
        if isinstance(value, (int, float)):
            values.append(float(value))
    return round(statistics.median(values), 4) if values else None


def combined_raw(runs: list[dict[str, Any]], key: str) -> list[float]:
    out: list[float] = []
    for run in runs:
        raw = (run.get(key) or {}).get("raw")
        if isinstance(raw, list):
            out.extend(float(x) for x in raw)
    return out


def aggregate(runs: list[dict[str, Any]]) -> dict[str, Any]:
    cold = combined_raw(runs, "query_ms_cold")
    warm = combined_raw(runs, "query_ms_warm")
    rss_values = [run.get("qdrant_rss_kb", {}).get("peak_sampled") for run in runs if run.get("qdrant_rss_kb", {}).get("peak_sampled") is not None]
    mem_values = [run.get("system_memory_available_mb", {}).get("minimum_sampled") for run in runs if run.get("system_memory_available_mb", {}).get("minimum_sampled") is not None]
    ready = [run.get("settle", {}).get("benchmark_ready") for run in runs]
    fully = [run.get("settle", {}).get("fully_indexed") for run in runs]
    return {
        "repeat_count": len(runs),
        "median_timing_seconds": {
            "vector_generation": median_metric(runs, ("timing_seconds", "vector_generation")),
            "json_encoding": median_metric(runs, ("timing_seconds", "json_encoding")),
            "ingestion_http": median_metric(runs, ("timing_seconds", "ingestion_http")),
            "qdrant_reported": median_metric(runs, ("timing_seconds", "qdrant_reported")),
            "upload_pipeline_wall": median_metric(runs, ("timing_seconds", "upload_pipeline_wall")),
            "settle_wait": median_metric(runs, ("timing_seconds", "settle_wait")),
            "run_wall": median_metric(runs, ("timing_seconds", "run_wall")),
        },
        "total_timing_seconds": {
            "settle_wait": round(sum(float(run.get("timing_seconds", {}).get("settle_wait") or 0) for run in runs), 4),
            "run_wall": round(sum(float(run.get("timing_seconds", {}).get("run_wall") or 0) for run in runs), 4),
        },
        "median_throughput_points_per_second": {
            "http_ingestion": median_metric(runs, ("throughput_points_per_second", "http_ingestion")),
            "end_to_end_pipeline": median_metric(runs, ("throughput_points_per_second", "end_to_end_pipeline")),
        },
        "query_ms_cold_combined": latency_summary(cold, include_raw=False),
        "query_ms_warm_combined": latency_summary(warm, include_raw=False),
        "query_ms_combined": latency_summary(warm, include_raw=False),  # compatibility alias
        "qdrant_peak_sampled_rss_kb": max(rss_values) if rss_values else None,
        "system_minimum_sampled_available_memory_mb": min(mem_values) if mem_values else None,
        "benchmark_ready_runs": sum(x is True for x in ready),
        "fully_indexed_runs": sum(x is True for x in fully),
        "all_runs_benchmark_ready": all(x is True for x in ready),
        "all_runs_settled": all(x is True for x in ready),  # compatibility alias
        "provisional": not all(x is True for x in ready),
        "extended_timeout_runs": sum(bool(run.get("settle", {}).get("timeout_extended")) for run in runs),
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Dependency-free Qdrant resource benchmark")
    parser.add_argument("--points", type=int, default=1000)
    parser.add_argument("--dimension", type=int, default=384)
    parser.add_argument("--batch-size", type=int, default=128)
    parser.add_argument("--queries", type=int, default=50, help="Warm measured queries")
    parser.add_argument("--cold-queries", type=int, default=20, help="Cold queries measured before warm-up")
    parser.add_argument("--warmup", type=int, default=50, help="Warm-up requests using the same measured query set")
    parser.add_argument("--repeat", type=int, default=1)
    parser.add_argument("--settle-timeout", type=int, default=180)
    parser.add_argument("--settle-max-timeout", type=int, default=300, help="Bounded adaptive settle timeout ceiling")
    parser.add_argument("--settle-poll", type=float, default=2.0)
    parser.add_argument("--stable-polls", type=int, default=3)
    parser.add_argument("--require-full-index", action="store_true", help="Require indexed_vectors_count >= points_count before measurement")
    parser.add_argument("--skip-settle", action="store_true")
    parser.add_argument("--collection", default="benchmark_portable")
    parser.add_argument("--keep", action="store_true")
    parser.add_argument("--no-raw-latencies", action="store_true")
    parser.add_argument("--output", help="Write JSON to this exact path")
    args = parser.parse_args()
    for name in ("points", "dimension", "batch_size", "queries", "repeat", "stable_polls"):
        if getattr(args, name) < 1:
            parser.error(f"--{name.replace('_', '-')} must be positive")
    if args.warmup < 0 or args.cold_queries < 0 or args.settle_timeout < 0 or args.settle_max_timeout < args.settle_timeout or args.settle_poll <= 0:
        parser.error("warmup/cold/settle values are invalid; settle-max-timeout must be >= settle-timeout")
    return args


def main() -> int:
    args = parse_args()
    client = QdrantHTTP()
    qdrant_pid = os.environ.get("QDRANT_PID", "")
    out_dir = Path(os.environ.get("QDRANT_BENCHMARK_DIR", "."))
    out_dir.mkdir(parents=True, exist_ok=True)
    base_dir = Path(os.environ.get("QDRANT_BASE_DIR", out_dir.parent))
    storage = Path(os.environ.get("QDRANT_STORAGE_DIR", base_dir / "storage"))
    run_id = utc_stamp()
    output = Path(args.output) if args.output else out_dir / f"benchmark-{args.points}p-{args.dimension}d-{run_id}.json"
    output.parent.mkdir(parents=True, exist_ok=True)

    document: dict[str, Any] = {
        "schema_version": 3,
        "run_id": run_id,
        "benchmark": {
            "points": args.points,
            "dimension": args.dimension,
            "batch_size": args.batch_size,
            "queries": args.queries,
            "cold_queries": args.cold_queries,
            "warmup": args.warmup,
            "repeat": args.repeat,
            "settle_timeout_seconds": args.settle_timeout,
            "settle_max_timeout_seconds": args.settle_max_timeout,
            "settle_poll_seconds": args.settle_poll,
            "stable_polls": args.stable_polls,
            "require_full_index": args.require_full_index,
        },
        "runtime": runtime_metadata(client),
        "host_before": host_metadata(base_dir),
        "runs": [],
    }
    for run_number in range(1, args.repeat + 1):
        print(f"[benchmark] run {run_number}/{args.repeat}: {args.points} points × {args.dimension} dimensions", flush=True)
        document["runs"].append(run_once(client, args, run_number, qdrant_pid, storage))
    document["aggregate"] = aggregate(document["runs"])
    document["host_after"] = host_metadata(base_dir)
    output.write_text(json.dumps(document, indent=2) + "\n")
    print(json.dumps(document["aggregate"], indent=2))
    print(f"\nSaved: {output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
