#!/usr/bin/env bash
set -euo pipefail

command="${1:-}"
collection="${QNP_SENTINEL_COLLECTION:-qnp_beam_sentinel}"
point_id="${QNP_SENTINEL_POINT_ID:-9182026}"

usage() {
  cat <<'USAGE'
Usage:
  QDRANT_URL=... QDRANT_API_KEY=... QNP_SENTINEL_TOKEN=... \
    bash examples/production/beam-sentinel.sh prepare

  QDRANT_URL=... QDRANT_READ_ONLY_API_KEY=... QNP_SENTINEL_TOKEN=... \
    bash examples/production/beam-sentinel.sh verify-readonly
USAGE
}

prepare() {
  : "${QDRANT_URL:?Set QDRANT_URL to the deployed Beam Qdrant endpoint}"
  : "${QDRANT_API_KEY:?Set QDRANT_API_KEY for the pre-recreation sentinel write}"
  : "${QNP_SENTINEL_TOKEN:?Set a unique QNP_SENTINEL_TOKEN and keep it for verification}"

  local base tmp status payload
  base="${QDRANT_URL%/}"
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  status="$(curl -sS -o "$tmp/collection.json" -w '%{http_code}' \
    -H "api-key: $QDRANT_API_KEY" \
    "$base/collections/$collection")"

  if [[ "$status" == "404" ]]; then
    curl -fsS -X PUT \
      -H "api-key: $QDRANT_API_KEY" \
      -H 'content-type: application/json' \
      "$base/collections/$collection" \
      --data '{"vectors":{"size":1,"distance":"Cosine"}}' >"$tmp/create.json"
  elif [[ "$status" != "200" ]]; then
    printf 'ERROR: sentinel collection probe returned HTTP %s\n' "$status" >&2
    cat "$tmp/collection.json" >&2 || true
    return 1
  fi

  payload="$(python3 - "$point_id" "$QNP_SENTINEL_TOKEN" <<'PY'
import json
import sys
point_id = int(sys.argv[1])
token = sys.argv[2]
print(json.dumps({
    "points": [{
        "id": point_id,
        "vector": [1.0],
        "payload": {"qnp_beam_sentinel": token},
    }]
}))
PY
)"

  curl -fsS -X PUT \
    -H "api-key: $QDRANT_API_KEY" \
    -H 'content-type: application/json' \
    "$base/collections/$collection/points?wait=true" \
    --data "$payload" >"$tmp/upsert.json"

  curl -fsS \
    -H "api-key: $QDRANT_API_KEY" \
    "$base/collections/$collection/points/$point_id?with_payload=true&with_vector=false" \
    >"$tmp/point.json"

  python3 - "$tmp/point.json" "$QNP_SENTINEL_TOKEN" "$collection" "$point_id" <<'PY'
import json
import sys
path, expected, collection, point_id = sys.argv[1:]
with open(path, "r", encoding="utf-8") as f:
    doc = json.load(f)
payload = (doc.get("result") or {}).get("payload") or {}
actual = payload.get("qnp_beam_sentinel")
if actual != expected:
    print(
        f"FAIL: sentinel write verification mismatch for {collection}/{point_id}: "
        f"expected={expected!r} actual={actual!r}",
        file=sys.stderr,
    )
    raise SystemExit(1)
print(f"PASS: Beam sentinel written and verified: collection={collection} point_id={point_id}")
PY

  printf 'collection=%s\npoint_id=%s\ntoken=%s\n' "$collection" "$point_id" "$QNP_SENTINEL_TOKEN"
}

verify_readonly() {
  : "${QDRANT_URL:?Set QDRANT_URL to the deployed Beam Qdrant endpoint}"
  : "${QDRANT_READ_ONLY_API_KEY:?Set QDRANT_READ_ONLY_API_KEY for post-recreation verification}"
  : "${QNP_SENTINEL_TOKEN:?Set the same QNP_SENTINEL_TOKEN used before recreation}"

  local base tmp timeout_seconds poll_seconds deadline status
  base="${QDRANT_URL%/}"
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  timeout_seconds="${QNP_BEAM_VOLUME_VISIBILITY_TIMEOUT_SECONDS:-75}"
  poll_seconds="${QNP_BEAM_VOLUME_VISIBILITY_POLL_SECONDS:-5}"
  # shellcheck disable=SC2015
  [[ "$timeout_seconds" =~ ^[0-9]+$ ]] && (( timeout_seconds >= 1 )) || {
    echo "QNP_BEAM_VOLUME_VISIBILITY_TIMEOUT_SECONDS must be a positive integer" >&2
    return 1
  }
  # shellcheck disable=SC2015
  [[ "$poll_seconds" =~ ^[0-9]+$ ]] && (( poll_seconds >= 1 )) || {
    echo "QNP_BEAM_VOLUME_VISIBILITY_POLL_SECONDS must be a positive integer" >&2
    return 1
  }

  deadline=$((SECONDS + timeout_seconds))
  while :; do
    status="$(curl -sS -o "$tmp/collection.json" -w '%{http_code}' \
      -H "api-key: $QDRANT_READ_ONLY_API_KEY" \
      "$base/collections/$collection" || true)"
    if [[ "$status" == "200" ]]; then
      status="$(curl -sS -o "$tmp/point.json" -w '%{http_code}' \
        -H "api-key: $QDRANT_READ_ONLY_API_KEY" \
        "$base/collections/$collection/points/$point_id?with_payload=true&with_vector=false" || true)"
      if [[ "$status" == "200" ]] && python3 - "$tmp/point.json" "$QNP_SENTINEL_TOKEN" <<'PY'
import json
import sys
path, expected = sys.argv[1:]
try:
    with open(path, "r", encoding="utf-8") as f:
        doc = json.load(f)
except Exception:
    raise SystemExit(1)
payload = (doc.get("result") or {}).get("payload") or {}
raise SystemExit(0 if payload.get("qnp_beam_sentinel") == expected else 1)
PY
      then
        printf 'PASS: Beam restored sentinel survived recreation: collection=%s point_id=%s\n' "$collection" "$point_id"
        return 0
      fi
    fi

    if (( SECONDS >= deadline )); then
      printf 'FAIL: Beam sentinel not visible within %ss: collection=%s point_id=%s last_http=%s\n' \
        "$timeout_seconds" "$collection" "$point_id" "${status:-curl-error}" >&2
      # shellcheck disable=SC2015
      [[ -f "$tmp/point.json" ]] && cat "$tmp/point.json" >&2 || true
      return 1
    fi
    sleep "$poll_seconds"
  done
}

case "$command" in
  prepare)
    prepare
    ;;
  verify-readonly)
    verify_readonly
    ;;
  -h|--help|help|"")
    usage
    [[ -n "$command" ]] || exit 2
    ;;
  *)
    printf 'Unknown command: %s\n' "$command" >&2
    usage >&2
    exit 2
    ;;
esac
