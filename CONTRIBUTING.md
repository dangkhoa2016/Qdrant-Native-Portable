# Contributing

> 🌐 Language / Ngôn ngữ: **English** | [Tiếng Việt](CONTRIBUTING.vi.md)

Contributions are welcome when they keep Qdrant Native Portable portable, understandable, security-conscious, and precise about what has actually been validated.

## Design principles

- Preserve the **native-first** core while keeping Docker and provider adapters as explicit, isolated deployment surfaces; Docker must not become a requirement for native workflows.
- Preserve rootless `current-user + minimal` operation.
- Keep Colab, Kaggle, Codespaces, generic Linux, Docker, and provider-specific assumptions behind clear platform/adapter boundaries.
- Treat live database storage and completed snapshot persistence as different concerns; do not claim a provider storage backend is safe for live Qdrant files without evidence.
- Never commit real credentials, private runtime URLs, snapshots containing private data, logs, `runtime.env`, `secrets.env`, or generated tokens.
- Prefer environment-variable configuration and stable, documented defaults.
- Keep English and Vietnamese user-facing documentation synchronized.
- Match validation claims to evidence: regression-tested, real-host validated, and real-provider validated are not interchangeable.

## Before opening a pull request

Run the canonical source and static checks:

```bash
python3 scripts/source-integrity.py check --root . --manifest SOURCE-MANIFEST.json --require-clean
bash tests/static-checks.sh
```

When you have a configured local runtime, also run:

```bash
bash qdrant.sh doctor
bash qdrant.sh security-check
bash qdrant.sh health
```

For release packaging, source-integrity, or public-source changes, also run:

```bash
bash tests/test-release-package.sh
```

For resource-profile changes, include a reproducible benchmark command and relevant host information from `bash qdrant.sh system-info`. For native lifecycle, PID handling, readiness, or service-manager changes, run `bash tests/test-start-readiness.sh` as well.

Provider-persistence changes should include the strongest evidence actually available for that provider and must preserve fail-closed restore/corruption behavior where documented.

Do not include revealed API keys, provider secrets, private URLs, or private data in tests, benchmark artifacts, issues, or pull requests.
