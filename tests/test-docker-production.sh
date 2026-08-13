#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail_test() { echo "docker production test failed: $*" >&2; exit 1; }

[[ -f "$ROOT/docker/Dockerfile" ]] || fail_test "missing Dockerfile"
[[ -f "$ROOT/docker/entrypoint.sh" ]] || fail_test "missing entrypoint"
[[ -f "$ROOT/docker/healthcheck.sh" ]] || fail_test "missing healthcheck"
[[ -f "$ROOT/docker/persistence.sh" ]] || fail_test "missing persistence helper"
[[ -f "$ROOT/docker/docker-compose.yml" ]] || fail_test "missing compose file"
[[ -f "$ROOT/.dockerignore" ]] || fail_test "missing root .dockerignore for project-root build context"

grep -q '^FROM qdrant/qdrant:v1.18.3-unprivileged' "$ROOT/docker/Dockerfile" || fail_test "Docker image must use the official v1.18.3-unprivileged tag"
grep -q '^USER 1000:1000' "$ROOT/docker/Dockerfile" || fail_test "Docker runtime must use uid 1000"
grep -q '^CMD \[\]' "$ROOT/docker/Dockerfile" || fail_test "derived image must reset the base image CMD so it is not passed to the custom entrypoint"
grep -q 'QDRANT_API_KEY' "$ROOT/docker/entrypoint.sh" || fail_test "entrypoint does not require admin key"
grep -q 'QDRANT_READ_ONLY_API_KEY' "$ROOT/docker/entrypoint.sh" || fail_test "entrypoint does not require read-only key"
grep -q 'QDRANT__CLUSTER__ENABLED=false' "$ROOT/docker/entrypoint.sh" || fail_test "entrypoint does not force single-node"
grep -q 'snapshot-persist' "$ROOT/docker/entrypoint.sh" || fail_test "entrypoint does not support snapshot-persist"
grep -q 'direct-mount-experimental' "$ROOT/docker/entrypoint.sh" || fail_test "entrypoint does not expose experimental direct storage mode"
grep -q 'qnp-persistence.sh' "$ROOT/docker/Dockerfile" || fail_test "Docker image does not copy persistence helper"
# shellcheck disable=SC2016
grep -q 'exec "\$QNP_QDRANT_BIN"' "$ROOT/docker/entrypoint.sh" || fail_test "entrypoint does not exec configured Qdrant binary"
grep -q '/readyz' "$ROOT/docker/healthcheck.sh" || fail_test "healthcheck must use the readiness endpoint"
if grep -q 'QDRANT_API_KEY' "$ROOT/docker/healthcheck.sh"; then
  fail_test "healthcheck must not put the API key in process arguments"
fi
grep -q 'qdrant-data:/qdrant/storage' "$ROOT/docker/docker-compose.yml" || fail_test "compose must use a named volume at /qdrant/storage"
grep -q 'qdrant-snapshots:/qdrant/snapshots' "$ROOT/docker/docker-compose.yml" || fail_test "compose must use a separate named volume at /qdrant/snapshots"
grep -q 'QNP_STORAGE_MODE:' "$ROOT/docker/docker-compose.yml" || fail_test "compose does not pass QNP_STORAGE_MODE"
grep -q 'QNP_AUTO_RESTORE:' "$ROOT/docker/docker-compose.yml" || fail_test "compose does not pass snapshot persistence policy"
grep -Eq 'read_only:[[:space:]]*true' "$ROOT/docker/docker-compose.yml" || fail_test "compose should harden Qdrant with a read-only root filesystem"
grep -q 'cap_drop:' "$ROOT/docker/docker-compose.yml" || fail_test "compose should drop Linux capabilities"

# shellcheck disable=SC2016
if grep -RIE 'QDRANT_(API_KEY|READ_ONLY_API_KEY)=.{8,}' "$ROOT/docker" | grep -v '\${' >/dev/null 2>&1; then
  fail_test "docker tree appears to hard-code a secret"
fi

echo "docker production tests passed"
