"""Beam single-node Qdrant snapshot-persistence Pod definition.

Live Qdrant database files remain container-local at /qdrant/storage.
Beam distributed storage is mounted only at /qdrant-persist for completed,
checksum-protected full snapshots managed by the existing QNP persistence core.

This adapter is a production path for Beam-hosted single-node deployments.
"""
from beam import Image, Pod, Volume

BEAM_PERSIST_VOLUME_NAME = "qnp-qdrant-persist"
BEAM_PERSIST_PATH = "/qdrant-persist"
BEAM_AUTO_SNAPSHOT_INTERVAL_SECONDS = 600
BEAM_KEEP_WARM_SECONDS = -1  # no automatic idle shutdown for single-node production

persist_volume = Volume(
    name=BEAM_PERSIST_VOLUME_NAME,
    mount_path=BEAM_PERSIST_PATH,
)

image = Image().from_dockerfile("docker/Dockerfile", context_dir=".")

pod = Pod(
    name="qnp-qdrant-single",
    image=image,
    cpu=2,
    memory="4Gi",
    ports=[6333],
    volumes=[persist_volume],
    entrypoint=["/qdrant/qnp-beam-entrypoint.sh"],
    secrets=["QDRANT_API_KEY", "QDRANT_READ_ONLY_API_KEY"],
    env={
        "QNP_ENV": "production",
        "QNP_RUNTIME": "docker",
        "QNP_TOPOLOGY": "single",
        "QNP_STORAGE_MODE": "snapshot-persist",
        "QNP_PERSIST_PATH": BEAM_PERSIST_PATH,
        "QNP_REQUIRE_PERSIST_MOUNT": "1",
        "QNP_AUTO_RESTORE": "1",
        "QNP_AUTO_SNAPSHOT_INTERVAL_SECONDS": str(BEAM_AUTO_SNAPSHOT_INTERVAL_SECONDS),
        "QNP_AUTO_SNAPSHOT_ON_SHUTDOWN": "0",
        "QNP_SNAPSHOT_RETENTION": "3",
        "QNP_READY_TIMEOUT_SECONDS": "180",
    },
    # Keep the container alive until the operator explicitly stops it.
    keep_warm_seconds=BEAM_KEEP_WARM_SECONDS,
    # Public traffic reaches Qdrant itself; Qdrant API keys remain the auth layer.
    authorized=False,
)
