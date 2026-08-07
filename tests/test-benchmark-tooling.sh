#!/usr/bin/env bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
server_pid=""
trap '[[ -z "$server_pid" ]] || kill "$server_pid" 2>/dev/null || true; rm -rf "$tmp"' EXIT

port="$(python3 - <<'PY'
import socket
s=socket.socket(); s.bind(('127.0.0.1',0)); print(s.getsockname()[1]); s.close()
PY
)"
cat > "$tmp/fake_qdrant.py" <<'PY'
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
class H(BaseHTTPRequestHandler):
    def send_json(self, body):
        raw=json.dumps(body).encode(); self.send_response(200); self.send_header('Content-Type','application/json'); self.send_header('Content-Length',str(len(raw))); self.end_headers(); self.wfile.write(raw)
    def do_GET(self):
        if self.path == '/': return self.send_json({'version':'test-qdrant'})
        if self.path.startswith('/collections/'):
            return self.send_json({'status':'ok','result':{'status':'green','optimizer_status':'ok','points_count':5,'indexed_vectors_count':5,'segments_count':1}})
        return self.send_json({'status':'ok','result':{'collections':[]}})
    def do_PUT(self):
        n=int(self.headers.get('Content-Length','0')); self.rfile.read(n)
        self.send_json({'status':'ok','result':{'operation_id':1,'status':'completed'},'time':0.001})
    def do_POST(self):
        n=int(self.headers.get('Content-Length','0')); self.rfile.read(n)
        self.send_json({'status':'ok','result':{'points':[{'id':1,'score':1.0}]},'time':0.0001})
    def do_DELETE(self):
        self.send_json({'status':'ok','result':True,'time':0.0001})
    def log_message(self,*args): pass
HTTPServer(('127.0.0.1',int(sys.argv[1])),H).serve_forever()
PY
python3 "$tmp/fake_qdrant.py" "$port" & server_pid=$!
for _ in $(seq 1 30); do curl -fsS "http://127.0.0.1:$port/" >/dev/null 2>&1 && break; sleep 0.1; done

mkdir -p "$tmp/base/storage" "$tmp/out"
QDRANT_URL="http://127.0.0.1:$port" \
QDRANT_API_KEY=test-key \
QDRANT_BENCHMARK_DIR="$tmp/out" \
QDRANT_BASE_DIR="$tmp/base" \
QDRANT_STORAGE_DIR="$tmp/base/storage" \
QDRANT_PROJECT_VERSION=1.0.0 \
QDRANT_PLATFORM_DETECTED=codesandbox \
QDRANT_VERSION=1.18.3 \
QDRANT_PROFILE=low-memory \
PROCESS_MODE=current-user \
DEPLOYMENT_MODE=minimal \
PUBLIC_MODE=cloudflare-quick \
QDRANT_ENABLE_GRPC=0 \
QDRANT_STRICT_MODE=1 \
python3 "$PROJECT_DIR/benchmarks/benchmark.py" \
    --points 5 --dimension 4 --batch-size 2 --queries 3 --cold-queries 2 --warmup 3 --repeat 2 \
    --settle-timeout 2 --settle-max-timeout 3 --settle-poll 0.1 --output "$tmp/out/result.json" >/dev/null

python3 - "$tmp/out/result.json" <<'PY'
import json,sys
x=json.load(open(sys.argv[1]))
assert x['schema_version']==3
assert x['runtime']['project_version']=='1.0.0'
assert x['host_before']['platform_detected']=='codesandbox'
assert len(x['runs'])==2
assert x['aggregate']['repeat_count']==2
assert x['aggregate']['all_runs_settled'] is True
assert x['aggregate']['query_ms_warm_combined']['count']==6
assert x['aggregate']['query_ms_cold_combined']['count']==4
assert x['aggregate']['all_runs_benchmark_ready'] is True
assert x['aggregate']['provisional'] is False
assert 'total_timing_seconds' in x['aggregate']
for run in x['runs']:
    assert len(run['query_ms_warm']['raw'])==3
    assert len(run['query_ms_cold']['raw'])==2
    assert run['settle']['benchmark_ready'] is True
    assert 'vector_generation' in run['timing_seconds']
    assert 'json_encoding' in run['timing_seconds']
    assert 'ingestion_http' in run['timing_seconds']
    assert 'run_wall' in run['timing_seconds']
    assert 'settle_wait' in run['timing_seconds']
    assert run['settle']['max_timeout_seconds'] == 3
PY

QDRANT_URL="http://127.0.0.1:$port" \
QDRANT_API_KEY=test-key \
QDRANT_BENCHMARK_DIR="$tmp/out" \
QDRANT_BASE_DIR="$tmp/base" \
QDRANT_STORAGE_DIR="$tmp/base/storage" \
QDRANT_PROJECT_VERSION=1.0.0 \
QDRANT_PLATFORM_DETECTED=codesandbox \
QDRANT_VERSION=1.18.3 \
QDRANT_PROFILE=balanced-memory \
PROCESS_MODE=current-user DEPLOYMENT_MODE=minimal PUBLIC_MODE=none \
python3 "$PROJECT_DIR/benchmarks/benchmark.py" \
    --points 5 --dimension 4 --batch-size 5 --queries 1 --cold-queries 0 --warmup 1 --repeat 1 \
    --settle-timeout 0 --settle-max-timeout 1 --settle-poll 0.05 --stable-polls 2 \
    --output "$tmp/out/extension.json" >/dev/null
python3 - "$tmp/out/extension.json" <<'PY'
import json,sys
x=json.load(open(sys.argv[1]))
s=x['runs'][0]['settle']
assert s['benchmark_ready'] is True
assert s['timeout_extended'] is True
assert s['extension_reason']=='ready-state-needs-stable-polls'
PY

python3 "$PROJECT_DIR/benchmarks/report.py" \
    --suite-wall-seconds 12 \
    --json-output "$tmp/out/report.json" \
    --markdown-output "$tmp/out/report.md" \
    "$tmp/out/result.json" >/dev/null

grep -q 'Qdrant benchmark report' "$tmp/out/report.md"
grep -q 'test-qdrant' "$tmp/out/report.md"
grep -q 'Suite status: \*\*READY\*\*' "$tmp/out/report.md"
grep -q '12s' "$tmp/out/report.md"

help_out="$(BASE_DIR="$tmp/help-runtime" QDRANT_PLATFORM=generic-linux PROCESS_MODE=current-user DEPLOYMENT_MODE=minimal PUBLIC_MODE=none bash "$PROJECT_DIR/qdrant.sh" --help)"
for cmd in auth-check benchmark-status benchmark-profiles benchmark-acceptance compare-benchmarks source-integrity; do
  grep -q "$cmd" <<<"$help_out" || { echo "qdrant.sh help missing command: $cmd" >&2; exit 1; }
done

echo 'benchmark tooling tests passed'
