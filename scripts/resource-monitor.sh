#!/usr/bin/env bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

output_dir=""
interval="2"
once=0
benchmark_pid=""

usage() {
  cat <<'EOF'
Usage: bash scripts/resource-monitor.sh --output-dir DIR [options]

Options:
  --interval SEC        Sampling interval (default: 2)
  --benchmark-pid PID   Track RSS for the benchmark/client process
  --once                Take one sample and exit
  -h, --help            Show help

Outputs:
  resource-monitor.csv
  resource-monitor-summary.json
  resource-monitor-summary.md
  resource-pressure-events.log
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-dir) output_dir="${2:?missing value}"; shift 2 ;;
    --interval) interval="${2:?missing value}"; shift 2 ;;
    --benchmark-pid) benchmark_pid="${2:?missing value}"; shift 2 ;;
    --once) once=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown resource-monitor option: $1" >&2; exit 1 ;;
  esac
done
[[ -n "$output_dir" ]] || { echo 'ERROR: --output-dir is required' >&2; exit 1; }
[[ "$interval" =~ ^[0-9]+([.][0-9]+)?$ ]] || { echo 'ERROR: --interval must be numeric' >&2; exit 1; }
[[ -z "$benchmark_pid" || "$benchmark_pid" =~ ^[0-9]+$ ]] || { echo 'ERROR: --benchmark-pid must be an integer' >&2; exit 1; }
mkdir -p "$output_dir"

csv="$output_dir/resource-monitor.csv"
summary_json="$output_dir/resource-monitor-summary.json"
summary_md="$output_dir/resource-monitor-summary.md"
pressure_log="$output_dir/resource-pressure-events.log"
meminfo_file="${RESOURCE_MONITOR_MEMINFO_FILE:-/proc/meminfo}"
cgroup_dir="${RESOURCE_MONITOR_CGROUP_DIR:-/sys/fs/cgroup}"
ps_file="${RESOURCE_MONITOR_PS_FILE:-}"

printf '%s\n' 'timestamp_utc,epoch,mem_total_mb,mem_available_mb,swap_total_mb,swap_used_mb,qdrant_processes,qdrant_zombie_processes,qdrant_rss_mb,benchmark_rss_mb,cgroup_memory_current_mb,cgroup_memory_limit_mb,cgroup_oom_events,cgroup_high_events,cgroup_max_events' > "$csv"

kb_field() {
  local key="$1"
  awk -v k="$key" '$1 == k":" {printf "%.3f", $2/1024}' "$meminfo_file" 2>/dev/null || true
}

read_cgroup_bytes_mb() {
  local name="$1" raw=""
  if [[ -r "$cgroup_dir/$name" ]]; then
    raw="$(cat "$cgroup_dir/$name" 2>/dev/null || true)"
  elif [[ -r "$cgroup_dir/memory/$name" ]]; then
    raw="$(cat "$cgroup_dir/memory/$name" 2>/dev/null || true)"
  fi
  if [[ "$raw" =~ ^[0-9]+$ ]]; then
    awk -v v="$raw" 'BEGIN {printf "%.3f", v/1048576}'
  fi
}

cgroup_event() {
  local key="$1" file=""
  if [[ -r "$cgroup_dir/memory.events" ]]; then file="$cgroup_dir/memory.events"
  elif [[ -r "$cgroup_dir/memory/memory.events" ]]; then file="$cgroup_dir/memory/memory.events"
  fi
  [[ -n "$file" ]] || { printf '0'; return; }
  awk -v k="$key" '$1==k {v=$2} END {print v+0}' "$file" 2>/dev/null || printf '0'
}

ps_snapshot() {
  if [[ -n "$ps_file" ]]; then
    cat "$ps_file"
  else
    ps -eo pid=,stat=,comm=,rss=,args= 2>/dev/null || true
  fi
}

sample_once() {
  local ts epoch mem_total mem_avail swap_total swap_free swap_used
  local q_live=0 q_zombie=0 q_rss_kb=0 bench_rss_kb=0
  local pid stat comm rss args
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  epoch="$(date +%s)"
  mem_total="$(kb_field MemTotal)"; mem_total="${mem_total:-0}"
  mem_avail="$(kb_field MemAvailable)"; mem_avail="${mem_avail:-0}"
  swap_total="$(kb_field SwapTotal)"; swap_total="${swap_total:-0}"
  swap_free="$(kb_field SwapFree)"; swap_free="${swap_free:-0}"
  swap_used="$(awk -v t="$swap_total" -v f="$swap_free" 'BEGIN {v=t-f; if(v<0)v=0; printf "%.3f", v}')"

  while read -r pid stat comm rss args; do
    [[ "$pid" =~ ^[0-9]+$ && "$rss" =~ ^[0-9]+$ ]] || continue
    if [[ "$comm" == qdrant* ]]; then
      if [[ "$stat" == Z* ]]; then
        q_zombie=$((q_zombie + 1))
      else
        q_live=$((q_live + 1))
        q_rss_kb=$((q_rss_kb + rss))
      fi
    fi
    if [[ -n "$benchmark_pid" && "$pid" == "$benchmark_pid" ]]; then
      bench_rss_kb=$((bench_rss_kb + rss))
    elif [[ -z "$benchmark_pid" && "$args" == *"benchmarks/benchmark.py"* ]]; then
      # The smart wrapper launches benchmark.py through benchmark-suite.sh, so
      # its PID is not known when the monitor starts. Discover the active
      # client by command line to preserve client-RSS telemetry.
      bench_rss_kb=$((bench_rss_kb + rss))
    fi
  done < <(ps_snapshot)

  local q_rss_mb bench_rss_mb cg_current cg_limit oom high maxev
  q_rss_mb="$(awk -v v="$q_rss_kb" 'BEGIN {printf "%.3f", v/1024}')"
  bench_rss_mb="$(awk -v v="$bench_rss_kb" 'BEGIN {printf "%.3f", v/1024}')"
  cg_current="$(read_cgroup_bytes_mb memory.current)"
  cg_limit="$(read_cgroup_bytes_mb memory.max)"
  oom="$(cgroup_event oom)"
  # Count OOM kills as OOM events too when the kernel exposes both counters.
  oom_kill="$(cgroup_event oom_kill)"
  oom=$((oom + oom_kill))
  high="$(cgroup_event high)"
  maxev="$(cgroup_event max)"

  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "$ts" "$epoch" "$mem_total" "$mem_avail" "$swap_total" "$swap_used" \
    "$q_live" "$q_zombie" "$q_rss_mb" "$bench_rss_mb" \
    "$cg_current" "$cg_limit" "$oom" "$high" "$maxev" >> "$csv"
}

summarized=0
finish() {
  [[ "$summarized" == "0" ]] || return 0
  summarized=1
  python3 "$PROJECT_DIR/benchmarks/resource_summary.py" \
    --csv "$csv" \
    --json-output "$summary_json" \
    --markdown-output "$summary_md" \
    --pressure-log "$pressure_log" \
    --expected-interval-seconds "$interval" >/dev/null 2>&1 || true
}
trap 'finish; exit 0' INT TERM HUP
trap 'finish' EXIT

if [[ "$once" == "1" ]]; then
  sample_once
  exit 0
fi

while :; do
  sample_once
  sleep "$interval"
done
