#!/usr/bin/env bash
# CNPG Playground - Scenario 03
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../engine/lib/ui.sh"
source "${SCRIPT_DIR}/../../engine/usecase.sh"
source "${SCRIPT_DIR}/../../.env"


export EDB_SUBSCRIPTION_TOKEN
: "${EDB_SUBSCRIPTION_TOKEN:?Missing EDB_SUBSCRIPTION_TOKEN in .env}"

show_instruct() {
  ui_note "
# 03 / Install PGD4K Operators

Install PGD4K 2.2.0 alongside CNPG Community
and the EDB Plugin.

## Architecture
- CNPG Community + EDB Plugin in cnpg-system
- PGD4K + PG4K operators in pgd-operator-system
- Independent PostgreSQL CRDs
- Existing Barman Cloud Plugin remains unchanged

## Objectives
1. Verify existing CNPG components
2. Configure EDB registry authentication
3. Install PGD4K and PG4K operators
4. Verify CRD isolation
5. Verify operator coexistence

## Expected outcome
Both operator stacks are running independently.
The existing EPAS cluster remains healthy.
No PGDGroup is created.
"
  ui_pause
}

play() {
  ui_info "Select Kubernetes context"
  ui_command "kubectl config use-context ${KUBE_CONTEXT}"
  ui_pause

  ui_info "Verify existing CNPG operators"
  ui_command "kubectl get deployments -n cnpg-system"
  ui_pause

  ui_info "Verify existing EPAS cluster"
  ui_command "kubectl get clusters.postgresql.cnpg.io epas-cluster"
  ui_pause

  ui_info "Create PGD4K operator namespace"
  ui_command "kubectl create namespace pgd-operator-system --dry-run=client -o yaml | kubectl apply -f -"
  ui_pause

  ui_info "Create EDB registry pull secret"
  ui_command 'kubectl -n pgd-operator-system create secret docker-registry edb-pull-secret --docker-server=docker.enterprisedb.com --docker-username=k8s --docker-password="$EDB_SUBSCRIPTION_TOKEN" --dry-run=client -o yaml | kubectl apply -f -'
  ui_pause

  ui_info "Install PGD4K 2.2.0 and PG4K operators"
  ui_command "kubectl apply --server-side --force-conflicts -f https://get.enterprisedb.io/pg4k-pgd/pg4k-pgd-2.2.0.yaml"
  ui_pause

  ui_info "Wait for PGD4K operator"
  ui_command "kubectl -n pgd-operator-system rollout status deployment/pgd-operator-controller-manager --timeout=600s"
  ui_pause

  ui_info "Wait for PG4K operator"
  ui_command "kubectl -n pgd-operator-system rollout status deployment/postgresql-operator-controller-manager --timeout=600s"
  ui_pause

  ui_info "Verify PGD4K and PG4K CRDs"
  ui_command "kubectl get crd pgdgroups.pgd.k8s.enterprisedb.io clusters.postgresql.k8s.enterprisedb.io"
  ui_pause

  ui_info "Verify CNPG Community CRD remains available"
  ui_command "kubectl get crd clusters.postgresql.cnpg.io"
  ui_pause

  ui_info "Verify all PostgreSQL operators"
  ui_command "kubectl get deployments -n cnpg-system; kubectl get deployments -n pgd-operator-system"
  ui_pause

  ui_info "Verify operator pods"
  ui_command "kubectl get pods -n cnpg-system; kubectl get pods -n pgd-operator-system"
  ui_pause

  ui_info "Verify EDB registry pull secret"
  ui_command "kubectl get secret edb-pull-secret -n pgd-operator-system"
  ui_pause

  ui_info "Verify existing EPAS cluster remains healthy"
  ui_command "kubectl cnpg status epas-cluster"
  ui_pause

  ui_info "Verify existing TDE remains enabled"
  ui_command "kubectl exec epas-cluster-1 -c postgres -- psql -U postgres -d postgres -tAc 'SELECT data_encryption_version FROM pg_control_init();'"
  ui_pause

  ui_success "PGD4K and PG4K operators installed alongside CNPG Community."
  ui_info "Next scenario: 04_deploy_pgd4k.sh"
}

main() {
  clear
  show_instruct
  play
}

main "$@"
