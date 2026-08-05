#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname "$0")/common.sh"
cd "$PROJECT_DIR"
require curl jq sha256sum
require_secrets

base="http://127.0.0.1:${QDRANT_HTTP_PORT}"

usage() {
    cat <<'EOF_USAGE'
Usage:
  bash scripts/snapshot-manager.sh create-full
  bash scripts/snapshot-manager.sh list-full
  bash scripts/snapshot-manager.sh download-full <snapshot-name> <destination-file>
  bash scripts/snapshot-manager.sh delete-full <snapshot-name>
  bash scripts/snapshot-manager.sh restore-full <snapshot-file> --yes

  bash scripts/snapshot-manager.sh create-collection <collection>
  bash scripts/snapshot-manager.sh list-collection <collection>
  bash scripts/snapshot-manager.sh download-collection <collection> <snapshot-name> <destination-file>
  bash scripts/snapshot-manager.sh delete-collection <collection> <snapshot-name>
  bash scripts/snapshot-manager.sh restore-collection <collection> <snapshot-file>

Downloaded snapshots receive a sibling .sha256 file. Restore commands verify that
checksum automatically when it exists.
EOF_USAGE
    exit "${1:-1}"
}

write_checksum() {
    local file="$1" dir base
    dir="$(cd "$(dirname "$file")" && pwd)"
    base="$(basename "$file")"
    (cd "$dir" && sha256sum "$base" > "$base.sha256")
    chmod 0600 "$file.sha256" 2>/dev/null || true
    ok "SHA256: $file.sha256"
}

verify_sidecar_checksum() {
    local file="$1"
    if [[ -f "$file.sha256" ]]; then
        (cd "$(dirname "$file")" && sha256sum -c "$(basename "$file").sha256") >/dev/null \
            || fail "Snapshot checksum verification failed: $file"
        ok "Snapshot checksum verified"
    else
        warn "No checksum sidecar found: $file.sha256"
    fi
}

require_running_qdrant() {
    qdrant_ready || fail "Qdrant must be running for this snapshot operation."
}

restore_full() {
    local snapshot_file="$1" confirm="${2:-}"
    [[ -f "$snapshot_file" ]] || fail "Snapshot file not found: $snapshot_file"
    [[ "$confirm" == "--yes" ]] || fail "Full restore replaces the active storage. Re-run with --yes after verifying the snapshot."
    require_service_control_privileges
    verify_sidecar_checksum "$snapshot_file"
    ensure_runtime_dirs

    local timestamp backup_dir staged_snapshot was_running=0
    timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
    backup_dir="$QDRANT_BACKUPS/storage-before-restore-$timestamp"
    staged_snapshot="$QDRANT_TMP/full-restore-$timestamp.snapshot"

    if pid_is_running "$QDRANT_PID_FILE"; then
        was_running=1
        stop_pid_file "Qdrant" "$QDRANT_PID_FILE"
    fi

    info "Creating rollback copy by moving current storage to: $backup_dir"
    if [[ -d "$QDRANT_STORAGE" ]]; then
        mv "$QDRANT_STORAGE" "$backup_dir"
    else
        mkdir -p "$backup_dir"
    fi
    mkdir -p "$QDRANT_STORAGE"
    if [[ "$PROCESS_MODE" == "service-user" ]]; then chown -R "$QDRANT_USER:$QDRANT_USER" "$QDRANT_STORAGE" "$backup_dir"; fi

    cp "$snapshot_file" "$staged_snapshot"
    if [[ "$PROCESS_MODE" == "service-user" ]]; then chown "$QDRANT_USER:$QDRANT_USER" "$staged_snapshot"; fi
    chmod 0600 "$staged_snapshot"

    info "Restoring full storage snapshot at Qdrant startup..."
    if start_qdrant_process --storage-snapshot "$staged_snapshot" && \
       wait_for "Waiting for restored Qdrant" "Full snapshot restore succeeded" 180 qdrant_ready; then
        rm -f "$staged_snapshot"
        ok "Previous storage preserved for rollback: $backup_dir"
        return 0
    fi

    warn "Full snapshot restore failed. Rolling back the previous storage..."
    stop_pid_file "Qdrant" "$QDRANT_PID_FILE" || true
    rm -rf "$QDRANT_STORAGE"
    mv "$backup_dir" "$QDRANT_STORAGE"
    if [[ "$PROCESS_MODE" == "service-user" ]]; then chown -R "$QDRANT_USER:$QDRANT_USER" "$QDRANT_STORAGE"; fi
    rm -f "$staged_snapshot"

    if (( was_running )); then
        start_qdrant_process
        wait_for "Restarting original Qdrant" "Rollback succeeded" 120 qdrant_ready || \
            fail "Restore failed and automatic rollback could not restart Qdrant. Inspect $QDRANT_LOG"
    fi
    fail "Full snapshot restore failed; original storage was restored. Inspect $QDRANT_LOG"
}

command="${1:-}"
case "$command" in
    create-full)
        require_running_qdrant
        api_curl -X POST "$base/snapshots" | jq .
        ;;
    list-full)
        require_running_qdrant
        api_curl "$base/snapshots" | jq .
        ;;
    download-full)
        [[ $# -eq 3 ]] || usage
        require_running_qdrant
        api_curl "$base/snapshots/$2" -o "$3"
        chmod 0600 "$3" 2>/dev/null || true
        ok "Downloaded: $3"
        write_checksum "$3"
        ;;
    delete-full)
        [[ $# -eq 2 ]] || usage
        require_running_qdrant
        api_curl -X DELETE "$base/snapshots/$2" | jq .
        ;;
    restore-full)
        [[ $# -eq 3 ]] || usage
        restore_full "$2" "$3"
        ;;
    create-collection)
        [[ $# -eq 2 ]] || usage
        require_running_qdrant
        api_curl -X POST "$base/collections/$2/snapshots" | jq .
        ;;
    list-collection)
        [[ $# -eq 2 ]] || usage
        require_running_qdrant
        api_curl "$base/collections/$2/snapshots" | jq .
        ;;
    download-collection)
        [[ $# -eq 4 ]] || usage
        require_running_qdrant
        api_curl "$base/collections/$2/snapshots/$3" -o "$4"
        chmod 0600 "$4" 2>/dev/null || true
        ok "Downloaded: $4"
        write_checksum "$4"
        ;;
    delete-collection)
        [[ $# -eq 3 ]] || usage
        require_running_qdrant
        api_curl -X DELETE "$base/collections/$2/snapshots/$3" | jq .
        ;;
    restore-collection)
        [[ $# -eq 3 ]] || usage
        require_running_qdrant
        [[ -f "$3" ]] || fail "Snapshot file not found: $3"
        verify_sidecar_checksum "$3"
        api_curl -X POST "$base/collections/$2/snapshots/upload?priority=snapshot" \
            -F "snapshot=@$3" | jq .
        ;;
    -h|--help|"") usage 0 ;;
    *) usage ;;
esac
