#!/usr/bin/env bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
wrapper="$PROJECT_DIR/run-smart-qdrant-benchmarks.sh"

bash -n "$wrapper"
for token in \
  BENCHMARK_REQUIRE_CLEAN_SOURCE BENCHMARK_REQUIRE_READY RUN_AUTH_CHECK \
  BENCHMARK_FRESH_BASELINE BENCHMARK_BASELINE_ORIGIN fresh_baseline baseline_origin \
  source-integrity.py resource-monitor.sh benchmark-status.sh benchmark-acceptance.sh \
  ignored_generated_files 'Ignored generated artifact' 'Modified source file' \
  'full_suite_skipped_reason=memory-safety' 'memory_effective_mb='; do
  grep -Fq "$token" "$wrapper" || { echo "missing wrapper integration token: $token" >&2; exit 1; }
done

python3 - "$wrapper" <<'PY'
import re, sys
s=open(sys.argv[1]).read()
# Regression for the historical set -u bug: a local initializer must not
# reference another local variable declared in the same command.
assert not re.search(r'local\s+[^\n]*suite_dir=[^\n]*report="\$suite_dir', s)
assert 'available_after_quick="$(available_memory_mb)"' in s
assert 'FINAL_RC=' in s
assert 'base_dir_is_absent_or_empty' in s, 'fresh/empty BASE_DIR must bypass legacy marker gate'
PY

# Boolean validation must reject invalid strictness input before any runtime
# setup or destructive operation is attempted.
set +e
BENCHMARK_REQUIRE_READY=maybe bash "$wrapper" > /dev/null 2>&1
rc=$?
set -e
[[ "$rc" -eq 1 ]]

set +e
BENCHMARK_FRESH_BASELINE=1 BENCHMARK_BASELINE_ORIGIN=existing-runtime bash "$wrapper" > /dev/null 2>&1
rc=$?
set -e
[[ "$rc" -eq 1 ]]

set +e
BENCHMARK_FRESH_BASELINE=0 BENCHMARK_BASELINE_ORIGIN=purge-all-test bash "$wrapper" > /dev/null 2>&1
rc=$?
set -e
[[ "$rc" -eq 1 ]]



# Final-state metadata keys must be written exactly once. Historically these
# fields were emitted before setup/reinstall and then appended again.
python3 - "$wrapper" <<'PY'
import re, sys
s=open(sys.argv[1], encoding='utf-8').read()
for key in ('resource_profile', 'fresh_baseline', 'baseline_origin'):
    count=len(re.findall(rf'^{key}=\$[^\n]+$', s, flags=re.M))
    assert count == 1, (key, count)
PY

echo 'smart benchmark wrapper tests passed' 
