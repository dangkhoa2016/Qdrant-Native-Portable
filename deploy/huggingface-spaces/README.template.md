---
title: Qdrant Native Portable
emoji: 🔎
colorFrom: blue
colorTo: green
sdk: docker
app_port: 6333
pinned: false
---

# Qdrant Native Portable — Hugging Face Spaces

Deploy the canonical **single-node Docker runtime**. Add `QDRANT_API_KEY` and `QDRANT_READ_ONLY_API_KEY` as Space **Secrets**.

## Recommended persistent mode: local live DB + Bucket snapshots

Hugging Face Storage Buckets are persistent and can be attached to a Space as read-write volumes. For Qdrant, keep the **live database** on the Space's local filesystem and use the bucket for completed full-storage snapshot files.

Attach a Storage Bucket to this Space at:

```text
/qdrant-persist
```

Then add these Space **Variables**:

```text
QNP_STORAGE_MODE=snapshot-persist
QNP_PERSIST_PATH=/qdrant-persist
QNP_REQUIRE_PERSIST_MOUNT=1
QNP_AUTO_RESTORE=1
QNP_AUTO_SNAPSHOT_INTERVAL_SECONDS=900
QNP_AUTO_SNAPSHOT_ON_SHUTDOWN=1
QNP_SHUTDOWN_SNAPSHOT_TIMEOUT_SECONDS=20
QNP_SNAPSHOT_RETENTION=3
```

Runtime layout:

```text
/qdrant/storage       local live Qdrant database (ephemeral)
/qdrant/snapshots     local snapshot/scratch area (ephemeral)
/qdrant-persist/full  persistent full-storage snapshots in the attached Bucket
```

On a fresh Space/container start, the entrypoint checks for a valid `LATEST` full snapshot, verifies its SHA256 sidecar, copies it back to local storage, and starts Qdrant with `--storage-snapshot`. If local live storage is already non-empty, automatic restore is skipped rather than overwriting it.

While Qdrant is running, `QNP_AUTO_SNAPSHOT_INTERVAL_SECONDS` controls periodic full snapshots. `0` disables periodic snapshots; values below 60 seconds are rejected. A best-effort final snapshot is also attempted on graceful `SIGTERM`/`SIGINT` when `QNP_AUTO_SNAPSHOT_ON_SHUTDOWN=1`.

Snapshots are retained according to `QNP_SNAPSHOT_RETENTION` (default `3`). Because abrupt platform termination can occur before a shutdown hook finishes, periodic snapshots are the primary persistence mechanism.

## Experimental direct Bucket mode

For research only, you can mount the Bucket and point the live Qdrant storage at it:

```text
QNP_STORAGE_MODE=direct-mount-experimental
QNP_PERSIST_PATH=/qdrant-persist
QNP_REQUIRE_PERSIST_MOUNT=1
QNP_ALLOW_UNSUPPORTED_STORAGE=1
```

This is deliberately double opt-in. Qdrant requires block-level persistent storage with a POSIX-compatible filesystem and warns that FUSE/NFS/object-storage-backed live storage can be unsafe. The wrapper does **not** bypass Qdrant's filesystem compatibility checks; if Qdrant refuses the mount, treat that as a correct safety failure.

## Ephemeral mode

If you do not attach a Bucket, leave the default:

```text
QNP_STORAGE_MODE=local
```

The Space remains useful for disposable demos and integration tests, but database state can disappear when the Space restarts or is rebuilt.

Use `examples/production/production-huggingface-spaces-example.sh <staging-dir>` from the main repository to prepare a Space-ready tree.

This deployment is single-node only and does not enable cluster peer networking.
