#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../engine/lib/ui.sh"
source "${SCRIPT_DIR}/../../engine/usecase.sh"

show_instruct() {
  ui_note "
# 05 / Physical Backup with Klio

Create and verify a PostgreSQL physical backup using Klio.

## Architecture
- CNPG triggers the backup through the Klio plugin
- Klio Server manages backup storage
- Tier 1: local PVC
- Tier 2: MinIO object storage

## Objectives
- Trigger an on-demand physical backup
- Monitor backup execution
- Verify backup completion
- Inspect the Klio server and MinIO storage

## Expected outcome
A completed physical backup managed by Klio.
"
  ui_pause
}

play() {
  ui_info "Select the Kubernetes cluster"
  ui_command "kubectl config use-context ${KUBE_CONTEXT}"
  ui_pause

  ui_info "Check PostgreSQL cluster health"
  ui_command "kubectl cnpg status klio-cluster"
  ui_pause

  ui_info "Check existing backups"
  ui_command "kubectl get backups"
  ui_pause

  ui_info "Trigger a physical backup using the Klio plugin"
  ui_command "kubectl cnpg backup klio-cluster --method plugin --plugin-name klio.cnpg.io --backup-target primary"
  ui_pause

  ui_info "Monitor backup execution"
  ui_command "kubectl get backups"
  ui_pause

  ui_info "Inspect backup status and details"
  ui_command "kubectl get backups -o wide"
  ui_pause

  ui_info "Inspect Klio server logs"
  ui_command "kubectl logs klio-server-klio-0 --tail=50"
  ui_pause

  ui_info "Verify the Klio replication slot remains active"
  ui_command "kubectl cnpg psql klio-cluster -- -c \"SELECT slot_name, active, restart_lsn FROM pg_replication_slots WHERE slot_name = 'klio';\""
  ui_pause

  ui_success "Klio physical backup verification completed."
  ui_info "Next scenario: 06_restore.sh"
}

main() {
  clear
  show_instruct
  play
}

main "$@"
