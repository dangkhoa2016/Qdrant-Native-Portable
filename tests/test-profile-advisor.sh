#!/usr/bin/env bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Build deterministic host/cgroup fixtures so the advisor can be tested without
# depending on the CI runner's actual RAM or container limit.
cat > "$tmp/meminfo" <<'MEM'
MemTotal:        8388608 kB
MemFree:         1048576 kB
MemAvailable:    6291456 kB
SwapTotal:             0 kB
SwapFree:              0 kB
MEM
mkdir -p "$tmp/cgroup"
printf '%s\n' 4294967296 > "$tmp/cgroup/memory.max"
printf '%s\n' 1073741824 > "$tmp/cgroup/memory.current"

# A nominal 8 GiB host constrained to 4 GiB by cgroup must be treated as a
# 4 GiB effective host. This is the behavior that protects containers and
# hosted notebook environments from over-selecting an in-memory profile.
BASE_DIR="$tmp/runtime" QDRANT_PLATFORM=generic-linux PROCESS_MODE=current-user DEPLOYMENT_MODE=minimal PUBLIC_MODE=none \
QDRANT_MEMINFO_FILE="$tmp/meminfo" QDRANT_CGROUP_DIR="$tmp/cgroup" \
  bash "$PROJECT_DIR/scripts/profile-advisor.sh" --points 100000 --dimension 768 --json > "$tmp/advisor.json"
python3 - "$tmp/advisor.json" <<'PY'
import json, sys
x=json.load(open(sys.argv[1]))
assert x['dataset']['points']==100000
assert x['dataset']['dimension']==768
assert x['dataset']['raw_vector_mib']==293
assert x['memory_total_mb']==8192
assert x['effective_memory_limit_mb']==4096
assert x['effective_memory_source']=='cgroup'
assert x['hardware_default_profile']=='low-memory'
assert x['recommended_profile']=='low-memory', x
PY

# Without a finite cgroup limit the same 8 GiB fixture should keep the proven
# balanced-memory hardware default.
printf '%s\n' max > "$tmp/cgroup/memory.max"
BASE_DIR="$tmp/runtime2" QDRANT_PLATFORM=generic-linux PROCESS_MODE=current-user DEPLOYMENT_MODE=minimal PUBLIC_MODE=none \
QDRANT_MEMINFO_FILE="$tmp/meminfo" QDRANT_CGROUP_DIR="$tmp/cgroup" \
  bash "$PROJECT_DIR/scripts/profile-advisor.sh" --json > "$tmp/advisor-unlimited.json"
python3 - "$tmp/advisor-unlimited.json" <<'PY'
import json, sys
x=json.load(open(sys.argv[1]))
assert x['memory_total_mb']==8192
assert x['effective_memory_limit_mb']==8192
assert x['effective_memory_source']=='host'
assert x['hardware_default_profile']=='balanced-memory'
assert x['recommended_profile']=='balanced-memory'
PY

echo 'profile advisor tests passed'
