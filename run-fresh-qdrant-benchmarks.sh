#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJECT_DIR"

yes=0
dry_run=0
usage() {
    cat <<'EOF_USAGE'
Fresh destructive benchmark entrypoint

Usage:
  bash run-fresh-qdrant-benchmarks.sh --yes
  bash run-fresh-qdrant-benchmarks.sh --dry-run

This entrypoint is intentionally destructive. It:
  1. safely repairs ONLY known stale source-overlay files from older private revisions
  2. verifies canonical source integrity BEFORE deleting data
  3. auto-discovers and purges Qdrant Native Portable runtime data on this host
  4. removes old benchmark exports/generated benchmark archives
  5. launches the normal smart benchmark wrapper from a fresh runtime state

The same command is designed for Colab, Kaggle, GitHub Codespaces,
CodeSandbox, and generic Linux hosts.
EOF_USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --yes|-y) yes=1; shift ;;
        --dry-run) dry_run=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "ERROR: unknown option: $1" >&2; usage >&2; exit 1 ;;
    esac
done

if [[ "$dry_run" != "1" && "$yes" != "1" ]]; then
    echo "ERROR: destructive fresh benchmark requires --yes (or use --dry-run)" >&2
    exit 1
fi

printf '\n========== Safe source-overlay repair ==========\n'
if [[ "$dry_run" == "1" ]]; then
    python3 "$PROJECT_DIR/scripts/source-integrity.py" repair-overlay \
      --root "$PROJECT_DIR" \
      --manifest "$PROJECT_DIR/SOURCE-MANIFEST.json"
else
    python3 "$PROJECT_DIR/scripts/source-integrity.py" repair-overlay \
      --root "$PROJECT_DIR" \
      --manifest "$PROJECT_DIR/SOURCE-MANIFEST.json" \
      --apply
fi

printf '\n========== Preflight canonical source integrity ==========\n'
if [[ "$dry_run" == "1" ]]; then
    # repair-overlay already refuses modified/missing/unknown files. In dry-run
    # mode a recognized overlay remains physically DIRTY by design, so show
    # the check without requiring CLEAN and continue to purge dry-run only.
    python3 "$PROJECT_DIR/scripts/source-integrity.py" check \
      --root "$PROJECT_DIR" \
      --manifest "$PROJECT_DIR/SOURCE-MANIFEST.json"
else
    python3 "$PROJECT_DIR/scripts/source-integrity.py" check \
      --root "$PROJECT_DIR" \
      --manifest "$PROJECT_DIR/SOURCE-MANIFEST.json" \
      --require-clean
fi

printf '\n========== Full project data purge ==========\n'
if [[ "$dry_run" == "1" ]]; then
    bash "$PROJECT_DIR/qdrant.sh" purge-all-test --dry-run --yes
    exit 0
fi
bash "$PROJECT_DIR/qdrant.sh" purge-all-test --yes

printf '\n========== Fresh smart benchmark ==========\n'
# Runtime is now absent, so the smart wrapper will perform a normal fresh setup.
# CLEAN_REINSTALL describes only whether the smart wrapper itself runs
# reinstall-test. The parent purge already established a fresh baseline, so
# transmit that provenance explicitly instead of performing a second purge.
export CLEAN_REINSTALL=0
export BENCHMARK_FRESH_BASELINE=1
export BENCHMARK_BASELINE_ORIGIN=purge-all-test
export BENCHMARK_REQUIRE_CLEAN_SOURCE="${BENCHMARK_REQUIRE_CLEAN_SOURCE:-1}"
exec bash "$PROJECT_DIR/run-smart-qdrant-benchmarks.sh"
