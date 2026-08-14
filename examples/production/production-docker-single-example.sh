#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
: "${QDRANT_API_KEY:?export QDRANT_API_KEY first}"
: "${QDRANT_READ_ONLY_API_KEY:?export QDRANT_READ_ONLY_API_KEY first}"
export QNP_ENV=production QNP_RUNTIME=docker QNP_TOPOLOGY=single
docker compose -f docker/docker-compose.yml up --build
