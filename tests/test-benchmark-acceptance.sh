#!/usr/bin/env bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
run="$tmp/run-codesandbox"
mkdir -p "$run/quick-suite" "$run/full-suite"
cat > "$run/run-metadata.txt" <<'META'
platform=codesandbox
memory_total_mb=4101
memory_effective_mb=4101
resource_profile=low-memory
clean_reinstall=0
fresh_baseline=1
baseline_origin=purge-all-test
full_suite=1
META
cat > "$run/source-integrity.json" <<'JSON'
{"integrity_status":"CLEAN","canonical_sha256":"abc","working_tree_sha256":"abc"}
JSON
cat > "$run/quick-suite/benchmark-report.json" <<'JSON'
{"suite_status":"READY","results":[{"points":10000,"dimension":768,"status":"READY"}]}
JSON
cat > "$run/full-suite/benchmark-report.json" <<'JSON'
{"suite_status":"READY","results":[{"points":100000,"dimension":768,"status":"READY","cold_p50_ms":780.0,"cold_p95_ms":1750.0,"warm_p50_ms":2.1,"warm_p95_ms":3.2,"http_ingestion_points_per_second_median":2300,"qdrant_peak_sampled_rss_kb":720896,"minimum_available_memory_mb":2750}]}
JSON
for f in system-info.log doctor.log health.log security-check.log; do printf 'ok\n' > "$run/$f"; done
cat > "$run/auth-check.log" <<'LOG'
✓ unauthenticated collection access is blocked (HTTP 401)
✓ admin API key can read collections
✓ read-only API key can read collections
✓ read-only API key is blocked from write operations (HTTP 403)
✓ runtime authorization check passed
LOG
printf 'timestamp,mem_total_mb\n' > "$run/resource-monitor.csv"
cat > "$run/resource-monitor-summary.json" <<'JSON'
{"samples":10,"telemetry_continuity":"GAPPED","sample_gap_events":1,"maximum_sample_gap_seconds":652,"missing_monitor_seconds":650,"host_pause_or_monitor_stall_suspected":true,"memory_pressure_duration_complete":false,"minimum_mem_available_mb":2600,"maximum_swap_used_mb":92.25,"swap_at_start_mb":92.25,"swap_at_end_mb":92.25,"swap_growth_mb":0,"swap_growth_events":0,"swap_present_samples":10,"maximum_qdrant_rss_mb":710,"qdrant_zombies_at_start":2,"qdrant_zombies_at_end":2,"maximum_qdrant_zombie_processes":2,"qdrant_zombie_growth":0,"pressure_samples":0,"pressure_event_count":0}
JSON

bash "$PROJECT_DIR/scripts/benchmark-acceptance.sh" --run-dir "$run" --json-output "$run/benchmark-acceptance.json" --markdown-output "$run/benchmark-acceptance.md" --require-accepted
python3 - "$run/benchmark-acceptance.json" <<'PY'
import json, sys
x=json.load(open(sys.argv[1]))
assert x['accepted_for_comparison'] is True, x
assert x['verdict']=='ACCEPTED_WITH_WARNINGS', x
assert x['status']['overall_status']=='READY'
assert x['status']['comparability']=='CLEAN_BASELINE'
assert x['status']['fresh_baseline'] is True
assert x['status']['baseline_origin']=='purge-all-test'
assert any('pre-existing' in w.lower() and 'zombie' in w.lower() and 'no zombie growth' in w.lower() for w in x['warnings']), x['warnings']
assert x['telemetry']['qdrant_zombies_at_start']==2
assert x['telemetry']['qdrant_zombies_at_end']==2
assert x['telemetry']['qdrant_zombie_growth']==0
assert any('pre-existing swap' in w.lower() for w in x['warnings']), x['warnings']
assert any('telemetry gap' in w.lower() for w in x['warnings']), x['warnings']
assert x['telemetry']['telemetry_continuity']=='GAPPED'
assert x['telemetry']['maximum_sample_gap_seconds']==652
assert x['telemetry']['host_pause_or_monitor_stall_suspected'] is True
assert not any(w.lower().startswith('continuous monitor observed swap growth') for w in x['warnings']), x['warnings']
assert x['missing_required_artifacts']==[]
PY

# A benchmark-window zombie increase must be called out as growth, even if the
# end count later returns to the original baseline.
python3 - "$run/resource-monitor-summary.json" <<'PY'
import json, sys
p=sys.argv[1]
x=json.load(open(p))
x.update({
    'qdrant_zombies_at_start': 2,
    'qdrant_zombies_at_end': 2,
    'maximum_qdrant_zombie_processes': 3,
    'qdrant_zombie_growth': 1,
})
open(p,'w').write(json.dumps(x))
PY
bash "$PROJECT_DIR/scripts/benchmark-acceptance.sh" --run-dir "$run" --json-output "$tmp/zombie-growth.json" --require-accepted
python3 - "$tmp/zombie-growth.json" <<'PY'
import json, sys
x=json.load(open(sys.argv[1]))
assert any('zombie growth of 1' in w.lower() for w in x['warnings']), x['warnings']
PY

# Historical summaries without baseline-aware fields remain readable and make
# the uncertainty explicit rather than guessing when the zombies appeared.
python3 - "$run/resource-monitor-summary.json" <<'PY'
import json, sys
p=sys.argv[1]
x=json.load(open(p))
for key in ('qdrant_zombies_at_start','qdrant_zombies_at_end','qdrant_zombie_growth'):
    x.pop(key, None)
x['maximum_qdrant_zombie_processes']=2
open(p,'w').write(json.dumps(x))
PY
bash "$PROJECT_DIR/scripts/benchmark-acceptance.sh" --run-dir "$run" --json-output "$tmp/legacy-zombies.json" --require-accepted
python3 - "$tmp/legacy-zombies.json" <<'PY'
import json, sys
x=json.load(open(sys.argv[1]))
assert any('legacy summary' in w.lower() and 'growth unknown' in w.lower() for w in x['warnings']), x['warnings']
PY

# Missing runtime authorization evidence must make the run incomplete even if
# the benchmark report itself says READY/CLEAN_BASELINE.
rm "$run/auth-check.log"
set +e
bash "$PROJECT_DIR/scripts/benchmark-acceptance.sh" --run-dir "$run" --json-output "$tmp/rejected.json" --require-accepted
rc=$?
set -e
[[ "$rc" -eq 5 ]]
python3 - "$tmp/rejected.json" <<'PY'
import json, sys
x=json.load(open(sys.argv[1]))
assert x['accepted_for_comparison'] is False
assert x['verdict']=='INCOMPLETE'
assert 'auth-check.log' in x['missing_required_artifacts']
PY

echo 'benchmark acceptance tests passed'
