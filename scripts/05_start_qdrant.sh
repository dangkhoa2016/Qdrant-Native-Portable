#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname "$0")/common.sh"

wait_for_qdrant_startup() {
    local started_at="$SECONDS" deadline=$((SECONDS + QDRANT_START_TIMEOUT_SECONDS))
    local elapsed=0 remaining poll_timeout next_progress=10
    printf "  ⏳ Waiting for Qdrant...\n"
    while (( SECONDS < deadline )); do
        remaining=$((deadline - SECONDS))
        poll_timeout=3
        (( remaining >= poll_timeout )) || poll_timeout="$remaining"
        if qdrant_ready_with_timeout "$poll_timeout" >/dev/null 2>&1; then
            elapsed=$((SECONDS - started_at))
            ok "Qdrant is ready (${elapsed}s)"
            return 0
        fi
        pid_is_running "$QDRANT_PID_FILE" || return 2
        elapsed=$((SECONDS - started_at))
        (( elapsed < QDRANT_START_TIMEOUT_SECONDS )) || return 1
        if (( elapsed >= next_progress )); then
            muted "waiting... ${elapsed}s"
            next_progress=$((next_progress + 10))
        fi
        sleep 1
    done
    return 1
}

wait_for_qdrant_or_fail() {
    local wait_rc=0
    wait_for_qdrant_startup || wait_rc=$?
    (( wait_rc == 0 )) && return 0
    tail -n 120 "$QDRANT_LOG" 2>/dev/null || true
    if (( wait_rc == 2 )); then
        fail "Qdrant exited before readiness. See $QDRANT_LOG"
    fi
    fail "Qdrant did not become ready within ${QDRANT_START_TIMEOUT_SECONDS}s. See $QDRANT_LOG"
}

header "Step 5: Start Qdrant"
require_service_control_privileges
require_secrets

if pid_is_running "$QDRANT_PID_FILE"; then
    info "Qdrant is already running (PID $(cat "$QDRANT_PID_FILE"))"
    info "Checking Qdrant API readiness..."
    wait_for_qdrant_or_fail
    exit 0
fi
rm -f "$QDRANT_PID_FILE"

info "Starting Qdrant ($PROCESS_MODE, profile=$QDRANT_PROFILE)..."
# shellcheck disable=SC2119
start_qdrant_process
wait_for_qdrant_or_fail
ok "Qdrant PID: $(cat "$QDRANT_PID_FILE")"
