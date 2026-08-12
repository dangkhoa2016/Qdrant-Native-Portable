#!/usr/bin/env bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
script="$PROJECT_DIR/run-fresh-qdrant-benchmarks.sh"
[[ -f "$script" ]] || { echo 'run-fresh-qdrant-benchmarks.sh missing' >&2; exit 1; }
bash -n "$script"
python3 - "$script" <<'PY'
import sys
s=open(sys.argv[1], encoding='utf-8').read()
for token in ['source-integrity.py', 'repair-overlay', '--require-clean', 'purge-all-test', '--yes', 'BENCHMARK_FRESH_BASELINE', 'BENCHMARK_BASELINE_ORIGIN', 'run-smart-qdrant-benchmarks.sh']:
    assert token in s, token
assert s.index('repair-overlay') < s.index('--require-clean'), 'known overlay repair must happen before strict clean check'
assert s.index('--require-clean') < s.index('purge-all-test'), 'strict source check must happen before destructive purge'
purge_cmd='bash "$PROJECT_DIR/qdrant.sh" purge-all-test --yes'
assert purge_cmd in s
assert s.index(purge_cmd) < s.index('export BENCHMARK_FRESH_BASELINE=1'), 'fresh provenance must only be exported after successful purge command'
assert s.index('export BENCHMARK_FRESH_BASELINE=1') < s.rindex('run-smart-qdrant-benchmarks.sh'), 'fresh provenance must be exported before benchmark wrapper exec'
PY
set +e
bash "$script" >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" -ne 0 ]]
echo 'fresh benchmark wrapper tests passed'
