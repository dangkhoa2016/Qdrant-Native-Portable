# Test-only Clean Reset and Reinstall

> 🌐 Language / Ngôn ngữ: **English** | [Tiếng Việt](RESET-REINSTALL.vi.md)

Normal lifecycle commands are non-destructive. `setup`, `start`, `stop`, `restart`, and `cleanup` preserve database storage and snapshots.

Use the commands on this page only when you intentionally need a **clean test/benchmark runtime**.

## Full clean reinstall

```bash
bash qdrant.sh reinstall-test
```

The command stops project ingress/processes, removes the complete managed `BASE_DIR`, then executes setup again. It removes:

- Qdrant binary and downloaded archives;
- live storage and collections;
- snapshots and recovery backups;
- logs, PID files, temp/cache files;
- benchmark results;
- API-key/JWT runtime files;
- generated config and runtime settings;
- cloudflared binary stored under the project runtime.

It does **not** uninstall apt packages or remove the optional system service user.

## Reset without reinstall

```bash
bash qdrant.sh reset-test --yes
```

## Automation

`--yes` skips the interactive path confirmation, but safety checks still run:

```bash
bash qdrant.sh reinstall-test --yes
```

## Fresh, empty, and older runtimes

If `BASE_DIR` does not exist yet, or exists as a completely empty directory, the command treats it as a fresh target. There is no existing runtime data to authorize for deletion, so no instance marker and no `--force-unmanaged` flag are required. This is important for `CLEAN_REINSTALL=1` on a brand-new Colab/Kaggle/session.

New installs contain `$BASE_DIR/.qdrant-native-portable-instance`. An older non-empty runtime may not. If you have verified that `BASE_DIR` is truly the disposable Qdrant runtime, use:

```bash
bash qdrant.sh reinstall-test --force-unmanaged --yes
```

`--force-unmanaged` does not disable path safety checks; it only bypasses the missing project marker requirement after the directory is recognized as Qdrant-like.

## Purge all project data across platform-specific paths

For disposable benchmark machines where you do not want to manually remember the runtime/export location, use:

```bash
bash qdrant.sh purge-all-test --yes
```

The purge helper discovers the current resolved `BASE_DIR`, the local `.qdrant-base` pointer, the platform default runtime location, managed project runtimes under narrow platform roots, and the configured/default benchmark export root. Recognized runtime candidates are preflighted **before any deletion begins**. A single unknown non-empty directory aborts the entire purge.

The command removes Qdrant runtime data (binary, storage, snapshots, logs, credentials, config, downloads, temp/cache, tokens, recovery backups), external benchmark result artifacts, local runtime pointers, generated benchmark ZIPs, and Python cache files. It does not remove the source repository, OS packages, or the optional service user.

Preview the complete plan without changing anything:

```bash
bash qdrant.sh purge-all-test --dry-run
```

Purge and immediately reinstall:

```bash
bash qdrant.sh purge-all-test --yes --reinstall
```

If you have an additional explicit legacy/custom runtime that cannot be discovered from the current environment, add it without changing the normal platform logic:

```bash
bash qdrant.sh purge-all-test --yes --base-dir /absolute/path/to/runtime
```

The same extra candidates can be supplied non-interactively with a colon-separated environment variable:

```bash
QDRANT_PURGE_EXTRA_BASE_DIRS=/path/a:/path/b \
  bash qdrant.sh purge-all-test --yes
```

### One-command clean benchmark baseline

For ephemeral validation machines, the recommended destructive benchmark command is:

```bash
bash run-fresh-qdrant-benchmarks.sh --yes
```

It first requires canonical source integrity to be `CLEAN`, then executes the full project purge, and only then launches the standard smart benchmark wrapper. This ordering prevents a dirty source tree from destroying an otherwise useful runtime before the run is rejected.

## Profile A/B testing

Explicit environment variables survive the destructive reset and are used by the fresh setup:

```bash
QDRANT_PROFILE=balanced-lite bash qdrant.sh reinstall-test --yes
```

Without an explicit profile, the deleted `runtime.env` cannot influence the new install, so hardware/platform auto-detection is recomputed.

## Dry run

```bash
bash qdrant.sh reinstall-test --dry-run
```

The destructive helper refuses broad paths such as `/`, `$HOME`, `/content`, `/kaggle/working`, `/workspaces`, `/tmp`, `/etc`, `/usr`, and the source repository itself.
