# Kubernetes provider contract, Kind implementation. Sourced by engine/lib/provider.sh, never executed.
#
# Everything about Kind and Docker (clusters, nodes, the "kind" Docker network, container names, host ports) stays in
# this directory. The generic engine (usecase.sh, usecase-*.sh, managed-clusters.sh, terminal.sh, entrypoint.sh,
# infra-run.sh, stacks/up.sh) calls only the functions below. A cluster is always an explicit name; there is no
# "all clusters" destroy. A new provider implements the same functions in engine/providers/<name>/provider.sh.
#
#   Naming and ownership
#     provider_cluster_name <usecase> <index>   name of cluster <index> of a use case
#     provider_context <cluster>                 kubectl context of a cluster
#     provider_context_id <context>              the cluster behind a context, without the provider's naming prefix
#                                                (kind-cnpg-lab-<usecase>-<n> -> <usecase>-<n>); stable, used in names
#     provider_require_managed_name <cluster>    dies unless the name is a playground cluster (never touch a foreign one)
#   Discovery (read-only)
#     provider_check_available                   0, or 2 with the reason on stderr: "cannot tell" is never "none"
#     provider_require_runtime                   dies with a hint unless the provider's runtime answers
#     provider_list [usecase]                    existing playground clusters (of one use case), one per line
#     provider_exists <cluster>                  0 if the cluster exists
#   Lifecycle
#     provider_init                              once per Playground container start (never fatal)
#     provider_create <workers> <cluster>...     create (or reuse a compatible) clusters and connect to them; never recreates
#     provider_connect <cluster>                 make the cluster reachable from here and write its kubeconfig entry
#     provider_status [cluster...]               nodes of the clusters (default: all)
#     provider_info [cluster...]                 nodes and the host URLs of the platform services (INFO_SERVICES limits them)
#     provider_destroy <cluster>...              delete the named clusters and everything in them
#     provider_validate_connectivity <cluster>...  every cluster can reach every other cluster's Kubernetes API
#   Endpoints (each kind answers one question)
#     provider_endpoint host-port <cluster> <port>   port published on the HOST (a browser) for a node port of the cluster
#     provider_endpoint cluster-address <cluster>    address the OTHER clusters use to reach this cluster's nodes (NodePort
#                                                    services, e.g. PostgreSQL replication); empty if unknown
#   Kubernetes API access from the Playground is the kubeconfig that provider_connect writes (context from provider_context).
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
PROVIDER_KIND_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

provider_cluster_name()          { cluster_name "$@"; }
provider_context()               { cluster_context "$1"; }
provider_context_id()            { local id="${1#kind-}"; printf '%s' "${id#"${CLUSTER_PREFIX}"-}"; }
provider_require_managed_name()  { require_managed_name "$1"; }

provider_check_available() {
  docker info >/dev/null 2>&1 || { echo "Docker Engine unreachable" >&2; return 2; }
  kind get clusters >/dev/null 2>&1 || { echo "kind could not list clusters" >&2; return 2; }
}
provider_require_runtime()       { require_docker; }
provider_list()                  { if [ "$#" -gt 0 ]; then usecase_clusters "$1"; else managed_clusters; fi; }
provider_exists()                { cluster_exists "$1"; }

# The Playground container must be on the "kind" Docker network before ttyd starts (see engine/entrypoint.sh).
provider_init() {
  ( ensure_kind_network ) || log_warn "Could not join the '${KIND_NETWORK}' network; Kind access will be set up on first use"
  return 0
}
provider_create()                { WORKERS="${1:-}" bash "${PROVIDER_KIND_DIR}/up.sh" "${@:2}"; }
provider_connect()               { join_kind_network; write_kubeconfig "$1"; }
provider_status()                { bash "${PROVIDER_KIND_DIR}/status.sh" "$@"; }
provider_info()                  { bash "${PROVIDER_KIND_DIR}/info.sh" "$@"; }
provider_destroy()               { bash "${PROVIDER_KIND_DIR}/down.sh" "$@"; }

provider_endpoint() {
  case "$1" in
    host-port)       host_port "$2" "$3" ;;
    cluster-address) _kind_control_plane_ip "$2" ;;
    *) echo "provider_endpoint: unknown endpoint kind '$1' (host-port, cluster-address)" >&2; return 2 ;;
  esac
}

# IP of a cluster's control-plane container on the Kind Docker network (empty if not attached).
_kind_control_plane_ip() {
  docker inspect -f "{{with index .NetworkSettings.Networks \"${KIND_NETWORK}\"}}{{.IPAddress}}{{end}}" \
    "$1-control-plane" 2>/dev/null || true
}

# Requires HTTP 200 and an "ok" body from the Kubernetes API readiness endpoint of cluster <to>, requested from
# inside the control-plane container of cluster <from>. Arguments: <from name> <to name> <from number> <to number>.
_kind_check_api_reachable() {
  local from="$1" to="$2" ip response
  ip="$(_kind_control_plane_ip "${to}")"
  response="$(docker exec "${from}-control-plane" \
    curl -sk --connect-timeout 3 --max-time 10 -w '\n%{http_code}' "https://${ip}:6443/readyz" 2>/dev/null || true)"
  if [ "${response##*$'\n'}" = "200" ] && [ "${response%%$'\n'*}" = "ok" ]; then
    log_success "Cluster $3 -> Cluster $4: Kubernetes API reachable"
  else
    log_error "Cluster $3 -> Cluster $4: Kubernetes API unreachable (https://${ip:-<no ip>}:6443/readyz)"
    return 1
  fi
}

# Several clusters: every control plane is on the Kind Docker network and every cluster's API answers from every other.
provider_validate_connectivity() {
  local names=("$@") count="$#" n m failed=0
  log_section "Validating inter-cluster connectivity"
  for (( n = 1; n <= count; n++ )); do
    [ -n "$(_kind_control_plane_ip "${names[n-1]}")" ] || {
      log_error "Cluster ${n} is not connected to Docker network '${KIND_NETWORK}'"
      failed=1
    }
  done
  if [ "${failed}" -eq 0 ]; then
    log_success "All ${count} clusters connected to Docker network '${KIND_NETWORK}'"
    for (( n = 1; n <= count; n++ )); do
      for (( m = 1; m <= count; m++ )); do
        [ "${n}" = "${m}" ] || _kind_check_api_reachable "${names[n-1]}" "${names[m-1]}" "${n}" "${m}" || failed=1
      done
    done
  fi
  [ "${failed}" -eq 0 ] || die "Inter-cluster connectivity validation failed"
  log_success "Inter-cluster connectivity validated"
}
