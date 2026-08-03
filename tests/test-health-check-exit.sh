#!/usr/bin/env bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
server_pid=""
trap '[[ -z "$server_pid" ]] || kill "$server_pid" 2>/dev/null || true; rm -rf "$tmp"; rm -f "$PROJECT_DIR/.qdrant-base"' EXIT

port="$(python3 - <<'PY'
import socket
s=socket.socket(); s.bind(('127.0.0.1',0)); print(s.getsockname()[1]); s.close()
PY
)"
proxy_port="$(python3 - <<'PY'
import socket
s=socket.socket(); s.bind(('127.0.0.1',0)); print(s.getsockname()[1]); s.close()
PY
)"

cat > "$tmp/server.py" <<'PY'
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
class H(BaseHTTPRequestHandler):
    def do_GET(self):
        body = {"version":"test"} if self.path == "/" else {"result":{"collections":[]},"status":"ok"}
        raw=json.dumps(body).encode(); self.send_response(200); self.send_header("Content-Type","application/json"); self.send_header("Content-Length",str(len(raw))); self.end_headers(); self.wfile.write(raw)
    def log_message(self, *args): pass
HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY

common_env=(
    QDRANT_PLATFORM=generic-linux
    PROCESS_MODE=current-user
    PUBLIC_MODE=none
    QDRANT_PROFILE=low-memory
    QDRANT_ENABLE_GRPC=0
    QDRANT_API_KEY=test-admin-key-not-a-production-credential
    QDRANT_READ_ONLY_API_KEY=test-readonly-key-not-a-production-credential
)

# DOWN must be a failing health check.
if env "${common_env[@]}" DEPLOYMENT_MODE=minimal QDRANT_HTTP_PORT="$port" BASE_DIR="$tmp/down" \
    bash "$PROJECT_DIR/scripts/09_health_check.sh" >/dev/null 2>&1; then
    echo 'FAIL: health check exited 0 while Qdrant API was down' >&2
    exit 1
fi

# Healthy Qdrant with gRPC disabled must exit 0.
python3 "$tmp/server.py" "$port" & server_pid=$!
for _ in $(seq 1 30); do curl -fsS "http://127.0.0.1:$port/collections" >/dev/null 2>&1 && break; sleep 0.1; done
if ! env "${common_env[@]}" DEPLOYMENT_MODE=minimal QDRANT_HTTP_PORT="$port" BASE_DIR="$tmp/up" \
    bash "$PROJECT_DIR/scripts/09_health_check.sh" >/dev/null 2>&1; then
    echo 'FAIL: health check exited non-zero while Qdrant API was healthy and gRPC disabled' >&2
    exit 1
fi

# In proxy mode, a dead required proxy must fail even when Qdrant itself is healthy.
if env "${common_env[@]}" DEPLOYMENT_MODE=proxy QDRANT_HTTP_PORT="$port" PROXY_PORT="$proxy_port" BASE_DIR="$tmp/proxy-down" \
    bash "$PROJECT_DIR/scripts/09_health_check.sh" >/dev/null 2>&1; then
    echo 'FAIL: health check exited 0 while required proxy was down' >&2
    exit 1
fi

echo 'health check exit semantics passed'
