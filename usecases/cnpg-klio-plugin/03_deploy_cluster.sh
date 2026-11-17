#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# CNPG Playground - Scenario 03
# Deploy a PostgreSQL cluster protected by Klio
# -----------------------------------------------------------------------------

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../engine/lib/ui.sh"
source "${SCRIPT_DIR}/../../engine/usecase.sh"

CLUSTER="kind-cnpg-lab-cnpg-klio-plugin-1"

show_instruct() {
  ui_note "
# 03 / Deploy PostgreSQL with Klio

Deploy a PostgreSQL 17 cluster protected by Klio.

## Architecture
- 3 PostgreSQL instances
- Synchronous replication (ANY 1)
- Klio plugin using CNPG-I
- Klio sidecar in PostgreSQL pods
- WAL streaming to Klio Server
- Tier 1: Local PVC
- Tier 2: MinIO S3

## Objectives
1. Configure the Klio plugin
2. Deploy PostgreSQL
3. Verify sidecar injection
4. Verify WAL streaming
5. Initialize pgbench (100,000 accounts)

## Expected outcome
A healthy PostgreSQL cluster streaming WAL to Klio.
"
  ui_pause
}

play() {

  ui_info "Select Kubernetes context"
  ui_command "kubectl config use-context ${CLUSTER}"
  ui_pause

  ui_info "Verify Klio Server is running"
  ui_command "kubectl get pods -l klio.cnpg.io/klio-server=klio-server"
  ui_pause

  ui_info "Explore the Klio PluginConfiguration CRD"
  ui_command "kubectl explain pluginconfigurations.spec"
  ui_pause

  ui_info "Explore PostgreSQL and Klio manifests"
  ui_command "vim manifests/cluster.yaml"
  ui_pause

  ui_info "Validate manifests"
  ui_command "kubectl apply --dry-run=server -f manifests/cluster.yaml"
  ui_pause

  ui_info "Deploy Klio PluginConfiguration"
  ui_command "kubectl apply -f manifests/cluster.yaml"
  ui_pause

  ui_info "Verify PluginConfiguration"
  ui_command "kubectl get pluginconfigurations.klio.cnpg.io"
  ui_pause

  ui_info "Wait for PostgreSQL cluster"
  ui_command "kubectl wait --for=condition=Ready cluster/klio-cluster --timeout=300s"
  ui_pause

  ui_info "Check PostgreSQL cluster status"
  ui_command "kubectl cnpg status klio-cluster"
  ui_pause

  ui_info "Verify PostgreSQL instances"
  ui_command "kubectl get pods -l cnpg.io/cluster=klio-cluster -o wide"
  ui_pause

  ui_info "Verify PostgreSQL roles"
  ui_command "kubectl get cluster klio-cluster"
  ui_pause

  ui_info "Inspect PostgreSQL containers"
  ui_note "
Klio integrates with CloudNativePG using CNPG-I.

The plugin injects a sidecar into PostgreSQL pods.

This sidecar handles:
- Continuous WAL streaming
- Backup operations
- Communication with Klio Server
"
  ui_command "kubectl get pod -l cnpg.io/cluster=klio-cluster -o jsonpath='{.items[0].spec.containers[*].name}'; echo"
  ui_pause

  ui_info "Inspect native sidecars"
  ui_command "kubectl get pod -l cnpg.io/cluster=klio-cluster -o jsonpath='{.items[0].spec.initContainers[*].name}'; echo"
  ui_pause

  ui_info "Verify Klio plugin status"
  ui_command "kubectl get pluginconfigurations.klio.cnpg.io klio-config -o yaml"
  ui_pause

  ui_info "Check WAL streaming replication slot"
  ui_note "
Unlike traditional WAL archiving, Klio streams
WAL directly from PostgreSQL.

It uses a physical replication slot named klio.

We verify that the slot exists and is active.
"
  ui_command "kubectl cnpg psql klio-cluster -- -c \"SELECT slot_name, slot_type, active FROM pg_replication_slots;\""
  ui_pause

  ui_info "Generate PostgreSQL WAL activity"
  ui_command "kubectl cnpg psql klio-cluster -- -c 'SELECT pg_switch_wal();'"
  ui_pause

  ui_info "Check Klio Server logs"
  ui_command "kubectl logs klio-server-klio-0 -c server --tail=30"
  ui_pause

  ui_info "Clean previous pgbench initialization job"
  ui_command "kubectl delete job pgb-init --ignore-not-found"
  ui_pause

  ui_info "Initialize pgbench dataset"
  ui_note "
pgbench generates a standard PostgreSQL dataset.

Scale factor 1 creates approximately:
- 100,000 accounts
- 10 branches
- 100 tellers

This generates data and WAL traffic.
"
  ui_command "kubectl cnpg pgbench --job-name pgb-init klio-cluster -- --initialize --scale 1"
  ui_pause

  ui_info "Wait for pgbench initialization"
  ui_command "kubectl wait --for=condition=complete job/pgb-init --timeout=300s"
  ui_pause

  ui_info "Verify pgbench dataset"
  ui_command "kubectl cnpg psql klio-cluster -- app -c 'SELECT count(*) FROM pgbench_accounts;'"
  ui_pause

  ui_info "Verify WAL streaming slot"
  ui_command "kubectl cnpg psql klio-cluster -- -c \"SELECT slot_name, active, restart_lsn FROM pg_replication_slots WHERE slot_name = 'klio';\""
  ui_pause

  ui_info "Final PostgreSQL status"
  ui_command "kubectl cnpg status klio-cluster"
  ui_pause

  ui_success "PostgreSQL cluster deployed with Klio."
  ui_info "Next scenario: 04_backup.sh"
}

main() {
  clear
  show_instruct
  play
}

main "$@"
