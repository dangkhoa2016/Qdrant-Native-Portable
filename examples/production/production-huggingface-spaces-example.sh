#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TARGET="${1:?usage: $0 /path/to/space-staging-dir}"
mkdir -p "$TARGET/docker"
cp "$ROOT/docker/Dockerfile" "$TARGET/Dockerfile"
cp "$ROOT/.dockerignore" "$TARGET/.dockerignore"
cp "$ROOT/docker/entrypoint.sh" "$ROOT/docker/healthcheck.sh" "$ROOT/docker/persistence.sh" "$TARGET/docker/"
cp "$ROOT/deploy/huggingface-spaces/README.template.md" "$TARGET/README.md"
printf 'Prepared HF Docker Space staging tree: %s\n' "$TARGET"
printf 'Create Space Secrets: QDRANT_API_KEY and QDRANT_READ_ONLY_API_KEY.\n'
printf 'Recommended: attach a read-write Storage Bucket at /qdrant-persist and set QNP_STORAGE_MODE=snapshot-persist.\n'
printf 'Recommended Variables: QNP_REQUIRE_PERSIST_MOUNT=1, QNP_AUTO_RESTORE=1, QNP_AUTO_SNAPSHOT_INTERVAL_SECONDS=900, QNP_AUTO_SNAPSHOT_ON_SHUTDOWN=1, QNP_SHUTDOWN_SNAPSHOT_TIMEOUT_SECONDS=20, QNP_SNAPSHOT_RETENTION=3.\n'
printf 'Direct Bucket-backed live Qdrant storage is experimental and requires QNP_STORAGE_MODE=direct-mount-experimental plus QNP_ALLOW_UNSUPPORTED_STORAGE=1; the entrypoint forces real-mount validation for this mode.\n'
