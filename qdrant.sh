#!/usr/bin/env bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$PROJECT_DIR"
source "$PROJECT_DIR/scripts/common.sh"

usage() {
    cat <<'EOF_USAGE'
Qdrant Native Portable helper

Usage:
  bash qdrant.sh setup
  bash qdrant.sh production-check
  bash qdrant.sh prepare
  bash qdrant.sh serve
  bash qdrant.sh start|stop|restart|status|health
  bash qdrant.sh public|public-stop
  bash qdrant.sh examples
  bash qdrant.sh credentials <args...>
  bash qdrant.sh snapshots <args...>
  bash qdrant.sh backup <args...>
  bash qdrant.sh system-info
  bash qdrant.sh doctor
  bash qdrant.sh metrics
  bash qdrant.sh profile-advisor [--points N --dimension N]
  bash qdrant.sh benchmark [benchmark args...]
  bash qdrant.sh benchmark-suite [suite args...]
  bash qdrant.sh benchmark-status [status args...]
  bash qdrant.sh benchmark-profiles [profile A/B args...]
  bash qdrant.sh benchmark-acceptance [acceptance args...]
  bash qdrant.sh compare-benchmarks [run dirs/ZIPs...]
  bash qdrant.sh auth-check
  bash qdrant.sh source-integrity <manifest|check> [args...]
  bash qdrant.sh security-check
  bash qdrant.sh cleanup
  bash qdrant.sh purge-all-test --yes [--dry-run] [--reinstall]
  bash qdrant.sh reset-test [--yes] [--force-unmanaged]
  bash qdrant.sh reinstall-test [--yes] [--force-unmanaged]

Single-node production:
  QNP_ENV=production QNP_RUNTIME=native|docker QNP_TOPOLOGY=single
  Production defaults to PUBLIC_MODE=none and no demo data.

Key modes:
  QDRANT_PROFILE=low-memory|balanced-lite|balanced-memory|balanced|performance
  PROCESS_MODE=current-user|service-user
  DEPLOYMENT_MODE=minimal|proxy
  PUBLIC_MODE=cloudflare-quick|platform|none
EOF_USAGE
}

cmd="${1:-}"; shift || true
case "$cmd" in
    setup) bash run_all.sh "$@" ;;
    production-check) bash scripts/production-check.sh "$@" ;;
    prepare) bash scripts/production-prepare.sh "$@" ;;
    serve) bash scripts/production-serve.sh "$@" ;;
    start) bash scripts/service-manager.sh --action start --service all ;;
    stop) bash scripts/service-manager.sh --action stop --service all ;;
    restart) bash scripts/service-manager.sh --action restart --service all ;;
    status) bash scripts/service-manager.sh --action status --service public ;;
    health) bash scripts/09_health_check.sh ;;
    public) bash scripts/public-access.sh "$@" ;;
    public-stop|tunnel-stop) bash scripts/public-access.sh --stop ;;
    examples) bash examples/run_examples.sh ;;
    credentials) bash scripts/credentials-manager.sh "$@" ;;
    snapshots) bash scripts/snapshot-manager.sh "$@" ;;
    backup) bash scripts/backup-manager.sh "$@" ;;
    system-info) bash scripts/system-info.sh ;;
    doctor) bash scripts/doctor.sh ;;
    metrics) bash scripts/metrics.sh "$@" ;;
    profile-advisor|profile) bash scripts/profile-advisor.sh "$@" ;;
    benchmark) bash scripts/benchmark.sh "$@" ;;
    benchmark-suite) bash scripts/benchmark-suite.sh "$@" ;;
    benchmark-status) bash scripts/benchmark-status.sh "$@" ;;
    benchmark-profiles) bash scripts/benchmark-profiles.sh "$@" ;;
    benchmark-acceptance) bash scripts/benchmark-acceptance.sh "$@" ;;
    compare-benchmarks) bash scripts/compare-benchmarks.sh "$@" ;;
    auth-check) bash scripts/auth-check.sh "$@" ;;
    source-integrity) python3 scripts/source-integrity.py "$@" ;;
    security-check) bash scripts/security-check.sh ;;
    cleanup) bash scripts/cleanup.sh ;;
    purge-all-test) bash scripts/purge-all-test.sh "$@" ;;
    reset-test) bash scripts/reinstall-test.sh --reset-only "$@" ;;
    reinstall-test) bash scripts/reinstall-test.sh "$@" ;;
    -h|--help|help|"") usage ;;
    *) echo "Unknown command: $cmd" >&2; usage >&2; exit 1 ;;
esac
