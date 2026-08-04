#!/usr/bin/env bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
server_pid=""
trap '[[ -n "$server_pid" ]] && kill "$server_pid" 2>/dev/null || true; rm -rf "$tmp"' EXIT

port_file="$tmp/port"
cat > "$tmp/server.py" <<'PY'
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import sys

ADMIN='admin-test-key'
READ='readonly-test-key'

class H(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass
    def _code(self, write=False):
        key=self.headers.get('api-key')
        if key is None:
            return 401
        if key == ADMIN:
            return 200
        if key == READ:
            return 403 if write else 200
        return 401
    def do_GET(self):
        code=self._code(False)
        self.send_response(code); self.send_header('Content-Type','application/json'); self.end_headers()
        self.wfile.write(b'{"result":{"collections":[]}}')
    def do_PUT(self):
        code=self._code(True)
        length=int(self.headers.get('content-length','0') or '0')
        if length: self.rfile.read(length)
        self.send_response(code); self.send_header('Content-Type','application/json'); self.end_headers()
        self.wfile.write(b'{"result":true}')

srv=ThreadingHTTPServer(('127.0.0.1',0),H)
open(sys.argv[1],'w').write(str(srv.server_address[1]))
srv.serve_forever()
PY
python3 "$tmp/server.py" "$port_file" &
server_pid=$!
for _ in $(seq 1 50); do [[ -s "$port_file" ]] && break; sleep 0.05; done
port="$(cat "$port_file")"

BASE_DIR="$tmp/runtime" \
QDRANT_PLATFORM=generic-linux \
PROCESS_MODE=current-user DEPLOYMENT_MODE=minimal PUBLIC_MODE=none \
QDRANT_HTTP_PORT="$port" \
QDRANT_API_KEY=admin-test-key \
QDRANT_READ_ONLY_API_KEY=readonly-test-key \
  bash "$PROJECT_DIR/scripts/auth-check.sh" > "$tmp/out.txt"

grep -q 'unauthenticated collection access.*HTTP 401' "$tmp/out.txt"
grep -q 'admin API key can read collections' "$tmp/out.txt"
grep -q 'read-only API key can read collections' "$tmp/out.txt"
grep -q 'read-only API key.*write.*HTTP 403' "$tmp/out.txt"
grep -q 'runtime authorization check passed' "$tmp/out.txt"

echo 'auth-check tests passed'
