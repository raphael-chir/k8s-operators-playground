#!/usr/bin/env bash
# Read-only: the Kind clusters of one use case and the host ports Docker published for their services,
# as "<cluster><TAB><grafana host port><TAB><minio console host port>" (empty port = not mapped).
# Cluster ownership and port lookup are the existing helpers (usecase_clusters, host_port); the container
# ports are the fixed NodePorts of platform/monitoring/values.yaml (Grafana) and
# platform/object-storage/values.yaml (MinIO console). Used by the Web UI status bar (web/app.py).
set -Eeuo pipefail
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${PROJECT_ROOT}/engine/infrastructure/kind/common.sh"

GRAFANA_NODE_PORT=30082
MINIO_CONSOLE_NODE_PORT=30084

usecase="${1:-}"
[[ "${usecase}" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] || { echo "invalid use case name" >&2; exit 2; }
docker info >/dev/null 2>&1 || { echo "Docker Engine unreachable" >&2; exit 2; }
kind get clusters >/dev/null 2>&1 || { echo "kind could not list clusters" >&2; exit 2; }

while IFS= read -r cluster; do
  [ -n "${cluster}" ] || continue
  printf '%s\t%s\t%s\n' "${cluster}" "$(host_port "${cluster}" "${GRAFANA_NODE_PORT}")" \
    "$(host_port "${cluster}" "${MINIO_CONSOLE_NODE_PORT}")"
done < <(usecase_clusters "${usecase}")
