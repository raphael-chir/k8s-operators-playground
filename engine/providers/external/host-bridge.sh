# Host-loopback forwarder for EXTERNAL clusters on native Linux Docker. Sourced (by import.sh and provider.sh), never executed.
#
# Problem: an external cluster whose API is bound to the host's loopback only (OpenShift Local / CRC in user-mode networking:
# api.crc.testing -> 127.0.0.1:6443). A container cannot reach it: Docker Desktop (macOS, Windows, Docker Desktop for Linux) provides
# host.docker.internal for that, native Linux Docker does not, and a loopback-only socket does not answer on the bridge gateway.
#
# Solution: one small socat container per endpoint, in the HOST network namespace (so it can reach 127.0.0.1), listening ONLY on the
# gateway of the Compose network (and, where the kernel allows, bound to that bridge interface), forwarding to 127.0.0.1:<port>.
# The kubeconfig then points at https://<gateway>:<port> with tls-server-name set to the original host: TLS stays verified.
#   * Owned containers only: name cnpg-extproxy-<port>, explicit labels (owner + role); anything else with that name is never touched.
#   * One forwarder per listen address (gateway:port), shared by every external use case that needs it; it is reused when healthy.
#   * restart policy unless-stopped: Docker brings it back after a daemon restart (it keeps retrying until the bridge exists).
#   * removed when the last attached use case that points at it is detached, and by ./playground uninstall / purge. CRC is never touched.
#   * no firewall rule, route or sysctl is changed; a host firewall that blocks the bridge is reported, never reconfigured.
# Needs docker (the Playground container has the socket) and jq. Nothing here runs on macOS: import.sh only gets here when
# host.docker.internal does not resolve.
HOSTBRIDGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${HOSTBRIDGE_DIR}/../../lib/logger.sh"
# alpine/socat (multi-arch index), pinned by digest (resolved from :latest on 2026-11-23). Bump deliberately.
HOSTBRIDGE_IMAGE="${HOSTBRIDGE_IMAGE:-alpine/socat@sha256:5aa280c6fc5bee94dbd2bbdf2a58d30f50396eaa110be84b03636945b157ae68}"
HOSTBRIDGE_NETWORK="${HOSTBRIDGE_NETWORK:-cnpg-operator-playground_default}"   # the Compose network of the Playground container
HOSTBRIDGE_OWNER="cnpg-operator-playground"
HOSTBRIDGE_WAIT_TICKS="${HOSTBRIDGE_WAIT_TICKS:-12}"
HB_GATEWAY=""; HB_DEVICE=""      # set by hostbridge_network

_hb_name() { printf 'cnpg-extproxy-%s' "$1"; }

# "<gateway> <bridge device>" of the Compose network, in HB_GATEWAY / HB_DEVICE. Quiet; fails without a usable IPv4 gateway.
hostbridge_network() {
  local out id dev
  out="$(docker network inspect "${HOSTBRIDGE_NETWORK}" 2>/dev/null | jq -r '.[0] | [(.Id[0:12]), (.Options["com.docker.network.bridge.name"] // ""),
    ([.IPAM.Config[]? | .Gateway // empty | select(test("^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+$"))] | first // "")] | join("|")' 2>/dev/null)" || return 1
  IFS='|' read -r id dev HB_GATEWAY <<< "${out}"
  case "${HB_GATEWAY}" in ""|0.0.0.0|127.*) HB_GATEWAY=""; return 1 ;; esac
  HB_DEVICE="${dev:-br-${id}}"
}

# True when the host name only resolves to loopback addresses from here (the case that cannot work from a container).
hostbridge_is_loopback() {
  local ips
  [ "$1" = localhost ] && return 0
  ips="$(getent ahostsv4 "$1" 2>/dev/null | awk '{print $1}' | sort -u)"
  [ -n "${ips}" ] && ! grep -qv '^127\.' <<< "${ips}"
}

# "running|image|listen-label|owner-label|role-label" of a container, empty when it does not exist.
_hb_info() {
  docker inspect "$1" 2>/dev/null | jq -r '.[0] | [(.State.Running | tostring), .Config.Image, (.Config.Labels["io.cnpg-playground.listen"] // ""),
    (.Config.Labels["io.cnpg-playground.owner"] // ""), (.Config.Labels["io.cnpg-playground.role"] // "")] | join("|")' 2>/dev/null || true
}
_hb_is_ours() { [ "$1" = "${HOSTBRIDGE_OWNER}" ] && [ "$2" = external-proxy ]; }

_hb_probe() {   # <port>: can the Playground container open the listener?
  if [ -n "${HOSTBRIDGE_PROBE_CMD:-}" ]; then ${HOSTBRIDGE_PROBE_CMD} "${HB_GATEWAY}" "$1"; return; fi
  timeout 2 bash -c 'exec 3<>"/dev/tcp/$1/$2"' _ "${HB_GATEWAY}" "$1" 2>/dev/null
}
_hb_stable() { docker inspect "$1" 2>/dev/null | jq -e '.[0] | .State.Running and ((.RestartCount // 0) == 0)' >/dev/null 2>&1; }

_hb_healthy() {   # <name> <listen> <port>
  local info running image lbl owner role
  info="$(_hb_info "$1")"; [ -n "${info}" ] || return 1
  IFS='|' read -r running image lbl owner role <<< "${info}"
  _hb_is_ours "${owner}" "${role}" && [ "${running}" = true ] && [ "${image}" = "${HOSTBRIDGE_IMAGE}" ] && [ "${lbl}" = "$2" ] && _hb_probe "$3"
}

_hb_start() {   # <name> <port> <device or empty>: start, wait until it listens and does not crash; on failure remove it again
  local name="$1" port="$2" dev="$3" listen="${HB_GATEWAY}:$2" i
  docker run -d --name "${name}" --restart unless-stopped --network host \
    --label "io.cnpg-playground.owner=${HOSTBRIDGE_OWNER}" --label io.cnpg-playground.role=external-proxy \
    --label "io.cnpg-playground.listen=${listen}" --label "io.cnpg-playground.target=127.0.0.1:${port}" \
    --cap-drop ALL --cap-add NET_RAW --security-opt no-new-privileges:true --read-only --pids-limit 256 --memory 64m \
    "${HOSTBRIDGE_IMAGE}" "TCP4-LISTEN:${port},bind=${HB_GATEWAY}${dev:+,so-bindtodevice=${dev}},fork,reuseaddr" "TCP4:127.0.0.1:${port}" >/dev/null 2>&1 ||
    { _hb_healthy "${name}" "${listen}" "${port}"; return; }   # lost a race with another start of the same endpoint: fine if it is healthy
  for ((i = 0; i < HOSTBRIDGE_WAIT_TICKS; i++)); do
    if _hb_probe "${port}"; then sleep 0.3; _hb_stable "${name}" && return 0; fi
    _hb_stable "${name}" || break
    sleep 0.25
  done
  HB_LOG="$(docker logs --tail 3 "${name}" 2>&1 | tr '\n' ' ')"
  docker rm -f "${name}" >/dev/null 2>&1 || true
  return 1
}

# Make sure a healthy forwarder for <port> exists (reuse, else (re)create). Sets HB_GATEWAY. Logs; returns 1 when it cannot.
hostbridge_ensure() {
  local port="$1" name listen info running image lbl owner role dev
  [[ "${port}" =~ ^[0-9]{1,5}$ ]] || { log_error "Invalid port '${port}' for the host forwarder"; return 2; }
  hostbridge_network || { log_warn "Cannot read the gateway of the Docker network ${HOSTBRIDGE_NETWORK}: no host forwarder started"; return 1; }
  name="$(_hb_name "${port}")"; listen="${HB_GATEWAY}:${port}"
  info="$(_hb_info "${name}")"
  if [ -n "${info}" ]; then
    IFS='|' read -r running image lbl owner role <<< "${info}"
    _hb_is_ours "${owner}" "${role}" || { log_error "A container named ${name} exists but is not a Playground forwarder: it was left alone"; return 1; }
    if _hb_healthy "${name}" "${listen}" "${port}"; then log_info "Reusing the host forwarder ${name} (${listen} -> 127.0.0.1:${port})"; return 0; fi
    docker rm -f "${name}" >/dev/null 2>&1 || { log_error "Could not replace the stale forwarder ${name}"; return 1; }
  fi
  HB_LOG=""
  for dev in "${HB_DEVICE}" ""; do
    if _hb_start "${name}" "${port}" "${dev}"; then
      [ -n "${dev}" ] || log_warn "Could not bind the forwarder to the interface ${HB_DEVICE}; it listens on ${listen} only"
      log_success "Host forwarder ${name} started (${listen}${dev:+ on ${dev}} -> 127.0.0.1:${port}); nothing is exposed on the LAN"
      return 0
    fi
  done
  log_error "The host forwarder ${name} did not become usable on ${listen}${HB_LOG:+ (${HB_LOG% })}. Is something else on that port? A host firewall (e.g. ufw) may drop traffic from the Docker bridge: allow ${port}/tcp in from ${HB_DEVICE} yourself, the Playground never changes firewall rules."
  return 1
}

# Does an attached context of this kubeconfig point at the forwarder <gateway:port> (a rewritten server with tls-server-name)?
hostbridge_in_use() {   # <gateway:port> [kubeconfig]
  local f="${2:-${HOME}/.kube/config}"
  [ -f "${f}" ] || return 1
  KUBECONFIG="${f}" kubectl config view --raw -o json 2>/dev/null | jq -e --arg s "https://$1" '
    [.contexts[]?.context.cluster] as $used |
    any(.clusters[]?; .name as $n | ($used | any(. == $n)) and .cluster.server == $s and ((.cluster["tls-server-name"] // "") != ""))' >/dev/null 2>&1
}

# Remove the forwarder of <gateway:port> when no attached use case needs it any more. Only an owned container with exactly that listen label.
hostbridge_release() {   # <gateway:port>
  local listen="$1" name info running image lbl owner role
  name="$(_hb_name "${listen##*:}")"
  info="$(_hb_info "${name}")"; [ -n "${info}" ] || return 0
  IFS='|' read -r running image lbl owner role <<< "${info}"
  _hb_is_ours "${owner}" "${role}" && [ "${lbl}" = "${listen}" ] || return 0
  if hostbridge_in_use "${listen}" "${EXTERNAL_SHARED:-}"; then log_info "Host forwarder ${name} stays: another external use case still uses it"; return 0; fi
  docker rm -f "${name}" >/dev/null 2>&1 && log_success "Host forwarder ${name} removed (the external cluster itself was not touched)" || log_warn "Could not remove the host forwarder ${name}"
}
