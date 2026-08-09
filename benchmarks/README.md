# Benchmark Suite

> 🌐 Language / Ngôn ngữ: **English** | [Tiếng Việt](README.vi.md)

The dependency-free Python benchmark is for **repeatable development measurements on constrained hosts**. It is not a production concurrency/load-testing framework.

## Measurement phases

Each repeat performs:

1. deterministic vector generation;
2. JSON encoding;
3. HTTP ingestion into Qdrant;
4. settle wait until the collection is green, optimizer-idle, and unchanged for consecutive polls;
5. **cold queries before warm-up**;
6. warm-up using the **same deterministic query set** that will be measured;
7. warm measured queries.

For standard 50K/100K workloads, the suite additionally requires `indexed_vectors_count >= points_count` before measurement. The default settle timeout adapts by workload: 120s <=10K, 180s <=50K, 300s for 100K.

## Single workload

```bash
bash qdrant.sh benchmark \
  --points 10000 \
  --dimension 768 \
  --queries 100 \
  --cold-queries 20 \
  --warmup 100 \
  --repeat 3
```

Useful options include `--batch-size`, `--cold-queries`, `--queries`, `--warmup`, `--repeat`, `--settle-timeout`, `--settle-poll`, `--stable-polls`, `--require-full-index`, `--skip-settle`, `--keep`, `--no-raw-latencies`, and `--output`.

`--warmup` is a number of requests, not a separate query region. Requests cycle through the same IDs used by the warm measurement. Setting warmup >= queries warms every measured query at least once.

## Standard suite

```bash
bash qdrant.sh benchmark-suite
```

Workloads: 1K×384, 10K×768, 50K×768, 100K×768. Defaults are three repeats, 20 cold queries, 50 warm queries, and 50 same-set warm-up requests.

Quick validation:

```bash
bash qdrant.sh benchmark-suite --quick
```

Every suite writes an internal `benchmark-suite.log` plus per-workload JSON, `benchmark-report.json`, and `benchmark-report.md` under `$BASE_DIR/benchmarks/suite-.../`. This makes the result bundle useful even if the hosting terminal's own capture is incomplete.

## Reading the numbers

- **Cold p50/p95/max** exposes mmap/page-cache and on-disk index behavior.
- **Warm p50/p95/p99/max** measures the same query set after warm-up and is better for hot-cache application latency.
- **HTTP ingest pts/s** excludes client vector generation and JSON encoding.
- **Pipeline pts/s** includes generation, encoding, HTTP, and Qdrant.
- **Ready runs** passed green + optimizer-idle + stable-state checks; 50K/100K also require full indexing.
- **Peak Qdrant RSS** is checkpoint sampling, not total host memory.
- **Minimum available RAM** is Linux `MemAvailable`.

## Clean comparisons

When validating profile changes, stale data/logs/cache/runtime state can distort conclusions. Use the explicit test-only clean reinstall between A/B runs:

```bash
QDRANT_PROFILE=low-memory bash qdrant.sh reinstall-test --yes
bash qdrant.sh benchmark-suite --quick

QDRANT_PROFILE=balanced-lite bash qdrant.sh reinstall-test --yes
bash qdrant.sh benchmark-suite --quick
```

Never use destructive reinstall on important data. Normal setup/cleanup preserve storage.

## Adaptive settle and provisional results

The standard suite uses bounded progress-aware settle windows. Initial/max defaults are 120/180 seconds for <=10K, 180/300 for 50K, and 300/480 for 100K. If indexing is visibly progressing near the initial deadline, the benchmark can extend up to the maximum.

`benchmark-report.md` marks each workload `READY` or `PROVISIONAL`, reports cumulative settle time and run wall time, and records how many repeats used timeout extension. Do not rank a `PROVISIONAL` workload equally with one where every repeat was benchmark-ready.

## Validation-grade portable run

For a comparable hosted-VM baseline, prefer the one-command fresh entrypoint from an extracted canonical release:

```bash
bash run-fresh-qdrant-benchmarks.sh --yes
```

The parent wrapper safely purges recognized project runtime state and passes explicit baseline provenance to the smart wrapper. `clean_reinstall=0` means only that the smart wrapper did not perform a redundant second reinstall; `fresh_baseline=1` and `baseline_origin=purge-all-test` are the semantic freshness fields used for comparability. The older direct smart-wrapper flow remains supported with `BENCHMARK_REQUIRE_CLEAN_SOURCE=1 CLEAN_REINSTALL=1`.

Add `BENCHMARK_REQUIRE_READY=1` when automation should return non-zero for a `PROVISIONAL`, missing, unknown, or memory-skipped suite. The wrapper packages diagnostics before returning the strict status code.

The result bundle contains source integrity, runtime authorization evidence, continuous resource telemetry, benchmark readiness/comparability, and an acceptance verdict. A strong comparison artifact is:

```text
READY
+ source integrity CLEAN
+ fresh baseline provenance
= CLEAN_BASELINE
+ required runtime evidence
= ACCEPTED_BASELINE or ACCEPTED_WITH_WARNINGS
```

`ACCEPTED_WITH_WARNINGS` remains eligible for comparison. Resource telemetry distinguishes swap already present at benchmark start from swap growth observed during the benchmark, logs pressure transitions/deltas instead of repeating unchanged state, and reports MemAvailable p01/p05/median plus observed pressure duration. Sampling continuity is also recorded: long gaps are reported as unobserved monitor time, excluded from pressure-duration calculations, and surfaced as a host-pause-or-monitor-stall warning when large enough. Zombie Qdrant processes remain visible separately from live RSS, with start/end/maximum counts and benchmark-window growth so pre-existing host state is not mistaken for a regression.

## Source integrity

A public source archive contains `SOURCE-MANIFEST.json`. Verify an extracted tree with:

```bash
bash qdrant.sh source-integrity check \
  --root . \
  --require-clean \
  --json-output source-integrity.json
```

Generated/runtime files such as `.qdrant-base`, logs, interpreter caches, and runtime secrets are not part of the canonical source fingerprint. Benchmark result archives named `qdrant-benchmarks-*.zip(.sha256)` or `profile-ab-*.zip(.sha256)` are also excluded from the fingerprint and are reported under `ignored_generated_files`; this prevents copied result bundles from invalidating an otherwise canonical source tree. The exclusion is intentionally narrow: arbitrary ZIPs or new source/config files still make integrity `DIRTY`.

## Order-controlled profile A/B

```bash
bash qdrant.sh benchmark-profiles \
  --yes \
  --require-clean-source \
  --profiles low-memory,balanced-lite,balanced-memory \
  --order alternate \
  --cycles 2 \
  --points 100000 \
  --dimension 768
```

`profile-comparison.md` reports benchmark checkpoint RAM and continuous-monitor RAM separately, plus Qdrant RSS, telemetry continuity/max-gap/missing-time, swap start/max/growth, pressure samples/events, and zombie start/max/growth.

## Compare host artifacts

Compare run directories or packaged benchmark ZIPs without silently ranking dirty/provisional runs:

```bash
bash qdrant.sh compare-benchmarks \
  --json-output compare.json \
  --markdown-output compare.md \
  result-a.zip result-b.zip result-c.zip result-d.zip
```

Only runs accepted as clean comparable baselines enter the cold-p50 ranking. Excluded runs remain in the report with the reason.
