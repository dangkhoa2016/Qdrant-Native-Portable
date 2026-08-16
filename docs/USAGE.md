# Detailed Usage Guide

> 🌐 Language / Ngôn ngữ: **English** | [Tiếng Việt](USAGE.vi.md)

This guide covers the portable workflow rather than assuming Google Colab.

## 1. Preflight

```bash
bash qdrant.sh doctor
bash qdrant.sh system-info
```

`doctor` checks Linux/architecture, RAM, writable storage, dependencies, mode privileges, secret/config permissions, and service health when installed.

## 2. Setup with automatic choices

```bash
# From the repository root
bash qdrant.sh setup
```

The sequence creates/loads credentials, prepares dependencies/runtime directories, downloads the native Qdrant binary, writes a secret-free config, starts Qdrant, verifies authentication, creates demo data, optionally configures Nginx in proxy mode, and runs health checks.

The public endpoint is **not** started by setup unless explicitly requested by configuration.

## 3. Deterministic setup

Rootless 8-GB VM/Codespaces:

```bash
QDRANT_PROFILE=balanced-memory \
PROCESS_MODE=current-user \
DEPLOYMENT_MODE=minimal \
bash qdrant.sh setup
```

Root/service-user + single-port proxy:

```bash
sudo -E env \
  PROCESS_MODE=service-user \
  DEPLOYMENT_MODE=proxy \
  QDRANT_PROFILE=balanced \
  bash qdrant.sh setup
```

## 4. Endpoints

Minimal mode:

```text
REST + Dashboard: http://127.0.0.1:6333
Dashboard:        http://127.0.0.1:6333/dashboard
```

Proxy mode:

```text
Qdrant internal:  http://127.0.0.1:6333
REST proxy:       http://127.0.0.1:9090
Dashboard:        http://127.0.0.1:9090/dashboard
```

Optional gRPC:

```text
127.0.0.1:6334
```

## 5. Status, logs and metrics

```bash
bash qdrant.sh status
bash qdrant.sh health
bash qdrant.sh system-info
bash qdrant.sh metrics
```

Runtime paths are shown in `system-info`. Typical logs:

```bash
tail -n 100 "$BASE_DIR/logs/qdrant.log"
tail -n 100 "$BASE_DIR/logs/cloudflared.log"
```

Management commands can recover the previous runtime path from the ignored `.qdrant-base` pointer. For client examples, simply run `source scripts/activate.sh`; it exports `BASE_DIR`, `QDRANT_URL`, and the runtime keys into the current shell without printing their values.

## 6. Credentials

```bash
bash qdrant.sh credentials status
```

To load keys for shell examples:

```bash
source scripts/activate.sh
```

For a new terminal, prefer `source scripts/activate.sh`; no manual BASE_DIR lookup is needed.

Prefer `QDRANT_READ_ONLY_API_KEY` for query-only applications. See [SECURITY.md](SECURITY.md) for rotation and scoped JWTs.

## 7. Raw REST example

Set the URL printed by health/system-info, for example:

```bash
export QDRANT_URL=http://127.0.0.1:6333
source scripts/activate.sh
```

Create:

```bash
curl -fsS -X PUT \
  -H "api-key: $QDRANT_API_KEY" \
  -H 'Content-Type: application/json' \
  "$QDRANT_URL/collections/books" \
  -d '{"vectors":{"size":4,"distance":"Cosine"}}' | jq .
```

Upsert:

```bash
curl -fsS -X PUT \
  -H "api-key: $QDRANT_API_KEY" \
  -H 'Content-Type: application/json' \
  "$QDRANT_URL/collections/books/points?wait=true" \
  -d '{"points":[{"id":1,"vector":[0.9,0.1,0.1,0.1],"payload":{"title":"Book A"}}]}' | jq .
```

Query with the read-only key:

```bash
curl -fsS -X POST \
  -H "api-key: $QDRANT_READ_ONLY_API_KEY" \
  -H 'Content-Type: application/json' \
  "$QDRANT_URL/collections/books/points/query" \
  -d '{"query":[0.8,0.2,0.1,0.1],"limit":2,"with_payload":true}' | jq .
```

## 8. Bundled examples

```bash
bash qdrant.sh examples
```

Or run cURL/Python/Node/Ruby separately. See [../examples/README.md](../examples/README.md).

## 9. Public access

Start local services first:

```bash
bash qdrant.sh start
bash qdrant.sh public
```

On GitHub Codespaces, `auto` uses the platform forwarded port. On other supported defaults it can use a Cloudflare Quick Tunnel. Disable public exposure separately:

```bash
bash qdrant.sh public-stop
```

Public access does not remove Qdrant authentication requirements.

## 10. Start/stop/restart

```bash
bash qdrant.sh start
bash qdrant.sh stop
bash qdrant.sh restart
bash qdrant.sh status
```

`start` and `restart` return successfully only after the authenticated Qdrant REST API is ready. Process liveness and API readiness are separate states: if the PID file identifies a live process but `/collections` is not reachable yet, the command keeps waiting instead of launching a duplicate process or reporting success. This commonly happens while Qdrant loads or recovers existing collections after a cold start, but the bounded wait also protects callers from a process that remains unready. Transient curl connection errors from readiness probes are suppressed.

The startup deadline is measured in wall-clock time and defaults to 300 seconds. Override it with a positive integer when a larger on-disk dataset needs more recovery time:

```bash
QDRANT_START_TIMEOUT_SECONDS=600 bash qdrant.sh start
```

Each readiness probe is capped by the time remaining before the deadline. If Qdrant exits before readiness, or if the deadline expires, the public `qdrant.sh` command returns non-zero, attempts to print the last 120 Qdrant log lines when available, and always reports the log path. To follow startup progress directly:

```bash
source scripts/activate.sh
tail -f "$BASE_DIR/logs/qdrant.log"
```

The pinned Qdrant release may log collection loading/recovery and HTTP-listener progress during startup. Regardless of the specific upstream log wording, a live recorded PID without a successful authenticated REST probe remains **not ready** until the probe succeeds, the process exits, or the deadline expires.

Code path for lifecycle reviews:

```text
qdrant.sh start
└── scripts/service-manager.sh        command dispatch + exit-status propagation
    └── scripts/05_start_qdrant.sh    PID/readiness/deadline state machine
        └── scripts/common.sh         runtime precedence + authenticated health probe
```

Keep these boundaries aligned when changing startup behavior: the start script owns waiting and diagnostics, while the service manager must preserve its success or failure for the public command.

The public ingress is intentionally separate.

## 11. Persisted runtime settings

Non-secret settings are stored in `$BASE_DIR/runtime.env`. Override them for a command with environment variables. Re-running setup persists the selected settings again.

Examples:

```bash
QDRANT_PROFILE=balanced bash qdrant.sh setup
QDRANT_ENABLE_GRPC=1 bash qdrant.sh setup
QDRANT_MAX_REQUEST_SIZE_MB=64 bash qdrant.sh setup
QDRANT_START_TIMEOUT_SECONDS=600 bash qdrant.sh setup
ENABLE_CORS=false bash qdrant.sh setup
```

`QDRANT_START_TIMEOUT_SECONDS` defaults to `300` and must contain a positive base-10 integer without a sign, fraction, or leading zero. It follows the same precedence rule as other persisted runtime settings: an explicit environment value wins for the current command. Running setup with a new value writes it to `runtime.env` for later lifecycle commands.

## 12. Backup and recovery

```bash
bash qdrant.sh snapshots create-collection portable_demo
bash qdrant.sh backup collection portable_demo /path/to/durable-backups
bash qdrant.sh backup full /path/to/durable-backups
```

See [SNAPSHOTS.md](SNAPSHOTS.md).

## 13. Benchmark a constrained host

```bash
bash qdrant.sh benchmark --points 10000 --dimension 768
```

Then inspect:

```bash
bash qdrant.sh system-info
bash qdrant.sh metrics
```

For 8-GB Codespaces, `auto` now selects `balanced-memory`. Use `profile-advisor` when you know the expected collection size, and compare profiles with a clean reinstall only for disposable A/B benchmark instances.


## Dataset-aware profile advice

```bash
bash qdrant.sh profile-advisor --points 100000 --dimension 768
```

The advisor is read-only: it does not rewrite config or restart Qdrant.

## Benchmark suite

```bash
bash qdrant.sh benchmark-suite
# quick smoke test
bash qdrant.sh benchmark-suite --quick
```

See `benchmarks/README.md` / `benchmarks/README.vi.md` for repeat, warm-up, settle, and percentile details.

## 14. Clean test reinstall

Normal cleanup preserves data:

```bash
bash qdrant.sh cleanup
```

For a disposable benchmark/test instance only, remove the complete managed runtime and install from scratch:

```bash
bash qdrant.sh reinstall-test
# non-interactive after verifying BASE_DIR
bash qdrant.sh reinstall-test --yes
```

Use `reset-test --yes` to remove the runtime without reinstalling. A missing or empty `BASE_DIR` is a safe fresh target and does not require a marker; older non-empty pre-marker Qdrant runtimes require `--force-unmanaged`. See [RESET-REINSTALL.md](RESET-REINSTALL.md).

## 15. Comparable smart benchmark

For the standard portable validation flow:

```bash
BENCHMARK_REQUIRE_CLEAN_SOURCE=1 \
CLEAN_REINSTALL=1 \
bash run-smart-qdrant-benchmarks.sh
```

For CI/automation that must reject provisional/incomplete suites:

```bash
BENCHMARK_REQUIRE_READY=1 \
BENCHMARK_REQUIRE_CLEAN_SOURCE=1 \
CLEAN_REINSTALL=1 \
bash run-smart-qdrant-benchmarks.sh
```

The result ZIP includes `benchmark-status.json`, `benchmark-acceptance.json`, `source-integrity.json`, and continuous resource-monitor files. If old result archives such as `qdrant-benchmarks-*.zip` or `profile-ab-*.zip` were copied into the project tree, source integrity keeps the run `CLEAN` and records those paths in `ignored_generated_files`; real source changes are still rejected. See [../benchmarks/README.md](../benchmarks/README.md).
