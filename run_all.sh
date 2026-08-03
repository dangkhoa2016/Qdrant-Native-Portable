#!/usr/bin/env bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$PROJECT_DIR/scripts/common.sh"
cd "$PROJECT_DIR"

steps=(
    scripts/01_credentials.sh
    scripts/02_setup_env.sh
    scripts/03_download_qdrant.sh
    scripts/04_configure_qdrant.sh
    scripts/05_start_qdrant.sh
    scripts/06_verify_qdrant.sh
)
if [[ "$QNP_CREATE_DEMO_DATA" == "1" ]]; then
    # Preserve the historical development order while production defaults to a clean DB.
    steps+=(scripts/07_demo_data.sh)
fi
steps+=(
    scripts/08_setup_proxy.sh
    scripts/09_health_check.sh
)

banner "Qdrant v$QDRANT_VERSION - Native Portable Setup" \
    "Platform=$PLATFORM · Profile=$QDRANT_PROFILE · Process=$PROCESS_MODE · Deployment=$DEPLOYMENT_MODE"

current=0; total=${#steps[@]}; script=""
trap 'warn "Setup failed at step $current/$total: $script"' ERR
for script in "${steps[@]}"; do current=$((current + 1)); bash "$script"; done

if [[ "$START_TUNNEL" == "1" ]]; then bash scripts/public-access.sh; fi

header "Qdrant setup complete"
info "Local REST API:  $(local_api_url)"
info "Local dashboard: $(local_dashboard_url)"
[[ -f "$PUBLIC_URL_FILE" ]] && info "Public URL:      $(cat "$PUBLIC_URL_FILE")"
require_secrets
info "Admin API key:   $(mask "$QDRANT_API_KEY")"
info "Read-only key:   $(mask "$QDRANT_READ_ONLY_API_KEY")"
printf '\n'
muted "Doctor:       bash qdrant.sh doctor"
muted "System info:  bash qdrant.sh system-info"
muted "Public URL:   bash qdrant.sh public"
muted "Examples:     bash qdrant.sh examples"
muted "Benchmark:    bash qdrant.sh benchmark --points 10000 --dimension 768"
muted "Bench suite:   bash qdrant.sh benchmark-suite --quick"
muted "Clean retest:  bash qdrant.sh reinstall-test   # destructive, test only"
