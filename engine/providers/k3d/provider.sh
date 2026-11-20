# Kubernetes provider contract, K3D implementation (internal: the Playground creates and deletes these clusters; usecase.yaml
# `provider: { type: internal, name: k3d }`). Sourced by engine/lib/provider.sh, never executed. The contract is documented in
# engine/providers/kind/provider.sh; everything k3d- and Docker-specific stays in this file.
#
# Topology and behaviour mirror Kind so the shared stacks and scenarios need no change:
#   * 1 server (control-plane) + WORKERS agents; clusters are named <CLUSTER_PREFIX>-<usecase>-<n>, context k3d-<cluster>;
#   * every cluster joins ONE Docker network (K3D_NETWORK) that the Playground container joins too, so the API is reached by Docker DNS
#     (https://k3d-<cluster>-serverlb:6443, no IP) and clusters reach each other's NodePorts;
#   * the server is tainted node-role.kubernetes.io/control-plane:NoSchedule and relabelled node-role.kubernetes.io/control-plane="" (k3s
#     uses the value "true"), which is what the stacks' nodeSelector and toleration expect; PostgreSQL stays on the agents;
#   * the platform NodePorts (engine/stacks/ports.sh) are published on random 127.0.0.1 ports of the host through the load balancer;
#   * per-index pod/service CIDRs, like Kind; storage is k3s's default local-path StorageClass; no k3s component is disabled.
CLUSTER_PREFIX="${CLUSTER_PREFIX:-cnpg-lab}"
PLAYGROUND_CONTAINER="${PLAYGROUND_CONTAINER:-cnpg-playground}"
K3D_NETWORK="${K3D_NETWORK:-k3d-playground}"
K3D_K3S_IMAGE="${K3D_K3S_IMAGE:-}"          # empty = the k3s release bundled with this k3d version
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/logger.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../stacks/ports.sh"

_k3d_regex_ok() { [[ "$1" =~ ^${CLUSTER_PREFIX}-[a-z0-9]+(-[a-z0-9]+)*-[0-9]+$ ]]; }
provider_cluster_name()          { printf '%s-%s-%s' "${CLUSTER_PREFIX}" "$1" "$2"; }
provider_context()               { printf 'k3d-%s' "$1"; }
provider_context_id()            { local id="${1#k3d-}"; printf '%s' "${id#"${CLUSTER_PREFIX}"-}"; }
provider_require_managed_name()  { _k3d_regex_ok "$1" || die "'$1' is not a playground cluster name (expected ${CLUSTER_PREFIX}-<name>-<number>)"; }

provider_check_available() {
  command -v k3d >/dev/null 2>&1 || { echo "k3d is not installed in this image (rebuild it: ./playground install)" >&2; return 2; }
  docker info >/dev/null 2>&1 || { echo "Docker Engine unreachable" >&2; return 2; }
  k3d cluster list >/dev/null 2>&1 || { echo "k3d could not list clusters" >&2; return 2; }
}
provider_require_runtime() {
  command -v k3d >/dev/null 2>&1 || die "k3d is not installed in this image (rebuild it: ./playground install)"
  docker info >/dev/null 2>&1 || die "Cannot reach the Docker Engine. Is /var/run/docker.sock mounted into this container?"
}

# Existing k3d clusters matching an extended regex, one per line, in numeric order.
_k3d_clusters() { { k3d cluster list -o json 2>/dev/null | jq -r '.[].name' || true; } | { grep -E "$1" || true; } | sort -V; }
provider_list() {
  if [ "$#" -gt 0 ]; then _k3d_clusters "^${CLUSTER_PREFIX}-$1-[0-9]+\$"
  else _k3d_clusters "^${CLUSTER_PREFIX}-[a-z0-9]+(-[a-z0-9]+)*-[0-9]+\$"; fi
}
provider_exists() { local existing; existing="$(_k3d_clusters '.')"; grep -Fxq -- "$1" <<< "${existing}"; }

# --- Docker network shared by all k3d clusters and the Playground container ---------------------------------------------------
_k3d_on_network() {
  docker inspect -f '{{json .NetworkSettings.Networks}}' "${PLAYGROUND_CONTAINER}" 2>/dev/null | jq -e --arg n "${K3D_NETWORK}" 'has($n)' >/dev/null
}
_k3d_ensure_network() {
  docker network inspect "${K3D_NETWORK}" >/dev/null 2>&1 || docker network create "${K3D_NETWORK}" >/dev/null || die "Could not create the '${K3D_NETWORK}' network"
  _k3d_on_network || docker network connect "${K3D_NETWORK}" "${PLAYGROUND_CONTAINER}" || die "Could not attach ${PLAYGROUND_CONTAINER} to '${K3D_NETWORK}'"
}
provider_init() { ( _k3d_ensure_network ) || log_warn "Could not join the '${K3D_NETWORK}' network; k3d access will be set up on first use"; return 0; }

# --- kubeconfig: merge the cluster and point it at the load balancer's Docker DNS name (the default 0.0.0.0:<port> is the host's) ---
_k3d_write_kubeconfig() {
  local name="$1" ctx; ctx="$(provider_context "$1")"
  log_run k3d kubeconfig merge "${name}" --kubeconfig-merge-default --kubeconfig-switch-context=false
  kubectl config set-cluster "${ctx}" --server="https://k3d-${name}-serverlb:6443" >/dev/null
}
provider_connect() { _k3d_ensure_network; _k3d_write_kubeconfig "$1"; }

# The server carries k3s's label node-role.kubernetes.io/control-plane="true"; the shared stacks select the Kubernetes convention (empty value).
_k3d_label_control_plane() {
  kubectl --context "$(provider_context "$1")" label nodes -l node-role.kubernetes.io/control-plane node-role.kubernetes.io/control-plane= --overwrite >/dev/null
}

# Create (or reuse a compatible) cluster, never recreate. $1 = workers, then the cluster names.
provider_create() {
  local workers="${1:-1}" name index nodes ctx port args
  shift
  [[ "${workers}" =~ ^[1-9][0-9]*$ ]] || die "WORKERS must be a positive number (got '${workers}')"
  [ "$#" -gt 0 ] || die "Usage: provider_create <workers> <cluster>..."
  for name in "$@"; do provider_require_managed_name "${name}"; done
  provider_require_runtime
  log_info "k3d: $(k3d version | head -n 1)"
  _k3d_ensure_network
  for name in "$@"; do
    if provider_exists "${name}"; then
      nodes="$(docker ps -a --filter "label=k3d.cluster=${name}" --format '{{.Label "k3d.role"}}' | grep -cE '^(server|agent)$' || true)"
      [ "${nodes}" -eq $(( workers + 1 )) ] ||
        die "Cluster ${name} exists with ${nodes} nodes, but $(( workers + 1 )) are required. Not recreating it: delete it explicitly with 'playground infra down ${name}'"
      log_info "Cluster ${name} already exists and is compatible, skipping creation"
    else
      index="${name##*-}"
      log_section "Creating cluster ${name}"
      args=(cluster create "${name}" --servers 1 --agents "${workers}" --network "${K3D_NETWORK}" --wait --timeout 300s
        --k3s-arg "--cluster-cidr=10.$(( 243 + index )).0.0/16@server:*" --k3s-arg "--service-cidr=10.$(( 95 + index )).0.0/16@server:*"
        --k3s-arg "--node-taint=node-role.kubernetes.io/control-plane=:NoSchedule@server:*"
        --k3s-arg "--tls-san=k3d-${name}-serverlb@server:*"
        --kubeconfig-update-default=false --kubeconfig-switch-context=false)
      for port in ${STACK_NODE_PORTS}; do args+=(--port "127.0.0.1::${port}@loadbalancer"); done
      [ -z "${K3D_K3S_IMAGE}" ] || args+=(--image "${K3D_K3S_IMAGE}")
      log_run k3d "${args[@]}"
    fi
  done
  log_section "Connecting to the Kubernetes API"
  for name in "$@"; do
    ctx="$(provider_context "${name}")"
    provider_connect "${name}"
    log_info "Waiting for nodes of ${name} to be Ready"
    log_run kubectl --context "${ctx}" wait --for=condition=Ready node --all --timeout=300s
    _k3d_label_control_plane "${name}"
    log_run kubectl --context "${ctx}" get nodes
  done
  log_success "Kubernetes cluster(s) ready: $*"
}

provider_status() {
  local name rc=0 clusters=("$@")
  provider_require_runtime
  [ "${#clusters[@]}" -gt 0 ] || mapfile -t clusters < <(provider_list)
  [ "${#clusters[@]}" -gt 0 ] || die "No ${CLUSTER_PREFIX}-<name>-<n> cluster found"
  for name in "${clusters[@]}"; do
    provider_require_managed_name "${name}"
    log_section "Cluster ${name}"
    provider_exists "${name}" || { log_error "Cluster ${name} does not exist"; rc=1; continue; }
    provider_connect "${name}"
    log_run kubectl --context "$(provider_context "${name}")" get nodes -o wide || { log_error "Cluster ${name} exists but its API server is unreachable"; rc=1; }
  done
  [ "${rc}" -eq 0 ] || return 1
  log_success "All listed clusters are reachable"
}

# Host port Docker published for a node port (through the load balancer container); empty if none.
_k3d_host_port() { local m; m="$(docker port "k3d-$1-serverlb" "$2/tcp" 2>/dev/null | head -n 1 || true)"; printf '%s' "${m##*:}"; }
_k3d_service_url() {   # <context> <cluster> <namespace> <service>
  local node_port port
  node_port="$(kubectl --context "$1" --request-timeout=10s -n "$3" get svc "$4" -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || true)"
  [ -n "${node_port}" ] || { printf 'Not installed (run: playground infra platform-up)'; return; }
  port="$(_k3d_host_port "$2" "${node_port}")"
  [ -n "${port}" ] || { printf 'No host port mapped (cluster created without port mappings)'; return; }
  printf 'http://localhost:%s' "${port}"
}
provider_info() {
  local name ctx nodes total ready clusters=("$@")
  provider_require_runtime
  [ "${#clusters[@]}" -gt 0 ] || mapfile -t clusters < <(provider_list)
  [ "${#clusters[@]}" -gt 0 ] || die "No ${CLUSTER_PREFIX}-<name>-<n> cluster found"
  _k3d_ensure_network
  shown() { case ",${INFO_SERVICES-minio,grafana}," in *",$1,"*) return 0 ;; *) return 1 ;; esac; }
  for name in "${clusters[@]}"; do
    provider_require_managed_name "${name}"
    ctx="$(provider_context "${name}")"
    _k3d_write_kubeconfig "${name}" >/dev/null 2>&1 || true
    log_section "Cluster ${name}"
    log_info "Context:       ${ctx}"
    nodes="$(kubectl --context "${ctx}" --request-timeout=10s get nodes --no-headers 2>/dev/null || true)"
    [ -n "${nodes}" ] || { log_error "Kubernetes: unreachable"; continue; }
    total="$(grep -c . <<< "${nodes}")"; ready="$(grep -c ' Ready' <<< "${nodes}" || true)"
    if [ "${ready}" = "${total}" ]; then log_success "Kubernetes: Ready (${ready}/${total} nodes)"; else log_warn "Kubernetes: ${ready}/${total} nodes Ready"; fi
    if shown grafana; then log_info "Grafana:       $(_k3d_service_url "${ctx}" "${name}" monitoring prometheus-community-grafana)"; fi
    if shown minio; then
      log_info "MinIO Console: $(_k3d_service_url "${ctx}" "${name}" object-storage minio-console)"
      log_info "MinIO S3 API:  $(_k3d_service_url "${ctx}" "${name}" object-storage minio)"
    fi
  done
  if shown grafana && shown minio; then log_info "Credentials (Grafana and MinIO): admin / password. Bucket: cnpg"
  elif shown grafana; then log_info "Credentials (Grafana): admin / password"
  elif shown minio; then log_info "Credentials (MinIO): admin / password. Bucket: cnpg"; fi
}

# Delete the named clusters (and everything in them). Explicit names only; a missing cluster is not an error. The shared network stays.
provider_destroy() {
  local name
  [ "$#" -gt 0 ] || die "Usage: provider_destroy <cluster>...  (explicit names only)"
  for name in "$@"; do provider_require_managed_name "${name}"; done
  provider_require_runtime
  for name in "$@"; do
    if provider_exists "${name}"; then
      log_section "Deleting cluster ${name}"
      log_run k3d cluster delete "${name}"
      log_success "Cluster ${name} deleted"
    else
      log_info "Cluster ${name} does not exist, nothing to delete"
    fi
  done
}

# IP of a cluster's server node on the shared network (empty if not attached): what other clusters use to reach its NodePorts.
_k3d_server_ip() {
  docker inspect -f "{{with index .NetworkSettings.Networks \"${K3D_NETWORK}\"}}{{.IPAddress}}{{end}}" "k3d-$1-server-0" 2>/dev/null || true
}
provider_endpoint() {
  case "$1" in
    host-port)       _k3d_host_port "$2" "$3" ;;
    cluster-address) _k3d_server_ip "$2" ;;
    *) echo "provider_endpoint: unknown endpoint kind '$1' (host-port, cluster-address)" >&2; return 2 ;;
  esac
}

# Several clusters: every server is on the shared network (so every cluster reaches every other) and every API answers.
provider_validate_connectivity() {
  local name failed=0 n=0
  log_section "Validating inter-cluster connectivity"
  for name in "$@"; do
    n=$(( n + 1 ))
    [ -n "$(_k3d_server_ip "${name}")" ] || { log_error "Cluster ${n} is not connected to Docker network '${K3D_NETWORK}'"; failed=1; continue; }
    kubectl --context "$(provider_context "${name}")" --request-timeout=10s get --raw /readyz >/dev/null 2>&1 ||
      { log_error "Cluster ${n}: Kubernetes API unreachable"; failed=1; }
  done
  [ "${failed}" -eq 0 ] || die "Inter-cluster connectivity validation failed"
  log_success "All $# clusters connected to Docker network '${K3D_NETWORK}' and their APIs answer"
}
