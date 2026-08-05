#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENTRYPOINT="$ROOT/docker/entrypoint.sh"
DOCKERFILES=("$ROOT/Dockerfile" "$ROOT/docker/Dockerfile")
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/fake-qdrant" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "${QDRANT__STORAGE__TEMP_PATH+x}" > "${QNP_TEST_CAPTURE:?}/temp-env-present"
printf '%s\n' "${QDRANT__STORAGE__TEMP_PATH-}" > "${QNP_TEST_CAPTURE:?}/temp-env-value"
exit 0
SH
chmod +x "$TMP/fake-qdrant"

cat > "$TMP/healthcheck" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$TMP/healthcheck"

mkdir -p "$TMP/persist" "$TMP/storage" "$TMP/snapshots"

QDRANT_API_KEY=admin-test-key \
QDRANT_READ_ONLY_API_KEY=readonly-test-key \
QNP_STORAGE_MODE=snapshot-persist \
QNP_PERSIST_PATH="$TMP/persist" \
QNP_REQUIRE_PERSIST_MOUNT=0 \
QNP_AUTO_RESTORE=0 \
QNP_AUTO_SNAPSHOT_INTERVAL_SECONDS=0 \
QNP_AUTO_SNAPSHOT_ON_SHUTDOWN=0 \
QDRANT_STORAGE_PATH="$TMP/storage" \
QDRANT_SNAPSHOTS_PATH="$TMP/snapshots" \
QDRANT__STORAGE__TEMP_PATH=/qdrant/snapshots/.tmp \
QNP_QDRANT_BIN="$TMP/fake-qdrant" \
QNP_HEALTHCHECK_BIN="$TMP/healthcheck" \
QNP_PERSISTENCE_LIB="$ROOT/docker/persistence.sh" \
QNP_TEST_CAPTURE="$TMP" \
bash "$ENTRYPOINT"

if [[ "$(cat "$TMP/temp-env-present")" != "" ]]; then
    echo "FAIL: snapshot-persist leaked QDRANT__STORAGE__TEMP_PATH into Qdrant" >&2
    echo "value=$(cat "$TMP/temp-env-value")" >&2
    exit 1
fi

for dockerfile in "${DOCKERFILES[@]}"; do
    if grep -q 'QDRANT__STORAGE__TEMP_PATH=' "$dockerfile"; then
        echo "FAIL: ${dockerfile#"$ROOT"/} still forces QDRANT__STORAGE__TEMP_PATH" >&2
        exit 1
    fi
done

echo "PASS: snapshot-persist leaves Qdrant temp_path unmanaged"
