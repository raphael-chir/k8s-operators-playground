#!/usr/bin/env bash
# Show the nodes of the named clusters (default: every playground cluster). Read-only apart from kubeconfig.
# Usage: status.sh [cluster...]
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

require_docker
if [ "$#" -gt 0 ]; then
  clusters=("$@")
  for name in "${clusters[@]}"; do require_managed_name "${name}"; done
else
  mapfile -t clusters < <(managed_clusters)
fi
[ "${#clusters[@]}" -gt 0 ] || die "No ${CLUSTER_PREFIX}-<name>-<n> cluster found"

join_kind_network
rc=0
for name in "${clusters[@]}"; do
  log_section "Cluster ${name}"
  if ! cluster_exists "${name}"; then log_error "Cluster ${name} does not exist"; rc=1; continue; fi
  write_kubeconfig "${name}"
  log_run kubectl --context "$(cluster_context "${name}")" get nodes -o wide || {
    log_error "Cluster ${name} exists but its API server is unreachable"; rc=1; }
done
[ "${rc}" -eq 0 ] || exit 1
log_success "All listed clusters are reachable"
