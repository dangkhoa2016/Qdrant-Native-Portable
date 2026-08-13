FROM qdrant/qdrant:v1.18.3-unprivileged

COPY --chown=1000:1000 docker/entrypoint.sh /qdrant/qnp-entrypoint.sh
COPY --chown=1000:1000 docker/healthcheck.sh /qdrant/qnp-healthcheck.sh
COPY --chown=1000:1000 docker/persistence.sh /qdrant/qnp-persistence.sh
COPY --chown=1000:1000 deploy/beam/entrypoint.sh /qdrant/qnp-beam-entrypoint.sh

ENV QNP_ENV=production \
    QNP_RUNTIME=docker \
    QNP_TOPOLOGY=single \
    QNP_STORAGE_MODE=local \
    QDRANT_BIND_HOST=0.0.0.0 \
    QDRANT_HTTP_PORT=6333 \
    QDRANT__SERVICE__ENABLE_CORS=false \
    QDRANT__CLUSTER__ENABLED=false \
    QDRANT__STORAGE__STORAGE_PATH=/qdrant/storage \
    QDRANT__STORAGE__SNAPSHOTS_PATH=/qdrant/snapshots \
    QDRANT__TELEMETRY_DISABLED=true

USER 1000:1000
EXPOSE 6333
HEALTHCHECK --interval=15s --timeout=5s --start-period=180s --retries=5 CMD ["/qdrant/qnp-healthcheck.sh"]
# Reset the base image CMD; otherwise it is passed as arguments to our ENTRYPOINT.
CMD []
ENTRYPOINT ["/qdrant/qnp-entrypoint.sh"]
