# Features & capability matrix

> 🌐 Language / Ngôn ngữ: **English** | [Tiếng Việt](FEATURES.vi.md)

This page is the **public capability overview** for Qdrant Native Portable `1.0.0`. It summarizes what the repository already provides and links to the specialist documentation that remains the source of truth for configuration details.

The project is **native-first, Docker-capable, and intentionally single-node**. It is designed for notebooks, development workspaces, constrained Linux hosts, integration environments, and production-oriented single-node deployments.

## Status language

The tables below use four evidence levels so that "supported" does not imply the same maturity everywhere:

- **Supported** — implementation and documented workflow exist in the public source.
- **Regression-tested** — repository tests exercise the relevant behavior or packaging contract.
- **Real-host validated** — the native/runtime path has been exercised on the named hosted environment class.
- **Real-provider validated** — the provider lifecycle and persistence behavior have been exercised against the real provider with real Qdrant data.

These labels describe the project's evidence, not an SLA or a guarantee from Qdrant or the hosting provider.

## Capability and platform matrix

| Environment / target | Runtime path | Storage / persistence model | Evidence level |
|---|---|---|---|
| Google Colab | Native, normally `service-user + proxy` | Ephemeral runtime; export/restore completed snapshots separately | Real-host validated |
| Kaggle Notebook | Native, root-aware `service-user/proxy` when available | Session/storage semantics depend on the notebook environment | Supported + regression-tested platform logic |
| GitHub Codespaces | Native rootless `current-user + minimal` | Workspace-lifecycle dependent | Real-host validated |
| CodeSandbox-like Linux VM | Native rootless `current-user + minimal` | Platform/VM-lifecycle dependent | Real-host validated |
| Generic Linux / VPS | Native | Live DB on compatible local/block POSIX storage | Supported + regression-tested production policy |
| Generic Docker host | Docker | Live DB on a compatible Docker volume/storage driver | Regression-tested Docker production path |
| Hugging Face Spaces | Docker | Local live DB + Bucket full snapshots | **Real-provider validated** |
| Modal.com | Docker | Local live DB + Modal Volume full snapshots | **Real-provider validated** |
| Beam.cloud | Docker | Local live DB + Beam Volume full snapshots | **Real-provider validated** |

For provider-specific configuration and limitations, use [Single-node production](PRODUCTION.md). For native environment defaults, use [Platforms](PLATFORMS.md).

## Production readiness matrix

| Target | Intended role | Persistence posture | Important boundary |
|---|---|---|---|
| Generic Linux/VPS | Production single-node | Compatible block/POSIX live storage | Operator owns host/storage durability |
| Generic Docker | Production single-node | Compatible Docker volume | Storage driver/filesystem must satisfy Qdrant requirements |
| Colab | Production-demo / development | Ephemeral unless snapshots are exported | Notebook termination remains outside project control |
| Kaggle | Production-demo / production-light | Notebook/session-storage dependent | Treat durable behavior as platform-dependent |
| Codespaces | Integration / production-demo | Workspace-lifecycle dependent | Public forwarding is development ingress |
| Hugging Face Spaces | Persistent production-demo / integration | Local live DB + Bucket full snapshots | **Real-provider validated** |
| Modal.com | Persistent production-demo / integration | Local live DB + Modal Volume full snapshots | **Real-provider validated** |
| Beam.cloud | Persistent production-demo / integration | Local live DB + Beam Volume full snapshots | **Real-provider validated** |

### Modal validation level

Modal has the strongest provider-specific evidence in this release. The real-provider validation exercised a fresh write, periodic full snapshots, natural scale-down, exit-hook Volume commit, fresh-container startup, newest-valid snapshot restore, collection recovery, and exact point/payload recovery. The configured periodic cadence is 600 seconds and defines the nominal durability RPO; shutdown snapshots are deliberately disabled because provider termination and exit hooks are concurrent.

The full operational contract is documented in [PRODUCTION.md](PRODUCTION.md#modalcom).

### Beam validation level

Beam is now real-provider validated for the documented single-node snapshot-persistence path, including recreation/restore, newest-valid selection, corrupt-newest fallback, all-corrupt fail-closed behavior, retention, and post-test recovery. See [PRODUCTION.md](PRODUCTION.md#beamcloud) for the provider-specific contract.

## Runtime and lifecycle capabilities

| Capability | Included | Notes / source of truth |
|---|---:|---|
| Native Qdrant without Docker | Yes | [Usage](USAGE.md), [Platforms](PLATFORMS.md) |
| Rootless/current-user operation | Yes | No `systemd`, `useradd`, or Nginx required in minimal mode |
| Optional service-user isolation | Yes | Used where root access makes it appropriate |
| Minimal direct REST mode | Yes | Normally `127.0.0.1:6333` |
| Optional Nginx proxy mode | Yes | Normally `127.0.0.1:9090` |
| Optional local gRPC | Yes | REST remains the default public workflow |
| Foreground production lifecycle | Yes | `production-check`, `prepare`, `serve` |
| Docker production runtime | Yes | Hardened single-node reference image/Compose path |
| Provider adapters | Yes | Hugging Face Spaces, Modal, Beam |
| Multiple Qdrant writers / autoscaled DB replicas | **No** | Deliberately outside the single-node topology |

## Persistence, snapshots, and recovery

Qdrant Native Portable separates **live database storage** from **portable durable snapshot storage**.

```text
Native / block-storage path
application
    ↓
Qdrant live DB
    ↓
compatible local/block POSIX filesystem

Snapshot-persist provider path
container-local live Qdrant DB
    ↓
completed full snapshot + SHA256
    ↓
durable provider storage
    ↓
cold-start checksum validation + restore
```

Included capabilities:

- collection and full-storage snapshot creation;
- portable backup/export with checksum and manifest information;
- checksum-aware restore selection;
- fail-closed behavior when persisted snapshot artifacts exist but none validate;
- corruption fallback to an older checksum-valid snapshot;
- automatic restore only when the live database directory is empty;
- retention controls for persisted full snapshots;
- snapshot-based persistence adapters for Hugging Face Spaces, Modal, and Beam.

Live Qdrant files should **not** be placed on arbitrary NFS, FUSE, S3/object-backed, or distributed mounts unless their filesystem semantics satisfy Qdrant's requirements. The provider adapters therefore keep the live database local and use durable provider storage for completed snapshots.

See [Snapshots & recovery](SNAPSHOTS.md) and [Single-node production](PRODUCTION.md).

## Security capabilities

Included security-oriented behavior:

- admin and read-only API keys;
- API keys injected into the process environment rather than written into `qdrant.yaml`;
- restricted secret-file permissions;
- masked credential output with explicit reveal behavior;
- staged admin-key rotation and read-only-key rotation;
- optional JWT RBAC with dependency-free scoped token generation;
- Strict Mode defaults for new collections;
- `auth-check` verification of unauthenticated/admin/read-only behavior;
- production secret policy that can require caller-injected secrets;
- result/evidence collectors that fail closed if current API-key values leak into collected files;
- public release scanning for credentials, runtime artifacts, concrete ephemeral tunnel URLs, and internal development markers.

See [Security](SECURITY.md) and the repository-level [SECURITY.md](../SECURITY.md).

## Resource-aware operation

Five resource profiles are included:

```text
low-memory
balanced-lite
balanced-memory
balanced
performance
```

The profiles control memory/disk trade-offs for vectors, HNSW, payloads, optimizer/search concurrency, and Low Memory Mode. Automatic selection uses host/cgroup memory, while explicit configuration always wins.

The `profile-advisor` adds workload-aware guidance using values such as point count and vector dimension instead of relying on host RAM alone.

See [Resource profiles](PROFILES.md) and [Profile advisor](PROFILE-ADVISOR.md).

## Diagnostics and benchmarking

The toolkit includes:

- `doctor`, `health`, `status`, `system-info`, `metrics`, `security-check`, and `auth-check`;
- platform, CPU, memory, cgroup, storage, and active-profile reporting;
- quick and full benchmark suites;
- separate client vector generation, JSON encoding, HTTP ingestion, and Qdrant processing timing;
- cold and warm query measurement;
- p50/p90/p95/p99, mean, maximum, and standard-deviation reporting;
- continuous resource telemetry including Qdrant RSS, Linux `MemAvailable`, swap growth, pressure time, and sampling-gap checks;
- bounded adaptive indexing/settle logic;
- explicit `READY`, `PROVISIONAL`, and other comparability states;
- cross-run and cross-profile comparison helpers;
- a one-command fresh-baseline benchmark workflow for disposable hosts.

See [Benchmarks](../benchmarks/README.md).

## Safe destructive test workflows

Normal lifecycle commands preserve data. Separate test-only workflows provide guarded destructive behavior:

- `reset-test`;
- `reinstall-test`;
- `purge-all-test`;
- `run-fresh-qdrant-benchmarks.sh --yes`.

They use ownership/path recognition, dangerous-path rejection, dry-run/preflight behavior, and fail-closed handling of unknown non-empty candidates. The source repository itself is protected from destructive cleanup.

See [Clean reset/reinstall](RESET-REINSTALL.md).

## Source integrity and release hygiene

The public repository includes:

- canonical `SOURCE-MANIFEST.json` source fingerprinting;
- detection of modified, missing, and unexpected source files;
- narrow source-overlay repair for known stale extracted-file cases;
- release packaging that excludes runtime state, logs, caches, credentials, snapshots, benchmark output, and local pointers;
- permission normalization in packaged archives;
- scans for internal development labels and concrete ephemeral tunnel endpoints;
- SHA256 generation and packaged-byte/source-integrity verification;
- GitHub Actions static/regression checks, with ShellCheck intended to run in hosted CI.

## Examples and documentation

Dependency-light examples are included for:

- cURL;
- Python;
- Node.js;
- Ruby.

English and Vietnamese documentation are maintained for the main usage, platform, production, security, snapshot, resource-profile, reset/reinstall, benchmark, and example workflows.

See [Examples](../examples/README.md) and the [Documentation index](README.md).

## What this project deliberately does not provide

Qdrant Native Portable `1.0.0` does **not** claim to provide:

- Qdrant cluster discovery or peer orchestration;
- HA, replication, distributed consensus, or automatic failover;
- multiple autoscaled Qdrant writers;
- a universal durable filesystem layer for every cloud provider;
- production TLS/load-balancing/identity infrastructure as a replacement for the hosting platform's ingress stack;
- a guarantee that ephemeral notebook/workspace providers will preserve a running session.

These are deliberate scope boundaries, not unfinished hidden cluster features.

## Documentation map

| Need | Read this |
|---|---|
| First setup and commands | [Usage](USAGE.md) |
| Native environment behavior | [Platforms](PLATFORMS.md) |
| Production/Docker/provider deployment | [Single-node production](PRODUCTION.md) |
| Keys, JWT, Strict Mode | [Security](SECURITY.md) |
| Backup, snapshots, restore | [Snapshots & recovery](SNAPSHOTS.md) |
| RAM/disk tuning | [Resource profiles](PROFILES.md) |
| Dataset-aware profile recommendation | [Profile advisor](PROFILE-ADVISOR.md) |
| Destructive test reset/reinstall | [Clean reset/reinstall](RESET-REINSTALL.md) |
| Benchmark methodology | [Benchmarks](../benchmarks/README.md) |
| Client examples | [Examples](../examples/README.md) |
