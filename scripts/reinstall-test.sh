#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname "$0")/common.sh"

reset_only=0
yes=0
force_unmanaged=0
dry_run=0

usage() {
    cat <<'EOF'
TEST-ONLY destructive reset/reinstall

Usage:
  bash qdrant.sh reset-test [--yes] [--force-unmanaged] [--dry-run]
  bash qdrant.sh reinstall-test [--yes] [--force-unmanaged] [--dry-run]

Behavior:
  reset-test      Stops project services and removes the entire Qdrant runtime
                  BASE_DIR, including binary, data, snapshots, logs, temp/cache,
                  benchmarks, credentials, downloads, config, and runtime state.
                  It does NOT reinstall Qdrant.

  reinstall-test  Performs the same clean reset, then runs setup again from
                  scratch. Hardware/platform/profile auto-detection is recomputed
                  unless you explicitly export overrides before invoking it.

Safety:
  - Normal setup/start/cleanup NEVER delete Qdrant data.
  - Existing non-empty runtimes require a managed instance marker.
  - Missing/empty BASE_DIR is treated as a fresh target and needs no marker.
  - For an older Qdrant-like instance without the marker, add --force-unmanaged.
  - --yes is required for non-interactive execution.
  - System packages and the optional service user are not removed.

Examples:
  bash qdrant.sh reinstall-test
  bash qdrant.sh reinstall-test --yes
  QDRANT_PROFILE=balanced-lite bash qdrant.sh reinstall-test --yes
  bash qdrant.sh reinstall-test --force-unmanaged --yes
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --reset-only) reset_only=1; shift ;;
        --yes|-y) yes=1; shift ;;
        --force-unmanaged) force_unmanaged=1; shift ;;
        --dry-run) dry_run=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) fail "Unknown reset/reinstall option: $1" ;;
    esac
done

assert_safe_destructive_base_dir
resolved_base="$(realpath -m "$BASE_DIR")"

# A fresh host may not have a runtime yet. Likewise, a previous interrupted
# attempt may have left an empty BASE_DIR. Neither case contains data to protect,
# so requiring an ownership marker would make CLEAN_REINSTALL unusable exactly
# when a clean baseline is being created. Unknown *non-empty* directories remain
# fail-closed below.
fresh_target=0
if base_dir_is_absent_or_empty; then
    fresh_target=1
fi

if [[ "$fresh_target" == "1" ]]; then
    info "BASE_DIR is absent or empty; no existing runtime needs destructive authorization: $resolved_base"
elif ! is_managed_instance; then
    if [[ "$force_unmanaged" != "1" ]]; then
        if looks_like_qdrant_instance; then
            fail "This looks like an older/unmanaged Qdrant runtime without the project marker. Re-run with --force-unmanaged after verifying BASE_DIR=$resolved_base"
        fi
        fail "Managed Qdrant instance marker not found at $INSTANCE_MARKER. Refusing to delete $resolved_base"
    fi
    looks_like_qdrant_instance || fail "--force-unmanaged was supplied, but $resolved_base does not look like a Qdrant runtime. Refusing deletion."
    warn "Forcing cleanup of an older/unmanaged runtime: $resolved_base"
fi

banner "TEST-ONLY clean reset" "This operation destroys the Qdrant runtime under $resolved_base"
warn "Will delete binary, storage, snapshots, logs, temp/cache, benchmarks, credentials, downloads, config, backups, and runtime state."
warn "Normal setup/start/cleanup do NOT perform this deletion."

if [[ "$dry_run" == "1" ]]; then
    info "Dry run only; nothing will be changed"
    printf 'Would stop project services and remove:\n  %s\n' "$resolved_base"
    [[ "$reset_only" == "1" ]] || printf 'Would then run a fresh setup.\n'
    exit 0
fi

if [[ "$yes" != "1" ]]; then
    [[ -t 0 ]] || fail "Non-interactive destructive reset requires --yes"
    printf 'Type the exact BASE_DIR to confirm deletion:\n%s\n> ' "$resolved_base"
    IFS= read -r confirmation
    [[ "$confirmation" == "$resolved_base" ]] || fail "Confirmation did not match BASE_DIR; nothing was deleted"
fi

# Stop ingress/processes before removing their runtime state. Fail-soft because
# an old or partially broken test install may already have stale PID/config files.
bash "$SCRIPT_DIR/public-access.sh" --stop >/dev/null 2>&1 || true
disable_proxy_config >/dev/null 2>&1 || true
stop_pid_file "Qdrant" "$QDRANT_PID_FILE" >/dev/null 2>&1 || true

# BASE_DIR itself is the deletion boundary. We deliberately do not remove apt
# packages or the optional service account; those are host-level dependencies,
# not Qdrant runtime state.
rm -rf --one-file-system "$resolved_base"
rm -f "$PROJECT_DIR/.qdrant-base"
ok "Removed Qdrant runtime: $resolved_base"

if [[ "$reset_only" == "1" ]]; then
    ok "Clean reset complete; Qdrant was not reinstalled"
    muted "Fresh install later: bash qdrant.sh setup"
    exit 0
fi

header "Fresh reinstall"
info "Re-running setup from an empty runtime directory"
# Explicit environment overrides supplied by the caller remain exported. Stale
# runtime.env values are gone, so auto settings are recomputed from this host.
exec bash "$PROJECT_DIR/run_all.sh"
