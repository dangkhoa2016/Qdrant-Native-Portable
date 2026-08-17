# Contributing

> 🌐 Language / Ngôn ngữ: **English** | [Tiếng Việt](CONTRIBUTING.vi.md)

Contributions are welcome when they keep the project portable, understandable, and safe for public educational use.

## Design principles

- Keep Docker optional/outside the core: this repository demonstrates native Qdrant.
- Preserve `current-user + minimal` rootless operation.
- Do not make Colab/Codespaces/Kaggle assumptions part of the generic core when platform detection can isolate them.
- Never commit real credentials, runtime URLs, snapshots, logs, `runtime.env`, or generated tokens.
- Prefer environment-variable configuration and stable, documented defaults.
- Keep EN/VI documentation synchronized when changing user-facing workflows.

## Before opening a pull request

```bash
bash tests/static-checks.sh
```

When you have a configured local runtime, also run:

```bash
bash qdrant.sh doctor
bash qdrant.sh security-check
bash qdrant.sh health
```

For changes to resource profiles, include a reproducible benchmark command and the relevant host information from:

```bash
bash qdrant.sh system-info
```

Do not include revealed API keys or private data in benchmark logs/issues.
