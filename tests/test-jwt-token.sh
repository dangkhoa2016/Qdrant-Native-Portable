#!/usr/bin/env bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
secret='0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
token="$(QDRANT_API_KEY="$secret" python3 "$PROJECT_DIR/scripts/jwt-token.py" --scope fairy_tales:r --scope demo:rw --ttl 300)"
TOKEN="$token" SECRET="$secret" python3 - <<'PY'
import base64, hashlib, hmac, json, os, time
parts=os.environ['TOKEN'].split('.')
assert len(parts)==3
def dec(s):
    return base64.urlsafe_b64decode(s + '='*((4-len(s)%4)%4))
header=json.loads(dec(parts[0]))
payload=json.loads(dec(parts[1]))
assert header == {'alg':'HS256','typ':'JWT'}
assert payload['access'] == [
    {'collection':'fairy_tales','access':'r'},
    {'collection':'demo','access':'rw'},
]
assert int(time.time()) < payload['exp'] <= int(time.time()) + 305
sig=hmac.new(os.environ['SECRET'].encode(), f'{parts[0]}.{parts[1]}'.encode(), hashlib.sha256).digest()
assert hmac.compare_digest(sig, dec(parts[2]))
PY
echo 'JWT token tests passed'
