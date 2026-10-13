
import requests
from datetime import datetime, timedelta, timezone

PROMETHEUS_URL = "http://localhost:9090"
LOKI_URL = "http://localhost:3100"


def query_prometheus(query):
    response = requests.get(
        f"{PROMETHEUS_URL}/api/v1/query",
        params={"query": query},
        timeout=15
    )
    response.raise_for_status()
    data = response.json()

    if data["status"] != "success":
        raise RuntimeError("Prometheus query failed")

    return data["data"]["result"]


def query_loki(query, limit=20):
    end = datetime.now(timezone.utc)
    start = end - timedelta(minutes=30)

    response = requests.get(
        f"{LOKI_URL}/loki/api/v1/query_range",
        params={
            "query": query,
            "start": int(start.timestamp() * 1e9),
            "end": int(end.timestamp() * 1e9),
            "limit": limit,
            "direction": "backward"
        },
        timeout=15
    )
    response.raise_for_status()
    data = response.json()

    if data["status"] != "success":
        raise RuntimeError("Loki query failed")

    return data["data"]["result"]


if __name__ == "__main__":
    print("=== Kubernetes Pod Status ===")
    metrics = query_prometheus(
        "kube_pod_status_phase{phase='Running'}"
    )
    print(metrics[:5])

    print("\n=== Recent Kubernetes Logs ===")
    logs = query_loki('{namespace="monitoring"}')
    print(logs[:2])
