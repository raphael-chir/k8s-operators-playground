#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../engine/lib/ui.sh"
source "${SCRIPT_DIR}/../../engine/usecase.sh"
source "${SCRIPT_DIR}/../../.env"

CLUSTER="pge-tde-openbao"
MARKER="CONFIDENTIAL_OPENBAO_TDE_2026"

show_instruct() {
  ui_note "
# 05 / Verify PostgreSQL TDE with OpenBao Transit

Validate two levels of encryption:

1. PostgreSQL TDE
   - AES-256 encryption
   - Data readable through SQL
   - No plaintext in physical data files

2. OpenBao Transit
   - PostgreSQL DEK wrapped with Transit
   - Encrypted DEK stored in key.bin
   - Transit key: pg-tde

Architecture:

PostgreSQL data
      |
      v
TDE encryption (DEK)
      |
      v
EDB Vault Helper
      |
      v
OpenBao Transit (KEK)
      |
      v
pg_encryption/key.bin
"
  ui_pause
}

play() {
  local POD REL_PATH DATA_DIR FILE KEY_FILE TDE_LENGTH

  POD=$(kubectl get cluster "$CLUSTER" \
    -o jsonpath='{.status.currentPrimary}')

  KEY_FILE="/var/lib/postgresql/data/pgdata/pg_encryption/key.bin"

  ui_info "Checking PostgreSQL cluster"

  ui_command "kubectl get cluster $CLUSTER"

  ui_pause

  ui_info "Checking TDE encryption"

  ui_command "kubectl exec $POD -c postgres -- pg_controldata /var/lib/postgresql/data/pgdata | grep -E 'Data encryption version|Data encryption key length'"

  TDE_LENGTH=$(kubectl exec "$POD" -c postgres -- \
    pg_controldata /var/lib/postgresql/data/pgdata |
    awk -F: '/Data encryption key length/ {gsub(/ /,"",$2); print $2}')

  [[ "$TDE_LENGTH" == "256" ]] || {
    ui_error "TDE AES-256 is not enabled"
    return 1
  }

  ui_pause

  ui_info "Creating test data"

  ui_command "kubectl exec $POD -c postgres -- pgbench -i -s 1 -U postgres postgres"

  ui_command "kubectl exec $POD -c postgres -- psql -U postgres -c \"UPDATE pgbench_accounts SET filler = '$MARKER' WHERE aid = 1; CHECKPOINT;\""

  ui_pause

  ui_info "Reading data through PostgreSQL"

  ui_command "kubectl exec $POD -c postgres -- psql -U postgres -c \"SELECT aid, filler FROM pgbench_accounts WHERE aid = 1;\""

  ui_pause

  ui_info "Inspecting physical PostgreSQL data"

  REL_PATH=$(kubectl exec "$POD" -c postgres -- \
    psql -U postgres -Atc \
    "SELECT pg_relation_filepath('pgbench_accounts')")

  DATA_DIR=$(kubectl exec "$POD" -c postgres -- \
    psql -U postgres -Atc "SHOW data_directory")

  FILE="${DATA_DIR}/${REL_PATH}"

  ui_command "kubectl exec $POD -c postgres -- hexdump -C -n 256 $FILE"

  if kubectl exec "$POD" -c postgres -- \
    grep -aqF "$MARKER" "$FILE"; then
    ui_error "Plaintext found in PostgreSQL data file"
    return 1
  fi

  ui_success "No plaintext found in physical data file"

  ui_pause

  ui_info "Checking encrypted PostgreSQL DEK"

  ui_command "kubectl exec $POD -c postgres -- ls -lh $KEY_FILE"

  ui_command "kubectl exec $POD -c postgres -- head -c 9 $KEY_FILE"

  echo

  if [[ "$(kubectl exec "$POD" -c postgres -- head -c 9 "$KEY_FILE")" != "vault:v1:" ]]; then
    ui_error "DEK is not wrapped using OpenBao Transit"
    return 1
  fi

  ui_success "PostgreSQL DEK wrapped using OpenBao Transit"

  ui_pause

  ui_info "Checking OpenBao Transit key"

  ui_command "kubectl exec openbao-0 -- bao read transit/keys/pg-tde"

  ui_pause

  ui_success "PostgreSQL TDE with OpenBao Transit successfully verified"
}

main() {
  clear
  show_instruct
  play
}

main "$@"
