#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname "$0")/common.sh"
require curl jq sha256sum
require_secrets

usage() {
    cat <<'EOF_USAGE'
Usage:
  bash scripts/backup-manager.sh full [DEST_DIR]
  bash scripts/backup-manager.sh collection COLLECTION [DEST_DIR]

DEST_DIR defaults to BACKUP_DIR when set, otherwise:
  $BASE_DIR/recovery-backups/exported

Each backup includes the snapshot, .sha256 checksum, and a JSON manifest.
EOF_USAGE
    exit "${1:-1}"
}

qdrant_ready || fail "Qdrant must be running"
kind="${1:-}"; name="${2:-}"; default_dest="${BACKUP_DIR:-$QDRANT_BACKUPS/exported}"
case "$kind" in
    full) dest="${2:-$default_dest}" ;;
    collection) [[ -n "$name" ]] || usage; dest="${3:-$default_dest}" ;;
    -h|--help|"") usage 0 ;;
    *) usage ;;
esac
mkdir -p "$dest"; chmod 0700 "$dest" 2>/dev/null || true
base="http://127.0.0.1:${QDRANT_HTTP_PORT}"

if [[ "$kind" == "full" ]]; then
    response="$(api_curl -X POST "$base/snapshots")"
    snapshot="$(jq -r '.result.name // empty' <<<"$response")"
    [[ -n "$snapshot" ]] || fail "Qdrant did not return a snapshot name"
    file="$dest/$snapshot"
    api_curl "$base/snapshots/$snapshot" -o "$file"
    collection=""
else
    response="$(api_curl -X POST "$base/collections/$name/snapshots")"
    snapshot="$(jq -r '.result.name // empty' <<<"$response")"
    [[ -n "$snapshot" ]] || fail "Qdrant did not return a snapshot name"
    file="$dest/${name}--${snapshot}"
    api_curl "$base/collections/$name/snapshots/$snapshot" -o "$file"
    collection="$name"
fi
chmod 0600 "$file"
(cd "$dest" && sha256sum "$(basename "$file")" > "$(basename "$file").sha256")
manifest="$file.manifest.json"
qversion="$(api_curl "$base/" | jq -r '.version // "unknown"')"
jq -n --arg created "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg kind "$kind" --arg collection "$collection" --arg snapshot "$snapshot" --arg qdrant_version "$qversion" --arg profile "$QDRANT_PROFILE" --arg platform "$PLATFORM" '{created_at:$created,kind:$kind,collection:$collection,snapshot:$snapshot,qdrant_version:$qdrant_version,profile:$profile,platform:$platform}' > "$manifest"
chmod 0600 "$manifest"
ok "Backup created: $file"
ok "Checksum:       $file.sha256"
ok "Manifest:       $manifest"
