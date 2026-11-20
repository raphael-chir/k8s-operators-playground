#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# CNPG Playground - Scenario 05
# Validate Distributed Topology Replication
# -----------------------------------------------------------------------------

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../engine/lib/ui.sh"
source "${SCRIPT_DIR}/../../engine/usecase.sh"

PRIMARY_CONTEXT="$(usecase_context 1)"
REPLICA_CONTEXT="$(usecase_context 2)"

show_instruct() {
  ui_note "
# 05 / Validate Distributed Topology Replication

Validate PostgreSQL streaming replication between two Kubernetes clusters.

## Architecture
- Cluster 1: Primary cluster (3 instances)
- Cluster 2: Replica cluster (3 instances)
- Physical replication using PostgreSQL WAL streaming

## Objectives
- Verify PostgreSQL instances and replication roles
- Validate pgbench data on the DR cluster
- Verify recovery mode and WAL replay position
- Inspect streaming replication connections and lag

## Expected outcome
Both clusters are healthy and WAL replication is operational.
"
  ui_pause
}

play() {

  ui_info "Select Kubernetes Cluster 1 (Primary)"
  ui_command "kubectl config use-context ${PRIMARY_CONTEXT}"
  ui_pause

  ui_info "Verify primary cluster health and local replication"
  ui_command "kubectl cnpg status cnpg-cluster --color always"
  ui_pause

  ui_info "Inspect streaming replication connections"
  ui_info "Expect 3 connections: 2 local replicas and 1 remote DR cluster."
  ui_command "kubectl exec cnpg-cluster-1 -c postgres -- psql -U postgres -c \"SELECT application_name, client_addr, state, sent_lsn, replay_lsn FROM pg_stat_replication;\""
  ui_pause

  ui_info "Measure replication lag in bytes"
  ui_info "A lag of 0 means the replica has replayed all WAL sent by the primary."
  ui_command "kubectl exec cnpg-cluster-1 -c postgres -- psql -U postgres -c \"SELECT application_name, state, pg_wal_lsn_diff(sent_lsn, replay_lsn) AS replay_lag_bytes FROM pg_stat_replication;\""
  ui_pause

  ui_info "Select Kubernetes Cluster 2 (Disaster Recovery)"
  ui_command "kubectl config use-context ${REPLICA_CONTEXT}"
  ui_pause

  ui_info "Verify replica cluster health and designated primary"
  ui_command "kubectl cnpg status cnpg-cluster --color always"
  ui_pause

  ui_info "Verify PostgreSQL instances and their roles"
  ui_command "kubectl get pods -l cnpg.io/cluster=cnpg-cluster -L cnpg.io/instanceRole -o wide"
  ui_pause

  ui_info "Verify replicated pgbench dataset"
  ui_info "The 100,000 accounts initialized on Cluster 1 must exist on Cluster 2."
  ui_command "kubectl exec cnpg-cluster-1 -c postgres -- psql -U postgres -d app -c \"SELECT count(*) FROM pgbench_accounts;\""
  ui_pause

  ui_info "Verify PostgreSQL recovery mode and WAL replay position"
  ui_info "pg_is_in_recovery() must return true: Cluster 2 is a read-only standby."
  ui_command "kubectl exec cnpg-cluster-1 -c postgres -- psql -U postgres -c \"SELECT pg_is_in_recovery(), pg_last_wal_replay_lsn();\""
  ui_pause

  ui_info "Verify WAL receiver on the designated primary"
  ui_info "The WAL receiver should be streaming from Cluster 1."
  ui_command "kubectl exec cnpg-cluster-1 -c postgres -- psql -U postgres -c \"SELECT status, sender_host, sender_port, written_lsn, flushed_lsn, latest_end_lsn FROM pg_stat_wal_receiver;\""  
  ui_pause

  ui_success "Distributed Topology replication validation completed."
  ui_info "Next scenario: 06_controlled_switchover.sh"
}

main() {
  clear
  show_instruct
  play
}

main "$@"
