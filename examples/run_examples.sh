#!/usr/bin/env bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$PROJECT_DIR/scripts/common.sh"
cd "$PROJECT_DIR"

require_secrets
export QDRANT_URL="${QDRANT_URL:-$(local_api_url)}"
export QDRANT_API_KEY QDRANT_READ_ONLY_API_KEY

header "Run examples"
info "Endpoint: $QDRANT_URL"

bash examples/curl/basic.sh

if command -v python3 >/dev/null 2>&1; then
    python3 examples/python/rest_client.py
    if python3 -c 'import qdrant_client' >/dev/null 2>&1; then
        python3 examples/python/sdk_client.py
    else
        warn "Skipping Python SDK example: install with 'pip install -r examples/python/requirements.txt'"
    fi
else
    warn "Skipping Python examples: python3 not found"
fi

if command -v node >/dev/null 2>&1 && [[ -d examples/node/node_modules/@qdrant ]]; then
    node examples/node/client.js
else
    warn "Skipping Node.js example: run 'cd examples/node && npm install' first"
fi

if command -v ruby >/dev/null 2>&1; then
    ruby examples/ruby/client.rb
else
    warn "Skipping Ruby example: ruby not found"
fi
