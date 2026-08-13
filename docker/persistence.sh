#!/usr/bin/env bash
# Helper library for single-node Docker persistence modes.
# This file is sourced by docker/entrypoint.sh and is intentionally side-effect free.

qnp_persist_log() { printf '[qnp-persist] %s\n' "$*" >&2; }
qnp_persist_warn() { printf '[qnp-persist] WARNING: %s\n' "$*" >&2; }
qnp_persist_error() { printf '[qnp-persist] ERROR: %s\n' "$*" >&2; }

qnp_trim_slash() {
    local value="${1:-/}"
    while [[ "$value" != "/" && "$value" == */ ]]; do value="${value%/}"; done
    printf '%s\n' "$value"
}

qnp_paths_overlap() {
    local a b
    a="$(qnp_trim_slash "$1")"
    b="$(qnp_trim_slash "$2")"
    [[ "$a" == "$b" || "$a" == "$b"/* || "$b" == "$a"/* ]]
}

qnp_validate_storage_mode() {
    local mode="${QNP_STORAGE_MODE:-local}"
    local storage="${QDRANT_STORAGE_PATH:-/qdrant/storage}"
    local persist="${QNP_PERSIST_PATH:-/qdrant-persist}"

    case "$mode" in
        local)
            return 0
            ;;
        snapshot-persist)
            if qnp_paths_overlap "$storage" "$persist"; then
                qnp_persist_error "snapshot-persist requires separate live-storage and persistent-backup paths: storage=$storage persist=$persist"
                return 1
            fi
            ;;
        direct-mount-experimental)
            if [[ "${QNP_ALLOW_UNSUPPORTED_STORAGE:-0}" != "1" ]]; then
                qnp_persist_error "direct-mount-experimental requires QNP_ALLOW_UNSUPPORTED_STORAGE=1"
                return 1
            fi
            qnp_persist_warn "direct-mounted live storage is experimental and unsupported by Qdrant when the mount is FUSE/NFS/object-storage backed"
            ;;
        *)
            qnp_persist_error "unsupported QNP_STORAGE_MODE=$mode (expected local, snapshot-persist, or direct-mount-experimental)"
            return 1
            ;;
    esac
}

qnp_persist_full_dir() {
    printf '%s/full\n' "$(qnp_trim_slash "${QNP_PERSIST_PATH:-/qdrant-persist}")"
}

qnp_validate_snapshot_policy() {
    local auto_restore="${QNP_AUTO_RESTORE:-1}"
    local interval="${QNP_AUTO_SNAPSHOT_INTERVAL_SECONDS:-0}"
    local on_shutdown="${QNP_AUTO_SNAPSHOT_ON_SHUTDOWN:-1}"
    local shutdown_timeout="${QNP_SHUTDOWN_SNAPSHOT_TIMEOUT_SECONDS:-20}"
    local ready_timeout="${QNP_READY_TIMEOUT_SECONDS:-180}"
    local retention="${QNP_SNAPSHOT_RETENTION:-3}"
    local require_mount="${QNP_REQUIRE_PERSIST_MOUNT:-0}"

    [[ "$auto_restore" == "0" || "$auto_restore" == "1" ]] || {
        qnp_persist_error "QNP_AUTO_RESTORE must be 0 or 1"; return 1;
    }
    [[ "$on_shutdown" == "0" || "$on_shutdown" == "1" ]] || {
        qnp_persist_error "QNP_AUTO_SNAPSHOT_ON_SHUTDOWN must be 0 or 1"; return 1;
    }
    [[ "$require_mount" == "0" || "$require_mount" == "1" ]] || {
        qnp_persist_error "QNP_REQUIRE_PERSIST_MOUNT must be 0 or 1"; return 1;
    }
    [[ "$interval" =~ ^[0-9]+$ ]] || {
        qnp_persist_error "QNP_AUTO_SNAPSHOT_INTERVAL_SECONDS must be a non-negative integer"; return 1;
    }
    (( interval == 0 || interval >= 60 )) || {
        qnp_persist_error "QNP_AUTO_SNAPSHOT_INTERVAL_SECONDS must be 0 or at least 60"; return 1;
    }
    # shellcheck disable=SC2015
    [[ "$shutdown_timeout" =~ ^[0-9]+$ ]] && (( shutdown_timeout > 0 )) || {
        qnp_persist_error "QNP_SHUTDOWN_SNAPSHOT_TIMEOUT_SECONDS must be a positive integer"; return 1;
    }
    # shellcheck disable=SC2015
    [[ "$ready_timeout" =~ ^[0-9]+$ ]] && (( ready_timeout > 0 )) || {
        qnp_persist_error "QNP_READY_TIMEOUT_SECONDS must be a positive integer"; return 1;
    }
    [[ "$retention" =~ ^[0-9]+$ ]] || {
        qnp_persist_error "QNP_SNAPSHOT_RETENTION must be a non-negative integer"; return 1;
    }
}

qnp_validate_persist_mount() {
    [[ "${QNP_REQUIRE_PERSIST_MOUNT:-0}" == "1" ]] || return 0
    local persist mountinfo
    persist="$(qnp_trim_slash "${QNP_PERSIST_PATH:-/qdrant-persist}")"
    mountinfo="${QNP_MOUNTINFO_PATH:-/proc/self/mountinfo}"
    [[ -r "$mountinfo" ]] || { qnp_persist_error "cannot read mount table: $mountinfo"; return 1; }
    grep -F " $persist " "$mountinfo" >/dev/null 2>&1 || {
        qnp_persist_error "QNP_REQUIRE_PERSIST_MOUNT=1 but $persist is not a mounted volume"
        return 1
    }
}

qnp_select_latest_snapshot() {
    local dir latest name candidate
    dir="$(qnp_persist_full_dir)"
    latest="$dir/LATEST"
    [[ -d "$dir" ]] || return 1

    if [[ -f "$latest" ]]; then
        IFS= read -r name < "$latest" || true
        if [[ -n "${name:-}" ]]; then
            candidate="$dir/$name"
            if [[ -f "$candidate" ]]; then
                printf '%s\n' "$candidate"
                return 0
            fi
        fi
    fi

    # shellcheck disable=SC2012
    candidate="$(ls -1t "$dir"/*.snapshot 2>/dev/null | head -n 1 || true)"
    [[ -n "$candidate" && -f "$candidate" ]] || return 1
    printf '%s\n' "$candidate"
}

qnp_verify_snapshot() {
    local snapshot="$1"
    local sidecar="$snapshot.sha256"
    [[ -f "$snapshot" ]] || { qnp_persist_error "snapshot not found: $snapshot"; return 1; }
    [[ -f "$sidecar" ]] || { qnp_persist_error "checksum sidecar not found: $sidecar"; return 1; }
    (cd "$(dirname "$snapshot")" && sha256sum -c "$(basename "$sidecar")" >/dev/null)
}

qnp_select_latest_valid_snapshot() {
    local dir preferred candidate
    dir="$(qnp_persist_full_dir)"
    [[ -d "$dir" ]] || return 1

    preferred="$(qnp_select_latest_snapshot 2>/dev/null || true)"
    if [[ -n "$preferred" ]] && qnp_verify_snapshot "$preferred" >/dev/null 2>&1; then
        printf '%s\n' "$preferred"
        return 0
    fi

    while IFS= read -r candidate; do
        [[ -n "$candidate" ]] || continue
        [[ "$candidate" == "$preferred" ]] && continue
        if qnp_verify_snapshot "$candidate" >/dev/null 2>&1; then
            qnp_persist_warn "preferred snapshot is invalid; falling back to $(basename "$candidate")"
            printf '%s\n' "$candidate"
            return 0
        fi
    done < <(ls -1t "$dir"/*.snapshot 2>/dev/null || true)
    return 1
}

qnp_persisted_snapshot_count() {
    local dir count=0 candidate
    dir="$(qnp_persist_full_dir)"
    [[ -d "$dir" ]] || { printf '0\n'; return 0; }
    while IFS= read -r candidate; do
        [[ -n "$candidate" ]] && ((count += 1))
    done < <(ls -1 "$dir"/*.snapshot 2>/dev/null || true)
    printf '%s\n' "$count"
}

qnp_storage_has_live_data() {
    local storage="${QDRANT_STORAGE_PATH:-/qdrant/storage}"
    [[ -d "$storage" ]] || return 1
    [[ -n "$(find "$storage" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null || true)" ]]
}

qnp_stage_latest_snapshot_for_restore() {
    local selected restore_dir staged
    selected="$(qnp_select_latest_valid_snapshot)" || return 1

    restore_dir="${QDRANT_SNAPSHOTS_PATH:-/qdrant/snapshots}/.qnp-restore"
    mkdir -p "$restore_dir"
    staged="$restore_dir/$(basename "$selected")"
    cp "$selected" "$staged.partial"
    mv "$staged.partial" "$staged"
    cp "$selected.sha256" "$staged.sha256"
    qnp_verify_snapshot "$staged" || { rm -f "$staged" "$staged.sha256"; return 1; }
    printf '%s\n' "$staged"
}

qnp_http_post() {
    local path="$1" host="${QDRANT_HEALTH_HOST:-127.0.0.1}" port="${QDRANT_HTTP_PORT:-6333}"
    local response
    exec 9<>"/dev/tcp/${host}/${port}" || return 1
    printf 'POST %s HTTP/1.1\r\nHost: %s\r\napi-key: %s\r\nContent-Length: 0\r\nConnection: close\r\n\r\n' \
        "$path" "$host" "${QDRANT_API_KEY:?}" >&9
    response="$(cat <&9)" || true
    exec 9>&- 9<&-
    printf '%s\n' "$response"
}

qnp_create_persistent_snapshot() {
    local response name source dir tmp dest retention old base
    dir="$(qnp_persist_full_dir)"
    mkdir -p "$dir"
    [[ -w "$dir" ]] || { qnp_persist_error "persistent snapshot directory is not writable: $dir"; return 1; }

    response="$(qnp_http_post '/snapshots')" || { qnp_persist_error "snapshot API request failed"; return 1; }
    name="$(printf '%s' "$response" | tr -d '\r\n' | sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\.snapshot\)".*/\1/p' | head -n 1)"
    [[ -n "$name" ]] || { qnp_persist_error "snapshot API did not return a snapshot name"; return 1; }

    source="${QDRANT_SNAPSHOTS_PATH:-${QDRANT_STORAGE_PATH:-/qdrant/storage}/snapshots}/$name"
    for _ in {1..20}; do [[ -f "$source" ]] && break; sleep 0.25; done
    [[ -f "$source" ]] || { qnp_persist_error "created snapshot file not found: $source"; return 1; }

    dest="$dir/$name"
    tmp="$dest.partial.$$"
    cp "$source" "$tmp"
    mv "$tmp" "$dest"
    (cd "$dir" && sha256sum "$name" > "$name.sha256")
    {
        printf 'created_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf 'qdrant_version=%s\n' "${QDRANT_VERSION:-1.18.3}"
        printf 'storage_mode=snapshot-persist\n'
    } > "$dest.manifest.txt"
    printf '%s\n' "$name" > "$dir/LATEST.tmp.$$"
    mv "$dir/LATEST.tmp.$$" "$dir/LATEST"
    rm -f "$source"
    qnp_persist_log "persistent full snapshot created: $dest"

    retention="${QNP_SNAPSHOT_RETENTION:-3}"
    if [[ "$retention" =~ ^[0-9]+$ ]] && (( retention > 0 )); then
        # shellcheck disable=SC2012
        while IFS= read -r old; do
            [[ -n "$old" ]] || continue
            base="${old%.snapshot}"
            rm -f "$old" "$old.sha256" "$old.manifest.txt" "$base.manifest.txt"
        done < <(ls -1t "$dir"/*.snapshot 2>/dev/null | tail -n +$((retention + 1)) || true)
    fi
}

qnp_create_persistent_snapshot_with_timeout() {
    local timeout_seconds="${1:-20}" pid i rc=0
    # shellcheck disable=SC2015
    [[ "$timeout_seconds" =~ ^[0-9]+$ ]] && (( timeout_seconds > 0 )) || {
        qnp_persist_error "snapshot timeout must be a positive integer"
        return 2
    }

    qnp_create_persistent_snapshot &
    pid=$!
    for ((i=0; i<timeout_seconds; i++)); do
        if ! kill -0 "$pid" 2>/dev/null; then
            wait "$pid" || rc=$?
            return "$rc"
        fi
        sleep 1
    done

    if kill -0 "$pid" 2>/dev/null; then
        kill -TERM "$pid" 2>/dev/null || true
        sleep 0.2
        kill -KILL "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
        qnp_persist_warn "persistent snapshot exceeded ${timeout_seconds}s timeout"
        return 124
    fi
    wait "$pid" || rc=$?
    return "$rc"
}

qnp_wait_ready() {
    local max_seconds="${1:-180}" watched_pid="${2:-}" i
    for ((i=0; i<max_seconds; i++)); do
        if [[ -n "$watched_pid" ]] && ! kill -0 "$watched_pid" 2>/dev/null; then
            return 2
        fi
        if "${QNP_HEALTHCHECK_BIN:-/qdrant/qnp-healthcheck.sh}" >/dev/null 2>&1; then return 0; fi
        sleep 1
    done
    if [[ -n "$watched_pid" ]] && ! kill -0 "$watched_pid" 2>/dev/null; then
        return 2
    fi
    return 1
}

qnp_snapshot_loop() {
    local interval="${QNP_AUTO_SNAPSHOT_INTERVAL_SECONDS:-0}"
    [[ "$interval" =~ ^[0-9]+$ ]] || { qnp_persist_error "QNP_AUTO_SNAPSHOT_INTERVAL_SECONDS must be a non-negative integer"; return 1; }
    (( interval == 0 )) && return 0
    (( interval >= 60 )) || { qnp_persist_error "QNP_AUTO_SNAPSHOT_INTERVAL_SECONDS must be 0 or at least 60"; return 1; }

    while sleep "$interval"; do
        if "${QNP_HEALTHCHECK_BIN:-/qdrant/qnp-healthcheck.sh}" >/dev/null 2>&1; then
            qnp_create_persistent_snapshot || qnp_persist_warn "periodic snapshot failed"
        else
            qnp_persist_warn "skipping periodic snapshot because Qdrant is not ready"
        fi
    done
}
