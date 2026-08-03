#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname "$0")/common.sh"

header "Step 6: Verify Qdrant security and REST API"
require curl jq
require_secrets

version_json="$(api_curl "http://127.0.0.1:${QDRANT_HTTP_PORT}/")"
version="$(jq -r '.version // "unknown"' <<<"$version_json")"
ok "Qdrant REST API is responding (version: $version)"

unauth_code="$(curl -sS -o /dev/null -w '%{http_code}' "http://127.0.0.1:${QDRANT_HTTP_PORT}/collections" || true)"
if [[ "$unauth_code" == "401" || "$unauth_code" == "403" ]]; then
    ok "Unauthenticated collection access is blocked (HTTP $unauth_code)"
else
    fail "Authentication check failed: expected HTTP 401/403 without a key, got HTTP $unauth_code"
fi

read_code="$(curl -sS -o /dev/null -w '%{http_code}' \
    -H "api-key: $QDRANT_READ_ONLY_API_KEY" \
    "http://127.0.0.1:${QDRANT_HTTP_PORT}/collections" || true)"
[[ "$read_code" == "200" ]] || fail "Read-only key failed to read collections (HTTP $read_code)"
ok "Read-only API key can read collections"

probe_collection="security_probe_$(date +%s)_$RANDOM"
write_code="$(curl -sS -o /dev/null -w '%{http_code}' -X PUT \
    -H "api-key: $QDRANT_READ_ONLY_API_KEY" \
    -H 'Content-Type: application/json' \
    -d '{"vectors":{"size":2,"distance":"Cosine"}}' \
    "http://127.0.0.1:${QDRANT_HTTP_PORT}/collections/${probe_collection}" || true)"
if [[ "$write_code" == "401" || "$write_code" == "403" ]]; then
    ok "Read-only API key is blocked from write operations (HTTP $write_code)"
else
    # Defensive cleanup in case a future Qdrant behavior unexpectedly accepted the request.
    curl -fsS -X DELETE -H "api-key: $QDRANT_API_KEY" \
        "http://127.0.0.1:${QDRANT_HTTP_PORT}/collections/${probe_collection}" >/dev/null 2>&1 || true
    fail "Read-only security check failed: write request returned HTTP $write_code"
fi
