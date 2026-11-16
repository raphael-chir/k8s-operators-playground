#!/usr/bin/env bash
# CNPG Playground - Scenario 02
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../engine/lib/ui.sh"
source "${SCRIPT_DIR}/../../engine/usecase.sh"

CLUSTER="kind-cnpg-lab-cnpg-edb-plugin-1"
MANIFEST="${SCRIPT_DIR}/manifests/cluster-tde.yaml"

show_instruct() {
  ui_note "
# 02 / Deploy EPAS 18 with TDE

Deploy a 3-instance EPAS 18 cluster using CloudNativePG
and the EDB Plugin.

## Components
- EPAS 18
- Transparent Data Encryption (AES-256)
- Barman Cloud Plugin
- MinIO object storage
- Synchronous replication (ANY 1)
- Prometheus monitoring

## Objectives
1. Create MinIO credentials
2. Deploy TDE Secret and TDE resource
3. Deploy EPAS 18 cluster
4. Verify PostgreSQL instances and replication
5. Verify TDE encryption
6. Verify Barman Cloud integration

## Expected outcome
EPAS 18 is operational with 3 instances,
TDE enabled and WAL archiving configured.
"
  ui_pause
}

play() {
  ui_info "Select Kubernetes context"
  ui_command "kubectl config use-context ${CLUSTER}"
  ui_pause

  ui_info "Create MinIO credentials"
  ui_command "kubectl create secret generic minio-secret --from-literal=MINIO_ACCESS_KEY=admin --from-literal=MINIO_SECRET_KEY=password --dry-run=client -o yaml | kubectl apply -f -"
  ui_pause

  ui_info "Deploy TDE Secret, TDE resource, ObjectStore and EPAS cluster"
  ui_command "kubectl apply -f ${MANIFEST}"
  ui_pause

  ui_info "Verify TransparentDataEncryption resource"
  ui_command "kubectl get tde epas-tde"
  ui_pause

  ui_info "Verify Barman ObjectStore"
  ui_command "kubectl get objectstore minio-storage"
  ui_pause

  ui_info "Wait for EPAS cluster readiness"
  ui_command "kubectl wait --for=jsonpath='{.status.phase}'='Cluster in healthy state' cluster/epas-cluster --timeout=600s"
  ui_pause

  ui_info "Verify EPAS cluster"
  ui_command "kubectl get cluster epas-cluster"
  ui_pause

  ui_info "Verify PostgreSQL pods"
  ui_command "kubectl get pods -l cnpg.io/cluster=epas-cluster -o wide"
  ui_pause

  ui_info "Inspect EPAS cluster status"
  ui_command "kubectl cnpg status epas-cluster"
  ui_pause

  ui_info "Verify TDE encryption"
  ui_command "kubectl exec epas-cluster-1 -c postgres -- psql -U postgres -d postgres -tAc 'SELECT data_encryption_version FROM pg_control_init();'"
  ui_pause

  ui_info "Verify WAL archiving"
  ui_command "kubectl exec epas-cluster-1 -c postgres -- psql -U postgres -d postgres -c 'SELECT archived_count, failed_count, last_archived_wal, last_failed_wal FROM pg_stat_archiver;'"
  ui_pause

  ui_info "Verify Prometheus PodMonitor"
  ui_command "kubectl get podmonitor epas-cluster"
  ui_pause

  ui_success "EPAS 18 deployed with TDE AES-256 and Barman Cloud Plugin."
}

main() {
  clear
  show_instruct
  play
}

main "$@"
