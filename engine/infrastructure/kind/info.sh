#!/usr/bin/env bash
# Show, for every playground cluster, node readiness and the host URLs of Grafana and MinIO.
# Ports are read from Docker (what the host actually listens on) and from the Services in the
# cluster (which NodePort each one uses). Nothing is stored.
# INFO_SERVICES (comma separated, e.g. minio,grafana; set by a use case) limits the services shown, so a disabled one is
# not reported as missing. Unset = show Grafana and MinIO, as the standalone `playground infra info` always did.
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

require_docker
# Usage: info.sh [cluster...]   (default: every playground cluster)
if [ "$#" -gt 0 ]; then
  clusters=("$@")
  for name in "${clusters[@]}"; do require_managed_name "${name}"; done
else
  mapfile -t clusters < <(managed_clusters)
fi
[ "${#clusters[@]}" -gt 0 ] || die "No ${CLUSTER_PREFIX}-<name>-<n> cluster found"
join_kind_network

# Usage: service_url <context> <cluster> <namespace> <service>; prints a URL or "Not installed".
service_url() {
  local node_port port
  node_port="$(kubectl --context "$1" --request-timeout=10s -n "$3" get svc "$4" \
    -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || true)"
  if [ -z "${node_port}" ]; then printf 'Not installed (run: playground infra platform-up)'; return; fi
  port="$(host_port "$2" "${node_port}")"
  if [ -z "${port}" ]; then printf 'No host port mapped (cluster created without port mappings)'; return; fi
  printf 'http://localhost:%s' "${port}"
}

shown() { case ",${INFO_SERVICES-minio,grafana}," in *",$1,"*) return 0 ;; *) return 1 ;; esac; }

for name in "${clusters[@]}"; do
  ctx="$(cluster_context "${name}")"
  write_kubeconfig "${name}" >/dev/null 2>&1 || true
  log_section "Cluster ${name}"
  log_info "Context:       ${ctx}"
  nodes="$(kubectl --context "${ctx}" --request-timeout=10s get nodes --no-headers 2>/dev/null || true)"
  if [ -z "${nodes}" ]; then
    log_error "Kubernetes: unreachable"
    continue
  fi
  total="$(grep -c . <<< "${nodes}")"
  ready="$(grep -c ' Ready' <<< "${nodes}" || true)"
  if [ "${ready}" = "${total}" ]; then
    log_success "Kubernetes: Ready (${ready}/${total} nodes)"
  else
    log_warn "Kubernetes: ${ready}/${total} nodes Ready"
  fi
  if shown grafana; then log_info "Grafana:       $(service_url "${ctx}" "${name}" monitoring prometheus-community-grafana)"; fi
  if shown minio; then
    log_info "MinIO Console: $(service_url "${ctx}" "${name}" object-storage minio-console)"
    log_info "MinIO S3 API:  $(service_url "${ctx}" "${name}" object-storage minio)"
  fi
done
if shown grafana && shown minio; then log_info "Credentials (Grafana and MinIO): admin / password. Bucket: cnpg"
elif shown grafana; then log_info "Credentials (Grafana): admin / password"
elif shown minio; then log_info "Credentials (MinIO): admin / password. Bucket: cnpg"; fi
