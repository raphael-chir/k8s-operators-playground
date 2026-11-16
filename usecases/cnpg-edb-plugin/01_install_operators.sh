#!/usr/bin/env bash
# CNPG Playground - Scenario 01
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../engine/lib/ui.sh"
source "${SCRIPT_DIR}/../../engine/usecase.sh"
source "${SCRIPT_DIR}/../../.env"

CLUSTER="kind-cnpg-lab-cnpg-edb-plugin-1"

export EDB_SUBSCRIPTION_TOKEN
: "${EDB_SUBSCRIPTION_TOKEN:?Missing EDB_SUBSCRIPTION_TOKEN in .env}"

show_instruct() {
  ui_note "
# 01 / Install CNPG and EDB Plugin

Install the operators and plugins required to run EPAS 18
with CloudNativePG.

## Components
- CloudNativePG Community 1.31+
- cert-manager
- Barman Cloud Plugin
- EDB Postgres AI Plugin 0.0.9

## Objectives
1. Install CloudNativePG
2. Install Barman Cloud Plugin
3. Configure EDB registry authentication
4. Install EDB Plugin
5. Verify installation

## Expected outcome
All components are operational in cnpg-system.

No PostgreSQL cluster is created.
"
  ui_pause
}

play() {

  ui_info "Select Kubernetes context"
  ui_command "kubectl config use-context ${CLUSTER}"
  ui_pause

  ui_info "Verify Kubernetes nodes"
  ui_command "kubectl get nodes"
  ui_pause

  ui_info "Verify cert-manager"
  ui_command "kubectl get pods -n cert-manager"
  ui_pause

  ui_info "Add CloudNativePG Helm repository"
  ui_command "helm repo add cnpg https://cloudnative-pg.github.io/charts --force-update"
  ui_pause

  ui_info "Update Helm repository"
  ui_command "helm repo update cnpg"
  ui_pause

  ui_info "Install CloudNativePG operator"
  ui_command "helm upgrade --install cnpg cnpg/cloudnative-pg --namespace cnpg-system --create-namespace --wait --timeout 5m"
  ui_pause

  ui_info "Verify CloudNativePG version"
  ui_command "kubectl get deployment -n cnpg-system cnpg-cloudnative-pg -o jsonpath='{.spec.template.spec.containers[0].image}'; echo"
  ui_pause

  ui_info "Install Barman Cloud Plugin"
  ui_command "helm upgrade --install plugin-barman-cloud cnpg/plugin-barman-cloud --namespace cnpg-system --wait --timeout 5m"
  ui_pause

  ui_info "Create EDB registry pull secret"
  ui_command 'kubectl -n cnpg-system create secret docker-registry cnpg-pull-secret --docker-server=docker.enterprisedb.com --docker-username=k8s --docker-password="$EDB_SUBSCRIPTION_TOKEN" --dry-run=client -o yaml | kubectl apply -f -'
  ui_pause

  ui_info "Authenticate Helm to EDB OCI registry"
  ui_command 'echo "$EDB_SUBSCRIPTION_TOKEN" | helm registry login helm.oci.cloudsmith.io -u enterprisedb/k8s --password-stdin'
  ui_pause

  ui_info "Install EDB Plugin 0.0.9"
  ui_command "helm upgrade --install edb-plugin-for-cnpg oci://helm.oci.cloudsmith.io/enterprisedb/k8s/edb-plugin-for-cnpg-chart --namespace cnpg-system --version 0.0.9 --wait --timeout 5m"
  ui_pause

  ui_info "Verify EDB Plugin deployment"
  ui_command "kubectl rollout status deployment/edb-plugin-for-cnpg -n cnpg-system --timeout=120s"
  ui_pause

  ui_info "Inspect installed CRDs"
  ui_command "kubectl get crds | grep -Ei 'edb|cnpg|barman'"
  ui_pause

  ui_info "List installed Helm releases"
  ui_command "helm list -n cnpg-system"
  ui_pause

  ui_info "Verify operator and plugin pods"
  ui_command "kubectl get pods -n cnpg-system -o wide"
  ui_pause

  ui_success "CloudNativePG, Barman Cloud and EDB Plugin installed successfully."
}

main() {
  clear
  show_instruct
  play
}

main "$@"
