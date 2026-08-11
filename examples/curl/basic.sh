#!/usr/bin/env bash
set -euo pipefail

QDRANT_URL="${QDRANT_URL:-http://127.0.0.1:9090}"
QDRANT_URL="${QDRANT_URL%/}"
QDRANT_API_KEY="${QDRANT_API_KEY:-}"
QDRANT_READ_ONLY_API_KEY="${QDRANT_READ_ONLY_API_KEY:-}"
QDRANT_COLLECTION="${QDRANT_COLLECTION:-curl_demo}"

[[ -n "$QDRANT_API_KEY" ]] || { echo "QDRANT_API_KEY is required" >&2; exit 1; }
readonly_key="${QDRANT_READ_ONLY_API_KEY:-$QDRANT_API_KEY}"

api() {
    curl -fsS -H "api-key: $QDRANT_API_KEY" "$@"
}
readonly_api() {
    curl -fsS -H "api-key: $readonly_key" "$@"
}

echo "[curl] Endpoint:   $QDRANT_URL"
echo "[curl] Collection: $QDRANT_COLLECTION"

if ! api "$QDRANT_URL/collections/$QDRANT_COLLECTION" >/dev/null 2>&1; then
    api -X PUT "$QDRANT_URL/collections/$QDRANT_COLLECTION" \
        -H 'Content-Type: application/json' \
        -d '{"vectors":{"size":4,"distance":"Cosine"}}' | jq .
fi

api -X PUT "$QDRANT_URL/collections/$QDRANT_COLLECTION/points?wait=true" \
    -H 'Content-Type: application/json' \
    -d '{
      "points": [
        {"id": 1, "vector": [0.9,0.1,0.1,0.1], "payload": {"label":"red"}},
        {"id": 2, "vector": [0.1,0.9,0.1,0.1], "payload": {"label":"green"}},
        {"id": 3, "vector": [0.1,0.1,0.9,0.1], "payload": {"label":"blue"}}
      ]
    }' | jq .

echo "[curl] Querying with the read-only key when available..."
readonly_api -X POST "$QDRANT_URL/collections/$QDRANT_COLLECTION/points/query" \
    -H 'Content-Type: application/json' \
    -d '{"query":[0.8,0.2,0.1,0.1],"limit":3,"with_payload":true}' | jq .
