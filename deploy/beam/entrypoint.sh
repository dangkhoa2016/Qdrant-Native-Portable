#!/usr/bin/env bash
set -euo pipefail

log() { printf '[qnp-beam] %s\n' "$*" >&2; }
fail() { printf '[qnp-beam] ERROR: %s\n' "$*" >&2; exit 1; }

persist="${QNP_PERSIST_PATH:-/qdrant-persist}"
[[ -d "$persist" ]] || fail "persistence path is not attached: $persist"
[[ -w "$persist" ]] || fail "persistence path is not writable: $persist"

command -v mktemp >/dev/null 2>&1 || fail "required preflight command is unavailable: mktemp"
command -v dd >/dev/null 2>&1 || fail "required preflight command is unavailable: dd"
command -v cmp >/dev/null 2>&1 || fail "required preflight command is unavailable: cmp"
command -v rm >/dev/null 2>&1 || fail "required preflight command is unavailable: rm"

expected="$(mktemp)" || fail "cannot create local Beam persistence probe source"
probe=""
cleanup() {
    rm -f "$expected" >/dev/null 2>&1 || true
    if [[ -n "$probe" ]]; then
        rm -f "$probe" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT HUP INT TERM

printf 'qnp-beam-volume-probe:%s:%s\n' "$$" "$RANDOM" >"$expected"
probe="$(mktemp "$persist/.qnp-beam-volume-probe-XXXXXXXX")" \
    || fail "cannot create Beam persistence probe"

if ! dd if="$expected" of="$probe" bs=4096 conv=fsync status=none; then
    fail "cannot durably write Beam persistence probe"
fi

cmp -s "$expected" "$probe" || fail "Beam persistence probe read-back mismatch"
rm -f "$probe" || fail "cannot remove Beam persistence probe"
probe=""
rm -f "$expected"
trap - EXIT HUP INT TERM

log "Beam persistence preflight passed for $persist"
log "snapshot-persist uses local /qdrant/storage and durable completed snapshots at $persist"
exec /qdrant/qnp-entrypoint.sh
