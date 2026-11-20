# The NodePorts the shared stacks expose, fixed in their values.yaml (monitoring: Grafana; minio: S3 API and Console).
# The single list the engine and the providers read. A provider must make them reachable from the host (Kind publishes
# them in engine/providers/kind/cluster.yaml; tests/provider.sh keeps the two and the values files in step). Sourced.
GRAFANA_NODE_PORT=30082
MINIO_API_NODE_PORT=30083
MINIO_CONSOLE_NODE_PORT=30084
STACK_NODE_PORTS="${GRAFANA_NODE_PORT} ${MINIO_API_NODE_PORT} ${MINIO_CONSOLE_NODE_PORT}"
