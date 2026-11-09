#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../engine/lib/ui.sh"
source "${SCRIPT_DIR}/../../engine/usecase.sh"

PGD_DSN="host=/controller/run user=postgres dbname=app"

show_instruct() {
  ui_note "
# 08 / Kubernetes Node Drain

Simulate planned Kubernetes node maintenance.

## Objectives
- Monitor continuous SQL transactions
- Identify the Write Leader worker
- Drain the worker and observe leadership transfer
- Measure transaction failures and latency
- Restore the Kubernetes worker

The availability monitor runs on the control-plane.
"
  ui_pause
}

play() {
  ui_info "Switch to the playground Kubernetes context."
  ui_command "kubectl config use-context ${KUBE_CONTEXT}"
  ui_pause

  ui_info "Inspect the current Write Leader."
  ui_command "kubectl exec pgd-group-1-1 -c postgres -- pgd --dsn '${PGD_DSN}' group pgd-group show --summary"
  ui_pause

  ui_info "Check PostgreSQL pod placement."
  ui_command "kubectl get pods -o wide | grep pgd-group"
  ui_pause

  ui_info "Remove any previous availability monitor."
  ui_command "kubectl delete pod pgd-availability-monitor --ignore-not-found --wait=true"
  ui_pause

  ui_info "Deploy the availability monitor."
  ui_command "kubectl apply -f ${SCRIPT_DIR}/manifests/availability-monitor.yaml"
  ui_pause

  ui_info "Wait for the availability monitor."
  ui_command "kubectl wait --for=condition=Ready pod/pgd-availability-monitor --timeout=120s"
  ui_pause

  ui_info "Verify application transactions."
  ui_command "kubectl logs pgd-availability-monitor --tail=10"
  ui_pause

  ui_info "Identify the worker hosting the current Write Leader."

  LEADER=$(kubectl exec pgd-group-1-1 -c postgres -- \
    pgd --dsn "$PGD_DSN" group pgd-group show --summary |
    awk -F '|' '/Write Leader/ {gsub(/ /,"",$2); print $2}')

  [ -n "$LEADER" ] || { ui_error "Unable to identify the Write Leader."; return 1; }

  DRAIN_NODE=$(kubectl get pod "${LEADER}-1" -o jsonpath='{.spec.nodeName}')

  [ -n "$DRAIN_NODE" ] || { ui_error "Unable to identify the worker."; return 1; }

  OBSERVER_POD=""
  for POD in pgd-group-1-1 pgd-group-2-1 pgd-group-3-1; do
    if [ "$POD" != "${LEADER}-1" ]; then
      OBSERVER_POD="$POD"
      break
    fi
  done

  ui_info "Write Leader: ${LEADER} | Worker: ${DRAIN_NODE}"
  ui_pause

  ui_info "Check PodDisruptionBudgets."
  ui_command "kubectl get pdb"
  ui_pause

  ui_info "Drain the Write Leader worker."
  ui_command "kubectl drain ${DRAIN_NODE} --ignore-daemonsets --delete-emptydir-data --timeout=180s"
  ui_pause

  ui_info "Verify the worker is cordoned."
  ui_command "kubectl get nodes"
  ui_pause

  ui_info "Check the Write Leader after the drain."
  ui_command "kubectl exec ${OBSERVER_POD} -c postgres -- pgd --dsn '${PGD_DSN}' group pgd-group show --summary"
  ui_pause

  ui_info "Review application availability measurements."
  ui_command "kubectl logs pgd-availability-monitor --tail=30"
  ui_pause

  ui_info "Observe PostgreSQL pod placement."
  ui_watch "kubectl get pods -o wide | grep pgd-group"

  ui_info "Restore scheduling on the drained worker."
  ui_command "kubectl uncordon ${DRAIN_NODE}"
  ui_pause

  ui_info "Verify PGDGroup health."
  ui_command "kubectl exec ${OBSERVER_POD} -c postgres -- pgd --dsn '${PGD_DSN}' group pgd-group show"
  ui_pause

  ui_info "Review final application availability measurements."
  ui_command "kubectl logs pgd-availability-monitor --tail=50"
  ui_pause

  ui_success "Kubernetes node drain demonstration completed!"
}

main() {
  clear
  show_instruct
  play
}

main "$@"
