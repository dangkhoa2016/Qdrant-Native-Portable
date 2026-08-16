# Single-node production

> 🌐 Language / Ngôn ngữ: **English** | [Tiếng Việt](PRODUCTION.vi.md)

The production path is deliberately **single-node**. It adds safer policy and lifecycle behavior without changing the proven development defaults.

## Native production

```bash
export QDRANT_API_KEY='replace-me'
export QDRANT_READ_ONLY_API_KEY='replace-me-too'
export QNP_ENV=production
export QNP_RUNTIME=native
export QNP_TOPOLOGY=single
export PUBLIC_MODE=none
bash qdrant.sh production-check
bash qdrant.sh prepare
exec bash qdrant.sh serve
```

`prepare` installs/configures but does not start Qdrant. `serve` uses foreground `exec`, which is suitable for a VM/container supervisor. Production defaults to no demo collection and no public Quick Tunnel. With `QNP_SECRET_POLICY=require-env`, caller-injected API keys are required for each production command and are not persisted to `secrets.env`.

Quick Tunnel is demo ingress only and requires both `PUBLIC_MODE=cloudflare-quick` and `QNP_ALLOW_DEMO_TUNNEL=1` in production.

For a durable native deployment, the live Qdrant data directory must be on storage that satisfies Qdrant's persistent-storage requirements: block-level access and a POSIX-compatible filesystem. Do not use NFS, S3/object storage, FUSE-style cloud drives, or provider mounts whose filesystem semantics are not known to satisfy those requirements as the live database path.

## Docker production

```bash
export QDRANT_API_KEY='replace-me'
export QDRANT_READ_ONLY_API_KEY='replace-me-too'
docker compose -f docker/docker-compose.yml up --build
```

The reference image is pinned to the official Qdrant `v1.18.3-unprivileged` image and runs as UID/GID 1000. The reference Compose file uses a Docker named volume at `/qdrant/storage`, a read-only root filesystem, dropped Linux capabilities, and a loopback-only host port.

The healthcheck uses Qdrant `/readyz`; it does not put an API key on the healthcheck command line. For remote production access, place TLS-capable restricted ingress in front of Qdrant. A Docker named volume still ultimately depends on the Docker host storage driver/filesystem; verify that it satisfies Qdrant's block/POSIX requirements.

### Docker storage modes

`QNP_STORAGE_MODE` controls the container storage policy:

```text
local                       local/block-backed live storage; default
snapshot-persist            local live storage + persistent full-snapshot archive
direct-mount-experimental   direct provider mount as live storage; explicit unsupported experiment
```

For `snapshot-persist`, configure a separate writable `QNP_PERSIST_PATH`. Full-storage snapshots are created in the separate local `/qdrant/snapshots` area, copied to the persistent path with SHA256 sidecars, and restored on a fresh start using Qdrant `--storage-snapshot`. Automatic restore never overwrites a non-empty live data directory.

Restore selection is fail-closed: a corrupt preferred/newest snapshot is skipped in favor of the newest older checksum-valid snapshot; if persisted snapshot files exist but none validate, QNP refuses to start an empty Qdrant. With Qdrant 1.18.3, `snapshot-persist` deliberately leaves Qdrant `storage.temp_path` unmanaged so full-storage recovery can allocate its own recovery directories without archive-unpack collisions.

Useful variables:

```text
QNP_PERSIST_PATH=/qdrant-persist
QNP_REQUIRE_PERSIST_MOUNT=1
QNP_AUTO_RESTORE=1
QNP_AUTO_SNAPSHOT_INTERVAL_SECONDS=900
QNP_AUTO_SNAPSHOT_ON_SHUTDOWN=1
QNP_SHUTDOWN_SNAPSHOT_TIMEOUT_SECONDS=20
QNP_SNAPSHOT_RETENTION=3
```

Periodic snapshots are the primary protection against abrupt platform termination. A shutdown snapshot is best-effort only.

`direct-mount-experimental` is intentionally guarded by:

```text
QNP_ALLOW_UNSUPPORTED_STORAGE=1
```

It does not disable Qdrant's filesystem safety checks.

## Provider direction

| Target | Runtime | Persistence model in this revision | Intended use |
|---|---|---|---|
| Generic Linux/VPS | Native | Live DB on compatible local/block storage | Production single-node |
| Generic Docker host | Docker | Live DB on compatible Docker volume | Production single-node |
| Kaggle | Native | Session-persistence dependent | Production-demo / production-light |
| Colab | Native | Ephemeral unless data is restored/exported separately | Production-demo |
| GitHub Codespaces | Native | Workspace-lifecycle dependent | Production-demo / integration |
| Hugging Face Spaces | Docker | Local live DB + Bucket full snapshots | **Real-provider validated** |
| Modal.com | Docker | Local live DB + Modal Volume full snapshots | **Real-provider validated** |
| Beam.cloud | Docker | Local live DB + Beam Volume full snapshots | **Real-provider validated** |

### Hugging Face Spaces

Attach a read-write Hugging Face Storage Bucket at:

```text
/qdrant-persist
```

and set:

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

The live database stays at `/qdrant/storage` on local Space disk. Completed full-storage snapshots are copied to `/qdrant-persist/full`. At startup, the newest valid snapshot (or the `LATEST` pointer) is checksum-verified, copied back to local storage, and supplied to Qdrant through `--storage-snapshot`.

This design uses the Bucket for durable archive files, not for live Qdrant segments/indexes. Hugging Face describes Storage Buckets as S3-like object storage exposed through volume mounts, while Qdrant requires block/POSIX storage for the live database.

For research only, `QNP_STORAGE_MODE=direct-mount-experimental` plus `QNP_ALLOW_UNSUPPORTED_STORAGE=1` can point live storage into the Bucket mount. QNP does not claim this is safe or supported and does not bypass Qdrant's filesystem compatibility checks.

### Modal.com

The Modal adapter uses a **Modal Volume only as the durable completed-snapshot layer**. The live Qdrant database stays on the container-local `/qdrant/storage` filesystem; the Volume `qnp-qdrant-persist` is mounted at `/qdrant-persist` and QNP runs in `snapshot-persist` mode. This preserves the same storage boundary used by the validated Hugging Face adapter instead of treating a distributed Volume as live block storage.

The adapter uses Modal's `@app.server` primitive, clears the Docker image ENTRYPOINT so Modal's Python runtime can start, and launches `/qdrant/qnp-entrypoint.sh` from `@modal.enter`. It is fail-closed to one writer with `max_containers=1`. `min_containers=0` plus a 15-minute scaledown window allows scale-to-zero; a cold start restores the newest checksum-valid full snapshot when local live storage is empty.

Modal Volumes are filesystem-mounted by the provider but are not required to appear as a traditional Linux mountpoint in `/proc/self/mountinfo`. Before launching QNP, the adapter therefore writes a unique probe to `/qdrant-persist`, calls `persist_volume.commit()`, and reads the committed bytes back through the Modal Volume API. Only after that durable round trip succeeds does the QNP child bypass the generic Linux mount-table check. Any write, commit, read-back, content-match, or cleanup-commit failure remains fail-closed and Qdrant is not started.

Default persistence policy:

```text
QNP_STORAGE_MODE=snapshot-persist
QNP_PERSIST_PATH=/qdrant-persist
QNP_REQUIRE_PERSIST_MOUNT=1
QNP_AUTO_RESTORE=1
QNP_AUTO_SNAPSHOT_INTERVAL_SECONDS=600
QNP_AUTO_SNAPSHOT_ON_SHUTDOWN=0
QNP_SNAPSHOT_RETENTION=3
```

Periodic snapshots are the primary and explicit Modal durability boundary. Modal uses a 600-second periodic snapshot cadence with a 900-second scale-down window, leaving a nominal 300-second gap; the adapter also enforces at least a 180-second safety margin so the old equal-timer race cannot silently return. Modal Server shutdown signals running processes concurrently with `@modal.exit()`, so this adapter deliberately sets `QNP_AUTO_SNAPSHOT_ON_SHUTDOWN=0` rather than promise an ordering it cannot guarantee. The exit hook remains useful for child cleanup and an explicit final `persist_volume.commit()` of already-completed periodic snapshots. Real provider validation has proven the 401/200/200/403 authorization matrix, actual-data periodic snapshots, scale-down/recreation, newest-valid auto-restore, Qdrant collection recovery, and exact sentinel survival. Final real-provider validation on 2026-08-18 proved the stronger fresh-write chain: a newly written sentinel survived a later scale-down/recreation after two completed periodic full snapshots; the exit hook completed its final Volume commit, the next container restored the newest valid snapshot, and the exact sentinel point/payload was recovered. The resulting durability RPO is bounded by the periodic cadence (nominally <=600 seconds), not by a shutdown snapshot.

For validation evidence, export the deployed `QDRANT_URL` and `QDRANT_READ_ONLY_API_KEY`, then run `examples/production/collect-modal-validation-result.sh`. By default it writes to a sibling `qnp-modal-results/` directory outside the source tree so generated evidence cannot make source-integrity DIRTY. In addition to Modal app logs, Volume listings, source-integrity, and metadata, it records read-only `/collections`, sentinel-collection, and sentinel-point responses. Individual provider/API probes are recorded in `collection-status.txt` so one unavailable evidence source does not discard the rest of the package. The collector refuses to create the ZIP if any collected file contains the exact current admin or read-only API-key value.

### Beam.cloud

The Beam adapter now has a **real-provider-validated snapshot-persistence path**. It attaches Beam Volume `qnp-qdrant-persist` at `/qdrant-persist` for completed, checksum-protected full snapshots while keeping the live Qdrant database on container-local `/qdrant/storage`. The Volume is deliberately **not** used as live database storage, because this adapter does not assume that distributed-volume semantics are equivalent to the block/POSIX storage expected for Qdrant live files.

The staging environment is:

```text
QNP_STORAGE_MODE=snapshot-persist
QNP_PERSIST_PATH=/qdrant-persist
QNP_REQUIRE_PERSIST_MOUNT=1
QNP_AUTO_RESTORE=1
QNP_AUTO_SNAPSHOT_INTERVAL_SECONDS=600
QNP_AUTO_SNAPSHOT_ON_SHUTDOWN=0
QNP_SNAPSHOT_RETENTION=3
QNP_READY_TIMEOUT_SECONDS=180
```

`deploy/beam/entrypoint.sh` performs a fail-closed provider preflight before QNP starts: the attached path must exist and be writable, a dedicated probe is written and fsynced, exact bytes are read back, and the probe must be removable. Only then does it `exec /qdrant/qnp-entrypoint.sh`. The generic QNP mounted-volume guard remains enabled for this provider path; if real Beam testing proves that Beam's mount representation is incompatible with that generic check, the adapter must adopt a provider-specific proof before disabling only the incompatible check.

Phase A deliberately uses `keep_warm_seconds=-1`. After a fresh sentinel is written, the operator waits for a completed periodic snapshot and checksum evidence, then stops the actual container with `beam container stop <CONTAINER-ID>`. A later request starts/uses a fresh container and `examples/production/beam-sentinel.sh verify-readonly` checks the exact old point using only the read-only API key. Beam documents that files written to a distributed Volume can take up to 60 seconds to become visible to other containers, so the Beam verifier uses bounded polling instead of treating the first cold-start read as definitive.

The Beam real-provider validation is complete for the documented single-node snapshot-persistence path: normal recreation/restore, newest-valid selection, corrupt-newest fallback, all-corrupt fail-closed behavior, retention, recovery, and secret-safe evidence collection were exercised on Beam.cloud. `QNP_AUTO_SNAPSHOT_ON_SHUTDOWN=0` remains deliberate; periodic snapshots define the durability boundary rather than an unproven shutdown-order guarantee.

For the operator workflow, run `examples/production/production-beam.cloud-example.sh`. Evidence is packaged by `examples/production/collect-beam-validation-result.sh`, which records Beam deployment/container/Volume inventory, optional deployment/container log captures, Qdrant authorization status, read-only collection/sentinel responses, source-integrity and phase metadata. The collector never dumps raw container environments and refuses to create a ZIP if any collected file contains the exact current admin or read-only Qdrant API-key value.

No cluster/peer networking is enabled. Multiple concurrent Qdrant writers remain deliberately outside the supported single-node topology.
