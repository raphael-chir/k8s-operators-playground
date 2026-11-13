#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# CNPG Playground - Distributed Topology - Scenario 01
# Install CloudNativePG Community and Barman Cloud Plugin
# -----------------------------------------------------------------------------

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "${SCRIPT_DIR}/../../engine/lib/ui.sh"
source "${SCRIPT_DIR}/../../engine/usecase.sh"

show_instruct() {
  ui_note "
# 01 / Install CloudNativePG Operators

Install CloudNativePG Community and Barman Cloud Plugin on both Kubernetes
clusters to prepare a distributed PostgreSQL topology.

## Architecture
- Kubernetes Cluster 1: Primary site
- Kubernetes Cluster 2: Disaster Recovery site
- CloudNativePG Community Operator on both clusters
- Barman Cloud Plugin on both clusters

## What you will learn
- Install Kubernetes operators using Helm
- Manage operators across multiple Kubernetes clusters
- Verify operator deployments and CRDs

## Prerequisites
- Two Kind clusters running
- cert-manager installed on both clusters
- Helm CLI available

## Expected outcome
CloudNativePG and Barman Cloud Plugin are operational on both clusters.

No PostgreSQL cluster will be created during this scenario.
"
  ui_pause
}

play() {

  for KUBE_CONTEXT in \
    kind-cnpg-lab-cnpg-distributed-topology-1 \
    kind-cnpg-lab-cnpg-distributed-topology-2
  do

    ui_info "Select Kubernetes context: ${KUBE_CONTEXT}"
    ui_command "kubectl config use-context ${KUBE_CONTEXT}"
    ui_pause

    ui_info "Check Kubernetes nodes"
    ui_command "kubectl get nodes -o wide"
    ui_pause

    ui_info "Check cert-manager"
    ui_command "kubectl get pods -n cert-manager"
    ui_pause

    ui_info "Wait for cert-manager readiness"
    ui_command "kubectl rollout status deployment/cert-manager -n cert-manager --timeout=120s"
    ui_command "kubectl rollout status deployment/cert-manager-webhook -n cert-manager --timeout=120s"
    ui_pause

    ui_info "Add the official CloudNativePG Helm repository"
    ui_command "helm repo add cnpg https://cloudnative-pg.github.io/charts --force-update"
    ui_pause

    ui_info "Update Helm repositories"
    ui_command "helm repo update"
    ui_pause

    ui_info "Install CloudNativePG Operator"
    ui_command "helm upgrade --install cnpg cnpg/cloudnative-pg --version 0.29.1 --namespace cnpg-system --create-namespace --wait --timeout 5m"
    ui_pause

    ui_info "Verify CloudNativePG Operator"
    ui_command "kubectl rollout status deployment/cnpg-cloudnative-pg -n cnpg-system --timeout=120s"
    ui_pause

    ui_info "Install Barman Cloud Plugin"
    ui_command "helm upgrade --install plugin-barman-cloud cnpg/plugin-barman-cloud --version 0.8.1 --namespace cnpg-system --wait --timeout 5m"
    ui_pause

    ui_info "Verify Barman Cloud Plugin"
    ui_command "kubectl rollout status deployment/plugin-barman-cloud -n cnpg-system --timeout=120s"
    ui_pause

    ui_info "Check CloudNativePG CRDs"
    ui_command "kubectl get crds | grep -E 'postgresql.cnpg.io|barmancloud.cnpg.io'"
    ui_pause

    ui_info "Check operator deployments"
    ui_command "kubectl get deployments -n cnpg-system"
    ui_pause

  done

  ui_success "CloudNativePG and Barman Cloud Plugin installed on both clusters."
  ui_success "Next scenario: 02_deploy_primary.sh"
}

main() {
  clear
  show_instruct
  play
}

main "$@"
