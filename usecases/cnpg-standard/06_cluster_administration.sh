#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../engine/lib/ui.sh"
source "${SCRIPT_DIR}/../../engine/usecase.sh"

CLUSTER="cnpg-cluster"

show_instruct() {
  ui_note "
# 06 / Cluster Administration

Manage PostgreSQL cluster lifecycle using CloudNativePG.

## Objectives
- Scale PostgreSQL from 3 to 2 instances and back
- Hibernate and resume the cluster
- Fence a replica without deleting its Pod
- Verify PostgreSQL process status

## Expected outcome
A healthy PostgreSQL cluster with three running instances.
All instances are unfenced and persistent data is preserved.
"
  ui_pause
}

play() {
  ui_info "Explore CloudNativePG administration commands"
  ui_command "kubectl cnpg --help"
  ui_pause

  ui_info "Scale down PostgreSQL to 2 instances"
  ui_command "kubectl scale cluster ${CLUSTER} --replicas=2"
  ui_pause
  ui_watch "kubectl get pods -l cnpg.io/cluster=${CLUSTER} -L cnpg.io/instanceRole"

  ui_info "Scale up PostgreSQL to 3 instances"
  ui_command "kubectl scale cluster ${CLUSTER} --replicas=3"
  ui_pause
  ui_watch "kubectl get pods -l cnpg.io/cluster=${CLUSTER} -L cnpg.io/instanceRole"

  ui_info "Hibernate PostgreSQL cluster"
  ui_command "kubectl cnpg hibernate on ${CLUSTER}"
  ui_pause
  ui_watch "kubectl get pods -l cnpg.io/cluster=${CLUSTER} -L cnpg.io/instanceRole"

  ui_info "Resume PostgreSQL cluster"
  ui_command "kubectl cnpg hibernate off ${CLUSTER}"
  ui_pause
  ui_watch "kubectl get pods -l cnpg.io/cluster=${CLUSTER} -L cnpg.io/instanceRole"

  local replica
  replica=$(kubectl get pods -l "cnpg.io/cluster=${CLUSTER},cnpg.io/instanceRole=replica" -o jsonpath='{.items[0].metadata.name}')
  [[ -n "$replica" ]] || { ui_error "No replica available for fencing"; return 1; }

  ui_info "Fence replica ${replica} without deleting its Pod"
  ui_command "kubectl cnpg fencing on ${CLUSTER} ${replica}"
  ui_pause

  ui_info "Verify PostgreSQL is stopped"
  ui_command "kubectl exec ${replica} -c postgres -- pg_ctl status || true"
  ui_pause

  ui_info "Remove fencing from replica ${replica}"
  ui_command "kubectl cnpg fencing off ${CLUSTER} ${replica}"
  ui_pause

  ui_info "Verify PostgreSQL is running again"
  ui_command "kubectl exec ${replica} -c postgres -- pg_ctl status"
  ui_pause

  ui_info "Verify PostgreSQL cluster status"
  ui_command "kubectl cnpg status ${CLUSTER}"
  ui_pause

  ui_success "Cluster administration scenario completed."
  ui_info "Next scenario: 07_postgresql_upgrades.sh"
}

main() {
  clear
  show_instruct
  play
}

main "$@"
