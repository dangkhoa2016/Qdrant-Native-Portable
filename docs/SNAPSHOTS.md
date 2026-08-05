# Snapshots and Recovery

> 🌐 Language / Ngôn ngữ: **English** | [Tiếng Việt](SNAPSHOTS.vi.md)

Snapshots are the portable recovery mechanism for this single-node toolkit, especially on ephemeral development platforms.

## Collection snapshot

Use collection snapshots when you want to back up or migrate one collection.

Create:

```bash
bash qdrant.sh snapshots create-collection colab_demo
```

List:

```bash
bash qdrant.sh snapshots list-collection colab_demo
```

Download:

```bash
bash qdrant.sh snapshots download-collection \
  colab_demo SNAPSHOT_NAME /path/to/colab_demo.snapshot
```

The project creates:

```text
/path/to/colab_demo.snapshot
/path/to/colab_demo.snapshot.sha256
```

Restore to a collection:

```bash
bash qdrant.sh snapshots restore-collection restored_demo /path/to/colab_demo.snapshot
```

If the `.sha256` sidecar exists, it is verified first.

## Full-storage snapshot

A full snapshot includes the whole single-node storage state, including collection aliases.

Create:

```bash
bash qdrant.sh snapshots create-full
```

List:

```bash
bash qdrant.sh snapshots list-full
```

Download:

```bash
bash qdrant.sh snapshots download-full SNAPSHOT_NAME /path/to/full.snapshot
```

## Full-storage restore

Qdrant full-storage snapshots are restored through the Qdrant CLI at startup, not through the normal REST restore endpoint.

This project wraps that workflow:

```bash
bash qdrant.sh snapshots restore-full /path/to/full.snapshot --yes
```

The manager performs these steps:

1. Verify the `.sha256` sidecar if present.
2. Stop Qdrant if it is running.
3. Move the current storage to a timestamped rollback directory.
4. Create a fresh storage directory.
5. Start Qdrant with `--storage-snapshot`.
6. Wait for authenticated readiness.
7. Keep the previous storage as a rollback copy after success.
8. If restore startup fails, restore the previous storage and attempt to restart the original database.

Rollback copies live under:

```text
$BASE_DIR/recovery-backups/
```

Delete old rollback copies manually only after validating the restored database.

## Export snapshots off an ephemeral runtime

A snapshot stored only inside an ephemeral runtime can disappear when the session is reset or deleted. Copy completed snapshots to persistent storage or download them.

Example durable-copy workflow:

```bash
cp /path/to/full.snapshot /path/to/durable-backups/
cp /path/to/full.snapshot.sha256 /path/to/durable-backups/
```

Cloud/FUSE storage can hold completed backup copies, but should not be the live Qdrant database storage directory.

## Version upgrades

Before testing another Qdrant version:

1. Create and export a snapshot.
2. Record the current working Qdrant version.
3. Test the new version with `QDRANT_VERSION=...`.
4. Validate collections, point counts, queries, payloads, and application clients.
5. Keep the old snapshot until the new version is accepted.

A snapshot is a recovery tool, not a substitute for a separate source of truth when your application data is important.

## Portable backup export

The higher-level backup command creates a fresh snapshot, downloads it to a destination directory, and adds a portable SHA256 file plus JSON manifest:

```bash
bash qdrant.sh backup full /path/to/durable-backups
bash qdrant.sh backup collection portable_demo /path/to/durable-backups
```

The manifest records creation time, snapshot kind/name, Qdrant version, resource profile, and detected platform. This is preferable to copying a live storage directory.

Full restore works in both service-user and current-user process modes as long as the current account has control over the configured runtime directory/process.
