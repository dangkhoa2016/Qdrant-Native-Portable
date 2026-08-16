#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SENTINEL="$ROOT/examples/production/beam-sentinel.sh"
COLLECTOR="$ROOT/examples/production/collect-beam-validation-result.sh"
fail_test() { echo "Beam result hygiene test failed: $*" >&2; exit 1; }

[[ -x "$SENTINEL" ]] || fail_test "Beam sentinel helper is missing or not executable"
[[ -x "$COLLECTOR" ]] || fail_test "Beam collector is missing or not executable"

python3 - "$SENTINEL" "$COLLECTOR" <<'PY'
import pathlib
import sys

sentinel = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
collector = pathlib.Path(sys.argv[2]).read_text(encoding="utf-8")


def require(text: str, fragment: str, message: str) -> None:
    if fragment not in text:
        raise SystemExit(f"Beam result hygiene test failed: {message}")


require(sentinel, 'case "$command" in', "sentinel helper must expose subcommands")
require(sentinel, 'prepare)', "sentinel helper must expose prepare")
require(sentinel, 'verify-readonly)', "sentinel helper must expose verify-readonly")
require(sentinel, 'qnp_beam_sentinel', "sentinel payload key must be Beam-specific")
require(sentinel, '/points?wait=true', "prepare must persist the sentinel point")

start = sentinel.find('verify_readonly()')
end = sentinel.find('\n}\n', start)
if start < 0 or end < 0:
    raise SystemExit("Beam result hygiene test failed: cannot isolate verify_readonly function")
readonly = sentinel[start:end]
if 'QDRANT_API_KEY' in readonly:
    raise SystemExit("Beam result hygiene test failed: read-only verifier must not depend on admin API key")
require(readonly, 'QDRANT_READ_ONLY_API_KEY', "read-only verifier must require the read-only key")
for verb in ('-X PUT', '-X PATCH', '-X DELETE', '--request PUT', '--request PATCH', '--request DELETE'):
    if verb in readonly:
        raise SystemExit(f"Beam result hygiene test failed: read-only verifier contains mutating method {verb}")
require(readonly, 'QNP_BEAM_VOLUME_VISIBILITY_TIMEOUT_SECONDS', "read-only verification must support Beam visibility retry")
require(readonly, 'sleep', "Beam visibility retry must be bounded by polling sleeps")

for fragment, message in (
    ('QDRANT_URL', 'collector must require deployed Qdrant endpoint'),
    ('QDRANT_API_KEY', 'collector must support admin auth evidence'),
    ('QDRANT_READ_ONLY_API_KEY', 'collector must use read-only credential'),
    ('beam-deployments.txt', 'collector must capture Beam deployment inventory'),
    ('beam-containers.txt', 'collector must capture Beam container inventory'),
    ('beam-volume-list.txt', 'collector must capture Beam Volume inventory'),
    ('beam-volume-root.txt', 'collector must capture Beam Volume contents'),
    ('beam-volume-full.txt', 'collector must attempt full snapshot directory listing'),
    ('qdrant-auth-status.txt', 'collector must capture authorization matrix status'),
    ('qdrant-collections.json', 'collector must capture collections evidence'),
    ('qdrant-sentinel-collection.json', 'collector must capture sentinel collection evidence'),
    ('qdrant-sentinel-point.json', 'collector must capture sentinel point evidence'),
    ('source-integrity.json', 'collector must capture source-integrity evidence'),
    ('collection-status.txt', 'collector must record nonfatal collection status'),
    ('grep -RIlF', 'collector must scan exact secret values before packaging'),
    ('QNP_BEAM_DEPLOYMENT_ID', 'collector must support deployment-specific logs'),
    ('QNP_BEAM_CONTAINER_ID', 'collector must support container-specific logs'),
):
    require(collector, fragment, message)

if 'env >' in collector or 'printenv' in collector or 'docker inspect' in collector:
    raise SystemExit("Beam result hygiene test failed: collector must not dump raw container environment")
PY

printf 'Beam result hygiene static tests passed\n'

# Behavioral regression: a normal synthetic collection must package, while any
# collected file containing an exact current secret value must fail closed.
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/results-ok" "$tmp/results-leak"

cat >"$tmp/bin/beam" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${QNP_FAKE_BEAM_LEAK:-0}" == "1" ]]; then
  printf 'synthetic leaked secret=%s\n' "${QDRANT_API_KEY:-}"
else
  printf 'synthetic beam evidence: %s\n' "$*"
fi
SH
chmod +x "$tmp/bin/beam"

cat >"$tmp/bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
out=""
write_status=0
status=200
args=("$@")
for ((i=0; i<${#args[@]}; i++)); do
  case "${args[$i]}" in
    -o|--output)
      ((i+=1)); out="${args[$i]}" ;;
    -w|--write-out)
      ((i+=1)); write_status=1 ;;
  esac
done
body='{"result":{"payload":{"qnp_beam_sentinel":"synthetic-token"}}}'
if [[ -n "$out" ]]; then
  printf '%s\n' "$body" >"$out"
else
  printf '%s\n' "$body"
fi
if (( write_status )); then
  printf '%s' "$status"
fi
SH
chmod +x "$tmp/bin/curl"

common_env=(
  "PATH=$tmp/bin:$PATH"
  "QDRANT_URL=https://beam.example.invalid"
  "QDRANT_API_KEY=admin-secret-beam-test-123"
  "QDRANT_READ_ONLY_API_KEY=readonly-secret-beam-test-456"
  "QNP_SENTINEL_TOKEN=synthetic-token"
  "QNP_BEAM_PHASE=unit-fixture"
)

env "${common_env[@]}" \
  QNP_BEAM_RESULT_BASE="$tmp/results-ok" \
  "$COLLECTOR" >/dev/null
ok_zip_count="$(find "$tmp/results-ok" -maxdepth 1 -type f -name '*.zip' | wc -l | tr -d ' ')"
[[ "$ok_zip_count" == "1" ]] || fail_test "normal synthetic Beam evidence did not produce exactly one ZIP"

set +e
env "${common_env[@]}" \
  QNP_FAKE_BEAM_LEAK=1 \
  QNP_BEAM_RESULT_BASE="$tmp/results-leak" \
  "$COLLECTOR" >"$tmp/leak.stdout" 2>"$tmp/leak.stderr"
leak_rc=$?
set -e
[[ $leak_rc -ne 0 ]] || fail_test "collector packaged evidence containing the exact admin secret"
if find "$tmp/results-leak" -maxdepth 1 -type f -name '*.zip' | grep -q .; then
  fail_test "collector created a ZIP after exact-secret leakage"
fi
grep -q 'Refusing to package result' "$tmp/leak.stderr" || fail_test "secret-leak refusal message missing"

printf 'Beam result hygiene behavioral tests passed\n'
