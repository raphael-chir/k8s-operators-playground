#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# CNPG Playground - Scenario 02
# Deploy a PostgreSQL cluster
# -----------------------------------------------------------------------------

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../engine/lib/ui.sh"
source "${SCRIPT_DIR}/../../engine/usecase.sh"

show_instruct() {
  ui_note "
# 02 / Deploy PostgreSQL Cluster

Deploy a highly available PostgreSQL 17.5 cluster using CloudNativePG.

## Architecture
- 3 PostgreSQL instances across 3 Kubernetes workers
- 1 primary and 2 replicas
- Synchronous replication (ANY 1)

## Features
- Automatic failover
- Continuous WAL archiving to MinIO
- Prometheus monitoring

## Prerequisites
- CloudNativePG Community Operator installed
- Barman Cloud Plugin installed
- MinIO and Prometheus available

## Expected outcome
A healthy PostgreSQL cluster with three running instances.
"
  ui_pause
}

play() {

  ui_info "Select the Kubernetes cluster"
  ui_command "kubectl config use-context ${KUBE_CONTEXT}"
  ui_pause

  ui_info "Verify CloudNativePG and Barman Cloud Plugin deployments"
  ui_command "kubectl get deployments -n cnpg-system"
  ui_pause

  ui_info "Create credentials for MinIO object storage"
  ui_command "kubectl create secret generic minio-secret --from-literal=MINIO_ACCESS_KEY=admin --from-literal=MINIO_SECRET_KEY=password --dry-run=client -o yaml | kubectl apply -f -"
  ui_pause

  ui_info "Explore the PostgreSQL Cluster, ObjectStore and PodMonitor manifests"
  ui_command "vim manifests/cluster.yaml"
  ui_pause

  ui_info "Deploy the PostgreSQL cluster"
  ui_command "kubectl apply -f manifests/cluster.yaml"
  ui_pause

  ui_info "Monitor PostgreSQL cluster initialization"
  ui_watch "kubectl cnpg status cnpg-cluster --color always"
  ui_pause

  ui_info "Verify PostgreSQL instances and their roles"
  ui_command "kubectl get pods -l cnpg.io/cluster=cnpg-cluster -L cnpg.io/instanceRole -o wide"
  ui_pause

  ui_info "Verify Prometheus monitoring"
  ui_command "kubectl get podmonitor cnpg-cluster"
  ui_pause

  ui_success "PostgreSQL cluster successfully deployed."
  ui_info "Next scenario: 03_data_workload.sh"
}

main() {
  clear
  show_instruct
  play
}

main "$@"
