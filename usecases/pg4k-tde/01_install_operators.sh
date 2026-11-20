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
# 01 / Install PG4K Operator

Install EDB PG4K 1.30.1 and Barman Cloud Plugin 0.8.1.

## Objectives
- Configure EDB registry authentication
- Install PG4K operator
- Install Barman Cloud Plugin
- Configure plugin discovery
- Verify operator and plugin

## Prerequisites
- Kind cluster with MinIO and monitoring
- EDB subscription token configured in .env

## Expected outcome
PG4K and Barman Cloud Plugin are ready.
"
  ui_pause
}

play() {
  ui_info "Switch to the playground Kubernetes context"
  ui_command "kubectl config use-context ${KUBE_CONTEXT}"
  ui_pause

  ui_info "Verify Kubernetes nodes"
  ui_command "kubectl get nodes"
  ui_pause

  ui_info "Create the PG4K operator namespace"
  ui_command "kubectl create namespace postgresql-operator-system --dry-run=client -o yaml | kubectl apply -f -"
  ui_pause

  ui_info "Create the EDB registry pull secret"
  ui_command 'kubectl -n postgresql-operator-system create secret docker-registry edb-pull-secret --docker-server=docker.enterprisedb.com --docker-username=k8s --docker-password="$EDB_SUBSCRIPTION_TOKEN" --dry-run=client -o yaml | kubectl apply -f -'
  ui_pause

  ui_info "Install EDB PG4K 1.30.1"
  ui_command "kubectl apply --server-side -f https://get.enterprisedb.io/pg4k/pg4k-1.30.1.yaml"
  ui_pause

  ui_info "Wait for PG4K operator"
  ui_command "kubectl -n postgresql-operator-system rollout status deployment/postgresql-operator-controller-manager --timeout=600s"
  ui_pause

  ui_info "Add the Helm repository for Barman Cloud Plugin"
  ui_command "helm repo add cnpg https://cloudnative-pg.github.io/charts --force-update"
  ui_pause

  ui_info "Update the Helm repository"
  ui_command "helm repo update cnpg"
  ui_pause

  ui_info "Install Barman Cloud Plugin 0.8.1"
  ui_command "helm upgrade --install plugin-barman-cloud cnpg/plugin-barman-cloud --namespace postgresql-operator-system --version 0.8.1 --set-json 'nodeSelector={\"node-role.kubernetes.io/control-plane\":\"\"}' --set 'tolerations[0].key=node-role.kubernetes.io/control-plane' --set 'tolerations[0].operator=Exists' --set 'tolerations[0].effect=NoSchedule' --wait --timeout 300s"
  ui_pause

  ui_info "Register Barman Cloud Plugin for PG4K discovery"
  ui_command "kubectl -n postgresql-operator-system label svc barman-cloud k8s.enterprisedb.io/pluginName=barman-cloud.cloudnative-pg.io --overwrite"
  ui_pause

  ui_info "Configure Barman Cloud Plugin discovery"
  ui_command 'kubectl -n postgresql-operator-system annotate svc barman-cloud k8s.enterprisedb.io/pluginPort="$(kubectl -n postgresql-operator-system get svc barman-cloud -o jsonpath="{.metadata.annotations.cnpg\.io/pluginPort}")" k8s.enterprisedb.io/pluginClientSecret="$(kubectl -n postgresql-operator-system get svc barman-cloud -o jsonpath="{.metadata.annotations.cnpg\.io/pluginClientSecret}")" k8s.enterprisedb.io/pluginServerSecret="$(kubectl -n postgresql-operator-system get svc barman-cloud -o jsonpath="{.metadata.annotations.cnpg\.io/pluginServerSecret}")" --overwrite'
  ui_pause

  ui_info "Verify operator and plugin pods"
  ui_command "kubectl get pods -n postgresql-operator-system -o wide"
  ui_pause

  ui_info "Verify PG4K and Barman Cloud CRDs"
  ui_command "kubectl get crd clusters.postgresql.k8s.enterprisedb.io objectstores.barmancloud.cnpg.io"
  ui_pause

  ui_success "PG4K and Barman Cloud Plugin installed successfully!"
  ui_info "Next scenario: 02_deploy_cluster.sh"
}

main() {
  clear
  show_instruct
  play
}

main "$@"
