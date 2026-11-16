#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../engine/lib/ui.sh"
source "${SCRIPT_DIR}/../../engine/usecase.sh"

CLUSTER="kind-cnpg-lab-cnpg-edb-plugin-1"

show_instruct() {
  ui_note "
# 05 / Test Operator Coexistence

Perform controlled switchovers on both clusters.

1. CNPG: epas-cluster-1 -> epas-cluster-2
2. PGD4K: pgd-group-1 -> pgd-group-2
3. Verify both clusters remain healthy
"
  ui_pause
}

play() {
  ui_info "Select Kubernetes context"
  ui_command "kubectl config use-context ${CLUSTER}"
  ui_pause

  ui_info "Check initial cluster status"
  ui_command "kubectl get clusters.postgresql.cnpg.io epas-cluster; kubectl get pgdgroup pgd-group"
  ui_pause

  ui_info "CNPG - Switchover to epas-cluster-2"
  ui_command "kubectl cnpg promote epas-cluster epas-cluster-2"
  ui_pause

  ui_info "Verify CNPG switchover"
  ui_command "kubectl get clusters.postgresql.cnpg.io epas-cluster"
  ui_pause

  ui_info "PGD4K - Check current Write Leader"
  ui_command "kubectl exec pgd-group-2-1 -c postgres -- pgd --dsn 'host=/controller/run user=postgres dbname=app' group pgd-group show --summary"
  ui_pause

  ui_info "PGD4K - Switchover to pgd-group-2"
  ui_command "kubectl exec pgd-group-2-1 -c postgres -- pgd --dsn 'host=/controller/run user=postgres dbname=app' group pgd-group set-leader pgd-group-2"
  ui_pause

  ui_info "Verify PGD4K switchover"
  ui_command "kubectl exec pgd-group-2-1 -c postgres -- pgd --dsn 'host=/controller/run user=postgres dbname=app' group pgd-group show --summary"
  ui_pause

  ui_info "Verify both clusters"
  ui_command "kubectl get clusters.postgresql.cnpg.io epas-cluster; kubectl get pgdgroup pgd-group"
  ui_pause

  ui_success "CNPG and PGD4K switchover tests completed."
}

main() {
  clear
  show_instruct
  play
}

main "$@"
