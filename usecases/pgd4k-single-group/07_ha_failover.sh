#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../engine/lib/ui.sh"
source "${SCRIPT_DIR}/../../engine/usecase.sh"

show_instruct() {
  ui_note "
# 07 / Automatic Failover

Simulate an unexpected failure of the Write Leader pod.

## Objectives
- Identify the current Write Leader
- Force-delete its PostgreSQL pod
- Observe Kubernetes automatic recovery
- Check PGD leadership after recovery

Note:
A fast pod restart may preserve the same Write Leader.
"
  ui_pause
}

play() {
  ui_info "Switch to the playground Kubernetes context."
  ui_command "kubectl config use-context ${KUBE_CONTEXT}"
  ui_pause

  ui_info "Identify the current Write Leader."
  ui_command "kubectl exec pgd-group-1-1 -c postgres -- pgd --dsn 'host=/controller/run user=postgres dbname=app' group pgd-group show --summary"
  ui_pause

  ui_info "Check the PostgreSQL pods and their Kubernetes workers."
  ui_command "kubectl get pods -o wide | grep pgd-group"
  ui_pause

  ui_info "Simulate an unexpected failure of the Write Leader pod."
  ui_command "kubectl delete pod pgd-group-2-1 --force --grace-period=0 --wait=false"
  ui_pause

  ui_info "Observe Kubernetes recreating the failed pod."
  ui_watch "kubectl get pods -o wide | grep pgd-group"

  ui_info "Check the Write Leader after the failure."
  ui_command "kubectl exec pgd-group-1-1 -c postgres -- pgd --dsn 'host=/controller/run user=postgres dbname=app' group pgd-group show --summary"
  ui_pause

  ui_info "Verify the health of all PGD nodes."
  ui_command "kubectl exec pgd-group-1-1 -c postgres -- pgd --dsn 'host=/controller/run user=postgres dbname=app' group pgd-group show"
  ui_pause

  ui_success "PGD4K failure and recovery demonstration completed!"
}

main() {
  clear
  show_instruct
  play
}

main "$@"
