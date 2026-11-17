#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# CNPG Playground - Scenario 05
# Restore a new cluster from Klio
# -----------------------------------------------------------------------------

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../engine/lib/ui.sh"
source "${SCRIPT_DIR}/../../engine/usecase.sh"

show_instruct() {
  ui_note "
# 05 / Restore from Klio

Bootstrap a new PostgreSQL cluster from the Klio server.

## Objectives
- Declare the Klio server as an external cluster (plugin source)
- Recover the latest base backup and replay the WAL stream
- Validate the restored data, including the marker row of scenario 04

## Expected outcome
A new cluster named klio-restored with the pgbench dataset
and the klio_demo marker row.

The source cluster klio-cluster remains unchanged.
"
  ui_pause
}

play() {

  ui_info "Select the Kubernetes cluster"
  ui_command "kubectl config use-context ${KUBE_CONTEXT}"
  ui_pause

  ui_info "List the backups available for klio-cluster"
  ui_command "kubectl get backups.postgresql.cnpg.io"
  ui_pause

  ui_info "Explore the restore manifest (bootstrap.recovery from the Klio plugin)"
  ui_command "vim manifests/restore-cluster.yaml"
  ui_pause

  ui_info "Deploy the restored PostgreSQL cluster"
  ui_command "kubectl apply -f manifests/restore-cluster.yaml"
  ui_pause

  ui_info "Watch the recovery job, then the new instance"
  ui_watch "kubectl get pods -l cnpg.io/cluster=klio-restored -o wide"
  ui_pause

  ui_info "Check the restored cluster"
  ui_watch "kubectl cnpg status klio-restored --color always"
  ui_pause

  ui_info "Verify the dataset from the base backup"
  ui_command "kubectl cnpg psql klio-restored -- app -c \"SELECT count(*) FROM pgbench_accounts;\""
  ui_pause

  ui_info "Verify the marker row written after the backup (recovered from the WAL stream)"
  ui_command "kubectl cnpg psql klio-restored -- app -c \"SELECT * FROM klio_demo;\""
  ui_pause

  ui_info "Compare with the source cluster"
  ui_command "kubectl cnpg psql klio-cluster -- app -c \"SELECT * FROM klio_demo;\""
  ui_pause

  ui_success "Restore from Klio successfully completed."
  ui_info "Next scenario: 06_reset_lab.sh"
}

main() {
  clear
  show_instruct
  play
}

main "$@"
