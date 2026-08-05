#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname "$0")/common.sh"
cd "$PROJECT_DIR"

usage() {
    cat <<'EOF_USAGE'
Usage:
  bash scripts/service-manager.sh --action <start|stop|restart|status> \
      --service <qdrant|nginx|tunnel|all|public>

Groups:
  all     Qdrant plus Nginx only when DEPLOYMENT_MODE=proxy
  public  Local stack plus the configured public-access backend
EOF_USAGE
    exit "${1:-1}"
}

action=""; service=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --action) action="${2:-}"; shift 2 ;;
        --service) service="${2:-}"; shift 2 ;;
        -h|--help) usage 0 ;;
        *) usage ;;
    esac
done
[[ "$action" =~ ^(start|stop|restart|status)$ ]] || usage
[[ "$service" =~ ^(qdrant|nginx|tunnel|all|public)$ ]] || usage

# shellcheck disable=SC2015
start_one() {
    case "$1" in
        qdrant) bash scripts/05_start_qdrant.sh ;;
        nginx) [[ "$DEPLOYMENT_MODE" == "proxy" ]] && bash scripts/08_setup_proxy.sh || muted "Nginx skipped in minimal mode" ;;
        tunnel) bash scripts/public-access.sh ;;
    esac
}
# shellcheck disable=SC2015
stop_one() {
    case "$1" in
        qdrant) stop_pid_file "Qdrant" "$QDRANT_PID_FILE" ;;
        tunnel) bash scripts/public-access.sh --stop ;;
        nginx) [[ "$DEPLOYMENT_MODE" == "proxy" ]] && disable_proxy_config || muted "Nginx not used in minimal mode" ;;
    esac
}
status_one() {
    case "$1" in
        qdrant) if pid_is_running "$QDRANT_PID_FILE" && qdrant_ready; then ok "Qdrant is running (PID $(cat "$QDRANT_PID_FILE"))"; else warn "Qdrant is down"; fi ;;
        nginx) if [[ "$DEPLOYMENT_MODE" != "proxy" ]]; then muted "Nginx: not used (minimal mode)"; elif [[ -f "$NGINX_CONFIG" ]] && proxy_ready; then ok "Qdrant Nginx proxy is running"; else warn "Qdrant Nginx proxy is down or disabled"; fi ;;
        tunnel) if pid_is_running "$TUNNEL_PID_FILE"; then ok "Cloudflare tunnel is running: $(cat "$PUBLIC_URL_FILE" 2>/dev/null || echo URL-pending)"; elif [[ -f "$PUBLIC_URL_FILE" ]]; then info "Platform public URL: $(cat "$PUBLIC_URL_FILE")"; else muted "Public access is not active"; fi ;;
    esac
}

local_services=(qdrant)
[[ "$DEPLOYMENT_MODE" == "proxy" ]] && local_services+=(nginx)
case "$service" in all) services=("${local_services[@]}") ;; public) services=("${local_services[@]}" tunnel) ;; *) services=("$service") ;; esac

if [[ "$action" == "stop" || "$action" == "restart" ]]; then
    if [[ "$service" == "all" ]]; then services=(); [[ "$DEPLOYMENT_MODE" == "proxy" ]] && services+=(nginx); services+=(qdrant); fi
    if [[ "$service" == "public" ]]; then services=(tunnel); [[ "$DEPLOYMENT_MODE" == "proxy" ]] && services+=(nginx); services+=(qdrant); fi
fi

case "$action" in
    start) for item in "${services[@]}"; do start_one "$item"; done ;;
    status) for item in "${services[@]}"; do status_one "$item"; done ;;
    stop) for item in "${services[@]}"; do stop_one "$item"; done ;;
    restart)
        for item in "${services[@]}"; do stop_one "$item"; done; sleep 1
        services=("${local_services[@]}"); [[ "$service" == "public" ]] && services+=(tunnel); [[ "$service" != "all" && "$service" != "public" ]] && services=("$service")
        for item in "${services[@]}"; do start_one "$item"; done
        ;;
esac
