#!/usr/bin/env bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

make_report() {
  local path="$1" status="$2"
  mkdir -p "$(dirname "$path")"
  printf '{"schema_version":3,"suite_status":"%s","results":[]}\n' "$status" > "$path"
}
make_clean_integrity() {
  cat > "$1" <<'EOF'
{"integrity_status":"CLEAN","canonical_sha256":"abc","working_tree_sha256":"abc","modified_files":[],"missing_files":[],"unexpected_files":[]}
EOF
}

run="$tmp/ready"
mkdir -p "$run"
cat > "$run/run-metadata.txt" <<'EOF'
clean_reinstall=1
full_suite=1
EOF
make_report "$run/quick-suite/benchmark-report.json" READY
make_report "$run/full-suite/benchmark-report.json" READY
make_clean_integrity "$run/source-integrity.json"
bash "$PROJECT_DIR/scripts/benchmark-status.sh" --run-dir "$run" --json-output "$run/status.json" --require-ready
python3 - "$run/status.json" <<'PY'
import json, sys
x=json.load(open(sys.argv[1]))
assert x['overall_status']=='READY'
assert x['quick_status']=='READY'
assert x['full_status']=='READY'
assert x['source_integrity']=='CLEAN'
assert x['comparability']=='CLEAN_BASELINE'
assert x['ready_for_ranking'] is True
PY

run="$tmp/fresh-ready"
mkdir -p "$run"
cat > "$run/run-metadata.txt" <<'EOF'
clean_reinstall=0
fresh_baseline=1
baseline_origin=purge-all-test
full_suite=1
EOF
make_report "$run/quick-suite/benchmark-report.json" READY
make_report "$run/full-suite/benchmark-report.json" READY
make_clean_integrity "$run/source-integrity.json"
bash "$PROJECT_DIR/scripts/benchmark-status.sh" --run-dir "$run" --json-output "$run/status.json" --require-ready --require-clean-baseline
python3 - "$run/status.json" <<'PY'
import json, sys
x=json.load(open(sys.argv[1]))
assert x['overall_status']=='READY'
assert x['clean_reinstall'] is False
assert x['fresh_baseline'] is True
assert x['baseline_origin']=='purge-all-test'
assert x['comparability']=='CLEAN_BASELINE'
assert x['ready_for_ranking'] is True
PY

run="$tmp/fresh-provisional"
mkdir -p "$run"
cat > "$run/run-metadata.txt" <<'EOF'
clean_reinstall=0
fresh_baseline=1
baseline_origin=purge-all-test
full_suite=1
EOF
make_report "$run/quick-suite/benchmark-report.json" READY
make_report "$run/full-suite/benchmark-report.json" PROVISIONAL
make_clean_integrity "$run/source-integrity.json"
bash "$PROJECT_DIR/scripts/benchmark-status.sh" --run-dir "$run" --json-output "$run/status.json" --require-clean-baseline
python3 - "$run/status.json" <<'PY'
import json, sys
x=json.load(open(sys.argv[1]))
assert x['overall_status']=='PROVISIONAL'
assert x['fresh_baseline'] is True
assert x['baseline_origin']=='purge-all-test'
assert x['comparability']=='CLEAN_BASELINE'
assert x['ready_for_ranking'] is False
PY

run="$tmp/fresh-dirty"
mkdir -p "$run"
cat > "$run/run-metadata.txt" <<'EOF'
clean_reinstall=0
fresh_baseline=1
baseline_origin=purge-all-test
full_suite=0
EOF
make_report "$run/quick-suite/benchmark-report.json" READY
cat > "$run/source-integrity.json" <<'EOF'
{"integrity_status":"DIRTY","canonical_sha256":"abc","working_tree_sha256":"def","modified_files":["qdrant.sh"]}
EOF
bash "$PROJECT_DIR/scripts/benchmark-status.sh" --run-dir "$run" --json-output "$run/status.json"
python3 - "$run/status.json" <<'PY'
import json, sys
x=json.load(open(sys.argv[1]))
assert x['fresh_baseline'] is True
assert x['comparability']=='DIRTY_SOURCE'
assert x['ready_for_ranking'] is False
PY

run="$tmp/fresh-origin-missing"
mkdir -p "$run"
cat > "$run/run-metadata.txt" <<'EOF'
clean_reinstall=0
fresh_baseline=1
full_suite=0
EOF
make_report "$run/quick-suite/benchmark-report.json" READY
make_clean_integrity "$run/source-integrity.json"
set +e
bash "$PROJECT_DIR/scripts/benchmark-status.sh" --run-dir "$run" --json-output "$run/status.json" --require-clean-baseline
rc=$?
set -e
[[ "$rc" == "4" ]] || { echo "FAIL: missing baseline origin unexpectedly accepted rc=$rc" >&2; exit 1; }
python3 - "$run/status.json" <<'PY'
import json, sys
x=json.load(open(sys.argv[1]))
assert x['fresh_baseline'] is None
assert x['baseline_origin'] is None
assert x['comparability']=='UNVERIFIED'
assert x['ready_for_ranking'] is False
PY

run="$tmp/provisional"
mkdir -p "$run"
cat > "$run/run-metadata.txt" <<'EOF'
clean_reinstall=1
full_suite=1
EOF
make_report "$run/quick-suite/benchmark-report.json" READY
make_report "$run/full-suite/benchmark-report.json" PROVISIONAL
make_clean_integrity "$run/source-integrity.json"
set +e
bash "$PROJECT_DIR/scripts/benchmark-status.sh" --run-dir "$run" --json-output "$run/status.json" --require-ready
rc=$?
set -e
[[ "$rc" == "2" ]] || { echo "FAIL: provisional --require-ready exit=$rc" >&2; exit 1; }
python3 - "$run/status.json" <<'PY'
import json, sys
x=json.load(open(sys.argv[1]))
assert x['overall_status']=='PROVISIONAL'
assert x['ready_for_ranking'] is False
PY

run="$tmp/missing"
mkdir -p "$run"
cat > "$run/run-metadata.txt" <<'EOF'
clean_reinstall=1
full_suite=1
full_suite_skipped_reason=memory-safety
EOF
make_report "$run/quick-suite/benchmark-report.json" READY
make_clean_integrity "$run/source-integrity.json"
set +e
bash "$PROJECT_DIR/scripts/benchmark-status.sh" --run-dir "$run" --json-output "$run/status.json" --require-ready
rc=$?
set -e
[[ "$rc" == "3" ]] || { echo "FAIL: skipped --require-ready exit=$rc" >&2; exit 1; }
python3 - "$run/status.json" <<'PY'
import json, sys
x=json.load(open(sys.argv[1]))
assert x['overall_status']=='SKIPPED_MEMORY'
assert x['full_status']=='SKIPPED_MEMORY'
PY

run="$tmp/existing"
mkdir -p "$run"
cat > "$run/run-metadata.txt" <<'EOF'
clean_reinstall=0
full_suite=0
EOF
make_report "$run/quick-suite/benchmark-report.json" READY
make_clean_integrity "$run/source-integrity.json"
bash "$PROJECT_DIR/scripts/benchmark-status.sh" --run-dir "$run" --json-output "$run/status.json" --require-ready
python3 - "$run/status.json" <<'PY'
import json, sys
x=json.load(open(sys.argv[1]))
assert x['overall_status']=='READY'
assert x['full_status']=='NOT_REQUESTED'
assert x['comparability']=='EXISTING_RUNTIME'
assert x['ready_for_ranking'] is False
PY

echo 'benchmark status tests passed'
