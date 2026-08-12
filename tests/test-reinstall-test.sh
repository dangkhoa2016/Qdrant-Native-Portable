#!/usr/bin/env bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"; rm -f "$PROJECT_DIR/.qdrant-base"' EXIT

managed="$tmp/managed/runtime"
mkdir -p "$managed/storage" "$managed/logs" "$managed/config"
printf 'project=qdrant-native-portable\nschema=1\n' > "$managed/.qdrant-native-portable-instance"
printf 'old-data\n' > "$managed/storage/old.bin"
printf 'old-log\n' > "$managed/logs/qdrant.log"
printf 'test\n' > "$managed/config/qdrant.yaml"

BASE_DIR="$managed" QDRANT_PLATFORM=generic-linux PROCESS_MODE=current-user DEPLOYMENT_MODE=minimal PUBLIC_MODE=none \
  bash "$PROJECT_DIR/scripts/reinstall-test.sh" --reset-only --yes >/dev/null
[[ ! -e "$managed" ]]

unmanaged="$tmp/unmanaged/runtime"
mkdir -p "$unmanaged/storage" "$unmanaged/config"
printf 'test\n' > "$unmanaged/config/qdrant.yaml"
if BASE_DIR="$unmanaged" QDRANT_PLATFORM=generic-linux PROCESS_MODE=current-user DEPLOYMENT_MODE=minimal PUBLIC_MODE=none \
  bash "$PROJECT_DIR/scripts/reinstall-test.sh" --reset-only --yes >/dev/null 2>&1; then
    echo 'unmanaged reset unexpectedly succeeded without --force-unmanaged' >&2
    exit 1
fi
[[ -e "$unmanaged" ]]
BASE_DIR="$unmanaged" QDRANT_PLATFORM=generic-linux PROCESS_MODE=current-user DEPLOYMENT_MODE=minimal PUBLIC_MODE=none \
  bash "$PROJECT_DIR/scripts/reinstall-test.sh" --reset-only --force-unmanaged --yes >/dev/null
[[ ! -e "$unmanaged" ]]

# A clean benchmark on a fresh host may point at a BASE_DIR that does not yet
# exist. There is nothing destructive to authorize in that case; reset-only
# should be a no-op and must not require a managed marker or --force-unmanaged.
fresh_missing="$tmp/fresh-missing/runtime"
BASE_DIR="$fresh_missing" QDRANT_PLATFORM=generic-linux PROCESS_MODE=current-user DEPLOYMENT_MODE=minimal PUBLIC_MODE=none \
  bash "$PROJECT_DIR/scripts/reinstall-test.sh" --reset-only --yes >/dev/null
[[ ! -e "$fresh_missing" ]]

# An existing but completely empty BASE_DIR is equally safe: it contains no
# runtime/user content to protect, so reset-only may remove it without marker.
fresh_empty="$tmp/fresh-empty/runtime"
mkdir -p "$fresh_empty"
BASE_DIR="$fresh_empty" QDRANT_PLATFORM=generic-linux PROCESS_MODE=current-user DEPLOYMENT_MODE=minimal PUBLIC_MODE=none \
  bash "$PROJECT_DIR/scripts/reinstall-test.sh" --reset-only --yes >/dev/null
[[ ! -e "$fresh_empty" ]]

# Unknown non-empty directories must remain fail-closed even when
# --force-unmanaged is supplied.
unknown_nonempty="$tmp/unknown/runtime"
mkdir -p "$unknown_nonempty"
printf 'keep-me\n' > "$unknown_nonempty/unrelated.txt"
if BASE_DIR="$unknown_nonempty" QDRANT_PLATFORM=generic-linux PROCESS_MODE=current-user DEPLOYMENT_MODE=minimal PUBLIC_MODE=none \
  bash "$PROJECT_DIR/scripts/reinstall-test.sh" --reset-only --force-unmanaged --yes >/dev/null 2>&1; then
    echo 'unknown non-empty directory unexpectedly accepted with --force-unmanaged' >&2
    exit 1
fi
[[ -f "$unknown_nonempty/unrelated.txt" ]]

# Broad/system path must always be refused before deletion.
if BASE_DIR=/tmp QDRANT_PLATFORM=generic-linux PROCESS_MODE=current-user DEPLOYMENT_MODE=minimal PUBLIC_MODE=none \
  bash "$PROJECT_DIR/scripts/reinstall-test.sh" --reset-only --force-unmanaged --yes >/dev/null 2>&1; then
    echo 'broad path /tmp unexpectedly accepted' >&2
    exit 1
fi

echo 'test reset/reinstall guardrail tests passed'
