# Shared settings and helpers for the Kind scripts. Sourced, not executed.
# Kind clusters are named <CLUSTER_PREFIX>-<name>-<n> (use cases: <prefix>-<usecase>-<n>) and are only
# ever created or deleted when named explicitly; names outside that pattern are refused.
CLUSTER_PREFIX="${CLUSTER_PREFIX:-cnpg-lab}"
WORKERS="${WORKERS:-1}"
PLAYGROUND_CONTAINER="${PLAYGROUND_CONTAINER:-cnpg-playground}"
KIND_NETWORK="kind"

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/logger.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../stacks/ports.sh"   # STACK_NODE_PORTS: the node ports Kind must publish (cluster.yaml)

require_docker() {
  docker info >/dev/null 2>&1 ||
    die "Cannot reach the Docker Engine. Is /var/run/docker.sock mounted into this container?"
}

# Report the tools and the Docker Engine (not the container) the playground relies on.
# Fails only when the Engine is unreachable; low memory is a warning.
check_prerequisites() {
  local info version arch mem_bytes mem_gib recommended=8
  log_section "Checking prerequisites"
  log_info "Checking Docker connectivity"
  info="$(docker info --format '{{.ServerVersion}}|{{.OSType}}/{{.Architecture}}|{{.MemTotal}}' 2>&1)" ||
    die "Docker Engine unreachable. Is /var/run/docker.sock mounted into this container? (${info})"
  IFS='|' read -r version arch mem_bytes <<< "${info}"
  log_success "Docker Engine: ${version} (${arch})"
  log_info "Kind: $(kind version)"
  log_info "kubectl: $(kubectl version --client 2>/dev/null | head -n 1)"
  log_info "Helm: $(helm version --short)"
  if [[ "${mem_bytes}" =~ ^[0-9]+$ ]] && [ "${mem_bytes}" -gt 0 ]; then
    # Rounded to the nearest GiB: Docker reports 7.65 GiB for an 8 GB setting.
    mem_gib=$(( (mem_bytes + 512 * 1024 * 1024) / 1024 / 1024 / 1024 ))
    if [ "${mem_gib}" -ge "${recommended}" ]; then
      log_success "Docker Engine memory: ${mem_gib} GiB (recommended: ${recommended} GiB)"
    else
      log_warn "Docker Engine memory: ${mem_gib} GiB, recommended at least ${recommended} GiB"
      log_warn "Low memory can cause Kubernetes API timeouts and unstable workloads (Docker Desktop: Settings > Resources)"
    fi
  else
    log_warn "Docker Engine memory: unknown"
  fi
}

cluster_name()    { printf '%s-%s-%s' "${CLUSTER_PREFIX}" "$1" "$2"; }   # <usecase> <index>
cluster_context() { printf 'kind-%s' "$1"; }

# Refuses anything that is not a playground cluster name, so a typo can never touch a foreign cluster.
require_managed_name() {
  [[ "$1" =~ ^${CLUSTER_PREFIX}-[a-z0-9]+(-[a-z0-9]+)*-[0-9]+$ ]] ||
    die "'$1' is not a playground cluster name (expected ${CLUSTER_PREFIX}-<name>-<number>)"
}

# Kind config for cluster $1: static file, per-index pod/service CIDRs so that several clusters never
# overlap (index 1: 10.244/10.96, index 2: 10.245/10.97, ...), plus one worker entry per WORKERS.
build_kind_config() {
  local index="${1##*-}" file i
  file="$(dirname "${BASH_SOURCE[0]}")/cluster.yaml"
  sed '/^nodes:/,$d' "${file}"
  printf 'networking:\n  podSubnet: "10.%s.0.0/16"\n  serviceSubnet: "10.%s.0.0/16"\n' $(( 243 + index )) $(( 95 + index ))
  sed -n '/^nodes:/,$p' "${file}"
  for (( i = 0; i < WORKERS; i++ )); do
    printf '  - role: worker\n'
  done
}

# Existing Kind clusters matching an extended regex, one per line, in numeric order.
_kind_clusters_matching() {
  { kind get clusters 2>/dev/null || true; } | { grep -E "$1" || true; } | sort -V
}

# Every playground cluster, whatever its use case.
managed_clusters() { _kind_clusters_matching "^${CLUSTER_PREFIX}-[a-z0-9]+(-[a-z0-9]+)*-[0-9]+\$"; }

# The clusters owned by one use case: <prefix>-<usecase>-<digits>, exactly. Other clusters are ignored.
usecase_clusters() { _kind_clusters_matching "^${CLUSTER_PREFIX}-$1-[0-9]+\$"; }

# Captured first: grep -q closing the pipe early would trip pipefail.
cluster_exists() {
  local existing
  existing="$(kind get clusters 2>/dev/null || true)"
  grep -Fxq "$1" <<< "${existing}"
}

# Host port Docker published for a control-plane container port (empty if none).
# Works through the Docker socket, so it reports ports of the HOST, not of this container.
host_port() {
  local mapping
  mapping="$(docker port "$1-control-plane" "$2/tcp" 2>/dev/null | head -n 1 || true)"
  printf '%s' "${mapping##*:}"
}

# An existing cluster is reused only if it has the expected nodes and host port mappings.
# Kind cannot resize or remap a cluster, and it is never deleted/recreated implicitly.
require_compatible_cluster() {
  local name="$1" workers="$2" nodes port
  nodes="$(docker ps -a --filter "label=io.x-k8s.kind.cluster=${name}" -q | wc -l | tr -d ' ')"
  [ "${nodes}" -eq $(( workers + 1 )) ] ||
    die "Cluster ${name} exists with ${nodes} nodes, but $(( workers + 1 )) are required. Not recreating it: delete it explicitly with 'playground infra down ${name}'"
  for port in ${STACK_NODE_PORTS}; do
    [ -n "$(host_port "${name}" "${port}")" ] ||
      die "Cluster ${name} has no host port mapping for ${port}. Not recreating it: delete it explicitly with 'playground infra down ${name}'"
  done
}

# Kind nodes live on the host Docker network "kind". The playground container joins it (done by
# entrypoint.sh at container start) so the API server is reachable by the control-plane container
# name (Docker DNS), with no IP addresses involved. Creates the network if Kind has not yet.
_on_kind_network() {
  docker inspect -f '{{json .NetworkSettings.Networks}}' "${PLAYGROUND_CONTAINER}" 2>/dev/null |
    jq -e --arg n "${KIND_NETWORK}" 'has($n)' >/dev/null
}

ensure_kind_network() {
  docker network inspect "${KIND_NETWORK}" >/dev/null 2>&1 || docker network create "${KIND_NETWORK}" >/dev/null ||
    die "Could not create the '${KIND_NETWORK}' network"
  _on_kind_network && return 0
  docker network connect "${KIND_NETWORK}" "${PLAYGROUND_CONTAINER}" ||
    die "Could not attach ${PLAYGROUND_CONTAINER} to the '${KIND_NETWORK}' network"
}

# Fallback for scripts: normally a no-op because the entrypoint already joined.
join_kind_network() {
  _on_kind_network && return 0
  docker network inspect "${KIND_NETWORK}" >/dev/null 2>&1 || return 0
  log_warn "Joining the '${KIND_NETWORK}' network now: open web-terminal sessions will be dropped (ttyd)."
  log_warn "Avoid this with: docker compose up -d --force-recreate (the entrypoint joins at start)"
  ensure_kind_network
}

# Merge the cluster's internal kubeconfig (https://<cluster>-control-plane:6443) into ~/.kube/config.
write_kubeconfig() {
  log_run kind export kubeconfig --name "$1" --internal
}
