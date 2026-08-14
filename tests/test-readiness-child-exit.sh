#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENTRYPOINT="$ROOT/docker/entrypoint.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/fake-qdrant" <<'SH'
#!/usr/bin/env bash
sleep 0.2
exit 42
SH
chmod +x "$TMP/fake-qdrant"

cat > "$TMP/healthcheck" <<'SH'
#!/usr/bin/env bash
exit 1
SH
chmod +x "$TMP/healthcheck"

mkdir -p "$TMP/persist" "$TMP/storage" "$TMP/snapshots"
start="$(date +%s)"
set +e
QDRANT_API_KEY=admin-test-key \
QDRANT_READ_ONLY_API_KEY=readonly-test-key \
QNP_STORAGE_MODE=snapshot-persist \
QNP_PERSIST_PATH="$TMP/persist" \
QNP_REQUIRE_PERSIST_MOUNT=0 \
QNP_AUTO_RESTORE=0 \
QNP_AUTO_SNAPSHOT_INTERVAL_SECONDS=0 \
QNP_AUTO_SNAPSHOT_ON_SHUTDOWN=0 \
QNP_READY_TIMEOUT_SECONDS=4 \
QDRANT_STORAGE_PATH="$TMP/storage" \
QDRANT_SNAPSHOTS_PATH="$TMP/snapshots" \
QNP_QDRANT_BIN="$TMP/fake-qdrant" \
QNP_HEALTHCHECK_BIN="$TMP/healthcheck" \
QNP_PERSISTENCE_LIB="$ROOT/docker/persistence.sh" \
bash "$ENTRYPOINT" >"$TMP/out.log" 2>&1
rc=$?
set -e
elapsed=$(( $(date +%s) - start ))

if (( elapsed >= 3 )); then
    echo "FAIL: entrypoint waited ${elapsed}s after Qdrant had already exited" >&2
    cat "$TMP/out.log" >&2
    exit 1
fi
if [[ "$rc" -ne 42 ]]; then
    echo "FAIL: expected Qdrant exit code 42, got $rc" >&2
    cat "$TMP/out.log" >&2
    exit 1
fi
if ! grep -q 'Qdrant exited before readiness' "$TMP/out.log"; then
    echo "FAIL: missing early-child-exit diagnostic" >&2
    cat "$TMP/out.log" >&2
    exit 1
fi

echo "PASS: child exit is detected before readiness timeout"
