# Security Policy

> 🌐 Language / Ngôn ngữ: **English** | [Tiếng Việt](SECURITY.vi.md)

## Reporting a vulnerability

Please do not publish credentials, exploit details, or sensitive runtime logs in a public issue. If the repository Security tab offers **Report a vulnerability**, use that private reporting flow. If it is not enabled, open only a non-sensitive issue asking the maintainer for a private contact channel; do not include exploit details or secrets in that issue.

## Secrets policy

This repository must never contain:

- real Qdrant API keys;
- concrete temporary tunnel URLs from a live session;
- `secrets.env` from a runtime;
- logs that include revealed credentials;
- downloaded database snapshots containing private data.

Run `bash tests/static-checks.sh` before publishing changes.

For deployment security guidance, see [docs/SECURITY.md](docs/SECURITY.md) and [docs/SECURITY.vi.md](docs/SECURITY.vi.md).
