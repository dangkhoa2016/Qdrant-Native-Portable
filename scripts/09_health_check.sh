#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname "$0")/common.sh"

header "Health check"
require curl jq
require_secrets

health_failed=0

if qdrant_ready; then
    version="$(api_curl "http://127.0.0.1:${QDRANT_HTTP_PORT}/" | jq -r '.version // "unknown"')"
    if pid_is_running "$QDRANT_PID_FILE"; then
        ok "Qdrant API: RUNNING (PID $(cat "$QDRANT_PID_FILE"), version $version)"
    else
        ok "Qdrant API: RUNNING (version $version)"
        warn "Qdrant PID file is missing or stale; the API is healthy but the process is not tracked by this project"
    fi
else
    warn "Qdrant API: DOWN"
    health_failed=1
fi

if [[ "$DEPLOYMENT_MODE" == "proxy" ]]; then
    if proxy_ready; then
        collections="$(readonly_api_curl "http://${PROXY_BIND}:${PROXY_PORT}/collections" | jq '.result.collections | length')"
        ok "Nginx proxy: RUNNING (collections: $collections)"
    else
        warn "Nginx proxy: DOWN"
        health_failed=1
    fi
else
    muted "Nginx proxy: disabled (minimal mode)"
fi

if pid_is_running "$TUNNEL_PID_FILE"; then
    ok "Cloudflare tunnel: RUNNING ($(cat "$PUBLIC_URL_FILE" 2>/dev/null || echo URL-pending))"
elif [[ -f "$PUBLIC_URL_FILE" ]]; then
    info "Platform public URL: $(cat "$PUBLIC_URL_FILE")"
else
    muted "Public access: not enabled"
fi

printf '\n'
info "Platform/profile:   $PLATFORM / $QDRANT_PROFILE"
info "Modes:              process=$PROCESS_MODE deployment=$DEPLOYMENT_MODE public=$PUBLIC_MODE"
info "Admin API key:      $(mask "$QDRANT_API_KEY")"
info "Read-only API key:  $(mask "$QDRANT_READ_ONLY_API_KEY")"
if [[ -n "${QDRANT_ALT_API_KEY:-}" ]]; then info "Alternate admin key: $(mask "$QDRANT_ALT_API_KEY")"; fi
info "Local API:          $(local_api_url)"
info "Dashboard:          $(local_dashboard_url)"
if [[ "$QDRANT_ENABLE_GRPC" == "1" ]]; then info "gRPC:               127.0.0.1:$QDRANT_GRPC_PORT"; fi

if (( health_failed )); then
    warn "Health check failed"
    exit 1
fi
ok "Health check passed"
