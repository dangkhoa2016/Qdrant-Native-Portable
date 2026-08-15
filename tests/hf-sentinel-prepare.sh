#!/usr/bin/env bash
set -euo pipefail

: "${QDRANT_URL:?Set QDRANT_URL, for example https://your-space.example}"
: "${QDRANT_API_KEY:?Set QDRANT_API_KEY for the pre-restart sentinel write}"
: "${QNP_SENTINEL_TOKEN:?Set a unique QNP_SENTINEL_TOKEN and keep it for post-restart verification}"

collection="${QNP_SENTINEL_COLLECTION:-qnp_restore_sentinel}"
point_id="${QNP_SENTINEL_POINT_ID:-9182026}"
base="${QDRANT_URL%/}"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

status="$(curl -sS -o "$tmp/collection.json" -w '%{http_code}' \
  -H "api-key: $QDRANT_API_KEY" \
  "$base/collections/$collection")"

if [[ "$status" == "404" ]]; then
  curl -fsS -X PUT \
    -H "api-key: $QDRANT_API_KEY" \
    -H 'content-type: application/json' \
    "$base/collections/$collection" \
    --data '{"vectors":{"size":1,"distance":"Cosine"}}' > "$tmp/create.json"
elif [[ "$status" != "200" ]]; then
  printf 'ERROR: collection probe returned HTTP %s\n' "$status" >&2
  cat "$tmp/collection.json" >&2 || true
  exit 1
fi

payload="$(python3 - "$point_id" "$QNP_SENTINEL_TOKEN" <<'PY'
import json, sys
point_id = int(sys.argv[1])
token = sys.argv[2]
print(json.dumps({"points": [{"id": point_id, "vector": [1.0], "payload": {"qnp_restore_sentinel": token}}]}))
PY
)"

curl -fsS -X PUT \
  -H "api-key: $QDRANT_API_KEY" \
  -H 'content-type: application/json' \
  "$base/collections/$collection/points?wait=true" \
  --data "$payload" > "$tmp/upsert.json"

printf 'PASS: sentinel written before restart\n'
printf 'collection=%s\npoint_id=%s\ntoken=%s\n' "$collection" "$point_id" "$QNP_SENTINEL_TOKEN"
