#!/usr/bin/env bash
# Install cert-manager (needed by the Barman Cloud plugin), or keep the one already there.
# Usage: engine/stacks/cert-manager/install.sh <kube-context>
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ../common.sh

CERT_MANAGER_VERSION="v1.20.2"

# An existing cert-manager (Helm release or foreign install) is kept untouched.
install_cert_manager() {
  log_info "cert-manager ${CERT_MANAGER_VERSION}"
  if helm status cert-manager --kube-context "${CONTEXT}" -n cert-manager >/dev/null 2>&1 ||
    kc get crd certificates.cert-manager.io >/dev/null 2>&1; then
    log_info "cert-manager already installed, keeping it"
  else
    log_run helm upgrade --install cert-manager oci://quay.io/jetstack/charts/cert-manager \
      --kube-context "${CONTEXT}" --namespace cert-manager --create-namespace \
      --version "${CERT_MANAGER_VERSION}" --set crds.enabled=true --values values.yaml \
      --hide-notes --wait --timeout 300s
  fi
  log_run kubectl --context "${CONTEXT}" -n cert-manager wait --for=condition=Available deployment --all --timeout=300s
  log_success "cert-manager ready"
}

use_context "$@"
install_cert_manager
