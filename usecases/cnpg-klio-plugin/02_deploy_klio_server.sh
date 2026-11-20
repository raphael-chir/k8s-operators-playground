#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../engine/lib/ui.sh"
source "${SCRIPT_DIR}/../../engine/usecase.sh"


show_instruct() {
  ui_note "
# 02 / Deploy Klio Server

## Architecture
- Tier 1: Local PVC (30Gi)
- Tier 2: MinIO S3 (bucket cnpg)
- Mutual TLS with cert-manager
- Age encryption

## Objectives
1. Configure TLS
2. Configure MinIO credentials
3. Generate Age encryption keys
4. Deploy Klio Server
5. Verify deployment
"
  ui_pause
}

play() {
  ui_info "Select Kubernetes context"
  ui_command "kubectl config use-context ${KUBE_CONTEXT}"
  ui_pause

  ui_info "Check Klio CRDs"
  ui_command "kubectl get crd | grep klio.cnpg.io"
  ui_pause

  ui_info "Explore TLS certificates"
  ui_command "vim manifests/klio-certificates.yaml"
  ui_pause

  ui_info "Deploy TLS certificates"
  ui_command "kubectl apply -f manifests/klio-certificates.yaml"
  ui_pause

  ui_info "Wait for certificates"
  ui_command "kubectl wait --for=condition=Ready certificate/klio-ca certificate/klio-server-tls certificate/klio-client-tls --timeout=120s"
  ui_pause

  ui_info "Verify certificates"
  ui_command "kubectl get certificates"
  ui_pause

  ui_info "Create client CA secret"
  ui_command "kubectl create secret generic klio-client-ca --from-literal=ca.crt=\"\$(kubectl get secret klio-ca -o jsonpath='{.data.tls\.crt}' | base64 -d)\" --dry-run=client -o yaml | kubectl apply -f -"
  ui_pause

  ui_info "Create MinIO credentials"
  ui_command "kubectl create secret generic minio-secret --from-literal=MINIO_ACCESS_KEY=admin --from-literal=MINIO_SECRET_KEY=password --dry-run=client -o yaml | kubectl apply -f -"
  ui_pause

  ui_info "Install Age"
  ui_note "
Age is a simple file encryption tool.

Klio uses Age to protect the encryption key
used for its backups.

We will generate an Age identity and use it
to encrypt a random backup key.
"
  ui_command "apt-get update && apt-get install -y age"
  ui_pause

  if ! kubectl get secret klio-age >/dev/null 2>&1; then
    ui_info "Generate Age identity"
    ui_command "age-keygen -o /tmp/klio-identity.txt"
    ui_pause

    ui_info "Encrypt backup key with Age"
    ui_command "openssl rand -hex 32 | age -a -r \"\$(age-keygen -y /tmp/klio-identity.txt)\" -o /tmp/klio-encryption-key.age"
    ui_pause

    ui_info "Store encryption keys in Kubernetes"
    ui_command "kubectl create secret generic klio-age --from-file=identity.txt=/tmp/klio-identity.txt --from-file=encryption-key.age=/tmp/klio-encryption-key.age"
    ui_pause

    rm -f /tmp/klio-identity.txt /tmp/klio-encryption-key.age
  else
    ui_info "Age encryption keys already exist in Kubernetes"
  fi

  ui_info "Verify secrets"
  ui_command "kubectl get secrets"
  ui_pause

  ui_info "Explore Klio Server manifest"
  ui_command "vim manifests/klio-server.yaml"
  ui_pause

  ui_info "Validate Klio Server manifest"
  ui_command "kubectl apply --dry-run=server -f manifests/klio-server.yaml"
  ui_pause

  ui_info "Deploy Klio Server"
  ui_command "kubectl apply -f manifests/klio-server.yaml"
  ui_pause

  ui_info "Wait for Klio Server"
  ui_command "kubectl rollout status statefulset/klio-server-klio --timeout=180s"
  ui_pause

  ui_info "Verify Klio Server"
  ui_command "kubectl get servers.klio.cnpg.io"
  ui_pause

  ui_info "Verify workloads"
  ui_command "kubectl get pods,pvc,svc"
  ui_pause

  ui_success "Klio Server deployment completed."
}

main() {
  clear
  show_instruct
  play
}

main "$@"
