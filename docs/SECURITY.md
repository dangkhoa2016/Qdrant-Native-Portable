# Security Guide

> 🌐 Language / Ngôn ngữ: **English** | [Tiếng Việt](SECURITY.vi.md)

## Threat model

This toolkit targets disposable or small single-node development/demo instances. Its security goals are to require authentication, bind services to loopback by default, reduce accidental secret leakage, make least-privilege access practical, and provide explicit rotation/recovery workflows.

It is not a production secret manager, VPC boundary, WAF, multi-tenant isolation layer, or HA platform.

## Secret and runtime state separation

Secrets live at:

```text
$BASE_DIR/secrets.env
```

Non-secret operational state lives at:

```text
$BASE_DIR/runtime.env
```

Both are mode `600`. API keys are not serialized into `qdrant.yaml`; Qdrant receives them through `QDRANT__SERVICE__*` environment variables at process startup.

Caller environment values override persisted values. This prevents an old secret/runtime file from silently replacing an intentionally supplied setting during rotation or testing.

## Keys

The default setup creates:

- an admin API key;
- a read-only API key;
- an optional alternate admin key only while staged rotation is active.

Normal status output masks key values. Reveal them only when required:

```bash
bash scripts/show_credentials.sh --reveal
```

Never put revealed output in `tee` logs, screenshots, GitHub issues, notebooks, or source code.

## Key rotation

Read-only:

```bash
bash qdrant.sh credentials rotate-readonly --restart
```

Staged admin rotation:

```bash
bash qdrant.sh credentials stage-admin-rotation --restart
# move clients to the alternate key
bash qdrant.sh credentials promote-admin-rotation --restart
```

For disposable environments you can replace both immediately:

```bash
bash qdrant.sh credentials rotate-all --restart
```

## JWT RBAC

JWT RBAC is disabled by default. Enable it explicitly:

```bash
bash qdrant.sh credentials jwt-enable --restart
```

Generate a collection-scoped read token:

```bash
bash qdrant.sh credentials create-token \
  --scope fairy_tales:r \
  --ttl 3600
```

Generate a token that can write only one collection:

```bash
bash qdrant.sh credentials create-token \
  --scope demo_app:rw \
  --ttl 900
```

Multiple `--scope` options are supported. Global `--access r` and `--access m` are also available for advanced use.

The helper signs HS256 JWTs with the Qdrant admin API key and saves them under `$BASE_DIR/tokens/` with mode `600`. Therefore rotating/promoting the admin API key invalidates tokens signed with the previous key; issue new tokens after rotation.

JWT RBAC is useful for scoped demos and service separation, but do not hand the admin API key to untrusted code merely so that code can mint tokens.

## Strict Mode

`QDRANT_STRICT_MODE=1` is enabled by default for newly created collections. The generated collection defaults limit expensive query behavior such as query result size, timeout, HNSW `ef`, exact search, oversampling, and unindexed filtering according to the values in `.env.example`.

Strict Mode is a resource guardrail, not a substitute for authentication, authorization, rate limiting, or network controls.

## Network modes

Qdrant REST binds loopback by default:

```text
127.0.0.1:6333
```

In proxy mode, Nginx also binds loopback by default:

```text
127.0.0.1:9090
```

Public exposure is always opt-in. `bash qdrant.sh start` does not publish the database.

GitHub Codespaces `PUBLIC_MODE=platform` changes the selected forwarded port to public visibility. `bash qdrant.sh public-stop` attempts to make it private again.

Cloudflare Quick Tunnel is a development/testing ingress. Do not treat a temporary public URL as a stable production endpoint.

## TLS and CORS

Local loopback traffic is HTTP. Remote access should terminate TLS at the platform/tunnel/reverse proxy. Never transmit API keys over an untrusted plaintext network.

CORS is disabled by default. Enable it only when a browser on another origin truly must call Qdrant directly:

```bash
ENABLE_CORS=true bash qdrant.sh setup
```

A backend-to-Qdrant connection does not need browser CORS.

## Request size and public demos

`QDRANT_MAX_REQUEST_SIZE_MB` controls the Qdrant service request limit and, in proxy mode, the corresponding Nginx body limit. Keep it conservative for public demos.

For stronger public-demo protection, add ingress rate limiting or authentication in front of Qdrant. This project deliberately does not pretend API keys + Strict Mode provide a complete Internet-facing production security perimeter.

## Rootless versus service-user

`current-user` mode avoids root and system integration. It is portable but does not add a separate OS account boundary around Qdrant.

`service-user` mode runs Qdrant as a dedicated non-login account and requires root. Use it when OS-level isolation is valuable and the environment permits it.

## Security checks

Repository checks:

```bash
bash tests/static-checks.sh
```

Configured runtime checks:

```bash
bash qdrant.sh security-check
bash qdrant.sh doctor
```

Always inspect staged changes before a public push.

## If a credential leaks

1. Treat the leaked key/token as compromised.
2. Rotate the corresponding API key or revoke it by rotation.
3. Restart Qdrant when API-key environment changes.
4. Re-issue JWTs if the admin signing key changed.
5. Update clients.
6. Remove the secret from Git history if committed; a later deletion is insufficient.
7. Inspect logs, notebooks, screenshots, release archives, and pasted examples for the same value.

## Resource guardrails for public/demo use

Strict Mode defaults include query/timeout/HNSW limits plus two Qdrant 1.18 guardrails that are useful on constrained hosts:

```text
QDRANT_STRICT_MAX_RESIDENT_MEMORY_PERCENT=85
QDRANT_STRICT_SEARCH_MAX_BATCHSIZE=64
```

The first can reject memory-consuming writes after Qdrant resident memory crosses the configured percentage of total system RAM; the second caps batch-search size. Tune them for your workload rather than disabling authentication or resource protection.
