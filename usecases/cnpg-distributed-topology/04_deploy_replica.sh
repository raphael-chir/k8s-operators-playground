#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# CNPG Playground - Scenario 04
# Deploy Replica Cluster
# -----------------------------------------------------------------------------

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../engine/lib/ui.sh"
source "${SCRIPT_DIR}/../../engine/usecase.sh"

PRIMARY_CONTEXT="kind-cnpg-lab-cnpg-distributed-topology-1"
REPLICA_CONTEXT="kind-cnpg-lab-cnpg-distributed-topology-2"
PRIMARY_NODE="cnpg-lab-cnpg-distributed-topology-1-control-plane"

show_instruct() {
  ui_note "
# 04 / Deploy Replica Cluster

Deploy a PostgreSQL 18 replica cluster on Kubernetes Cluster 2.

## Architecture
- Cluster 1: Primary PostgreSQL cluster (3 instances)
- Cluster 2: Replica PostgreSQL cluster (3 instances)
- Initial synchronization using pg_basebackup
- Continuous WAL streaming replication

## Prerequisites
- Cluster 1 running with pgbench data
- CloudNativePG and Barman Cloud Plugin installed on Cluster 2
- MinIO available on Cluster 2

## Expected outcome
Two PostgreSQL clusters with synchronized data.
"
  ui_pause
}

play() {

  ui_info "Select Kubernetes Cluster 1"
  ui_command "kubectl config use-context ${PRIMARY_CONTEXT}"
  ui_pause

  ui_info "Verify primary PostgreSQL cluster"
  ui_command "kubectl cnpg status cnpg-cluster --color always"
  ui_pause

  ui_info "Verify PostgreSQL external endpoint"
  ui_command "kubectl get svc cnpg-cluster-external"
  ui_pause

  ui_info "Export replication TLS secrets from Cluster 1"
  TLS_SECRETS=$(kubectl get secret cnpg-cluster-replication cnpg-cluster-ca -o json | jq '{apiVersion:"v1",kind:"List",items:[.items[] | {apiVersion:"v1",kind:"Secret",metadata:{name:.metadata.name},type:.type,data:.data}]}')
  ui_command "echo \"\$TLS_SECRETS\" | jq '{kind, secrets: [.items[].metadata.name]}'"
  ui_pause

  ui_info "Import replication TLS secrets into Cluster 2"
  echo "$TLS_SECRETS" | kubectl --context "${REPLICA_CONTEXT}" apply -f -
  ui_pause

  ui_info "Select Kubernetes Cluster 2"
  ui_command "kubectl config use-context ${REPLICA_CONTEXT}"
  ui_pause

  ui_info "Verify CloudNativePG and Barman Cloud Plugin deployments"
  ui_command "kubectl get deployments -n cnpg-system"
  ui_pause

  ui_info "Create credentials for MinIO object storage"
  ui_command "kubectl create secret generic minio-secret --from-literal=MINIO_ACCESS_KEY=admin --from-literal=MINIO_SECRET_KEY=password --dry-run=client -o yaml | kubectl apply -f -"
  ui_pause

  PRIMARY_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${PRIMARY_NODE}")

  ui_info "Cluster 1 PostgreSQL endpoint: ${PRIMARY_IP}:30432"
  ui_info "Inject this IP into the replica manifest at deployment time (source file unchanged)"
  ui_command "sed 's/PRIMARY_NODE_IP/${PRIMARY_IP}/g' manifests/cluster-replica.yaml | kubectl apply -f -"
  ui_pause

  ui_info "Monitor replica cluster initialization"
  ui_watch "kubectl cnpg status cnpg-cluster --color always"
  ui_pause

  ui_info "Verify PostgreSQL instances and their roles"
  ui_command "kubectl get pods -l cnpg.io/cluster=cnpg-cluster -L cnpg.io/instanceRole -o wide"
  ui_pause

  ui_info "Verify replicated pgbench data"
  ui_command "kubectl cnpg psql cnpg-cluster -- app -c \"SELECT count(*) FROM pgbench_accounts;\""
  ui_pause

  ui_success "Replica PostgreSQL cluster deployed."
  ui_info "Next scenario: 05_replication_validation.sh"
}

main() {
  clear
  show_instruct
  play
}

main "$@"
