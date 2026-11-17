#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../engine/lib/ui.sh"
source "${SCRIPT_DIR}/../../engine/usecase.sh"

show_instruct() {
  ui_note "
# 06 / Restore PostgreSQL with Klio

Restore a PostgreSQL cluster from a physical backup managed by Klio.

## Architecture
- Source: klio-cluster
- Destination: klio-restored
- Backup: latest available Klio backup
- Recovery: physical backup + WAL replay

## Objectives
- Verify the source backup
- Deploy a new PostgreSQL cluster
- Monitor recovery and WAL replay
- Wait for the restored cluster to become Ready
- Validate restored PostgreSQL data

## Expected outcome
A healthy PostgreSQL cluster restored from Klio,
without modifying the original cluster.
"
  ui_pause
}

play() {
  ui_info "Select the Kubernetes cluster"
  ui_command "kubectl config use-context ${KUBE_CONTEXT}"
  ui_pause

  ui_info "Check the source PostgreSQL cluster"
  ui_command "kubectl cnpg status klio-cluster"
  ui_pause

  ui_info "List available Klio backups"
  ui_command "kubectl get backups -l cnpg.io/cluster=klio-cluster"
  ui_pause

  ui_info "Inspect the recovery manifest"
  ui_command "vim manifests/restore.yaml"
  ui_pause

  ui_info "Validate the recovery manifest"
  ui_command "kubectl apply --dry-run=server -f manifests/restore.yaml"
  ui_pause

  ui_info "Deploy the restored PostgreSQL cluster"
  ui_command "kubectl apply -f manifests/restore.yaml"
  ui_pause

  ui_info "Inspect PostgreSQL recovery jobs"
  ui_command "kubectl get jobs,pods -l cnpg.io/cluster=klio-restored"
  ui_pause

  ui_info "Monitor PostgreSQL recovery and WAL replay"
  ui_watch "kubectl cnpg status klio-restored --color always"
  ui_pause

  ui_info "Wait for the restored PostgreSQL cluster to become Ready"
  ui_command "kubectl wait --for=condition=Ready cluster/klio-restored --timeout=600s"
  ui_pause

  ui_info "Verify all three PostgreSQL instances are Ready"
  ui_command "kubectl wait --for=condition=Ready pod -l cnpg.io/cluster=klio-restored --timeout=300s"
  ui_pause

  ui_info "Inspect the final PostgreSQL cluster status"
  ui_command "kubectl cnpg status klio-restored"
  ui_pause

  ui_info "Verify recovery has completed"
  ui_command "kubectl cnpg psql klio-restored -- -c \"SELECT pg_is_in_recovery();\""
  ui_pause

  ui_info "Verify restored pgbench data"
  ui_command "kubectl cnpg psql klio-restored -- app -c \"SELECT count(*) FROM pgbench_accounts;\""
  ui_pause

  ui_info "Compare source and restored clusters"
  ui_command "kubectl get clusters"
  ui_pause

  ui_success "Klio physical restore completed successfully."
}

main() {
  clear
  show_instruct
  play
}

main "$@"
