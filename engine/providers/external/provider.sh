# Kubernetes provider contract, EXTERNAL implementation: an existing, user-managed cluster (OpenShift Local, EKS, AKS, a
# Kubernetes on VMs...). Sourced by engine/lib/provider.sh, never executed. A use case selects it in usecase.yaml:
#   provider: { type: external, context: <kubeconfig context> }
# The Playground never creates, deletes, starts or stops this cluster and never writes to the host kubeconfig:
#   * the credentials of the ONE configured context are imported from the host into the container (playground usecase start, on the
#     host, runs engine/providers/external/import.sh) and kept in ~/.kube/external/<usecase>.yaml (mode 600, never printed);
#   * "attached" = that context is merged into the container's shared ~/.kube/config (the Playground's own volume), which is what
#     terminals, kubectl and oc read; start attaches after checking connectivity, stop (provider_destroy) only detaches.
#   * on native Linux Docker a loopback-only API goes through a labelled socat forwarder (host-bridge.sh), started on attach if needed and
#     removed on detach when unused.
# Every function below touches the container's own kubeconfig or reads the cluster; none modifies the external cluster.
EXTERNAL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXTERNAL_STORE="${HOME}/.kube/external"
EXTERNAL_SHARED="${HOME}/.kube/config"
EXTERNAL_HOST_KUBECONFIG="${EXTERNAL_HOST_KUBECONFIG:-/host-kubeconfig}"   # the host kubeconfig, mounted read-only by compose.yaml
source "${EXTERNAL_DIR}/../../lib/usecase-manifest.sh"
source "${EXTERNAL_DIR}/../../lib/logger.sh"
source "${EXTERNAL_DIR}/host-bridge.sh"

# ext-<usecase>-<n> (n is always 1: one external cluster per use case).
_ext_usecase() { local n="${1#ext-}"; printf '%s' "${n%-1}"; }
_ext_file()    { printf '%s/%s.yaml' "${EXTERNAL_STORE}" "$(_ext_usecase "$1")"; }

provider_cluster_name()          { printf 'ext-%s-%s' "$1" "$2"; }
provider_context()               { usecase_config "$(_ext_usecase "$1")" provider.context; }
provider_context_id()            { local id="${1//[^A-Za-z0-9]/-}"; printf '%s' "ext-${id}"; }
provider_require_managed_name() {
  local uc; uc="$(_ext_usecase "$1")"
  [[ "$1" =~ ^ext-[a-z0-9]+(-[a-z0-9]+)*-1$ ]] && [ "$(usecase_provider "${uc}")" = external ] ||
    die "'$1' is not an external cluster of a use case (refusing to touch it)"
}
provider_check_available()       { command -v kubectl >/dev/null 2>&1 || { echo "kubectl is not available" >&2; return 2; }; }
provider_require_runtime()       { :; }
provider_init()                  { :; }
provider_validate_connectivity() { :; }     # one external cluster per use case

_ext_attached() {   # captured first: grep -q closing the pipe early would fail kubectl under pipefail
  local known; known="$(kubectl config get-contexts -o name --kubeconfig "${EXTERNAL_SHARED}" 2>/dev/null || true)"
  grep -Fxq -- "$(provider_context "$1")" <<< "${known}"
}
provider_exists()                { _ext_attached "$1"; }
provider_list() {
  # Without a use case no cluster is listed: external clusters are not Playground clusters (no global enumeration).
  [ "$#" -gt 0 ] || return 0
  [ "$(usecase_provider "$1")" = external ] || return 0
  ! _ext_attached "$(provider_cluster_name "$1" 1)" || printf '%s\n' "$(provider_cluster_name "$1" 1)"
}

# Names of the context, cluster and user of the imported credentials file ("ctx<TAB>cluster<TAB>user").
_ext_names() {
  KUBECONFIG="$1" kubectl config view --raw -o json | jq -r '.contexts[0] | "\(.name)\t\(.context.cluster)\t\(.context.user)"'
}

# Linux host forwarder (host-bridge.sh). Prints "<ip>:<port>" of a stored server shaped like https://<ipv4>:<port> WITH a tls-server-name
# (what import.sh writes when it goes through a gateway or a forwarder), nothing otherwise.
_ext_bridge_listen() {
  KUBECONFIG="$1" kubectl config view --raw -o json 2>/dev/null | jq -r '.clusters[0].cluster |
    select((.["tls-server-name"] // "") != "" and (.server | test("^https://[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+:[0-9]+$")) and (.server | test("^https://127\\.") | not)) | .server[8:]'
}
# Make sure the forwarder of the stored server exists and is healthy when that server is the Compose gateway. Idempotent: reuses a healthy
# one, restores it after a restart or a daemon reboot.
_ext_ensure_bridge() {
  local file listen; file="$(_ext_file "$1")"; [ -f "${file}" ] || return 0
  listen="$(_ext_bridge_listen "${file}" || true)"; [ -n "${listen}" ] || return 0
  hostbridge_network && [ "${listen%:*}" = "${HB_GATEWAY}" ] || return 0     # not our gateway: a real remote address, never touched
  hostbridge_ensure "${listen##*:}" || true                                   # the connectivity check below reports what remains
}

# Delete a cluster or user entry of the shared kubeconfig unless another attached context still uses it (two use cases may share one, e.g.
# CRC's crc-admin and crc-developer contexts use the same cluster entry).
_ext_drop() {   # <cluster|user> <name>
  local used
  used="$(KUBECONFIG="${EXTERNAL_SHARED}" kubectl config view --raw -o json 2>/dev/null | jq -r --arg k "$1" --arg n "$2" '[.contexts[]?.context[$k] | select(. == $n)] | length' || true)"
  [ "${used:-0}" != 0 ] || KUBECONFIG="${EXTERNAL_SHARED}" kubectl config "delete-$1" "$2" >/dev/null 2>&1 || true
}

# Merge the imported context into the shared kubeconfig (idempotent; the shared current-context is never changed).
provider_connect() {
  local file ctx cluster user tmp
  file="$(_ext_file "$1")"
  [ -f "${file}" ] || die "No imported credentials for context '$(provider_context "$1")'. On the host run: ./playground usecase start $(_ext_usecase "$1")"
  IFS=$'\t' read -r ctx cluster user < <(_ext_names "${file}")
  [ "${ctx}" = "$(provider_context "$1")" ] || die "The imported file holds context '${ctx}', not '$(provider_context "$1")'. Re-run: ./playground usecase start $(_ext_usecase "$1")"
  touch "${EXTERNAL_SHARED}"
  KUBECONFIG="${EXTERNAL_SHARED}" kubectl config delete-context "${ctx}" >/dev/null 2>&1 || true
  KUBECONFIG="${EXTERNAL_SHARED}" kubectl config delete-cluster "${cluster}" >/dev/null 2>&1 || true
  KUBECONFIG="${EXTERNAL_SHARED}" kubectl config delete-user "${user}" >/dev/null 2>&1 || true
  tmp="$(umask 077; mktemp)"
  KUBECONFIG="${EXTERNAL_SHARED}:${file}" kubectl config view --flatten --raw > "${tmp}" && mv "${tmp}" "${EXTERNAL_SHARED}" || { rm -f "${tmp}"; die "Could not merge the imported context"; }
  chmod 600 "${EXTERNAL_SHARED}"
}

# Read-only connectivity check of the attached context: API reachable, TLS verified, credentials accepted. Never prints credentials.
_ext_check() {
  local ctx server out
  ctx="$(provider_context "$1")"
  server="$(kubectl --kubeconfig "${EXTERNAL_SHARED}" config view --minify --context "${ctx}" -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null)"
  if out="$(kubectl --context "${ctx}" --request-timeout=15s get --raw /readyz 2>&1)"; then
    log_success "Context ${ctx}: API ${server} reachable, TLS verified, credentials accepted"
    return 0
  fi
  case "${out}" in
    *nauthorized*|*"must be logged in"*) log_error "Context ${ctx}: the API at ${server} answers but refused the credentials (expired token?). Log in again on the host (for CRC: oc login or crc), then rerun: ./playground usecase start $(_ext_usecase "$1")" ;;
    *certificate*|*x509*) log_error "Context ${ctx}: TLS verification of ${server} failed (${out##*: }). TLS verification is never disabled." ;;
    *) log_error "Context ${ctx}: cannot reach ${server} from the Playground container (${out##*: }). The cluster must be running and reachable from Docker; nothing was changed." ;;
  esac
  return 1
}

# Start from the container (Web UI): import the one configured context from the read-only host kubeconfig mount (/host-kubeconfig) with
# the same import.sh the host CLI uses. A failed import keeps the credentials stored by an earlier import.
_ext_import_from_host() {
  local name="$1" ctx; ctx="$(provider_context "${name}")"
  [ -f "${EXTERNAL_HOST_KUBECONFIG}" ] && [ -s "${EXTERNAL_HOST_KUBECONFIG}" ] || return 0
  KUBECONFIG="${EXTERNAL_HOST_KUBECONFIG}" kubectl config view --minify --flatten --raw --context "${ctx}" 2>/dev/null |
    bash "${EXTERNAL_DIR}/import.sh" "$(_ext_usecase "${name}")" || log_warn "Could not import '${ctx}' from the host kubeconfig mount; using the stored credentials if any"
}

# Start: never creates anything. Attach the imported context and require that the cluster answers.
provider_create() {
  local name
  for name in "${@:2}"; do
    _ext_import_from_host "${name}"
    provider_connect "${name}"
    _ext_ensure_bridge "${name}"
    _ext_check "${name}" || { provider_destroy "${name}" >/dev/null 2>&1 || true; die "External cluster ${name} is not usable (see above)"; }
  done
}

provider_status() {
  local name ctx
  for name in "$@"; do
    ctx="$(provider_context "${name}")"
    if ! _ext_attached "${name}"; then log_warn "Context ${ctx}: not attached"; continue; fi
    _ext_check "${name}" && kubectl --context "${ctx}" --request-timeout=15s get nodes
  done
}
provider_info() {
  local name
  for name in "$@"; do
    log_section "External cluster ${name}"
    log_info "Context:       $(provider_context "${name}")"
    kubectl --context "$(provider_context "${name}")" --request-timeout=15s get nodes --no-headers 2>/dev/null | log_stream || log_warn "Cluster is not reachable"
  done
}

# Stop: DETACH only. Removes the imported context from the container's shared kubeconfig; the credentials file is kept so that a
# restart (including from the Web UI) works. The external cluster is not contacted, stopped or modified.
provider_destroy() {
  local name file ctx cluster user listen
  for name in "$@"; do
    provider_require_managed_name "${name}"
    file="$(_ext_file "${name}")"
    listen=""
    if [ -f "${file}" ]; then
      listen="$(_ext_bridge_listen "${file}" || true)"
      IFS=$'\t' read -r ctx cluster user < <(_ext_names "${file}")
      KUBECONFIG="${EXTERNAL_SHARED}" kubectl config delete-context "${ctx}" >/dev/null 2>&1 || true
      _ext_drop cluster "${cluster}"; _ext_drop user "${user}"
    fi
    [ -z "${listen}" ] || hostbridge_release "${listen}"   # only the labelled forwarder, and only if no other attached use case needs it
    log_success "Detached ${name}: the external cluster was not touched"
  done
}

provider_endpoint() {
  case "$1" in
    host-port|cluster-address) printf '' ;;     # external services are reached through the cluster's own routes, not published ports
    *) echo "provider_endpoint: unknown endpoint kind '$1' (host-port, cluster-address)" >&2; return 2 ;;
  esac
}
