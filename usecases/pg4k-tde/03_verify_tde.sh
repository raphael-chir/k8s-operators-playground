#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../engine/lib/ui.sh"
source "${SCRIPT_DIR}/../../engine/usecase.sh"
source "${SCRIPT_DIR}/../../.env"

show_instruct() {
  ui_note "
# 03 / Compare PostgreSQL with and without TDE

Demonstrate how Transparent Data Encryption protects
PostgreSQL data at rest.

## Objectives
- Insert identical data into two PostgreSQL clusters
- Read the data through SQL
- Force data persistence with CHECKPOINT
- Identify the physical PostgreSQL files
- Locate plaintext using grep
- Inspect physical data using hexdump

## Expected outcome
- pge: plaintext is visible in the physical file
- pge-tde: plaintext is not visible in the encrypted file
- Both clusters return identical data through SQL
"
  ui_pause
}

play() {
  local MARKER="CONFIDENTIAL_TDE_TEST_2026"
  local CLUSTER POD REL_PATH DATA_DIR FILE OFFSET RESULT

  ui_info "Switch to the playground Kubernetes context"
  ui_command "kubectl config use-context ${KUBE_CONTEXT}"
  ui_pause

  for CLUSTER in pge pge-tde; do

    POD=$(kubectl get cluster "$CLUSTER" -o jsonpath='{.status.currentPrimary}')
    [[ -n "$POD" ]] || { echo "ERROR: Primary pod not found for $CLUSTER"; return 1; }

    ui_info "PostgreSQL cluster: $CLUSTER"
    ui_command "kubectl get cluster $CLUSTER"
    ui_pause

    ui_info "Initialize pgbench with 100,000 accounts"
    ui_command "kubectl exec $POD -c postgres -- pgbench -i -s 1 -U postgres postgres"
    ui_pause

    ui_info "Insert recognizable data"
    ui_command "kubectl exec $POD -c postgres -- psql -U postgres -c \"UPDATE pgbench_accounts SET filler = '$MARKER' WHERE aid = 1;\""
    ui_pause

    ui_info "Read data through SQL"
    ui_command "kubectl exec $POD -c postgres -- psql -U postgres -c 'SELECT aid, filler FROM pgbench_accounts WHERE aid = 1;'"
    ui_pause

    ui_info "Force PostgreSQL to write modified pages to disk"
    ui_command "kubectl exec $POD -c postgres -- psql -U postgres -c 'CHECKPOINT;'"
    ui_pause

    ui_info "Identify the PostgreSQL relation file"
    ui_command "kubectl exec $POD -c postgres -- psql -U postgres -c \"SELECT pg_relation_filepath('pgbench_accounts');\""
    ui_pause

    ui_info "Identify the PostgreSQL data directory"
    ui_command "kubectl exec $POD -c postgres -- psql -U postgres -c 'SHOW data_directory;'"
    ui_pause

    REL_PATH=$(kubectl exec "$POD" -c postgres -- psql -U postgres -Atc \
      "SELECT pg_relation_filepath('pgbench_accounts');")

    DATA_DIR=$(kubectl exec "$POD" -c postgres -- psql -U postgres -Atc \
      "SHOW data_directory;")

    FILE="${DATA_DIR}/${REL_PATH}"

    ui_info "Search for plaintext in the physical file"
    ui_command "kubectl exec $POD -c postgres -- grep -aobF '$MARKER' $FILE || true"
    ui_pause

    RESULT=0
    OFFSET=$(kubectl exec "$POD" -c postgres -- grep -aobF "$MARKER" "$FILE" 2>/dev/null) || RESULT=$?

    if [[ "$CLUSTER" == "pge" ]]; then

      if [[ "$RESULT" -ne 0 ]]; then
        echo "ERROR: Plaintext not found in the unencrypted cluster"
        return 1
      fi

      OFFSET="${OFFSET%%:*}"

      ui_info "Inspect plaintext at offset $OFFSET"
      ui_command "kubectl exec $POD -c postgres -- hexdump -C -s $OFFSET -n 128 $FILE"
      ui_pause

      ui_success "Plaintext found in the unencrypted PostgreSQL file"

    else

      if [[ "$RESULT" -ne 1 ]]; then
        echo "ERROR: Unexpected result when inspecting encrypted data"
        return 1
      fi

      ui_info "Inspect encrypted PostgreSQL data"
      ui_command "kubectl exec $POD -c postgres -- hexdump -C -n 128 $FILE"
      ui_pause

      ui_success "No plaintext found in the encrypted PostgreSQL file"

    fi

  done

  ui_success "TDE comparison completed successfully"
}

main() {
  clear
  show_instruct
  play
}

main "$@"
