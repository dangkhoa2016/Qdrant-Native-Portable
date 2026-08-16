#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail_test() { echo "provider production test failed: $*" >&2; exit 1; }

for f in \
  deploy/huggingface-spaces/README.template.md \
  deploy/modal/app.py deploy/beam/app.py \
  examples/production/production-kaggle-example.sh \
  examples/production/production-google-colab-example.sh \
  examples/production/production-github-codespaces-example.sh \
  examples/production/production-huggingface-spaces-example.sh \
  examples/production/production-modal.com-example.sh \
  examples/production/collect-modal-validation-result.sh \
  examples/production/production-beam.cloud-example.sh \
  examples/production/collect-beam-validation-result.sh \
  examples/production/beam-sentinel.sh \
  examples/production/production-generic-linux-example.sh \
  examples/production/production-docker-single-example.sh; do
  [[ -f "$ROOT/$f" ]] || fail_test "missing $f"
done

grep -q 'sdk: docker' "$ROOT/deploy/huggingface-spaces/README.template.md" || fail_test "HF template is not Docker Space"
grep -q 'app_port: 6333' "$ROOT/deploy/huggingface-spaces/README.template.md" || fail_test "HF app port mismatch"
grep -q 'snapshot-persist' "$ROOT/deploy/huggingface-spaces/README.template.md" || fail_test "HF template must document safe snapshot persistence"
grep -q '/qdrant-persist' "$ROOT/deploy/huggingface-spaces/README.template.md" || fail_test "HF template must document the Bucket mount path"
grep -q 'direct-mount-experimental' "$ROOT/deploy/huggingface-spaces/README.template.md" || fail_test "HF template must label direct Bucket-backed live storage experimental"
grep -q 'QNP_ALLOW_UNSUPPORTED_STORAGE=1' "$ROOT/deploy/huggingface-spaces/README.template.md" || fail_test "HF direct mount must require explicit acknowledgement"
grep -q '\.dockerignore' "$ROOT/examples/production/production-huggingface-spaces-example.sh" || fail_test "HF staging helper must copy root .dockerignore"

grep -Eq 'max_containers[[:space:]]*=[[:space:]]*1' "$ROOT/deploy/modal/app.py" || fail_test "Modal is not pinned to one container"
grep -q '@app.server' "$ROOT/deploy/modal/app.py" || fail_test "Modal adapter must use the current app.server primitive"
if grep -q '@modal.web_server' "$ROOT/deploy/modal/app.py"; then
  fail_test "Modal adapter must not use the legacy web_server wrapper"
fi
grep -Fq '.entrypoint([])' "$ROOT/deploy/modal/app.py" || fail_test "Modal image must neutralize the Docker ENTRYPOINT so Modal Python runtime can start"
grep -q 'Volume.from_name' "$ROOT/deploy/modal/app.py" || fail_test "Modal adapter must attach durable snapshot storage"
grep -Eq 'volumes[[:space:]]*=[[:space:]]*\{[[:space:]]*"/qdrant-persist"' "$ROOT/deploy/modal/app.py" || fail_test "Modal persistent Volume must mount at /qdrant-persist"
if grep -Eq 'volumes[[:space:]]*=.*[/"]qdrant/storage' "$ROOT/deploy/modal/app.py"; then
  fail_test "Modal Volume must never be mounted as live /qdrant/storage"
fi
for setting in \
  'QNP_STORAGE_MODE.*snapshot-persist' \
  'QNP_PERSIST_PATH.*/qdrant-persist' \
  'QNP_REQUIRE_PERSIST_MOUNT.*1' \
  'QNP_AUTO_RESTORE.*1' \
  'MODAL_AUTO_SNAPSHOT_INTERVAL_SECONDS.*600' \
  'QNP_AUTO_SNAPSHOT_INTERVAL_SECONDS.*MODAL_AUTO_SNAPSHOT_INTERVAL_SECONDS' \
  'QNP_AUTO_SNAPSHOT_ON_SHUTDOWN.*0' \
  'QNP_SNAPSHOT_RETENTION.*3'; do
  grep -Eq "$setting" "$ROOT/deploy/modal/app.py" || fail_test "Modal adapter missing persistence setting: $setting"
done
grep -Eq 'unauthenticated[[:space:]]*=[[:space:]]*True' "$ROOT/deploy/modal/app.py" || fail_test "Modal proxy must pass public traffic through to Qdrant authentication"
grep -q '@modal.enter' "$ROOT/deploy/modal/app.py" || fail_test "Modal adapter must define startup lifecycle"
grep -q '@modal.exit' "$ROOT/deploy/modal/app.py" || fail_test "Modal adapter must define shutdown lifecycle"
grep -q 'persist_volume.commit' "$ROOT/deploy/modal/app.py" || fail_test "Modal shutdown must explicitly commit persistent snapshot files"
if grep -Eq 'QNP_AUTO_SNAPSHOT_ON_SHUTDOWN.*1' "$ROOT/deploy/modal/app.py"; then
  fail_test "Modal must not advertise a shutdown snapshot that provider shutdown ordering cannot guarantee"
fi
grep -q '/qdrant/qnp-entrypoint.sh' "$ROOT/deploy/modal/app.py" || fail_test "Modal lifecycle must launch the QNP production entrypoint"
grep -q 'modal secret create --force qnp-qdrant-secrets' "$ROOT/examples/production/production-modal.com-example.sh" || fail_test "Modal helper must safely update the deployment secret"
grep -q 'qnp-qdrant-persist' "$ROOT/examples/production/production-modal.com-example.sh" || fail_test "Modal helper must identify the persistent Volume"
grep -qi 'snapshot-persist' "$ROOT/examples/production/production-modal.com-example.sh" || fail_test "Modal helper must describe snapshot persistence"
grep -q 'collect-modal-validation-result.sh' "$ROOT/examples/production/production-modal.com-example.sh" || fail_test "Modal helper must point to the external result collector"
grep -q 'QDRANT_URL' "$ROOT/examples/production/collect-modal-validation-result.sh" || fail_test "Modal result collector must require the deployed Qdrant endpoint"
grep -q 'QDRANT_READ_ONLY_API_KEY' "$ROOT/examples/production/collect-modal-validation-result.sh" || fail_test "Modal result collector must use the read-only API key for Qdrant evidence"
grep -q 'qdrant-sentinel-point.json' "$ROOT/examples/production/collect-modal-validation-result.sh" || fail_test "Modal result collector must capture sentinel point evidence"
grep -q 'Modal Volume.*snapshot' "$ROOT/docs/PRODUCTION.md" || fail_test "English production docs must describe Modal snapshot persistence"
grep -q 'Modal Volume.*snapshot' "$ROOT/docs/PRODUCTION.vi.md" || fail_test "Vietnamese production docs must describe Modal snapshot persistence"
grep -Fq 'newly written sentinel survived a later scale-down/recreation' "$ROOT/docs/PRODUCTION.md" || fail_test "English production docs must record the final real Modal sentinel validation"
grep -Fq 'sentinel mới ghi đã sống sót qua một lần scale-down/recreation tiếp theo' "$ROOT/docs/PRODUCTION.vi.md" || fail_test "Vietnamese production docs must record the final real Modal sentinel validation"
grep -Fq 'newly written sentinel survived a later scale-down/recreation' "$ROOT/CHANGELOG.md" || fail_test "Changelog must record the final real Modal sentinel validation"

grep -q 'Pod' "$ROOT/deploy/beam/app.py" || fail_test "Beam adapter should use Pod"
grep -q 'Volume' "$ROOT/deploy/beam/app.py" || fail_test "Beam adapter must attach snapshot persistence Volume"
grep -q 'qnp-qdrant-persist' "$ROOT/deploy/beam/app.py" || fail_test "Beam adapter must use the canonical persistent Volume name"
grep -q '/qdrant-persist' "$ROOT/deploy/beam/app.py" || fail_test "Beam Volume must mount at /qdrant-persist"
grep -q 'snapshot-persist' "$ROOT/deploy/beam/app.py" || fail_test "Beam adapter must enable snapshot-persist"
grep -q 'QNP_AUTO_SNAPSHOT_ON_SHUTDOWN.*0' "$ROOT/deploy/beam/app.py" || fail_test "Beam must not claim an unproven shutdown snapshot"
if grep -Eq 'mount_path.*qdrant/storage' "$ROOT/deploy/beam/app.py"; then
  fail_test "Beam Volume must never be mounted as live /qdrant/storage"
fi
[[ -f "$ROOT/deploy/beam/entrypoint.sh" ]] || fail_test "Beam provider preflight entrypoint missing"
grep -q 'qnp-beam-volume-probe' "$ROOT/deploy/beam/entrypoint.sh" || fail_test "Beam provider preflight probe missing"
grep -q '/qdrant/qnp-entrypoint.sh' "$ROOT/deploy/beam/entrypoint.sh" || fail_test "Beam provider wrapper must launch QNP entrypoint"
grep -q 'beam secret create' "$ROOT/examples/production/production-beam.cloud-example.sh" || fail_test "Beam helper must create deployment secrets"
grep -q 'beam secret modify' "$ROOT/examples/production/production-beam.cloud-example.sh" || fail_test "Beam helper must safely update existing deployment secrets"
grep -q 'qnp-qdrant-persist' "$ROOT/examples/production/production-beam.cloud-example.sh" || fail_test "Beam helper must identify the persistent Volume"
grep -q 'beam-sentinel.sh' "$ROOT/examples/production/production-beam.cloud-example.sh" || fail_test "Beam helper must document sentinel validation"
grep -q 'collect-beam-validation-result.sh' "$ROOT/examples/production/production-beam.cloud-example.sh" || fail_test "Beam helper must document result collection"
grep -q 'beam container stop' "$ROOT/examples/production/production-beam.cloud-example.sh" || fail_test "Beam helper must document controlled container recreation"
grep -q 'beam ls' "$ROOT/examples/production/production-beam.cloud-example.sh" || fail_test "Beam helper must document Volume snapshot inspection"
BEAM_HELPER="$ROOT/examples/production/production-beam.cloud-example.sh"
INTEGRITY_CMD='python3 scripts/source-integrity.py check --root . --manifest SOURCE-MANIFEST.json --require-clean'
grep -Fq "$INTEGRITY_CMD" "$BEAM_HELPER" || fail_test "Beam helper must require clean canonical source before provider mutation"
integrity_line="$(grep -nF "$INTEGRITY_CMD" "$BEAM_HELPER" | head -n1 | cut -d: -f1)"
secret_invoke_line="$(grep -nF 'upsert_beam_secret QDRANT_API_KEY' "$BEAM_HELPER" | head -n1 | cut -d: -f1)"
volume_invoke_line="$(grep -nF 'if ! beam volume list' "$BEAM_HELPER" | head -n1 | cut -d: -f1)"
deploy_invoke_line="$(grep -nF 'beam deploy deploy/beam/app.py:pod' "$BEAM_HELPER" | head -n1 | cut -d: -f1)"
[[ "$integrity_line" -lt "$secret_invoke_line" ]] || fail_test "Beam integrity gate must run before secret mutation"
[[ "$integrity_line" -lt "$volume_invoke_line" ]] || fail_test "Beam integrity gate must run before Volume mutation"
[[ "$integrity_line" -lt "$deploy_invoke_line" ]] || fail_test "Beam integrity gate must run before deployment"
grep -Fq 'Beam Volume' "$ROOT/docs/PRODUCTION.md" || fail_test "English production docs must describe Beam Volume snapshot persistence"
grep -Fq 'snapshot-persist' "$ROOT/docs/PRODUCTION.md" || fail_test "English production docs must name Beam snapshot-persist mode"
grep -Fq 'Beam Volume' "$ROOT/docs/PRODUCTION.vi.md" || fail_test "Vietnamese production docs must describe Beam Volume snapshot persistence"
grep -Fq 'snapshot-persist' "$ROOT/docs/PRODUCTION.vi.md" || fail_test "Vietnamese production docs must name Beam snapshot-persist mode"

if grep -R 'QNP_TOPOLOGY=cluster' "$ROOT/deploy" "$ROOT/examples/production" >/dev/null 2>&1; then
  fail_test "provider production artifacts must not enable cluster"
fi

echo "production provider tests passed"

# QNP_PROVIDER_REAL_VALIDATION_PROMOTION_20260819
# Public provider maturity must not regress after the real HF/Modal/Beam validations.
for qnp_doc in \
  README.md README.vi.md \
  docs/FEATURES.md docs/FEATURES.vi.md \
  docs/PRODUCTION.md docs/PRODUCTION.vi.md
do
  grep -Eq 'Hugging Face Spaces.*Real-provider validated' "$qnp_doc" || {
    echo "provider production test failed: $qnp_doc must mark Hugging Face Spaces real-provider validated" >&2
    exit 1
  }
  grep -Eq 'Modal(\.com)?.*Real-provider validated' "$qnp_doc" || {
    echo "provider production test failed: $qnp_doc must mark Modal.com real-provider validated" >&2
    exit 1
  }
  grep -Eq 'Beam(\.cloud)?.*Real-provider validated' "$qnp_doc" || {
    echo "provider production test failed: $qnp_doc must mark Beam.cloud real-provider validated" >&2
    exit 1
  }
  if grep -Eq 'Beam(\.cloud)?.*(Supported adapter|Ephemeral by default)' "$qnp_doc"; then
    echo "provider production test failed: $qnp_doc contains stale Beam maturity wording" >&2
    exit 1
  fi
  if grep -Eq 'Hugging Face Spaces.*Validated snapshot-persistence adapter' "$qnp_doc"; then
    echo "provider production test failed: $qnp_doc contains stale Hugging Face maturity wording" >&2
    exit 1
  fi
done

