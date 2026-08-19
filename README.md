# Qdrant Native Portable

[![CI](https://github.com/dangkhoa2016/Qdrant-Native-Portable/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/dangkhoa2016/Qdrant-Native-Portable/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/dangkhoa2016/Qdrant-Native-Portable?display_name=tag&sort=semver)](https://github.com/dangkhoa2016/Qdrant-Native-Portable/releases/latest)
[![License: MIT](https://img.shields.io/github/license/dangkhoa2016/Qdrant-Native-Portable)](LICENSE)

> 🌐 Language / Ngôn ngữ: **English** | [Tiếng Việt](README.vi.md)

A security-conscious, **native-first and Docker-capable Qdrant runtime toolkit** for learning, development, RAG demos, integration tests, and production-oriented single-node deployments. Native mode targets Google Colab, Kaggle, GitHub Codespaces, CodeSandbox-like Linux VMs, and generic Linux hosts; the Docker runtime adds provider adapters for Hugging Face Spaces, Modal, and Beam.

> Scope: single-node infrastructure. Production policy, foreground lifecycle, Docker hardening, and provider-specific persistence helpers are included, but this project is intentionally not a replacement for a production HA Qdrant cluster.

## Design goals

The public release is designed to avoid platform-specific assumptions:

- auto-detects the host platform and chooses a suitable data directory;
- supports **rootless/current-user mode**;
- supports **minimal mode** with Qdrant only, so Nginx/root is optional;
- keeps the original Nginx single-port proxy as an optional `proxy` mode;
- adds `low-memory`, `balanced-lite`, `balanced-memory`, `balanced`, and `performance` resource profiles;
- enables Qdrant Low Memory Mode on constrained hosts;
- supports optional local gRPC;
- applies Strict Mode defaults to newly created collections;
- supports optional JWT RBAC and dependency-free scoped JWT generation;
- supports Cloudflare Quick Tunnel and GitHub Codespaces port publishing;
- adds `doctor`, `system-info`, `metrics`, backup export, and resource benchmarks;
- persists non-secret runtime settings outside the repository;
- adds fail-closed single-node production policy and foreground `prepare`/`serve` lifecycle;
- adds a hardened Docker runtime plus provider adapters for Hugging Face Spaces, Modal, and Beam;
- supports Hugging Face Storage Buckets safely as a full-snapshot persistence layer while keeping live Qdrant data local.
- includes a real-provider-validated Beam Volume snapshot-persistence adapter while keeping live Qdrant data local;

## Why this project?

Most Qdrant getting-started paths assume Docker, root access, or a long-lived server. Those assumptions are awkward on hosted notebooks and constrained cloud development environments. **Qdrant Native Portable turns the official native Qdrant binary into a reusable runtime toolkit**: platform detection, resource-aware profiles, rootless lifecycle management, secure credentials, diagnostics, snapshots, optional ingress, reproducible benchmarking, and guarded destructive test workflows are handled in one repository.

It is especially useful for:

- RAG and semantic-search developers who need a disposable Qdrant beside an embedding model or application;
- Colab, Kaggle, Codespaces, CodeSandbox-like, and restricted Linux users who cannot or do not want to run Docker;
- students, workshops, demos, SDK integration tests, and CI-style experiments that need a predictable single-node database;
- developers comparing Qdrant memory/disk trade-offs on small and medium hosted machines.

The toolkit keeps Qdrant itself CPU/RAM-oriented. On GPU-equipped notebook hosts, that leaves GPU capacity available for embeddings, rerankers, LLMs, or VLMs instead of spending it on the database layer.

## Capability and platform matrix

The table below is the fast public overview. It distinguishes native notebook/workspace support from Docker provider adapters and makes persistence maturity explicit. See the [Full capability reference](docs/FEATURES.md) for the complete feature matrix and evidence definitions.

| Target | Runtime | Persistence posture | Evidence |
|---|---|---|---|
| Google Colab | Native | Ephemeral; export/restore snapshots separately | Real-host validated |
| Kaggle Notebook | Native | Session/storage dependent | Supported + regression-tested platform logic |
| GitHub Codespaces | Native rootless | Workspace-lifecycle dependent | Real-host validated |
| CodeSandbox-like Linux VM | Native rootless | Platform/VM-lifecycle dependent | Real-host validated |
| Generic Linux / VPS | Native | Compatible block/POSIX live storage | Supported + regression-tested |
| Generic Docker host | Docker | Compatible Docker volume | Regression-tested |
| Hugging Face Spaces | Docker | Local live DB + Bucket full snapshots | **Real-provider validated** |
| Modal.com | Docker | Local live DB + Modal Volume full snapshots | **Real-provider validated** |
| Beam.cloud | Docker | Local live DB + Beam Volume full snapshots | **Real-provider validated** |

The strongest provider persistence proof in this release is Modal: the real-provider lifecycle recovered the exact fresh point/payload after periodic snapshots, scale-down, a fresh container, and newest-valid snapshot restore. See [Single-node production](docs/PRODUCTION.md#modalcom).

## What this project is — and is not

**It is:** a single-node Qdrant runtime/deployment toolkit that can run native without Docker where that is useful, use Docker where the platform prefers containers, apply resource-aware profiles and security defaults, create/restore snapshots, validate authorization, benchmark host behavior, and package clean public source.

**It is not:** a Qdrant HA/cluster orchestrator. This release does not provide peer discovery, replication, distributed consensus, automatic failover, multiple autoscaled Qdrant writers, or a universal cloud filesystem abstraction. Provider object/distributed storage is used only where its semantics are appropriate — for example, completed snapshot persistence rather than arbitrary live database files.

## Evidence-backed defaults

The automatic profiles are not only theoretical presets; they were refined with repeated real-host runs on Google Colab, GitHub Codespaces, and CodeSandbox-class Linux VMs. The numbers below are **observations for the project's tested 100K×768 development workload, not universal Qdrant performance guarantees**:

- **~4 GB:** `low-memory` was repeatedly usable without an OOM pattern, while deliberately trading first-query latency for memory headroom.
- **~8 GB:** `balanced-memory` kept vectors + HNSW in RAM and produced roughly **2–3 ms-class cold p50** in measured runs. Earlier disk-first `balanced-lite` baselines on the same host classes ranged from roughly **0.1–0.8 s cold p50**, depending strongly on the platform/storage backend.
- **~13 GB Colab:** `balanced` remained stable with large RAM headroom. The benchmark work also showed why client/server timing must be separated: Python vector generation and JSON encoding can dominate wall-clock time even when Qdrant server-side processing is strong.

These results are intended to guide development defaults, not replace workload-specific sizing. Use `profile-advisor` for your own point count and vector dimension, and re-measure when changing Qdrant versions, collection scale, storage class, or payload/index design.

## Native mode defaults

| Environment | Default process mode | Default deployment | Default profile* | Public access |
|---|---|---|---|---|
| Google Colab | service-user | proxy | based on RAM | Cloudflare Quick Tunnel |
| Kaggle | service-user when root | proxy when root | based on RAM | Cloudflare Quick Tunnel |
| GitHub Codespaces | current-user | minimal | usually balanced-memory at 8 GB | Codespaces forwarding |
| CodeSandbox/Linux VM | current-user | minimal | based on RAM | Quick Tunnel / platform-specific |
| Generic Linux | current-user unless root | minimal unless root | based on RAM | opt-in |

`auto` selects `low-memory` at roughly <=5.5 GB RAM, `balanced-memory` at <=10.5 GB, `balanced` at <=22 GB, and `performance` above that. These are conservative development defaults derived from cross-host tests; explicit settings always win.

## Architecture

Minimal/rootless:

```text
client / platform forwarding / optional tunnel
                │
                ▼
       127.0.0.1:6333 Qdrant REST + Dashboard
                │
        storage + snapshots
```

Proxy mode:

```text
client / HTTPS tunnel
        │
        ▼
127.0.0.1:9090 Nginx
        │
        ▼
127.0.0.1:6333 Qdrant
```

API keys are never written into `qdrant.yaml`; they are injected into the Qdrant process environment at startup.

## Quick start

```bash
# From the repository root
bash qdrant.sh doctor
bash qdrant.sh setup
```

Then:

```bash
bash qdrant.sh status
bash qdrant.sh health
bash qdrant.sh auth-check
bash qdrant.sh system-info
```

The current local endpoint is printed by setup/health. In minimal mode it is normally `http://127.0.0.1:6333`; in proxy mode it is normally `http://127.0.0.1:9090`.

Native lifecycle commands distinguish a live Qdrant process from a ready REST API. `bash qdrant.sh start` waits for authenticated API readiness even when the PID file identifies a live process, so callers wait through cold-start collection loading/recovery until the REST endpoint responds. The wall-clock startup deadline defaults to 300 seconds and can be overridden for larger datasets, for example with `QDRANT_START_TIMEOUT_SECONDS=600 bash qdrant.sh start`. See [Detailed usage](docs/USAGE.md#10-startstoprestart) for timeout, logging, and failure semantics.

### GitHub Codespaces 8 GB

No root or Nginx is required. With `auto`, an 8 GB Codespace now selects `balanced-memory` + `current-user` + `minimal` based on measured headroom from real 8 GB runs. To force the exact profile:

```bash
QDRANT_PROFILE=balanced-memory \
PROCESS_MODE=current-user \
DEPLOYMENT_MODE=minimal \
bash qdrant.sh setup
```

`balanced-memory` keeps vectors and HNSW in RAM while leaving payload on disk and retaining conservative optimizer concurrency. The disk-first `balanced-lite` profile remains available for larger collections. To publish the forwarded port using GitHub CLI:

```bash
bash qdrant.sh public
```

To return the forwarded port to private visibility:

```bash
bash qdrant.sh public-stop
```

## Resource profiles

### `low-memory`

Designed for approximately 2-5.5 GB hosts and memory-constrained development VMs. It uses Qdrant startup Low Memory Mode `no_populate`, stores vectors/HNSW/payload on disk, and limits background/search concurrency. It intentionally trades cold-query latency for lower resident memory.

```bash
QDRANT_PROFILE=low-memory bash qdrant.sh setup
```

### `balanced-lite`

Disk-first option for roughly 6-10 GB hosts when the expected collection is too large to keep full vectors resident safely. Vectors/payload stay on disk while HNSW remains in memory.

### `balanced-memory`

The default 6-10 GB profile for small/medium collections. Vectors and HNSW stay in RAM, payload stays on disk, and optimizer concurrency remains conservative. It targets the large cold-query penalty observed with disk-backed vectors on some 8 GB hosted VMs.

Use the dataset-aware advisor before choosing a profile for a known collection size:

```bash
bash qdrant.sh profile-advisor --points 100000 --dimension 768
```

### `balanced`

Good default for roughly 10-22 GB development machines. Payload remains on disk while vectors/HNSW favor memory for steadier latency.

### `performance`

For RAM-rich hosts and fast local storage. It favors in-memory operation and automatic thread selection.

See [docs/PROFILES.md](docs/PROFILES.md).

## Security

Credentials are stored outside the repository at `$BASE_DIR/secrets.env` with mode `600`. Non-secret settings are stored at `$BASE_DIR/runtime.env`.

```bash
bash qdrant.sh credentials status
bash scripts/show_credentials.sh --reveal   # only when intentionally needed
```

Rotate keys:

```bash
bash qdrant.sh credentials rotate-readonly --restart
bash qdrant.sh credentials stage-admin-rotation --restart
bash qdrant.sh credentials promote-admin-rotation --restart
```

JWT RBAC is opt-in:

```bash
bash qdrant.sh credentials jwt-enable --restart
bash qdrant.sh credentials create-token \
  --scope fairy_tales:r \
  --ttl 3600
```

A token file is created with mode `600`. Admin-key rotation invalidates JWTs signed with the previous admin key.

Strict Mode defaults are enabled for newly created collections with conservative query/timeout/HNSW limits. These defaults are configurable and do not turn the project into a multi-tenant security boundary by themselves.

After setup, verify the runtime authorization semantics explicitly:

```bash
bash qdrant.sh auth-check
```

`auth-check` validates the expected protection path: unauthenticated collection access is rejected, the admin key can read, the read-only key can read, and a read-only write is rejected. This checks authorization behavior rather than only checking that the Qdrant process is alive.

See [docs/SECURITY.md](docs/SECURITY.md).

## Optional gRPC

REST stays the default. Enable local gRPC explicitly:

```bash
QDRANT_ENABLE_GRPC=1 bash qdrant.sh setup
```

This opens Qdrant gRPC on loopback port `6334`. The single-port Nginx proxy still exposes REST only.

## Examples

Examples are separated from infrastructure code:

```text
examples/
├── curl/
├── python/
├── node/
└── ruby/
```

Load the active runtime into your current shell without printing secrets:

```bash
source scripts/activate.sh
```

Run dependency-light examples:

```bash
bash qdrant.sh examples
```

See [examples/README.md](examples/README.md).

## Backups and snapshots

Snapshot manager:

```bash
bash qdrant.sh snapshots create-full
bash qdrant.sh snapshots create-collection portable_demo
```

Portable backup export adds a checksum and manifest:

```bash
bash qdrant.sh backup full /path/to/backup-dir
bash qdrant.sh backup collection portable_demo /path/to/backup-dir
```

Do not place the **live** Qdrant storage on Google Drive/FUSE/network-style storage. Keep the active database on a suitable local POSIX filesystem and copy completed snapshot files to durable storage.

See [docs/SNAPSHOTS.md](docs/SNAPSHOTS.md).

## Diagnostics and benchmarking

```bash
bash qdrant.sh doctor
bash qdrant.sh system-info
bash qdrant.sh metrics
bash qdrant.sh metrics --raw
```

Dependency-free benchmark with stable settle checks, repeated runs, separate **cold vs warm** latency, host metadata, and separate client/server-facing timing:

```bash
bash qdrant.sh benchmark \
  --points 10000 \
  --dimension 768 \
  --queries 100 \
  --cold-queries 20 \
  --warmup 100 \
  --repeat 3
```

The warm-up reuses the exact measured query set. Standard 50K/100K suite workloads also require full indexing before measurement.

Run the standard constrained-host suite (1K×384, 10K×768, 50K×768, 100K×768):

```bash
bash qdrant.sh benchmark-suite
```

For a quick smoke benchmark:

```bash
bash qdrant.sh benchmark-suite --quick
```

Results are stored under `$BASE_DIR/benchmarks/`. Suite runs produce both `benchmark-report.json` and `benchmark-report.md`.

### Benchmark readiness and comparability

A successful HTTP request is not automatically a comparison-grade benchmark. Suite artifacts distinguish workload states such as `READY`, `PROVISIONAL`, `MISSING`, `UNKNOWN`, and `SKIPPED_MEMORY`. `READY` means the workload satisfied the benchmark-readiness checks; `PROVISIONAL` is deliberately not ranked as equivalent to `READY` when indexing/optimizer readiness is incomplete.

The project also separates **readiness** from **comparability**. Comparison-grade workflows can validate source cleanliness, fresh-baseline provenance, and acceptance before ranking runs:

```bash
bash qdrant.sh benchmark-status --run-dir /path/to/run --require-ready --require-clean-baseline
bash qdrant.sh benchmark-acceptance --run-dir /path/to/run --require-accepted
bash qdrant.sh compare-benchmarks /path/to/run-a /path/to/run-b
```

For destructive profile A/B experiments, `benchmark-profiles` reinstalls each measured profile as a fresh disposable runtime and supports deterministic ordering/cycles to reduce order effects:

```bash
bash qdrant.sh benchmark-profiles \
  --profiles low-memory,balanced-memory \
  --points 100000 \
  --dimension 768 \
  --yes
```

### Source integrity and fresh-baseline provenance

`SOURCE-MANIFEST.json` defines the canonical public source set. You can verify that the working tree matches it before comparing results:

```bash
python3 scripts/source-integrity.py check \
  --root . \
  --manifest SOURCE-MANIFEST.json \
  --require-clean
```

Fresh benchmark workflows record provenance such as `fresh_baseline=1` and `baseline_origin=purge-all-test` so a result can distinguish a genuinely rebuilt runtime from an existing one. Generated benchmark archives are handled separately from canonical source identity; unknown unexpected source files still fail the clean-source gate.

### Resource telemetry correctness

Benchmark orchestration can continuously observe Linux `MemAvailable`, Qdrant/client RSS, swap, and cgroup signals. Summaries distinguish `CONTINUOUS` from `GAPPED` telemetry, record missing monitor time, and avoid treating unobserved time as observed memory pressure. Swap and Qdrant-zombie reporting use start/end/max/growth semantics so pre-existing host state is not automatically blamed on the benchmark.

See [benchmarks/README.md](benchmarks/README.md) for the detailed report schemas, status/acceptance rules, telemetry fields, and comparison workflow.

## Clean reinstall for benchmark/test validation

Normal `setup`, `start`, `restart`, and `cleanup` are **non-destructive** and preserve Qdrant data. For controlled benchmark validation only, the project includes an explicit destructive path that removes the entire managed runtime and installs again from an empty directory:

```bash
bash qdrant.sh reinstall-test
```

For automation after you have verified `BASE_DIR`:

```bash
bash qdrant.sh reinstall-test --yes
```

To delete the current runtime without immediately reinstalling:

```bash
bash qdrant.sh reset-test --yes
```

For disposable benchmark hosts where runtime/export paths differ by platform, use the host-wide project purge. It auto-discovers the current `BASE_DIR`, `.qdrant-base`, the platform default, managed project runtimes under narrow platform roots, and the benchmark export directory. Destructive operations use path/ownership recognition plus an **atomic fail-closed preflight**; an unknown non-empty candidate stops the purge before any recognized candidate is deleted rather than blindly trusting a configured path:

```bash
bash qdrant.sh purge-all-test --yes
```

To purge everything and reinstall Qdrant immediately:

```bash
bash qdrant.sh purge-all-test --yes --reinstall
```

For the strictest one-command benchmark baseline on Colab, Kaggle, Codespaces, CodeSandbox, or generic Linux:

```bash
bash run-fresh-qdrant-benchmarks.sh --yes
```

The fresh benchmark entrypoint first repairs a narrowly allowlisted set of stale source files that can remain when a newer source archive is extracted over an older tree, then validates canonical source integrity **before** deleting runtime data. Auto-repair is fail-closed: modified/missing canonical files or any unknown unexpected file stop the workflow without deleting source or runtime data. After a CLEAN check, it purges recognized project runtime/benchmark state and performs a fresh smart benchmark setup. The resulting benchmark metadata records `fresh_baseline=1` with `baseline_origin=purge-all-test`; `clean_reinstall=0` remains correct because the smart wrapper does not repeat the destructive reinstall. Destructive path validation remains fail-closed and the source repository itself is never removed. See [docs/RESET-REINSTALL.md](docs/RESET-REINSTALL.md).

## Important limitations

The project deliberately keeps a small set of real limitations instead of encoding platform-specific restrictions into the core design:

1. **Single node only.** HA, replication, distributed consensus, and cluster orchestration are outside this repository's scope.
2. **Storage matters.** Live database files should use suitable block/POSIX storage. Cloud/FUSE/object-backed mounts are better used for completed backups/snapshots; the Hugging Face adapter can automate this snapshot-persistence pattern.
3. **Ephemeral platforms remain ephemeral.** Colab/Kaggle runtime termination cannot be prevented by this project; export backups before losing the runtime.
4. **Public demo endpoints are not production ingress.** Quick Tunnel is for development/testing; Codespaces public ports are also explicitly exposed development endpoints.
5. **Rootless mode intentionally omits system integration.** Core Qdrant works without root, but the system Nginx proxy and service-user isolation require root.
6. **gRPC is local/advanced by default.** The project's optional single-port reverse proxy is REST-oriented.

See [docs/PLATFORMS.md](docs/PLATFORMS.md) for environment-specific behavior.

## Version policy

Qdrant `1.18.3` remains the default because it is the known-good baseline previously validated for this project. Test newer releases explicitly before changing the default:

```bash
QDRANT_VERSION=1.19.0 bash qdrant.sh setup
```

Snapshot important data before testing a new server version.

## Documentation map

| Need | Start here |
|---|---|
| Full capability/status overview | [Features & capability matrix](docs/FEATURES.md) |
| Setup and daily commands | [Usage](docs/USAGE.md) |
| Colab/Kaggle/Codespaces/CodeSandbox/Linux behavior | [Platforms](docs/PLATFORMS.md) |
| Docker, production policy, HF Spaces, Modal, Beam | [Single-node production](docs/PRODUCTION.md) |
| API keys, JWT RBAC, Strict Mode | [Security](docs/SECURITY.md) |
| Snapshot, backup, restore | [Snapshots & recovery](docs/SNAPSHOTS.md) |
| RAM/disk tuning | [Resource profiles](docs/PROFILES.md) |
| Dataset-aware profile advice | [Profile advisor](docs/PROFILE-ADVISOR.md) |
| Guarded destructive test workflows | [Clean reset/reinstall](docs/RESET-REINSTALL.md) |
| Benchmark methodology/results format | [Benchmarks](benchmarks/README.md) |
| cURL/Python/Node/Ruby clients | [Examples](examples/README.md) |

See the [full documentation index](docs/README.md) for the bilingual documentation tree.

## Repository checks

The repository includes regression coverage for portable/rootless modes, authorization and JWT behavior, benchmark settle/status/acceptance/comparison, source integrity, resource-monitor continuity, reinstall/purge guardrails, secret precedence, and release-package hygiene. Many of these tests exist because a concrete real-host or orchestration bug was previously reproduced and then locked down as a regression case.

```bash
bash tests/static-checks.sh
bash qdrant.sh security-check
```

GitHub Actions is the intended authoritative environment for ShellCheck in the public repository; local environments may not have the `shellcheck` binary installed.

## Community, support, and security

- Read [CONTRIBUTING.md](CONTRIBUTING.md) before proposing code or documentation changes.
- Use the structured GitHub issue forms for reproducible bugs, focused feature requests, and usage questions.
- See the [support guide](.github/SUPPORT.md) for support scope and the diagnostic information to provide.
- Report suspected vulnerabilities through [SECURITY.md](SECURITY.md), never through a public issue.
- Participation in project spaces is governed by the [Code of Conduct](.github/CODE_OF_CONDUCT.md).

Repository ownership for critical areas is declared in [`.github/CODEOWNERS`](.github/CODEOWNERS). Automated dependency maintenance is intentionally limited to GitHub Actions so Qdrant/client baseline changes continue to require explicit compatibility validation.

## License

MIT. See [LICENSE](LICENSE).
