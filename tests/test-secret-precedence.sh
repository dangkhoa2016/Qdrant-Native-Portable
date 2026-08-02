#!/usr/bin/env bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

TEST_BASE="$(mktemp -d)"
trap 'rm -rf "$TEST_BASE"' EXIT

BASE_DIR="$TEST_BASE/runtime" \
QDRANT_API_KEY="env-admin" \
QDRANT_READ_ONLY_API_KEY="env-readonly" \
bash -c '
  set -euo pipefail
  source "$1/scripts/common.sh"
  mkdir -p "$BASE_DIR"
  cat > "$SECRETS_FILE" <<SECRETS
QDRANT_API_KEY=file-admin
QDRANT_READ_ONLY_API_KEY=file-readonly
QDRANT_ALT_API_KEY=file-alt
SECRETS
  chmod 600 "$SECRETS_FILE"
  load_secrets
  [[ "$QDRANT_API_KEY" == "env-admin" ]]
  [[ "$QDRANT_READ_ONLY_API_KEY" == "env-readonly" ]]
  [[ "$QDRANT_ALT_API_KEY" == "file-alt" ]]
' _ "$PROJECT_DIR"

echo "secret precedence: OK"
