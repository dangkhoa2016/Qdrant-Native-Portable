# Changelog

> 🌐 Language / Ngôn ngữ: **English** | [Tiếng Việt](CHANGELOG.vi.md)

All notable public changes to this project will be documented in this file.

## 1.0.0 - 2026-08-18

- Provider validation: Hugging Face Spaces, Modal.com, and Beam.cloud are now real-provider validated for the documented single-node snapshot-persistence paths; Beam.cloud real-provider validation includes corrupt-newest fallback, all-corrupt fail-closed behavior, post-test recovery, and retention.


Initial public release.

### Added

- Native-first Qdrant setup for Linux development environments plus a hardened single-node Docker runtime for selected cloud/container platforms.
- Platform detection for Google Colab, Kaggle, GitHub Codespaces, CodeSandbox-style VMs, and generic Linux.
- Rootless `current-user` mode and optional privileged `service-user` mode.
- `minimal` and Nginx `proxy` deployment modes.
- `low-memory`, `balanced-lite`, `balanced-memory`, `balanced`, and `performance` resource profiles with RAM-aware auto selection.
- Admin/read-only API keys, staged admin-key rotation, optional JWT RBAC, masked credential output, and security checks.
- Optional gRPC, Strict Mode defaults, snapshots, backup/export, service management, public-access helpers, diagnostics, metrics, and examples.
- Portable benchmark tooling with environment metadata, separate cold/warm query measurement, stable/full-index settle checks, adaptive timeouts, repeated runs, raw latency samples, percentile reporting, internal suite logs, and Markdown/JSON suite reports.
- Guarded test-only clean reset/reinstall commands that remove stale runtime data/log/cache/binaries before a fresh benchmark install while leaving normal lifecycle commands non-destructive.
- Guarded host-wide `purge-all-test` and one-command fresh benchmark entrypoint for disposable multi-platform validation hosts with platform-specific runtime/export paths.
- Fail-closed source-overlay handling for the fresh benchmark workflow: known legacy paths can be classified, but automatic removal is allowed only when a trusted expected SHA256 is available and matches exactly; modified, missing, unknown, or unverifiable source remains refused.
- English and Vietnamese documentation, including a public capability/platform matrix, production-readiness overview, and documentation map.
- GitHub Actions static checks and release-artifact validation.
- Fail-closed single-node production policy with `production-check`, `prepare`, and foreground `serve` lifecycle.
- Docker adapters for Hugging Face Spaces, Modal, and Beam, with autoscaling/cluster behavior deliberately disabled for the database node.
- Hugging Face Storage Bucket persistence in `snapshot-persist` mode: local live Qdrant data, periodic checksum-verified full-storage snapshots in the attached Bucket, automatic restore, retention, corruption fallback, and bounded shutdown snapshots.
- Modal single-node snapshot-persist adapter: local live Qdrant data, Modal Volume-backed completed full snapshots, provider-native commit/read-back durability preflight, a validated 600-second periodic cadence safely ahead of the 900-second scale-down window, an enforced timing margin, secret-free exit/child/commit lifecycle observability, and a hard `max_containers=1` writer limit. Real-provider validation on 2026-08-18 proved the complete fresh-write durability chain: a newly written sentinel survived a later scale-down/recreation after two completed periodic full snapshots; the exit hook completed its final Volume commit, the fresh container restored the newest valid snapshot, and the exact sentinel point/payload was recovered. Modal shutdown snapshots are intentionally disabled because provider termination is concurrent with exit hooks; periodic snapshots define the <=600-second durability RPO.
- Modal validation-result collector that writes evidence outside the source tree by default, records read-only Qdrant collection/sentinel evidence alongside provider logs and Volume listings, and refuses to package current API-key values if they appear in collected files.
- Full-snapshot restore hardening for Qdrant 1.18.3: fail closed when all persisted snapshots are invalid, avoid forcing `storage.temp_path` during snapshot restore, and fail fast when the Qdrant child exits before readiness.
- Explicit `direct-mount-experimental` mode for testing Bucket-backed live storage without bypassing Qdrant filesystem-safety checks.

### Reliability and release-quality safeguards

- Health checks return non-zero when the Qdrant API is unavailable or when a required proxy is unhealthy.
- Native service startup distinguishes PID liveness from authenticated REST readiness, waits against a configurable 300-second wall-clock deadline while collections recover, bounds probes by the remaining time, suppresses transient curl connection errors, and fails early if the process exits.
- Startup failures remain non-zero through the public service-manager entry point, with lifecycle regression coverage for delayed readiness, early exit, wall-clock timeout behavior, and runtime-setting validation, precedence, and persistence.
- Runtime artifacts, logs, caches, generated benchmark data, local pointers, and credentials are excluded from release archives.
- Release packaging prefers Git-tracked source in a canonical Git checkout; outside Git, an existing canonical SOURCE-MANIFEST.json is verified and used as the exact source file authority, with the explicit public-file allowlist retained only as a compatibility fallback when no canonical manifest is available.
### Benchmark/profile refinements

- Added `balanced-memory` for 6-10 GB hosts with small/medium collections.
- Added dataset-aware `profile-advisor` with JSON output.
- Added bounded progress-aware settle extension and explicit `READY` / `PROVISIONAL` reporting.
- Added suite/run wall-time and cumulative settle-time reporting.
- Added the smart cross-platform benchmark orchestrator to the public source archive.
- Added explicit fresh-baseline provenance (`fresh_baseline` / `baseline_origin`) so a successful `purge-all-test` fresh workflow is comparison-grade without a redundant second reinstall.
- Refined continuous resource telemetry to distinguish pre-existing swap from benchmark-window swap growth, deduplicate pressure transitions/events, report MemAvailable percentiles plus time under pressure, detect sampling gaps, and distinguish pre-existing Qdrant zombies from benchmark-window zombie growth.
