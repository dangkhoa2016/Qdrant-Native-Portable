#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
qdrant_pid=""
trap '[[ -z "$qdrant_pid" ]] || kill "$qdrant_pid" 2>/dev/null || true; rm -rf "$tmp"' EXIT

mkdir -p "$tmp/runtime/run" "$tmp/bin"
default_timeout="$({
    # These variables intentionally expand in the child shell.
    # shellcheck disable=SC2016
    env -u QDRANT_START_TIMEOUT_SECONDS \
        BASE_DIR="$tmp/default-runtime" \
        bash -c 'source "$1/scripts/common.sh"; printf "%s" "$QDRANT_START_TIMEOUT_SECONDS"' _ "$PROJECT_DIR"
} 2>/dev/null)"
if [[ "$default_timeout" != "300" ]]; then
    echo "FAIL: default startup timeout is '$default_timeout', expected 300" >&2
    exit 1
fi

printf 'QDRANT_START_TIMEOUT_SECONDS=77\n' > "$tmp/runtime/runtime.env"

effective_timeout="$({
    # These variables intentionally expand in the child shell.
    # shellcheck disable=SC2016
    env \
        BASE_DIR="$tmp/runtime" \
        QDRANT_START_TIMEOUT_SECONDS=5 \
        bash -c 'source "$1/scripts/common.sh"; printf "%s" "$QDRANT_START_TIMEOUT_SECONDS"' _ "$PROJECT_DIR"
} 2>/dev/null)"
if [[ "$effective_timeout" != "5" ]]; then
    echo "FAIL: explicit startup timeout was overridden by runtime.env (effective: $effective_timeout)" >&2
    exit 1
fi

set +e
invalid_timeout_output="$(
    # This path intentionally expands in the child shell.
    # shellcheck disable=SC2016
    env \
    BASE_DIR="$tmp/runtime" \
    QDRANT_START_TIMEOUT_SECONDS=abc \
    bash -c 'source "$1/scripts/common.sh"' _ "$PROJECT_DIR" 2>&1
)"
invalid_timeout_rc=$?
set -e
if [[ "$invalid_timeout_rc" -eq 0 ]] || ! grep -Fq 'QDRANT_START_TIMEOUT_SECONDS must be a positive integer' <<<"$invalid_timeout_output"; then
    echo "FAIL: invalid startup timeout returned rc=$invalid_timeout_rc: $invalid_timeout_output" >&2
    exit 1
fi

mkdir -p "$tmp/persist-project/scripts"
cp "$PROJECT_DIR/scripts/common.sh" "$tmp/persist-project/scripts/common.sh"
# This path intentionally expands in the child shell.
# shellcheck disable=SC2016
env \
    BASE_DIR="$tmp/persist-runtime" \
    QDRANT_START_TIMEOUT_SECONDS=19 \
    bash -c 'source "$1/scripts/common.sh"; write_runtime_env' _ "$tmp/persist-project"
persisted_timeout="$({
    # These variables intentionally expand in the child shell.
    # shellcheck disable=SC2016
    env -u QDRANT_START_TIMEOUT_SECONDS \
        BASE_DIR="$tmp/persist-runtime" \
        bash -c 'source "$1/scripts/common.sh"; printf "%s" "$QDRANT_START_TIMEOUT_SECONDS"' _ "$tmp/persist-project"
} 2>/dev/null)"
if [[ "$persisted_timeout" != "19" ]]; then
    echo "FAIL: persisted startup timeout is '$persisted_timeout', expected 19" >&2
    exit 1
fi

# Keep a real process alive so the start script takes its existing-PID path.
sleep 30 &
qdrant_pid=$!
printf '%s\n' "$qdrant_pid" > "$tmp/runtime/run/qdrant.pid"

# Model an API that is unavailable while Qdrant restores collections, then
# becomes ready on the third health check.
cat > "$tmp/bin/curl" <<'CURL_STUB'
#!/usr/bin/env bash
set -euo pipefail
count=0
[[ ! -f "$QNP_TEST_CURL_COUNT" ]] || count="$(cat "$QNP_TEST_CURL_COUNT")"
count=$((count + 1))
printf '%s\n' "$count" > "$QNP_TEST_CURL_COUNT"
delay="${QNP_TEST_CURL_DELAY_SECONDS:-0}"
max_time=3
while (( $# > 0 )); do
    if [[ "$1" == "--max-time" ]]; then max_time="${2:-3}"; break; fi
    shift
done
[[ -z "${QNP_TEST_CURL_MAX_TIME_FILE:-}" ]] || printf '%s\n' "$max_time" > "$QNP_TEST_CURL_MAX_TIME_FILE"
if (( delay > max_time )); then delay="$max_time"; fi
(( delay == 0 )) || sleep "$delay"
if [[ "${QNP_TEST_CURL_ALWAYS_FAIL:-0}" == "1" ]] || (( count < 3 )); then
    echo 'QNP_TEST_CURL_CONNECTION_ERROR' >&2
    exit 7
fi
CURL_STUB
chmod +x "$tmp/bin/curl"

output="$tmp/start.out"
env \
    PATH="$tmp/bin:$PATH" \
    BASE_DIR="$tmp/runtime" \
    QNP_TEST_CURL_COUNT="$tmp/curl-count" \
    QDRANT_START_TIMEOUT_SECONDS=5 \
    QDRANT_PLATFORM=generic-linux \
    PROCESS_MODE=current-user \
    DEPLOYMENT_MODE=minimal \
    PUBLIC_MODE=none \
    QDRANT_PROFILE=low-memory \
    QDRANT_API_KEY=test-admin-key-not-a-production-credential \
    QDRANT_READ_ONLY_API_KEY=test-readonly-key-not-a-production-credential \
    bash "$PROJECT_DIR/qdrant.sh" start >"$output" 2>&1

checks="$(cat "$tmp/curl-count")"
if (( checks < 3 )); then
    cat "$output" >&2
    echo "FAIL: start returned after $checks health check(s) while the existing Qdrant process was still starting" >&2
    exit 1
fi
grep -Fq 'Qdrant is ready' "$output" || {
    cat "$output" >&2
    echo 'FAIL: start did not confirm readiness after the API became available' >&2
    exit 1
}
if grep -Fq 'QNP_TEST_CURL_CONNECTION_ERROR' "$output"; then
    cat "$output" >&2
    echo 'FAIL: start leaked a transient curl connection error' >&2
    exit 1
fi

# A process that exits during recovery must fail immediately instead of making
# the caller wait for the full startup timeout.
kill "$qdrant_pid"
wait "$qdrant_pid" 2>/dev/null || true
qdrant_pid=""
sleep 0.2 &
qdrant_pid=$!
printf '%s\n' "$qdrant_pid" > "$tmp/runtime/run/qdrant.pid"

start_seconds="$(date +%s)"
set +e
env \
    PATH="$tmp/bin:$PATH" \
    BASE_DIR="$tmp/runtime" \
    QNP_TEST_CURL_COUNT="$tmp/dead-curl-count" \
    QNP_TEST_CURL_ALWAYS_FAIL=1 \
    QDRANT_START_TIMEOUT_SECONDS=4 \
    QDRANT_PLATFORM=generic-linux \
    PROCESS_MODE=current-user \
    DEPLOYMENT_MODE=minimal \
    PUBLIC_MODE=none \
    QDRANT_PROFILE=low-memory \
    QDRANT_API_KEY=test-admin-key-not-a-production-credential \
    QDRANT_READ_ONLY_API_KEY=test-readonly-key-not-a-production-credential \
    bash "$PROJECT_DIR/qdrant.sh" start >"$tmp/dead.out" 2>&1
dead_rc=$?
set -e
elapsed=$(( $(date +%s) - start_seconds ))
wait "$qdrant_pid" 2>/dev/null || true
qdrant_pid=""

if [[ "$dead_rc" -eq 0 ]]; then
    cat "$tmp/dead.out" >&2
    echo 'FAIL: start succeeded after the Qdrant process exited before readiness' >&2
    exit 1
fi
if (( elapsed >= 3 )); then
    cat "$tmp/dead.out" >&2
    echo "FAIL: start waited ${elapsed}s after the Qdrant process had exited" >&2
    exit 1
fi
grep -Fq 'exited before readiness' "$tmp/dead.out" || {
    cat "$tmp/dead.out" >&2
    echo 'FAIL: start did not explain that Qdrant exited before readiness' >&2
    exit 1
}

# Timeout is a wall-clock deadline, not a count of potentially slow health
# probes. A one-second timeout must also avoid a separate preliminary probe.
sleep 30 &
qdrant_pid=$!
printf '%s\n' "$qdrant_pid" > "$tmp/runtime/run/qdrant.pid"
start_seconds="$(date +%s)"
set +e
env \
    PATH="$tmp/bin:$PATH" \
    BASE_DIR="$tmp/runtime" \
    QNP_TEST_CURL_COUNT="$tmp/slow-curl-count" \
    QNP_TEST_CURL_MAX_TIME_FILE="$tmp/slow-curl-max-time" \
    QNP_TEST_CURL_ALWAYS_FAIL=1 \
    QNP_TEST_CURL_DELAY_SECONDS=2 \
    QDRANT_START_TIMEOUT_SECONDS=1 \
    QDRANT_PLATFORM=generic-linux \
    PROCESS_MODE=current-user \
    DEPLOYMENT_MODE=minimal \
    PUBLIC_MODE=none \
    QDRANT_PROFILE=low-memory \
    QDRANT_API_KEY=test-admin-key-not-a-production-credential \
    QDRANT_READ_ONLY_API_KEY=test-readonly-key-not-a-production-credential \
    bash "$PROJECT_DIR/qdrant.sh" start >"$tmp/timeout.out" 2>&1
timeout_rc=$?
set -e
elapsed=$(( $(date +%s) - start_seconds ))
kill "$qdrant_pid" 2>/dev/null || true
wait "$qdrant_pid" 2>/dev/null || true
qdrant_pid=""

if [[ "$timeout_rc" -eq 0 ]] || (( elapsed >= 3 )); then
    cat "$tmp/timeout.out" >&2
    echo "FAIL: one-second startup timeout returned rc=$timeout_rc after ${elapsed}s" >&2
    exit 1
fi
grep -Fq 'did not become ready within 1s' "$tmp/timeout.out" || {
    cat "$tmp/timeout.out" >&2
    echo 'FAIL: startup timeout diagnostic is missing' >&2
    exit 1
}
if [[ "$(cat "$tmp/slow-curl-max-time")" != "1" ]]; then
    cat "$tmp/timeout.out" >&2
    echo "FAIL: slow health probe did not receive the one-second remaining timeout" >&2
    exit 1
fi

echo 'PASS: start handles existing Qdrant processes that become ready or exit'
