#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname "$0")/common.sh"

action="start"
[[ "${1:-}" == "--stop" ]] && action="stop"

if [[ "$action" == "stop" ]]; then
    header "Disable public access"
    case "$PUBLIC_MODE" in
        cloudflare-quick)
            stop_pid_file "Cloudflare tunnel" "$TUNNEL_PID_FILE"
            rm -f "$PUBLIC_URL_FILE"
            ;;
        platform)
            if [[ "$PLATFORM" == "github-codespaces" && -n "${CODESPACE_NAME:-}" && -n "$(command -v gh 2>/dev/null || true)" ]]; then
                port="$(public_target_port)"
                if gh codespace ports visibility "${port}:private" -c "$CODESPACE_NAME" >/dev/null 2>&1; then ok "Codespaces port $port changed to private"; else warn "Could not change Codespaces port visibility; verify it in the PORTS panel"; fi
            fi
            rm -f "$PUBLIC_URL_FILE"
            ;;
        none) rm -f "$PUBLIC_URL_FILE" ;;
    esac
    exit 0
fi

header "Public access"
require_secrets
qdrant_ready || fail "Qdrant is not ready. Start the local stack first."
[[ "$DEPLOYMENT_MODE" != "proxy" ]] || proxy_ready || fail "Nginx proxy is configured but not ready."

case "$PUBLIC_MODE" in
    none) fail "PUBLIC_MODE=none. Set PUBLIC_MODE=cloudflare-quick or PUBLIC_MODE=platform." ;;
    cloudflare-quick) exec bash "$SCRIPT_DIR/10_start_tunnel.sh" ;;
    platform)
        if [[ "$PLATFORM" == "github-codespaces" ]]; then
            require gh
            port="$(public_target_port)"; name="${CODESPACE_NAME:?CODESPACE_NAME is not set}"; domain="${GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN:-app.github.dev}"
            info "Requesting public visibility for Codespaces port $port..."
            gh codespace ports visibility "${port}:public" -c "$name" >/dev/null || fail "Could not make the Codespaces port public. Organization policy may forbid public ports."
            url="https://${name}-${port}.${domain}"
            printf '%s\n' "$url" > "$PUBLIC_URL_FILE"; chmod 0600 "$PUBLIC_URL_FILE"
            ok "Codespaces public URL: $url"
            info "Dashboard: $url/dashboard"
            warn "The forwarded port is public. Qdrant authentication is still required."
        else
            fail "PUBLIC_MODE=platform currently automates GitHub Codespaces only. Use cloudflare-quick on this platform."
        fi
        ;;
esac
