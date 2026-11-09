#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../engine/lib/ui.sh"
source "${SCRIPT_DIR}/../../engine/usecase.sh"

show_instruct() {
  ui_note "
# 04 / Backup

Explore PGD4K backup architecture using Barman Cloud Plugin and MinIO.

## Architecture
- Each PGD node independently archives its WAL files
- PGD4K selects one Backup Node for physical base backups
- Barman Cloud Plugin stores backups in MinIO
- PGD4K automatically manages scheduled backups

## Objectives
- Identify the Backup Node
- Explore existing backups
- Trigger an on-demand backup
- Monitor backup completion

## Expected outcome
A successful physical backup stored in MinIO.

Note: Restore operations are outside the scope of this scenario.
"
  ui_pause
}

play() {
  ui_info "Switch to the playground Kubernetes context."
  ui_command "kubectl config use-context ${KUBE_CONTEXT}"
  ui_pause

  ui_info "Step 1/5 — Backup architecture. PGD4K configures WAL archiving for each PostgreSQL node, but selects one Backup Node for physical backups. The scheduled backup resource identifies the currently selected node."
  ui_command "kubectl get scheduledbackups -o wide"
  ui_pause

  ui_info "Step 2/5 — Existing backups. PGD4K automatically created an initial backup during cluster deployment because immediate backups were enabled. Each Backup resource belongs to an underlying PG4K cluster."
  ui_command "kubectl get backups"
  ui_pause

  ui_info "Step 3/5 — Backup configuration. The PGDGroup defines the S3-compatible MinIO destination, Barman Cloud Plugin integration, retention policy and backup schedule."
  ui_command "kubectl get pgdgroup pgd-group -o yaml"
  ui_pause

  ui_info "Step 4/5 — On-demand backup. The EDB kubectl cnp plugin creates a PG4K Backup resource. Here we target pgd-group-1, the Backup Node identified in our current deployment."
  ui_command "kubectl cnp backup pgd-group-1 --method=plugin --plugin-name=barman-cloud.cloudnative-pg.io"
  ui_pause

  ui_info "Step 5/5 — Backup monitoring. Observe the new Backup resource until its phase becomes completed. Barman Cloud Plugin uploads the physical backup to MinIO."
  ui_watch "kubectl get backups"

  ui_success "PGD4K backup demonstration completed!"
  ui_info "Next scenario: 05_high_availability.sh"
}

main() {
  clear
  show_instruct
  play
}

main "$@"
