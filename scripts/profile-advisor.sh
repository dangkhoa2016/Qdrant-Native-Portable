#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname "$0")/common.sh"

points=""
dimension=""
bytes_per_component=4
json=0

usage() {
  cat <<'USAGE'
Usage:
  bash qdrant.sh profile-advisor
  bash qdrant.sh profile-advisor --points N --dimension N [options]

Options:
  --points N                 Expected vector count
  --dimension N              Vector dimension
  --bytes-per-component N    Bytes per vector component (default: 4 for float32)
  --json                     Emit machine-readable JSON
  -h, --help                 Show this help

The advisor is conservative. It uses exact raw-vector size plus a budgeting
heuristic for indexes, payload, optimizer work, OS, and filesystem cache. It
does not change the running Qdrant configuration.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --points) points="${2:?missing value}"; shift 2 ;;
    --dimension) dimension="${2:?missing value}"; shift 2 ;;
    --bytes-per-component) bytes_per_component="${2:?missing value}"; shift 2 ;;
    --json) json=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) fail "Unknown profile-advisor option: $1" ;;
  esac
done

for pair in "points:$points" "dimension:$dimension" "bytes:$bytes_per_component"; do
  key="${pair%%:*}"; val="${pair#*:}"
  [[ -z "$val" || "$val" =~ ^[1-9][0-9]*$ ]] || fail "$key must be a positive integer"
done
[[ -z "$points" && -z "$dimension" ]] || [[ -n "$points" && -n "$dimension" ]] || fail "--points and --dimension must be supplied together"

mem_total_mb="$(total_memory_mb)"
mem_available_mb="$(available_memory_mb)"
effective_mem_mb="$(effective_memory_mb)"
effective_mem_source="$(effective_memory_source)"
hardware_default="$(default_profile)"
recommended="$hardware_default"
reason="hardware-only recommendation"
raw_bytes=0
raw_mib=0
budget_mib=0
ratio_permille=0

if [[ -n "$points" ]]; then
  raw_bytes=$(( points * dimension * bytes_per_component ))
  raw_mib=$(( (raw_bytes + 1048575) / 1048576 ))
  # Budgeting heuristic: 1.65x raw vectors for vectors + HNSW/metadata/search
  # working set. This is intentionally conservative and is not a Qdrant sizing
  # guarantee.
  budget_mib=$(( (raw_mib * 165 + 99) / 100 ))
  if (( effective_mem_mb > 0 )); then ratio_permille=$(( raw_mib * 1000 / effective_mem_mb )); fi

  if (( effective_mem_mb <= 5500 )); then
    recommended="low-memory"
    reason="<=5.5 GB effective memory remains on the proven low-memory default pending order-controlled A/B evidence"
  elif (( effective_mem_mb <= 10500 )); then
    if (( budget_mib <= effective_mem_mb * 28 / 100 )); then
      recommended="balanced-memory"
      reason="estimated collection working set fits comfortably in a 6-10 GB host"
    elif (( budget_mib <= effective_mem_mb * 55 / 100 )); then
      recommended="balanced-lite"
      reason="vectors are large enough that disk-backed vectors preserve safer RAM headroom"
    else
      recommended="low-memory"
      reason="estimated collection working set is too large for a 6-10 GB host"
    fi
  elif (( effective_mem_mb <= 22000 )); then
    if (( budget_mib <= effective_mem_mb * 40 / 100 )); then
      recommended="balanced"
      reason="estimated collection working set fits comfortably in host RAM"
    elif (( budget_mib <= effective_mem_mb * 62 / 100 )); then
      recommended="balanced-memory"
      reason="keep vectors/HNSW in RAM while retaining conservative optimizer behavior"
    else
      recommended="balanced-lite"
      reason="dataset is large relative to host RAM; use disk-backed vectors"
    fi
  else
    if (( budget_mib <= effective_mem_mb * 45 / 100 )); then
      recommended="performance"
      reason="large host has ample estimated headroom for in-memory data"
    elif (( budget_mib <= effective_mem_mb * 65 / 100 )); then
      recommended="balanced"
      reason="dataset fits RAM but should preserve additional OS/cache headroom"
    else
      recommended="balanced-lite"
      reason="dataset is large enough to benefit from disk-backed vectors"
    fi
  fi
fi

if (( json )); then
  python3 - "$PLATFORM" "$mem_total_mb" "$mem_available_mb" "$effective_mem_mb" "$effective_mem_source" "$hardware_default" "$recommended" "$points" "$dimension" "$bytes_per_component" "$raw_bytes" "$raw_mib" "$budget_mib" "$ratio_permille" "$reason" <<'PY'
import json, sys
(platform, total, avail, effective, effective_source, hw, rec, points, dim, bpc, rawb, rawm, budget, ratio, reason) = sys.argv[1:]
def maybe_int(v): return int(v) if v else None
print(json.dumps({
  "platform": platform,
  "memory_total_mb": int(total),
  "memory_available_mb": int(avail),
  "effective_memory_limit_mb": int(effective),
  "effective_memory_source": effective_source,
  "hardware_default_profile": hw,
  "recommended_profile": rec,
  "dataset": {
    "points": maybe_int(points), "dimension": maybe_int(dim),
    "bytes_per_component": int(bpc), "raw_vector_bytes": int(rawb),
    "raw_vector_mib": int(rawm), "budgeting_working_set_mib": int(budget),
    "raw_vector_to_host_permille": int(ratio)
  },
  "reason": reason,
  "note": "Budgeting working set is a conservative project heuristic, not a Qdrant memory guarantee."
}, indent=2))
PY
  exit 0
fi

header "Profile advisor"
printf '  Platform:                  %s\n' "$PLATFORM"
printf '  RAM total / available:     %s MB / %s MB\n' "$mem_total_mb" "$mem_available_mb"
printf '  Effective memory limit:    %s MB (%s)\n' "$effective_mem_mb" "$effective_mem_source"
printf '  Hardware default:          %s\n' "$hardware_default"
if [[ -n "$points" ]]; then
  printf '  Dataset:                   %s points × %s dimensions × %s bytes\n' "$points" "$dimension" "$bytes_per_component"
  printf '  Raw vector footprint:      %s MiB\n' "$raw_mib"
  printf '  Budgeting working set:     ~%s MiB (heuristic)\n' "$budget_mib"
fi
printf '  Recommended profile:       %s\n' "$recommended"
printf '  Reason:                    %s\n' "$reason"
printf '\n'
printf 'Profiles:\n'
printf '  low-memory       vectors/HNSW/payload on disk; strongest RAM conservation\n'
printf '  balanced-lite    vectors/payload on disk, HNSW in RAM\n'
printf '  balanced-memory  vectors/HNSW in RAM, payload on disk, conservative optimizers\n'
printf '  balanced         vectors/HNSW in RAM, payload on disk, normal optimizers\n'
printf '  performance      vectors/HNSW/payload in RAM where practical\n'
printf '\n'
warn "Changing QDRANT_PROFILE requires regenerating config/restarting; existing collections may retain collection-level settings. Use reinstall-test only for disposable test baselines."
