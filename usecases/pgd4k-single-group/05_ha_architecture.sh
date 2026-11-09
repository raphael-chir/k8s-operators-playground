#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../engine/lib/ui.sh"
source "${SCRIPT_DIR}/../../engine/usecase.sh"

show_instruct() {
  ui_note "
# 05 / High Availability Architecture

Explore PGD4K high availability through distributed
PostgreSQL, Write Leader election and Raft consensus.

## Key Concepts
- Write Leader: coordinates application writes
- Raft Leader: coordinates distributed consensus
- Quorum: majority of voting members
- PGD4K: manages the distributed group
- PG4K: manages PostgreSQL instances

## Objectives
- Explore PGD topology and leadership
- Understand Raft consensus and quorum
- Inspect Kubernetes placement and PDBs

Read-only scenario. No cluster modifications.
"
  ui_pause
}

play() {
  ui_info "Switch to the playground Kubernetes context."
  ui_command "kubectl config use-context ${KUBE_CONTEXT}"
  ui_pause

  ui_info "PGD4K manages the distributed group, composed of three PostgreSQL data nodes."
  ui_command "kubectl get pgdgroup pgd-group"
  ui_pause

  ui_info "PG4K manages each PGD node as an independent single-instance PostgreSQL cluster."
  ui_command "kubectl get clusters.postgresql.k8s.enterprisedb.io"
  ui_pause

  ui_info "The Write Leader coordinates writes, while Connection Manager routes application traffic."
  ui_command "kubectl exec pgd-group-1-1 -c postgres -- pgd --dsn 'host=/controller/run user=postgres dbname=app' group pgd-group show --summary"
  ui_pause

  ui_info "Raft maintains distributed consensus. The Raft Leader and Write Leader have different responsibilities."
  ui_command "kubectl exec pgd-group-1-1 -c postgres -- pgd --dsn 'host=/controller/run user=postgres dbname=app' raft show"
  ui_pause

  ui_info "With three voting nodes, Raft requires two votes for quorum and can tolerate one voter failure."
  ui_command "kubectl get pgdgroup pgd-group -o jsonpath='{.spec.instances}{\" data instances, \"}{.spec.witnessInstances}{\" witness instances\n\"}'"
  ui_pause

  ui_info "PostgreSQL instances should be distributed across different Kubernetes workers for fault tolerance."
  ui_command "kubectl get pods -o wide -l k8s.pgd.enterprisedb.io/group=pgd-group"
  ui_pause

  ui_info "PodDisruptionBudgets control voluntary evictions, while PGD4K coordinates leadership during maintenance."
  ui_command "kubectl get pdb"
  ui_pause

  ui_success "PGD4K High Availability architecture explored!"
  ui_info "Next scenario: 06_ha_switchover.sh"
}

main() {
  clear
  show_instruct
  play
}

main "$@"
