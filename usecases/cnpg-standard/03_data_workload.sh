#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# CNPG Playground - Scenario 03
# Data & Workload
# -----------------------------------------------------------------------------

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../engine/lib/ui.sh"
source "${SCRIPT_DIR}/../../engine/usecase.sh"

show_instruct() {
  ui_note "
# 03 / Data & Workload

Connect to PostgreSQL, initialize a dataset and generate a workload.

## Objectives
- Discover PostgreSQL application credentials
- Initialize a pgbench dataset (100,000 accounts)
- Query PostgreSQL using psql
- Generate a workload and observe performance

## Expected outcome
A PostgreSQL cluster populated with data, ready for backup,
restore and high availability scenarios.
"
  ui_pause
}

play() {

  ui_info "Discover PostgreSQL application connection credentials"
  ui_command "kubectl get secret cnpg-cluster-app -o jsonpath='{.data.uri}' | base64 --decode; echo"
  ui_pause

  ui_info "Clean up previous pgbench jobs"
  ui_command "kubectl delete job pgb-init pgb-run --ignore-not-found"
  ui_pause

  ui_info "Initialize the pgbench dataset (100,000 accounts)"
  ui_command "kubectl cnpg pgbench --job-name pgb-init cnpg-cluster -- --initialize"
  ui_pause

  ui_info "Wait for dataset initialization"
  ui_command "kubectl wait --for=condition=complete job/pgb-init --timeout=300s"
  ui_pause

  ui_info "Query PostgreSQL using psql"
  ui_command "kubectl cnpg psql cnpg-cluster -- app -c \"SELECT count(*) FROM pgbench_accounts;\""
  ui_pause

  ui_info "Generate a 15-second workload"
  ui_command "kubectl cnpg pgbench --job-name pgb-run cnpg-cluster -- --time 15 --client 2 --jobs 2"
  ui_pause

  ui_info "Wait for workload completion"
  ui_command "kubectl wait --for=condition=complete job/pgb-run --timeout=120s"
  ui_pause

  ui_info "Review pgbench results"
  ui_command "kubectl logs job/pgb-run"
  ui_pause

  ui_success "Dataset initialized and workload completed."
  ui_info "Next scenario: 04_backup_restore.sh"
}

main() {
  clear
  show_instruct
  play
}

main "$@"
