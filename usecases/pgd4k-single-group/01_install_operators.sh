#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../engine/lib/ui.sh"
source "${SCRIPT_DIR}/../../engine/usecase.sh"
source "${SCRIPT_DIR}/../../.env"
export EDB_SUBSCRIPTION_TOKEN
: "${EDB_SUBSCRIPTION_TOKEN:?Missing EDB_SUBSCRIPTION_TOKEN in .env}"

show_instruct() {
  ui_note "
# 01 / Install PGD4K Operators

Install EDB PGD4K 2.2.0 and its dependencies.

## Objectives
- Configure EDB registry authentication
- Install PGD4K and PG4K operators
- Install Barman Cloud Plugin 0.8.1
- Configure plugin discovery for PG4K
- Verify operators and CRDs

## Prerequisites
- Kind cluster with cert-manager and monitoring
- EDB subscription token configured in .env

## Expected outcome
PGD4K, PG4K and Barman Cloud Plugin are ready.
"
  ui_pause
}

play() {
  ui_info "Switch to the playground Kubernetes context"
  ui_command "kubectl config use-context ${KUBE_CONTEXT}"
  ui_pause

  ui_info "Verify Kubernetes nodes"
  ui_command "kubectl get nodes -L playground.edb.io/role"
  ui_pause

  ui_info "Create the PGD4K operator namespace"
  ui_command "kubectl create namespace pgd-operator-system --dry-run=client -o yaml | kubectl apply -f -"
  ui_pause

  ui_info "Create the EDB registry pull secret"
  ui_command 'kubectl -n pgd-operator-system create secret docker-registry edb-pull-secret --docker-server=docker.enterprisedb.com --docker-username=k8s --docker-password="$EDB_SUBSCRIPTION_TOKEN" --dry-run=client -o yaml | kubectl apply -f -'
  ui_pause

  ui_info "Install EDB PGD4K 2.2.0 and PG4K operators"
  ui_command "kubectl apply --server-side --force-conflicts -f https://get.enterprisedb.io/pg4k-pgd/pg4k-pgd-2.2.0.yaml"
  ui_pause

  ui_info "PGD4K Operator: manages distributed PostgreSQL groups, replication, consensus and high availability"
  ui_command "kubectl -n pgd-operator-system rollout status deployment/pgd-operator-controller-manager --timeout=600s"
  ui_pause

  ui_info "PG4K Operator: manages PostgreSQL instances, storage, lifecycle and Kubernetes integration"
  ui_command "kubectl -n pgd-operator-system rollout status deployment/postgresql-operator-controller-manager --timeout=600s"
  ui_pause

  ui_info "Add the CloudNativePG Helm repository"
  ui_command "helm repo add cnpg https://cloudnative-pg.github.io/charts --force-update"
  ui_pause

  ui_info "Update the CloudNativePG Helm repository"
  ui_command "helm repo update cnpg"
  ui_pause

  ui_info "Install Barman Cloud Plugin 0.8.1 on the platform node"
  ui_command 'helm upgrade --install plugin-barman-cloud cnpg/plugin-barman-cloud --namespace pgd-operator-system --version 0.8.1 --set nodeSelector.playground\\.edb\\.io/role=platform --set tolerations[0].key=node-role.kubernetes.io/control-plane --set tolerations[0].operator=Exists --set tolerations[0].effect=NoSchedule --wait --timeout 300s'
  ui_pause

  ui_info "Read Barman Cloud Plugin discovery annotations"
  port="$(kubectl -n pgd-operator-system get svc barman-cloud -o jsonpath='{.metadata.annotations.cnpg\.io/pluginPort}')"
  client="$(kubectl -n pgd-operator-system get svc barman-cloud -o jsonpath='{.metadata.annotations.cnpg\.io/pluginClientSecret}')"
  server="$(kubectl -n pgd-operator-system get svc barman-cloud -o jsonpath='{.metadata.annotations.cnpg\.io/pluginServerSecret}')"

  [[ -n "${port}" && -n "${client}" && -n "${server}" ]] || {
    ui_error "Barman Cloud Plugin discovery annotations missing"
    exit 1
  }

  ui_info "Register Barman Cloud Plugin for PG4K discovery"
  ui_command "kubectl -n pgd-operator-system label svc barman-cloud k8s.enterprisedb.io/pluginName=barman-cloud.cloudnative-pg.io --overwrite"
  ui_pause

  ui_info "Configure Barman Cloud Plugin discovery annotations"
  ui_command "kubectl -n pgd-operator-system annotate svc barman-cloud k8s.enterprisedb.io/pluginPort=${port} k8s.enterprisedb.io/pluginClientSecret=${client} k8s.enterprisedb.io/pluginServerSecret=${server} --overwrite"
  ui_pause

  ui_info "Verify operator and plugin pods"
  ui_command "kubectl get pods -n pgd-operator-system -o wide"
  ui_pause

  ui_info "Verify PGD4K, PG4K and Barman Cloud CRDs"
  ui_command "kubectl get crd pgdgroups.pgd.k8s.enterprisedb.io clusters.postgresql.k8s.enterprisedb.io objectstores.barmancloud.cnpg.io"
  ui_pause

  ui_info "Verify the EDB registry pull secret"
  ui_command "kubectl get secret edb-pull-secret -n pgd-operator-system"
  ui_pause

  ui_success "PGD4K, PG4K and Barman Cloud Plugin installed successfully!"
  ui_info "Next scenario: 02_deploy_cluster.sh"
}

main() {
  clear
  show_instruct
  play
}

main "$@"
