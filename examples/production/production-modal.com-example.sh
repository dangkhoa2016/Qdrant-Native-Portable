#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

: "${QDRANT_API_KEY:?export QDRANT_API_KEY first}"
: "${QDRANT_READ_ONLY_API_KEY:?export QDRANT_READ_ONLY_API_KEY first}"
[[ "$QDRANT_API_KEY" != "$QDRANT_READ_ONLY_API_KEY" ]] || {
  echo "QDRANT_API_KEY and QDRANT_READ_ONLY_API_KEY must differ" >&2
  exit 1
}

command -v modal >/dev/null 2>&1 || {
  echo "Modal CLI is required. Install it and run 'modal setup' first." >&2
  exit 1
}

modal secret create --force qnp-qdrant-secrets \
  QDRANT_API_KEY="$QDRANT_API_KEY" \
  QDRANT_READ_ONLY_API_KEY="$QDRANT_READ_ONLY_API_KEY"

printf '%s\n' \
  'Modal persistence: QNP snapshot-persist with live DB on local container storage.' \
  'Durable completed snapshots: Modal Volume qnp-qdrant-persist mounted at /qdrant-persist.' \
  'The adapter lazily creates the v1 Volume if it does not already exist.' \
  'Startup performs a commit/read-back durability probe before Qdrant is allowed to start.' \
  'Periodic snapshots: 600s; Modal scale-down window: 900s; timing safety margin is enforced by the adapter.' \
  'Modal provider shutdown snapshots are disabled: periodic snapshots define a <=600s durability RPO.' \
  'Exit logs expose child termination and final Volume commit status without printing API keys.' \
  'Server topology: single-node, max_containers=1, scale-to-zero enabled.' \
  'For validation evidence, export QDRANT_URL for the deployed endpoint, then run examples/production/collect-modal-validation-result.sh outside the repo.'

modal deploy deploy/modal/app.py
