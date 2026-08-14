#!/usr/bin/env bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export QNP_ENV="${QNP_ENV:-production}"
source "$PROJECT_DIR/scripts/common.sh"

[[ "$QNP_RUNTIME" == "native" ]] || fail "qdrant.sh prepare manages the native runtime. For Docker, build docker/Dockerfile instead."
bash "$PROJECT_DIR/scripts/production-check.sh"

header "Prepare single-node production runtime"
# Production preflight requires caller-injected keys. The credentials step validates
# them for the native runtime but deliberately does not persist them to secrets.env.
bash "$PROJECT_DIR/scripts/01_credentials.sh"
bash "$PROJECT_DIR/scripts/02_setup_env.sh"
bash "$PROJECT_DIR/scripts/03_download_qdrant.sh"
bash "$PROJECT_DIR/scripts/04_configure_qdrant.sh"

ok "Production runtime prepared without starting Qdrant"
muted "Start in the foreground with: QNP_ENV=production bash qdrant.sh serve"
