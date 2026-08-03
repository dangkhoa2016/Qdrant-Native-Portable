#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname "$0")/common.sh"

header "Step 8: Configure optional single-port Nginx proxy"
if [[ "$DEPLOYMENT_MODE" != "proxy" ]]; then
    info "DEPLOYMENT_MODE=minimal: skipping Nginx. Clients connect directly to 127.0.0.1:$QDRANT_HTTP_PORT."
    exit 0
fi
require_root
require nginx
require_secrets

cat > "$NGINX_CONFIG" <<EOF_NGINX
server {
    listen ${PROXY_BIND}:${PROXY_PORT};
    server_name _;
    server_tokens off;
    client_max_body_size ${QDRANT_MAX_REQUEST_SIZE_MB}M;
    proxy_connect_timeout 30s;
    proxy_read_timeout 600s;
    proxy_send_timeout 600s;
    location / {
        proxy_pass http://127.0.0.1:${QDRANT_HTTP_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_request_buffering off;
        proxy_buffering off;
    }
}
EOF_NGINX
nginx -t
if [[ -f /run/nginx.pid ]] && kill -0 "$(cat /run/nginx.pid)" 2>/dev/null; then nginx -s reload; else nginx; fi
wait_for "Waiting for Nginx proxy" "Nginx proxy is ready" 30 proxy_ready || fail "Nginx proxy did not become ready"
ok "Single proxy endpoint: http://${PROXY_BIND}:${PROXY_PORT}"
info "Dashboard: http://${PROXY_BIND}:${PROXY_PORT}/dashboard"
