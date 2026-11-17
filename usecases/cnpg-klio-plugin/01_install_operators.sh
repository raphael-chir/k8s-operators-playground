#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# CNPG Playground - Scenario 01
# Install CloudNativePG Community and Klio
# -----------------------------------------------------------------------------

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "${SCRIPT_DIR}/../../engine/lib/ui.sh"
source "${SCRIPT_DIR}/../../engine/usecase.sh"

KLIO_VERSION="${KLIO_VERSION:-0.0.21}"

show_instruct() {
  ui_note "
# 01 / Install CloudNativePG and Klio

Deploy CloudNativePG Community and the Klio operator.

## Components
- CloudNativePG Community (Helm chart 0.29.1)
- Klio Operator ${KLIO_VERSION}
- CNPG-I plugin architecture

## Architecture
- Namespace: cnpg-system
- CNPG Operator
- Klio Operator
- Klio CRDs

## Objectives
1. Install CloudNativePG
2. Install Klio using Helm OCI
3. Verify both operators
4. Explore Klio CRDs

## Expected outcome
Both operators running in cnpg-system.

No Klio server or PostgreSQL cluster deployed yet.
"
  ui_pause
}

play() {

  ui_info "Select Kubernetes context"
  ui_command "kubectl config use-context ${KUBE_CONTEXT}"
  ui_pause

  ui_info "Check Kubernetes nodes"
  ui_command "kubectl get nodes"
  ui_pause

  ui_info "Verify cert-manager"
  ui_command "kubectl get pods -n cert-manager"
  ui_pause

  ui_info "Install CloudNativePG Community"
  ui_command "helm repo add cnpg https://cloudnative-pg.github.io/charts --force-update"
  ui_command "helm repo update"
  ui_command "helm upgrade --install cnpg cnpg/cloudnative-pg --version 0.29.1 --namespace cnpg-system --create-namespace"
  ui_pause

  ui_info "Verify CNPG operator"
  ui_command "kubectl rollout status deployment/cnpg-cloudnative-pg -n cnpg-system --timeout=180s"
  ui_pause

  ui_info "Install Klio Operator ${KLIO_VERSION}"
  ui_command "helm upgrade --install klio-operator oci://ghcr.io/cloudnative-pg/klio-operator-chart --version ${KLIO_VERSION} --namespace cnpg-system --set prometheus.enable=false"
  ui_pause

  ui_info "Verify Klio operator"
  ui_command "kubectl get pods -n cnpg-system -l app.kubernetes.io/name=klio"
  ui_pause

  ui_info "Explore Klio CRDs"
  ui_command "kubectl get crds | grep klio.cnpg.io"
  ui_pause

  ui_info "Verify both operators"
  ui_command "kubectl get deployments -n cnpg-system"
  ui_pause

  ui_success "CloudNativePG and Klio installation completed."
}

main() {
  clear
  show_instruct
  play
}

main "$@"
