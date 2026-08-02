#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname "$0")/common.sh"

header "Step 3: Download Qdrant binary"
require curl tar
ensure_runtime_dirs
mkdir -p "$QDRANT_HOME"

if [[ -x "$QDRANT_BIN" ]]; then
    info "Qdrant $QDRANT_VERSION is already installed"
    "$QDRANT_BIN" --version 2>/dev/null || true
    exit 0
fi

archive="$QDRANT_DOWNLOADS/$QDRANT_ARCHIVE"
info "Downloading Qdrant v$QDRANT_VERSION for $QDRANT_TARGET"
download_with_retry "$QDRANT_URL" "$archive" 3 || fail "Could not download $QDRANT_URL"
verify_sha256_if_provided "$archive" "${QDRANT_SHA256:-}"

tar -xzf "$archive" -C "$QDRANT_HOME"
rm -f "$archive"
if [[ ! -f "$QDRANT_BIN" ]]; then
    found="$(find "$QDRANT_HOME" -type f -name qdrant -print -quit)"
    [[ -n "$found" ]] || fail "The archive did not contain a qdrant binary"
    mv "$found" "$QDRANT_BIN"
fi
chmod 0755 "$QDRANT_BIN"
if [[ "$PROCESS_MODE" == "service-user" ]]; then chown -R root:root "$QDRANT_HOME"; fi

ok "Installed: $QDRANT_BIN"
"$QDRANT_BIN" --version 2>/dev/null || true
[[ -n "${QDRANT_SHA256:-}" ]] || muted "Tip: set QDRANT_SHA256 to enforce checksum verification for reproducible releases."
