#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname "$0")/common.sh"

header "Step 2: Prepare portable Linux environment"
ensure_runtime_dirs

base_packages=(curl ca-certificates jq openssl tar)
proxy_packages=(nginx)
packages=("${base_packages[@]}")
[[ "$DEPLOYMENT_MODE" == "proxy" ]] && packages+=("${proxy_packages[@]}" util-linux)

missing_cmds=()
for cmd in curl jq openssl tar; do command -v "$cmd" >/dev/null 2>&1 || missing_cmds+=("$cmd"); done
if [[ "$DEPLOYMENT_MODE" == "proxy" ]]; then
    command -v nginx >/dev/null 2>&1 || missing_cmds+=(nginx)
    [[ "$PROCESS_MODE" != "service-user" ]] || command -v setpriv >/dev/null 2>&1 || missing_cmds+=(setpriv)
fi

if (( ${#missing_cmds[@]} > 0 )); then
    if [[ "$(id -u)" -eq 0 ]] && command -v apt-get >/dev/null 2>&1; then
        info "Installing missing OS packages with apt: ${packages[*]}"
        apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${packages[@]}"
    elif command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1 && command -v apt-get >/dev/null 2>&1; then
        info "Installing missing OS packages with passwordless sudo: ${packages[*]}"
        sudo apt-get update -qq
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${packages[@]}"
    else
        fail "Missing tools: ${missing_cmds[*]}. Install them, or use DEPLOYMENT_MODE=minimal to avoid Nginx."
    fi
fi

require curl jq openssl tar
[[ "$DEPLOYMENT_MODE" != "proxy" ]] || require nginx

if [[ "$PROCESS_MODE" == "service-user" ]]; then
    require_root
    require setpriv
    if ! id "$QDRANT_USER" >/dev/null 2>&1; then
        useradd --system --home-dir "$BASE_DIR" --shell /usr/sbin/nologin "$QDRANT_USER"
        ok "Created service user: $QDRANT_USER"
    fi
    chown -R "$QDRANT_USER:$QDRANT_USER" "$QDRANT_STORAGE" "$QDRANT_SNAPSHOTS" "$QDRANT_LOGS" "$QDRANT_TMP"
else
    info "Rootless/current-user process mode: no system user is created"
fi

chmod 0750 "$QDRANT_STORAGE" "$QDRANT_SNAPSHOTS" "$QDRANT_LOGS" "$QDRANT_TMP" 2>/dev/null || true
chmod 0700 "$QDRANT_RUN" "$QDRANT_TOKENS" "$QDRANT_BENCHMARKS" 2>/dev/null || true
write_runtime_env

info "Platform:          $PLATFORM"
info "Process mode:      $PROCESS_MODE"
info "Deployment mode:   $DEPLOYMENT_MODE"
info "Resource profile:  $QDRANT_PROFILE"
info "Base directory:    $BASE_DIR"
info "CPU architecture:  $(uname -m)"
info "Available memory:  $(free -h | awk '/^Mem:/ {print $7}')"
info "Free disk:         $(df -h "$BASE_DIR" | awk 'NR==2 {print $4}')"

case "$PLATFORM" in
    google-colab) warn "Colab local storage is ephemeral. Export snapshots/backups before the runtime is reset." ;;
    kaggle) warn "Kaggle session/runtime behavior may reset processes; keep durable backups outside the live database directory." ;;
    github-codespaces) info "Codespaces detected. Minimal/rootless mode can use native port forwarding without Nginx." ;;
    codesandbox) info "CodeSandbox-like environment detected. Minimal/rootless mode is preferred unless sudo is available." ;;
esac
warn "Keep live Qdrant storage on local POSIX storage; use cloud/FUSE storage for snapshots or backup copies, not the active database."
ok "Environment is ready"
