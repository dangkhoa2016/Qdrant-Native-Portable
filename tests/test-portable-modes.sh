#!/usr/bin/env bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"; rm -f "$PROJECT_DIR/.qdrant-base"' EXIT

BASE_DIR="$tmp/runtime" \
QDRANT_PLATFORM=generic-linux \
PROCESS_MODE=current-user \
DEPLOYMENT_MODE=minimal \
PUBLIC_MODE=none \
QDRANT_PROFILE=low-memory \
QDRANT_ENABLE_GRPC=1 \
QDRANT_JWT_RBAC=1 \
QDRANT_API_KEY=test-admin-key-not-a-production-credential \
QDRANT_READ_ONLY_API_KEY=test-readonly-key-not-a-production-credential \
bash -c '
  set -euo pipefail
  source "$1/scripts/common.sh"
  [[ "$PROCESS_MODE" == current-user ]]
  [[ "$DEPLOYMENT_MODE" == minimal ]]
  [[ "$QDRANT_PROFILE" == low-memory ]]
  [[ "$PROFILE_LOW_MEMORY_MODE" == no_populate ]]
  [[ "$PROFILE_VECTORS_ON_DISK" == true ]]
  [[ "$PROFILE_HNSW_ON_DISK" == true ]]
  [[ "$QDRANT_ENABLE_GRPC" == 1 ]]
  [[ "$QDRANT_JWT_RBAC" == 1 ]]
  write_secrets_file
  bash "$1/scripts/04_configure_qdrant.sh" >/dev/null
  grep -q "grpc_port: 6334" "$QDRANT_CONFIG"
  grep -q "strict_mode:" "$QDRANT_CONFIG"
  grep -q "max_query_limit: 1000" "$QDRANT_CONFIG"
  grep -q "max_resident_memory_percent: 85" "$QDRANT_CONFIG"
  grep -q "search_max_batchsize: 64" "$QDRANT_CONFIG"
  grep -q "vectors:" "$QDRANT_CONFIG"
  ! grep -Eq "^[[:space:]]*(api_key|read_only_api_key|alt_api_key):" "$QDRANT_CONFIG"
  [[ "$(stat -c %a "$SECRETS_FILE")" == 600 ]]
  [[ "$(stat -c %a "$RUNTIME_ENV_FILE")" == 600 ]]
' _ "$PROJECT_DIR"

if python3 -c 'import yaml' >/dev/null 2>&1; then
  python3 -c 'import sys,yaml; yaml.safe_load(open(sys.argv[1]))' "$tmp/runtime/config/qdrant.yaml"
fi

# Explicit values must override persisted runtime.env values in a fresh shell.
mkdir -p "$tmp/precedence"
cat > "$tmp/precedence/runtime.env" <<'EOF_RUNTIME'
QDRANT_PROFILE=performance
PROCESS_MODE=service-user
DEPLOYMENT_MODE=proxy
PUBLIC_MODE=cloudflare-quick
EOF_RUNTIME
BASE_DIR="$tmp/precedence" QDRANT_PROFILE=balanced PROCESS_MODE=current-user DEPLOYMENT_MODE=minimal PUBLIC_MODE=none \
  bash -c 'source "$1/scripts/common.sh"; [[ "$QDRANT_PROFILE" == balanced && "$PROCESS_MODE" == current-user && "$DEPLOYMENT_MODE" == minimal && "$PUBLIC_MODE" == none ]]' _ "$PROJECT_DIR"


# balanced-memory keeps vectors/HNSW in RAM but payload on disk with conservative optimizers.
BASE_DIR="$tmp/balanced-memory" QDRANT_PLATFORM=generic-linux PROCESS_MODE=current-user DEPLOYMENT_MODE=minimal PUBLIC_MODE=none QDRANT_PROFILE=balanced-memory \
  bash -c 'source "$1/scripts/common.sh"; [[ "$QDRANT_PROFILE" == balanced-memory && "$PROFILE_VECTORS_ON_DISK" == false && "$PROFILE_HNSW_ON_DISK" == false && "$PROFILE_ON_DISK_PAYLOAD" == true && "$PROFILE_OPTIMIZER_CPU_BUDGET" == 1 ]]' _ "$PROJECT_DIR"

# Codespaces must stay rootless/minimal even if the underlying test runner is root.
# shellcheck disable=SC2016
env -u CODESANDBOX_HOST -u CODESANDBOX_SSE -u CSB -u COLAB_RELEASE_TAG -u COLAB_BACKEND_VERSION -u KAGGLE_KERNEL_RUN_TYPE \
  BASE_DIR="$tmp/codespaces" CODESPACES=true QDRANT_PROFILE=balanced-lite \
  bash -c 'source "$1/scripts/common.sh"; [[ "$PLATFORM" == github-codespaces && "$PROCESS_MODE" == current-user && "$DEPLOYMENT_MODE" == minimal && "$PUBLIC_MODE" == platform && "$QDRANT_PROFILE" == balanced-lite && "$PROFILE_VECTORS_ON_DISK" == true && "$PROFILE_HNSW_ON_DISK" == false ]]' _ "$PROJECT_DIR"

# CodeSandbox-style VMs must also stay rootless/minimal. Public access uses the
# explicit Cloudflare helper unless the user selects another supported mode.
# shellcheck disable=SC2016
env -u CODESPACES -u CODESPACE_NAME -u COLAB_RELEASE_TAG -u COLAB_BACKEND_VERSION -u KAGGLE_KERNEL_RUN_TYPE \
  BASE_DIR="$tmp/codesandbox" CODESANDBOX_HOST=test-host QDRANT_PROFILE=low-memory \
  bash -c 'source "$1/scripts/common.sh"; [[ "$PLATFORM" == codesandbox && "$PROCESS_MODE" == current-user && "$DEPLOYMENT_MODE" == minimal && "$PUBLIC_MODE" == cloudflare-quick ]]' _ "$PROJECT_DIR"

# Explicit platform override is the stable escape hatch when a hosted VM does
# not expose a reliable provider-specific environment marker.
# shellcheck disable=SC2016
env -u CODESPACES -u CODESPACE_NAME -u COLAB_RELEASE_TAG -u COLAB_BACKEND_VERSION -u KAGGLE_KERNEL_RUN_TYPE -u CODESANDBOX_HOST -u CODESANDBOX_SSE -u CSB \
  BASE_DIR="$tmp/codesandbox-override" QDRANT_PLATFORM=codesandbox QDRANT_PROFILE=low-memory \
  bash -c 'source "$1/scripts/common.sh"; [[ "$PLATFORM" == codesandbox && "$PROCESS_MODE" == current-user && "$DEPLOYMENT_MODE" == minimal ]]' _ "$PROJECT_DIR"


# system-info must expose effective/cgroup memory rather than only host MemTotal.
cat > "$tmp/meminfo" <<'EOF_MEM'
MemTotal:        8388608 kB
MemAvailable:    6291456 kB
EOF_MEM
mkdir -p "$tmp/cgroup" "$tmp/system-info" "$tmp/doctor"
printf '%s\n' 4294967296 > "$tmp/cgroup/memory.max"
BASE_DIR="$tmp/system-info" QDRANT_PLATFORM=generic-linux PROCESS_MODE=current-user DEPLOYMENT_MODE=minimal PUBLIC_MODE=none QDRANT_PROFILE=low-memory \
QDRANT_MEMINFO_FILE="$tmp/meminfo" QDRANT_CGROUP_DIR="$tmp/cgroup" \
  bash "$PROJECT_DIR/scripts/system-info.sh" > "$tmp/system-info.txt"
grep -Eq 'Effective RAM[[:space:]]+4096 MB \(cgroup\)' "$tmp/system-info.txt"

# doctor must use the same effective-memory view for safety decisions.
printf '%s\n' 1073741824 > "$tmp/cgroup/memory.max"
set +e
BASE_DIR="$tmp/doctor" QDRANT_PLATFORM=generic-linux PROCESS_MODE=current-user DEPLOYMENT_MODE=minimal PUBLIC_MODE=none QDRANT_PROFILE=low-memory \
QDRANT_MEMINFO_FILE="$tmp/meminfo" QDRANT_CGROUP_DIR="$tmp/cgroup" \
  bash "$PROJECT_DIR/scripts/doctor.sh" > "$tmp/doctor.txt" 2>&1
doctor_rc=$?
set -e
[[ "$doctor_rc" -ne 0 ]]
grep -q 'effective RAM is below' "$tmp/doctor.txt"

echo 'portable mode/config tests passed'
