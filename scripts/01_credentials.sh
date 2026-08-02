#!/usr/bin/env bash
set -euo pipefail

# Capture caller-provided production secrets before any persisted secret source is
# considered. QNP_SECRET_POLICY=require-env means exactly that: explicit runtime
# injection, not fallback to secrets.env and not persistence back to disk.
_admin_explicit="${QDRANT_API_KEY+x}"
_readonly_explicit="${QDRANT_READ_ONLY_API_KEY+x}"
_admin_value="${QDRANT_API_KEY-}"
_readonly_value="${QDRANT_READ_ONLY_API_KEY-}"
_alt_explicit="${QDRANT_ALT_API_KEY+x}"
_alt_value="${QDRANT_ALT_API_KEY-}"

# shellcheck source=scripts/common.sh
source "$(dirname "$0")/common.sh"

header "Step 1: Prepare API credentials"
require openssl
ensure_runtime_dirs

if [[ "$QNP_SECRET_POLICY" == "require-env" ]]; then
    [[ -n "$_admin_explicit" && -n "$_admin_value" ]] || fail "QDRANT_API_KEY must be supplied explicitly for production"
    [[ -n "$_readonly_explicit" && -n "$_readonly_value" ]] || fail "QDRANT_READ_ONLY_API_KEY must be supplied explicitly for production"
    [[ "$_admin_value" != "$_readonly_value" ]] || fail "Admin and read-only API keys must be different"

    QDRANT_API_KEY="$_admin_value"
    QDRANT_READ_ONLY_API_KEY="$_readonly_value"
    export QDRANT_API_KEY QDRANT_READ_ONLY_API_KEY
    if [[ -n "$_alt_explicit" ]]; then
        QDRANT_ALT_API_KEY="$_alt_value"
        export QDRANT_ALT_API_KEY
    fi

    info "Using credentials injected by the caller environment"
    info "Admin API key:     $(mask "$QDRANT_API_KEY")"
    info "Read-only API key: $(mask "$QDRANT_READ_ONLY_API_KEY")"
    [[ -n "${QDRANT_ALT_API_KEY:-}" ]] && info "Alternate admin key: $(mask "$QDRANT_ALT_API_KEY")"
    info "QNP_SECRET_POLICY=require-env: secrets are not written to $SECRETS_FILE"
    exit 0
fi

load_secrets
if [[ -n "${QDRANT_API_KEY:-}" && -n "${QDRANT_READ_ONLY_API_KEY:-}" ]]; then
    info "Reusing credentials supplied by environment or $SECRETS_FILE"
else
    QDRANT_API_KEY="${QDRANT_API_KEY:-$(random_secret)}"
    QDRANT_READ_ONLY_API_KEY="${QDRANT_READ_ONLY_API_KEY:-$(random_secret)}"
    export QDRANT_API_KEY QDRANT_READ_ONLY_API_KEY
    write_secrets_file
    ok "New credentials generated"
fi

# Development keeps the historical persisted-secret workflow so management
# commands can reuse the generated/effective credentials.
write_secrets_file
info "Admin API key:     $(mask "$QDRANT_API_KEY")"
info "Read-only API key: $(mask "$QDRANT_READ_ONLY_API_KEY")"
[[ -n "${QDRANT_ALT_API_KEY:-}" ]] && info "Alternate admin key: $(mask "$QDRANT_ALT_API_KEY")"
info "Stored with mode 600 at: $SECRETS_FILE"
