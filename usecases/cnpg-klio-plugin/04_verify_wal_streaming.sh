#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../engine/lib/ui.sh"
source "${SCRIPT_DIR}/../../engine/usecase.sh"

show_instruct() {
  ui_note "
# 04 / Verify Klio WAL Streaming

Validate continuous WAL streaming from PostgreSQL to Klio.

## Objectives
- Check the Klio replication slot
- Generate a new WAL segment
- Verify that Klio consumes WAL
- Inspect the Klio sidecar logs

## Expected outcome
The Klio replication slot remains active and its restart LSN advances.
"
  ui_pause
}

play() {
  ui_info "Select the Kubernetes cluster"
  ui_command "kubectl config use-context ${KUBE_CONTEXT}"
  ui_pause

  ui_info "Check the Klio replication slot"
  ui_command "kubectl cnpg psql klio-cluster -- -c \"SELECT slot_name, active, restart_lsn FROM pg_replication_slots WHERE slot_name = 'klio';\""
  ui_pause

  ui_info "Force PostgreSQL to switch WAL segments"
  ui_command "kubectl cnpg psql klio-cluster -- -c \"SELECT pg_switch_wal();\""
  ui_pause

  ui_info "Verify that Klio advances its replication position"
  ui_command "kubectl cnpg psql klio-cluster -- -c \"SELECT slot_name, active, restart_lsn FROM pg_replication_slots WHERE slot_name = 'klio';\""
  ui_pause

  ui_info "Identify the current PostgreSQL primary"
  ui_command "kubectl get pods -l cnpg.io/cluster=klio-cluster -L cnpg.io/instanceRole"
  ui_pause

  ui_info "Inspect Klio sidecar logs (replace pod name if the primary changed)"
  ui_command "kubectl logs -l cnpg.io/cluster=klio-cluster,cnpg.io/instanceRole=primary -c klio-plugin --tail=30"
  ui_pause

  ui_success "Klio WAL streaming verification completed."
  ui_info "Next scenario: 05_backup.sh"
}

main() {
  clear
  show_instruct
  play
}

main "$@"
