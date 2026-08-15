"""Modal single-node Qdrant deployment with durable snapshot persistence.

Qdrant live database files stay on the container-local POSIX filesystem at
/qdrant/storage. A Modal Volume is mounted only at /qdrant-persist and stores
completed, checksum-protected full snapshots through QNP's snapshot-persist
adapter. The Volume is intentionally not used as live Qdrant storage.
"""

import os
import secrets
import subprocess
import time

import modal

APP_NAME = "qnp-qdrant-single"
PORT = 6333
PERSIST_PATH = "/qdrant-persist"
PERSIST_VOLUME_NAME = "qnp-qdrant-persist"
SECRET_NAME = "qnp-qdrant-secrets"
STARTUP_TIMEOUT_SECONDS = 240
QNP_READY_TIMEOUT_SECONDS = 180
SHUTDOWN_WAIT_SECONDS = 20

# Modal starts its idle scale-down clock before Qdrant necessarily reaches
# readiness, while QNP's periodic snapshot timer starts only after readiness.
# Keep the first periodic snapshot comfortably ahead of scale-down instead of
# racing an equal 900-second timer on both sides.
MODAL_AUTO_SNAPSHOT_INTERVAL_SECONDS = 600
MODAL_SCALEDOWN_WINDOW_SECONDS = 900
MODAL_MIN_SNAPSHOT_MARGIN_SECONDS = 180
MODAL_DURABILITY_RPO_SECONDS = MODAL_AUTO_SNAPSHOT_INTERVAL_SECONDS


def _validate_modal_timing_policy() -> None:
    margin = MODAL_SCALEDOWN_WINDOW_SECONDS - MODAL_AUTO_SNAPSHOT_INTERVAL_SECONDS
    if margin < MODAL_MIN_SNAPSHOT_MARGIN_SECONDS:
        raise RuntimeError(
            "Modal snapshot cadence must leave at least "
            f"{MODAL_MIN_SNAPSHOT_MARGIN_SECONDS}s before scale-down "
            f"(snapshot={MODAL_AUTO_SNAPSHOT_INTERVAL_SECONDS}s, "
            f"scaledown={MODAL_SCALEDOWN_WINDOW_SECONDS}s)"
        )


_validate_modal_timing_policy()

app = modal.App(APP_NAME)

# QNP's Docker image has an ENTRYPOINT that launches Qdrant directly. Modal
# needs its own Python runtime to start first, so clear that image entrypoint
# and launch QNP explicitly from the Server lifecycle hook below.
image = (
    modal.Image.from_dockerfile(
        "docker/Dockerfile",
        context_dir=".",
        add_python="3.12",
    )
    .entrypoint([])
)

secret = modal.Secret.from_name(SECRET_NAME)

# Pin to Volume v1 for the validated Modal snapshot-persist path. The Volume
# is used only for completed snapshot artifacts, never for live Qdrant segments/indexes.
persist_volume = modal.Volume.from_name(
    PERSIST_VOLUME_NAME,
    create_if_missing=True,
    version=1,
)

SERVER_ENV = {
    "QNP_ENV": "production",
    "QNP_TOPOLOGY": "single",
    "QNP_STORAGE_MODE": "snapshot-persist",
    "QNP_PERSIST_PATH": "/qdrant-persist",
    "QNP_REQUIRE_PERSIST_MOUNT": "1",
    "QNP_AUTO_RESTORE": "1",
    "QNP_AUTO_SNAPSHOT_INTERVAL_SECONDS": str(MODAL_AUTO_SNAPSHOT_INTERVAL_SECONDS),
    # Modal Server shutdown sends termination to running processes while
    # @modal.exit() is also invoked, so a QNP shutdown snapshot cannot be
    # ordered ahead of Qdrant termination. Periodic snapshots are the explicit
    # durability boundary for this provider; the exit hook only commits already
    # completed snapshot artifacts.
    "QNP_AUTO_SNAPSHOT_ON_SHUTDOWN": "0",
    "QNP_SNAPSHOT_RETENTION": "3",
    "QNP_READY_TIMEOUT_SECONDS": str(QNP_READY_TIMEOUT_SECONDS),
}


@app.server(
    image=image,
    secrets=[secret],
    volumes={"/qdrant-persist": persist_volume},
    env=SERVER_ENV,
    port=PORT,
    startup_timeout=STARTUP_TIMEOUT_SECONDS,
    min_containers=0,
    max_containers=1,
    scaledown_window=MODAL_SCALEDOWN_WINDOW_SECONDS,
    exit_grace_period=10,
    # Modal proxy authentication is disabled so Qdrant's own admin/read-only
    # API-key policy is the externally visible authentication layer.
    unauthenticated=True,
)
class QdrantServer:
    def _verify_modal_persist_volume(self) -> None:
        """Prove the mounted Modal Volume is durably writable before QNP starts.

        Modal Volumes are exposed as filesystems but are not guaranteed to appear
        as a traditional Linux mountpoint in /proc/self/mountinfo. QNP's generic
        Docker/HF mount-table guard therefore cannot be the authoritative Modal
        check. Instead, write a unique probe through the mounted filesystem,
        commit it, and read the committed bytes back through the Modal Volume API.
        Only after this round-trip succeeds may the QNP child bypass the generic
        mountinfo check.
        """

        token = secrets.token_hex(16)
        probe_name = f".qnp-modal-volume-probe-{token}"
        probe_path = os.path.join(PERSIST_PATH, probe_name)
        expected = f"qnp-modal-volume-probe:{token}\n".encode("utf-8")

        try:
            with open(probe_path, "xb") as probe:
                probe.write(expected)
                probe.flush()

            persist_volume.commit()
            observed = b"".join(persist_volume.read_file(probe_name))
            if observed != expected:
                raise RuntimeError(
                    "committed Modal Volume probe did not round-trip exactly"
                )
        except Exception as exc:
            # Best-effort cleanup must never turn a failed durability check into
            # an apparent success. Qdrant remains stopped on every error here.
            try:
                if os.path.exists(probe_path):
                    os.unlink(probe_path)
                    persist_volume.commit()
            except Exception:
                pass
            raise RuntimeError(
                "Modal durable persistence preflight failed for /qdrant-persist"
            ) from exc

        try:
            os.unlink(probe_path)
            persist_volume.commit()
        except Exception as exc:
            raise RuntimeError(
                "Modal durable persistence probe cleanup/commit failed"
            ) from exc

        print(
            "[qnp-modal] durable Modal Volume preflight passed for /qdrant-persist",
            flush=True,
        )

    @modal.enter()
    def start(self) -> None:
        self._verify_modal_persist_volume()

        # The provider-native round-trip above replaces QNP's Linux mount-table
        # check for Modal only. Keep SERVER_ENV fail-closed at 1 so any alternate
        # launch path still refuses to run without an explicit validation step.
        os.environ["QNP_REQUIRE_PERSIST_MOUNT"] = "0"
        print(
            "[qnp-modal] Modal-native persistence validated; "
            "Linux mountinfo check disabled for QNP child",
            flush=True,
        )
        print(
            "[qnp-modal] periodic snapshot durability boundary: "
            f"<= {MODAL_DURABILITY_RPO_SECONDS}s; "
            "provider shutdown snapshots disabled",
            flush=True,
        )
        self.proc = subprocess.Popen(["/qdrant/qnp-entrypoint.sh"])
        deadline = time.monotonic() + STARTUP_TIMEOUT_SECONDS

        while time.monotonic() < deadline:
            if self.proc.poll() is not None:
                raise RuntimeError(
                    "QNP entrypoint exited before Qdrant became ready "
                    f"(exit code {self.proc.returncode})"
                )

            health = subprocess.run(
                ["/qdrant/qnp-healthcheck.sh"],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=False,
            )
            if health.returncode == 0:
                return
            time.sleep(1)

        self.proc.terminate()
        try:
            self.proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            self.proc.wait()
        raise TimeoutError("Qdrant did not become ready before Modal startup timeout")

    @modal.exit()
    def stop(self) -> None:
        print("[qnp-modal] exit hook started", flush=True)
        proc = getattr(self, "proc", None)

        if proc is None:
            print("[qnp-modal] no QNP child process was registered", flush=True)
        elif proc.poll() is None:
            # Modal may already be terminating other container processes when
            # this exit hook runs. This SIGTERM is therefore process cleanup,
            # not a promise that QNP can snapshot before Qdrant begins stopping.
            print("[qnp-modal] sending SIGTERM to QNP child", flush=True)
            proc.terminate()
            try:
                proc.wait(timeout=SHUTDOWN_WAIT_SECONDS)
            except subprocess.TimeoutExpired:
                # Periodic snapshots are the primary protection; do not let a
                # stuck shutdown consume Modal's entire exit-handler window.
                print(
                    "[qnp-modal] QNP child exceeded shutdown wait; sending SIGKILL",
                    flush=True,
                )
                proc.kill()
                proc.wait()
            print(f"[qnp-modal] QNP child exited rc={proc.returncode}", flush=True)
        else:
            print(f"[qnp-modal] QNP child exited rc={proc.returncode}", flush=True)

        # Modal also performs background/final commits. Keep this explicit
        # commit so the newest already-completed periodic snapshot artifacts
        # are flushed deliberately before the exit handler returns.
        print("[qnp-modal] committing Modal persistence volume", flush=True)
        try:
            persist_volume.commit()
        except Exception:
            print("[qnp-modal] exit volume commit failed", flush=True)
            raise
        print("[qnp-modal] exit volume commit complete", flush=True)
