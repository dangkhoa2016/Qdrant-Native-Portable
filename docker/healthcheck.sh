#!/usr/bin/env bash
set -euo pipefail
host="${QDRANT_HEALTH_HOST:-127.0.0.1}"
port="${QDRANT_HTTP_PORT:-6333}"

exec 3<>"/dev/tcp/${host}/${port}"
printf 'GET /readyz HTTP/1.1\r\nHost: %s\r\nConnection: close\r\n\r\n' "$host" >&3
IFS= read -r status_line <&3
[[ "$status_line" == *" 200 "* ]]
