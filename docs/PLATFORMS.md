# Platform and Deployment Modes

> 🌐 Language / Ngôn ngữ: **English** | [Tiếng Việt](PLATFORMS.vi.md)

The project separates four decisions: **platform detection**, **process isolation**, **deployment topology**, and **public access**. Every automatic decision can be overridden with an environment variable.

## Auto-detection

Run:

```bash
bash qdrant.sh system-info
```

The detector recognizes Google Colab, Kaggle, GitHub Codespaces, common CodeSandbox-style Linux VMs, and generic Linux.

| Setting | Values |
|---|---|
| `PROCESS_MODE` | `auto`, `current-user`, `service-user` |
| `DEPLOYMENT_MODE` | `auto`, `minimal`, `proxy` |
| `PUBLIC_MODE` | `auto`, `cloudflare-quick`, `platform`, `none` |
| `QDRANT_PROFILE` | `auto`, `low-memory`, `balanced-lite`, `balanced-memory`, `balanced`, `performance` |

Explicit environment values override persisted runtime settings and auto-detection. If a hosted VM does not expose a stable provider marker, force the platform explicitly:

```bash
QDRANT_PLATFORM=codesandbox bash qdrant.sh system-info
QDRANT_PLATFORM=generic-linux bash qdrant.sh setup
```

Benchmark JSON records the final detected/overridden platform, profile, process mode, and deployment mode so results can be compared without guessing the runtime configuration. Profile auto-selection uses effective memory: the lower of visible host RAM and a finite cgroup memory limit. `system-info` prints both values.

## Rootless/current-user mode

Recommended for GitHub Codespaces, CodeSandbox-like VMs, and restricted Linux accounts:

```bash
PROCESS_MODE=current-user \
DEPLOYMENT_MODE=minimal \
bash qdrant.sh setup
```

Qdrant runs as the current account. The toolkit does not create a system user or write Nginx configuration. Local REST is normally `127.0.0.1:6333`.

## Service-user/proxy mode

Useful on Colab or disposable root environments:

```bash
PROCESS_MODE=service-user \
DEPLOYMENT_MODE=proxy \
bash qdrant.sh setup
```

Qdrant runs as a dedicated non-login account and Nginx exposes a loopback REST proxy on port `9090`. This mode requires root.

## GitHub Codespaces

A typical 8-GB Codespace uses `balanced-memory`, `current-user`, and `minimal`. The in-memory vector/HNSW profile is the proven default for this RAM class; `auto` normally reaches the same result.

```bash
bash qdrant.sh setup
bash qdrant.sh system-info
```

To make the forwarded Qdrant port public:

```bash
bash qdrant.sh public
```

The command uses GitHub CLI to change that forwarded port to public visibility. Reverse it with:

```bash
bash qdrant.sh public-stop
```

Organization policy can forbid public ports. If publishing fails, keep the port private or use an allowed ingress method.

## Google Colab and Kaggle

When root is available, `auto` keeps the original service-user + Nginx proxy topology. Active storage belongs on local runtime storage. Export completed snapshots to durable storage before an ephemeral runtime is destroyed.

## CodeSandbox-like VMs

These environments vary. The safest portable baseline is:

```bash
PROCESS_MODE=current-user \
DEPLOYMENT_MODE=minimal \
PUBLIC_MODE=cloudflare-quick \
bash qdrant.sh setup
```

If the platform provides its own authenticated port forwarding, prefer it over an extra public tunnel.

## Generic Linux

Root is not required for the core database. `current-user + minimal` is the least invasive mode. Use `service-user + proxy` only when you intentionally want system integration and have root privileges.

## Runtime state

Non-secret operational choices are persisted to:

```text
$BASE_DIR/runtime.env
```

Secrets are kept separately in:

```text
$BASE_DIR/secrets.env
```

The repository-local `.qdrant-base` pointer remembers which external runtime directory was last configured. It is ignored by Git and contains no credential.
