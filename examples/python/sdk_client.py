#!/usr/bin/env python3
"""Qdrant Python SDK example configured to use REST rather than gRPC."""
from __future__ import annotations

import os
import sys

from qdrant_client import QdrantClient, models

BASE_URL = os.getenv("QDRANT_URL", "http://127.0.0.1:9090").rstrip("/")
ADMIN_KEY = os.getenv("QDRANT_API_KEY", "")
READ_ONLY_KEY = os.getenv("QDRANT_READ_ONLY_API_KEY", "") or ADMIN_KEY
COLLECTION = os.getenv("QDRANT_COLLECTION", "python_sdk_demo")


def main() -> int:
    if not ADMIN_KEY:
        raise RuntimeError("Set QDRANT_API_KEY before running this example")

    admin = QdrantClient(url=BASE_URL, api_key=ADMIN_KEY, prefer_grpc=False, timeout=60)
    reader = QdrantClient(url=BASE_URL, api_key=READ_ONLY_KEY, prefer_grpc=False, timeout=60)

    if not admin.collection_exists(COLLECTION):
        admin.create_collection(
            collection_name=COLLECTION,
            vectors_config=models.VectorParams(size=3, distance=models.Distance.COSINE),
        )

    admin.upsert(
        collection_name=COLLECTION,
        wait=True,
        points=[
            models.PointStruct(id=1, vector=[0.9, 0.1, 0.1], payload={"name": "red"}),
            models.PointStruct(id=2, vector=[0.1, 0.9, 0.1], payload={"name": "green"}),
            models.PointStruct(id=3, vector=[0.1, 0.1, 0.9], payload={"name": "blue"}),
        ],
    )

    response = reader.query_points(
        collection_name=COLLECTION,
        query=[0.8, 0.2, 0.1],
        limit=3,
        with_payload=True,
    )
    for point in response.points:
        print(f"id={point.id} score={point.score:.4f} payload={point.payload}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:  # noqa: BLE001
        print(f"Error: {exc}", file=sys.stderr)
        raise SystemExit(1)
