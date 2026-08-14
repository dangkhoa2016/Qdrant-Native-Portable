#!/usr/bin/env bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export QNP_ENV="${QNP_ENV:-production}"
source "$PROJECT_DIR/scripts/common.sh"

[[ "$QNP_RUNTIME" == "native" ]] || fail "qdrant.sh serve is the native foreground lifecycle. Docker uses docker/entrypoint.sh."
bash "$PROJECT_DIR/scripts/production-check.sh"
require_service_control_privileges
require_secrets
[[ -x "$QDRANT_BIN" ]] || fail "Qdrant binary not found. Run: QNP_ENV=production bash qdrant.sh prepare"
[[ -f "$QDRANT_CONFIG" ]] || fail "Qdrant config not found. Run: QNP_ENV=production bash qdrant.sh prepare"
ensure_runtime_dirs
fix_runtime_ownership

export QDRANT__SERVICE__API_KEY="$QDRANT_API_KEY"
export QDRANT__SERVICE__READ_ONLY_API_KEY="$QDRANT_READ_ONLY_API_KEY"
# shellcheck disable=SC2155
QDRANT__SERVICE__JWT_RBAC="$([[ "$QDRANT_JWT_RBAC" == "1" ]] && echo true || echo false)"
export QDRANT__SERVICE__JWT_RBAC
export QDRANT__STORAGE__LOW_MEMORY_MODE="$PROFILE_LOW_MEMORY_MODE"
if [[ -n "${QDRANT_ALT_API_KEY:-}" ]]; then export QDRANT__SERVICE__ALT_API_KEY="$QDRANT_ALT_API_KEY"; else unset QDRANT__SERVICE__ALT_API_KEY 2>/dev/null || true; fi

header "Serve Qdrant in foreground"
info "Qdrant: $QDRANT_BIN"
info "Config: $QDRANT_CONFIG"
info "REST:   $QDRANT_BIND_HOST:$QDRANT_HTTP_PORT"

if [[ "$PROCESS_MODE" == "service-user" ]]; then
    require setpriv
    uid="$(id -u "$QDRANT_USER")"; gid="$(id -g "$QDRANT_USER")"
    exec setpriv --reuid="$uid" --regid="$gid" --init-groups "$QDRANT_BIN" --config-path "$QDRANT_CONFIG" "$@"
else
    exec "$QDRANT_BIN" --config-path "$QDRANT_CONFIG" "$@"
fi
