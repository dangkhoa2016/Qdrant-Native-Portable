#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
VOLUME_NAME="${QNP_BEAM_VOLUME_NAME:-qnp-qdrant-persist}"
QDRANT_URL="${QDRANT_URL:?Set QDRANT_URL to the deployed Beam endpoint}"
QDRANT_API_KEY="${QDRANT_API_KEY:?Set QDRANT_API_KEY for admin authorization evidence}"
QDRANT_READ_ONLY_API_KEY="${QDRANT_READ_ONLY_API_KEY:?Set QDRANT_READ_ONLY_API_KEY for read-only validation evidence}"
QDRANT_BASE="${QDRANT_URL%/}"
SENTINEL_COLLECTION="${QNP_SENTINEL_COLLECTION:-qnp_beam_sentinel}"
SENTINEL_POINT_ID="${QNP_SENTINEL_POINT_ID:-9182026}"
DEPLOYMENT_ID="${QNP_BEAM_DEPLOYMENT_ID:-}"
CONTAINER_ID="${QNP_BEAM_CONTAINER_ID:-}"
PHASE="${QNP_BEAM_PHASE:-unspecified}"
LOG_CAPTURE_SECONDS="${QNP_BEAM_LOG_CAPTURE_SECONDS:-20}"
RESULT_BASE="${QNP_BEAM_RESULT_BASE:-$(dirname "$ROOT")/qnp-beam-results}"
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
RESULT_DIR="$RESULT_BASE/qnp-beam-validation-$TIMESTAMP"
RESULT_ZIP="$RESULT_BASE/qnp-beam-validation-$TIMESTAMP.zip"

command -v beam >/dev/null 2>&1 || { echo "Beam CLI is required" >&2; exit 1; }
command -v zip >/dev/null 2>&1 || { echo "zip is required" >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "curl is required" >&2; exit 1; }
# shellcheck disable=SC2015
[[ "$LOG_CAPTURE_SECONDS" =~ ^[0-9]+$ ]] && (( LOG_CAPTURE_SECONDS >= 1 )) || {
  echo "QNP_BEAM_LOG_CAPTURE_SECONDS must be a positive integer" >&2
  exit 1
}

ROOT_REAL="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$ROOT")"
RESULT_BASE_REAL="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$RESULT_BASE")"
case "$RESULT_BASE_REAL" in
  "$ROOT_REAL"|"$ROOT_REAL"/*)
    echo "Refusing to write Beam validation results inside the source tree: $RESULT_BASE_REAL" >&2
    echo "Set QNP_BEAM_RESULT_BASE to a directory outside $ROOT_REAL" >&2
    exit 1
    ;;
esac

mkdir -p "$RESULT_DIR"
: >"$RESULT_DIR/collection-status.txt"

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

collect_stream_nonfatal() {
  local output="$1"
  shift
  if command -v timeout >/dev/null 2>&1; then
    set +e
    timeout "${LOG_CAPTURE_SECONDS}s" "$@" >"$RESULT_DIR/$output" 2>&1
    local rc=$?
    set -e
    if [[ $rc -eq 0 || $rc -eq 124 ]]; then
      printf 'PASS rc=%s %s\n' "$rc" "$output" >>"$RESULT_DIR/collection-status.txt"
    else
      printf 'FAIL rc=%s %s\n' "$rc" "$output" >>"$RESULT_DIR/collection-status.txt"
    fi
  else
    printf 'SKIP timeout-command-unavailable %s\n' "$output" >>"$RESULT_DIR/collection-status.txt"
  fi
}

collect_nonfatal beam-deployments.txt beam deployment list
collect_nonfatal beam-containers.txt beam container list
collect_nonfatal beam-volume-list.txt beam volume list
collect_nonfatal beam-volume-root.txt beam ls "$VOLUME_NAME"
collect_nonfatal beam-volume-full.txt beam ls "$VOLUME_NAME/full"

if [[ -n "$DEPLOYMENT_ID" ]]; then
  collect_stream_nonfatal beam-deployment.log beam logs --deployment-id "$DEPLOYMENT_ID"
else
  printf 'SKIP QNP_BEAM_DEPLOYMENT_ID-not-set beam-deployment.log\n' >>"$RESULT_DIR/collection-status.txt"
fi
if [[ -n "$CONTAINER_ID" ]]; then
  collect_stream_nonfatal beam-container.log beam logs --container-id "$CONTAINER_ID"
else
  printf 'SKIP QNP_BEAM_CONTAINER_ID-not-set beam-container.log\n' >>"$RESULT_DIR/collection-status.txt"
fi

http_status() {
  local output="$1"
  shift
  local status
  set +e
  status="$(curl -sS -o "$RESULT_DIR/${output%.txt}.body.json" -w '%{http_code}' "$@")"
  local rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    printf 'curl_error_rc=%s\n' "$rc" >"$RESULT_DIR/$output"
    return 0
  fi
  printf '%s\n' "$status" >"$RESULT_DIR/$output"
}

# qdrant-auth-status.txt summarizes 401/200/200/403 evidence.
unauth_status_file="qdrant-auth-unauthenticated.txt"
admin_status_file="qdrant-auth-admin-read.txt"
readonly_status_file="qdrant-auth-readonly-read.txt"
readonly_write_status_file="qdrant-auth-readonly-write.txt"
http_status "$unauth_status_file" "$QDRANT_BASE/collections"
http_status "$admin_status_file" -H "api-key: $QDRANT_API_KEY" "$QDRANT_BASE/collections"
http_status "$readonly_status_file" -H "api-key: $QDRANT_READ_ONLY_API_KEY" "$QDRANT_BASE/collections"
http_status "$readonly_write_status_file" \
  -X POST \
  -H "api-key: $QDRANT_READ_ONLY_API_KEY" \
  -H 'content-type: application/json' \
  "$QDRANT_BASE/collections/$SENTINEL_COLLECTION/points/delete?wait=true" \
  --data '{"filter":{"must":[{"key":"__qnp_beam_auth_probe__","match":{"value":"__never_match__"}}]}}'
{
  printf 'unauthenticated='; cat "$RESULT_DIR/$unauth_status_file"
  printf 'admin_read='; cat "$RESULT_DIR/$admin_status_file"
  printf 'readonly_read='; cat "$RESULT_DIR/$readonly_status_file"
  printf 'readonly_write='; cat "$RESULT_DIR/$readonly_write_status_file"
} >"$RESULT_DIR/qdrant-auth-status.txt"

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
phase=$PHASE
volume_name=$VOLUME_NAME
deployment_id=${DEPLOYMENT_ID:-not-set}
container_id=${CONTAINER_ID:-not-set}
qdrant_url=$QDRANT_BASE
sentinel_collection=$SENTINEL_COLLECTION
sentinel_point_id=$SENTINEL_POINT_ID
source_root=$ROOT_REAL
result_base=$RESULT_BASE_REAL
beam_volume_cross_container_visibility_documented_max_seconds=60
META

# Result packages must never persist exact current Qdrant API-key values.
# Variable names are harmless; exact secret matches fail closed before ZIP creation.
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
