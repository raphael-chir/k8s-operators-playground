#!/usr/bin/env bash
# Create the named Kind clusters (WORKERS workers each, default 1) and make them usable. Safe to rerun.
# An existing cluster is reused only if compatible; it is never recreated implicitly.
# Usage: up.sh <cluster>...      e.g. WORKERS=3 up.sh cnpg-lab-cnpg-standard-1
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

[ "$#" -gt 0 ] || die "Usage: $0 <cluster>...  (e.g. ${CLUSTER_PREFIX}-mytest-1)"
[[ "${WORKERS}" =~ ^[1-9][0-9]*$ ]] || die "WORKERS must be a positive number (got '${WORKERS}')"
for name in "$@"; do require_managed_name "${name}"; done

check_prerequisites

for name in "$@"; do
  if cluster_exists "${name}"; then
    require_compatible_cluster "${name}" "${WORKERS}"
    log_info "Cluster ${name} already exists and is compatible, skipping creation"
  else
    log_section "Creating cluster ${name}"
    build_kind_config "${name}" | log_run kind create cluster --name "${name}" --config -
  fi
done

log_section "Connecting to the Kubernetes API"
join_kind_network
for name in "$@"; do
  context="$(cluster_context "${name}")"
  write_kubeconfig "${name}"
  log_info "Waiting for nodes of ${name} to be Ready"
  log_run kubectl --context "${context}" wait --for=condition=Ready node --all --timeout=300s
  label_nodes "${context}"
  log_run kubectl --context "${context}" get nodes -L playground.edb.io/role
done
log_success "Kubernetes cluster(s) ready: $*"
