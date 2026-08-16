#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/deploy/beam/app.py"
ENTRYPOINT="$ROOT/deploy/beam/entrypoint.sh"
DOCKERFILE="$ROOT/docker/Dockerfile"
DOCKERIGNORE="$ROOT/.dockerignore"
BEAMIGNORE="$ROOT/.beamignore"
fail_test() { echo "Beam persistence adapter test failed: $*" >&2; exit 1; }

[[ -f "$APP" ]] || fail_test "missing deploy/beam/app.py"
[[ -f "$ENTRYPOINT" ]] || fail_test "missing deploy/beam/entrypoint.sh"
[[ -f "$DOCKERFILE" ]] || fail_test "missing docker/Dockerfile"
[[ -f "$DOCKERIGNORE" ]] || fail_test "missing root .dockerignore"
[[ -f "$BEAMIGNORE" ]] || fail_test "missing root .beamignore"

python3 - "$APP" "$ENTRYPOINT" "$DOCKERFILE" "$DOCKERIGNORE" "$BEAMIGNORE" <<'PY'
import pathlib
import sys

app_path = pathlib.Path(sys.argv[1])
entrypoint_path = pathlib.Path(sys.argv[2])
dockerfile_path = pathlib.Path(sys.argv[3])
dockerignore_path = pathlib.Path(sys.argv[4])
beamignore_path = pathlib.Path(sys.argv[5])
app = app_path.read_text(encoding="utf-8")
entrypoint = entrypoint_path.read_text(encoding="utf-8")
dockerfile = dockerfile_path.read_text(encoding="utf-8")
dockerignore = dockerignore_path.read_text(encoding="utf-8")
beamignore = beamignore_path.read_text(encoding="utf-8")


def require(text: str, fragment: str, message: str) -> None:
    if fragment not in text:
        raise SystemExit(f"Beam persistence adapter test failed: {message}")


require(app, "from beam import Image, Pod, Volume", "Beam adapter must import Volume")
require(app, 'BEAM_PERSIST_VOLUME_NAME = "qnp-qdrant-persist"', "wrong Beam Volume name")
require(app, 'BEAM_PERSIST_PATH = "/qdrant-persist"', "wrong Beam Volume mount path")
require(app, "Volume(", "Beam adapter must instantiate a Volume")
require(app, "name=BEAM_PERSIST_VOLUME_NAME", "Beam Volume must use the canonical name")
require(app, "mount_path=BEAM_PERSIST_PATH", "Beam Volume must mount at the persistence path")
require(app, "volumes=[persist_volume]", "Beam Pod must attach the persistence Volume")
require(app, '"QNP_ENV": "production"', "Beam must run production policy")
require(app, '"QNP_RUNTIME": "docker"', "Beam must run Docker runtime policy")
require(app, '"QNP_TOPOLOGY": "single"', "Beam topology must stay single-node")
require(app, '"QNP_STORAGE_MODE": "snapshot-persist"', "Beam must enable snapshot-persist")
require(app, '"QNP_PERSIST_PATH": BEAM_PERSIST_PATH', "Beam must pass the canonical persist path")
require(app, '"QNP_REQUIRE_PERSIST_MOUNT": "1"', "Beam must start fail-closed on persist mount")
require(app, '"QNP_AUTO_RESTORE": "1"', "Beam must auto-restore persisted snapshots")
require(app, '"QNP_AUTO_SNAPSHOT_INTERVAL_SECONDS": str(BEAM_AUTO_SNAPSHOT_INTERVAL_SECONDS)', "Beam cadence must derive from the Beam constant")
require(app, '"QNP_AUTO_SNAPSHOT_ON_SHUTDOWN": "0"', "Beam shutdown snapshots must remain disabled until lifecycle proof")
require(app, '"QNP_SNAPSHOT_RETENTION": "3"', "Beam retention must be three completed snapshots")
require(app, '"QNP_READY_TIMEOUT_SECONDS": "180"', "Beam readiness timeout must be explicit")
require(app, "BEAM_AUTO_SNAPSHOT_INTERVAL_SECONDS = 600", "Beam controlled validation cadence must be 600 seconds")
require(app, "BEAM_KEEP_WARM_SECONDS = -1", "Beam keep-warm must be explicitly defined as -1 (no idle shutdown)")
require(app, "keep_warm_seconds=BEAM_KEEP_WARM_SECONDS", "Beam keep-warm must be configurable via BEAM_KEEP_WARM_SECONDS")
require(app, 'entrypoint=["/qdrant/qnp-beam-entrypoint.sh"]', "Beam must launch through provider preflight wrapper")
require(app, 'secrets=["QDRANT_API_KEY", "QDRANT_READ_ONLY_API_KEY"]', "Beam credentials must stay runtime-injected")

for pattern in (
    "temp/",
    "*.log",
    "__pycache__/",
    "*.py[cod]",
    ".qdrant-base",
    "runtime.env",
    "secrets.env",
    "*.zip",
    "*.zip.sha256",
):
    if pattern not in beamignore.splitlines():
        raise SystemExit(f"Beam persistence adapter test failed: .beamignore missing hygiene pattern {pattern!r}")

if 'mount_path="/qdrant/storage"' in app or "mount_path='/qdrant/storage'" in app:
    raise SystemExit("Beam persistence adapter test failed: Beam Volume must never back live /qdrant/storage")

require(entrypoint, 'persist="${QNP_PERSIST_PATH:-/qdrant-persist}"', "preflight must use QNP_PERSIST_PATH")
require(entrypoint, ".qnp-beam-volume-probe-", "preflight must use a dedicated QNP probe")
if "python3" in entrypoint or "os.fsync" in entrypoint:
    raise SystemExit("Beam persistence adapter test failed: Beam container preflight must not depend on Python")
require(entrypoint, "command -v dd", "preflight must verify dd is available")
require(entrypoint, "conv=fsync", "preflight must fsync the provider probe with dd")
require(entrypoint, "cmp -s", "preflight must compare exact probe bytes")
require(entrypoint, "exec /qdrant/qnp-entrypoint.sh", "preflight must delegate to the QNP entrypoint")

probe = entrypoint.find(".qnp-beam-volume-probe-")
launch = entrypoint.find("exec /qdrant/qnp-entrypoint.sh")
if min(probe, launch) < 0 or not probe < launch:
    raise SystemExit("Beam persistence adapter test failed: provider preflight must occur before QNP launch")
PY

# Import smoke test: execute entire app.py using a fake beam module to catch
# NameError/TypeError/undefined globals even when the real Beam SDK is absent.
python3 - "$APP" <<'PYEOF'
import importlib.util, pathlib, sys, types

path = pathlib.Path(sys.argv[1])

# Build a minimal fake beam module so app.py can execute fully.
fake_beam = types.ModuleType("beam")

class _FakeImage:
    def from_dockerfile(self, *a, **kw):
        return self
    def entrypoint(self, *a, **kw):
        return self

class _FakeVolume:
    def __init__(self, **kw):
        self._kw = kw

class _FakePod:
    def __init__(self, **kw):
        self._kw = kw

fake_beam.Image = _FakeImage
fake_beam.Volume = _FakeVolume
fake_beam.Pod = _FakePod
sys.modules["beam"] = fake_beam

spec = importlib.util.spec_from_file_location("beam_app", str(path))
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

# Verify critical Pod configuration was set correctly.
pod = mod.pod
assert pod._kw.get("keep_warm_seconds") == -1, f"expected keep_warm_seconds=-1, got {pod._kw.get('keep_warm_seconds')}"
assert 6333 in pod._kw.get("ports", []), f"expected port 6333 in ports"
assert any(v._kw.get("name") == "qnp-qdrant-persist" for v in pod._kw.get("volumes", [])), "missing persist volume"
assert pod._kw.get("entrypoint") == ["/qdrant/qnp-beam-entrypoint.sh"], "wrong entrypoint"
PYEOF

echo "Beam persistence adapter tests passed"
