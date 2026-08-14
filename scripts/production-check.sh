#!/usr/bin/env bash
set -euo pipefail
# Capture caller-provided secrets before common.sh can load a persisted secrets.env.
_admin_explicit="${QDRANT_API_KEY+x}"
_readonly_explicit="${QDRANT_READ_ONLY_API_KEY+x}"
_admin_value="${QDRANT_API_KEY-}"
_readonly_value="${QDRANT_READ_ONLY_API_KEY-}"
# shellcheck source=scripts/common.sh
source "$(dirname "$0")/common.sh"

header "Single-node production preflight"
[[ "$QNP_ENV" == "production" ]] || fail "production-check requires QNP_ENV=production"
[[ "$QNP_TOPOLOGY" == "single" ]] || fail "This revision supports only QNP_TOPOLOGY=single"

if [[ "$QNP_RUNTIME" == "native" ]]; then
    [[ "$QDRANT_BIND_HOST" != "0.0.0.0" || "$PUBLIC_MODE" != "none" ]] || warn "Native Qdrant is bound to all interfaces without an ingress proxy; enforce host firewall/TLS before public traffic."
fi

[[ "$QNP_SECRET_POLICY" == "require-env" ]] || fail "Production requires QNP_SECRET_POLICY=require-env"
[[ -n "$_admin_explicit" && -n "$_admin_value" ]] || fail "QDRANT_API_KEY must be supplied explicitly in the production environment"
[[ -n "$_readonly_explicit" && -n "$_readonly_value" ]] || fail "QDRANT_READ_ONLY_API_KEY must be supplied explicitly in the production environment"
[[ "$_admin_value" != "$_readonly_value" ]] || fail "QDRANT_API_KEY and QDRANT_READ_ONLY_API_KEY must be different"

if [[ "$QNP_RUNTIME" == "native" ]]; then
    [[ "${QDRANT_SHA256:-}" =~ ^[[:xdigit:]]{64}$ ]] || fail "Production native runtime requires QDRANT_SHA256 to be a 64-hex SHA256 digest"
fi

if [[ "$PUBLIC_MODE" == "cloudflare-quick" && "$QNP_ALLOW_DEMO_TUNNEL" != "1" ]]; then
    fail "Production Cloudflare Quick Tunnel is demo ingress only. Set QNP_ALLOW_DEMO_TUNNEL=1 for explicit acknowledgement, or use PUBLIC_MODE=none."
fi
if [[ "$START_TUNNEL" == "1" && "$PUBLIC_MODE" == "none" ]]; then
    fail "START_TUNNEL=1 conflicts with production PUBLIC_MODE=none"
fi

if [[ "$PLATFORM" == "kaggle" && "$QNP_KAGGLE_PERSISTENCE" == "none" ]]; then
    warn "Kaggle persistence is not declared. Enable Files/Variables & Files in Kaggle and set QNP_KAGGLE_PERSISTENCE accordingly for persistent production-demo data."
fi
if [[ "$ENABLE_CORS" == "true" ]]; then
    warn "ENABLE_CORS=true broadens browser access. Keep it disabled unless the application requires it."
fi

info "Environment:       $QNP_ENV"
info "Runtime:           $QNP_RUNTIME"
info "Topology:          $QNP_TOPOLOGY"
info "Public mode:       $PUBLIC_MODE"
info "Qdrant bind:       $QDRANT_BIND_HOST:$QDRANT_HTTP_PORT"
info "Demo data:         $QNP_CREATE_DEMO_DATA"
info "Secret policy:     $QNP_SECRET_POLICY"
ok "Single-node production preflight passed"
