#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname "$0")/common.sh"
require_secrets

reveal=0
case "${1:-}" in
    "") ;;
    --reveal) reveal=1 ;;
    -h|--help)
        echo "Usage: bash scripts/show_credentials.sh [--reveal]"
        exit 0
        ;;
    *) fail "Unknown option: $1" ;;
esac

if (( reveal )); then
    warn "Displaying full credentials. Do not paste this output into public logs, issues, notebooks, or screenshots."
    printf 'Admin API key:     %s\n' "$QDRANT_API_KEY"
    printf 'Read-only API key: %s\n' "$QDRANT_READ_ONLY_API_KEY"
    [[ -n "${QDRANT_ALT_API_KEY:-}" ]] && printf 'Alternate admin:   %s\n' "$QDRANT_ALT_API_KEY"
else
    printf 'Admin API key:     %s\n' "$(mask "$QDRANT_API_KEY")"
    printf 'Read-only API key: %s\n' "$(mask "$QDRANT_READ_ONLY_API_KEY")"
    [[ -n "${QDRANT_ALT_API_KEY:-}" ]] && printf 'Alternate admin:   %s\n' "$(mask "$QDRANT_ALT_API_KEY")"
fi
printf 'Secrets file:      %s\n' "$SECRETS_FILE"
