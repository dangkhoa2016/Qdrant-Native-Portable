#!/usr/bin/env bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
source_zip="$PROJECT_DIR/qdrant-benchmarks-test-purge.zip"
source_sha="$source_zip.sha256"
trap 'rm -rf "$tmp"; rm -f "$PROJECT_DIR/.qdrant-base" "$source_zip" "$source_sha"' EXIT

purge="$PROJECT_DIR/scripts/purge-all-test.sh"
[[ -f "$purge" ]] || { echo 'purge-all-test.sh missing' >&2; exit 1; }

make_managed() {
  local path="$1"
  mkdir -p "$path/storage" "$path/run"
  printf 'project=qdrant-native-portable\nschema=1\n' > "$path/.qdrant-native-portable-instance"
  printf 'data\n' > "$path/storage/data.bin"
}

make_legacy() {
  local path="$1"
  mkdir -p "$path/config" "$path/storage"
  printf 'storage:\n  storage_path: storage\n' > "$path/config/qdrant.yaml"
  printf 'data\n' > "$path/storage/data.bin"
}

# Dry-run discovers current BASE_DIR, .qdrant-base pointer, platform default,
# and benchmark export root but must not delete anything.
current="$tmp/current/runtime"
pointer="$tmp/pointer/runtime"
home="$tmp/home"
default="$home/.local/share/qdrant-native-portable"
exports="$tmp/exports/qdrant-benchmark-exports"
make_managed "$current"
make_legacy "$pointer"
make_managed "$default"
mkdir -p "$exports/run-old"
printf 'old benchmark\n' > "$exports/run-old/report.txt"
printf '%s\n' "$pointer" > "$PROJECT_DIR/.qdrant-base"
printf 'zip\n' > "$source_zip"
printf 'sha\n' > "$source_sha"

BASE_DIR="$current" HOME="$home" QDRANT_PLATFORM=generic-linux \
QDRANT_BENCHMARK_EXPORT_DIR="$exports" PROCESS_MODE=current-user DEPLOYMENT_MODE=minimal PUBLIC_MODE=none \
  bash "$purge" --dry-run --yes >/dev/null
[[ -e "$current/storage/data.bin" ]]
[[ -e "$pointer/storage/data.bin" ]]
[[ -e "$default/storage/data.bin" ]]
[[ -e "$exports/run-old/report.txt" ]]
[[ -e "$source_zip" ]]

# Real purge removes every recognized project runtime candidate, benchmark
# exports, local pointer, and known generated benchmark archives.
BASE_DIR="$current" HOME="$home" QDRANT_PLATFORM=generic-linux \
QDRANT_BENCHMARK_EXPORT_DIR="$exports" PROCESS_MODE=current-user DEPLOYMENT_MODE=minimal PUBLIC_MODE=none \
  bash "$purge" --yes >/dev/null
[[ ! -e "$current" ]]
[[ ! -e "$pointer" ]]
[[ ! -e "$default" ]]
[[ ! -e "$exports" ]]
[[ ! -e "$PROJECT_DIR/.qdrant-base" ]]
[[ ! -e "$source_zip" ]]
[[ ! -e "$source_sha" ]]

# Preflight must be atomic: an unknown non-empty candidate makes the whole
# operation fail BEFORE any recognized runtime is removed.
managed2="$tmp/atomic/managed"
unknown="$tmp/atomic/unknown"
make_managed "$managed2"
mkdir -p "$unknown"
printf 'personal file\n' > "$unknown/keep.txt"
set +e
BASE_DIR="$managed2" HOME="$home" QDRANT_PLATFORM=generic-linux \
QDRANT_BENCHMARK_EXPORT_DIR="$tmp/atomic/exports" PROCESS_MODE=current-user DEPLOYMENT_MODE=minimal PUBLIC_MODE=none \
  bash "$purge" --yes --base-dir "$unknown" >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" -ne 0 ]]
[[ -e "$managed2/storage/data.bin" ]]
[[ -e "$unknown/keep.txt" ]]

# Broad paths remain forbidden even with explicit --base-dir.
set +e
BASE_DIR="$tmp/safe/runtime" HOME="$home" QDRANT_PLATFORM=generic-linux \
PROCESS_MODE=current-user DEPLOYMENT_MODE=minimal PUBLIC_MODE=none \
  bash "$purge" --yes --base-dir /tmp >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" -ne 0 ]]

# Non-interactive destructive execution must require --yes.
set +e
BASE_DIR="$tmp/no-yes/runtime" HOME="$home" QDRANT_PLATFORM=generic-linux \
PROCESS_MODE=current-user DEPLOYMENT_MODE=minimal PUBLIC_MODE=none \
  bash "$purge" >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" -ne 0 ]]

echo 'purge-all-test guardrail tests passed'
