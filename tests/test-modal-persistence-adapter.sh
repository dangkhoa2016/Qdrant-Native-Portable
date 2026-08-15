#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/deploy/modal/app.py"
fail_test() { echo "Modal persistence adapter test failed: $*" >&2; exit 1; }

[[ -f "$APP" ]] || fail_test "missing deploy/modal/app.py"

python3 - "$APP" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text(encoding="utf-8")

def require(fragment: str, message: str) -> None:
    if fragment not in text:
        raise SystemExit(f"Modal persistence adapter test failed: {message}")

require('"QNP_REQUIRE_PERSIST_MOUNT": "1"',
        "Modal must remain fail-closed before provider-native persistence validation")
require('def _verify_modal_persist_volume',
        "missing provider-native durable-volume preflight")
require('persist_volume.commit()',
        "durable-volume preflight must commit the filesystem probe")
require('persist_volume.read_file(',
        "durable-volume preflight must read the committed probe through the Volume API")
require('QNP_REQUIRE_PERSIST_MOUNT"] = "0"',
        "mountinfo validation must be disabled only after Modal-native validation")
require('.qnp-modal-volume-probe-',
        "durable-volume probe must use a dedicated QNP marker name")

# Modal scale-to-zero timing must leave a real window for the first periodic
# snapshot after Qdrant readiness. Lock both the target cadence and a minimum
# safety margin so a future edit cannot silently recreate the 900s/900s race.
require('MODAL_AUTO_SNAPSHOT_INTERVAL_SECONDS = 600',
        "Modal periodic snapshot cadence must be 600 seconds")
require('MODAL_SCALEDOWN_WINDOW_SECONDS = 900',
        "Modal scaledown window must remain 900 seconds for this candidate")
require('MODAL_MIN_SNAPSHOT_MARGIN_SECONDS = 180',
        "Modal timing policy must reserve at least a 180-second safety margin")
require('def _validate_modal_timing_policy',
        "missing Modal snapshot-vs-scaledown timing invariant")
require('_validate_modal_timing_policy()',
        "Modal timing invariant must execute during adapter initialization")
require('str(MODAL_AUTO_SNAPSHOT_INTERVAL_SECONDS)',
        "SERVER_ENV must derive snapshot cadence from the validated Modal constant")
require('scaledown_window=MODAL_SCALEDOWN_WINDOW_SECONDS',
        "Modal server scaledown must derive from the validated Modal constant")

# Modal sends termination to running Server processes concurrently with @modal.exit().
# Therefore a provider shutdown snapshot cannot be guaranteed to run before Qdrant
# begins stopping. Modal must declare periodic snapshots as its durability boundary
# instead of advertising an unreliable shutdown-snapshot guarantee.
require('"QNP_AUTO_SNAPSHOT_ON_SHUTDOWN": "0"',
        "Modal must disable unguaranteed shutdown snapshots")
require('MODAL_DURABILITY_RPO_SECONDS = MODAL_AUTO_SNAPSHOT_INTERVAL_SECONDS',
        "Modal must expose the periodic snapshot interval as its durability RPO")
require('[qnp-modal] periodic snapshot durability boundary:',
        "Modal startup must log the periodic durability boundary")

import re
def int_constant(name: str) -> int:
    match = re.search(rf"^{name} = ([0-9]+)$", text, re.MULTILINE)
    if not match:
        raise SystemExit(f"Modal persistence adapter test failed: missing integer constant {name}")
    return int(match.group(1))

interval = int_constant("MODAL_AUTO_SNAPSHOT_INTERVAL_SECONDS")
scaledown = int_constant("MODAL_SCALEDOWN_WINDOW_SECONDS")
minimum_margin = int_constant("MODAL_MIN_SNAPSHOT_MARGIN_SECONDS")
if interval >= scaledown:
    raise SystemExit(
        "Modal persistence adapter test failed: snapshot interval must be below scale-down window"
    )
if scaledown - interval < minimum_margin:
    raise SystemExit(
        "Modal persistence adapter test failed: snapshot cadence lacks required scale-down safety margin"
    )

# Provider shutdown observability is intentionally secret-free. These markers
# let real Modal logs prove whether the exit hook ran, the QNP child received
# termination, and the final Volume commit completed.
for marker, message in (
    ('[qnp-modal] exit hook started', 'missing Modal exit-hook start log'),
    ('[qnp-modal] sending SIGTERM to QNP child', 'missing QNP child termination log'),
    ('[qnp-modal] QNP child exited rc=', 'missing QNP child exit-code log'),
    ('[qnp-modal] committing Modal persistence volume', 'missing exit Volume commit-start log'),
    ('[qnp-modal] exit volume commit complete', 'missing exit Volume commit-complete log'),
):
    require(marker, message)

call = text.find('self._verify_modal_persist_volume()')
disable = text.find('QNP_REQUIRE_PERSIST_MOUNT"] = "0"')
launch = text.find('subprocess.Popen(["/qdrant/qnp-entrypoint.sh"]')
if min(call, disable, launch) < 0:
    raise SystemExit("Modal persistence adapter test failed: missing startup ordering markers")
if not call < disable < launch:
    raise SystemExit(
        "Modal persistence adapter test failed: startup must verify durable Volume, "
        "then disable Linux mountinfo validation, then launch QNP"
    )

# The Modal Volume remains snapshot-only and must not become Qdrant live storage.
if 'volumes={"/qdrant/storage"' in text or 'volumes={"/qdrant/storage/"' in text:
    raise SystemExit("Modal persistence adapter test failed: live Qdrant storage must stay local")
PY

echo "Modal persistence adapter tests passed"
