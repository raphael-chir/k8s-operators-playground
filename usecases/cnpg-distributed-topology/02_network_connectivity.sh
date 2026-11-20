#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# CNPG Playground - Distributed Topology - Scenario 02
# Inter-Cluster Network Connectivity
# -----------------------------------------------------------------------------

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "${SCRIPT_DIR}/../../engine/lib/ui.sh"
source "${SCRIPT_DIR}/../../engine/usecase.sh"

CLUSTER_1="$(usecase_context 1)"
CLUSTER_2="$(usecase_context 2)"

NAME_1="$(provider_cluster_name "${USECASE}" 1)"
NAME_2="$(provider_cluster_name "${USECASE}" 2)"

show_instruct() {
  ui_note "
# 02 / Inter-Cluster Network Connectivity

Explore and validate network connectivity between two independent
Kubernetes clusters of the same environment.

## Architecture
- Kubernetes Cluster 1: Primary site
- Kubernetes Cluster 2: Disaster Recovery site
- Both clusters reachable from each other (provider network)
- PostgreSQL replication: TCP 5432

## What you will learn
- Understand networking between independent Kubernetes clusters
- Discover the address each cluster is reached on
- Validate bidirectional Kubernetes API connectivity
- Understand ClusterIP and NodePort services
- Prepare networking for PostgreSQL streaming replication

## Prerequisites
- Two Kubernetes clusters running
- Both clusters reachable from each other
- kubectl available

## Expected outcome
Both Kubernetes clusters can communicate with each other.

PostgreSQL services will be exposed and tested in the next scenarios.
"
  ui_pause
}

play() {

  ADDR_1="$(usecase_cluster_address 1)"
  ADDR_2="$(usecase_cluster_address 2)"

  ui_info "Identify the address other clusters use to reach Cluster 1"
  ui_command "echo ${ADDR_1}"
  ui_pause

  ui_info "Identify the address other clusters use to reach Cluster 2"
  ui_command "echo ${ADDR_2}"
  ui_pause

  ui_info "Verify that each Kubernetes API answers from the other cluster (both directions)"
  ui_command "provider_validate_connectivity ${NAME_1} ${NAME_2}"
  ui_pause

  ui_info "Select Kubernetes Cluster 1"
  ui_command "kubectl config use-context ${CLUSTER_1}"
  ui_pause

  ui_info "Display Kubernetes nodes and their internal IP addresses"
  ui_command "kubectl get nodes -o wide"
  ui_pause

  ui_info "Explore Kubernetes services"
  ui_command "kubectl get svc -A"
  ui_pause

  ui_info "Inspect the existing MinIO NodePort service"
  ui_command "kubectl get svc minio -n object-storage -o wide"
  ui_pause

  ui_info "Select Kubernetes Cluster 2"
  ui_command "kubectl config use-context ${CLUSTER_2}"
  ui_pause

  ui_info "Display Kubernetes nodes and their internal IP addresses"
  ui_command "kubectl get nodes -o wide"
  ui_pause

  ui_info "Explore Kubernetes services"
  ui_command "kubectl get svc -A"
  ui_pause

  ui_info "Inspect the existing MinIO NodePort service"
  ui_command "kubectl get svc minio -n object-storage -o wide"
  ui_pause

  ui_note "
## Network Design

Kubernetes ClusterIP services are accessible only inside their cluster.

For PostgreSQL streaming replication between clusters, we will expose
the PostgreSQL primary using a NodePort service.

Planned configuration:

- PostgreSQL port: TCP 5432
- Kubernetes NodePort: TCP 30432
- Cluster 1: Primary PostgreSQL endpoint
- Cluster 2: Replica PostgreSQL endpoint

Both clusters can reach each other (checked above).

The PostgreSQL NodePort services will be created during the
PostgreSQL deployment scenarios.
"
  ui_pause

  ui_success "Inter-cluster network discovery completed."
  ui_success "Next scenario: 03_deploy_primary.sh"
}

main() {
  clear
  show_instruct
  play
}

main "$@"
