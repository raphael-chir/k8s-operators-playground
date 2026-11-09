#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../engine/lib/ui.sh"
source "${SCRIPT_DIR}/../../engine/usecase.sh"

CLUSTERS=(
  "cnpg-cluster"
  "restored-cnpg-cluster"
)

MINIO_PREFIXES=(
  "cnpg-cluster"
  "cnpg-cluster-pg18"
  "restored-cnpg-cluster"
)

MC_IMAGE="netiedge/minio-mc:RELEASE.2025-01-17T23-25-50Z"
MINIO_ENDPOINT="http://minio.object-storage.svc.cluster.local:9000"
MINIO_BUCKET="cnpg"

show_instruct() {
  ui_note "
# 99 / Reset Lab

Reset the CNPG Standard lab to its initial state.

## Objectives
- Delete PostgreSQL clusters and backups
- Delete pgbench workload jobs
- Remove backup data from MinIO
- Remove ObjectStore configuration and credentials

## Expected outcome
A clean lab ready to restart from scenario 01.

## Warning
This operation permanently deletes PostgreSQL data and backups.

Kind, operators, monitoring and MinIO remain installed.
"
  ui_pause
}

play() {
  local cluster prefix backup
  local minio_user minio_password

  ui_info "Current lab resources"
  ui_command "kubectl get clusters,backups,jobs || true"
  ui_pause

  if ! ui_confirm "Delete all PostgreSQL data and backups?"; then
    ui_warn "Reset cancelled."
    return 0
  fi

  ui_pause

  ui_info "Retrieve MinIO credentials"
  minio_user=$(kubectl get secret minio-secret \
    -o jsonpath='{.data.MINIO_ACCESS_KEY}' | base64 --decode)

  minio_password=$(kubectl get secret minio-secret \
    -o jsonpath='{.data.MINIO_SECRET_KEY}' | base64 --decode)

  ui_info "Delete CNPG backup resources"

  for cluster in "${CLUSTERS[@]}"; do
    while IFS= read -r backup; do
      [[ -n "$backup" ]] || continue
      ui_command "kubectl delete backup.postgresql.cnpg.io ${backup}"
    done < <(
      kubectl get backups.postgresql.cnpg.io \
        -o jsonpath="{range .items[?(@.spec.cluster.name=='${cluster}')]}{.metadata.name}{'\n'}{end}"
    )
  done

  ui_info "Delete pgbench jobs"
  ui_command "kubectl delete job pgb-init pgb-run --ignore-not-found"

  for cluster in "${CLUSTERS[@]}"; do
    ui_info "Delete PostgreSQL cluster: ${cluster}"
    ui_command "kubectl delete cluster.postgresql.cnpg.io ${cluster} --ignore-not-found --wait=true"
  done

  ui_info "Remove previous MinIO cleanup pod"
  kubectl delete pod minio-reset-mc --ignore-not-found --wait=true

  for prefix in "${MINIO_PREFIXES[@]}"; do
    ui_info "Purge MinIO backup prefix: ${prefix}"

    if kubectl run minio-reset-mc \
      --rm -i --quiet \
      --restart=Never \
      --image="${MC_IMAGE}" \
      --command -- sh -c "
        mc alias set minio '${MINIO_ENDPOINT}' '${minio_user}' '${minio_password}' &&
        mc rm --recursive --force --versions minio/${MINIO_BUCKET}/${prefix}/
      "
    then
      ui_success "MinIO prefix ${prefix} removed."
    else
      ui_error "Failed to purge MinIO prefix ${prefix}."
      ui_warn "MinIO secret and ObjectStore preserved for retry."
      return 1
    fi
  done

  ui_info "Delete ObjectStore configuration"
  ui_command "kubectl delete objectstores.barmancloud.cnpg.io minio-storage --ignore-not-found"

  ui_info "Delete MinIO credentials"
  ui_command "kubectl delete secret minio-secret --ignore-not-found"

  ui_info "Verify lab cleanup"
  ui_command "kubectl get clusters,backups,jobs || true"
  ui_pause

  ui_success "CNPG Standard lab reset completed."
  ui_info "Ready to restart from scenario 01."
}

main() {
  clear
  show_instruct
  play
}

main "$@"
