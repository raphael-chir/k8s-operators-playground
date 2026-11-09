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

source "${PROJECT_ROOT}/engine/infrastructure/kind/common.sh"
KIND_DIR="${PROJECT_ROOT}/engine/infrastructure/kind"
CLUSTER="$(cluster_name "${USECASE}" 1)"
KUBE_CONTEXT="$(cluster_context "${CLUSTER}")"

# Context of the use case's cluster number $1.
usecase_context() { cluster_context "$(cluster_name "${USECASE}" "$1")"; }

# Fails with a hint unless cluster number $1 (default 1) of the use case answers.
usecase_require_cluster() {
  kubectl --context "$(usecase_context "${1:-1}")" --request-timeout=10s get nodes >/dev/null 2>&1 ||
    die "Cluster $(cluster_name "${USECASE}" "${1:-1}") is not reachable. Run: playground usecase start ${USECASE}"
}

# Create the use case's clusters if missing (an incompatible existing one stops with an error),
# then install the services its usecase.yaml enables (cert-manager, MinIO, Prometheus, Grafana) independently on each.
# Usage: usecase_provision <count> <workers>
usecase_provision() {
  local count="$1" workers="$2" i names=()
  for (( i = 1; i <= count; i++ )); do names+=("$(cluster_name "${USECASE}" "${i}")"); done
  WORKERS="${workers}" bash "${KIND_DIR}/up.sh" "${names[@]}"
  PLATFORM_SERVICES="$(usecase_services "${USECASE}")" bash "${KIND_DIR}/platform-up.sh" "${names[@]}"
}

# Delete every Kind cluster owned by this use case, and nothing else (confirmation unless FORCE=1).
# Deleting a cluster removes everything in it (Helm releases, MinIO data, PostgreSQL volumes).
usecase_delete() {
  local answer="" clusters
  mapfile -t clusters < <(usecase_clusters "${USECASE}")
  if [ "${#clusters[@]}" -eq 0 ]; then
    log_info "Use case ${USECASE} has no cluster, nothing to delete"
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
  bash "${KIND_DIR}/down.sh" "${clusters[@]}"
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
  local count workers reason clusters
  reason="$(usecase_manifest_check "${USECASE}")" || die "${reason}"
  count="$(usecase_config "${USECASE}" infrastructure.clusters)"
  workers="$(usecase_config "${USECASE}" infrastructure.workers_per_cluster)"
  log_section "Installing use case ${USECASE}"
  usecase_provision "${count}" "${workers}"
  [ "${count}" -le 1 ] || usecase_validate_connectivity "${count}"
  log_section "Use case ${USECASE} is ready"
  mapfile -t clusters < <(usecase_clusters "${USECASE}")
  INFO_SERVICES="$(usecase_services "${USECASE}")" bash "${KIND_DIR}/info.sh" "${clusters[@]}"
  if usecase_service_enabled minio; then
    log_info "URLs above are for your host browser. Workloads inside Kubernetes use the in-cluster MinIO endpoint of their own cluster:"
    log_info "  http://minio.object-storage.svc.cluster.local:9000 (bucket cnpg)"
  fi
  log_info "Operators and plugins are not installed by Start: scenarios (or platform/operators) install them."
  log_info "Run the scenarios from this terminal: ls usecases/${USECASE}"
}

# Prints the IP of a control-plane container on the Kind Docker network (empty if not attached).
_control_plane_ip() {
  docker inspect -f "{{with index .NetworkSettings.Networks \"${KIND_NETWORK}\"}}{{.IPAddress}}{{end}}" \
    "$(cluster_name "${USECASE}" "$1")-control-plane" 2>/dev/null || true
}

# Requires HTTP 200 and an "ok" body from the Kubernetes API readiness endpoint of cluster $2,
# requested from inside the control-plane container of cluster $1.
_check_api_reachable() {
  local from="$1" to="$2" ip response
  ip="$(_control_plane_ip "${to}")"
  response="$(docker exec "$(cluster_name "${USECASE}" "${from}")-control-plane" \
    curl -sk --connect-timeout 3 --max-time 10 -w '\n%{http_code}' "https://${ip}:6443/readyz" 2>/dev/null || true)"
  if [ "${response##*$'\n'}" = "200" ] && [ "${response%%$'\n'*}" = "ok" ]; then
    log_success "Cluster ${from} -> Cluster ${to}: Kubernetes API reachable"
  else
    log_error "Cluster ${from} -> Cluster ${to}: Kubernetes API unreachable (https://${ip:-<no ip>}:6443/readyz)"
    return 1
  fi
}

# Several clusters: every control plane is on the Kind Docker network and every cluster's API answers from every other.
usecase_validate_connectivity() {   # <cluster count>
  local count="$1" n m failed=0
  log_section "Validating inter-cluster connectivity"
  for (( n = 1; n <= count; n++ )); do
    [ -n "$(_control_plane_ip "${n}")" ] || {
      log_error "Cluster ${n} is not connected to Docker network '${KIND_NETWORK}'"
      failed=1
    }
  done
  if [ "${failed}" -eq 0 ]; then
    log_success "All ${count} clusters connected to Docker network '${KIND_NETWORK}'"
    for (( n = 1; n <= count; n++ )); do
      for (( m = 1; m <= count; m++ )); do
        [ "${n}" = "${m}" ] || _check_api_reachable "${n}" "${m}" || failed=1
      done
    done
  fi
  [ "${failed}" -eq 0 ] || die "Inter-cluster connectivity validation failed"
  log_success "Inter-cluster connectivity validated"
}

# Read-only status of every cluster of the use case: nodes, shared platform services, access URLs, scenarios.
usecase_status() {
  local clusters name context file
  mapfile -t clusters < <(usecase_clusters "${USECASE}")
  if [ "${#clusters[@]}" -eq 0 ]; then
    log_warn "Use case ${USECASE} has no cluster. Run: playground usecase start ${USECASE}"
    return 0
  fi
  join_kind_network
  for name in "${clusters[@]}"; do
    context="$(cluster_context "${name}")"
    write_kubeconfig "${name}"
    log_section "Cluster ${name}"
    log_run kubectl --context "${context}" --request-timeout=10s get nodes -L playground.edb.io/role ||
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
  INFO_SERVICES="$(usecase_services "${USECASE}")" bash "${KIND_DIR}/info.sh" "${clusters[@]}"
  log_section "Available scenarios"
  for file in "${USECASE_DIR}"/[0-9]*.sh; do
    log_info "usecases/${USECASE}/$(basename "${file}")"
  done
}

[ -z "${_UC_CALLER_DIR}" ] || cd "${_UC_CALLER_DIR}"
