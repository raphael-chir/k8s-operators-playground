#!/usr/bin/env bash
# Install the shared platform services independently on each named cluster. Safe to rerun.
# Usage: [PLATFORM_SERVICES=cert_manager,minio,prometheus,grafana] platform-up.sh <cluster>...
# PLATFORM_SERVICES (comma separated, any subset) selects what is installed; set but empty = nothing. Unset = the
# standalone default: MinIO, Prometheus and Grafana (cert-manager only when asked). A use case start passes the
# services of its usecase.yaml. Operators and plugins are never installed here.
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
PLATFORM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../platform" && pwd)"

[ "$#" -gt 0 ] || die "Usage: $0 <cluster>..."
SERVICES="${PLATFORM_SERVICES-minio,prometheus,grafana}"
for service in ${SERVICES//,/ }; do
  case " ${PLATFORM_SERVICE_KEYS} " in *" ${service} "*) ;; *) die "Unknown service '${service}' (expected: ${PLATFORM_SERVICE_KEYS// /, })" ;; esac
done
wanted() { case ",${SERVICES}," in *",$1,"*) return 0 ;; *) return 1 ;; esac; }
for name in "$@"; do require_managed_name "${name}"; done
require_docker
for name in "$@"; do cluster_exists "${name}" || die "Cluster ${name} does not exist. Create it first (playground infra up ${name})"; done
join_kind_network

PROMETHEUS_ENABLED=false; GRAFANA_ENABLED=false
wanted prometheus && PROMETHEUS_ENABLED=true
wanted grafana && GRAFANA_ENABLED=true
export PROMETHEUS_ENABLED GRAFANA_ENABLED

for name in "$@"; do
  write_kubeconfig "${name}"
  context="$(cluster_context "${name}")"
  if wanted cert_manager; then bash "${PLATFORM_DIR}/cert-manager/install.sh" "${context}"; fi
  if wanted minio; then bash "${PLATFORM_DIR}/object-storage/install.sh" "${context}"; fi
  if wanted prometheus || wanted grafana; then bash "${PLATFORM_DIR}/monitoring/install.sh" "${context}"; fi
done
log_success "Platform ready on: $* (services: ${SERVICES:-none})"
