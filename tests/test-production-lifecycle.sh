#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail_test() { echo "production lifecycle test failed: $*" >&2; exit 1; }

grep -q 'production-check)' "$ROOT/qdrant.sh" || fail_test "qdrant.sh missing production-check command"
grep -q 'prepare)' "$ROOT/qdrant.sh" || fail_test "qdrant.sh missing prepare command"
grep -q 'serve)' "$ROOT/qdrant.sh" || fail_test "qdrant.sh missing serve command"
# shellcheck disable=SC2016
grep -q 'host: \$QDRANT_BIND_HOST' "$ROOT/scripts/04_configure_qdrant.sh" || fail_test "Qdrant bind host is still hard-coded"
grep -q 'QNP_CREATE_DEMO_DATA' "$ROOT/run_all.sh" || fail_test "run_all.sh does not gate demo data"
grep -q 'exec .*QDRANT_BIN' "$ROOT/scripts/production-serve.sh" || fail_test "production serve is not foreground exec"

echo "production lifecycle tests passed"
