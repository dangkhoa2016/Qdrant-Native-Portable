#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP_NAME="${QNP_MODAL_APP_NAME:-qnp-qdrant-single}"
VOLUME_NAME="${QNP_MODAL_VOLUME_NAME:-qnp-qdrant-persist}"
LOG_SINCE="${QNP_MODAL_LOG_SINCE:-2h}"
LOG_TAIL="${QNP_MODAL_LOG_TAIL:-3000}"
QDRANT_URL="${QDRANT_URL:?Set QDRANT_URL to the deployed Modal endpoint}"
QDRANT_READ_ONLY_API_KEY="${QDRANT_READ_ONLY_API_KEY:?Set QDRANT_READ_ONLY_API_KEY for read-only validation evidence}"
QDRANT_BASE="${QDRANT_URL%/}"
SENTINEL_COLLECTION="${QNP_SENTINEL_COLLECTION:-qnp_restore_sentinel}"
SENTINEL_POINT_ID="${QNP_SENTINEL_POINT_ID:-9182026}"
RESULT_BASE="${QNP_MODAL_RESULT_BASE:-$(dirname "$ROOT")/qnp-modal-results}"
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
RESULT_DIR="$RESULT_BASE/qnp-modal-validation-$TIMESTAMP"
RESULT_ZIP="$RESULT_BASE/qnp-modal-validation-$TIMESTAMP.zip"

command -v modal >/dev/null 2>&1 || {
  echo "Modal CLI is required" >&2
  exit 1
}
command -v zip >/dev/null 2>&1 || {
  echo "zip is required" >&2
  exit 1
}
command -v curl >/dev/null 2>&1 || {
  echo "curl is required" >&2
  exit 1
}

ROOT_REAL="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$ROOT")"
RESULT_BASE_REAL="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$RESULT_BASE")"
case "$RESULT_BASE_REAL" in
  "$ROOT_REAL"|"$ROOT_REAL"/*)
    echo "Refusing to write Modal validation results inside the source tree: $RESULT_BASE_REAL" >&2
    echo "Set QNP_MODAL_RESULT_BASE to a directory outside $ROOT_REAL" >&2
    exit 1
    ;;
esac

mkdir -p "$RESULT_DIR"

collect_nonfatal() {
  local output="$1"
  shift
  if "$@" >"$RESULT_DIR/$output" 2>&1; then
    printf 'PASS %s\n' "$output" >>"$RESULT_DIR/collection-status.txt"
  else
    local rc=$?
    printf 'FAIL rc=%s %s\n' "$rc" "$output" >>"$RESULT_DIR/collection-status.txt"
  fi
}

collect_nonfatal modal-app.log \
  modal app logs "$APP_NAME" --since "$LOG_SINCE" --tail "$LOG_TAIL" --timestamps
collect_nonfatal modal-volume-root.txt \
  modal volume ls "$VOLUME_NAME" /
collect_nonfatal modal-volume-full.txt \
  modal volume ls "$VOLUME_NAME" full

collect_nonfatal qdrant-collections.json \
  curl -fsS -H "api-key: $QDRANT_READ_ONLY_API_KEY" \
  "$QDRANT_BASE/collections"
collect_nonfatal qdrant-sentinel-collection.json \
  curl -fsS -H "api-key: $QDRANT_READ_ONLY_API_KEY" \
  "$QDRANT_BASE/collections/$SENTINEL_COLLECTION"
collect_nonfatal qdrant-sentinel-point.json \
  curl -fsS -H "api-key: $QDRANT_READ_ONLY_API_KEY" \
  "$QDRANT_BASE/collections/$SENTINEL_COLLECTION/points/$SENTINEL_POINT_ID?with_payload=true&with_vector=false"

python3 "$ROOT/scripts/source-integrity.py" check \
  --root "$ROOT" \
  --json-output "$RESULT_DIR/source-integrity.json" \
  >"$RESULT_DIR/source-integrity.stdout.txt" 2>"$RESULT_DIR/source-integrity.stderr.txt" || true

cat >"$RESULT_DIR/metadata.txt" <<META
collected_utc=$TIMESTAMP
app_name=$APP_NAME
volume_name=$VOLUME_NAME
log_since=$LOG_SINCE
log_tail=$LOG_TAIL
qdrant_url=$QDRANT_BASE
sentinel_collection=$SENTINEL_COLLECTION
sentinel_point_id=$SENTINEL_POINT_ID
source_root=$ROOT_REAL
result_base=$RESULT_BASE_REAL
META

# Result packages must never persist API-key values if they are present in the
# collector environment. The variable names themselves are harmless; exact
# secret-value matches abort packaging.
for secret_name in QDRANT_API_KEY QDRANT_READ_ONLY_API_KEY; do
  secret_value="${!secret_name:-}"
  if [[ -n "$secret_value" ]] && grep -RIlF -- "$secret_value" "$RESULT_DIR" >/dev/null 2>&1; then
    echo "Refusing to package result: collected files contain $secret_name value" >&2
    exit 1
  fi
done

(
  cd "$RESULT_BASE"
  zip -qr "$(basename "$RESULT_ZIP")" "$(basename "$RESULT_DIR")"
)
sha256sum "$RESULT_ZIP" >"$RESULT_ZIP.sha256"

printf 'RESULT_DIR=%s\n' "$RESULT_DIR"
printf 'RESULT_ZIP=%s\n' "$RESULT_ZIP"
printf 'RESULT_SHA256=%s\n' "$RESULT_ZIP.sha256"
