#!/usr/bin/env bash
# Install or reconcile MinIO (S3 API + console) with the "cnpg" bucket.
# Usage: engine/stacks/minio/install.sh <kube-context>
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ../common.sh

CHART_VERSION="5.4.0"
RELEASE="minio"
NAMESPACE="object-storage"
BUCKET="cnpg"

install_minio() {
  log_info "Installing MinIO chart ${CHART_VERSION}"
  log_run helm repo add minio https://charts.min.io/ --force-update
  log_run helm upgrade --install "${RELEASE}" minio/minio \
    --kube-context "${CONTEXT}" --namespace "${NAMESPACE}" --create-namespace \
    --version "${CHART_VERSION}" --values values.yaml \
    --hide-notes --wait --timeout 10m
}

# The chart's post-install job creates the bucket; in filesystem mode it is a directory.
verify_bucket() {
  local i
  for (( i = 1; i <= 20; i++ )); do
    if kc -n "${NAMESPACE}" exec "deploy/${RELEASE}" -- test -d "/export/${BUCKET}" 2>/dev/null; then
      log_success "Bucket ${BUCKET} exists"
      return 0
    fi
    sleep 3
  done
  die "Bucket ${BUCKET} not found in MinIO"
}

use_context "$@"
log_section "Installing MinIO on ${CONTEXT}"
install_minio
log_info "Waiting for MinIO"
log_run kubectl --context "${CONTEXT}" -n "${NAMESPACE}" rollout status "deployment/${RELEASE}" --timeout=300s
verify_bucket
log_success "MinIO ready on ${CONTEXT}"
