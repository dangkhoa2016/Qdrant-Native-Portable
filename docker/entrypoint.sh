#!/usr/bin/env bash
set -euo pipefail

export QNP_PERSISTENCE_LIB="${QNP_PERSISTENCE_LIB:-/qdrant/qnp-persistence.sh}"
export QNP_QDRANT_BIN="${QNP_QDRANT_BIN:-/qdrant/qdrant}"
export QNP_HEALTHCHECK_BIN="${QNP_HEALTHCHECK_BIN:-/qdrant/qnp-healthcheck.sh}"
# shellcheck source=/dev/null
source "$QNP_PERSISTENCE_LIB"

: "${QDRANT_API_KEY:?QDRANT_API_KEY is required in production}"
: "${QDRANT_READ_ONLY_API_KEY:?QDRANT_READ_ONLY_API_KEY is required in production}"
[[ "$QDRANT_API_KEY" != "$QDRANT_READ_ONLY_API_KEY" ]] || { echo "Admin and read-only API keys must be different" >&2; exit 1; }
[[ "${QNP_TOPOLOGY:-single}" == "single" ]] || { echo "This image supports only QNP_TOPOLOGY=single" >&2; exit 1; }
[[ "${QNP_ENV:-production}" == "production" ]] || { echo "Docker production image requires QNP_ENV=production" >&2; exit 1; }

export QNP_STORAGE_MODE="${QNP_STORAGE_MODE:-local}"
export QNP_PERSIST_PATH="${QNP_PERSIST_PATH:-/qdrant-persist}"

case "$QNP_STORAGE_MODE" in
    direct-mount-experimental)
        # Direct live storage only makes sense when the provider path is a real mount.
        export QNP_REQUIRE_PERSIST_MOUNT=1
        export QDRANT_STORAGE_PATH="${QDRANT_STORAGE_PATH:-$QNP_PERSIST_PATH/live}"
        export QDRANT_SNAPSHOTS_PATH="${QDRANT_SNAPSHOTS_PATH:-$QNP_PERSIST_PATH/snapshots}"
        export QDRANT_TEMP_PATH="${QDRANT_TEMP_PATH:-/tmp/qdrant}"
        ;;
    snapshot-persist)
        export QDRANT_STORAGE_PATH="${QDRANT_STORAGE_PATH:-/qdrant/storage}"
        export QDRANT_SNAPSHOTS_PATH="${QDRANT_SNAPSHOTS_PATH:-/qdrant/snapshots}"
        # Qdrant 1.18.3 full-storage restore reuses an explicitly configured
        # storage.temp_path for both the outer archive and per-collection
        # recovery. Leave temp_path unmanaged so Qdrant allocates distinct
        # recovery directories and avoids archive-unpack collisions.
        unset QDRANT_TEMP_PATH QDRANT__STORAGE__TEMP_PATH
        ;;
    local)
        export QDRANT_STORAGE_PATH="${QDRANT_STORAGE_PATH:-/qdrant/storage}"
        export QDRANT_SNAPSHOTS_PATH="${QDRANT_SNAPSHOTS_PATH:-/qdrant/snapshots}"
        export QDRANT_TEMP_PATH="${QDRANT_TEMP_PATH:-$QDRANT_SNAPSHOTS_PATH/.tmp}"
        ;;
esac

qnp_validate_storage_mode
if [[ "$QNP_STORAGE_MODE" != "local" ]]; then
    qnp_validate_persist_mount
fi
mkdir -p "$QDRANT_STORAGE_PATH" "$QDRANT_SNAPSHOTS_PATH"
if [[ -n "${QDRANT_TEMP_PATH:-}" ]]; then
    mkdir -p "$QDRANT_TEMP_PATH"
fi

export QDRANT__SERVICE__API_KEY="$QDRANT_API_KEY"
export QDRANT__SERVICE__READ_ONLY_API_KEY="$QDRANT_READ_ONLY_API_KEY"
export QDRANT__SERVICE__HOST="${QDRANT_BIND_HOST:-0.0.0.0}"
export QDRANT__SERVICE__HTTP_PORT="${QDRANT_HTTP_PORT:-6333}"
export QDRANT__SERVICE__ENABLE_CORS="${ENABLE_CORS:-false}"
QDRANT__SERVICE__JWT_RBAC="$([[ "${QDRANT_JWT_RBAC:-0}" == "1" ]] && echo true || echo false)"
export QDRANT__SERVICE__JWT_RBAC
export QDRANT__CLUSTER__ENABLED=false
export QDRANT__STORAGE__STORAGE_PATH="$QDRANT_STORAGE_PATH"
export QDRANT__STORAGE__SNAPSHOTS_PATH="$QDRANT_SNAPSHOTS_PATH"
if [[ "$QNP_STORAGE_MODE" == "snapshot-persist" ]]; then
    unset QDRANT__STORAGE__TEMP_PATH
elif [[ -n "${QDRANT_TEMP_PATH:-}" ]]; then
    export QDRANT__STORAGE__TEMP_PATH="$QDRANT_TEMP_PATH"
fi
export QDRANT__TELEMETRY_DISABLED=true

if [[ -n "${QDRANT_ALT_API_KEY:-}" ]]; then
    export QDRANT__SERVICE__ALT_API_KEY="$QDRANT_ALT_API_KEY"
fi

if [[ "$QNP_STORAGE_MODE" != "snapshot-persist" ]]; then
    exec "$QNP_QDRANT_BIN" "$@"
fi

qnp_validate_snapshot_policy
mkdir -p "$(qnp_persist_full_dir)"
[[ -w "$(qnp_persist_full_dir)" ]] || { echo "Persistent bucket mount is not writable: $(qnp_persist_full_dir)" >&2; exit 1; }

restore_args=()
staged_restore=""
if [[ "${QNP_AUTO_RESTORE:-1}" == "1" ]] && ! qnp_storage_has_live_data; then
    persisted_count="$(qnp_persisted_snapshot_count)"
    if staged_restore="$(qnp_stage_latest_snapshot_for_restore 2>/dev/null)"; then
        qnp_persist_log "restoring latest valid persistent full snapshot: $staged_restore"
        restore_args=(--storage-snapshot "$staged_restore")
    elif (( persisted_count > 0 )); then
        qnp_persist_error "persistent snapshots exist but none pass checksum verification; refusing to start empty"
        exit 1
    else
        qnp_persist_log "no persistent full snapshot found; starting with empty local storage"
    fi
elif [[ "${QNP_AUTO_RESTORE:-1}" == "1" ]]; then
    qnp_persist_log "local live storage is non-empty; automatic restore skipped"
fi

qdrant_pid=""
snapshot_loop_pid=""
# shellcheck disable=SC2317
shutdown_handler() {
    local signal="$1" rc=0
    trap - TERM INT
    [[ -z "$snapshot_loop_pid" ]] || { kill "$snapshot_loop_pid" 2>/dev/null || true; wait "$snapshot_loop_pid" 2>/dev/null || true; }
    if [[ "${QNP_AUTO_SNAPSHOT_ON_SHUTDOWN:-1}" == "1" ]] && "$QNP_HEALTHCHECK_BIN" >/dev/null 2>&1; then
        qnp_persist_log "creating bounded best-effort shutdown snapshot before forwarding $signal"
        qnp_create_persistent_snapshot_with_timeout "${QNP_SHUTDOWN_SNAPSHOT_TIMEOUT_SECONDS:-20}" || qnp_persist_warn "shutdown snapshot failed or timed out"
    fi
    if [[ -n "$qdrant_pid" ]] && kill -0 "$qdrant_pid" 2>/dev/null; then
        kill -"$signal" "$qdrant_pid" 2>/dev/null || true
        wait "$qdrant_pid" || rc=$?
    fi
    exit "$rc"
}
trap 'shutdown_handler TERM' TERM
trap 'shutdown_handler INT' INT

"$QNP_QDRANT_BIN" "${restore_args[@]}" "$@" &
qdrant_pid=$!

ready_rc=0
qnp_wait_ready "${QNP_READY_TIMEOUT_SECONDS:-180}" "$qdrant_pid" || ready_rc=$?
if (( ready_rc != 0 )); then
    if (( ready_rc == 2 )); then
        child_rc=0
        wait "$qdrant_pid" || child_rc=$?
        qnp_persist_error "Qdrant exited before readiness (exit code $child_rc); refusing to run snapshot-persist without an active backup loop"
        if (( child_rc == 0 )); then child_rc=1; fi
        exit "$child_rc"
    fi
    qnp_persist_error "Qdrant readiness timeout reached; refusing to run snapshot-persist without an active backup loop"
    if kill -0 "$qdrant_pid" 2>/dev/null; then
        kill -TERM "$qdrant_pid" 2>/dev/null || true
        wait "$qdrant_pid" 2>/dev/null || true
    else
        wait "$qdrant_pid" 2>/dev/null || true
    fi
    exit 1
else
    if [[ -n "$staged_restore" ]]; then
        rm -f "$staged_restore" "$staged_restore.sha256"
        rmdir "$(dirname "$staged_restore")" 2>/dev/null || true
    fi
    qnp_snapshot_loop &
    snapshot_loop_pid=$!
fi

rc=0
wait "$qdrant_pid" || rc=$?
[[ -z "$snapshot_loop_pid" ]] || { kill "$snapshot_loop_pid" 2>/dev/null || true; wait "$snapshot_loop_pid" 2>/dev/null || true; }
exit "$rc"
