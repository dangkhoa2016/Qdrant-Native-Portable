#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname "$0")/common.sh"

banner "Cleanup" "Disable project services while preserving Qdrant data and snapshots"
bash "$SCRIPT_DIR/public-access.sh" --stop
disable_proxy_config
stop_pid_file "Qdrant" "$QDRANT_PID_FILE"
ok "Project services stopped. Data and snapshots are preserved in $BASE_DIR"
