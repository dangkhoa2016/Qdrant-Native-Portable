#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname "$0")/common.sh"

yes=0
dry_run=0
reinstall=0
keep_benchmark_exports=0
declare -a extra_base_dirs=()

usage() {
    cat <<'EOF_USAGE'
TEST-ONLY full project data purge

Usage:
  bash qdrant.sh purge-all-test --yes [--dry-run] [--reinstall]
  bash qdrant.sh purge-all-test --yes --base-dir /custom/runtime

Purpose:
  Removes Qdrant Native Portable runtime data across the current host without
  requiring the caller to know which platform-specific BASE_DIR was used.

Automatically discovers:
  - current resolved BASE_DIR
  - .qdrant-base pointer from this source tree
  - the platform default runtime path
  - managed runtimes under narrow platform-specific project roots
  - optional extra runtime paths supplied with --base-dir or
    QDRANT_PURGE_EXTRA_BASE_DIRS (colon-separated)

Also removes:
  - Qdrant storage, snapshots, logs, credentials, config, downloads, binaries,
    temp/cache, tokens, recovery backups, and benchmark data inside runtimes
  - benchmark export artifacts under the configured/default benchmark export root
  - local project pointer/generated benchmark ZIPs and Python cache files

Safety:
  - --yes is mandatory for destructive execution
  - --dry-run prints the plan and changes nothing
  - broad/system/source paths are always refused
  - every non-empty runtime candidate must look like a Qdrant Native Portable
    runtime before any deletion begins
  - preflight is atomic: one unsafe candidate aborts before deleting anything
  - source repository files are never deleted, except known generated artifacts

Options:
  --yes, -y                 authorize destructive purge
  --dry-run                 print deletion plan only
  --reinstall               run a fresh setup after purge
  --base-dir PATH           add an explicit runtime candidate (repeatable)
  --keep-benchmark-exports  preserve external benchmark result artifacts
  -h, --help                show this help
EOF_USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --yes|-y) yes=1; shift ;;
        --dry-run) dry_run=1; shift ;;
        --reinstall) reinstall=1; shift ;;
        --keep-benchmark-exports) keep_benchmark_exports=1; shift ;;
        --base-dir)
            [[ $# -ge 2 && -n "${2:-}" ]] || fail "--base-dir requires a path"
            extra_base_dirs+=("$2")
            shift 2
            ;;
        -h|--help) usage; exit 0 ;;
        *) fail "Unknown purge-all-test option: $1" ;;
    esac
done

if [[ "$dry_run" != "1" && "$yes" != "1" ]]; then
    fail "purge-all-test is destructive and requires --yes (or use --dry-run)"
fi

normalize_path() {
    realpath -m "$1"
}

assert_safe_candidate_path() {
    local candidate="$1" resolved home_resolved project_resolved
    resolved="$(normalize_path "$candidate")"
    home_resolved="$(normalize_path "${HOME:-/nonexistent}")"
    project_resolved="$(normalize_path "$PROJECT_DIR")"

    [[ "$resolved" == /* ]] || fail "Destructive purge requires an absolute path: $resolved"
    [[ "$resolved" != "/" ]] || fail "Refusing destructive purge on /"
    [[ "$resolved" != "$home_resolved" ]] || fail "Refusing destructive purge on HOME: $resolved"
    [[ "$resolved" != "$project_resolved" ]] || fail "Refusing destructive purge on source repository: $resolved"
    case "$resolved" in
        /content|/kaggle|/kaggle/working|/workspaces|/workspace|/root|/home|/tmp|/var|/usr|/etc)
            fail "Refusing destructive purge on broad/system path: $resolved" ;;
    esac
    [[ ${#resolved} -ge 12 ]] || fail "Destructive purge path is suspiciously short: $resolved"
}

path_is_absent_or_empty() {
    local path="$1"
    [[ ! -e "$path" ]] && return 0
    [[ -d "$path" ]] || return 1
    [[ -z "$(find "$path" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]
}

path_looks_like_qdrant_runtime() {
    local path="$1"
    [[ -f "$path/.qdrant-native-portable-instance" ]] && \
        grep -qx 'project=qdrant-native-portable' "$path/.qdrant-native-portable-instance" 2>/dev/null && return 0
    [[ -f "$path/runtime.env" || -f "$path/secrets.env" || -f "$path/config/qdrant.yaml" || \
       -d "$path/storage" || -x "$path/bin/qdrant" ]]
}

# Runtime candidate discovery is intentionally narrow. It follows current
# configuration/pointers plus known project defaults and ownership markers; it
# does not recursively search the whole host for arbitrary "qdrant" directories.
declare -a runtime_candidates=()
declare -A runtime_seen=()
add_runtime_candidate() {
    local raw="${1:-}" resolved
    [[ -n "$raw" ]] || return 0
    resolved="$(normalize_path "$raw")"
    [[ -n "${runtime_seen[$resolved]:-}" ]] && return 0
    runtime_seen["$resolved"]=1
    runtime_candidates+=("$resolved")
}

add_runtime_candidate "$BASE_DIR"
if [[ -f "$PROJECT_DIR/.qdrant-base" ]]; then
    pointer_path="$(head -n 1 "$PROJECT_DIR/.qdrant-base" 2>/dev/null || true)"
    [[ -n "$pointer_path" ]] && add_runtime_candidate "$pointer_path"
fi
add_runtime_candidate "$(default_base_dir)"

case "$PLATFORM" in
    google-colab) add_runtime_candidate "/content/qdrant-stack" ;;
    kaggle) add_runtime_candidate "/kaggle/working/qdrant-stack" ;;
    github-codespaces|codesandbox|generic-linux)
        add_runtime_candidate "${HOME:-/tmp}/.local/share/qdrant-native-portable"
        ;;
esac

if [[ -n "${QDRANT_PURGE_EXTRA_BASE_DIRS:-}" ]]; then
    IFS=':' read -r -a env_extra_dirs <<< "$QDRANT_PURGE_EXTRA_BASE_DIRS"
    for candidate in "${env_extra_dirs[@]}"; do add_runtime_candidate "$candidate"; done
fi
for candidate in "${extra_base_dirs[@]}"; do add_runtime_candidate "$candidate"; done

# Discover additional managed runtimes only under narrow project-specific roots.
declare -a marker_roots=()
[[ -d "${HOME:-/nonexistent}/.local/share" ]] && marker_roots+=("${HOME}/.local/share")
case "$PLATFORM" in
    google-colab) [[ -d /content ]] && marker_roots+=(/content) ;;
    kaggle) [[ -d /kaggle/working ]] && marker_roots+=(/kaggle/working) ;;
esac
for root in "${marker_roots[@]}"; do
    while IFS= read -r -d '' marker; do
        add_runtime_candidate "$(dirname "$marker")"
    done < <(find "$root" -maxdepth 4 -type f -name '.qdrant-native-portable-instance' -print0 2>/dev/null || true)
done

# Benchmark export root can be customized independently from BASE_DIR.
benchmark_export_root="${QDRANT_BENCHMARK_EXPORT_DIR:-${HOME:-/tmp}/qdrant-benchmark-exports}"
benchmark_export_root="$(normalize_path "$benchmark_export_root")"

# ---------- Preflight: validate the full deletion plan before changing state.
banner "TEST-ONLY full project purge" "Preflight all runtime and benchmark paths before deletion"
printf 'Platform: %s\n' "$PLATFORM"
printf 'Current BASE_DIR: %s\n' "$BASE_DIR"
printf 'Discovered runtime candidates: %s\n' "${#runtime_candidates[@]}"

for candidate in "${runtime_candidates[@]}"; do
    assert_safe_candidate_path "$candidate"
    if path_is_absent_or_empty "$candidate"; then
        info "Runtime candidate absent/empty: $candidate"
    elif path_looks_like_qdrant_runtime "$candidate"; then
        info "Recognized Qdrant runtime: $candidate"
    else
        fail "Refusing full purge: non-empty candidate does not look like Qdrant Native Portable runtime: $candidate"
    fi
done

if [[ "$keep_benchmark_exports" != "1" ]]; then
    assert_safe_candidate_path "$benchmark_export_root"
    info "Benchmark export root: $benchmark_export_root"
else
    info "Benchmark export root will be preserved: $benchmark_export_root"
fi

if [[ "$dry_run" == "1" ]]; then
    header "Dry-run purge plan"
    for candidate in "${runtime_candidates[@]}"; do
        printf 'Would remove runtime candidate: %s\n' "$candidate"
    done
    if [[ "$keep_benchmark_exports" != "1" ]]; then
        printf 'Would remove Qdrant benchmark artifacts under: %s\n' "$benchmark_export_root"
    fi
    printf 'Would remove local project generated state/artifacts under: %s\n' "$PROJECT_DIR"
    [[ "$reinstall" == "1" ]] && printf 'Would then run a fresh setup.\n'
    exit 0
fi

# ---------- Stop known project processes before deleting their state.
header "Stopping project services"
disable_proxy_config >/dev/null 2>&1 || true

stop_candidate_pid() {
    local pid_file="$1" expected="$2" pid cmdline
    [[ -f "$pid_file" ]] || return 0
    pid="$(cat "$pid_file" 2>/dev/null || true)"
    [[ "$pid" =~ ^[0-9]+$ ]] || return 0
    kill -0 "$pid" 2>/dev/null || return 0
    cmdline="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)"
    if [[ "$cmdline" == *"$expected"* ]]; then
        info "Stopping $expected process PID $pid from $pid_file"
        kill "$pid" 2>/dev/null || true
        for _ in $(seq 1 20); do
            kill -0 "$pid" 2>/dev/null || return 0
            sleep 0.1
        done
        kill -9 "$pid" 2>/dev/null || true
    else
        warn "PID file $pid_file points to PID $pid whose command does not contain '$expected'; not killing it"
    fi
}

for candidate in "${runtime_candidates[@]}"; do
    stop_candidate_pid "$candidate/run/cloudflared.pid" cloudflared
    stop_candidate_pid "$candidate/run/qdrant.pid" qdrant

done

# ---------- Remove all validated project runtime candidates.
header "Removing Qdrant runtime data"
for candidate in "${runtime_candidates[@]}"; do
    if [[ -e "$candidate" ]]; then
        rm -rf --one-file-system "$candidate"
        ok "Removed runtime: $candidate"
    else
        muted "Runtime already absent: $candidate"
    fi
done

# ---------- Remove benchmark exports without deleting an arbitrary shared root.
remove_known_benchmark_artifacts() {
    local root="$1" item
    [[ -d "$root" ]] || return 0
    shopt -s nullglob
    local patterns=(
        "$root"/run-google-colab-*
        "$root"/run-github-codespaces-*
        "$root"/run-codesandbox-*
        "$root"/run-kaggle-*
        "$root"/run-generic-linux-*
        "$root"/qdrant-benchmarks-*.zip
        "$root"/qdrant-benchmarks-*.zip.sha256
        "$root"/profile-ab-*
    )
    for item in "${patterns[@]}"; do
        [[ -e "$item" ]] || continue
        rm -rf --one-file-system "$item"
    done
    shopt -u nullglob
}

if [[ "$keep_benchmark_exports" != "1" ]]; then
    header "Removing benchmark exports"
    # The standard dedicated root can be removed whole. A custom export path
    # may be shared, so only project-shaped children are removed there.
    if [[ "$(basename "$benchmark_export_root")" == "qdrant-benchmark-exports" ]]; then
        if [[ -e "$benchmark_export_root" ]]; then
            rm -rf --one-file-system "$benchmark_export_root"
            ok "Removed benchmark export root: $benchmark_export_root"
        fi
    else
        remove_known_benchmark_artifacts "$benchmark_export_root"
        ok "Removed recognized Qdrant benchmark artifacts from custom export root: $benchmark_export_root"
    fi
fi

# ---------- Remove local generated state but never canonical source files.
header "Removing local generated project state"
rm -f "$PROJECT_DIR/.qdrant-base" "$PROJECT_DIR/.qdrant-initialized"
find "$PROJECT_DIR" -type d -name '__pycache__' -prune -exec rm -rf {} + 2>/dev/null || true
find "$PROJECT_DIR" -type f -name '*.pyc' -delete 2>/dev/null || true
shopt -s nullglob
for artifact in \
    "$PROJECT_DIR"/qdrant-benchmarks-*.zip \
    "$PROJECT_DIR"/qdrant-benchmarks-*.zip.sha256 \
    "$PROJECT_DIR"/profile-ab-*.zip \
    "$PROJECT_DIR"/profile-ab-*.zip.sha256; do
    rm -f "$artifact"
done
shopt -u nullglob
ok "Removed local runtime pointer/cache/generated benchmark archives"

ok "Full project data purge complete"

if [[ "$reinstall" == "1" ]]; then
    header "Fresh reinstall"
    info "Running setup after purge using current host auto-detection/overrides"
    exec bash "$PROJECT_DIR/run_all.sh"
fi
