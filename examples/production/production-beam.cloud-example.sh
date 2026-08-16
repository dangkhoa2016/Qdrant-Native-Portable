#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

: "${QDRANT_API_KEY:?export QDRANT_API_KEY first}"
: "${QDRANT_READ_ONLY_API_KEY:?export QDRANT_READ_ONLY_API_KEY first}"
[[ "$QDRANT_API_KEY" != "$QDRANT_READ_ONLY_API_KEY" ]] || {
  echo "QDRANT_API_KEY and QDRANT_READ_ONLY_API_KEY must differ" >&2
  exit 1
}

command -v beam >/dev/null 2>&1 || {
  echo "Beam CLI is required. Install beam-client and configure credentials first." >&2
  exit 1
}
command -v python3 >/dev/null 2>&1 || {
  echo "Python 3 is required for the pre-deploy source-integrity gate." >&2
  exit 1
}

echo "Checking canonical source integrity before Beam provider changes..."
python3 scripts/source-integrity.py check --root . --manifest SOURCE-MANIFEST.json --require-clean

VOLUME_NAME="${QNP_BEAM_VOLUME_NAME:-qnp-qdrant-persist}"

upsert_beam_secret() {
  local name="$1" value="$2"
  if beam secret list | grep -Eq "(^|[[:space:]])${name}([[:space:]]|$)"; then
    beam secret modify "$name" "$value"
  else
    beam secret create "$name" "$value"
  fi
}

upsert_beam_secret QDRANT_API_KEY "$QDRANT_API_KEY"
upsert_beam_secret QDRANT_READ_ONLY_API_KEY "$QDRANT_READ_ONLY_API_KEY"

if ! beam volume list | grep -Eq "(^|[[:space:]])${VOLUME_NAME}([[:space:]]|$)"; then
  beam volume create "$VOLUME_NAME"
fi

cat <<INFO
Beam snapshot-persistence staging deployment
-------------------------------------------
Live Qdrant DB:        /qdrant/storage (container-local)
Persistent snapshots: Beam Volume $VOLUME_NAME mounted at /qdrant-persist
Snapshot cadence:      600 seconds
Retention:             3 completed full snapshots
Shutdown snapshot:     disabled until Beam lifecycle ordering is real-validated
Phase A lifecycle:     keep_warm_seconds=-1; use controlled container stop after a completed snapshot
Topology:              single-node

The Beam Volume is snapshot-only. It is never mounted as live /qdrant/storage.
INFO

beam deploy deploy/beam/app.py:pod

cat <<'NEXT'

Next validation steps
---------------------
1. Copy the deployed HTTPS endpoint from Beam and export it:
     export QDRANT_URL='https://...app.beam.cloud'

2. Create a unique sentinel token and write it with the admin key:
     export QNP_SENTINEL_TOKEN="qnp-beam-$(date -u +%Y%m%dT%H%M%SZ)-$RANDOM"
     bash examples/production/beam-sentinel.sh prepare

3. Wait for a completed periodic full snapshot, then inspect Beam Volume evidence:
     beam volume list
     beam ls qnp-qdrant-persist
     beam ls qnp-qdrant-persist/full

   Do not stop the source container until a completed snapshot and checksum sidecar are visible.
   Beam documents that new Volume files can take up to 60 seconds to become visible to other containers.

4. Record the running container ID, then stop that container deliberately:
     beam container list
     beam container stop <CONTAINER-ID>

5. Request QDRANT_URL again to cause the deployed Pod to serve from a fresh container.
   Then verify the exact old sentinel using only the read-only key:
     bash examples/production/beam-sentinel.sh verify-readonly

   The verifier uses bounded polling (75s default) for provider visibility/cold-start timing.

6. Capture deployment/container IDs if available and package evidence outside the repo:
     export QNP_BEAM_DEPLOYMENT_ID='<DEPLOYMENT-ID>'   # optional but recommended
     export QNP_BEAM_CONTAINER_ID='<CONTAINER-ID>'     # optional but recommended
     export QNP_BEAM_PHASE='normal-recreation'
     bash examples/production/collect-beam-validation-result.sh

7. Only after normal recreation/restore passes, perform the documented newest-valid,
   corrupt-newest fallback, all-corrupt fail-closed, retention, and recovery tests.

Do not mark Beam real-provider validated until the real-provider evidence matrix passes.
NEXT
