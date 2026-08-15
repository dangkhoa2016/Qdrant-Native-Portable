#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREPARE="$ROOT/tests/hf-sentinel-prepare.sh"
VERIFY="$ROOT/tests/hf-sentinel-verify-readonly.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

[[ -x "$PREPARE" ]] || fail "sentinel prepare helper is missing or not executable"
[[ -x "$VERIFY" ]] || fail "read-only sentinel verifier is missing or not executable"

# The post-restart verifier is deliberately read-only. It may use GET or POST
# query/read APIs, but it must never issue mutating HTTP methods or point upserts.
if grep -Eq -- '(^|[[:space:]])(-X|--request)[[:space:]]+(PUT|PATCH|DELETE)([[:space:]]|$)' "$VERIFY"; then
  fail "read-only verifier contains a mutating HTTP method"
fi
if grep -Eq -- '/points\?wait=|/snapshots|/collections/.*/points($|[?[:space:]])' "$VERIFY"; then
  fail "read-only verifier contains a known mutating endpoint pattern"
fi
if grep -q 'QDRANT_API_KEY' "$VERIFY"; then
  fail "read-only verifier must not depend on the admin API key"
fi
grep -q 'QDRANT_READ_ONLY_API_KEY' "$VERIFY" || fail "read-only verifier must use the read-only API key"

grep -q '/collections/' "$PREPARE" || fail "prepare helper must target a collection"
grep -q '/points?wait=true' "$PREPARE" || fail "prepare helper must write the sentinel point before restart"

printf 'PASS: sentinel prepare/write and post-restart read-only verification are separated\n'
