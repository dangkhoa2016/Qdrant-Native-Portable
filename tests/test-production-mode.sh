#!/usr/bin/env bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

fail_test() { echo "production mode test failed: $*" >&2; exit 1; }

# shellcheck disable=SC2016
run_common() {
  env -i PATH="$PATH" HOME="${HOME:-/tmp}" PROJECT_DIR="$PROJECT_DIR" \
    QDRANT_PLATFORM=generic-linux "$@" bash -c '
      set -euo pipefail
      cd "$PROJECT_DIR"
      source scripts/common.sh
      printf "%s|%s|%s|%s|%s|%s|%s\n" \
        "$QNP_ENV" "$QNP_RUNTIME" "$QNP_TOPOLOGY" "$QNP_CREATE_DEMO_DATA" \
        "$QNP_SECRET_POLICY" "$PUBLIC_MODE" "$QDRANT_BIND_HOST"
    '
}

dev="$(run_common env)"
[[ "$dev" == "development|native|single|1|generate|cloudflare-quick|127.0.0.1" ]] || fail_test "unexpected development defaults: $dev"

prod="$(run_common env QNP_ENV=production)"
[[ "$prod" == "production|native|single|0|require-env|none|127.0.0.1" ]] || fail_test "unexpected production defaults: $prod"

# Production secret policy is fail-closed even when a caller tries to override it.
if run_common env QNP_ENV=production QNP_SECRET_POLICY=generate >/tmp/qnp-prod-policy.out 2>&1; then
  fail_test "production unexpectedly accepted QNP_SECRET_POLICY=generate"
fi
grep -q "require-env" /tmp/qnp-prod-policy.out || fail_test "missing production require-env policy message"

docker_prod="$(run_common env QNP_ENV=production QNP_RUNTIME=docker)"
[[ "$docker_prod" == "production|docker|single|0|require-env|none|0.0.0.0" ]] || fail_test "unexpected docker defaults: $docker_prod"

# production-check must fail when secrets are absent
if env -i PATH="$PATH" HOME="${HOME:-/tmp}" QDRANT_PLATFORM=generic-linux QNP_ENV=production \
  bash "$PROJECT_DIR/scripts/production-check.sh" >/tmp/qnp-prod-check.out 2>&1; then
  fail_test "production-check unexpectedly accepted missing secrets"
fi
grep -q "QDRANT_API_KEY" /tmp/qnp-prod-check.out || fail_test "missing admin-key failure message"

# identical keys must fail
if env -i PATH="$PATH" HOME="${HOME:-/tmp}" QDRANT_PLATFORM=generic-linux QNP_ENV=production \
  QDRANT_API_KEY=same QDRANT_READ_ONLY_API_KEY=same \
  bash "$PROJECT_DIR/scripts/production-check.sh" >/tmp/qnp-prod-check.out 2>&1; then
  fail_test "production-check unexpectedly accepted identical keys"
fi
grep -qi "different" /tmp/qnp-prod-check.out || fail_test "missing distinct-key failure message"

# quick tunnel requires explicit production acknowledgement
if env -i PATH="$PATH" HOME="${HOME:-/tmp}" QDRANT_PLATFORM=generic-linux QNP_ENV=production \
  QDRANT_API_KEY=admin QDRANT_READ_ONLY_API_KEY=readonly PUBLIC_MODE=cloudflare-quick \
  bash "$PROJECT_DIR/scripts/production-check.sh" >/tmp/qnp-prod-check.out 2>&1; then
  fail_test "production-check unexpectedly accepted unacknowledged quick tunnel"
fi
grep -q "QNP_ALLOW_DEMO_TUNNEL=1" /tmp/qnp-prod-check.out || fail_test "missing tunnel acknowledgement hint"

env -i PATH="$PATH" HOME="${HOME:-/tmp}" QDRANT_PLATFORM=generic-linux QNP_ENV=production \
  QDRANT_API_KEY=admin QDRANT_READ_ONLY_API_KEY=readonly PUBLIC_MODE=cloudflare-quick QNP_ALLOW_DEMO_TUNNEL=1 QDRANT_SHA256=abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789 \
  bash "$PROJECT_DIR/scripts/production-check.sh" >/tmp/qnp-prod-check.out 2>&1 || fail_test "acknowledged quick tunnel should pass"

# cluster must be rejected in this revision
if env -i PATH="$PATH" HOME="${HOME:-/tmp}" QDRANT_PLATFORM=generic-linux QNP_ENV=production \
  QDRANT_API_KEY=admin QDRANT_READ_ONLY_API_KEY=readonly QNP_TOPOLOGY=cluster \
  bash "$PROJECT_DIR/scripts/production-check.sh" >/tmp/qnp-prod-check.out 2>&1; then
  fail_test "production-check unexpectedly accepted cluster topology"
fi
grep -qi "single" /tmp/qnp-prod-check.out || fail_test "missing single-node topology failure message"

# native production must require QDRANT_SHA256
if env -i PATH="$PATH" HOME="${HOME:-/tmp}" QDRANT_PLATFORM=generic-linux QNP_ENV=production \
  QDRANT_API_KEY=admin QDRANT_READ_ONLY_API_KEY=readonly QNP_RUNTIME=native \
  bash "$PROJECT_DIR/scripts/production-check.sh" >/tmp/qnp-prod-check.out 2>&1; then
  fail_test "production-check unexpectedly accepted native without QDRANT_SHA256"
fi
grep -q "QDRANT_SHA256" /tmp/qnp-prod-check.out || fail_test "missing QDRANT_SHA256 failure message"

# malformed SHA256 must fail
if env -i PATH="$PATH" HOME="${HOME:-/tmp}" QDRANT_PLATFORM=generic-linux QNP_ENV=production \
  QDRANT_API_KEY=admin QDRANT_READ_ONLY_API_KEY=readonly QNP_RUNTIME=native QDRANT_SHA256=abc123 \
  bash "$PROJECT_DIR/scripts/production-check.sh" >/tmp/qnp-prod-check.out 2>&1; then
  fail_test "production-check unexpectedly accepted malformed QDRANT_SHA256"
fi
grep -q "64-hex" /tmp/qnp-prod-check.out || fail_test "missing 64-hex format failure message"

# 63 hex chars must fail
if env -i PATH="$PATH" HOME="${HOME:-/tmp}" QDRANT_PLATFORM=generic-linux QNP_ENV=production \
  QDRANT_API_KEY=admin QDRANT_READ_ONLY_API_KEY=readonly QNP_RUNTIME=native QDRANT_SHA256=abcdef0123456789abcdef0123456789abcdef0123456789abcdef012345678 \
  bash "$PROJECT_DIR/scripts/production-check.sh" >/tmp/qnp-prod-check.out 2>&1; then
  fail_test "production-check unexpectedly accepted 63-char QDRANT_SHA256"
fi

# 65 hex chars must fail
if env -i PATH="$PATH" HOME="${HOME:-/tmp}" QDRANT_PLATFORM=generic-linux QNP_ENV=production \
  QDRANT_API_KEY=admin QDRANT_READ_ONLY_API_KEY=readonly QNP_RUNTIME=native QDRANT_SHA256=abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abc \
  bash "$PROJECT_DIR/scripts/production-check.sh" >/tmp/qnp-prod-check.out 2>&1; then
  fail_test "production-check unexpectedly accepted 65-char QDRANT_SHA256"
fi

# non-hex 64 chars must fail
if env -i PATH="$PATH" HOME="${HOME:-/tmp}" QDRANT_PLATFORM=generic-linux QNP_ENV=production \
  QDRANT_API_KEY=admin QDRANT_READ_ONLY_API_KEY=readonly QNP_RUNTIME=native QDRANT_SHA256=zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz \
  bash "$PROJECT_DIR/scripts/production-check.sh" >/tmp/qnp-prod-check.out 2>&1; then
  fail_test "production-check unexpectedly accepted non-hex QDRANT_SHA256"
fi

# valid 64 hex SHA256 must pass
env -i PATH="$PATH" HOME="${HOME:-/tmp}" QDRANT_PLATFORM=generic-linux QNP_ENV=production \
  QDRANT_API_KEY=admin QDRANT_READ_ONLY_API_KEY=readonly QNP_RUNTIME=native QDRANT_SHA256=abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789 \
  bash "$PROJECT_DIR/scripts/production-check.sh" >/tmp/qnp-prod-check.out 2>&1 || fail_test "native production with valid 64-hex SHA256 should pass"

# Direct production commands must not bypass the Quick Tunnel acknowledgement.
# shellcheck disable=SC2016
if env -i PATH="$PATH" HOME="${HOME:-/tmp}" PROJECT_DIR="$PROJECT_DIR" QDRANT_PLATFORM=generic-linux \
  QNP_ENV=production PUBLIC_MODE=cloudflare-quick \
  bash -c 'cd "$PROJECT_DIR"; source scripts/common.sh' >/tmp/qnp-prod-common.out 2>&1; then
  fail_test "common policy unexpectedly accepted unacknowledged production Quick Tunnel"
fi
grep -q "QNP_ALLOW_DEMO_TUNNEL=1" /tmp/qnp-prod-common.out || fail_test "common policy missing tunnel acknowledgement hint"


# Generic production helpers must also refuse persisted-secret fallback.
helper_tmp="$(mktemp -d)"
cat > "$helper_tmp/secrets.env" <<'EOF_HELPER_SECRETS'
QDRANT_API_KEY=stale-admin
QDRANT_READ_ONLY_API_KEY=stale-readonly
EOF_HELPER_SECRETS
# shellcheck disable=SC2016
if env -i PATH="$PATH" HOME="${HOME:-/tmp}" PROJECT_DIR="$PROJECT_DIR" QDRANT_PLATFORM=generic-linux BASE_DIR="$helper_tmp" \
  QNP_ENV=production QNP_SECRET_POLICY=require-env PROCESS_MODE=current-user DEPLOYMENT_MODE=minimal PUBLIC_MODE=none \
  bash -c 'cd "$PROJECT_DIR"; source scripts/common.sh; require_secrets' >/tmp/qnp-prod-helper-secrets.out 2>&1; then
  rm -rf "$helper_tmp"
  fail_test "require_secrets unexpectedly loaded persisted secrets in production"
fi
rm -rf "$helper_tmp"

# require-env must not fall back to a persisted secrets.env and must not persist
# caller-injected production secrets at rest.
prod_tmp="$(mktemp -d)"
mkdir -p "$prod_tmp"
cat > "$prod_tmp/secrets.env" <<'EOF_SECRETS'
QDRANT_API_KEY=persisted-admin
QDRANT_READ_ONLY_API_KEY=persisted-readonly
EOF_SECRETS
if env -i PATH="$PATH" HOME="${HOME:-/tmp}" QDRANT_PLATFORM=generic-linux BASE_DIR="$prod_tmp" \
  QNP_ENV=production QNP_SECRET_POLICY=require-env PROCESS_MODE=current-user DEPLOYMENT_MODE=minimal PUBLIC_MODE=none \
  bash "$PROJECT_DIR/scripts/01_credentials.sh" >/tmp/qnp-prod-creds.out 2>&1; then
  rm -rf "$prod_tmp"
  fail_test "require-env unexpectedly accepted only persisted credentials"
fi
grep -q "supplied explicitly" /tmp/qnp-prod-creds.out || { rm -rf "$prod_tmp"; fail_test "missing explicit-secret failure message"; }
rm -f "$prod_tmp/secrets.env"
env -i PATH="$PATH" HOME="${HOME:-/tmp}" QDRANT_PLATFORM=generic-linux BASE_DIR="$prod_tmp" \
  QNP_ENV=production QNP_SECRET_POLICY=require-env PROCESS_MODE=current-user DEPLOYMENT_MODE=minimal PUBLIC_MODE=none \
  QDRANT_API_KEY=caller-admin QDRANT_READ_ONLY_API_KEY=caller-readonly \
  bash "$PROJECT_DIR/scripts/01_credentials.sh" >/tmp/qnp-prod-creds.out 2>&1 || { rm -rf "$prod_tmp"; fail_test "explicit production credentials should pass"; }
[[ ! -e "$prod_tmp/secrets.env" ]] || { rm -rf "$prod_tmp"; fail_test "require-env must not persist production secrets.env"; }
rm -rf "$prod_tmp"

echo "production mode tests passed"
