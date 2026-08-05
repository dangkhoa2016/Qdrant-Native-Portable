#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname "$0")/common.sh"
require_secrets
qdrant_ready || fail "Qdrant is not running"

raw=0
[[ "${1:-}" == "--raw" ]] && raw=1
metrics="$(curl -fsS -H "api-key: $QDRANT_API_KEY" "http://127.0.0.1:${QDRANT_HTTP_PORT}/metrics")"
if (( raw )); then printf '%s\n' "$metrics"; exit 0; fi

header "Qdrant metrics summary"
printf '%s\n' "$metrics" | grep -E '^(collections_total|collections_vector_total|rest_responses_total|grpc_responses_total|memory_|app_info|cluster_)' | head -n 80 || true
printf '\n'
if pid_is_running "$QDRANT_PID_FILE"; then
    pid="$(cat "$QDRANT_PID_FILE")"
    info "Process snapshot"
    ps -p "$pid" -o pid,%cpu,%mem,rss,vsz,etime,cmd || true
    info "Storage size: $(du -sh "$QDRANT_STORAGE" 2>/dev/null | awk '{print $1}')"
fi
muted "Use 'bash qdrant.sh metrics --raw' for the full Prometheus/OpenMetrics output."
