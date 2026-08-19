## Summary

Describe the problem and the change concisely.

## Validation

List the commands, tests, real-host checks, or provider evidence you ran. Do not claim real-provider validation unless the evidence actually came from that provider.

## Impact

- [ ] The change is focused and avoids unrelated refactoring.
- [ ] Relevant regression coverage was added or updated when behavior changed.
- [ ] `python3 scripts/source-integrity.py manifest --root . --output SOURCE-MANIFEST.json` was run after canonical source changes.
- [ ] `python3 scripts/source-integrity.py check --root . --manifest SOURCE-MANIFEST.json --require-clean` passes.
- [ ] `bash tests/static-checks.sh` passes.
- [ ] `bash tests/test-release-package.sh` was run when release packaging, source integrity, or public-source contents changed.
- [ ] User-facing English and Vietnamese documentation were updated together when applicable.
- [ ] No credentials, private URLs, sensitive runtime state, private snapshots, logs, PIDs, sockets, or generated tokens are included.
- [ ] Native/rootless, Docker, persistence, security, provider, compatibility, benchmark, and release implications were considered where relevant.

## Additional notes

Call out breaking behavior, migration requirements, validation limitations, provider assumptions, benchmark comparability limitations, or follow-up work.
