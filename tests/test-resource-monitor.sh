#!/usr/bin/env bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/cgroup" "$tmp/out"
cat > "$tmp/meminfo" <<'EOF'
MemTotal:        4194304 kB
MemAvailable:     307200 kB
SwapTotal:       1048576 kB
SwapFree:         786432 kB
EOF
cat > "$tmp/ps.txt" <<'EOF'
101 S qdrant 500000
102 Z qdrant 0
103 Z+ qdrant 0
104 Sl qdrant 220000
201 S python3 34000
202 S bash 5000
EOF
printf '805306368\n' > "$tmp/cgroup/memory.current"
printf '2147483648\n' > "$tmp/cgroup/memory.max"
cat > "$tmp/cgroup/memory.events" <<'EOF'
low 1
high 2
max 3
oom 1
oom_kill 0
EOF

RESOURCE_MONITOR_PS_FILE="$tmp/ps.txt" \
RESOURCE_MONITOR_MEMINFO_FILE="$tmp/meminfo" \
RESOURCE_MONITOR_CGROUP_DIR="$tmp/cgroup" \
  bash "$PROJECT_DIR/scripts/resource-monitor.sh" \
    --output-dir "$tmp/out" --once --benchmark-pid 201 >/dev/null

[[ -s "$tmp/out/resource-monitor.csv" ]]
[[ -s "$tmp/out/resource-monitor-summary.json" ]]
[[ -s "$tmp/out/resource-monitor-summary.md" ]]
[[ -s "$tmp/out/resource-pressure-events.log" ]]
python3 - "$tmp/out/resource-monitor-summary.json" <<'PY'
import json, sys
x=json.load(open(sys.argv[1]))
assert x['samples']==1
assert x['minimum_mem_available_mb']==300.0
assert x['maximum_swap_used_mb']==256.0
assert x['maximum_qdrant_processes']==2
assert x['maximum_qdrant_zombie_processes']==2
assert abs(x['maximum_qdrant_rss_mb'] - 703.125) < 0.01
assert abs(x['maximum_benchmark_rss_mb'] - 33.203125) < 0.01
assert x['maximum_cgroup_memory_current_mb']==768.0
assert x['cgroup_memory_limit_mb']==2048.0
assert x['maximum_cgroup_oom_events']==1
assert x['pressure_samples']==1
PY

grep -q 'memory-pressure' "$tmp/out/resource-pressure-events.log"

# Without an explicit benchmark PID, the monitor should still discover the
# benchmark client by command line so the smart wrapper captures client RSS.
mkdir -p "$tmp/out-auto"
cat > "$tmp/ps-auto.txt" <<'EOF'
101 S qdrant 500000 /tmp/qdrant
201 S python3 34000 python3 /project/benchmarks/benchmark.py --points 100000
202 S bash 5000 bash run-smart-qdrant-benchmarks.sh
EOF
RESOURCE_MONITOR_PS_FILE="$tmp/ps-auto.txt" \
RESOURCE_MONITOR_MEMINFO_FILE="$tmp/meminfo" \
RESOURCE_MONITOR_CGROUP_DIR="$tmp/cgroup" \
  bash "$PROJECT_DIR/scripts/resource-monitor.sh" --output-dir "$tmp/out-auto" --once >/dev/null
python3 - "$tmp/out-auto/resource-monitor-summary.json" <<'PY'
import json, sys
x=json.load(open(sys.argv[1]))
assert abs(x['maximum_benchmark_rss_mb'] - 33.203125) < 0.01, x
PY

echo 'resource monitor tests passed'

# Static pre-existing swap must not be classified as benchmark-induced pressure.
mkdir -p "$tmp/static-swap"
cat > "$tmp/static-swap/input.csv" <<'CSV'
timestamp_utc,epoch,mem_total_mb,mem_available_mb,swap_total_mb,swap_used_mb,qdrant_processes,qdrant_zombie_processes,qdrant_rss_mb,benchmark_rss_mb,cgroup_memory_current_mb,cgroup_memory_limit_mb,cgroup_oom_events,cgroup_high_events,cgroup_max_events
2026-08-16T00:00:00Z,0,4096,3000,4096,92.25,1,7,700,30,1000,4096,0,0,0
2026-08-16T00:00:02Z,2,4096,2950,4096,92.25,1,7,710,31,1010,4096,0,0,0
2026-08-16T00:00:04Z,4,4096,2900,4096,92.25,1,7,720,32,1020,4096,0,0,0
CSV
python3 "$PROJECT_DIR/benchmarks/resource_summary.py" \
  --csv "$tmp/static-swap/input.csv" \
  --json-output "$tmp/static-swap/summary.json" \
  --markdown-output "$tmp/static-swap/summary.md" \
  --pressure-log "$tmp/static-swap/pressure.log"
python3 - "$tmp/static-swap/summary.json" <<'PY'
import json, sys
x=json.load(open(sys.argv[1]))
assert x['swap_at_start_mb']==92.25
assert x['swap_at_end_mb']==92.25
assert x['maximum_swap_used_mb']==92.25
assert x['swap_growth_mb']==0
assert x['swap_growth_events']==0
assert x['swap_present_samples']==3
assert x['qdrant_zombies_at_start']==7
assert x['qdrant_zombies_at_end']==7
assert x['maximum_qdrant_zombie_processes']==7
assert x['qdrant_zombie_growth']==0
assert x['pressure_samples']==0
assert x['pressure_event_count']==0
PY
[[ ! -s "$tmp/static-swap/pressure.log" ]]


# Zombie counts use the same baseline/growth interpretation as swap. A transient
# increase must remain visible even if the count returns to its starting value.
mkdir -p "$tmp/dynamic-zombies"
cat > "$tmp/dynamic-zombies/input.csv" <<'CSV'
timestamp_utc,epoch,mem_total_mb,mem_available_mb,swap_total_mb,swap_used_mb,qdrant_processes,qdrant_zombie_processes,qdrant_rss_mb,benchmark_rss_mb,cgroup_memory_current_mb,cgroup_memory_limit_mb,cgroup_oom_events,cgroup_high_events,cgroup_max_events
2026-08-16T00:00:00Z,0,8192,6000,0,0,1,7,1000,30,1200,8192,0,0,0
2026-08-16T00:00:02Z,2,8192,6000,0,0,1,8,1000,30,1200,8192,0,0,0
2026-08-16T00:00:04Z,4,8192,6000,0,0,1,7,1000,30,1200,8192,0,0,0
CSV
python3 "$PROJECT_DIR/benchmarks/resource_summary.py" \
  --csv "$tmp/dynamic-zombies/input.csv" \
  --json-output "$tmp/dynamic-zombies/summary.json" \
  --markdown-output "$tmp/dynamic-zombies/summary.md" \
  --pressure-log "$tmp/dynamic-zombies/pressure.log"
python3 - "$tmp/dynamic-zombies/summary.json" <<'PY'
import json, sys
x=json.load(open(sys.argv[1]))
assert x['qdrant_zombies_at_start']==7
assert x['qdrant_zombies_at_end']==7
assert x['maximum_qdrant_zombie_processes']==8
assert x['qdrant_zombie_growth']==1
PY

# Swap growth and low-memory pressure should be event-oriented, not repeated
# unchanged-state log lines. Percentiles/durations preserve transient context.
mkdir -p "$tmp/dynamic-pressure"
cat > "$tmp/dynamic-pressure/input.csv" <<'CSV'
timestamp_utc,epoch,mem_total_mb,mem_available_mb,swap_total_mb,swap_used_mb,qdrant_processes,qdrant_zombie_processes,qdrant_rss_mb,benchmark_rss_mb,cgroup_memory_current_mb,cgroup_memory_limit_mb,cgroup_oom_events,cgroup_high_events,cgroup_max_events
2026-08-16T00:00:00Z,0,4096,800,4096,92.25,1,0,700,30,1000,4096,1,2,3
2026-08-16T00:00:02Z,2,4096,300,4096,100,1,0,710,31,1010,4096,1,2,3
2026-08-16T00:00:04Z,4,4096,250,4096,100,1,0,720,32,1020,4096,2,2,4
2026-08-16T00:00:06Z,6,4096,900,4096,110,1,0,730,33,1030,4096,2,3,4
CSV
python3 "$PROJECT_DIR/benchmarks/resource_summary.py" \
  --csv "$tmp/dynamic-pressure/input.csv" \
  --json-output "$tmp/dynamic-pressure/summary.json" \
  --markdown-output "$tmp/dynamic-pressure/summary.md" \
  --pressure-log "$tmp/dynamic-pressure/pressure.log"
python3 - "$tmp/dynamic-pressure/summary.json" <<'PY'
import json, sys
x=json.load(open(sys.argv[1]))
assert x['swap_at_start_mb']==92.25
assert x['swap_at_end_mb']==110.0
assert x['swap_growth_mb']==17.75
assert x['swap_growth_events']==2
assert x['swap_present_samples']==4
assert x['mem_available_p01_mb']==251.5
assert x['mem_available_p05_mb']==257.5
assert x['mem_available_median_mb']==550.0
assert x['seconds_below_mem_available_threshold']==4.0
assert x['longest_mem_pressure_duration_seconds']==4.0
assert x['pressure_samples']==3, x
assert x['pressure_event_count']==7, x
PY
[[ "$(grep -c 'memory-pressure-entered' "$tmp/dynamic-pressure/pressure.log")" -eq 1 ]]
[[ "$(grep -c 'memory-pressure-cleared' "$tmp/dynamic-pressure/pressure.log")" -eq 1 ]]
[[ "$(grep -c 'swap-growth' "$tmp/dynamic-pressure/pressure.log")" -eq 2 ]]
[[ "$(grep -c 'cgroup-.*-growth' "$tmp/dynamic-pressure/pressure.log")" -eq 3 ]]


# A long sampling gap must not be interpreted as continuous memory pressure.
# This reproduces the real CodeSandbox 8 GB shape: one low-memory sample,
# then ~652 seconds without monitor samples, then normal memory again.
mkdir -p "$tmp/gapped-pressure"
cat > "$tmp/gapped-pressure/input.csv" <<'CSV'
timestamp_utc,epoch,mem_total_mb,mem_available_mb,swap_total_mb,swap_used_mb,qdrant_processes,qdrant_zombie_processes,qdrant_rss_mb,benchmark_rss_mb,cgroup_memory_current_mb,cgroup_memory_limit_mb,cgroup_oom_events,cgroup_high_events,cgroup_max_events
2026-08-16T00:00:00Z,0,8192,6000,0,0,1,0,1000,30,1200,8192,0,0,0
2026-08-16T00:00:02Z,2,8192,377,0,0,1,0,1010,31,1210,8192,0,0,0
2026-08-16T00:10:54Z,654,8192,6075,0,0,1,0,1020,32,1220,8192,0,0,0
2026-08-16T00:10:56Z,656,8192,6100,0,0,1,0,1030,33,1230,8192,0,0,0
CSV
python3 "$PROJECT_DIR/benchmarks/resource_summary.py" \
  --csv "$tmp/gapped-pressure/input.csv" \
  --json-output "$tmp/gapped-pressure/summary.json" \
  --markdown-output "$tmp/gapped-pressure/summary.md" \
  --pressure-log "$tmp/gapped-pressure/pressure.log" \
  --expected-interval-seconds 2
python3 - "$tmp/gapped-pressure/summary.json" <<'PY'
import json, sys
x=json.load(open(sys.argv[1]))
assert x['expected_sample_interval_seconds']==2.0, x
assert x['sample_gap_tolerance_seconds']==6.0, x
assert x['sample_gap_events']==1, x
assert x['maximum_sample_gap_seconds']==652.0, x
assert x['missing_monitor_seconds']==650.0, x
assert x['telemetry_continuity']=='GAPPED', x
assert x['host_pause_or_monitor_stall_suspected'] is True, x
assert x['pressure_samples']==1, x
assert x['seconds_below_mem_available_threshold']==0.0, x
assert x['longest_mem_pressure_duration_seconds']==0.0, x
assert x['memory_pressure_duration_complete'] is False, x
PY
grep -q 'telemetry-gap' "$tmp/gapped-pressure/pressure.log"
[[ "$(grep -c 'memory-pressure-entered' "$tmp/gapped-pressure/pressure.log")" -eq 1 ]]
[[ "$(grep -c 'memory-pressure-cleared' "$tmp/gapped-pressure/pressure.log")" -eq 0 ]]
