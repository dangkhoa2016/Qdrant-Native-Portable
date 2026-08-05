#!/usr/bin/env bash
# Source this file to load the active runtime into the current shell.
# Usage: source scripts/activate.sh
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    echo "This helper must be sourced so it can export variables into your current shell:" >&2
    echo "  source scripts/activate.sh" >&2
    exit 1
fi

# shellcheck source=scripts/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
load_secrets
if [[ -z "${QDRANT_API_KEY:-}" || -z "${QDRANT_READ_ONLY_API_KEY:-}" ]]; then
    echo "Qdrant credentials are not initialized. Run: bash qdrant.sh setup" >&2
    return 1
fi

export BASE_DIR
QDRANT_URL="$(local_api_url)"
export QDRANT_URL
export QDRANT_API_KEY QDRANT_READ_ONLY_API_KEY
export QDRANT_COLLECTION="${QDRANT_COLLECTION:-$DEMO_COLLECTION}"

printf 'Qdrant runtime activated\n'
printf '  BASE_DIR=%s\n' "$BASE_DIR"
printf '  QDRANT_URL=%s\n' "$QDRANT_URL"
printf '  QDRANT_COLLECTION=%s\n' "$QDRANT_COLLECTION"
printf '  API keys loaded: yes (values hidden)\n'
