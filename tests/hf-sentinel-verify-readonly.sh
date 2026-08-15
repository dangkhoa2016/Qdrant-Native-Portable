#!/usr/bin/env bash
set -euo pipefail

: "${QDRANT_URL:?Set QDRANT_URL, for example https://your-space.example}"
: "${QDRANT_READ_ONLY_API_KEY:?Set QDRANT_READ_ONLY_API_KEY for post-restart verification}"
: "${QNP_SENTINEL_TOKEN:?Set the same QNP_SENTINEL_TOKEN used before the restart}"

collection="${QNP_SENTINEL_COLLECTION:-qnp_restore_sentinel}"
point_id="${QNP_SENTINEL_POINT_ID:-9182026}"
base="${QDRANT_URL%/}"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

curl -fsS \
  -H "api-key: $QDRANT_READ_ONLY_API_KEY" \
  "$base/collections/$collection" > "$tmp/collection.json"

curl -fsS \
  -H "api-key: $QDRANT_READ_ONLY_API_KEY" \
  "$base/collections/$collection/points/$point_id?with_payload=true&with_vector=false" > "$tmp/point.json"

python3 - "$tmp/point.json" "$QNP_SENTINEL_TOKEN" "$collection" "$point_id" <<'PY'
import json, sys
path, expected, collection, point_id = sys.argv[1:]
with open(path, 'r', encoding='utf-8') as f:
    doc = json.load(f)
result = doc.get('result') or {}
payload = result.get('payload') or {}
actual = payload.get('qnp_restore_sentinel')
if actual != expected:
    print(f"FAIL: restored sentinel mismatch for {collection}/{point_id}: expected={expected!r} actual={actual!r}", file=sys.stderr)
    raise SystemExit(1)
print(f"PASS: restored sentinel survived recreation: collection={collection} point_id={point_id}")
PY
