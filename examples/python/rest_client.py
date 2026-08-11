#!/usr/bin/env python3
"""Small dependency-light Qdrant REST example using the universal Query API."""
from __future__ import annotations

import os
import sys
from typing import Any

import requests

BASE_URL = os.getenv("QDRANT_URL", "http://127.0.0.1:9090").rstrip("/")
ADMIN_KEY = os.getenv("QDRANT_API_KEY", "")
READ_ONLY_KEY = os.getenv("QDRANT_READ_ONLY_API_KEY", "") or ADMIN_KEY
COLLECTION = os.getenv("QDRANT_COLLECTION", "python_rest_demo")


def request(method: str, path: str, *, api_key: str, **kwargs: Any) -> dict[str, Any]:
    if not api_key:
        raise RuntimeError("Set QDRANT_API_KEY before running this example")
    headers = dict(kwargs.pop("headers", {}))
    headers["api-key"] = api_key
    response = requests.request(
        method,
        f"{BASE_URL}{path}",
        headers=headers,
        timeout=60,
        **kwargs,
    )
    response.raise_for_status()
    return response.json()


def ensure_collection() -> None:
    try:
        request("GET", f"/collections/{COLLECTION}", api_key=ADMIN_KEY)
    except requests.HTTPError as exc:
        if exc.response.status_code != 404:
            raise
        request(
            "PUT",
            f"/collections/{COLLECTION}",
            api_key=ADMIN_KEY,
            json={"vectors": {"size": 3, "distance": "Cosine"}},
        )


def main() -> int:
    print(f"[python/rest] Endpoint: {BASE_URL}")
    print(f"[python/rest] Collection: {COLLECTION}")
    ensure_collection()

    request(
        "PUT",
        f"/collections/{COLLECTION}/points?wait=true",
        api_key=ADMIN_KEY,
        json={
            "points": [
                {"id": 1, "vector": [0.9, 0.1, 0.1], "payload": {"name": "red"}},
                {"id": 2, "vector": [0.1, 0.9, 0.1], "payload": {"name": "green"}},
                {"id": 3, "vector": [0.1, 0.1, 0.9], "payload": {"name": "blue"}},
            ]
        },
    )

    result = request(
        "POST",
        f"/collections/{COLLECTION}/points/query",
        api_key=READ_ONLY_KEY,
        json={"query": [0.8, 0.2, 0.1], "limit": 3, "with_payload": True},
    )
    for point in result["result"]["points"]:
        print(f"id={point['id']} score={point['score']:.4f} payload={point.get('payload')}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:  # noqa: BLE001
        print(f"Error: {exc}", file=sys.stderr)
        raise SystemExit(1)
