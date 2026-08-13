#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail_test() { echo "docker persistence entrypoint test failed: $*" >&2; exit 1; }

tmp="$(mktemp -d)"
qdrant_root="$tmp/qdrant"
cleanup() {
    if [[ -n "${entry_pid:-}" ]] && kill -0 "$entry_pid" 2>/dev/null; then
        kill -TERM "$entry_pid" 2>/dev/null || true
        wait "$entry_pid" 2>/dev/null || true
    fi
    rm -rf "$tmp"
}
trap cleanup EXIT
mkdir -p "$qdrant_root"
cp "$ROOT/docker/persistence.sh" "$qdrant_root/qnp-persistence.sh"
cat > "$qdrant_root/qnp-healthcheck.sh" <<'EOS'
#!/usr/bin/env bash
exit 0
EOS
chmod +x "$qdrant_root/qnp-healthcheck.sh"
cat > "$qdrant_root/qdrant" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" > "${QNP_TEST_ARGS_FILE:?}"
trap 'printf "TERM\n" > "${QNP_TEST_TERM_FILE:?}"; exit 0' TERM INT
while :; do sleep 1; done
EOS
chmod +x "$qdrant_root/qdrant"

mkdir -p "$tmp/bucket/full" "$tmp/live" "$tmp/scratch"
printf 'full-snapshot-data' > "$tmp/bucket/full/restore.snapshot"
(cd "$tmp/bucket/full" && sha256sum restore.snapshot > restore.snapshot.sha256)
printf '%s\n' restore.snapshot > "$tmp/bucket/full/LATEST"
printf '10 2 0:9 / %s rw - fuse.hf-mount hf rw\n' "$tmp/bucket" > "$tmp/mountinfo"

export QNP_PERSISTENCE_LIB="$qdrant_root/qnp-persistence.sh"
export QNP_QDRANT_BIN="$qdrant_root/qdrant"
export QNP_HEALTHCHECK_BIN="$qdrant_root/qnp-healthcheck.sh"
export QDRANT_API_KEY='admin-test-key'
export QDRANT_READ_ONLY_API_KEY='reader-test-key'
export QNP_ENV=production
export QNP_TOPOLOGY=single
export QNP_STORAGE_MODE=snapshot-persist
export QNP_PERSIST_PATH="$tmp/bucket"
export QNP_REQUIRE_PERSIST_MOUNT=1
export QNP_MOUNTINFO_PATH="$tmp/mountinfo"
export QDRANT_STORAGE_PATH="$tmp/live"
export QDRANT_SNAPSHOTS_PATH="$tmp/scratch"
export QDRANT_TEMP_PATH="$tmp/scratch/.tmp"
export QNP_AUTO_RESTORE=1
export QNP_AUTO_SNAPSHOT_INTERVAL_SECONDS=0
export QNP_AUTO_SNAPSHOT_ON_SHUTDOWN=0
export QNP_TEST_ARGS_FILE="$tmp/args"
export QNP_TEST_TERM_FILE="$tmp/term"

bash "$ROOT/docker/entrypoint.sh" >"$tmp/entry.log" 2>&1 &
entry_pid=$!
for _ in {1..50}; do [[ -f "$tmp/args" ]] && break; sleep 0.1; done
[[ -f "$tmp/args" ]] || { cat "$tmp/entry.log" >&2; fail_test "fake Qdrant did not start"; }
grep -Fx -- '--storage-snapshot' "$tmp/args" >/dev/null || fail_test "entrypoint did not pass --storage-snapshot"
grep -F "$tmp/scratch/.qnp-restore/restore.snapshot" "$tmp/args" >/dev/null || fail_test "entrypoint staged restore in wrong location"
[[ -z "$(find "$tmp/live" -mindepth 1 -print -quit)" ]] || fail_test "entrypoint polluted empty live storage before fake Qdrant start"

kill -TERM "$entry_pid"
wait "$entry_pid"
entry_pid=""
for _ in {1..30}; do [[ -f "$tmp/term" ]] && break; sleep 0.1; done
[[ -f "$tmp/term" ]] || fail_test "SIGTERM was not forwarded to Qdrant child"

# Corrupt-only persistent backups must fail before Qdrant starts.
rm -f "$tmp/args" "$tmp/term"
rm -rf "$tmp/live" "$tmp/scratch"
mkdir -p "$tmp/live" "$tmp/scratch"
printf 'bad' > "$tmp/bucket/full/restore.snapshot"
printf 'wrong-checksum  restore.snapshot\n' > "$tmp/bucket/full/restore.snapshot.sha256"
printf '%s\n' restore.snapshot > "$tmp/bucket/full/LATEST"
set +e
bash "$ROOT/docker/entrypoint.sh" >"$tmp/corrupt.log" 2>&1
rc=$?
set -e
(( rc != 0 )) || fail_test "corrupt-only backup unexpectedly started"
[[ ! -f "$tmp/args" ]] || fail_test "Qdrant started even though all persistent snapshots were corrupt"
grep -q 'refusing to start empty' "$tmp/corrupt.log" || { cat "$tmp/corrupt.log" >&2; fail_test "corrupt backup failure was not explicit"; }

# Snapshot-persist must fail closed if Qdrant never becomes ready; otherwise backups would never start.
rm -f "$tmp/args" "$tmp/term"
rm -rf "$tmp/live" "$tmp/scratch"
mkdir -p "$tmp/live" "$tmp/scratch"
cat > "$qdrant_root/qnp-healthcheck.sh" <<'EOS'
#!/usr/bin/env bash
exit 1
EOS
chmod +x "$qdrant_root/qnp-healthcheck.sh"
export QNP_STORAGE_MODE=snapshot-persist
export QNP_ALLOW_UNSUPPORTED_STORAGE=0
export QNP_REQUIRE_PERSIST_MOUNT=1
export QNP_PERSIST_PATH="$tmp/bucket"
export QNP_MOUNTINFO_PATH="$tmp/mountinfo"
export QNP_AUTO_RESTORE=0
export QNP_READY_TIMEOUT_SECONDS=1
set +e
bash "$ROOT/docker/entrypoint.sh" >"$tmp/not-ready.log" 2>&1 &
not_ready_pid=$!
set -e
for _ in {1..40}; do
    if ! kill -0 "$not_ready_pid" 2>/dev/null; then break; fi
    sleep 0.1
done
if kill -0 "$not_ready_pid" 2>/dev/null; then
    kill -TERM "$not_ready_pid" 2>/dev/null || true
    wait "$not_ready_pid" 2>/dev/null || true
    fail_test "entrypoint kept running after readiness timeout with persistence disabled"
fi
wait "$not_ready_pid" 2>/dev/null || true
grep -q 'readiness timeout' "$tmp/not-ready.log" || { cat "$tmp/not-ready.log" >&2; fail_test "readiness timeout failure was not explicit"; }

# Restore healthcheck for subsequent cases.
cat > "$qdrant_root/qnp-healthcheck.sh" <<'EOS'
#!/usr/bin/env bash
exit 0
EOS
chmod +x "$qdrant_root/qnp-healthcheck.sh"
unset QNP_READY_TIMEOUT_SECONDS

# Direct experimental mode must require a real mount even if the caller tries to disable mount validation.
rm -f "$tmp/args" "$tmp/term"
printf '1 2 0:1 / / rw - rootfs rootfs rw\n' > "$tmp/no-direct-mountinfo"
export QNP_STORAGE_MODE=direct-mount-experimental
export QNP_ALLOW_UNSUPPORTED_STORAGE=1
export QNP_REQUIRE_PERSIST_MOUNT=0
export QNP_PERSIST_PATH="$tmp/not-mounted"
export QNP_MOUNTINFO_PATH="$tmp/no-direct-mountinfo"
set +e
bash "$ROOT/docker/entrypoint.sh" >"$tmp/direct.log" 2>&1 &
direct_pid=$!
set -e
for _ in {1..30}; do
    if ! kill -0 "$direct_pid" 2>/dev/null; then break; fi
    [[ -f "$tmp/args" ]] && break
    sleep 0.1
done
if [[ -f "$tmp/args" ]]; then
    kill -TERM "$direct_pid" 2>/dev/null || true
    wait "$direct_pid" 2>/dev/null || true
    fail_test "direct experimental mode started without a real persistent mount"
fi
if kill -0 "$direct_pid" 2>/dev/null; then
    kill -TERM "$direct_pid" 2>/dev/null || true
    wait "$direct_pid" 2>/dev/null || true
    fail_test "direct experimental mode did not fail closed when mount was absent"
fi
wait "$direct_pid" 2>/dev/null || true
grep -q 'not a mounted volume' "$tmp/direct.log" || { cat "$tmp/direct.log" >&2; fail_test "direct mount failure did not explain missing mount"; }

echo "docker persistence entrypoint tests passed"
