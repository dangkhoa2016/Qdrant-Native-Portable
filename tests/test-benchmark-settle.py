#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("qnp_benchmark", ROOT / "benchmarks" / "benchmark.py")
module = importlib.util.module_from_spec(spec)
assert spec and spec.loader
spec.loader.exec_module(module)


class FakeClock:
    def __init__(self) -> None:
        self.now = 0.0

    def perf_counter(self) -> float:
        return self.now

    def sleep(self, seconds: float) -> None:
        self.now += seconds


class FakeClient:
    def __init__(self, indexed_values: list[int], points: int = 100_000) -> None:
        self.indexed_values = indexed_values
        self.points = points
        self.calls = 0

    def request(self, method: str, path: str):
        assert method == "GET"
        idx = self.indexed_values[min(self.calls, len(self.indexed_values) - 1)]
        self.calls += 1
        return {
            "result": {
                "status": "green",
                "optimizer_status": "ok",
                "points_count": self.points,
                "indexed_vectors_count": idx,
                "segments_count": 4,
            }
        }


def run(indexed_values: list[int]):
    clock = FakeClock()
    original_perf = module.time.perf_counter
    original_sleep = module.time.sleep
    module.time.perf_counter = clock.perf_counter
    module.time.sleep = clock.sleep
    try:
        result = module.wait_for_settle(
            FakeClient(indexed_values),
            "test",
            timeout_s=4,
            max_timeout_s=10,
            poll_s=2,
            stable_polls_required=3,
            require_full_index=True,
        )
    finally:
        module.time.perf_counter = original_perf
        module.time.sleep = original_sleep
    return result


def test_near_complete_but_stalled_does_not_extend() -> None:
    result = run([98_048, 98_048, 98_048, 98_048])
    assert result["benchmark_ready"] is False
    assert result["timeout_extended"] is False
    assert result["extension_reason"] is None
    assert result["wait_seconds"] == 4.0
    assert result["seconds_since_index_progress"] is None


def test_recent_index_progress_can_extend() -> None:
    result = run([85_000, 91_000, 91_000, 91_000, 91_000, 91_000])
    assert result["benchmark_ready"] is False
    assert result["timeout_extended"] is True
    assert result["extension_reason"] in {"indexing-near-complete-recent-progress", "indexing-progress-recent"}
    assert result["wait_seconds"] == 10.0
    assert result["seconds_since_index_progress"] is not None


if __name__ == "__main__":
    test_near_complete_but_stalled_does_not_extend()
    test_recent_index_progress_can_extend()
    print("benchmark settle tests passed")
