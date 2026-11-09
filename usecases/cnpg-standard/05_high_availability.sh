#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../engine/lib/ui.sh"
source "${SCRIPT_DIR}/../../engine/usecase.sh"

show_instruct() {
  ui_note "
# 05 / High Availability

Explore PostgreSQL high availability with CloudNativePG.

## Objectives
- Identify primary and replica instances
- Perform a controlled switchover
- Simulate an unexpected primary failure
- Observe automatic failover and recovery

## Expected outcome
PostgreSQL recovers automatically after a primary failure.
Persistent volumes and data are preserved.
"
  ui_pause
}

play() {
  ui_info "Identify the current PostgreSQL primary and replicas"
  ui_command "kubectl get pods -l cnpg.io/cluster=cnpg-cluster -L cnpg.io/instanceRole -o wide"
  ui_pause

  local replica
  replica=$(kubectl get pods -l cnpg.io/cluster=cnpg-cluster,cnpg.io/instanceRole=replica -o jsonpath='{.items[0].metadata.name}')
  [[ -n "$replica" ]] || { ui_error "No replica available"; return 1; }

  ui_info "Perform a controlled switchover to ${replica}"
  ui_command "kubectl cnpg promote cnpg-cluster ${replica}"
  ui_pause

  ui_info "Observe PostgreSQL roles after switchover"
  ui_watch "kubectl get pods -l cnpg.io/cluster=cnpg-cluster -L cnpg.io/instanceRole"
  ui_pause

  ui_info "Verify PostgreSQL cluster status"
  ui_command "kubectl cnpg status cnpg-cluster"
  ui_pause

  local primary
  primary=$(kubectl get cluster cnpg-cluster -o jsonpath='{.status.currentPrimary}')
  [[ -n "$primary" ]] || { ui_error "No primary found"; return 1; }

  ui_warn "Simulate an unexpected failure of primary ${primary}. Persistent volumes are preserved."
  ui_confirm "Force-delete ${primary}?" || return 0

  ui_command "kubectl delete pod ${primary} --grace-period=0 --force"
  ui_pause

  ui_info "Observe automatic failover and primary election"
  ui_watch "kubectl get pods -l cnpg.io/cluster=cnpg-cluster -L cnpg.io/instanceRole"
  ui_pause

  ui_info "Verify PostgreSQL cluster recovery"
  ui_command "kubectl cnpg status cnpg-cluster"
  ui_pause

  ui_success "High availability scenario completed."
  ui_info "Next scenario: 06_cluster_administration.sh"
}

main() {
  clear
  show_instruct
  play
}

main "$@"
