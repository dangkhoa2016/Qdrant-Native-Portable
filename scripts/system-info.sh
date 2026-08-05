#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname "$0")/common.sh"

header "System information"
mem_total_mb="$(total_memory_mb)"
mem_effective_mb="$(effective_memory_mb)"
mem_effective_source="$(effective_memory_source)"
mem_available="$(free -h 2>/dev/null | awk '/^Mem:/ {print $7}')"
disk_free="$(df -h "$BASE_DIR" 2>/dev/null | awk 'NR==2 {print $4}')"

printf '  %-22s %s\n' "Platform" "$PLATFORM"
printf '  %-22s %s\n' "OS" "$(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown}")"
printf '  %-22s %s\n' "Kernel" "$(uname -sr)"
printf '  %-22s %s\n' "Architecture" "$(uname -m)"
printf '  %-22s %s\n' "CPU threads" "$(nproc 2>/dev/null || echo unknown)"
printf '  %-22s %s MB\n' "Total RAM" "$mem_total_mb"
printf '  %-22s %s MB (%s)\n' "Effective RAM" "$mem_effective_mb" "$mem_effective_source"
printf '  %-22s %s\n' "Available RAM" "${mem_available:-unknown}"
printf '  %-22s %s\n' "Free disk" "${disk_free:-unknown}"
printf '  %-22s %s\n' "Base directory" "$BASE_DIR"
printf '  %-22s %s\n' "Qdrant version" "$QDRANT_VERSION"
printf '  %-22s %s\n' "Resource profile" "$QDRANT_PROFILE"
printf '  %-22s %s\n' "HW default profile" "$(default_profile)"
printf '  %-22s %s\n' "Low-memory startup" "$PROFILE_LOW_MEMORY_MODE"
printf '  %-22s %s\n' "Vectors on disk" "$PROFILE_VECTORS_ON_DISK"
printf '  %-22s %s\n' "HNSW on disk" "$PROFILE_HNSW_ON_DISK"
printf '  %-22s %s\n' "Payload on disk" "$PROFILE_ON_DISK_PAYLOAD"
printf '  %-22s %s\n' "Process mode" "$PROCESS_MODE"
printf '  %-22s %s\n' "Deployment mode" "$DEPLOYMENT_MODE"
printf '  %-22s %s\n' "Public mode" "$PUBLIC_MODE"
printf '  %-22s %s\n' "gRPC enabled" "$QDRANT_ENABLE_GRPC"
printf '  %-22s %s\n' "JWT RBAC" "$QDRANT_JWT_RBAC"
printf '  %-22s %s\n' "Strict defaults" "$QDRANT_STRICT_MODE"
printf '  %-22s %s\n' "Local API" "$(local_api_url)"

if pid_is_running "$QDRANT_PID_FILE"; then
    pid="$(cat "$QDRANT_PID_FILE")"
    printf '\n'
    info "Qdrant process resources"
    ps -p "$pid" -o pid,ppid,%cpu,%mem,rss,vsz,etime,cmd || true
fi
