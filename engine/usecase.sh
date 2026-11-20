# Shared by the scenarios under usecases/<name>/ and by the use case lifecycle (engine/usecase-run.sh). Sourced, not executed.
# Resolves where it is run from, so nothing has to be exported by hand and no path is hardcoded:
#   PROJECT_ROOT  repository root          USECASE       use case name (directory under usecases/)
#   USECASE_DIR   usecases/<name>          CLUSTER       its first Kind cluster, <prefix>-<usecase>-1
#   KUBE_CONTEXT  kubectl context of CLUSTER (contexts are always passed explicitly; the global one is not changed)
# A use case owns its clusters: the engine creates them (usecase_start) and deletes them (usecase_delete), as
# declared in usecases/<name>/usecase.yaml. A scenario finally changes into its own directory (the use case root),
# so relative paths such as manifests/cluster.yaml work from anywhere.

if [ -n "${PLAYGROUND_USECASE:-}" ]; then
  # Lifecycle run by the engine (engine/usecase-run.sh): the use case is named, nothing is derived from a caller.
  _UC_CALLER_DIR=""
  PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  USECASE="${PLAYGROUND_USECASE}"
else
  # -P: the physical path (a caller reached through /usecases would otherwise never find the project root by walking up).
  _UC_CALLER_DIR="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd -P)"
  PROJECT_ROOT="${_UC_CALLER_DIR}"
  # The project root is the directory holding the `playground` CLI and `engine/` (independent of the working directory).
  while [ ! -f "${PROJECT_ROOT}/playground" ] || [ ! -d "${PROJECT_ROOT}/engine" ]; do
    [ "${PROJECT_ROOT}" != "/" ] || { echo "Cannot locate the project root from ${_UC_CALLER_DIR}" >&2; return 1; }
    PROJECT_ROOT="$(dirname "${PROJECT_ROOT}")"
  done
  _UC_REL="${_UC_CALLER_DIR#"${PROJECT_ROOT}"/usecases/}"
  [ "${_UC_REL}" != "${_UC_CALLER_DIR}" ] || { echo "${_UC_CALLER_DIR} is not under usecases/" >&2; return 1; }
  USECASE="${_UC_REL%%/*}"
fi
USECASE_DIR="${PROJECT_ROOT}/usecases/${USECASE}"

source "${PROJECT_ROOT}/engine/lib/logger.sh"
source "${PROJECT_ROOT}/engine/lib/usecase-manifest.sh"
# The use case's provider (usecase.yaml provider.type, default kind) unless the environment forces one.
[ -n "${PLAYGROUND_PROVIDER:-}" ] || PLAYGROUND_PROVIDER="$(usecase_provider "${USECASE}")"
export PLAYGROUND_PROVIDER   # inherited by the scripts it starts (stacks/up.sh must use this use case's provider, not the default)
source "${PROJECT_ROOT}/engine/lib/provider.sh"     # the Kubernetes provider: the only way the engine reaches clusters
ENGINE_DIR="${PROJECT_ROOT}/engine"
CLUSTER="$(provider_cluster_name "${USECASE}" 1)"
KUBE_CONTEXT="$(provider_context "${CLUSTER}")"

# Context of the use case's cluster number $1.
usecase_context() { provider_context "$(provider_cluster_name "${USECASE}" "$1")"; }

# Address other clusters can use to reach cluster number $1 (what a PostgreSQL NodePort is reached on from another cluster).
usecase_cluster_address() { provider_endpoint cluster-address "$(provider_cluster_name "${USECASE}" "$1")"; }

# Fails with a hint unless cluster number $1 (default 1) of the use case answers.
usecase_require_cluster() {
  kubectl --context "$(usecase_context "${1:-1}")" --request-timeout=10s get nodes >/dev/null 2>&1 ||
    die "Cluster $(provider_cluster_name "${USECASE}" "${1:-1}") is not reachable. Run: playground usecase start ${USECASE}"
}

# Create the use case's clusters if missing (an incompatible existing one stops with an error),
# then install the services its usecase.yaml enables (cert-manager, MinIO, Prometheus, Grafana) independently on each.
# Usage: usecase_provision <count> <workers>
usecase_provision() {
  local count="$1" workers="$2" i names=()
  for (( i = 1; i <= count; i++ )); do names+=("$(provider_cluster_name "${USECASE}" "${i}")"); done
  provider_create "${workers}" "${names[@]}"
  # A provider that does not own its clusters (external) installs no stack unless the manifest asks (it never does: services are refused).
  [ "${PLAYGROUND_PROVIDER}" != external ] || [ -n "$(usecase_services "${USECASE}")" ] || return 0
  PLATFORM_SERVICES="$(usecase_services "${USECASE}")" bash "${ENGINE_DIR}/stacks/up.sh" "${names[@]}"
}

# Delete every Kind cluster owned by this use case, and nothing else (confirmation unless FORCE=1).
# Deleting a cluster removes everything in it (Helm releases, MinIO data, PostgreSQL volumes).
usecase_delete() {
  local answer="" clusters
  mapfile -t clusters < <(provider_list "${USECASE}")
  if [ "${#clusters[@]}" -eq 0 ]; then
    log_info "Use case ${USECASE} has no cluster, nothing to delete"
    return 0
  fi
  if [ "${PLAYGROUND_PROVIDER}" = external ]; then   # an external cluster is only detached, never deleted (no confirmation needed)
    provider_destroy "${clusters[@]}"
    return 0
  fi
  log_section "Clusters of use case ${USECASE}"
  printf '%s\n' "${clusters[@]}" | log_stream
  if [ "${FORCE:-0}" != "1" ]; then
    read -r -p "Delete these Kind clusters and everything in them? [y/N] " answer || true
    case "${answer}" in
      y|Y|yes|YES) ;;
      *) log_info "Aborted, nothing deleted"; return 0 ;;
    esac
  fi
  provider_destroy "${clusters[@]}"
}

_deployment_state() {  # <context> <namespace> <kubectl wait args...>
  if kubectl --context "$1" --request-timeout=10s -n "$2" wait --for=condition=Available deployment "${@:3}" --timeout=5s >/dev/null 2>&1; then
    printf 'Ready'
  else
    printf 'Not ready / not installed'
  fi
}

# True when usecase.yaml enables the service ($1: cert_manager | minio | prometheus | grafana).
usecase_service_enabled() { [ "$(usecase_config "${USECASE}" "services.$1")" = true ]; }

# Start a use case: its Kind clusters, nodes, networking and the platform services it enables (cert-manager, MinIO, Prometheus, Grafana), as declared in
# usecase.yaml. No PostgreSQL operator, plugin or database is installed: the scenarios do that.
usecase_start() {
  local count workers reason clusters names=() i
  reason="$(usecase_manifest_check "${USECASE}")" || die "${reason}"
  count="$(usecase_config "${USECASE}" infrastructure.clusters)"; count="${count:-1}"
  workers="$(usecase_config "${USECASE}" infrastructure.workers_per_cluster)"; workers="${workers:-1}"
  log_section "Installing use case ${USECASE}"
  usecase_provision "${count}" "${workers}"
  if [ "${count}" -gt 1 ]; then
    for (( i = 1; i <= count; i++ )); do names+=("$(provider_cluster_name "${USECASE}" "${i}")"); done
    provider_validate_connectivity "${names[@]}"
  fi
  log_section "Use case ${USECASE} is ready"
  mapfile -t clusters < <(provider_list "${USECASE}")
  INFO_SERVICES="$(usecase_services "${USECASE}")" provider_info "${clusters[@]}"
  if usecase_service_enabled minio; then
    log_info "URLs above are for your host browser. Workloads inside Kubernetes use the in-cluster MinIO endpoint of their own cluster:"
    log_info "  http://minio.object-storage.svc.cluster.local:9000 (bucket cnpg)"
  fi
  if [ "${PLAYGROUND_PROVIDER}" != external ]; then
    log_info "Operators and plugins are not installed by Start: the scenarios install them."
    log_info "Run the scenarios from this terminal: ls usecases/${USECASE}"
  else
    log_info "Nothing was created or installed on the external cluster. Open the use case terminal: kubectl and oc use context $(usecase_context 1)."
  fi
}

# Read-only status of every cluster of the use case: nodes, shared platform services, access URLs, scenarios.
usecase_status() {
  local clusters name context file
  mapfile -t clusters < <(provider_list "${USECASE}")
  if [ "${#clusters[@]}" -eq 0 ]; then
    log_warn "Use case ${USECASE} has no cluster. Run: playground usecase start ${USECASE}"
    return 0
  fi
  for name in "${clusters[@]}"; do
    context="$(provider_context "${name}")"
    provider_connect "${name}"
    log_section "Cluster ${name}"
    log_run kubectl --context "${context}" --request-timeout=10s get nodes ||
      { log_error "Cluster ${name} is unreachable"; continue; }
    # Only the services the manifest requests are reported: a disabled one is neither missing nor unhealthy.
    if usecase_service_enabled cert_manager; then
      log_info "cert-manager:        $(_deployment_state "${context}" cert-manager --all)"
    fi
    if usecase_service_enabled prometheus; then
      log_info "Prometheus:          $(_deployment_state "${context}" monitoring -l app=kube-prometheus-stack-operator)"
    fi
    if usecase_service_enabled grafana; then
      log_info "Grafana:             $(_deployment_state "${context}" monitoring -l app.kubernetes.io/name=grafana)"
    fi
    if usecase_service_enabled minio; then
      log_info "MinIO:               $(_deployment_state "${context}" object-storage minio)"
    fi
  done
  INFO_SERVICES="$(usecase_services "${USECASE}")" provider_info "${clusters[@]}"
  log_section "Available scenarios"
  for file in "${USECASE_DIR}"/[0-9]*.sh; do
    log_info "usecases/${USECASE}/$(basename "${file}")"
  done
}

[ -z "${_UC_CALLER_DIR}" ] || cd "${_UC_CALLER_DIR}"
