#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname "$0")/common.sh"

header "Step 5: Start Qdrant"
require_service_control_privileges
require_secrets

if pid_is_running "$QDRANT_PID_FILE"; then
    info "Qdrant is already running (PID $(cat "$QDRANT_PID_FILE"))"
    qdrant_ready && ok "Qdrant is ready"
    exit 0
fi
rm -f "$QDRANT_PID_FILE"

info "Starting Qdrant ($PROCESS_MODE, profile=$QDRANT_PROFILE)..."
# shellcheck disable=SC2119
start_qdrant_process
wait_for "Waiting for Qdrant" "Qdrant is ready" 90 qdrant_ready || {
    tail -n 120 "$QDRANT_LOG" || true
    fail "Qdrant did not become ready. See $QDRANT_LOG"
}
ok "Qdrant PID: $(cat "$QDRANT_PID_FILE")"
