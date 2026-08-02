#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname "$0")/common.sh"

header "Step 4: Configure Qdrant"
require_secrets
ensure_runtime_dirs

case "$ENABLE_CORS" in true|false) ;; *) fail "ENABLE_CORS must be true or false" ;; esac
case "$QDRANT_STRICT_ALLOW_EXACT" in true|false) ;; *) fail "QDRANT_STRICT_ALLOW_EXACT must be true or false" ;; esac
for n in QDRANT_MAX_REQUEST_SIZE_MB QDRANT_STRICT_MAX_QUERY_LIMIT QDRANT_STRICT_MAX_TIMEOUT QDRANT_STRICT_MAX_HNSW_EF QDRANT_STRICT_MAX_RESIDENT_MEMORY_PERCENT QDRANT_STRICT_SEARCH_MAX_BATCHSIZE; do
    [[ "${!n}" =~ ^[0-9]+$ ]] || fail "$n must be an integer"
done
(( QDRANT_STRICT_MAX_RESIDENT_MEMORY_PERCENT >= 1 && QDRANT_STRICT_MAX_RESIDENT_MEMORY_PERCENT <= 100 )) || fail "QDRANT_STRICT_MAX_RESIDENT_MEMORY_PERCENT must be between 1 and 100"
(( QDRANT_STRICT_SEARCH_MAX_BATCHSIZE >= 1 )) || fail "QDRANT_STRICT_SEARCH_MAX_BATCHSIZE must be at least 1"

if [[ "$QDRANT_ENABLE_GRPC" == "1" ]]; then grpc_line="  grpc_port: $QDRANT_GRPC_PORT"; else grpc_line="  grpc_port: null"; fi
if [[ "$QDRANT_STRICT_MODE" == "1" ]]; then
    strict_block=$(cat <<EOF_STRICT
    strict_mode:
      enabled: true
      max_query_limit: $QDRANT_STRICT_MAX_QUERY_LIMIT
      max_timeout: $QDRANT_STRICT_MAX_TIMEOUT
      search_max_hnsw_ef: $QDRANT_STRICT_MAX_HNSW_EF
      search_allow_exact: $QDRANT_STRICT_ALLOW_EXACT
      max_resident_memory_percent: $QDRANT_STRICT_MAX_RESIDENT_MEMORY_PERCENT
      search_max_batchsize: $QDRANT_STRICT_SEARCH_MAX_BATCHSIZE
EOF_STRICT
)
else
    strict_block="    strict_mode:\n      enabled: false"
fi

cat > "$QDRANT_CONFIG" <<EOF_CFG
log_level: INFO

storage:
  storage_path: '$QDRANT_STORAGE'
  snapshots_path: '$QDRANT_SNAPSHOTS'
  temp_path: '$QDRANT_TMP'
  on_disk_payload: $PROFILE_ON_DISK_PAYLOAD
  performance:
    max_search_threads: $PROFILE_MAX_SEARCH_THREADS
    optimizer_cpu_budget: $PROFILE_OPTIMIZER_CPU_BUDGET
  optimizers:
    max_optimization_threads: $PROFILE_MAX_OPTIMIZATION_THREADS
  hnsw_index:
    max_indexing_threads: $PROFILE_MAX_INDEXING_THREADS
    on_disk: $PROFILE_HNSW_ON_DISK
  collection:
    vectors:
      on_disk: $PROFILE_VECTORS_ON_DISK
$(printf '%b' "$strict_block")

service:
  host: $QDRANT_BIND_HOST
  http_port: $QDRANT_HTTP_PORT
$grpc_line
  enable_cors: $ENABLE_CORS
  max_request_size_mb: $QDRANT_MAX_REQUEST_SIZE_MB

cluster:
  enabled: false

telemetry_disabled: true
EOF_CFG

chmod 0640 "$QDRANT_CONFIG"
if [[ "$PROCESS_MODE" == "service-user" ]]; then
    require_root
    chown -R "$QDRANT_USER:$QDRANT_USER" "$QDRANT_STORAGE" "$QDRANT_SNAPSHOTS" "$QDRANT_LOGS" "$QDRANT_TMP"
    chown root:"$QDRANT_USER" "$QDRANT_CONFIG"
fi
write_runtime_env

ok "Configuration written: $QDRANT_CONFIG"
info "Profile:               $QDRANT_PROFILE"
info "Startup low-memory:    $PROFILE_LOW_MEMORY_MODE"
info "Vectors on disk:       $PROFILE_VECTORS_ON_DISK"
info "HNSW on disk:          $PROFILE_HNSW_ON_DISK"
info "Internal REST bind:    http://$QDRANT_BIND_HOST:$QDRANT_HTTP_PORT"
info "gRPC enabled:          $QDRANT_ENABLE_GRPC"
[[ "$QDRANT_ENABLE_GRPC" == "1" ]] && info "Internal gRPC:         $QDRANT_BIND_HOST:$QDRANT_GRPC_PORT"
info "Strict mode defaults:  $QDRANT_STRICT_MODE"
[[ "$QDRANT_STRICT_MODE" == "1" ]] && info "Strict memory/batch:    ${QDRANT_STRICT_MAX_RESIDENT_MEMORY_PERCENT}% / ${QDRANT_STRICT_SEARCH_MAX_BATCHSIZE}"
info "JWT RBAC:              $QDRANT_JWT_RBAC"
ok "API keys are not stored in qdrant.yaml"
