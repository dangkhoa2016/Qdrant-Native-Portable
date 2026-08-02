#!/usr/bin/env bash
# Shared configuration, platform detection, security, logging, and service helpers.

if [[ -n "${QDRANT_COMMON_LOADED:-}" ]]; then
    return 0
fi
QDRANT_COMMON_LOADED=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ----- Platform detection ---------------------------------------------------
detect_platform() {
    if [[ "${CODESPACES:-}" == "true" || -n "${CODESPACE_NAME:-}" ]]; then
        printf 'github-codespaces'
    elif [[ -n "${KAGGLE_KERNEL_RUN_TYPE:-}" || -d /kaggle/working ]]; then
        printf 'kaggle'
    elif [[ -n "${COLAB_RELEASE_TAG:-}" || -n "${COLAB_BACKEND_VERSION:-}" ]]; then
        printf 'google-colab'
    elif [[ -n "${CODESANDBOX_HOST:-}" || -n "${CODESANDBOX_SSE:-}" || -n "${CSB:-}" ]]; then
        printf 'codesandbox'
    else
        printf 'generic-linux'
    fi
}

PLATFORM="${QDRANT_PLATFORM:-$(detect_platform)}"

default_base_dir() {
    case "$PLATFORM" in
        google-colab) printf '/content/qdrant-stack' ;;
        kaggle) printf '/kaggle/working/qdrant-stack' ;;
        github-codespaces|codesandbox|generic-linux)
            printf '%s/.local/share/qdrant-native-portable' "${HOME:-/tmp}"
            ;;
        *) printf '%s/.local/share/qdrant-native-portable' "${HOME:-/tmp}" ;;
    esac
}

if [[ -z "${BASE_DIR:-}" && -f "$PROJECT_DIR/.qdrant-base" ]]; then
    BASE_DIR="$(cat "$PROJECT_DIR/.qdrant-base" 2>/dev/null || true)"
fi
BASE_DIR="${BASE_DIR:-$(default_base_dir)}"
RUNTIME_ENV_FILE="$BASE_DIR/runtime.env"

# Persisted non-secret runtime settings are loaded, but explicitly supplied
# environment variables always win.
_runtime_vars=(
    QNP_ENV QNP_RUNTIME QNP_TOPOLOGY QNP_CREATE_DEMO_DATA QNP_SECRET_POLICY
    QNP_ALLOW_DEMO_TUNNEL QNP_KAGGLE_PERSISTENCE QDRANT_BIND_HOST
    QDRANT_VERSION QDRANT_PROFILE PROCESS_MODE DEPLOYMENT_MODE PUBLIC_MODE
    PROXY_PORT PORT PROXY_BIND QDRANT_HTTP_PORT QDRANT_GRPC_PORT
    QDRANT_START_TIMEOUT_SECONDS QDRANT_ENABLE_GRPC QDRANT_JWT_RBAC QDRANT_USER DEMO_COLLECTION
    START_TUNNEL ENABLE_CORS QDRANT_MAX_REQUEST_SIZE_MB CLOUDFLARED_VERSION
    QDRANT_STRICT_MODE QDRANT_STRICT_MAX_QUERY_LIMIT QDRANT_STRICT_MAX_TIMEOUT
    QDRANT_STRICT_MAX_HNSW_EF QDRANT_STRICT_ALLOW_EXACT
    QDRANT_STRICT_MAX_RESIDENT_MEMORY_PERCENT QDRANT_STRICT_SEARCH_MAX_BATCHSIZE
)
declare -A _explicit_set=()
declare -A _explicit_value=()
for _v in "${_runtime_vars[@]}"; do
    if [[ -v "$_v" ]]; then
        _explicit_set["$_v"]=1
        _explicit_value["$_v"]="${!_v}"
    fi
done
if [[ -f "$RUNTIME_ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$RUNTIME_ENV_FILE"
fi
for _v in "${_runtime_vars[@]}"; do
    if [[ -n "${_explicit_set[$_v]:-}" ]]; then
        printf -v "$_v" '%s' "${_explicit_value[$_v]}"
        # shellcheck disable=SC2163
        export "$_v"
    fi
done
unset _v

# ----- Environment/runtime policy -----------------------------------------
# Development keeps the historical portable behavior. Production opts into
# fail-closed exposure and secret handling while remaining single-node.
QNP_ENV="${QNP_ENV:-development}"
QNP_RUNTIME="${QNP_RUNTIME:-auto}"
[[ "$QNP_RUNTIME" == "auto" ]] && QNP_RUNTIME="native"
QNP_TOPOLOGY="${QNP_TOPOLOGY:-single}"
QNP_CREATE_DEMO_DATA="${QNP_CREATE_DEMO_DATA:-auto}"
QNP_SECRET_POLICY="${QNP_SECRET_POLICY:-auto}"
QNP_ALLOW_DEMO_TUNNEL="${QNP_ALLOW_DEMO_TUNNEL:-0}"
QNP_KAGGLE_PERSISTENCE="${QNP_KAGGLE_PERSISTENCE:-none}"

if [[ "$QNP_CREATE_DEMO_DATA" == "auto" ]]; then
    if [[ "$QNP_ENV" == "production" ]]; then QNP_CREATE_DEMO_DATA=0; else QNP_CREATE_DEMO_DATA=1; fi
fi
if [[ "$QNP_SECRET_POLICY" == "auto" ]]; then
    if [[ "$QNP_ENV" == "production" ]]; then QNP_SECRET_POLICY=require-env; else QNP_SECRET_POLICY=generate; fi
fi

# ----- Resource-aware defaults ---------------------------------------------
meminfo_file() {
    printf '%s' "${QDRANT_MEMINFO_FILE:-/proc/meminfo}"
}

total_memory_mb() {
    local file
    file="$(meminfo_file)"
    awk '/^MemTotal:/ {printf "%d", $2/1024}' "$file" 2>/dev/null || printf '0'
}

available_memory_mb() {
    local file
    file="$(meminfo_file)"
    awk '/^MemAvailable:/ {printf "%d", $2/1024}' "$file" 2>/dev/null || printf '0'
}

cgroup_memory_limit_mb() {
    local root="${QDRANT_CGROUP_DIR:-/sys/fs/cgroup}" raw=""
    if [[ -r "$root/memory.max" ]]; then
        raw="$(cat "$root/memory.max" 2>/dev/null || true)"
    elif [[ -r "$root/memory/memory.limit_in_bytes" ]]; then
        raw="$(cat "$root/memory/memory.limit_in_bytes" 2>/dev/null || true)"
    fi
    if [[ "$raw" =~ ^[0-9]+$ ]] && (( raw > 0 )); then
        printf '%d' $(( raw / 1048576 ))
    else
        printf '0'
    fi
}

effective_memory_mb() {
    local host limit
    host="$(total_memory_mb)"
    limit="$(cgroup_memory_limit_mb)"
    if (( limit > 0 && (host <= 0 || limit < host) )); then
        printf '%d' "$limit"
    else
        printf '%d' "$host"
    fi
}

effective_memory_source() {
    local host limit
    host="$(total_memory_mb)"
    limit="$(cgroup_memory_limit_mb)"
    if (( limit > 0 && (host <= 0 || limit < host) )); then
        printf 'cgroup'
    else
        printf 'host'
    fi
}

default_profile() {
    local mb
    mb="$(effective_memory_mb)"
    # Thresholds are deliberately conservative and are based on observed runs
    # across 4 GB, 8 GB, and ~13 GB development hosts.
    if (( mb > 0 && mb <= 5500 )); then
        printf 'low-memory'
    elif (( mb > 0 && mb <= 10500 )); then
        printf 'balanced-memory'
    elif (( mb > 0 && mb <= 22000 )); then
        printf 'balanced'
    else
        printf 'performance'
    fi
}

QDRANT_VERSION="${QDRANT_VERSION:-1.18.3}"
QDRANT_PROFILE="${QDRANT_PROFILE:-auto}"
[[ "$QDRANT_PROFILE" == "auto" ]] && QDRANT_PROFILE="$(default_profile)"

PROCESS_MODE="${PROCESS_MODE:-auto}"
if [[ "$PROCESS_MODE" == "auto" ]]; then
    case "$PLATFORM" in
        github-codespaces|codesandbox) PROCESS_MODE="current-user" ;;
        *) if [[ "$(id -u)" -eq 0 ]]; then PROCESS_MODE="service-user"; else PROCESS_MODE="current-user"; fi ;;
    esac
fi

DEPLOYMENT_MODE="${DEPLOYMENT_MODE:-auto}"
if [[ "$DEPLOYMENT_MODE" == "auto" ]]; then
    if [[ "$PROCESS_MODE" == "service-user" && "$(id -u)" -eq 0 ]]; then
        DEPLOYMENT_MODE="proxy"
    else
        DEPLOYMENT_MODE="minimal"
    fi
fi

PUBLIC_MODE="${PUBLIC_MODE:-auto}"
if [[ "$PUBLIC_MODE" == "auto" ]]; then
    if [[ "$QNP_ENV" == "production" ]]; then
        PUBLIC_MODE="none"
    elif [[ "$PLATFORM" == "github-codespaces" ]]; then
        PUBLIC_MODE="platform"
    else
        PUBLIC_MODE="cloudflare-quick"
    fi
fi

if [[ -z "${QDRANT_BIND_HOST:-}" ]]; then
    if [[ "$QNP_RUNTIME" == "docker" ]]; then QDRANT_BIND_HOST="0.0.0.0"; else QDRANT_BIND_HOST="127.0.0.1"; fi
fi

PROXY_PORT="${PORT:-${PROXY_PORT:-9090}}"
PROXY_BIND="${PROXY_BIND:-127.0.0.1}"
QDRANT_HTTP_PORT="${QDRANT_HTTP_PORT:-6333}"
QDRANT_GRPC_PORT="${QDRANT_GRPC_PORT:-6334}"
QDRANT_START_TIMEOUT_SECONDS="${QDRANT_START_TIMEOUT_SECONDS:-300}"
QDRANT_ENABLE_GRPC="${QDRANT_ENABLE_GRPC:-0}"
QDRANT_JWT_RBAC="${QDRANT_JWT_RBAC:-0}"
QDRANT_USER="${QDRANT_USER:-qdrantuser}"
DEMO_COLLECTION="${DEMO_COLLECTION:-portable_demo}"
START_TUNNEL="${START_TUNNEL:-0}"
ENABLE_CORS="${ENABLE_CORS:-false}"
QDRANT_MAX_REQUEST_SIZE_MB="${QDRANT_MAX_REQUEST_SIZE_MB:-128}"
CLOUDFLARED_VERSION="${CLOUDFLARED_VERSION:-latest}"

# Strict mode defaults apply to collections created after this config is active.
QDRANT_STRICT_MODE="${QDRANT_STRICT_MODE:-1}"
QDRANT_STRICT_MAX_QUERY_LIMIT="${QDRANT_STRICT_MAX_QUERY_LIMIT:-1000}"
QDRANT_STRICT_MAX_TIMEOUT="${QDRANT_STRICT_MAX_TIMEOUT:-30}"
QDRANT_STRICT_MAX_HNSW_EF="${QDRANT_STRICT_MAX_HNSW_EF:-512}"
QDRANT_STRICT_ALLOW_EXACT="${QDRANT_STRICT_ALLOW_EXACT:-false}"
QDRANT_STRICT_MAX_RESIDENT_MEMORY_PERCENT="${QDRANT_STRICT_MAX_RESIDENT_MEMORY_PERCENT:-85}"
QDRANT_STRICT_SEARCH_MAX_BATCHSIZE="${QDRANT_STRICT_SEARCH_MAX_BATCHSIZE:-64}"

case "$QDRANT_PROFILE" in
    low-memory)
        PROFILE_LOW_MEMORY_MODE="no_populate"
        PROFILE_ON_DISK_PAYLOAD="true"
        PROFILE_VECTORS_ON_DISK="true"
        PROFILE_HNSW_ON_DISK="true"
        PROFILE_MAX_SEARCH_THREADS="1"
        PROFILE_OPTIMIZER_CPU_BUDGET="1"
        PROFILE_MAX_OPTIMIZATION_THREADS="1"
        PROFILE_MAX_INDEXING_THREADS="2"
        ;;
    balanced-lite)
        # Disk-first middle ground: HNSW stays resident but vectors/payload stay
        # on disk. Useful when the dataset is too large for the host RAM budget.
        PROFILE_LOW_MEMORY_MODE="disabled"
        PROFILE_ON_DISK_PAYLOAD="true"
        PROFILE_VECTORS_ON_DISK="true"
        PROFILE_HNSW_ON_DISK="false"
        PROFILE_MAX_SEARCH_THREADS="0"
        PROFILE_OPTIMIZER_CPU_BUDGET="1"
        PROFILE_MAX_OPTIMIZATION_THREADS="1"
        PROFILE_MAX_INDEXING_THREADS="2"
        ;;
    balanced-memory)
        # Query-latency oriented profile for ~6-10 GB development hosts and
        # small/medium collections: vectors + HNSW in RAM, payload on disk,
        # conservative optimizer concurrency.
        PROFILE_LOW_MEMORY_MODE="disabled"
        PROFILE_ON_DISK_PAYLOAD="true"
        PROFILE_VECTORS_ON_DISK="false"
        PROFILE_HNSW_ON_DISK="false"
        PROFILE_MAX_SEARCH_THREADS="0"
        PROFILE_OPTIMIZER_CPU_BUDGET="1"
        PROFILE_MAX_OPTIMIZATION_THREADS="1"
        PROFILE_MAX_INDEXING_THREADS="2"
        ;;
    balanced)
        PROFILE_LOW_MEMORY_MODE="disabled"
        PROFILE_ON_DISK_PAYLOAD="true"
        PROFILE_VECTORS_ON_DISK="false"
        PROFILE_HNSW_ON_DISK="false"
        PROFILE_MAX_SEARCH_THREADS="0"
        PROFILE_OPTIMIZER_CPU_BUDGET="0"
        PROFILE_MAX_OPTIMIZATION_THREADS="null"
        PROFILE_MAX_INDEXING_THREADS="0"
        ;;
    performance)
        PROFILE_LOW_MEMORY_MODE="disabled"
        export PROFILE_ON_DISK_PAYLOAD="false"
        export PROFILE_VECTORS_ON_DISK="false"
        export PROFILE_HNSW_ON_DISK="false"
        export PROFILE_MAX_SEARCH_THREADS="0"
        export PROFILE_OPTIMIZER_CPU_BUDGET="0"
        export PROFILE_MAX_OPTIMIZATION_THREADS="null"
        export PROFILE_MAX_INDEXING_THREADS="0"
        ;;
    *) printf 'Invalid QDRANT_PROFILE: %s\n' "$QDRANT_PROFILE" >&2; printf 'Valid profiles: low-memory, balanced-lite, balanced-memory, balanced, performance\n' >&2; exit 1 ;;
esac

case "$QNP_ENV" in development|production) ;; *) printf 'Invalid QNP_ENV: %s (expected development or production)\n' "$QNP_ENV" >&2; exit 1 ;; esac
case "$QNP_RUNTIME" in native|docker) ;; *) printf 'Invalid QNP_RUNTIME: %s (expected native or docker)\n' "$QNP_RUNTIME" >&2; exit 1 ;; esac
case "$QNP_TOPOLOGY" in single) ;; *) printf 'QNP_TOPOLOGY supports only single-node in this revision (got: %s)\n' "$QNP_TOPOLOGY" >&2; exit 1 ;; esac
case "$QNP_CREATE_DEMO_DATA" in 0|1) ;; *) printf 'QNP_CREATE_DEMO_DATA must be auto, 0 or 1\n' >&2; exit 1 ;; esac
case "$QNP_SECRET_POLICY" in generate|require-env) ;; *) printf 'QNP_SECRET_POLICY must be auto, generate or require-env\n' >&2; exit 1 ;; esac
if [[ "$QNP_ENV" == "production" && "$QNP_SECRET_POLICY" != "require-env" ]]; then
    printf 'Production requires QNP_SECRET_POLICY=require-env; generated/persisted credentials are disabled.\n' >&2
    exit 1
fi
case "$QNP_ALLOW_DEMO_TUNNEL" in 0|1) ;; *) printf 'QNP_ALLOW_DEMO_TUNNEL must be 0 or 1\n' >&2; exit 1 ;; esac
case "$QNP_KAGGLE_PERSISTENCE" in none|files|variables-and-files) ;; *) printf 'Invalid QNP_KAGGLE_PERSISTENCE: %s\n' "$QNP_KAGGLE_PERSISTENCE" >&2; exit 1 ;; esac
[[ "$QDRANT_START_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] || { printf 'QDRANT_START_TIMEOUT_SECONDS must be a positive integer\n' >&2; exit 1; }
case "$PROCESS_MODE" in current-user|service-user) ;; *) printf 'Invalid PROCESS_MODE: %s\n' "$PROCESS_MODE" >&2; exit 1 ;; esac
case "$DEPLOYMENT_MODE" in minimal|proxy) ;; *) printf 'Invalid DEPLOYMENT_MODE: %s\n' "$DEPLOYMENT_MODE" >&2; exit 1 ;; esac
case "$PUBLIC_MODE" in none|cloudflare-quick|platform) ;; *) printf 'Invalid PUBLIC_MODE: %s\n' "$PUBLIC_MODE" >&2; exit 1 ;; esac
case "$QDRANT_ENABLE_GRPC" in 0|1) ;; *) printf 'QDRANT_ENABLE_GRPC must be 0 or 1\n' >&2; exit 1 ;; esac
case "$QDRANT_JWT_RBAC" in 0|1) ;; *) printf 'QDRANT_JWT_RBAC must be 0 or 1\n' >&2; exit 1 ;; esac
case "$QDRANT_STRICT_MODE" in 0|1) ;; *) printf 'QDRANT_STRICT_MODE must be 0 or 1\n' >&2; exit 1 ;; esac

if [[ "$QNP_ENV" == "production" && "$PUBLIC_MODE" == "cloudflare-quick" && "$QNP_ALLOW_DEMO_TUNNEL" != "1" ]]; then
    printf 'Production Cloudflare Quick Tunnel requires explicit QNP_ALLOW_DEMO_TUNNEL=1; otherwise use PUBLIC_MODE=none.\n' >&2
    exit 1
fi
if [[ "$QNP_ENV" == "production" && "$START_TUNNEL" == "1" && "$PUBLIC_MODE" == "none" ]]; then
    printf 'START_TUNNEL=1 conflicts with production PUBLIC_MODE=none.\n' >&2
    exit 1
fi

case "$(uname -m)" in
    x86_64|amd64) QDRANT_TARGET="x86_64-unknown-linux-musl"; CLOUDFLARED_ARCH="amd64" ;;
    aarch64|arm64) QDRANT_TARGET="aarch64-unknown-linux-musl"; CLOUDFLARED_ARCH="arm64" ;;
    *) printf 'Unsupported CPU architecture: %s\n' "$(uname -m)" >&2; exit 1 ;;
esac

QDRANT_ARCHIVE="qdrant-${QDRANT_TARGET}.tar.gz"
export QDRANT_URL="https://github.com/qdrant/qdrant/releases/download/v${QDRANT_VERSION}/${QDRANT_ARCHIVE}"
QDRANT_HOME="$BASE_DIR/qdrant-$QDRANT_VERSION"
QDRANT_BIN="$QDRANT_HOME/qdrant"
QDRANT_CONFIG_DIR="$BASE_DIR/config"
QDRANT_CONFIG="$QDRANT_CONFIG_DIR/qdrant.yaml"
QDRANT_STORAGE="$BASE_DIR/storage"
QDRANT_SNAPSHOTS="$BASE_DIR/snapshots"
QDRANT_LOGS="$BASE_DIR/logs"
QDRANT_RUN="$BASE_DIR/run"
QDRANT_TMP="$BASE_DIR/tmp"
QDRANT_BACKUPS="$BASE_DIR/recovery-backups"
QDRANT_DOWNLOADS="$BASE_DIR/downloads"
QDRANT_TOKENS="$BASE_DIR/tokens"
QDRANT_BENCHMARKS="$BASE_DIR/benchmarks"
INSTANCE_MARKER="$BASE_DIR/.qdrant-native-portable-instance"
QDRANT_LOG="$QDRANT_LOGS/qdrant.log"
QDRANT_PID_FILE="$QDRANT_RUN/qdrant.pid"
SECRETS_FILE="$BASE_DIR/secrets.env"
NGINX_CONFIG="${NGINX_CONFIG:-/etc/nginx/conf.d/qdrant-native-portable.conf}"
export CLOUDFLARED_BIN="$BASE_DIR/bin/cloudflared"
export TUNNEL_LOG="$QDRANT_LOGS/cloudflared.log"
export TUNNEL_PID_FILE="$QDRANT_RUN/cloudflared.pid"
export PUBLIC_URL_FILE="$QDRANT_RUN/public-url.txt"
export TUNNEL_URL_FILE="$PUBLIC_URL_FILE" # backwards-compatible alias

if [[ "$CLOUDFLARED_VERSION" == "latest" ]]; then
    export CLOUDFLARED_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CLOUDFLARED_ARCH}"
else
    export CLOUDFLARED_URL="https://github.com/cloudflare/cloudflared/releases/download/${CLOUDFLARED_VERSION}/cloudflared-linux-${CLOUDFLARED_ARCH}"
fi

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
    C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
    C_BLUE=$'\033[34m'; C_CYAN=$'\033[36m'
else
    C_RESET=""; C_BOLD=""; C_DIM=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_CYAN=""
fi

info()  { printf "  ${C_CYAN}•${C_RESET} %s\n" "$*"; }
ok()    { printf "  ${C_GREEN}✓${C_RESET} %s\n" "$*"; }
warn()  { printf "  ${C_YELLOW}⚠${C_RESET} %s\n" "$*"; }
muted() { printf "  ${C_DIM}%s${C_RESET}\n" "$*"; }
fail()  { printf "  ${C_RED}✖${C_RESET} %s\n" "$*" >&2; exit 1; }
hr()    { printf '  %s%s%s\n' "$C_BOLD" "$C_BLUE" "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━$C_RESET"; }
header() { printf '\n'; hr; printf "  ${C_BOLD}${C_BLUE}%s${C_RESET}\n" "$1"; hr; printf '\n'; }
banner() { printf '\n'; hr; printf "  ${C_BOLD}${C_BLUE}%s${C_RESET}\n" "$1"; [[ -n "${2:-}" ]] && printf "  ${C_DIM}%s${C_RESET}\n" "$2"; hr; printf '\n'; }

mask() {
    local value="${1:-}" length visible
    [[ -z "$value" ]] && { printf '(not set)'; return; }
    length=${#value}
    if (( length <= 8 )); then printf '********'; return; fi
    visible="${value: -4}"
    printf '%*s%s' "$((length - 4))" '' "$visible" | tr ' ' '*'
}

require() { local tool; for tool in "$@"; do command -v "$tool" >/dev/null 2>&1 || fail "Missing required tool: $tool"; done; }
require_root() { [[ "$(id -u)" -eq 0 ]] || fail "This operation requires root privileges. Re-run with sudo or use PROCESS_MODE=current-user / DEPLOYMENT_MODE=minimal."; }
require_service_control_privileges() { [[ "$PROCESS_MODE" != "service-user" ]] || require_root; }
random_secret() { openssl rand -hex 32; }

ensure_runtime_dirs() {
    mkdir -p "$BASE_DIR" "$QDRANT_CONFIG_DIR" "$QDRANT_STORAGE" "$QDRANT_SNAPSHOTS" \
        "$QDRANT_LOGS" "$QDRANT_RUN" "$QDRANT_TMP" "$QDRANT_BACKUPS" \
        "$QDRANT_DOWNLOADS" "$BASE_DIR/bin" "$QDRANT_TOKENS" "$QDRANT_BENCHMARKS"
}

write_instance_marker() {
    ensure_runtime_dirs
    umask 077
    cat > "$INSTANCE_MARKER" <<EOF_MARKER
project=qdrant-native-portable
schema=1
base_dir=$(printf '%q' "$BASE_DIR")
created_or_refreshed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF_MARKER
    chmod 0600 "$INSTANCE_MARKER"
}

is_managed_instance() {
    [[ -f "$INSTANCE_MARKER" ]] && grep -qx 'project=qdrant-native-portable' "$INSTANCE_MARKER" 2>/dev/null
}

looks_like_qdrant_instance() {
    [[ -f "$RUNTIME_ENV_FILE" || -f "$SECRETS_FILE" || -f "$QDRANT_CONFIG" || -d "$QDRANT_STORAGE" || -x "$QDRANT_BIN" ]]
}

base_dir_is_absent_or_empty() {
    local resolved
    resolved="$(realpath -m "$BASE_DIR")"
    [[ ! -e "$resolved" ]] && return 0
    [[ -d "$resolved" ]] || return 1
    [[ -z "$(find "$resolved" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]
}

assert_safe_destructive_base_dir() {
    local resolved home_resolved project_resolved
    resolved="$(realpath -m "$BASE_DIR")"
    home_resolved="$(realpath -m "${HOME:-/nonexistent}")"
    project_resolved="$(realpath -m "$PROJECT_DIR")"

    [[ "$resolved" == /* ]] || fail "Destructive operations require an absolute BASE_DIR: $resolved"
    [[ "$resolved" != "/" ]] || fail "Refusing destructive operation on /"
    [[ "$resolved" != "$home_resolved" ]] || fail "Refusing destructive operation on HOME: $resolved"
    [[ "$resolved" != "$project_resolved" ]] || fail "Refusing destructive operation on the source repository: $resolved"
    case "$resolved" in
        /content|/kaggle|/kaggle/working|/workspaces|/workspace|/root|/home|/tmp|/var|/usr|/etc)
            fail "Refusing destructive operation on broad/system path: $resolved" ;;
    esac
    [[ ${#resolved} -ge 12 ]] || fail "BASE_DIR is suspiciously short for a destructive operation: $resolved"
}

write_runtime_env() {
    ensure_runtime_dirs
    umask 077
    cat > "$RUNTIME_ENV_FILE" <<EOF_RUNTIME
QNP_ENV=$(printf '%q' "$QNP_ENV")
QNP_RUNTIME=$(printf '%q' "$QNP_RUNTIME")
QNP_TOPOLOGY=$(printf '%q' "$QNP_TOPOLOGY")
QNP_CREATE_DEMO_DATA=$(printf '%q' "$QNP_CREATE_DEMO_DATA")
QNP_SECRET_POLICY=$(printf '%q' "$QNP_SECRET_POLICY")
QNP_ALLOW_DEMO_TUNNEL=$(printf '%q' "$QNP_ALLOW_DEMO_TUNNEL")
QNP_KAGGLE_PERSISTENCE=$(printf '%q' "$QNP_KAGGLE_PERSISTENCE")
QDRANT_BIND_HOST=$(printf '%q' "$QDRANT_BIND_HOST")
QDRANT_VERSION=$(printf '%q' "$QDRANT_VERSION")
QDRANT_PROFILE=$(printf '%q' "$QDRANT_PROFILE")
PROCESS_MODE=$(printf '%q' "$PROCESS_MODE")
DEPLOYMENT_MODE=$(printf '%q' "$DEPLOYMENT_MODE")
PUBLIC_MODE=$(printf '%q' "$PUBLIC_MODE")
PROXY_PORT=$(printf '%q' "$PROXY_PORT")
PROXY_BIND=$(printf '%q' "$PROXY_BIND")
QDRANT_HTTP_PORT=$(printf '%q' "$QDRANT_HTTP_PORT")
QDRANT_GRPC_PORT=$(printf '%q' "$QDRANT_GRPC_PORT")
QDRANT_START_TIMEOUT_SECONDS=$(printf '%q' "$QDRANT_START_TIMEOUT_SECONDS")
QDRANT_ENABLE_GRPC=$(printf '%q' "$QDRANT_ENABLE_GRPC")
QDRANT_JWT_RBAC=$(printf '%q' "$QDRANT_JWT_RBAC")
QDRANT_USER=$(printf '%q' "$QDRANT_USER")
DEMO_COLLECTION=$(printf '%q' "$DEMO_COLLECTION")
START_TUNNEL=$(printf '%q' "$START_TUNNEL")
ENABLE_CORS=$(printf '%q' "$ENABLE_CORS")
QDRANT_MAX_REQUEST_SIZE_MB=$(printf '%q' "$QDRANT_MAX_REQUEST_SIZE_MB")
CLOUDFLARED_VERSION=$(printf '%q' "$CLOUDFLARED_VERSION")
QDRANT_STRICT_MODE=$(printf '%q' "$QDRANT_STRICT_MODE")
QDRANT_STRICT_MAX_QUERY_LIMIT=$(printf '%q' "$QDRANT_STRICT_MAX_QUERY_LIMIT")
QDRANT_STRICT_MAX_TIMEOUT=$(printf '%q' "$QDRANT_STRICT_MAX_TIMEOUT")
QDRANT_STRICT_MAX_HNSW_EF=$(printf '%q' "$QDRANT_STRICT_MAX_HNSW_EF")
QDRANT_STRICT_ALLOW_EXACT=$(printf '%q' "$QDRANT_STRICT_ALLOW_EXACT")
QDRANT_STRICT_MAX_RESIDENT_MEMORY_PERCENT=$(printf '%q' "$QDRANT_STRICT_MAX_RESIDENT_MEMORY_PERCENT")
QDRANT_STRICT_SEARCH_MAX_BATCHSIZE=$(printf '%q' "$QDRANT_STRICT_SEARCH_MAX_BATCHSIZE")
EOF_RUNTIME
    chmod 0600 "$RUNTIME_ENV_FILE"
    write_instance_marker
    if [[ -w "$PROJECT_DIR" ]]; then
        printf '%s\n' "$BASE_DIR" > "$PROJECT_DIR/.qdrant-base"
        chmod 0600 "$PROJECT_DIR/.qdrant-base" 2>/dev/null || true
    fi
}

# Load secrets without allowing secrets.env to override values explicitly supplied by the caller.
load_secrets() {
    # In production require-env mode, persisted secrets are intentionally ignored.
    # Every management/lifecycle command must receive secrets from its caller or
    # provider secret manager; this prevents stale development keys from silently
    # becoming production credentials.
    if [[ "${QNP_SECRET_POLICY:-generate}" == "require-env" ]]; then
        export QDRANT_API_KEY="${QDRANT_API_KEY-}" QDRANT_READ_ONLY_API_KEY="${QDRANT_READ_ONLY_API_KEY-}" QDRANT_ALT_API_KEY="${QDRANT_ALT_API_KEY-}"
        return 0
    fi

    local admin_was_set="${QDRANT_API_KEY+x}" readonly_was_set="${QDRANT_READ_ONLY_API_KEY+x}" alt_was_set="${QDRANT_ALT_API_KEY+x}"
    local env_admin="${QDRANT_API_KEY-}" env_readonly="${QDRANT_READ_ONLY_API_KEY-}" env_alt="${QDRANT_ALT_API_KEY-}"
    if [[ -f "$SECRETS_FILE" ]]; then
        # shellcheck disable=SC1090
        source "$SECRETS_FILE"
    fi
    [[ -n "$admin_was_set" ]] && QDRANT_API_KEY="$env_admin"
    [[ -n "$readonly_was_set" ]] && QDRANT_READ_ONLY_API_KEY="$env_readonly"
    [[ -n "$alt_was_set" ]] && QDRANT_ALT_API_KEY="$env_alt"
    export QDRANT_API_KEY="${QDRANT_API_KEY-}" QDRANT_READ_ONLY_API_KEY="${QDRANT_READ_ONLY_API_KEY-}" QDRANT_ALT_API_KEY="${QDRANT_ALT_API_KEY-}"
}

write_secrets_file() {
    ensure_runtime_dirs; umask 077
    {
        printf 'QDRANT_API_KEY=%q\n' "${QDRANT_API_KEY:-}"
        printf 'QDRANT_READ_ONLY_API_KEY=%q\n' "${QDRANT_READ_ONLY_API_KEY:-}"
        [[ -n "${QDRANT_ALT_API_KEY:-}" ]] && printf 'QDRANT_ALT_API_KEY=%q\n' "$QDRANT_ALT_API_KEY"
    } > "$SECRETS_FILE"
    chmod 0600 "$SECRETS_FILE"
}

require_secrets() {
    load_secrets
    if [[ "${QNP_SECRET_POLICY:-generate}" == "require-env" ]]; then
        [[ -n "${QDRANT_API_KEY:-}" ]] || fail "QDRANT_API_KEY must be supplied explicitly in the production environment"
        [[ -n "${QDRANT_READ_ONLY_API_KEY:-}" ]] || fail "QDRANT_READ_ONLY_API_KEY must be supplied explicitly in the production environment"
    else
        [[ -n "${QDRANT_API_KEY:-}" ]] || fail "Admin API key is missing. Run: bash scripts/01_credentials.sh"
        [[ -n "${QDRANT_READ_ONLY_API_KEY:-}" ]] || fail "Read-only API key is missing. Run: bash scripts/01_credentials.sh"
    fi
}

wait_for() {
    local waiting="$1" done="$2" timeout="$3"; shift 3; local elapsed=0
    printf "  ⏳ %s...\n" "$waiting"
    while (( elapsed < timeout )); do
        if "$@" >/dev/null 2>&1; then ok "$done (${elapsed}s)"; return 0; fi
        sleep 1; elapsed=$((elapsed + 1)); (( elapsed % 10 == 0 )) && muted "waiting... ${elapsed}s"
    done
    return 1
}

download_with_retry() {
    local url="$1" dest="$2" attempts="${3:-3}" i
    for i in $(seq 1 "$attempts"); do
        rm -f "$dest"
        if curl -fL --connect-timeout 20 --retry 2 --retry-delay 2 "$url" -o "$dest"; then return 0; fi
        warn "Download failed ($i/$attempts)"; sleep 3
    done
    return 1
}

verify_sha256_if_provided() {
    local file="$1" expected="${2:-}"
    [[ -z "$expected" ]] && return 0
    require sha256sum
    printf '%s  %s\n' "$expected" "$file" | sha256sum -c - >/dev/null || fail "SHA256 verification failed for $file"
    ok "SHA256 verified: $(basename "$file")"
}

pid_is_running() { local pid_file="$1" pid; [[ -f "$pid_file" ]] || return 1; pid="$(cat "$pid_file" 2>/dev/null || true)"; [[ "$pid" =~ ^[0-9]+$ ]] || return 1; kill -0 "$pid" 2>/dev/null; }
stop_pid_file() {
    local name="$1" pid_file="$2" pid
    if ! pid_is_running "$pid_file"; then rm -f "$pid_file"; warn "$name is not running"; return 0; fi
    pid="$(cat "$pid_file")"; info "Stopping $name (PID $pid)..."; kill "$pid" 2>/dev/null || true
    local i; for i in $(seq 1 30); do if ! kill -0 "$pid" 2>/dev/null; then rm -f "$pid_file"; ok "$name stopped"; return 0; fi; sleep 1; done
    warn "$name did not stop gracefully; sending SIGKILL"; kill -9 "$pid" 2>/dev/null || true; rm -f "$pid_file"
}

qdrant_ready_with_timeout() { require_secrets; local max_time="$1" host="$QDRANT_BIND_HOST"; [[ "$host" == "0.0.0.0" ]] && host="127.0.0.1"; curl -fsS --max-time "$max_time" -H "api-key: $QDRANT_API_KEY" "http://${host}:${QDRANT_HTTP_PORT}/collections" >/dev/null; }
qdrant_ready() { qdrant_ready_with_timeout 3; }
proxy_ready() { [[ "$DEPLOYMENT_MODE" == "proxy" ]] || return 1; require_secrets; curl -fsS --max-time 3 -H "api-key: $QDRANT_API_KEY" "http://${PROXY_BIND}:${PROXY_PORT}/collections" >/dev/null; }
api_curl() { require_secrets; curl -fsS -H "api-key: $QDRANT_API_KEY" "$@"; }
readonly_api_curl() { require_secrets; curl -fsS -H "api-key: $QDRANT_READ_ONLY_API_KEY" "$@"; }

local_api_url() { if [[ "$DEPLOYMENT_MODE" == "proxy" ]]; then printf 'http://%s:%s' "$PROXY_BIND" "$PROXY_PORT"; else local host="$QDRANT_BIND_HOST"; [[ "$host" == "0.0.0.0" ]] && host="127.0.0.1"; printf 'http://%s:%s' "$host" "$QDRANT_HTTP_PORT"; fi; }
local_dashboard_url() { printf '%s/dashboard' "$(local_api_url)"; }
public_target_url() { local_api_url; }
public_target_port() { if [[ "$DEPLOYMENT_MODE" == "proxy" ]]; then printf '%s' "$PROXY_PORT"; else printf '%s' "$QDRANT_HTTP_PORT"; fi; }

fix_runtime_ownership() {
    ensure_runtime_dirs
    if [[ "$PROCESS_MODE" == "service-user" ]]; then
        require_root
        id "$QDRANT_USER" >/dev/null 2>&1 || fail "Service user $QDRANT_USER does not exist. Run scripts/02_setup_env.sh."
        chown -R "$QDRANT_USER:$QDRANT_USER" "$QDRANT_STORAGE" "$QDRANT_SNAPSHOTS" "$QDRANT_LOGS" "$QDRANT_TMP"
    fi
}

start_qdrant_process() {
    require_service_control_privileges
    require_secrets
    [[ -x "$QDRANT_BIN" ]] || fail "Qdrant binary not found. Run scripts/03_download_qdrant.sh."
    [[ -f "$QDRANT_CONFIG" ]] || fail "Qdrant config not found. Run scripts/04_configure_qdrant.sh."
    ensure_runtime_dirs; fix_runtime_ownership

    export QDRANT__SERVICE__API_KEY="$QDRANT_API_KEY"
    export QDRANT__SERVICE__READ_ONLY_API_KEY="$QDRANT_READ_ONLY_API_KEY"
    QDRANT__SERVICE__JWT_RBAC="$([[ "$QDRANT_JWT_RBAC" == "1" ]] && echo true || echo false)"
    export QDRANT__SERVICE__JWT_RBAC
    export QDRANT__STORAGE__LOW_MEMORY_MODE="$PROFILE_LOW_MEMORY_MODE"
    if [[ -n "${QDRANT_ALT_API_KEY:-}" ]]; then export QDRANT__SERVICE__ALT_API_KEY="$QDRANT_ALT_API_KEY"; else unset QDRANT__SERVICE__ALT_API_KEY 2>/dev/null || true; fi

    if [[ "$PROCESS_MODE" == "service-user" ]]; then
        require setpriv
        local uid gid; uid="$(id -u "$QDRANT_USER")"; gid="$(id -g "$QDRANT_USER")"
        nohup setpriv --reuid="$uid" --regid="$gid" --init-groups "$QDRANT_BIN" --config-path "$QDRANT_CONFIG" "$@" >> "$QDRANT_LOG" 2>&1 &
    else
        nohup "$QDRANT_BIN" --config-path "$QDRANT_CONFIG" "$@" >> "$QDRANT_LOG" 2>&1 &
    fi
    echo $! > "$QDRANT_PID_FILE"; chmod 0600 "$QDRANT_PID_FILE"
}

disable_proxy_config() {
    if [[ "$DEPLOYMENT_MODE" != "proxy" ]]; then muted "Proxy mode is disabled"; return 0; fi
    require_root
    if [[ -f "$NGINX_CONFIG" ]]; then
        rm -f "$NGINX_CONFIG"
        # shellcheck disable=SC2015
        if command -v nginx >/dev/null 2>&1 && [[ -f /run/nginx.pid ]] && kill -0 "$(cat /run/nginx.pid)" 2>/dev/null; then nginx -t >/dev/null && nginx -s reload >/dev/null 2>&1 || true; fi
        ok "Removed Qdrant Nginx proxy configuration"
    else warn "Qdrant Nginx proxy configuration is not installed"; fi
}
