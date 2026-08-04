#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname "$0")/common.sh"
require curl
require_secrets

base="$(local_api_url)"
collection="auth_probe_$(date -u +%Y%m%d%H%M%S)_$$"

http_code() {
    local method="$1" key="$2" url="$3" body="${4:-}"
    local args=(-sS --max-time 10 -o /dev/null -w '%{http_code}' -X "$method")
    [[ -n "$key" ]] && args+=(-H "api-key: $key")
    if [[ -n "$body" ]]; then
        args+=(-H 'Content-Type: application/json' --data-binary "$body")
    fi
    curl "${args[@]}" "$url"
}

header "Runtime authorization check"

code="$(http_code GET '' "$base/collections")"
[[ "$code" == "401" ]] || fail "unauthenticated collection access was expected to be blocked with HTTP 401, got HTTP $code"
ok "unauthenticated collection access is blocked (HTTP 401)"

code="$(http_code GET "$QDRANT_API_KEY" "$base/collections")"
[[ "$code" =~ ^2 ]] || fail "admin API key cannot read collections (HTTP $code)"
ok "admin API key can read collections"

code="$(http_code GET "$QDRANT_READ_ONLY_API_KEY" "$base/collections")"
[[ "$code" =~ ^2 ]] || fail "read-only API key cannot read collections (HTTP $code)"
ok "read-only API key can read collections"

# Use a unique collection name and only the read-only credential. A correctly
# configured Qdrant rejects the request before creating anything, so this test
# is non-destructive while still exercising a real write endpoint.
body='{"vectors":{"size":4,"distance":"Cosine"}}'
code="$(http_code PUT "$QDRANT_READ_ONLY_API_KEY" "$base/collections/$collection" "$body")"
[[ "$code" == "403" ]] || fail "read-only API key write was expected to be blocked with HTTP 403, got HTTP $code"
ok "read-only API key is blocked from write operations (HTTP 403)"

ok "runtime authorization check passed"
