#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../engine/lib/ui.sh"
source "${SCRIPT_DIR}/../../engine/usecase.sh"

CLUSTER="cnpg-cluster"

show_instruct() {
  ui_note "
# 07 / PostgreSQL Upgrades

Upgrade PostgreSQL using CloudNativePG 1.30.

## Objectives
- Perform a minor upgrade from PostgreSQL 17.5 to 17.6
- Observe the rolling update of PostgreSQL instances
- Perform an in-place major upgrade from PostgreSQL 17 to 18
- Observe the upgrade job and PostgreSQL recovery

## Expected outcome
PostgreSQL 18 is running on the existing cluster.

## Important
The major upgrade requires downtime.
All PostgreSQL instances stop while pg_upgrade runs.
A backup should be available (scenario 04).
"
  ui_pause
}

play() {
  ui_info "Current PostgreSQL version"
  ui_command "kubectl cnpg psql ${CLUSTER} -- app -c \"SHOW server_version;\""
  ui_pause

  ui_info "Minor upgrade: PostgreSQL 17.5 to 17.6"
  ui_command "kubectl patch cluster ${CLUSTER} --type merge -p '{\"spec\":{\"imageName\":\"ghcr.io/cloudnative-pg/postgresql:17.6-standard-bookworm\"}}'"
  ui_pause

  ui_info "Observe PostgreSQL rolling update"
  ui_watch "kubectl get pods -l cnpg.io/cluster=${CLUSTER} -L cnpg.io/instanceRole"

  ui_info "Verify PostgreSQL version"
  ui_command "kubectl cnpg psql ${CLUSTER} -- app -c \"SHOW server_version;\""
  ui_pause

  ui_warn "Major upgrade to PostgreSQL 18: all instances will stop and PostgreSQL will be unavailable."
  ui_confirm "Upgrade PostgreSQL 17 to 18 in place?" || exit 0

  ui_info "Major upgrade: PostgreSQL 17 to 18"
  ui_command "kubectl patch cluster ${CLUSTER} --type json -p '[{\"op\":\"replace\",\"path\":\"/spec/imageName\",\"value\":\"ghcr.io/cloudnative-pg/postgresql:18-standard-bookworm\"},{\"op\":\"add\",\"path\":\"/spec/plugins/0/parameters/serverName\",\"value\":\"cnpg-cluster-pg18\"}]'"
  ui_pause

  ui_info "Observe PostgreSQL upgrade and recovery"
  ui_watch "kubectl get pods,jobs -l cnpg.io/cluster=${CLUSTER}"

  ui_info "Verify PostgreSQL 18"
  ui_command "kubectl cnpg psql ${CLUSTER} -- app -c \"SELECT version();\""
  ui_pause

  ui_info "Verify cluster health"
  ui_command "kubectl cnpg status ${CLUSTER}"
  ui_pause

  ui_success "PostgreSQL upgraded successfully to version 18."
  ui_info "Next scenario: 08"
}

main() {
  clear
  show_instruct
  play
}

main "$@"
