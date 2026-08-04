#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname "$0")/common.sh"
cd "$PROJECT_DIR"

header "Repository/runtime security check"
issues=0

if [[ -f "$SECRETS_FILE" ]]; then
    mode="$(stat -c '%a' "$SECRETS_FILE" 2>/dev/null || echo unknown)"
    if [[ "$mode" == "600" ]]; then
        ok "Secrets file permissions: 600"
    else
        warn "Secrets file permissions are $mode; expected 600"
        issues=$((issues + 1))
    fi
else
    muted "No runtime secrets file yet"
fi

if [[ -f "$QDRANT_CONFIG" ]]; then
    if grep -Eiq '^\s*(api_key|read_only_api_key|alt_api_key)\s*:' "$QDRANT_CONFIG"; then
        warn "A plaintext API key field appears in qdrant.yaml"
        issues=$((issues + 1))
    else
        ok "qdrant.yaml contains no API key fields"
    fi
fi

if grep -RIE --exclude-dir=.git --exclude='*.md' --exclude='security-check.sh' \
    'https://[-a-z0-9]+\.trycloudflare\.com' "$PROJECT_DIR" >/dev/null 2>&1; then
    warn "A concrete trycloudflare.com URL appears in source files"
    issues=$((issues + 1))
else
    ok "No hard-coded Quick Tunnel URL found in source files"
fi

if grep -RIE --exclude-dir=.git --exclude='security-check.sh' \
    "(QDRANT_API_KEY|apiKey|api-key)[^[:space:]]{0,80}[=:][[:space:]]*['\"]?[a-f0-9]{48,}" "$PROJECT_DIR" >/dev/null 2>&1; then
    warn "A value resembling a hard-coded long API key was found"
    issues=$((issues + 1))
else
    ok "No obvious hard-coded long API key found"
fi

if (( issues > 0 )); then
    fail "Security check found $issues issue(s)"
fi
ok "Security check passed"
