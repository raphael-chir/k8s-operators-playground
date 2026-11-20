#!/usr/bin/env bash
# CNPG Playground - Scenario 04
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../engine/lib/ui.sh"
source "${SCRIPT_DIR}/../../engine/usecase.sh"


show_instruct() {
  ui_note "
# 04 / Deploy PGD4K Alongside CNPG

Deploy PGD4K alongside CNPG Community + EDB Plugin.

## Architecture
- CNPG: EPAS 18, 3 instances, TDE enabled
- PGD4K: PostgreSQL 17, 3 instances, PGD 6
- TLS certificates managed by cert-manager
- Prometheus monitoring
- No Barman Cloud Plugin for PGD4K

## Objectives
1. Verify both operator stacks
2. Deploy PGD4K TLS certificates
3. Deploy a 3-node PGDGroup
4. Verify PGD replication topology
5. Verify CNPG and PGD4K coexistence

## Expected outcome
Two independent PostgreSQL clusters running
on the same Kubernetes infrastructure.

Barman Cloud integration is excluded from this test.
"
  ui_pause
}

play() {
  ui_info "Select Kubernetes context"
  ui_command "kubectl config use-context ${KUBE_CONTEXT}"
  ui_pause

  ui_info "Verify CNPG and PGD4K operators"
  ui_command "kubectl get deployments -n cnpg-system; kubectl get deployments -n pgd-operator-system"
  ui_pause

  ui_info "Verify existing CNPG cluster"
  ui_command "kubectl get clusters.postgresql.cnpg.io epas-cluster"
  ui_pause

  ui_info "Create TLS Certificate Authorities and Issuers"
  ui_command "kubectl apply -f manifests/pgd-certificates.yaml"
  ui_pause

  ui_info "Wait for TLS Certificate Authorities"
  ui_command "kubectl wait --for=condition=Ready certificate/server-ca certificate/client-ca --timeout=120s"
  ui_pause

  ui_info "Verify TLS certificates and issuers"
  ui_command "kubectl get certificates,issuers"
  ui_pause

  ui_info "Deploy PGDGroup with 3 PostgreSQL instances"
  ui_command "kubectl apply -f manifests/pgd-cluster.yaml"
  ui_pause

  ui_info "Wait for PGDGroup readiness"
  ui_command "kubectl wait --for=condition=Ready pgdgroup/pgd-group --timeout=600s"
  ui_pause

  ui_info "Verify PGDGroup status"
  ui_command "kubectl get pgdgroup pgd-group"
  ui_pause

  ui_info "Verify PG4K PostgreSQL clusters"
  ui_command "kubectl get clusters.postgresql.k8s.enterprisedb.io"
  ui_pause

  ui_info "Explore PGD4K PostgreSQL instances"
  ui_command "kubectl get pods -o wide -l k8s.pgd.enterprisedb.io/group=pgd-group"
  ui_pause

  ui_info "Verify PGD replication topology"
  ui_command "kubectl exec pgd-group-2-1 -c postgres -- pgd --dsn 'host=/controller/run user=postgres dbname=app' group pgd-group show --summary"
  ui_pause

  ui_info "Discover PGD Connection Manager services"
  ui_command "kubectl get svc -o wide"
  ui_pause

  ui_info "Verify PodDisruptionBudgets"
  ui_command "kubectl get pdb"
  ui_pause

  ui_info "Verify PGD Prometheus monitoring"
  ui_command "kubectl get podmonitor pgd-nodes"
  ui_pause

  ui_info "Verify CNPG remains healthy"
  ui_command "kubectl cnpg status epas-cluster"
  ui_pause

  ui_info "Verify CNPG TDE remains enabled"
  ui_command "kubectl exec epas-cluster-1 -c postgres -- psql -U postgres -d postgres -tAc 'SELECT data_encryption_version FROM pg_control_init();'"
  ui_pause

  ui_info "Verify both PostgreSQL clusters"
  ui_command "kubectl get clusters.postgresql.cnpg.io epas-cluster; kubectl get pgdgroup pgd-group"
  ui_pause

  ui_success "PGD4K and CNPG coexistence validated successfully."
}

main() {
  clear
  show_instruct
  play
}

main "$@"
