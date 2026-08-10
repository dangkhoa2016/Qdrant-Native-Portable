#!/usr/bin/env bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

plan="$tmp/plan.txt"
bash "$PROJECT_DIR/scripts/benchmark-profiles.sh" \
  --profiles low-memory,balanced-lite,balanced-memory \
  --order alternate --cycles 2 --seed 17 --points 100000 --dimension 768 \
  --print-plan > "$plan"
cat > "$tmp/expected.txt" <<'EOF'
cycle=1 position=1 profile=low-memory
cycle=1 position=2 profile=balanced-lite
cycle=1 position=3 profile=balanced-memory
cycle=2 position=1 profile=balanced-memory
cycle=2 position=2 profile=balanced-lite
cycle=2 position=3 profile=low-memory
EOF
diff -u "$tmp/expected.txt" "$plan"

mkdir -p "$tmp/runs/cycle-1/01-low-memory" "$tmp/runs/cycle-1/02-balanced-memory"
cat > "$tmp/runs/cycle-1/01-low-memory/benchmark.json" <<'JSON'
{
  "benchmark":{"points":100000,"dimension":768,"repeat":3},
  "runtime":{"profile":"low-memory"},
  "aggregate":{
    "all_runs_benchmark_ready":true,
    "benchmark_ready_runs":3,
    "fully_indexed_runs":3,
    "median_throughput_points_per_second":{"http_ingestion":2300.0},
    "query_ms_cold_combined":{"p50":785.84,"p95":1793.088},
    "query_ms_warm_combined":{"p50":2.16,"p95":3.2},
    "qdrant_peak_sampled_rss_kb":720896,
    "system_minimum_sampled_available_memory_mb":2814
  }
}
JSON
cat > "$tmp/runs/cycle-1/01-low-memory/resource-monitor-summary.json" <<'JSON'
{"samples":100,"telemetry_continuity":"GAPPED","sample_gap_events":1,"maximum_sample_gap_seconds":652,"missing_monitor_seconds":650,"host_pause_or_monitor_stall_suspected":true,"minimum_mem_available_mb":500.72,"maximum_swap_used_mb":92.25,"swap_at_start_mb":92.25,"swap_growth_mb":0,"maximum_qdrant_processes":1,"qdrant_zombies_at_start":3,"qdrant_zombies_at_end":3,"maximum_qdrant_zombie_processes":3,"qdrant_zombie_growth":0,"maximum_qdrant_rss_mb":704.0,"maximum_benchmark_rss_mb":34.0,"pressure_samples":1}
JSON
cat > "$tmp/runs/cycle-1/01-low-memory/run-metadata.txt" <<'EOF'
cycle=1
position=1
profile=low-memory
EOF

cat > "$tmp/runs/cycle-1/02-balanced-memory/benchmark.json" <<'JSON'
{
  "benchmark":{"points":100000,"dimension":768,"repeat":3},
  "runtime":{"profile":"balanced-memory"},
  "aggregate":{
    "all_runs_benchmark_ready":false,
    "benchmark_ready_runs":2,
    "fully_indexed_runs":2,
    "median_throughput_points_per_second":{"http_ingestion":2200.0},
    "query_ms_cold_combined":{"p50":2.296,"p95":2.986},
    "query_ms_warm_combined":{"p50":2.196,"p95":3.0},
    "qdrant_peak_sampled_rss_kb":1056768,
    "system_minimum_sampled_available_memory_mb":2706
  }
}
JSON
cat > "$tmp/runs/cycle-1/02-balanced-memory/resource-monitor-summary.json" <<'JSON'
{"samples":100,"telemetry_continuity":"CONTINUOUS","sample_gap_events":0,"maximum_sample_gap_seconds":2,"missing_monitor_seconds":0,"host_pause_or_monitor_stall_suspected":false,"minimum_mem_available_mb":2450.0,"maximum_swap_used_mb":0,"swap_at_start_mb":0,"swap_growth_mb":0,"maximum_qdrant_processes":1,"maximum_qdrant_zombie_processes":0,"maximum_qdrant_rss_mb":1032.0,"maximum_benchmark_rss_mb":40.0,"pressure_samples":0}
JSON
cat > "$tmp/runs/cycle-1/02-balanced-memory/run-metadata.txt" <<'EOF'
cycle=1
position=2
profile=balanced-memory
EOF

python3 "$PROJECT_DIR/benchmarks/profile_compare.py" \
  --root "$tmp/runs" \
  --json-output "$tmp/comparison.json" \
  --markdown-output "$tmp/comparison.md"
python3 - "$tmp/comparison.json" <<'PY'
import json, sys
x=json.load(open(sys.argv[1]))
assert len(x['runs'])==2
low=next(r for r in x['runs'] if r['profile']=='low-memory')
bm=next(r for r in x['runs'] if r['profile']=='balanced-memory')
assert low['status']=='READY'
assert bm['status']=='PROVISIONAL'
assert low['benchmark_min_available_memory_mb']==2814
assert low['monitor_min_available_memory_mb']==500.72
assert low['monitor_max_qdrant_rss_mb']==704.0
assert low['monitor_qdrant_zombies_at_start']==3
assert low['monitor_max_qdrant_zombie_processes']==3
assert low['monitor_qdrant_zombie_growth']==0
assert low['monitor_pressure_samples']==1
assert low['monitor_swap_growth_mb']==0
assert low['monitor_telemetry_continuity']=='GAPPED'
assert low['monitor_maximum_sample_gap_seconds']==652
assert low['monitor_host_pause_or_stall_suspected'] is True
assert bm['monitor_telemetry_continuity']=='CONTINUOUS'
assert x['ready_profiles']==['low-memory']
PY

grep -q 'Monitor Min RAM' "$tmp/comparison.md"
grep -q 'Zombie' "$tmp/comparison.md"
grep -q 'Continuity' "$tmp/comparison.md"

echo 'profile comparison tests passed'
