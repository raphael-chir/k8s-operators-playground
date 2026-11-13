#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../engine/lib/ui.sh"
source "${SCRIPT_DIR}/../../engine/usecase.sh"
source "${SCRIPT_DIR}/../../.env"

show_instruct() {
  ui_note "
# 02 / Deploy Postgres Extended with and without TDE

Deploy two EDB Postgres Extended 18 clusters to compare
encrypted and unencrypted PostgreSQL data at rest.

## Objectives
- Deploy Postgres Extended 18 without TDE (pge)
- Deploy Postgres Extended 18 with AES-256 TDE (pge-tde)
- Configure Barman Cloud Plugin with MinIO
- Verify both clusters are ready

## Prerequisites
- PG4K Operator and Barman Cloud Plugin installed
- EDB registry pull secret available
- MinIO available
- manifests/cluster.yaml configured
- manifests/cluster-no-tde.yaml configured

## Expected outcome
Two PostgreSQL clusters running with identical configurations,
except for Transparent Data Encryption.
"
  ui_pause
}

play() {
  ui_info "Switch to the playground Kubernetes context"
  ui_command "kubectl config use-context ${KUBE_CONTEXT}"
  ui_pause

  ui_info "Create credentials for MinIO object storage"
  ui_command "kubectl create secret generic minio-secret --from-literal=MINIO_ACCESS_KEY=admin --from-literal=MINIO_SECRET_KEY=password --dry-run=client -o yaml | kubectl apply -f -"
  ui_pause

  ui_info "Deploy Postgres Extended 18 without TDE"
  ui_command "kubectl apply -f ${SCRIPT_DIR}/manifests/cluster.yaml"
  ui_pause

  ui_info "Deploy Postgres Extended 18 with TDE"
  ui_command "kubectl apply -f ${SCRIPT_DIR}/manifests/cluster-tde.yaml"
  ui_pause

  ui_info "Wait for PostgreSQL clusters readiness"
  ui_command "kubectl wait --for=condition=Ready cluster/pge --timeout=600s"
  ui_command "kubectl wait --for=condition=Ready cluster/pge-tde --timeout=600s"
  ui_pause

  ui_info "Verify PostgreSQL clusters"
  ui_command "kubectl get clusters.postgresql.k8s.enterprisedb.io"
  ui_pause

  ui_info "Verify PostgreSQL pods"
  ui_command "kubectl get pods -l k8s.enterprisedb.io/cluster=pge -o wide"
  ui_command "kubectl get pods -l k8s.enterprisedb.io/cluster=pge-tde -o wide"
  ui_pause

  ui_info "Verify TDE configuration"
  ui_command "kubectl get cluster pge-tde -o jsonpath='{.spec.postgresql.epas.tde}'"
  ui_pause

  ui_info "Verify Barman Cloud ObjectStores"
  ui_command "kubectl get objectstores"
  ui_pause

  ui_success "Both PostgreSQL clusters are ready for TDE comparison"
}

main() {
  clear
  show_instruct
  play
}

main "$@"
