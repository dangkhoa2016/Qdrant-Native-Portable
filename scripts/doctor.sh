#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname "$0")/common.sh"

header "Qdrant doctor"
issues=0; warnings=0
pass() { ok "$*"; }
warning() { warn "$*"; warnings=$((warnings + 1)); }
issue() { warn "$*"; issues=$((issues + 1)); }

# shellcheck disable=SC2015
[[ "$(uname -s)" == "Linux" ]] && pass "Linux host" || issue "This project targets Linux"
case "$(uname -m)" in x86_64|amd64|aarch64|arm64) pass "Supported architecture: $(uname -m)" ;; *) issue "Unsupported architecture: $(uname -m)" ;; esac

host_mem="$(total_memory_mb)"
mem="$(effective_memory_mb)"
mem_source="$(effective_memory_source)"
if (( mem >= 3500 )); then
  pass "Effective RAM: ${mem} MB (${mem_source}; host ${host_mem} MB)"
elif (( mem >= 1800 )); then
  warning "Effective RAM is only ${mem} MB (${mem_source}); use QDRANT_PROFILE=low-memory"
else
  issue "effective RAM is below the recommended demo minimum (~2 GB): ${mem} MB (${mem_source}; host ${host_mem} MB)"
fi

ensure_runtime_dirs
# shellcheck disable=SC2015
[[ -w "$BASE_DIR" ]] && pass "Base directory is writable: $BASE_DIR" || issue "Base directory is not writable: $BASE_DIR"
free_kb="$(df -Pk "$BASE_DIR" | awk 'NR==2 {print $4}')"
if (( free_kb >= 4*1024*1024 )); then pass "At least 4 GB disk is free"; else warning "Less than 4 GB disk is free"; fi

# shellcheck disable=SC2015
for cmd in curl jq openssl tar; do command -v "$cmd" >/dev/null 2>&1 && pass "Dependency: $cmd" || issue "Missing dependency: $cmd"; done
# shellcheck disable=SC2015
if [[ "$DEPLOYMENT_MODE" == "proxy" ]]; then command -v nginx >/dev/null 2>&1 && pass "Nginx available" || issue "Proxy mode requires Nginx"; [[ "$(id -u)" -eq 0 ]] && pass "Root privileges available for proxy mode" || issue "Proxy mode currently requires root; switch to DEPLOYMENT_MODE=minimal"; fi
# shellcheck disable=SC2015
if [[ "$PROCESS_MODE" == "service-user" ]]; then [[ "$(id -u)" -eq 0 ]] && pass "Root privileges available for service-user mode" || issue "service-user mode requires root"; fi

if [[ -f "$SECRETS_FILE" ]]; then
    mode="$(stat -c '%a' "$SECRETS_FILE" 2>/dev/null || echo unknown)"
    # shellcheck disable=SC2015
    [[ "$mode" == "600" ]] && pass "Secrets file mode 600" || issue "Secrets file mode is $mode; expected 600"
else warning "Credentials have not been generated yet"; fi

if [[ -f "$QDRANT_CONFIG" ]]; then
    # shellcheck disable=SC2015
    grep -Eiq '^\s*(api_key|read_only_api_key|alt_api_key)\s*:' "$QDRANT_CONFIG" && issue "Plaintext API key field found in qdrant.yaml" || pass "qdrant.yaml contains no API key fields"
else warning "Qdrant config has not been generated yet"; fi

# shellcheck disable=SC2015
[[ -x "$QDRANT_BIN" ]] && pass "Qdrant binary installed: $QDRANT_BIN" || warning "Qdrant binary not installed yet"
# shellcheck disable=SC2015
if pid_is_running "$QDRANT_PID_FILE"; then qdrant_ready && pass "Qdrant REST API is healthy" || issue "Qdrant process exists but health check fails"; else warning "Qdrant is not running"; fi
# shellcheck disable=SC2015
if [[ "$DEPLOYMENT_MODE" == "proxy" ]]; then proxy_ready && pass "Nginx proxy is healthy" || warning "Nginx proxy is not healthy"; fi

printf '\n'
if (( issues )); then fail "Doctor found $issues issue(s) and $warnings warning(s)"; fi
ok "Doctor found no blocking issues ($warnings warning(s))"
