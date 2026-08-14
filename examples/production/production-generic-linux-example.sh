#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
: "${QDRANT_API_KEY:?export QDRANT_API_KEY first}"
: "${QDRANT_READ_ONLY_API_KEY:?export QDRANT_READ_ONLY_API_KEY first}"
export QNP_ENV=production
export QNP_RUNTIME=native
export QNP_TOPOLOGY=single
export PUBLIC_MODE="${PUBLIC_MODE:-none}"
export QNP_CREATE_DEMO_DATA="${QNP_CREATE_DEMO_DATA:-0}"
bash qdrant.sh production-check
bash qdrant.sh prepare
exec bash qdrant.sh serve
