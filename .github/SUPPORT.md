# Support

> 🌐 Language / Ngôn ngữ: **English** | [Tiếng Việt](SUPPORT.vi.md)

Qdrant Native Portable is maintained as an open-source single-node Qdrant runtime and deployment toolkit. Support is best-effort and is organized through GitHub issues.

## Where to ask

Use the repository issue forms for reproducible bugs, focused feature proposals, and usage questions not answered by the documentation. Before opening an issue, review [`../README.md`](../README.md), [`../docs/README.md`](../docs/README.md), [`../docs/FEATURES.md`](../docs/FEATURES.md), [`../docs/PLATFORMS.md`](../docs/PLATFORMS.md), and existing issues.

For runtime problems, include the project release/commit, Qdrant version, runtime mode, platform, resource profile, relevant command, expected behavior, actual behavior, and sanitized logs. Never include API keys, JWTs, provider credentials, private URLs, snapshots containing private data, `secrets.env`, token files, or other sensitive runtime state.

## Scope

The project targets single-node Qdrant for development, demos, integration testing, benchmarking, and production-oriented deployments where the documented single-node constraints are acceptable. It is not a managed hosting service and does not promise HA, replication, automatic failover, multi-writer autoscaling, or compatibility with every unvalidated Qdrant/provider combination.

## Security

Do not use a public support issue for a suspected vulnerability or accidental secret exposure. Follow [`../SECURITY.md`](../SECURITY.md).
