#!/usr/bin/env bash
set -Eeuo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

profiles_csv="low-memory,balanced-lite,balanced-memory"
order="listed"
cycles=1
seed=1
points=100000
dimension=768
repeat=3
queries=50
cold_queries=20
warmup=50
batch_size=128
stable_polls=3
yes=0
require_clean=0
print_plan=0
force_unmanaged=0

usage() {
  cat <<'EOF'
Usage: bash qdrant.sh benchmark-profiles [options]

Destructive profile A/B benchmark. Every measured profile is installed as a
fresh disposable runtime before measurement.

Options:
  --profiles CSV             Profiles to test (default: low-memory,balanced-lite,balanced-memory)
  --order MODE               listed|reverse|alternate|shuffle (default: listed)
  --cycles N                 Number of cycles (default: 1)
  --seed N                   Deterministic shuffle seed (default: 1)
  --points N                 Points per run (default: 100000)
  --dimension N              Vector dimension (default: 768)
  --repeat N                 Benchmark repeats per profile/run (default: 3)
  --queries N                Warm measured queries (default: 50)
  --cold-queries N           Cold measured queries (default: 20)
  --warmup N                 Warm-up requests (default: 50)
  --batch-size N             Upsert batch size (default: 128)
  --stable-polls N           Stable readiness polls (default: 3)
  --require-clean-source     Refuse to run unless canonical source integrity is CLEAN
  --force-unmanaged          Allow one-time removal of a legacy unmanaged test runtime
  --print-plan               Print deterministic cycle/profile order only; non-destructive
  --yes                      Required acknowledgement for destructive execution
  -h, --help                 Show help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profiles) profiles_csv="${2:?missing value}"; shift 2 ;;
    --order) order="${2:?missing value}"; shift 2 ;;
    --cycles) cycles="${2:?missing value}"; shift 2 ;;
    --seed) seed="${2:?missing value}"; shift 2 ;;
    --points) points="${2:?missing value}"; shift 2 ;;
    --dimension) dimension="${2:?missing value}"; shift 2 ;;
    --repeat) repeat="${2:?missing value}"; shift 2 ;;
    --queries) queries="${2:?missing value}"; shift 2 ;;
    --cold-queries) cold_queries="${2:?missing value}"; shift 2 ;;
    --warmup) warmup="${2:?missing value}"; shift 2 ;;
    --batch-size) batch_size="${2:?missing value}"; shift 2 ;;
    --stable-polls) stable_polls="${2:?missing value}"; shift 2 ;;
    --require-clean-source) require_clean=1; shift ;;
    --force-unmanaged) force_unmanaged=1; shift ;;
    --print-plan) print_plan=1; shift ;;
    --yes) yes=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown benchmark-profiles option: $1" >&2; exit 1 ;;
  esac
done

for value in "$cycles" "$seed" "$points" "$dimension" "$repeat" "$queries" "$batch_size" "$stable_polls"; do
  [[ "$value" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: positive integer expected, got: $value" >&2; exit 1; }
done
for value in "$cold_queries" "$warmup"; do
  [[ "$value" =~ ^[0-9]+$ ]] || { echo "ERROR: non-negative integer expected, got: $value" >&2; exit 1; }
done
case "$order" in listed|reverse|alternate|shuffle) ;; *) echo "ERROR: invalid --order: $order" >&2; exit 1 ;; esac
IFS=',' read -r -a profiles <<< "$profiles_csv"
(( ${#profiles[@]} > 0 )) || { echo 'ERROR: --profiles is empty' >&2; exit 1; }
for profile in "${profiles[@]}"; do
  case "$profile" in low-memory|balanced-lite|balanced-memory|balanced|performance) ;; *) echo "ERROR: unsupported profile: $profile" >&2; exit 1 ;; esac
done

cycle_profiles() {
  local cycle="$1"
  case "$order" in
    listed) printf '%s\n' "${profiles[@]}" ;;
    reverse)
      local i; for ((i=${#profiles[@]}-1; i>=0; i--)); do printf '%s\n' "${profiles[$i]}"; done ;;
    alternate)
      if (( cycle % 2 == 1 )); then
        printf '%s\n' "${profiles[@]}"
      else
        local i; for ((i=${#profiles[@]}-1; i>=0; i--)); do printf '%s\n' "${profiles[$i]}"; done
      fi ;;
    shuffle)
      printf '%s\n' "${profiles[@]}" | python3 -c 'import random,sys; a=[x.strip() for x in sys.stdin if x.strip()]; random.Random(int(sys.argv[1])).shuffle(a); print("\\n".join(a))' "$((seed + cycle - 1))" ;;
  esac
}

emit_plan() {
  local cycle pos profile
  for ((cycle=1; cycle<=cycles; cycle++)); do
    pos=0
    while IFS= read -r profile; do
      [[ -n "$profile" ]] || continue
      pos=$((pos + 1))
      printf 'cycle=%s position=%s profile=%s\n' "$cycle" "$pos" "$profile"
    done < <(cycle_profiles "$cycle")
  done
}

if [[ "$print_plan" == "1" ]]; then
  emit_plan
  exit 0
fi
[[ "$yes" == "1" ]] || { echo 'ERROR: destructive profile benchmarking requires --yes' >&2; exit 1; }

# shellcheck disable=SC1091
source "$PROJECT_DIR/scripts/common.sh"
require python3

if [[ "$require_clean" == "1" ]]; then
  python3 "$PROJECT_DIR/scripts/source-integrity.py" check \
    --root "$PROJECT_DIR" --json-output /tmp/qnp-profile-source-integrity-$$.json --require-clean || \
    fail "Source integrity is not CLEAN; refusing profile A/B benchmark"
  rm -f /tmp/qnp-profile-source-integrity-$$.json
fi

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
mem_mb="$(total_memory_mb)"
safe_platform="$(printf '%s' "$PLATFORM" | tr -cs 'A-Za-z0-9._-' '-')"
export_root="${QDRANT_BENCHMARK_EXPORT_DIR:-${HOME:-/tmp}/qdrant-benchmark-exports}"
ab_root="$export_root/profile-ab-${points}p-${dimension}d-${stamp}-${safe_platform}-${mem_mb}mb"
mkdir -p "$ab_root/runs"
exec > >(tee -a "$ab_root/terminal.log") 2>&1
emit_plan > "$ab_root/execution-plan.txt"
python3 "$PROJECT_DIR/scripts/source-integrity.py" check --root "$PROJECT_DIR" --json-output "$ab_root/source-integrity.json" || true

adaptive_pair() {
  if (( points <= 10000 )); then printf '120:180'
  elif (( points <= 50000 )); then printf '180:300'
  else printf '300:480'
  fi
}
timeout_pair="$(adaptive_pair)"
settle_timeout="${timeout_pair%%:*}"
settle_max="${timeout_pair##*:}"

cycle=0
while IFS=' ' read -r cycle_field pos_field profile_field; do
  cycle="${cycle_field#cycle=}"
  pos="${pos_field#position=}"
  profile="${profile_field#profile=}"
  run_dir="$ab_root/runs/cycle-$cycle/$(printf '%02d' "$pos")-$profile"
  mkdir -p "$run_dir"
  cat > "$run_dir/run-metadata.txt" <<META
cycle=$cycle
position=$pos
profile=$profile
points=$points
dimension=$dimension
repeat=$repeat
order=$order
seed=$seed
META

  printf '\n========== cycle %s position %s profile %s ==========\n' "$cycle" "$pos" "$profile"
  if [[ -x "$QDRANT_BIN" || -f "$INSTANCE_MARKER" ]]; then
    args=(--yes)
    if [[ ! -f "$INSTANCE_MARKER" && "$force_unmanaged" == "1" ]]; then args+=(--force-unmanaged); fi
    QDRANT_PROFILE="$profile" bash "$PROJECT_DIR/qdrant.sh" reinstall-test "${args[@]}"
  else
    QDRANT_PROFILE="$profile" bash "$PROJECT_DIR/qdrant.sh" setup
  fi

  bash "$PROJECT_DIR/scripts/resource-monitor.sh" --output-dir "$run_dir" --interval 2 >/dev/null 2>&1 &
  monitor_pid=$!
  benchmark_rc=0
  args=(
    --points "$points" --dimension "$dimension" --repeat "$repeat"
    --queries "$queries" --cold-queries "$cold_queries" --warmup "$warmup"
    --batch-size "$batch_size" --stable-polls "$stable_polls"
    --settle-timeout "$settle_timeout" --settle-max-timeout "$settle_max"
    --output "$run_dir/benchmark.json"
  )
  (( points >= 50000 )) && args+=(--require-full-index)
  QDRANT_PROFILE="$profile" bash "$PROJECT_DIR/qdrant.sh" benchmark "${args[@]}" || benchmark_rc=$?
  kill "$monitor_pid" 2>/dev/null || true
  wait "$monitor_pid" 2>/dev/null || true
  if (( benchmark_rc != 0 )); then
    printf 'benchmark_exit_code=%s\n' "$benchmark_rc" >> "$run_dir/run-metadata.txt"
    warn "Profile benchmark failed: cycle=$cycle profile=$profile exit=$benchmark_rc"
  fi
done < <(emit_plan | tr '\n' '\n')

python3 "$PROJECT_DIR/benchmarks/profile_compare.py" \
  --root "$ab_root/runs" \
  --json-output "$ab_root/profile-comparison.json" \
  --markdown-output "$ab_root/profile-comparison.md"

archive="$export_root/$(basename "$ab_root").zip"
rm -f "$archive" "$archive.sha256"
if command -v zip >/dev/null 2>&1; then
  (cd "$export_root" && zip -qr "$archive" "$(basename "$ab_root")")
else
  python3 - "$ab_root" "$archive" <<'PY'
import os,sys,zipfile
src,dst=sys.argv[1:]
base=os.path.dirname(src)
with zipfile.ZipFile(dst,'w',zipfile.ZIP_DEFLATED) as z:
    for root,dirs,files in os.walk(src):
        dirs.sort(); files.sort()
        for name in files:
            p=os.path.join(root,name); z.write(p,os.path.relpath(p,base))
PY
fi
command -v sha256sum >/dev/null 2>&1 && sha256sum "$archive" > "$archive.sha256"
ok "Profile A/B complete: $archive"
exit "$overall_rc"
