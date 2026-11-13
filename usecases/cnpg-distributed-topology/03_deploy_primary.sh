#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# CNPG Playground - Scenario 03
# Deploy Primary PostgreSQL Cluster & Initialize Data
# -----------------------------------------------------------------------------

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../engine/lib/ui.sh"
source "${SCRIPT_DIR}/../../engine/usecase.sh"

KUBE_CONTEXT="kind-cnpg-lab-cnpg-distributed-topology-1"
REPLICA_NODE="cnpg-lab-cnpg-distributed-topology-2-control-plane"

show_instruct() {
  ui_note "
# 03 / Deploy Primary PostgreSQL Cluster & Initialize Data

Deploy a highly available PostgreSQL 18 cluster on Kubernetes Cluster 1.

## Architecture
- 3 PostgreSQL instances across 3 Kubernetes workers
- 1 primary and 2 synchronous replicas (ANY 1)
- Distributed Topology configured for future DR switchover

## Features
- Automatic local failover
- Continuous WAL archiving to local MinIO
- Prometheus monitoring
- External PostgreSQL endpoint (NodePort 30432)

## Data & Workload
- Initialize a pgbench dataset (100,000 accounts)
- Generate a 15-second workload

## Expected outcome
A healthy PostgreSQL cluster populated with data,
ready for Distributed Topology replication.
"
  ui_pause
}

play() {

  ui_info "Select Kubernetes Cluster 1"
  ui_command "kubectl config use-context ${KUBE_CONTEXT}"
  ui_pause

  ui_info "Verify CloudNativePG and Barman Cloud Plugin deployments"
  ui_command "kubectl get deployments -n cnpg-system"
  ui_pause

  ui_info "Create credentials for MinIO object storage"
  ui_command "kubectl create secret generic minio-secret --from-literal=MINIO_ACCESS_KEY=admin --from-literal=MINIO_SECRET_KEY=password --dry-run=client -o yaml | kubectl apply -f -"
  ui_pause

  ui_info "Explore the PostgreSQL Cluster, ObjectStore and PodMonitor manifests"
  ui_command "vim manifests/cluster-primary.yaml"
  ui_pause

  REPLICA_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${REPLICA_NODE}")

  ui_info "Cluster 2 PostgreSQL endpoint: ${REPLICA_IP}:30432"
  ui_info "Inject this IP into the primary manifest at deployment time (source file unchanged)"
  ui_command "sed 's/REPLICA_NODE_IP/${REPLICA_IP}/g' manifests/cluster-primary.yaml | kubectl apply -f -"
  ui_pause

  ui_info "Monitor PostgreSQL cluster initialization"
  ui_watch "kubectl cnpg status cnpg-cluster --color always"
  ui_pause

  ui_info "Verify PostgreSQL instances and their roles"
  ui_command "kubectl get pods -l cnpg.io/cluster=cnpg-cluster -L cnpg.io/instanceRole -o wide"
  ui_pause

  ui_info "Verify external PostgreSQL endpoint"
  ui_command "kubectl get svc cnpg-cluster-external"
  ui_pause

  ui_info "Verify Prometheus monitoring"
  ui_command "kubectl get podmonitor cnpg-cluster"
  ui_pause

  ui_info "Discover PostgreSQL application connection credentials"
  ui_command "kubectl get secret cnpg-cluster-app -o jsonpath='{.data.uri}' | base64 --decode; echo"
  ui_pause

  ui_info "Clean up previous pgbench jobs"
  ui_command "kubectl delete job pgb-init pgb-run --ignore-not-found"
  ui_pause

  ui_info "Initialize the pgbench dataset (100,000 accounts)"
  ui_command "kubectl cnpg pgbench --job-name pgb-init cnpg-cluster -- --initialize"
  ui_pause

  ui_info "Wait for dataset initialization"
  ui_command "kubectl wait --for=condition=complete job/pgb-init --timeout=300s"
  ui_pause

  ui_info "Query PostgreSQL using psql"
  ui_command "kubectl cnpg psql cnpg-cluster -- app -c \"SELECT count(*) FROM pgbench_accounts;\""
  ui_pause

  ui_info "Generate a 15-second workload"
  ui_command "kubectl cnpg pgbench --job-name pgb-run cnpg-cluster -- --time 15 --client 2 --jobs 2"
  ui_pause

  ui_info "Wait for workload completion"
  ui_command "kubectl wait --for=condition=complete job/pgb-run --timeout=120s"
  ui_pause

  ui_info "Review pgbench results"
  ui_command "kubectl logs job/pgb-run"
  ui_pause

  ui_info "Verify PostgreSQL cluster status after workload"
  ui_watch "kubectl cnpg status cnpg-cluster --color always"
  ui_pause

  ui_success "Primary PostgreSQL cluster deployed and dataset initialized."
  ui_info "Next scenario: 04_deploy_replica.sh"
}

main() {
  clear
  show_instruct
  play
}

main "$@"
