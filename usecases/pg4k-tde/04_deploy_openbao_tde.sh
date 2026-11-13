#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "${SCRIPT_DIR}/../../engine/lib/ui.sh"
source "${SCRIPT_DIR}/../../engine/usecase.sh"
source "${SCRIPT_DIR}/../../.env"

CLUSTER="pge-tde-openbao"
OPENBAO_POD="openbao-0"
TRANSIT_KEY="pg-tde"

show_instruct() {
  ui_note "
# 04 / Deploy PG4K with OpenBao Transit

Deploy PostgreSQL 18 with TDE and external key management.

Architecture:

PostgreSQL 18
    |
    | Data Encryption Key (DEK)
    v
EDB Vault Helper
    |
    | WRAP / UNWRAP
    v
OpenBao Transit
    |
    | Key Encryption Key (KEK)
    | pg-tde
    v
Encrypted DEK stored in PostgreSQL

This scenario deploys:

- OpenBao using Helm
- Transit secrets engine
- AES-256 Transit key
- Kubernetes Secrets and RBAC
- PostgreSQL 18 with TDE enabled

OpenBao runs in development mode.
"
  ui_pause
}

play() {
  ui_info "Installing OpenBao Helm repository"

  ui_command "helm repo add openbao https://openbao.github.io/openbao-helm --force-update"
  ui_command "helm repo update"

  ui_pause

  ui_info "Deploying OpenBao"

  ui_command "helm upgrade --install openbao openbao/openbao --set server.dev.enabled=true --set server.dev.devRootToken=root --set injector.enabled=false"

  ui_command "kubectl wait --for=condition=Ready pod/openbao-0 --timeout=180s"

  ui_command "kubectl get pods -l app.kubernetes.io/name=openbao"

  ui_pause

  ui_info "Checking OpenBao status"

  ui_command "kubectl exec $OPENBAO_POD -- bao status"

  ui_pause

  ui_info "Configuring Transit secrets engine"

  if kubectl exec "$OPENBAO_POD" -- bao secrets list -format=json \
    | grep -q '"transit/"'; then
    ui_success "Transit secrets engine already enabled"
  else
    ui_command "kubectl exec $OPENBAO_POD -- bao secrets enable transit"
  fi

  ui_pause

  ui_info "Creating Transit encryption key"

  if kubectl exec "$OPENBAO_POD" -- bao read "transit/keys/$TRANSIT_KEY" \
    >/dev/null 2>&1; then
    ui_success "Transit key already exists"
  else
    ui_command "kubectl exec $OPENBAO_POD -- bao write -f transit/keys/$TRANSIT_KEY"
  fi

  ui_pause

  ui_info "Verifying Transit encryption key"

  ui_command "kubectl exec $OPENBAO_POD -- bao read transit/keys/$TRANSIT_KEY"

  ui_pause

  ui_info "Creating OpenBao authentication Secret"

  ui_command "kubectl create secret generic openbao-token --from-literal=token=root --dry-run=client -o yaml | kubectl apply -f -"

  ui_pause

  ui_info "Creating TDE WRAP / UNWRAP commands"

  kubectl create secret generic openbao-tde-commands \
    --from-literal=wrap='/bin/vault wrap --file %p --host http://openbao:8200 --secret openbao-token --key token --vault-transit transit --vault-endpoint pg-tde' \
    --from-literal=unwrap='/bin/vault unwrap --file %p --host http://openbao:8200 --secret openbao-token --key token --vault-transit transit --vault-endpoint pg-tde' \
    --dry-run=client -o yaml | kubectl apply -f -

  ui_command "kubectl get secret openbao-tde-commands"

  ui_pause

  ui_info "Configuring Kubernetes RBAC"

  ui_command "kubectl apply -f ${SCRIPT_DIR}/manifests/openbao-rbac.yaml"

  ui_pause

  ui_info "Deploying PostgreSQL with OpenBao TDE"

  ui_command "kubectl apply -f ${SCRIPT_DIR}/manifests/cluster-openbao.yaml"

  ui_info "Waiting for PostgreSQL readiness"

  ui_command "kubectl wait --for=condition=Ready cluster/$CLUSTER --timeout=300s"

  ui_pause

  ui_info "Checking PostgreSQL cluster"

  ui_command "kubectl get cluster $CLUSTER"

  ui_command "kubectl get pods -l k8s.enterprisedb.io/cluster=$CLUSTER"

  ui_pause

  ui_info "Verifying PostgreSQL TDE configuration"

  local POD
  POD=$(kubectl get cluster "$CLUSTER" \
    -o jsonpath='{.status.currentPrimary}')

  ui_command "kubectl exec $POD -c postgres -- pg_controldata /var/lib/postgresql/data/pgdata | grep -E 'Data encryption version|Data encryption key length'"

  ui_success "PostgreSQL TDE with OpenBao Transit deployed"
}

main() {
  clear
  show_instruct
  play
}

main "$@"
