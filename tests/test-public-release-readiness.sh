#!/usr/bin/env bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

[[ "$(cat VERSION)" == "1.0.0" ]]

grep -Fq '## 1.0.0 - 2026-08-18' CHANGELOG.md

if grep -RInF '<YOUR_REPOSITORY_URL>' README.md README.vi.md docs/USAGE.md docs/USAGE.vi.md >/dev/null; then
    echo 'FAIL: public documentation still contains repository URL placeholder' >&2
    exit 1
fi

# The public examples runner must respect the active deployment mode instead of
# assuming that the Nginx proxy exists on :9090.
# shellcheck disable=SC2016
grep -Fq 'QDRANT_URL="${QDRANT_URL:-$(local_api_url)}"' examples/run_examples.sh
# shellcheck disable=SC2016
if grep -Fq 'QDRANT_URL="${QDRANT_URL:-http://${PROXY_BIND}:${PROXY_PORT}}"' examples/run_examples.sh; then
    echo 'FAIL: examples runner still hard-codes proxy endpoint' >&2
    exit 1
fi

# Public source must not expose private development labels.
scan_paths=(.github README.md README.vi.md CHANGELOG.md CONTRIBUTING.md SECURITY.md benchmarks deploy docker docs examples scripts tests qdrant.sh run_all.sh run-smart-qdrant-benchmarks.sh run-fresh-qdrant-benchmarks.sh)
internal_marker_re='(v1\.1\.[0-9]+|staging[0-9]+|production-candidate-'"real-pass"'|qnp-modal-staging[0-9]+)'
if grep -RIE --exclude='SOURCE-MANIFEST.json' --exclude='test-public-release-readiness.sh' \
    "$internal_marker_re" "${scan_paths[@]}" >/dev/null 2>&1; then
    echo 'FAIL: internal development marker detected in public source' >&2
    exit 1
fi

# Concrete ephemeral tunnel endpoints are runtime evidence, never source.
if grep -RIE --exclude='test-public-release-readiness.sh' \
    'https://[-a-z0-9]+\.trycloudflare\.com' "${scan_paths[@]}" >/dev/null 2>&1; then
    echo 'FAIL: concrete trycloudflare URL detected in public source' >&2
    exit 1
fi

# CI third-party actions are pinned to an immutable upstream commit.
grep -Fq 'actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1' .github/workflows/ci.yml
if grep -Eq 'uses:[[:space:]]+actions/checkout@v[0-9]+' .github/workflows/ci.yml; then
    echo 'FAIL: GitHub Actions checkout is pinned only to a mutable version tag' >&2
    exit 1
fi

# Give public users a safe path for sensitive vulnerability reports without
# requiring a maintainer email address in source.
grep -Fq 'Report a vulnerability' SECURITY.md

# Public documentation must expose a concise capability overview without
# forcing first-time readers to reconstruct the product from specialist docs.
[[ -f docs/FEATURES.md ]]
[[ -f docs/FEATURES.vi.md ]]
grep -Fq '## Capability and platform matrix' README.md
grep -Fq '## Ma trận khả năng và nền tảng' README.vi.md
grep -Fq '## What this project is — and is not' README.md
grep -Fq '## Project này là gì — và không phải là gì' README.vi.md
grep -Fq '## Documentation map' README.md
grep -Fq '## Bản đồ tài liệu' README.vi.md
grep -Fq '[Full capability reference](docs/FEATURES.md)' README.md
grep -Fq '[Tổng hợp đầy đủ các khả năng](docs/FEATURES.vi.md)' README.vi.md

grep -Fq '## Production readiness matrix' docs/FEATURES.md
grep -Fq '## Ma trận mức độ sẵn sàng production' docs/FEATURES.vi.md
grep -Fq 'Real-provider validated' docs/FEATURES.md
grep -Fq 'Đã xác thực trên provider thực' docs/FEATURES.vi.md
grep -Fq '[Features & capability matrix](FEATURES.md)' docs/README.md
grep -Fq '[Tính năng & ma trận khả năng](FEATURES.vi.md)' docs/README.vi.md

# Keep EN/VI feature references paired so public navigation does not drift.
grep -Fq '[Tiếng Việt](FEATURES.vi.md)' docs/FEATURES.md
grep -Fq '[English](FEATURES.md)' docs/FEATURES.vi.md

echo 'public release readiness checks passed'
