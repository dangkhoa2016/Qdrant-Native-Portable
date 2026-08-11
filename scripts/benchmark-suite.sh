#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname "$0")/common.sh"
require python3
require_secrets
qdrant_ready || fail "Qdrant must be running before benchmarking"
ensure_runtime_dirs

repeat=3
queries=50
warmup=""
cold_queries=20
batch_size=128
settle_timeout=""
settle_max_timeout=""
stable_polls=3
quick=0

usage() {
    cat <<'USAGE'
Usage: bash qdrant.sh benchmark-suite [options]

Options:
  --repeat N                 Recreate/rerun each workload N times (default: 3)
  --queries N                Warm measured queries per repeat (default: 50)
  --cold-queries N           Cold queries before warm-up (default: 20)
  --warmup N                 Warm-up requests using same query set (default: queries)
  --batch-size N             Upsert batch size (default: 128)
  --settle-timeout SEC       Initial settle timeout for every workload
  --settle-max-timeout SEC   Maximum bounded adaptive settle timeout
  --stable-polls N           Consecutive stable ready polls required (default: 3)
  --quick                    Run only 1K×384 and 10K×768 with repeat=1
  -h, --help                 Show help

Adaptive defaults:
  <=10K: 120s initial / 180s maximum
  50K:   180s initial / 300s maximum
  100K:  300s initial / 480s maximum

50K/100K require full HNSW indexing. If Qdrant is still making progress near
the initial timeout, the benchmark may extend up to the bounded maximum.
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --repeat) repeat="${2:?missing value}"; shift 2 ;;
        --queries) queries="${2:?missing value}"; shift 2 ;;
        --cold-queries) cold_queries="${2:?missing value}"; shift 2 ;;
        --warmup) warmup="${2:?missing value}"; shift 2 ;;
        --batch-size) batch_size="${2:?missing value}"; shift 2 ;;
        --settle-timeout) settle_timeout="${2:?missing value}"; shift 2 ;;
        --settle-max-timeout) settle_max_timeout="${2:?missing value}"; shift 2 ;;
        --stable-polls) stable_polls="${2:?missing value}"; shift 2 ;;
        --quick) quick=1; repeat=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) fail "Unknown benchmark-suite option: $1" ;;
    esac
done

for value in "$repeat" "$queries" "$batch_size" "$stable_polls"; do
    [[ "$value" =~ ^[1-9][0-9]*$ ]] || fail "repeat, queries, batch-size, and stable-polls must be positive integers"
done
[[ "$cold_queries" =~ ^[0-9]+$ ]] || fail "cold-queries must be a non-negative integer"
[[ -z "$warmup" || "$warmup" =~ ^[0-9]+$ ]] || fail "warmup must be a non-negative integer"
[[ -z "$settle_timeout" || "$settle_timeout" =~ ^[0-9]+$ ]] || fail "settle-timeout must be a non-negative integer"
[[ -z "$settle_max_timeout" || "$settle_max_timeout" =~ ^[0-9]+$ ]] || fail "settle-max-timeout must be a non-negative integer"
[[ -n "$warmup" ]] || warmup="$queries"
if [[ -n "$settle_timeout" && -n "$settle_max_timeout" ]] && (( settle_max_timeout < settle_timeout )); then
    fail "--settle-max-timeout must be >= --settle-timeout"
fi

suite_id="$(date -u +%Y%m%dT%H%M%SZ)"
suite_dir="$QDRANT_BENCHMARKS/suite-$suite_id"
mkdir -p "$suite_dir"
suite_log="$suite_dir/benchmark-suite.log"
suite_started_epoch="$(date +%s)"

exec > >(tee -a "$suite_log") 2>&1

adaptive_timeouts() {
    local points="$1" initial maximum
    if [[ -n "$settle_timeout" ]]; then
        initial="$settle_timeout"
    elif (( points <= 10000 )); then initial=120
    elif (( points <= 50000 )); then initial=180
    else initial=300
    fi

    if [[ -n "$settle_max_timeout" ]]; then
        maximum="$settle_max_timeout"
    elif [[ -n "$settle_timeout" ]]; then maximum="$initial"
    elif (( points <= 10000 )); then maximum=180
    elif (( points <= 50000 )); then maximum=300
    else maximum=480
    fi
    (( maximum >= initial )) || maximum="$initial"
    printf '%s:%s' "$initial" "$maximum"
}

workloads=("1000:384" "10000:768")
if [[ "$quick" != "1" ]]; then workloads+=("50000:768" "100000:768"); fi

result_files=()
header "Benchmark suite"
info "Output:       $suite_dir"
info "Internal log: $suite_log"
info "Repeat:       $repeat"
info "Queries:      $queries warm + $cold_queries cold"
info "Warm-up:      $warmup requests using measured set"
info "Batch size:   $batch_size"
info "Stable polls: $stable_polls"
info "Profile:      $QDRANT_PROFILE"
info "Platform:     $PLATFORM"

for workload in "${workloads[@]}"; do
    points="${workload%%:*}"
    dim="${workload##*:}"
    timeout_pair="$(adaptive_timeouts "$points")"
    timeout="${timeout_pair%%:*}"
    max_timeout="${timeout_pair##*:}"
    output="$suite_dir/benchmark-${points}p-${dim}d.json"
    args=(
        --points "$points"
        --dimension "$dim"
        --batch-size "$batch_size"
        --queries "$queries"
        --cold-queries "$cold_queries"
        --warmup "$warmup"
        --repeat "$repeat"
        --settle-timeout "$timeout"
        --settle-max-timeout "$max_timeout"
        --stable-polls "$stable_polls"
        --output "$output"
    )
    if (( points >= 50000 )); then args+=(--require-full-index); fi
    printf '\n'
    info "Running ${points} points × ${dim} dimensions (settle ${timeout}s → max ${max_timeout}s)"
    bash "$SCRIPT_DIR/benchmark.sh" "${args[@]}"
    result_files+=("$output")
done

suite_finished_epoch="$(date +%s)"
suite_wall_seconds=$(( suite_finished_epoch - suite_started_epoch ))
python3 "$PROJECT_DIR/benchmarks/report.py" \
    --suite-wall-seconds "$suite_wall_seconds" \
    --json-output "$suite_dir/benchmark-report.json" \
    --markdown-output "$suite_dir/benchmark-report.md" \
    "${result_files[@]}"

printf '\n'
ok "Benchmark suite complete"
info "Suite wall time:  ${suite_wall_seconds}s"
info "JSON report:      $suite_dir/benchmark-report.json"
info "Markdown report:  $suite_dir/benchmark-report.md"
info "Internal log:     $suite_log"
