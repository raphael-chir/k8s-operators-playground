#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# CNPG Playground - Scenario 04
# Backup & Restore
# -----------------------------------------------------------------------------

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../engine/lib/ui.sh"
source "${SCRIPT_DIR}/../../engine/usecase.sh"

show_instruct() {
  ui_note "
# 04 / Backup & Restore

Back up PostgreSQL to MinIO using the Barman Cloud Plugin, then restore
the backup into a new CloudNativePG cluster.

## Objectives
- Trigger an on-demand PostgreSQL backup
- Verify backup completion
- Restore PostgreSQL from MinIO object storage
- Validate the restored data

## Expected outcome
A new PostgreSQL cluster named restored-cnpg-cluster,
containing the original dataset.

The source cluster remains unchanged.
"
  ui_pause
}

play() {

  ui_info "Trigger an on-demand backup using Barman Cloud"
  ui_command "kubectl cnpg backup cnpg-cluster --backup-name cnpg-cluster-backup --method plugin --plugin-name barman-cloud.cloudnative-pg.io"
  ui_pause

  ui_info "Wait for backup completion"
  ui_command "kubectl wait --for=jsonpath='{.status.phase}'=completed backup/cnpg-cluster-backup --timeout=600s"
  ui_pause

  ui_info "Verify PostgreSQL backups"
  ui_command "kubectl get backups.postgresql.cnpg.io"
  ui_pause

  ui_info "Explore the PostgreSQL restore manifest"
  ui_command "vim manifests/restore-cluster.yaml"
  ui_pause

  ui_info "Deploy the restored PostgreSQL cluster"
  ui_command "kubectl apply -f manifests/restore-cluster.yaml"
  ui_pause

  ui_info "Monitor PostgreSQL cluster recovery"
  ui_watch "kubectl cnpg status restored-cnpg-cluster --color always"
  ui_pause

  ui_info "Verify restored PostgreSQL data"
  ui_command "kubectl cnpg psql restored-cnpg-cluster -- app -c \"SELECT count(*) FROM pgbench_accounts;\""
  ui_pause

  ui_info "Verify PostgreSQL version"
  ui_command "kubectl cnpg psql restored-cnpg-cluster -- app -c \"SHOW server_version;\""
  ui_pause

  ui_success "Backup and restore successfully completed."
  ui_info "Next scenario: 05_high_availability.sh"
}

main() {
  clear
  show_instruct
  play
}

main "$@"
