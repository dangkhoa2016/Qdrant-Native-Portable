#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname "$0")/common.sh"

header "Step 7: Create and query demo vector data"
require curl jq
require_secrets

base="http://127.0.0.1:${QDRANT_HTTP_PORT}"
if api_curl "$base/collections/$DEMO_COLLECTION" >/dev/null 2>&1; then
    info "Demo collection already exists: $DEMO_COLLECTION"
else
    api_curl -X PUT "$base/collections/$DEMO_COLLECTION" \
        -H 'Content-Type: application/json' \
        -d '{"vectors":{"size":4,"distance":"Cosine"}}' >/dev/null
    ok "Created collection: $DEMO_COLLECTION"
fi

api_curl -X PUT "$base/collections/$DEMO_COLLECTION/points?wait=true" \
    -H 'Content-Type: application/json' \
    -d '{
      "points": [
        {"id": 1, "vector": [0.05, 0.61, 0.76, 0.74], "payload": {"text": "Qdrant vector database", "lang": "en"}},
        {"id": 2, "vector": [0.19, 0.81, 0.75, 0.11], "payload": {"text": "Portable native Qdrant development", "lang": "en"}},
        {"id": 3, "vector": [0.36, 0.55, 0.47, 0.94], "payload": {"text": "Cơ sở dữ liệu vector tự host", "lang": "vi"}}
      ]
    }' >/dev/null
ok "Inserted demo points"

result="$(readonly_api_curl -X POST "$base/collections/$DEMO_COLLECTION/points/query" \
    -H 'Content-Type: application/json' \
    -d '{"query":[0.05,0.61,0.76,0.74],"limit":3,"with_payload":true}')"

count="$(jq '.result.points | length' <<<"$result")"
[[ "$count" -ge 1 ]] || fail "Vector query returned no results"
ok "Query API returned $count result(s) using the read-only key"
jq -r '.result.points[] | "    id=\(.id) score=\(.score) text=\(.payload.text)"' <<<"$result"
