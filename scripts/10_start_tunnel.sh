#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname "$0")/common.sh"

header "Start Cloudflare Quick Tunnel"
require curl
require_secrets
qdrant_ready || fail "Start Qdrant before creating the tunnel."
[[ "$DEPLOYMENT_MODE" != "proxy" ]] || proxy_ready || fail "Nginx proxy is configured but not ready."
ensure_runtime_dirs

if [[ ! -x "$CLOUDFLARED_BIN" ]]; then
    info "Downloading cloudflared (${CLOUDFLARED_VERSION}) for $CLOUDFLARED_ARCH"
    download_with_retry "$CLOUDFLARED_URL" "$CLOUDFLARED_BIN" 3 || fail "Could not download cloudflared"
    verify_sha256_if_provided "$CLOUDFLARED_BIN" "${CLOUDFLARED_SHA256:-}"
    chmod 0755 "$CLOUDFLARED_BIN"
fi
if pid_is_running "$TUNNEL_PID_FILE"; then
    info "Tunnel is already running (PID $(cat "$TUNNEL_PID_FILE"))"
    [[ -f "$PUBLIC_URL_FILE" ]] && info "Public URL: $(cat "$PUBLIC_URL_FILE")"
    exit 0
fi

rm -f "$PUBLIC_URL_FILE"; : > "$TUNNEL_LOG"
target="$(public_target_url)"
info "Tunnel target: $target"
nohup "$CLOUDFLARED_BIN" tunnel --no-autoupdate --url "$target" >> "$TUNNEL_LOG" 2>&1 &
echo $! > "$TUNNEL_PID_FILE"; chmod 0600 "$TUNNEL_PID_FILE"
find_tunnel_url() { grep -Eo 'https://[-a-z0-9]+\.trycloudflare\.com' "$TUNNEL_LOG" | head -n 1 | tee "$PUBLIC_URL_FILE" >/dev/null; }
wait_for "Waiting for the public tunnel URL" "Cloudflare tunnel is ready" 60 find_tunnel_url || { tail -n 100 "$TUNNEL_LOG" || true; fail "Tunnel URL was not created"; }
chmod 0600 "$PUBLIC_URL_FILE"
public_url="$(cat "$PUBLIC_URL_FILE")"
ok "Public URL: $public_url"
info "Dashboard: $public_url/dashboard"
warn "Quick Tunnel is intended for testing/development. Prefer read-only or scoped JWT credentials for consumers that do not need admin access."
