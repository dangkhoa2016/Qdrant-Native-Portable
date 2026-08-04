#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname "$0")/common.sh"
cd "$PROJECT_DIR"
require openssl

usage() {
    cat <<'EOF_USAGE'
Usage:
  bash scripts/credentials-manager.sh status
  bash scripts/credentials-manager.sh rotate-readonly [--restart]
  bash scripts/credentials-manager.sh rotate-all [--restart]
  bash scripts/credentials-manager.sh stage-admin-rotation [--restart]
  bash scripts/credentials-manager.sh promote-admin-rotation [--restart]
  bash scripts/credentials-manager.sh cancel-admin-rotation [--restart]
  bash scripts/credentials-manager.sh jwt-enable [--restart]
  bash scripts/credentials-manager.sh jwt-disable [--restart]
  bash scripts/credentials-manager.sh create-token [--scope COLLECTION:r|rw ... | --access r|m]
      [--ttl SECONDS] [--output FILE] [--reveal]

Notes:
  - JWT RBAC uses the admin API key as the HS256 signing secret.
  - Rotating the admin key invalidates JWTs signed with the previous key.
  - Generated tokens are stored with mode 600 unless --reveal is requested.
EOF_USAGE
    exit "${1:-1}"
}

cmd="${1:-}"; shift || true
restart=0
apply_restart() {
    if (( restart )); then
        if pid_is_running "$QDRANT_PID_FILE"; then
            info "Restarting Qdrant so credential/config changes take effect..."
            stop_pid_file "Qdrant" "$QDRANT_PID_FILE"
            bash scripts/05_start_qdrant.sh
            bash scripts/06_verify_qdrant.sh
        else warn "Qdrant is not running; changes will apply on the next start."; fi
    else warn "Changes are persisted but a running Qdrant process keeps its current environment until restart."; fi
}

load_secrets
case "$cmd" in
    status)
        require_secrets
        info "Admin API key:     $(mask "$QDRANT_API_KEY")"
        info "Read-only API key: $(mask "$QDRANT_READ_ONLY_API_KEY")"
        # shellcheck disable=SC2015
        [[ -n "${QDRANT_ALT_API_KEY:-}" ]] && info "Alternate admin:   $(mask "$QDRANT_ALT_API_KEY") (rotation staged)" || muted "Alternate admin:   not set"
        info "JWT RBAC:          $QDRANT_JWT_RBAC"
        ;;
    rotate-readonly|rotate-all|stage-admin-rotation|promote-admin-rotation|cancel-admin-rotation|jwt-enable|jwt-disable)
        while [[ $# -gt 0 ]]; do case "$1" in --restart) restart=1; shift ;; -h|--help) usage 0 ;; *) usage ;; esac; done
        require_secrets
        case "$cmd" in
            rotate-readonly) QDRANT_READ_ONLY_API_KEY="$(random_secret)"; export QDRANT_READ_ONLY_API_KEY; write_secrets_file; ok "Read-only key rotated: $(mask "$QDRANT_READ_ONLY_API_KEY")" ;;
            rotate-all) QDRANT_API_KEY="$(random_secret)"; QDRANT_READ_ONLY_API_KEY="$(random_secret)"; QDRANT_ALT_API_KEY=""; export QDRANT_API_KEY QDRANT_READ_ONLY_API_KEY QDRANT_ALT_API_KEY; write_secrets_file; ok "Admin and read-only keys rotated"; warn "Any JWT signed with the previous admin key is now invalid." ;;
            stage-admin-rotation) [[ -z "${QDRANT_ALT_API_KEY:-}" ]] || fail "An admin rotation is already staged."; QDRANT_ALT_API_KEY="$(random_secret)"; export QDRANT_ALT_API_KEY; write_secrets_file; ok "Alternate admin key created: $(mask "$QDRANT_ALT_API_KEY")" ;;
            promote-admin-rotation) [[ -n "${QDRANT_ALT_API_KEY:-}" ]] || fail "No staged alternate admin key exists."; QDRANT_API_KEY="$QDRANT_ALT_API_KEY"; QDRANT_ALT_API_KEY=""; export QDRANT_API_KEY QDRANT_ALT_API_KEY; write_secrets_file; ok "Alternate key promoted"; warn "JWTs signed with the previous admin key must be re-issued." ;;
            cancel-admin-rotation) QDRANT_ALT_API_KEY=""; export QDRANT_ALT_API_KEY; write_secrets_file; ok "Staged alternate admin key removed" ;;
            jwt-enable) QDRANT_JWT_RBAC=1; export QDRANT_JWT_RBAC; write_runtime_env; ok "JWT RBAC enabled in persisted runtime settings" ;;
            jwt-disable) QDRANT_JWT_RBAC=0; export QDRANT_JWT_RBAC; write_runtime_env; ok "JWT RBAC disabled in persisted runtime settings" ;;
        esac
        apply_restart
        ;;
    create-token)
        require_secrets
        [[ "$QDRANT_JWT_RBAC" == "1" ]] || fail "JWT RBAC is disabled. Run: bash qdrant.sh credentials jwt-enable --restart"
        require python3
        scopes=(); access=""; ttl=3600; output=""; reveal=0
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --scope) scopes+=("${2:-}"); shift 2 ;;
                --access) access="${2:-}"; shift 2 ;;
                --ttl) ttl="${2:-}"; shift 2 ;;
                --output) output="${2:-}"; shift 2 ;;
                --reveal) reveal=1; shift ;;
                -h|--help) usage 0 ;;
                *) usage ;;
            esac
        done
        args=(--ttl "$ttl")
        for scope in "${scopes[@]}"; do args+=(--scope "$scope"); done
        [[ -z "$access" ]] || args+=(--access "$access")
        token="$(QDRANT_API_KEY="$QDRANT_API_KEY" python3 scripts/jwt-token.py "${args[@]}")"
        ensure_runtime_dirs
        if [[ -z "$output" ]]; then output="$QDRANT_TOKENS/qdrant-token-$(date -u +%Y%m%dT%H%M%SZ).jwt"; fi
        umask 077; printf '%s\n' "$token" > "$output"; chmod 0600 "$output"
        ok "JWT written: $output"
        info "Token: $(mask "$token")"
        (( reveal )) && printf '%s\n' "$token"
        ;;
    -h|--help|"") usage 0 ;;
    *) usage ;;
esac
