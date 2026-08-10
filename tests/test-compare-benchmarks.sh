#!/usr/bin/env bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

make_run() {
  local dir="$1" platform="$2" profile="$3" cold="$4" warm="$5" comp="$6" accepted="$7"
  mkdir -p "$dir/full-suite"
  cat > "$dir/run-metadata.txt" <<META
platform=$platform
memory_total_mb=8192
memory_effective_mb=8192
resource_profile=$profile
clean_reinstall=1
full_suite=1
META
  cat > "$dir/benchmark-status.json" <<JSON
{"overall_status":"READY","comparability":"$comp","ready_for_ranking":$accepted,"source_integrity":"CLEAN"}
JSON
  cat > "$dir/benchmark-acceptance.json" <<JSON
{"verdict":"ACCEPTED_BASELINE","accepted_for_comparison":$accepted,"warnings":[]}
JSON
  cat > "$dir/full-suite/benchmark-report.json" <<JSON
{"suite_status":"READY","results":[{"points":100000,"dimension":768,"status":"READY","cold_p50_ms":$cold,"cold_p95_ms":$cold,"warm_p50_ms":$warm,"warm_p95_ms":$warm,"http_ingestion_points_per_second_median":2200,"qdrant_peak_sampled_rss_kb":1048576,"minimum_available_memory_mb":5000}]}
JSON
  cat > "$dir/resource-monitor-summary.json" <<'JSON'
{"telemetry_continuity":"GAPPED","sample_gap_events":1,"maximum_sample_gap_seconds":652,"missing_monitor_seconds":650,"host_pause_or_monitor_stall_suspected":true,"minimum_mem_available_mb":4800,"maximum_qdrant_rss_mb":1024,"maximum_swap_used_mb":92.25,"swap_at_start_mb":92.25,"swap_growth_mb":0,"pressure_samples":0,"pressure_event_count":0,"qdrant_zombies_at_start":7,"qdrant_zombies_at_end":7,"maximum_qdrant_zombie_processes":7,"qdrant_zombie_growth":0}
JSON
}
make_run "$tmp/cs8" codesandbox balanced-memory 2.2 2.1 CLEAN_BASELINE true
make_run "$tmp/gh8" github-codespaces balanced-memory 2.5 2.2 CLEAN_BASELINE true
make_run "$tmp/dirty" codesandbox balanced-memory 1.8 1.9 DIRTY_SOURCE false

bash "$PROJECT_DIR/scripts/compare-benchmarks.sh" --json-output "$tmp/compare.json" --markdown-output "$tmp/compare.md" "$tmp/cs8" "$tmp/gh8" "$tmp/dirty"
python3 - "$tmp/compare.json" <<'PY'
import json, sys
x=json.load(open(sys.argv[1]))
assert len(x['runs'])==3
assert len(x['eligible_runs'])==2
assert x['ranking'][0]['platform']=='codesandbox'
assert x['ranking'][0]['cold_p50_ms']==2.2
assert any(r['comparability']=='DIRTY_SOURCE' and not r['eligible_for_ranking'] for r in x['runs'])
assert all(r['monitor_swap_growth_mb']==0 for r in x['runs']), x['runs']
assert all(r['monitor_telemetry_continuity']=='GAPPED' for r in x['runs']), x['runs']
assert all(r['monitor_maximum_sample_gap_seconds']==652 for r in x['runs']), x['runs']
assert all(r['monitor_host_pause_or_stall_suspected'] is True for r in x['runs']), x['runs']
assert all(r['monitor_qdrant_zombies_at_start']==7 for r in x['runs']), x['runs']
assert all(r['monitor_max_qdrant_zombies']==7 for r in x['runs']), x['runs']
assert all(r['monitor_qdrant_zombie_growth']==0 for r in x['runs']), x['runs']
PY
grep -q 'Excluded from ranking' "$tmp/compare.md"
grep -q 'Continuity' "$tmp/compare.md"

echo 'cross-host benchmark comparison tests passed'
