#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../engine/lib/ui.sh"
source "${SCRIPT_DIR}/../../engine/usecase.sh"

show_instruct() {
  ui_note "
# 06 / Planned Switchover

Demonstrate a controlled Write Leader transfer
between PostgreSQL nodes in a PGDGroup.

## Key Concepts
- Write Leader: coordinates application writes
- Switchover: planned transfer of write leadership
- Raft: coordinates distributed decisions
- Connection Manager: routes application traffic

## Objectives
- Identify the current Write Leader
- Transfer leadership to another node
- Verify the new leader and group health

No PostgreSQL pod will be intentionally stopped.
"
  ui_pause
}

play() {
  ui_info "Switch to the playground Kubernetes context."
  ui_command "kubectl config use-context ${KUBE_CONTEXT}"
  ui_pause

  ui_info "Identify the current Write Leader and confirm all three PGD nodes are healthy."
  ui_command "kubectl exec pgd-group-1-1 -c postgres -- pgd --dsn 'host=/controller/run user=postgres dbname=app' group pgd-group show --summary"
  ui_pause

  ui_info "Check the current Raft Leader. Raft leadership and write leadership are separate responsibilities."
  ui_command "kubectl exec pgd-group-1-1 -c postgres -- pgd --dsn 'host=/controller/run user=postgres dbname=app' raft show"
  ui_pause

  ui_info "Inspect the available PGD nodes and select a healthy node that is not the current Write Leader."
  ui_command "kubectl get pods -o wide | grep pgd-group"
  ui_pause

  ui_info "Review the supported PGD command syntax before initiating a controlled Write Leader transfer."
  ui_command "kubectl exec pgd-group-1-1 -c postgres -- pgd group --help"
  ui_pause

  ui_info "Transfer the Write Leader to the selected node using the PGD CLI."
  ui_command "kubectl exec pgd-group-1-1 -c postgres -- pgd --dsn 'host=/controller/run user=postgres dbname=app' group pgd-group set-leader pgd-group-2"
  ui_pause

  ui_info "Verify that the Write Leader has changed and that the other PGD nodes remain available."
  ui_command "kubectl exec pgd-group-1-1 -c postgres -- pgd --dsn 'host=/controller/run user=postgres dbname=app' group pgd-group show --summary"
  ui_pause

  ui_info "Check Raft consensus after the switchover. The Raft Leader does not necessarily change."
  ui_command "kubectl exec pgd-group-1-1 -c postgres -- pgd --dsn 'host=/controller/run user=postgres dbname=app' raft show"
  ui_pause

  ui_info "Confirm the PGDGroup remains healthy after the planned leadership transfer."
  ui_command "kubectl get pgdgroup pgd-group"
  ui_pause

  ui_success "Planned switchover demonstration completed!"
  ui_info "Next scenario: 07_ha_failover.sh"
}

main() {
  clear
  show_instruct
  play
}

main "$@"
