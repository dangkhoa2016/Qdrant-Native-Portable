#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail_test() { echo "HF bucket persistence test failed: $*" >&2; exit 1; }

[[ -f "$ROOT/docker/persistence.sh" ]] || fail_test "missing docker/persistence.sh"
# shellcheck source=/dev/null
source "$ROOT/docker/persistence.sh"

# SAFE snapshot persistence must keep live Qdrant data separate from the bucket mount.
QNP_STORAGE_MODE=snapshot-persist
QDRANT_STORAGE_PATH=/tmp/qnp-live-storage
QNP_PERSIST_PATH=/tmp/qnp-bucket
QNP_ALLOW_UNSUPPORTED_STORAGE=0
qnp_validate_storage_mode || fail_test "snapshot-persist should accept separate local and persistent paths"

QDRANT_STORAGE_PATH=/tmp/qnp-bucket/live
if qnp_validate_storage_mode >/dev/null 2>&1; then
  fail_test "snapshot-persist must reject live storage inside the persistent bucket mount"
fi

# Direct bucket-backed live storage is deliberately experimental and double opt-in.
export QNP_STORAGE_MODE=direct-mount-experimental
QDRANT_STORAGE_PATH=/tmp/qnp-bucket/live
QNP_PERSIST_PATH=/tmp/qnp-bucket
export QNP_ALLOW_UNSUPPORTED_STORAGE=0
if qnp_validate_storage_mode >/dev/null 2>&1; then
  fail_test "direct-mount-experimental must require QNP_ALLOW_UNSUPPORTED_STORAGE=1"
fi
export QNP_ALLOW_UNSUPPORTED_STORAGE=1
qnp_validate_storage_mode || fail_test "explicitly acknowledged direct mount should pass wrapper validation"

# Restore selection must prefer LATEST and verify checksums before returning a snapshot.
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/persist/full"
printf 'older' > "$tmp/persist/full/older.snapshot"
(cd "$tmp/persist/full" && sha256sum older.snapshot > older.snapshot.sha256)
printf 'newer' > "$tmp/persist/full/newer.snapshot"
(cd "$tmp/persist/full" && sha256sum newer.snapshot > newer.snapshot.sha256)
printf '%s\n' 'older.snapshot' > "$tmp/persist/full/LATEST"
QNP_PERSIST_PATH="$tmp/persist"
selected="$(qnp_select_latest_snapshot)"
[[ "$selected" == "$tmp/persist/full/older.snapshot" ]] || fail_test "LATEST pointer was not preferred"

printf 'corrupt' >> "$tmp/persist/full/older.snapshot"
if qnp_verify_snapshot "$tmp/persist/full/older.snapshot" >/dev/null 2>&1; then
  fail_test "corrupt persistent snapshot passed checksum verification"
fi

# When requested, persistence must be a real mount rather than an accidentally-created local directory.
mountinfo="$tmp/mountinfo"
printf '1 2 0:1 / / rw - rootfs rootfs rw\n' > "$mountinfo"
export QNP_MOUNTINFO_PATH="$mountinfo"
QNP_PERSIST_PATH=/qdrant-persist
export QNP_REQUIRE_PERSIST_MOUNT=1
if qnp_validate_persist_mount >/dev/null 2>&1; then
  fail_test "required persistent mount passed even though /qdrant-persist was not mounted"
fi
printf '10 2 0:9 / /qdrant-persist rw - fuse.hf-mount hf rw\n' >> "$mountinfo"
qnp_validate_persist_mount || fail_test "attached /qdrant-persist mount was not recognized"
export QNP_REQUIRE_PERSIST_MOUNT=0

declare -F qnp_validate_snapshot_policy >/dev/null || fail_test "missing snapshot policy validator"
export QNP_AUTO_RESTORE=1
export QNP_AUTO_SNAPSHOT_INTERVAL_SECONDS=30
export QNP_AUTO_SNAPSHOT_ON_SHUTDOWN=1
export QNP_SHUTDOWN_SNAPSHOT_TIMEOUT_SECONDS=20
export QNP_SNAPSHOT_RETENTION=3
if qnp_validate_snapshot_policy >/dev/null 2>&1; then
  fail_test "snapshot interval below 60 seconds should be rejected"
fi
export QNP_AUTO_SNAPSHOT_INTERVAL_SECONDS=900
qnp_validate_snapshot_policy || fail_test "valid snapshot policy was rejected"
QNP_AUTO_RESTORE=2
if qnp_validate_snapshot_policy >/dev/null 2>&1; then
  fail_test "invalid QNP_AUTO_RESTORE boolean was accepted"
fi
export QNP_AUTO_RESTORE=1

# Snapshot export must write a complete file, checksum, manifest and LATEST pointer.
export_root="$tmp/export"
mkdir -p "$export_root/live/snapshots" "$export_root/persist/full"
printf 'snapshot-payload' > "$export_root/live/snapshots/generated.snapshot"
QDRANT_STORAGE_PATH="$export_root/live"
QDRANT_SNAPSHOTS_PATH="$export_root/live/snapshots"
export QNP_PERSIST_PATH="$export_root/persist"
export QNP_SNAPSHOT_RETENTION=3
qnp_http_post() { printf 'HTTP/1.1 200 OK\r\n\r\n{"result":{"name":"generated.snapshot"},"status":"ok"}\n'; }
qnp_create_persistent_snapshot || fail_test "persistent snapshot export failed"
[[ -f "$export_root/persist/full/generated.snapshot" ]] || fail_test "exported snapshot missing"
qnp_verify_snapshot "$export_root/persist/full/generated.snapshot" || fail_test "exported snapshot checksum invalid"
[[ "$(cat "$export_root/persist/full/LATEST")" == generated.snapshot ]] || fail_test "LATEST pointer not updated"
[[ -f "$export_root/persist/full/generated.snapshot.manifest.txt" ]] || fail_test "snapshot manifest missing"
[[ ! -f "$export_root/live/snapshots/generated.snapshot" ]] || fail_test "local completed snapshot should be removed after durable copy"

# Corrupt LATEST must fall back to an older valid snapshot instead of returning corrupt data.
printf 'good' > "$export_root/persist/full/good.snapshot"
(cd "$export_root/persist/full" && sha256sum good.snapshot > good.snapshot.sha256)
printf 'bad' > "$export_root/persist/full/bad.snapshot"
(cd "$export_root/persist/full" && sha256sum bad.snapshot > bad.snapshot.sha256)
printf 'corruption' >> "$export_root/persist/full/bad.snapshot"
printf '%s\n' bad.snapshot > "$export_root/persist/full/LATEST"
selected="$(qnp_select_latest_valid_snapshot)"
[[ "$selected" == "$export_root/persist/full/good.snapshot" ]] || fail_test "corrupt LATEST did not fall back to valid snapshot"

# Restore staging must stay outside the live storage directory so full-storage restore starts from clean live storage.
printf 'restore-me' > "$export_root/persist/full/restore.snapshot"
(cd "$export_root/persist/full" && sha256sum restore.snapshot > restore.snapshot.sha256)
printf '%s\n' restore.snapshot > "$export_root/persist/full/LATEST"
QDRANT_STORAGE_PATH="$export_root/live-empty"
QDRANT_SNAPSHOTS_PATH="$export_root/snapshot-scratch"
mkdir -p "$QDRANT_STORAGE_PATH" "$QDRANT_SNAPSHOTS_PATH"
staged="$(qnp_stage_latest_snapshot_for_restore)"
[[ "$staged" == "$QDRANT_SNAPSHOTS_PATH/.qnp-restore/restore.snapshot" ]] || fail_test "restore snapshot was staged inside live storage"
[[ -z "$(find "$QDRANT_STORAGE_PATH" -mindepth 1 -print -quit)" ]] || fail_test "restore staging polluted live storage"

# Shutdown snapshot wrapper must be bounded so a slow Bucket cannot block termination forever.
declare -F qnp_create_persistent_snapshot_with_timeout >/dev/null || fail_test "missing bounded snapshot wrapper"
qnp_create_persistent_snapshot() { sleep 3; }
start_seconds="$SECONDS"
if qnp_create_persistent_snapshot_with_timeout 1 >/dev/null 2>&1; then
  fail_test "timed snapshot unexpectedly succeeded"
fi
elapsed=$((SECONDS - start_seconds))
(( elapsed < 3 )) || fail_test "shutdown snapshot timeout did not bound execution"

# HF provider artifacts must document the safe and experimental modes.
grep -q 'snapshot-persist' "$ROOT/deploy/huggingface-spaces/README.template.md" || fail_test "HF README missing snapshot-persist mode"
grep -q '/qdrant-persist' "$ROOT/deploy/huggingface-spaces/README.template.md" || fail_test "HF README missing bucket mount path"
grep -q 'direct-mount-experimental' "$ROOT/deploy/huggingface-spaces/README.template.md" || fail_test "HF README missing experimental direct mode"
grep -q 'QNP_ALLOW_UNSUPPORTED_STORAGE=1' "$ROOT/deploy/huggingface-spaces/README.template.md" || fail_test "HF README missing experimental acknowledgement"

grep -q 'persistence.sh' "$ROOT/examples/production/production-huggingface-spaces-example.sh" || fail_test "HF staging helper does not copy persistence helper"

echo "HF bucket persistence tests passed"
