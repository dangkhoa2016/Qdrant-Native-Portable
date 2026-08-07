#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname "$0")/common.sh"
require python3
require_secrets
qdrant_ready || fail "Qdrant must be running before benchmarking"
ensure_runtime_dirs
export QDRANT_URL="http://127.0.0.1:${QDRANT_HTTP_PORT}"
export QDRANT_API_KEY
QDRANT_PID="$(cat "$QDRANT_PID_FILE" 2>/dev/null || true)"
export QDRANT_PID
export QDRANT_BENCHMARK_DIR="$QDRANT_BENCHMARKS"
export QDRANT_BASE_DIR="$BASE_DIR"
export QDRANT_STORAGE_DIR="$QDRANT_STORAGE"
QDRANT_PROJECT_VERSION="$(cat "$PROJECT_DIR/VERSION" 2>/dev/null || echo unknown)"
export QDRANT_PROJECT_VERSION
export QDRANT_PLATFORM_DETECTED="$PLATFORM"
export QDRANT_VERSION QDRANT_PROFILE PROCESS_MODE DEPLOYMENT_MODE PUBLIC_MODE QDRANT_ENABLE_GRPC QDRANT_STRICT_MODE
exec python3 "$PROJECT_DIR/benchmarks/benchmark.py" "$@"
