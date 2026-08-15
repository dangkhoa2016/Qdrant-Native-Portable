#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COLLECTOR="$ROOT/examples/production/collect-modal-validation-result.sh"
fail_test() { echo "Modal result hygiene test failed: $*" >&2; exit 1; }

[[ -x "$COLLECTOR" ]] || fail_test "missing executable Modal validation result collector"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/results"
cat > "$TMP/bin/modal" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1 $2" == "app logs" ]]; then
  echo "stub modal app log"
elif [[ "$1 $2" == "volume ls" ]]; then
  echo "stub modal volume listing"
else
  echo "unexpected modal invocation: $*" >&2
  exit 2
fi
STUB
chmod +x "$TMP/bin/modal"

cat > "$TMP/bin/curl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
expected_key="${QNP_TEST_EXPECTED_READONLY_KEY:-readonly-evidence-key}"
args=" $* "
[[ "$args" == *" api-key: $expected_key "* ]] || {
  echo "missing read-only api-key header" >&2
  exit 22
}
url="${@: -1}"
case "$url" in
  */collections)
    if [[ "${QNP_TEST_LEAK_QDRANT_SECRET:-0}" == "1" ]]; then
      printf '{"leaked_secret":"%s"}\n' "$expected_key"
    else
      printf '%s\n' '{"result":{"collections":[{"name":"qnp_restore_sentinel"}]},"status":"ok"}'
    fi
    ;;
  */collections/qnp_restore_sentinel)
    printf '%s\n' '{"result":{"status":"green","points_count":1},"status":"ok"}'
    ;;
  */collections/qnp_restore_sentinel/points/9182026?with_payload=true\&with_vector=false)
    printf '%s\n' '{"result":{"id":9182026,"payload":{"qnp_restore_sentinel":"test-token"}},"status":"ok"}'
    ;;
  *)
    echo "unexpected qdrant URL: $url" >&2
    exit 22
    ;;
esac
STUB
chmod +x "$TMP/bin/curl"

before="$(find "$ROOT" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort | sha256sum | awk '{print $1}')"
PATH="$TMP/bin:$PATH" \
QDRANT_URL="https://qdrant.example.test" \
QDRANT_READ_ONLY_API_KEY="readonly-evidence-key" \
QNP_MODAL_RESULT_BASE="$TMP/results" \
QNP_MODAL_LOG_SINCE="1h" \
QNP_MODAL_LOG_TAIL="50" \
  "$COLLECTOR" > "$TMP/collector.out"
after="$(find "$ROOT" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort | sha256sum | awk '{print $1}')"
[[ "$before" == "$after" ]] || fail_test "collector created top-level artifacts inside source tree"

zip_path="$(sed -n 's/^RESULT_ZIP=//p' "$TMP/collector.out" | tail -n1)"
[[ -n "$zip_path" && -f "$zip_path" ]] || fail_test "collector did not report/create result ZIP"
case "$zip_path" in
  "$ROOT"/*) fail_test "result ZIP must live outside source tree" ;;
esac

zip_listing="$(unzip -Z1 "$zip_path")"
grep -Fq 'modal-app.log' <<<"$zip_listing" || fail_test "result ZIP missing Modal app log"
grep -Fq 'modal-volume-root.txt' <<<"$zip_listing" || fail_test "result ZIP missing Volume root listing"
grep -Fq 'modal-volume-full.txt' <<<"$zip_listing" || fail_test "result ZIP missing Volume full listing"
grep -Fq 'source-integrity.json' <<<"$zip_listing" || fail_test "result ZIP missing source-integrity report"
grep -Fq 'qdrant-collections.json' <<<"$zip_listing" || fail_test "result ZIP missing Qdrant collections evidence"
grep -Fq 'qdrant-sentinel-collection.json' <<<"$zip_listing" || fail_test "result ZIP missing sentinel collection evidence"
grep -Fq 'qdrant-sentinel-point.json' <<<"$zip_listing" || fail_test "result ZIP missing sentinel point evidence"

unzip -p "$zip_path" '*/collection-status.txt' > "$TMP/collection-status.txt"
grep -Fq 'PASS qdrant-collections.json' "$TMP/collection-status.txt" || fail_test "collections probe was not recorded PASS"
grep -Fq 'PASS qdrant-sentinel-collection.json' "$TMP/collection-status.txt" || fail_test "sentinel collection probe was not recorded PASS"
grep -Fq 'PASS qdrant-sentinel-point.json' "$TMP/collection-status.txt" || fail_test "sentinel point probe was not recorded PASS"

mkdir -p "$TMP/leak-results"
set +e
PATH="$TMP/bin:$PATH" \
QDRANT_URL="https://qdrant.example.test" \
QDRANT_READ_ONLY_API_KEY="qnp-fake-readonly-secret-for-hygiene-test" \
QNP_TEST_EXPECTED_READONLY_KEY="qnp-fake-readonly-secret-for-hygiene-test" \
QNP_TEST_LEAK_QDRANT_SECRET=1 \
QNP_MODAL_RESULT_BASE="$TMP/leak-results" \
QNP_MODAL_LOG_SINCE="1h" \
QNP_MODAL_LOG_TAIL="50" \
  "$COLLECTOR" > "$TMP/leak-collector.out" 2> "$TMP/leak-collector.err"
leak_rc=$?
set -e
[[ "$leak_rc" -ne 0 ]] || fail_test "collector must fail closed when Qdrant evidence contains the read-only key"
find "$TMP/leak-results" -maxdepth 1 -type f -name '*.zip' -print -quit | grep -q . && \
  fail_test "collector created a ZIP despite Qdrant evidence secret leakage"
grep -Fq 'Refusing to package result: collected files contain QDRANT_READ_ONLY_API_KEY value' "$TMP/leak-collector.err" || \
  fail_test "collector did not explain Qdrant evidence secret-leak refusal"

echo "Modal result hygiene tests passed"
