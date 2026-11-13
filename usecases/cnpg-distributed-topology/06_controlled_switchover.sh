#!/usr/bin/env bash
# CNPG Playground - Scenario 06
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../engine/lib/ui.sh"
source "${SCRIPT_DIR}/../../engine/usecase.sh"

CLUSTER1="kind-cnpg-lab-cnpg-distributed-topology-1"
CLUSTER2="kind-cnpg-lab-cnpg-distributed-topology-2"

show_instruct() {
  ui_note "
# 06 / Controlled Switchover

Move the PostgreSQL primary from Cluster 1 to Cluster 2.

## Initial topology
- Cluster 1: Primary
- Cluster 2: Replica

## Procedure
1. Demote Cluster 1 and remove any previous promotionToken
2. Retrieve the new demotionToken
3. Promote Cluster 2 using this token
4. Wait for cluster stabilization
5. Validate PostgreSQL roles and streaming replication

## Expected outcome
- Cluster 1: Replica
- Cluster 2: Primary

## Important
Stop application writes before starting.
The demotion token protects the promotion sequence.
"
  ui_pause
}

play() {

  ui_info "Verify Cluster 1 is Primary and Cluster 2 is Replica"
  ui_command "kubectl --context ${CLUSTER1} get cluster cnpg-cluster -o jsonpath='{.spec.replica}'; echo"
  ui_pause

  CURRENT_PRIMARY=$(kubectl --context "${CLUSTER1}" get cluster cnpg-cluster -o jsonpath='{.spec.replica.primary}')
  TARGET_PRIMARY=$(kubectl --context "${CLUSTER2}" get cluster cnpg-cluster -o jsonpath='{.spec.replica.primary}')

  if [[ "${CURRENT_PRIMARY}" != "cluster-1" || "${TARGET_PRIMARY}" != "cluster-1" ]]; then
    echo "ERROR: Expected Cluster 1 as primary on both clusters."
    exit 1
  fi

  ui_info "Demote Cluster 1 and remove any previous promotion token"
  ui_command "kubectl --context ${CLUSTER1} patch cluster cnpg-cluster --type merge -p '{\"spec\":{\"replica\":{\"primary\":\"cluster-2\",\"promotionToken\":null}}}'"
  ui_pause

  ui_info "Retrieve the new demotion token from Cluster 1"

  DEMOTION_TOKEN=""

  for i in $(seq 1 120); do
    DEMOTION_TOKEN=$(kubectl --context "${CLUSTER1}" get cluster cnpg-cluster -o jsonpath='{.status.demotionToken}')
    [[ -n "${DEMOTION_TOKEN}" ]] && break
    sleep 2
  done

  if [[ -z "${DEMOTION_TOKEN}" ]]; then
    echo "ERROR: No demotion token available. Cluster 2 will not be promoted."
    exit 1
  fi

  ui_command "kubectl --context ${CLUSTER1} get cluster cnpg-cluster -o jsonpath='{.status.demotionToken}'; echo"
  ui_pause

  ui_info "Promote Cluster 2 using the new demotion token"
  ui_command "kubectl --context ${CLUSTER2} patch cluster cnpg-cluster --type merge -p '{\"spec\":{\"replica\":{\"primary\":\"cluster-2\",\"promotionToken\":\"${DEMOTION_TOKEN}\"}}}'"
  ui_pause

  ui_info "Wait for Cluster 2 to become healthy"
  ui_command "kubectl --context ${CLUSTER2} wait --for=jsonpath='{.status.phase}'='Cluster in healthy state' cluster/cnpg-cluster --timeout=300s"
  ui_pause

  ui_info "Verify Cluster 2 is now Primary"
  ui_command "kubectl cnpg status cnpg-cluster --context ${CLUSTER2} --color always"
  ui_pause

  ui_info "Verify Cluster 1 is now Replica"
  ui_command "kubectl cnpg status cnpg-cluster --context ${CLUSTER1} --color always"
  ui_pause

  ui_info "Verify PostgreSQL is writable on Cluster 2"
  ui_command "kubectl --context ${CLUSTER2} exec svc/cnpg-cluster-rw -c postgres -- psql -U postgres -c \"SELECT pg_is_in_recovery(), pg_current_wal_lsn();\""
  ui_pause

  ui_info "Verify Cluster 1 is in recovery mode"
  REPLICA_POD=$(kubectl --context "${CLUSTER1}" get cluster cnpg-cluster -o jsonpath='{.status.currentPrimary}')
  ui_command "kubectl --context ${CLUSTER1} exec ${REPLICA_POD} -c postgres -- psql -U postgres -c \"SELECT pg_is_in_recovery();\""
  ui_pause

  ui_info "Verify streaming replication from Cluster 2 to Cluster 1"
  ui_command "kubectl --context ${CLUSTER1} exec ${REPLICA_POD} -c postgres -- psql -U postgres -c \"SELECT status, sender_host, sender_port, latest_end_lsn FROM pg_stat_wal_receiver;\""
  ui_pause

  ui_success "Controlled switchover completed: Cluster 2 is Primary."
}

main() {
  clear
  show_instruct
  play
}

main "$@"
