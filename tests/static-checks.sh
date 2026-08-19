#!/usr/bin/env bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

failed=0

check() {
    local name="$1"
    shift
    printf '[check] %-34s ' "$name"
    if "$@" >/dev/null; then
        echo OK
    else
        echo FAILED
        failed=1
    fi
}

while IFS= read -r -d '' file; do
    check "bash -n ${file#./}" bash -n "$file"
done < <(find . -type f -name '*.sh' -print0 | sort -z)

check "Python syntax" python3 -c '
import ast, pathlib
for path in sorted(pathlib.Path(".").rglob("*.py")):
    if any(part in {".git", ".venv", "node_modules", "__pycache__"} for part in path.parts):
        continue
    ast.parse(path.read_text(), filename=str(path))
'

if command -v node >/dev/null 2>&1; then
    check "Node syntax" node --check examples/node/client.js
else
    echo '[skip] Node syntax: node not installed'
fi

if command -v ruby >/dev/null 2>&1; then
    check "Ruby syntax" ruby -c examples/ruby/client.rb
else
    echo '[skip] Ruby syntax: ruby not installed'
fi

printf '[check] %-34s ' 'public version is 1.0.0'
version_scan_paths=(.github README.md README.vi.md CHANGELOG.md CONTRIBUTING.md SECURITY.md docs benchmarks deploy docker examples scripts tests qdrant.sh run_all.sh run-smart-qdrant-benchmarks.sh run-fresh-qdrant-benchmarks.sh)
if [[ "$(cat VERSION 2>/dev/null)" == "1.0.0" ]] && ! grep -RIE --exclude='*.json' --exclude='*.log' --exclude='static-checks.sh' '(v1\.0\.[1-9][0-9]*|v2\.1\.0|v2\.1\.1|2\.1\.0|2\.1\.1|2\.0\.0)' "${version_scan_paths[@]}" >/dev/null 2>&1; then
    echo OK
else
    echo FAILED
    failed=1
fi

printf '[check] %-34s ' 'no unsafe runtime artifacts'
# A live installed working tree can legitimately contain generated, Git-ignored state
# such as .qdrant-base and Python __pycache__. Those must not make runtime diagnostics
# fail after setup. Public-release cleanliness is enforced separately by
# test-release-package.sh / package-release.sh.
#
# Still fail on sensitive runtime configuration accidentally written inside the source
# tree because those may contain credentials or deployment state.
unsafe_runtime_artifact="$(find . -type f \( \
    -name 'secrets.env' -o -name 'runtime.env' -o \
    -name '*.snapshot' -o -name '*.snapshot.sha256' \
  \) -print -quit 2>/dev/null || true)"
if [[ -n "$unsafe_runtime_artifact" ]]; then
    echo FAILED
    printf '[warn] unsafe runtime artifact: %s\n' "$unsafe_runtime_artifact" >&2
    failed=1
else
    echo OK
fi

printf '[check] %-34s ' 'local generated artifacts'
generated_artifact="$(find . \( \
    -type d \( -name __pycache__ -o -name node_modules -o -name .venv \) -o \
    -type f \( -name '.qdrant-initialized' -o -name '.qdrant-base' -o \
                   -name '.qdrant-native-portable-instance' -o -name '*.pyc' -o \
                   -name 'qdrant-benchmarks-*.zip' -o -name 'qdrant-benchmarks-*.zip.sha256' -o \
                   -name 'profile-ab-*.zip' -o -name 'profile-ab-*.zip.sha256' \) \
  \) -print -quit 2>/dev/null || true)"
if [[ -n "$generated_artifact" ]]; then
    echo 'OK (present, ignored for live-tree diagnostics)'
else
    echo OK
fi

printf '[check] %-34s ' 'no concrete tunnel URL'
if grep -RIE --exclude-dir=.git --exclude='static-checks.sh' --exclude='security-check.sh' \
    'https://[-a-z0-9]+\.trycloudflare\.com' . >/dev/null 2>&1; then
    echo FAILED
    failed=1
else
    echo OK
fi

printf '[check] %-34s ' 'no likely embedded API key'
if grep -RIE --exclude-dir=.git --exclude='static-checks.sh' --exclude='security-check.sh' \
    "(QDRANT_API_KEY|apiKey|api-key)[^[:space:]]{0,80}[=:][[:space:]]*['\"]?[a-f0-9]{48,}" . >/dev/null 2>&1; then
    echo FAILED
    failed=1
else
    echo OK
fi

check "secret precedence" bash tests/test-secret-precedence.sh
check "portable modes/config" bash tests/test-portable-modes.sh
check "JWT token generator" bash tests/test-jwt-token.sh
check "health exit semantics" bash tests/test-health-check-exit.sh
check "runtime authorization" bash tests/test-auth-check.sh
check "benchmark settle semantics" python3 tests/test-benchmark-settle.py
check "benchmark status semantics" bash tests/test-benchmark-status.sh
check "benchmark tooling" bash tests/test-benchmark-tooling.sh
check "smart benchmark wrapper" bash tests/test-smart-benchmark-wrapper.sh
check "source fingerprint" bash tests/test-source-fingerprint.sh
check "resource monitor" bash tests/test-resource-monitor.sh
check "profile comparison" bash tests/test-profile-compare.sh
check "benchmark acceptance" bash tests/test-benchmark-acceptance.sh
check "cross-host comparison" bash tests/test-compare-benchmarks.sh
check "profile advisor" bash tests/test-profile-advisor.sh
check "production mode" bash tests/test-production-mode.sh
check "production lifecycle" bash tests/test-production-lifecycle.sh
check "Docker production" bash tests/test-docker-production.sh
check "production providers" bash tests/test-production-providers.sh
check "Beam persistence adapter" bash tests/test-beam-persistence-adapter.sh
check "Beam result hygiene" bash tests/test-beam-result-hygiene.sh
check "Modal persistence adapter" bash tests/test-modal-persistence-adapter.sh
check "Modal result hygiene" bash tests/test-modal-result-hygiene.sh
check "HF Bucket persistence" bash tests/test-hf-bucket-persistence.sh
check "Docker persistence entrypoint" bash tests/test-docker-persistence-entrypoint.sh
check "HF restore temp-path" bash tests/test-snapshot-restore-temp-path.sh
check "readiness child exit" bash tests/test-readiness-child-exit.sh
check "HF sentinel tools" bash tests/test-hf-sentinel-tools.sh
check "test reset/reinstall guardrails" bash tests/test-reinstall-test.sh
check "full purge guardrails" bash tests/test-purge-all-test.sh
check "fresh benchmark entrypoint" bash tests/test-run-fresh-benchmark-wrapper.sh
check "public release readiness" bash tests/test-public-release-readiness.sh
check "release package hygiene" bash tests/test-release-package.sh

if command -v shellcheck >/dev/null 2>&1; then
    while IFS= read -r -d '' file; do
        check "shellcheck ${file#./}" shellcheck -x "$file"
    done < <(find . -type f -name '*.sh' -print0 | sort -z)
else
    echo '[skip] shellcheck: not installed'
fi

if (( failed )); then
    echo 'Static checks failed.' >&2
    exit 1
fi

echo 'All static checks passed.'
