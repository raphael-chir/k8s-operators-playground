#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../engine/lib/ui.sh"
source "${SCRIPT_DIR}/../../engine/usecase.sh"

show_instruct() {
  ui_note "
# 03 / Data & Workload

Explore PGD connectivity, logical replication and PostgreSQL workloads.

## Architecture
- 3 PostgreSQL instances managed by PGD4K
- PGD Connection Manager for application connections
- 1 temporary PostgreSQL client running pgbench

## Objectives
- Identify the PGD Write Leader
- Discover application connection services
- Initialize the standard pgbench dataset
- Generate a PostgreSQL workload
- Verify data replication across PGD instances

## Expected outcome
A client application connects through PGD Connection Manager,
executes transactions and verifies data across the PGD cluster.
"
  ui_pause
}

play() {
  ui_info "Switch to the playground Kubernetes context"
  ui_command "kubectl config use-context ${KUBE_CONTEXT}"
  ui_pause

  ui_info "PGD uses a Write Leader to coordinate application writes. Identify the current Write Leader and explore the distributed group topology."
  ui_command "kubectl exec pgd-group-1-1 -c postgres -- pgd --dsn 'host=/controller/run user=postgres dbname=app' group pgd-group show --summary"
  ui_pause

  ui_info "PGD Connection Manager provides stable Kubernetes endpoints for applications. The read-write proxy routes writes to the appropriate PGD node, independently of the current Write Leader."
  ui_command "kubectl get svc pgd-group-proxy pgd-group-proxy-r"
  ui_pause

  ui_info "Applications authenticate using PostgreSQL credentials stored in a Kubernetes Secret. We will use the credentials generated for the application database."
  ui_command "kubectl get secret pgd-group-app"
  ui_pause

  ui_info "Deploy a temporary PostgreSQL client outside the PGDGroup. This simulates a real application connecting over the network through PGD Connection Manager, rather than directly to a PostgreSQL instance."
  ui_command "kubectl run pgd-client --image=postgres:17 --restart=Never --env=PGHOST=pgd-group-proxy --env=PGUSER=app --env=PGDATABASE=app --env=PGPASSWORD=\"\$(kubectl get secret pgd-group-app -o jsonpath='{.data.password}' | base64 -d)\" --command -- sleep 3600"
  ui_pause

  ui_info "Wait until the independent PostgreSQL client is running and ready to execute SQL commands."
  ui_command "kubectl wait --for=condition=Ready pod/pgd-client --timeout=120s"
  ui_pause

  ui_info "Initialize the standard pgbench dataset through PGD Connection Manager. pgbench creates its own benchmark tables and populates them with sample data. No custom application tables are required."
  ui_command "kubectl exec pgd-client -- pgbench -i -s 1"
  ui_pause

  ui_info "Generate a 15-second transactional workload through the read-write proxy using two concurrent clients. pgbench reports throughput (TPS) and transaction latency."
  ui_command "kubectl exec pgd-client -- pgbench -T 15 -c 2 -j 2"
  ui_pause

  ui_info "Inspect the benchmark dataset through PGD Connection Manager. Scale factor 1 creates approximately 100,000 accounts."
  ui_command "kubectl exec pgd-client -- psql -c 'SELECT count(*) FROM pgbench_accounts;'"
  ui_pause

  ui_info "Query the first PostgreSQL instance directly. This bypasses Connection Manager and lets us inspect the data stored on this PGD node."
  ui_command "kubectl exec pgd-group-1-1 -c postgres -- psql -U postgres -d app -c 'SELECT count(*) FROM pgbench_accounts;'"
  ui_pause

  ui_info "Query the second PostgreSQL instance to verify that the benchmark data is available on another PGD node."
  ui_command "kubectl exec pgd-group-2-1 -c postgres -- psql -U postgres -d app -c 'SELECT count(*) FROM pgbench_accounts;'"
  ui_pause

  ui_info "Query the third PostgreSQL instance to complete the data replication verification across the distributed group."
  ui_command "kubectl exec pgd-group-3-1 -c postgres -- psql -U postgres -d app -c 'SELECT count(*) FROM pgbench_accounts;'"
  ui_pause

  ui_info "Inspect the PGD group after the workload to verify its operational status and current Write Leader."
  ui_command "kubectl exec pgd-group-1-1 -c postgres -- pgd --dsn 'host=/controller/run user=postgres dbname=app' group pgd-group show --summary"
  ui_pause

  ui_info "Remove the temporary PostgreSQL client. The benchmark data remains stored in the PGD cluster for subsequent scenarios."
  ui_command "kubectl delete pod pgd-client --ignore-not-found"
  ui_pause

  ui_success "PGD connectivity, replication and workload exploration completed!"
  ui_info "Next scenario: 04_backup_restore.sh"
}

main() {
  clear
  show_instruct
  play
}

main "$@"
