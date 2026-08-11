#!/usr/bin/env bash
set -Eeuo pipefail

# Smart, portable Qdrant benchmark orchestrator.
#
# Safe default: DOES NOT delete or reinstall Qdrant.
# Recommended clean/comparable run:
#   BENCHMARK_REQUIRE_CLEAN_SOURCE=1 CLEAN_REINSTALL=1 \
#     bash run-smart-qdrant-benchmarks.sh
#
# Optional strict readiness:
#   BENCHMARK_REQUIRE_READY=1 BENCHMARK_REQUIRE_CLEAN_SOURCE=1 \
#     CLEAN_REINSTALL=1 bash run-smart-qdrant-benchmarks.sh

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJECT_DIR"

[[ -f "$PROJECT_DIR/qdrant.sh" ]] || {
  echo "ERROR: qdrant.sh not found in $PROJECT_DIR" >&2
  exit 1
}
[[ -f "$PROJECT_DIR/scripts/common.sh" ]] || {
  echo "ERROR: scripts/common.sh not found" >&2
  exit 1
}

RUN_FULL="${RUN_FULL:-1}"
RUN_STATIC_CHECKS="${RUN_STATIC_CHECKS:-1}"
STATIC_CHECKS_FATAL="${STATIC_CHECKS_FATAL:-0}"
RUN_SECURITY_CHECK="${RUN_SECURITY_CHECK:-1}"
RUN_AUTH_CHECK="${RUN_AUTH_CHECK:-1}"
CLEAN_REINSTALL="${CLEAN_REINSTALL:-0}"
FORCE_UNMANAGED="${FORCE_UNMANAGED:-0}"
ALLOW_PROFILE_MISMATCH="${ALLOW_PROFILE_MISMATCH:-0}"
BENCHMARK_REQUIRE_CLEAN_SOURCE="${BENCHMARK_REQUIRE_CLEAN_SOURCE:-0}"
BENCHMARK_REQUIRE_READY="${BENCHMARK_REQUIRE_READY:-0}"
BENCHMARK_FRESH_BASELINE="${BENCHMARK_FRESH_BASELINE:-0}"
BENCHMARK_BASELINE_ORIGIN="${BENCHMARK_BASELINE_ORIGIN:-}"
RESOURCE_MONITOR_INTERVAL="${RESOURCE_MONITOR_INTERVAL:-2}"
FULL_REPEAT="${FULL_REPEAT:-3}"
FULL_QUERIES="${FULL_QUERIES:-50}"
FULL_COLD_QUERIES="${FULL_COLD_QUERIES:-20}"
FULL_WARMUP="${FULL_WARMUP:-$FULL_QUERIES}"
BATCH_SIZE="${BATCH_SIZE:-128}"
STABLE_POLLS="${STABLE_POLLS:-3}"

for flag in RUN_FULL RUN_STATIC_CHECKS STATIC_CHECKS_FATAL RUN_SECURITY_CHECK RUN_AUTH_CHECK CLEAN_REINSTALL FORCE_UNMANAGED ALLOW_PROFILE_MISMATCH BENCHMARK_REQUIRE_CLEAN_SOURCE BENCHMARK_REQUIRE_READY BENCHMARK_FRESH_BASELINE; do
  value="${!flag}"
  [[ "$value" == "0" || "$value" == "1" ]] || {
    echo "ERROR: $flag must be 0 or 1 (got: $value)" >&2
    exit 1
  }
done
for n in FULL_REPEAT FULL_QUERIES BATCH_SIZE STABLE_POLLS; do
  value="${!n}"
  [[ "$value" =~ ^[1-9][0-9]*$ ]] || {
    echo "ERROR: $n must be a positive integer (got: $value)" >&2
    exit 1
  }
done
for n in FULL_COLD_QUERIES FULL_WARMUP; do
  value="${!n}"
  [[ "$value" =~ ^[0-9]+$ ]] || {
    echo "ERROR: $n must be a non-negative integer (got: $value)" >&2
    exit 1
  }
done
[[ "$RESOURCE_MONITOR_INTERVAL" =~ ^[0-9]+([.][0-9]+)?$ ]] || {
  echo "ERROR: RESOURCE_MONITOR_INTERVAL must be numeric" >&2
  exit 1
}

if [[ "$BENCHMARK_FRESH_BASELINE" == "1" ]]; then
  [[ "$BENCHMARK_BASELINE_ORIGIN" == "purge-all-test" ]] || {
    echo "ERROR: BENCHMARK_FRESH_BASELINE=1 requires BENCHMARK_BASELINE_ORIGIN=purge-all-test" >&2
    exit 1
  }
else
  [[ -z "$BENCHMARK_BASELINE_ORIGIN" || "$BENCHMARK_BASELINE_ORIGIN" == "existing-runtime" ]] || {
    echo "ERROR: baseline origin '$BENCHMARK_BASELINE_ORIGIN' requires BENCHMARK_FRESH_BASELINE=1" >&2
    exit 1
  }
  BENCHMARK_BASELINE_ORIGIN="existing-runtime"
fi
fresh_baseline="$BENCHMARK_FRESH_BASELINE"
baseline_origin="$BENCHMARK_BASELINE_ORIGIN"

# shellcheck disable=SC1091
source "$PROJECT_DIR/scripts/common.sh"

mem_total_mb="$(total_memory_mb)"
mem_effective_mb="$(effective_memory_mb)"
mem_effective_source="$(effective_memory_source)"
mem_available_mb="$(available_memory_mb)"
cpu_threads="$(getconf _NPROCESSORS_ONLN 2>/dev/null || nproc 2>/dev/null || echo 1)"
expected_profile="$(default_profile)"
current_profile="$QDRANT_PROFILE"

utc_stamp="$(date -u +%Y%m%dT%H%M%SZ)"
safe_platform="$(printf '%s' "$PLATFORM" | tr -cs 'A-Za-z0-9._-' '-')"
OUTPUT_ROOT="${QDRANT_BENCHMARK_EXPORT_DIR:-${HOME:-/tmp}/qdrant-benchmark-exports}"
RUN_DIR="$OUTPUT_ROOT/run-${safe_platform}-${mem_total_mb}mb-${utc_stamp}"
mkdir -p "$RUN_DIR"
RUN_LOG="$RUN_DIR/orchestrator.log"
exec > >(tee -a "$RUN_LOG") 2>&1

section() { printf '\n========== %s ==========\n' "$1"; }
info() { printf '[INFO] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

capture() {
  local name="$1"
  shift
  section "$name"
  "$@" 2>&1 | tee "$RUN_DIR/${name// /-}.log"
  return "${PIPESTATUS[0]}"
}

print_source_integrity_details() {
  local report="$1"
  python3 - "$report" <<'PYREPORT'
import json
import sys

report = json.load(open(sys.argv[1], encoding="utf-8"))
for path in report.get("modified_files", []):
    print(f"[ERROR] Modified source file: {path}", file=sys.stderr)
for path in report.get("missing_files", []):
    print(f"[ERROR] Missing canonical source file: {path}", file=sys.stderr)
for path in report.get("unexpected_files", []):
    print(f"[ERROR] Unexpected source file: {path}", file=sys.stderr)
ignored = report.get("ignored_generated_files", [])
if ignored:
    print(f"[INFO] Ignored generated artifacts: {len(ignored)}")
    for path in ignored:
        print(f"[INFO] Ignored generated artifact: {path}")
PYREPORT
}


diagnose_local_runtime_artifacts() {
  local out="$RUN_DIR/local-runtime-artifacts.txt"
  {
    echo "# Local/generated files that may make repository static checks fail after setup"
    echo "# These are diagnostic only and do not imply Qdrant runtime failure."
    find "$PROJECT_DIR" -maxdepth 3 \( \
      -type d \( -name node_modules -o -name __pycache__ -o -name .venv \) -o \
      -type f \( -name '.qdrant-initialized' -o -name '.qdrant-base' -o -name '.qdrant-native-portable-instance' -o -name 'runtime.env' -o -name 'secrets.env' -o -name '*.pyc' -o \
                   -name 'qdrant-benchmarks-*.zip' -o -name 'qdrant-benchmarks-*.zip.sha256' -o \
                   -name 'profile-ab-*.zip' -o -name 'profile-ab-*.zip.sha256' \) \
    \) -print 2>/dev/null || true
  } > "$out"
  if [[ $(wc -l < "$out") -gt 2 ]]; then
    warn "Static-check diagnostics saved to: $out"
    sed -n '3,80p' "$out" | sed 's/^/[WARN] local artifact: /' >&2
  fi
}

latest_suite_dir() {
  find "$QDRANT_BENCHMARKS" -mindepth 1 -maxdepth 1 -type d -name 'suite-*' -printf '%T@ %p\n' 2>/dev/null \
    | sort -n | tail -1 | cut -d' ' -f2-
}

# Keep declarations split: under `set -u`, referencing a local variable in the
# same `local` command that declares it can trigger an unbound-variable bug.
copy_suite() {
  local label="$1"
  local suite_dir="$2"
  [[ -n "$suite_dir" && -d "$suite_dir" ]] || return 0
  rm -rf "${RUN_DIR:?}/$label"
  cp -a "$suite_dir" "$RUN_DIR/$label"
  info "Copied $label results: $suite_dir"
}

package_results() {
  local archive="$OUTPUT_ROOT/qdrant-benchmarks-${safe_platform}-${mem_total_mb}mb-${utc_stamp}.zip"
  mkdir -p "$OUTPUT_ROOT"
  rm -f "$archive" "$archive.sha256"
  if command -v zip >/dev/null 2>&1; then
    (cd "$OUTPUT_ROOT" && zip -qr "$archive" "$(basename "$RUN_DIR")")
  elif command -v python3 >/dev/null 2>&1; then
    python3 - "$RUN_DIR" "$archive" <<'PY'
import os, sys, zipfile
src, dst = sys.argv[1], sys.argv[2]
base = os.path.dirname(src)
with zipfile.ZipFile(dst, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as z:
    for root, dirs, files in os.walk(src):
        dirs.sort(); files.sort()
        for name in files:
            path = os.path.join(root, name)
            z.write(path, os.path.relpath(path, base))
PY
  else
    die "Neither zip nor python3 is available to package benchmark results"
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    (cd "$(dirname "$archive")" && sha256sum "$(basename "$archive")" > "$(basename "$archive").sha256")
  fi
  RESULTS_PACKAGED=1
  info "RESULT ZIP: $archive"
  [[ -f "$archive.sha256" ]] && info "SHA256:     $archive.sha256"
}

RESOURCE_MONITOR_PID=""
start_resource_monitor() {
  section "Continuous resource monitor"
  bash "$PROJECT_DIR/scripts/resource-monitor.sh" \
    --output-dir "$RUN_DIR" \
    --interval "$RESOURCE_MONITOR_INTERVAL" \
    > "$RUN_DIR/resource-monitor-driver.log" 2>&1 &
  RESOURCE_MONITOR_PID=$!
  info "Resource monitor PID: $RESOURCE_MONITOR_PID"
}

stop_resource_monitor() {
  local pid="${RESOURCE_MONITOR_PID:-}"
  [[ -n "$pid" ]] || return 0
  if kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  fi
  RESOURCE_MONITOR_PID=""
  [[ -f "$RUN_DIR/resource-monitor-summary.json" ]] || warn "Resource monitor summary was not produced"
}

RESULTS_PACKAGED=0
FINAL_RC=0
on_exit() {
  local rc=$?
  set +e
  stop_resource_monitor
  if (( rc != 0 )); then
    warn "Benchmark orchestration stopped with exit code $rc"
    warn "Partial logs/results remain in: $RUN_DIR"
    if [[ "${RESULTS_PACKAGED:-0}" != "1" && -d "$RUN_DIR" ]]; then
      warn "Packaging partial diagnostics automatically..."
      package_results
    fi
  fi
  return "$rc"
}
trap on_exit EXIT

section "Host and smart profile"
info "Project:           $PROJECT_DIR"
info "Public version:    $(cat "$PROJECT_DIR/VERSION" 2>/dev/null || echo unknown)"
info "Platform:          $PLATFORM"
info "Architecture:      $(uname -m)"
info "CPU threads:       $cpu_threads"
info "RAM total:         ${mem_total_mb} MB"
info "Effective RAM:     ${mem_effective_mb} MB (${mem_effective_source})"
info "RAM available:     ${mem_available_mb} MB"
info "BASE_DIR:          $BASE_DIR"
info "Persisted profile: $current_profile"
info "Smart profile:     $expected_profile"
info "Process mode:      $PROCESS_MODE"
info "Deployment mode:   $DEPLOYMENT_MODE"
info "Public mode:       $PUBLIC_MODE"
info "Clean reinstall:   $CLEAN_REINSTALL"
info "Fresh baseline:    $fresh_baseline ($baseline_origin)"
info "Output directory:  $RUN_DIR"

cat > "$RUN_DIR/run-metadata.txt" <<META
utc_started=$utc_stamp
project_version=$(cat "$PROJECT_DIR/VERSION" 2>/dev/null || echo unknown)
platform=$PLATFORM
architecture=$(uname -m)
cpu_threads=$cpu_threads
memory_total_mb=$mem_total_mb
memory_effective_mb=$mem_effective_mb
memory_effective_source=$mem_effective_source
memory_available_at_start_mb=$mem_available_mb
base_dir=$BASE_DIR
persisted_profile=$current_profile
smart_profile=$expected_profile
initial_resource_profile=$current_profile
process_mode=$PROCESS_MODE
deployment_mode=$DEPLOYMENT_MODE
public_mode=$PUBLIC_MODE
clean_reinstall=$CLEAN_REINSTALL
initial_fresh_baseline=$fresh_baseline
initial_baseline_origin=$baseline_origin
full_suite=$RUN_FULL
run_static_checks=$RUN_STATIC_CHECKS
static_checks_fatal=$STATIC_CHECKS_FATAL
run_security_check=$RUN_SECURITY_CHECK
run_auth_check=$RUN_AUTH_CHECK
benchmark_require_clean_source=$BENCHMARK_REQUIRE_CLEAN_SOURCE
benchmark_require_ready=$BENCHMARK_REQUIRE_READY
resource_monitor_interval=$RESOURCE_MONITOR_INTERVAL
full_repeat=$FULL_REPEAT
full_queries=$FULL_QUERIES
full_cold_queries=$FULL_COLD_QUERIES
full_warmup=$FULL_WARMUP
batch_size=$BATCH_SIZE
stable_polls=$STABLE_POLLS
META

section "Source provenance"
python3 "$PROJECT_DIR/scripts/source-integrity.py" check \
  --root "$PROJECT_DIR" \
  --json-output "$RUN_DIR/source-integrity.json" >/dev/null
source_integrity_status="$(python3 - "$RUN_DIR/source-integrity.json" <<'PY'
import json, sys
print(json.load(open(sys.argv[1])).get('integrity_status','NO_MANIFEST'))
PY
)"
canonical_source_sha256="$(python3 - "$RUN_DIR/source-integrity.json" <<'PY'
import json, sys
print(json.load(open(sys.argv[1])).get('canonical_sha256') or '')
PY
)"
info "Source integrity:  $source_integrity_status"
[[ -n "$canonical_source_sha256" ]] && info "Canonical source:   $canonical_source_sha256"
print_source_integrity_details "$RUN_DIR/source-integrity.json"
if [[ "$BENCHMARK_REQUIRE_CLEAN_SOURCE" == "1" && "$source_integrity_status" != "CLEAN" ]]; then
  die "BENCHMARK_REQUIRE_CLEAN_SOURCE=1 requires source integrity CLEAN (got: $source_integrity_status)"
fi

if [[ "$CLEAN_REINSTALL" == "1" ]]; then
  section "TEST-ONLY clean reinstall"
  warn "CLEAN_REINSTALL=1 is destructive for Qdrant runtime under BASE_DIR."
  args=(--yes)
  if [[ ! -f "$INSTANCE_MARKER" ]] && ! base_dir_is_absent_or_empty; then
    if [[ "$FORCE_UNMANAGED" == "1" ]]; then
      args+=(--force-unmanaged)
    else
      die "Managed instance marker is missing. Refusing destructive reinstall of a non-empty runtime. For an old disposable install, set FORCE_UNMANAGED=1."
    fi
  elif [[ ! -f "$INSTANCE_MARKER" ]]; then
    info "BASE_DIR is absent or empty; clean reinstall can create a fresh managed runtime without FORCE_UNMANAGED."
  fi
  QDRANT_PROFILE="$expected_profile" bash "$PROJECT_DIR/qdrant.sh" reinstall-test "${args[@]}"
  current_profile="$expected_profile"
  fresh_baseline=1
  baseline_origin=clean-reinstall
  info "Fresh reinstall completed with QDRANT_PROFILE=$expected_profile"
else
  if [[ "$current_profile" != "$expected_profile" ]]; then
    warn "Installed profile '$current_profile' differs from smart profile '$expected_profile' for ${mem_effective_mb} MB effective RAM."
    if [[ "$ALLOW_PROFILE_MISMATCH" != "1" ]]; then
      die "Refusing misleading profile comparison. Use CLEAN_REINSTALL=1 for a clean test or ALLOW_PROFILE_MISMATCH=1 deliberately."
    fi
    warn "ALLOW_PROFILE_MISMATCH=1: continuing with installed profile: $current_profile"
  fi
fi

if [[ ! -x "$QDRANT_BIN" ]]; then
  section "Normal non-destructive setup"
  info "Qdrant binary is missing; running setup with smart profile: $expected_profile"
  QDRANT_PROFILE="$expected_profile" bash "$PROJECT_DIR/qdrant.sh" setup
  current_profile="$expected_profile"
fi

if ! bash "$PROJECT_DIR/qdrant.sh" health >/dev/null 2>&1; then
  section "Start existing Qdrant runtime"
  bash "$PROJECT_DIR/qdrant.sh" start
fi
cat >> "$RUN_DIR/run-metadata.txt" <<META
resource_profile=$current_profile
fresh_baseline=$fresh_baseline
baseline_origin=$baseline_origin
META
info "Baseline provenance: fresh=$fresh_baseline origin=$baseline_origin"

start_resource_monitor
capture "system-info" bash "$PROJECT_DIR/qdrant.sh" system-info
capture "profile-advisor-100k-768" bash "$PROJECT_DIR/qdrant.sh" profile-advisor --points 100000 --dimension 768
capture "doctor" bash "$PROJECT_DIR/qdrant.sh" doctor
capture "health" bash "$PROJECT_DIR/qdrant.sh" health

if [[ "$RUN_SECURITY_CHECK" == "1" ]]; then
  capture "security-check" bash "$PROJECT_DIR/qdrant.sh" security-check
else
  warn "RUN_SECURITY_CHECK=0: acceptance verdict will be incomplete for comparison-grade use."
fi
if [[ "$RUN_AUTH_CHECK" == "1" ]]; then
  capture "auth-check" bash "$PROJECT_DIR/qdrant.sh" auth-check
else
  warn "RUN_AUTH_CHECK=0: acceptance verdict will be incomplete for comparison-grade use."
fi

if [[ "$RUN_STATIC_CHECKS" == "1" ]]; then
  if capture "static-checks" bash "$PROJECT_DIR/tests/static-checks.sh"; then
    static_rc=0
  else
    static_rc=$?
  fi
  if (( static_rc != 0 )); then
    diagnose_local_runtime_artifacts
    if [[ "$STATIC_CHECKS_FATAL" == "1" ]]; then
      die "Repository static checks failed (exit $static_rc) and STATIC_CHECKS_FATAL=1."
    fi
    warn "Repository static checks returned non-zero (exit $static_rc); runtime benchmark continues because STATIC_CHECKS_FATAL=0."
  fi
fi

section "Quick benchmark suite"
quick_before="$(latest_suite_dir || true)"
bash "$PROJECT_DIR/qdrant.sh" benchmark-suite \
  --quick \
  --queries 30 \
  --cold-queries 10 \
  --warmup 30 \
  --batch-size "$BATCH_SIZE" \
  --stable-polls "$STABLE_POLLS"
quick_after="$(latest_suite_dir || true)"
if [[ -n "$quick_after" && "$quick_after" != "$quick_before" ]]; then
  copy_suite "quick-suite" "$quick_after"
else
  warn "Could not uniquely identify the newly created quick suite directory"
fi
capture "health-after-quick" bash "$PROJECT_DIR/qdrant.sh" health

available_after_quick="$(available_memory_mb)"
info "MemAvailable after quick suite: ${available_after_quick} MB"

if [[ "$RUN_FULL" == "1" ]]; then
  min_required_mb=1200
  if (( available_after_quick > 0 && available_after_quick < min_required_mb )); then
    warn "Only ${available_after_quick} MB MemAvailable remains; skipping full suite (safety floor ${min_required_mb} MB)."
    printf 'full_suite_skipped_reason=memory-safety\n' >> "$RUN_DIR/run-metadata.txt"
  else
    section "Full benchmark suite"
    full_before="$(latest_suite_dir || true)"
    bash "$PROJECT_DIR/qdrant.sh" benchmark-suite \
      --repeat "$FULL_REPEAT" \
      --queries "$FULL_QUERIES" \
      --cold-queries "$FULL_COLD_QUERIES" \
      --warmup "$FULL_WARMUP" \
      --batch-size "$BATCH_SIZE" \
      --stable-polls "$STABLE_POLLS"
    full_after="$(latest_suite_dir || true)"
    if [[ -n "$full_after" && "$full_after" != "$full_before" ]]; then
      copy_suite "full-suite" "$full_after"
    else
      warn "Could not uniquely identify the newly created full suite directory"
    fi
    capture "health-after-full" bash "$PROJECT_DIR/qdrant.sh" health
  fi
fi

section "Final system snapshot"
free -h | tee "$RUN_DIR/free-final.txt"
df -h "$BASE_DIR" | tee "$RUN_DIR/disk-final.txt"
ps -eo pid,ppid,stat,comm,%cpu,%mem,rss,vsz,etime --sort=-rss | head -40 | tee "$RUN_DIR/processes-final.txt"
cat >> "$RUN_DIR/run-metadata.txt" <<META
memory_available_at_end_mb=$(available_memory_mb)
utc_finished=$(date -u +%Y%m%dT%H%M%SZ)
META

stop_resource_monitor

section "Benchmark status"
bash "$PROJECT_DIR/scripts/benchmark-status.sh" \
  --run-dir "$RUN_DIR" \
  --json-output "$RUN_DIR/benchmark-status.json" \
  --markdown-output "$RUN_DIR/benchmark-status.md"

section "Benchmark acceptance"
bash "$PROJECT_DIR/scripts/benchmark-acceptance.sh" \
  --run-dir "$RUN_DIR" \
  --json-output "$RUN_DIR/benchmark-acceptance.json" \
  --markdown-output "$RUN_DIR/benchmark-acceptance.md"

overall_status="$(python3 - "$RUN_DIR/benchmark-status.json" <<'PY'
import json, sys
print(json.load(open(sys.argv[1])).get('overall_status','UNKNOWN'))
PY
)"
comparability="$(python3 - "$RUN_DIR/benchmark-status.json" <<'PY'
import json, sys
print(json.load(open(sys.argv[1])).get('comparability','UNVERIFIED'))
PY
)"
acceptance_verdict="$(python3 - "$RUN_DIR/benchmark-acceptance.json" <<'PY'
import json, sys
print(json.load(open(sys.argv[1])).get('verdict','UNKNOWN'))
PY
)"
info "Overall status:     $overall_status"
info "Comparability:      $comparability"
info "Acceptance verdict: $acceptance_verdict"

FINAL_RC=0
if [[ "$BENCHMARK_REQUIRE_READY" == "1" ]]; then
  if [[ "$overall_status" == "PROVISIONAL" ]]; then
    FINAL_RC=2
  elif [[ "$overall_status" != "READY" ]]; then
    FINAL_RC=3
  fi
fi

section "Package results"
package_results
trap - EXIT
if (( FINAL_RC != 0 )); then
  warn "Strict benchmark readiness requirement failed with status $overall_status (exit $FINAL_RC)."
  exit "$FINAL_RC"
fi
info "Benchmark orchestration completed: status=$overall_status comparability=$comparability acceptance=$acceptance_verdict"
