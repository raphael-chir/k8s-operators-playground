#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# CNPG Playground - Scenario 01
# Install CloudNativePG Community and Barman Cloud Plugin
# -----------------------------------------------------------------------------

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "${SCRIPT_DIR}/../../engine/lib/ui.sh"
source "${SCRIPT_DIR}/../../engine/usecase.sh"

show_instruct() {
  ui_note "
# 01 / Install CloudNativePG Operators

Deploy the CloudNativePG ecosystem on Kubernetes using official Helm charts.

## Components
- CloudNativePG Community Operator
- Barman Cloud Plugin

## What you will learn
- Install Kubernetes operators using Helm
- Verify operator deployments and readiness
- Explore CloudNativePG Custom Resource Definitions (CRDs)
- Validate the Barman Cloud Plugin installation

## Prerequisites
- Kubernetes cluster running
- cert-manager installed and ready
- Helm CLI available

## Expected outcome
Both operators are deployed and operational in the cnpg-system namespace.

No PostgreSQL cluster will be created during this scenario.
"
  ui_pause
}

play() {

  ui_info "Select the Kubernetes context"
  ui_command "kubectl config use-context ${KUBE_CONTEXT}"
  ui_pause

  ui_info "Check Kubernetes nodes"
  ui_command "kubectl get nodes -o wide"
  ui_pause

  ui_info "The Barman Cloud Plugin requires cert-manager for TLS certificates."
  ui_command "kubectl get pods -n cert-manager"
  ui_pause

  ui_info "Wait for cert-manager to be ready"
  ui_command "kubectl rollout status deployment/cert-manager -n cert-manager --timeout=120s"
  ui_command "kubectl rollout status deployment/cert-manager-webhook -n cert-manager --timeout=120s"
  ui_pause

  ui_info "Add the official CloudNativePG Helm repository"
  ui_command "helm repo add cnpg https://cloudnative-pg.github.io/charts --force-update"
  ui_pause

  ui_info "Update Helm repositories"
  ui_command "helm repo update"
  ui_pause

  ui_info "Display available CloudNativePG charts"
  ui_command "helm search repo cnpg"
  ui_pause

  ui_info "Install the CloudNativePG operator using Helm chart 0.29.1"
  ui_command "helm upgrade --install cnpg cnpg/cloudnative-pg --version 0.29.1 --namespace cnpg-system --create-namespace --wait --timeout 5m"
  ui_pause

  ui_info "Verify the operator deployment"
  ui_command "kubectl rollout status deployment/cnpg-cloudnative-pg -n cnpg-system --timeout=120s"
  ui_pause

  ui_info "Check installed CloudNativePG CRDs"
  ui_command "kubectl get crds | grep postgresql.cnpg.io"
  ui_pause

  ui_info "Install the Barman Cloud Plugin using Helm chart 0.8.1"
  ui_command "helm upgrade --install plugin-barman-cloud cnpg/plugin-barman-cloud --version 0.8.1 --namespace cnpg-system --wait --timeout 5m"
  ui_pause

  ui_info "Verify the plugin deployment"
  ui_command "kubectl rollout status deployment/plugin-barman-cloud -n cnpg-system --timeout=120s"
  ui_pause

  ui_info "List installed Helm releases"
  ui_command "helm list -n cnpg-system"
  ui_pause

  ui_info "Check operator and plugin pods"
  ui_command "kubectl get pods -n cnpg-system -o wide"
  ui_pause

  ui_info "Check CNPG operator and plugin deployments"
  ui_command "kubectl get deployments -n cnpg-system"

  ui_success "CloudNativePG Community and Barman Cloud Plugin are installed."
  ui_success "Next scenario: 02_deploy_cluster.sh"
}

main() {
  clear
  show_instruct
  play
}

main "$@"
