#!/usr/bin/env bash
# Read-only: the clusters of one use case, one line each, tab separated:
#   <cluster> <grafana host port> <minio console host port> <kubectl context> <cluster address> <grafana NodePort> <console NodePort>
# (an empty host port = not published; an empty address = the cluster is not reachable from here).
# Everything comes from the provider (provider_list, provider_context, provider_endpoint host-port | cluster-address); the
# NodePorts are the fixed ones of engine/stacks/ports.sh. The address and NodePorts let the Web UI check that a service answers
# without knowing how the provider names or attaches nodes. Used by the Web UI status bar (web/app.py).
set -Eeuo pipefail
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${PROJECT_ROOT}/engine/lib/usecase-manifest.sh"

usecase="${1:-}"
[[ "${usecase}" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] || { echo "invalid use case name" >&2; exit 2; }
[ -n "${PLAYGROUND_PROVIDER:-}" ] || PLAYGROUND_PROVIDER="$(usecase_provider "${usecase}")"   # the use case's provider (default kind)
source "${PROJECT_ROOT}/engine/lib/provider.sh"
source "${PROJECT_ROOT}/engine/stacks/ports.sh"   # GRAFANA_NODE_PORT, MINIO_CONSOLE_NODE_PORT
provider_check_available || exit 2

while IFS= read -r cluster; do
  [ -n "${cluster}" ] || continue
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "${cluster}" "$(provider_endpoint host-port "${cluster}" "${GRAFANA_NODE_PORT}")" \
    "$(provider_endpoint host-port "${cluster}" "${MINIO_CONSOLE_NODE_PORT}")" "$(provider_context "${cluster}")" \
    "$(provider_endpoint cluster-address "${cluster}")" "${GRAFANA_NODE_PORT}" "${MINIO_CONSOLE_NODE_PORT}"
done < <(provider_list "${usecase}")
