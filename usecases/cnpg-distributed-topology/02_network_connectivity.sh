#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# CNPG Playground - Distributed Topology - Scenario 02
# Inter-Cluster Network Connectivity
# -----------------------------------------------------------------------------

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "${SCRIPT_DIR}/../../engine/lib/ui.sh"
source "${SCRIPT_DIR}/../../engine/usecase.sh"

CLUSTER_1="kind-cnpg-lab-cnpg-distributed-topology-1"
CLUSTER_2="kind-cnpg-lab-cnpg-distributed-topology-2"

NODE_1="cnpg-lab-cnpg-distributed-topology-1-control-plane"
NODE_2="cnpg-lab-cnpg-distributed-topology-2-control-plane"

show_instruct() {
  ui_note "
# 02 / Inter-Cluster Network Connectivity

Explore and validate network connectivity between two independent
Kubernetes clusters running on the same Docker network.

## Architecture
- Kubernetes Cluster 1: Primary site
- Kubernetes Cluster 2: Disaster Recovery site
- Shared Docker network: kind
- PostgreSQL replication: TCP 5432

## What you will learn
- Understand networking between independent Kubernetes clusters
- Discover Docker networks and Kind node addresses
- Validate bidirectional TCP connectivity
- Understand ClusterIP and NodePort services
- Prepare networking for PostgreSQL streaming replication

## Prerequisites
- Two Kind clusters running
- Both clusters connected to the Docker network kind
- Docker and kubectl available

## Expected outcome
Both Kubernetes clusters can communicate over the Docker network.

PostgreSQL services will be exposed and tested in the next scenarios.
"
  ui_pause
}

play() {

  ui_info "List Docker networks"
  ui_command "docker network ls"
  ui_pause

  ui_info "Identify Kind containers and their Docker networks"
  ui_command "docker ps --format 'table {{.Names}}\t{{.Networks}}'"
  ui_pause

  ui_info "Inspect the shared Kind Docker network"
  ui_command "docker network inspect kind --format '{{range .Containers}}{{println .Name .IPv4Address}}{{end}}'"
  ui_pause

  ui_info "Identify Cluster 1 control-plane IP address"
  ui_command "docker inspect -f '{{.NetworkSettings.Networks.kind.IPAddress}}' ${NODE_1}"
  ui_pause

  ui_info "Identify Cluster 2 control-plane IP address"
  ui_command "docker inspect -f '{{.NetworkSettings.Networks.kind.IPAddress}}' ${NODE_2}"
  ui_pause

  ui_info "Check Kubernetes API listening ports on Cluster 1"
  ui_command "docker exec ${NODE_1} ss -lnt"
  ui_pause

  ui_info "Check Kubernetes API listening ports on Cluster 2"
  ui_command "docker exec ${NODE_2} ss -lnt"
  ui_pause

  ui_info "Verify TCP connectivity from Cluster 1 to Cluster 2 (Kubernetes API)"
  ui_command "docker exec ${NODE_1} bash -c 'timeout 3 bash -c \"echo > /dev/tcp/${NODE_2}/6443\" && echo TCP_OK'"
  ui_pause

  ui_info "Verify TCP connectivity from Cluster 2 to Cluster 1 (Kubernetes API)"
  ui_command "docker exec ${NODE_2} bash -c 'timeout 3 bash -c \"echo > /dev/tcp/${NODE_1}/6443\" && echo TCP_OK'"
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

Both clusters share the Docker network kind.

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
