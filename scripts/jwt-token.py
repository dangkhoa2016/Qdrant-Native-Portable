#!/usr/bin/env python3
"""Generate Qdrant HS256 JWT access tokens without third-party dependencies."""
import argparse, base64, hashlib, hmac, json, os, sys, time

def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")

def parse_scope(value: str):
    try:
        collection, access = value.rsplit(":", 1)
    except ValueError:
        raise argparse.ArgumentTypeError("scope must be COLLECTION:r or COLLECTION:rw")
    if not collection or access not in {"r", "rw"}:
        raise argparse.ArgumentTypeError("scope must be COLLECTION:r or COLLECTION:rw")
    return {"collection": collection, "access": access}

p = argparse.ArgumentParser()
p.add_argument("--scope", action="append", type=parse_scope, default=[])
p.add_argument("--access", choices=["r", "m"])
p.add_argument("--ttl", type=int, default=3600, help="seconds; 0 means no exp claim")
args = p.parse_args()
if args.scope and args.access:
    p.error("use either --scope or --access, not both")
if not args.scope and not args.access:
    p.error("at least one --scope or --access is required")
secret = os.environ.get("QDRANT_API_KEY", "")
if not secret:
    sys.exit("QDRANT_API_KEY is not set")

payload = {"access": args.scope if args.scope else args.access}
if args.ttl < 0:
    p.error("--ttl must be >= 0")
if args.ttl:
    payload["exp"] = int(time.time()) + args.ttl
header = {"alg": "HS256", "typ": "JWT"}
segments = [b64url(json.dumps(x, separators=(",", ":")).encode()) for x in (header, payload)]
signing_input = ".".join(segments).encode()
signature = hmac.new(secret.encode(), signing_input, hashlib.sha256).digest()
print(".".join(segments + [b64url(signature)]))
