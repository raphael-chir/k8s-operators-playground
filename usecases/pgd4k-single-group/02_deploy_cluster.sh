#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../engine/lib/ui.sh"
source "${SCRIPT_DIR}/../../engine/usecase.sh"

show_instruct() {
  ui_note "
# 02 / Deploy PGD Cluster

Deploy a distributed PostgreSQL cluster managed by EDB PGD4K.

## Architecture
- 3 PostgreSQL 17 instances with PGD 6
- TLS certificates managed by cert-manager
- Barman Cloud Plugin connected to MinIO
- Prometheus monitoring

## Objectives
- Deploy a PGDGroup
- Explore PostgreSQL instances and their placement
- Identify the PGD Write Leader
- Discover application services and HA configuration

## Expected outcome
A healthy 3-node PGD cluster ready for application workloads.
"
  ui_pause
}

play() {
  ui_info "Switch to the playground Kubernetes context"
  ui_command "kubectl config use-context ${KUBE_CONTEXT}"
  ui_pause

  ui_info "Verify PGD4K and PG4K operators are running"
  ui_command "kubectl get pods -n pgd-operator-system"
  ui_pause

  ui_info "Create MinIO credentials for PostgreSQL backups"
  ui_command "kubectl create secret generic minio-secret --from-literal=MINIO_ACCESS_KEY=admin --from-literal=MINIO_SECRET_KEY=password --dry-run=client -o yaml | kubectl apply -f -"
  ui_pause

  ui_info "Create TLS Certificate Authorities and Issuers using cert-manager"
  ui_command "kubectl apply -f manifests/pgd-certificates.yaml"
  ui_pause

  ui_info "Wait for the TLS Certificate Authorities to become ready"
  ui_command "kubectl wait --for=condition=Ready certificate/server-ca certificate/client-ca --timeout=120s"
  ui_pause

  ui_info "Verify TLS certificates and issuers"
  ui_command "kubectl get certificates,issuers"
  ui_pause

  ui_info "Deploy the PGDGroup: 3 PostgreSQL instances with PGD 6"
  ui_command "kubectl apply -f manifests/pgd-cluster.yaml"
  ui_pause

  ui_info "Observe PGD4K provisioning and cluster health (press Enter to continue)"
  ui_watch "kubectl get pgdgroup pgd-group"

  ui_info "Explore PostgreSQL instances and their Kubernetes node placement"
  ui_command "kubectl get pods -o wide -l k8s.pgd.enterprisedb.io/group=pgd-group"
  ui_pause

  ui_info "Identify the PGD Write Leader and replication topology"
  ui_command "kubectl exec pgd-group-2-1 -c postgres -- pgd --dsn 'host=/controller/run user=postgres dbname=app' group pgd-group show --summary"
  ui_pause

  ui_info "Discover PGD Connection Manager services for read-write and read-only applications"
  ui_command "kubectl get svc -o wide"
  ui_pause

  ui_info "Verify PodDisruptionBudgets protecting PGD instances during voluntary disruptions"
  ui_command "kubectl get pdb"
  ui_pause

  ui_info "Verify Prometheus PodMonitor configuration for PGD metrics"
  ui_command "kubectl get podmonitor pgd-nodes"
  ui_pause

  ui_success "PGD cluster deployed successfully!"
  ui_info "Next scenario: 03_application_connectivity.sh"
}

main() {
  clear
  show_instruct
  play
}

main "$@"
