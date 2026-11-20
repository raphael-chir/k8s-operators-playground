#!/usr/bin/env bash
# Delete the named Kind clusters (and everything in them). Always explicit: there is no delete-all.
# Names outside the playground pattern are refused. A cluster that does not exist is not an error.
# Usage: down.sh <cluster>...
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

[ "$#" -gt 0 ] || die "Usage: $0 <cluster>...  (explicit names only)"
for name in "$@"; do require_managed_name "${name}"; done
require_docker

for name in "$@"; do
  if cluster_exists "${name}"; then
    log_section "Deleting cluster ${name}"
    log_run kind delete cluster --name "${name}"
    log_success "Cluster ${name} deleted"
  else
    log_info "Cluster ${name} does not exist, nothing to delete"
  fi
done
