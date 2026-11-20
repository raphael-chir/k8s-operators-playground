#!/usr/bin/env bash
# Kubernetes provider contract tests (engine/lib/provider.sh, engine/providers/<name>/provider.sh).
#  1. The Kind provider defines the whole contract; an unknown or invalid provider is refused.
#  2. Architecture guard: the generic engine scripts name no Kind, Docker, node or provider script.
#  3. The generic engine drives a FAKE provider (a temporary copy of engine/ with engine/providers/fake): use case list,
#     start (several clusters, services off), stop, status columns, infra commands, stack installer. `docker` and `kind` are
#     stubs that fail the test if anything calls them, so the generic engine provably reaches clusters only through
#     provider_*. Nothing real is created, started, stopped or deleted.
# The engine scripts need Bash >= 4 (mapfile). On a host with Bash 3.2 (macOS) this file re-runs itself inside the running
# Playground container (read-only apart from /tmp there); with neither, it reports SKIP.
# Run: tests/provider.sh
if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  if command -v docker >/dev/null 2>&1 && [ "$(docker inspect -f '{{.State.Running}}' cnpg-playground 2>/dev/null)" = "true" ]; then
    echo "(Bash ${BASH_VERSION%%(*} here: running the provider tests inside the Playground container)"
    exec docker exec -i -e PROVIDER_TEST_ROOT=/workspace cnpg-playground bash -s < "${BASH_SOURCE[0]}"
  fi
  echo "SKIP provider tests (Bash >= 4 is needed: start the Playground container, or run them with Bash >= 4)"; exit 0
fi
ROOT="${PROVIDER_TEST_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "${ROOT}" || exit 1
FAIL=0
check() { if [ "$2" = ok ]; then echo "PASS $1"; else echo "FAIL $1   [$3]"; FAIL=1; fi; }
code_hits() {   # <file> <regex>: lines with the token outside comments (a whole-line or " # " comment; "${x#y}" is code)
  sed -E 's/^[[:space:]]*#.*$//; s/[[:space:]]#[[:space:]].*$//' "$1" | grep -nE "(^|[^A-Za-z_])($2)" || true
}
P="$(cd "$(mktemp -d)" && pwd -P)"; trap 'rm -rf "${P}"' EXIT

# --- 1. the Kind provider's contract, and provider selection -----------------------------------------------------------
CONTRACT="provider_cluster_name provider_context provider_context_id provider_require_managed_name provider_check_available provider_require_runtime
 provider_list provider_exists provider_init provider_create provider_connect provider_status provider_info provider_destroy
 provider_validate_connectivity provider_endpoint"
missing="$(bash -c 'source engine/lib/provider.sh; for f in '"${CONTRACT//$'\n'/ }"'; do declare -F "$f" >/dev/null || echo "$f"; done' 2>&1)"
[ -z "${missing}" ] && r=ok || r=bad; check "the Kind provider defines the whole contract" "$r" "missing: ${missing}"
missing="$(PLAYGROUND_PROVIDER=k3d bash -c 'source engine/lib/provider.sh; for f in '"${CONTRACT//$'\n'/ }"'; do declare -F "$f" >/dev/null || echo "$f"; done' 2>&1)"
[ -z "${missing}" ] && r=ok || r=bad; check "the k3d provider defines the whole contract" "$r" "missing: ${missing}"
out="$(PLAYGROUND_PROVIDER=nope bash -c 'source engine/lib/provider.sh' 2>&1)"; rc=$?
[ "${rc}" != 0 ] && grep -q "Unknown Kubernetes provider 'nope'" <<< "${out}" && r=ok || r=bad; check "an unknown provider is refused" "$r" "rc=${rc} ${out}"
out="$(PLAYGROUND_PROVIDER='../kind' bash -c 'source engine/lib/provider.sh' 2>&1)"; rc=$?
[ "${rc}" != 0 ] && grep -q "Invalid Kubernetes provider name" <<< "${out}" && r=ok || r=bad; check "a provider name that is not a plain word is refused (no path traversal)" "$r" "rc=${rc} ${out}"
out="$(bash -c 'source engine/lib/provider.sh; provider_endpoint bogus x' 2>&1)"; rc=$?
[ "${rc}" = 2 ] && grep -q "unknown endpoint kind" <<< "${out}" && r=ok || r=bad; check "an unknown endpoint kind is refused" "$r" "rc=${rc} ${out}"
out="$(bash -c 'source engine/lib/logger.sh; source engine/lib/provider.sh; ensure_kind_network() { return 1; }; provider_init; echo "rc=$?"' 2>&1)"
grep -q "Could not join the 'kind' network" <<< "${out}" && grep -q "rc=0" <<< "${out}" && r=ok || r=bad; check "provider_init only warns when the network cannot be joined (the terminal still starts)" "$r" "${out}"

# --- 2. architecture guard: generic engine code never names Kind, Docker or a node ------------------------------------------
GENERIC="engine/usecase.sh engine/usecase-run.sh engine/usecase-list.sh engine/usecase-clusters.sh engine/managed-clusters.sh
 engine/terminal.sh engine/entrypoint.sh engine/infra-run.sh engine/stacks/up.sh engine/lib/usecase-manifest.sh engine/lib/provider.sh"
FORBIDDEN='docker|kind (get|create|delete|export|load)|join_kind_network|ensure_kind_network|write_kubeconfig|host_port|cluster_exists|KIND_|providers/kind|control-plane|require_docker|managed_clusters|usecase_clusters|cluster_name[ (]|cluster_context|require_managed_name'
for f in ${GENERIC}; do
  hits="$(code_hits "${f}" "${FORBIDDEN}")"
  [ -z "${hits}" ] && r=ok || r=bad; check "${f} reaches clusters only through provider_*" "$r" "${hits}"
done
hits="$(code_hits playground 'providers/kind')"
[ -z "${hits}" ] && r=ok || r=bad; check "the CLI does not name the Kind provider (it calls engine/infra-run.sh)" "$r" "${hits}"

# Stacks: portable shared services. They may assume kubectl and helm and nothing else; the one provider fact they need
# (a stable cluster id for names) comes from provider_context_id. (Their control-plane label and toleration are the
# scheduling model, changed in a later phase, so "control-plane" is not banned here.)
STACK_FORBIDDEN='docker|kind (get|create|delete|export|load)|kind-|join_kind_network|ensure_kind_network|write_kubeconfig|host_port|cluster_exists|KIND_|providers/kind|require_docker|managed_clusters|usecase_clusters|cluster_name[ (]|cluster_context|CLUSTER_PREFIX'
for f in engine/stacks/common.sh engine/stacks/up.sh engine/stacks/ports.sh engine/stacks/cert-manager/install.sh engine/stacks/minio/install.sh engine/stacks/monitoring/install.sh; do
  hits="$(code_hits "${f}" "${STACK_FORBIDDEN}")"
  [ -z "${hits}" ] && r=ok || r=bad; check "${f} assumes no Kind, Docker or Playground cluster naming" "$r" "${hits}"
done
# The Grafana cookie name is derived through the provider and must equal the former inline derivation for every context.
for pfx in "" cnpg-test; do
  for ctx in kind-cnpg-lab-cnpg-distributed-topology-2 kind-cnpg-lab-cnpg-standard-1 kind-cnpg-test-pgd4k-single-group-1 kind-other-thing-1 cnpg-lab-x-1; do
    old="$(CLUSTER_PREFIX="${pfx}" bash -c 'name="${1#kind-}"; name="${name#"${CLUSTER_PREFIX:-cnpg-lab}"-}"; printf "grafana_session_%s" "${name//[^A-Za-z0-9]/_}"' _ "${ctx}")"
    new="$(CLUSTER_PREFIX="${pfx}" bash -c 'source engine/lib/provider.sh; name="$(provider_context_id "$1")"; printf "grafana_session_%s" "${name//[^A-Za-z0-9]/_}"' _ "${ctx}")"
    [ "${old}" = "${new}" ] && r=ok || r=bad; check "cookie name unchanged for ${ctx} (prefix '${pfx:-default}'): ${new}" "$r" "old=${old} new=${new}"
  done
done
# One list of stack node ports: ports.sh, the stacks' values, what Kind publishes, and the Web UI's copy must agree.
ports_sh="$(bash -c 'source engine/stacks/ports.sh; printf "%s\n" ${STACK_NODE_PORTS}' | sort -n | tr '\n' ' ')"
ports_values="$(grep -hE '^[[:space:]]*nodePort:' engine/stacks/*/values.yaml | sed -E 's/.*nodePort:[[:space:]]*([0-9]+).*/\1/' | sort -n | tr '\n' ' ')"
ports_kind="$(grep -hoE 'containerPort: [0-9]+' engine/providers/kind/cluster.yaml | sed -E 's/.*: //' | sort -n | tr '\n' ' ')"
[ "${ports_sh}" = "${ports_values}" ] && r=ok || r=bad; check "engine/stacks/ports.sh equals the nodePorts in the stacks' values.yaml (${ports_sh})" "$r" "ports.sh=${ports_sh} values=${ports_values}"
[ "${ports_sh}" = "${ports_kind}" ] && r=ok || r=bad; check "Kind publishes exactly the stacks' node ports (cluster.yaml)" "$r" "ports.sh=${ports_sh} cluster.yaml=${ports_kind}"
h="$(grep -nE 'NODE_PORT|-control-plane|kind-' web/app.py || true)"
[ -z "${h}" ] && r=ok || r=bad; check "web/app.py has no node-port copy, node container name or Kind context (cluster facts come from usecase-clusters.sh)" "$r" "${h}"

# --- 3. the generic engine against a fake provider ---------------------------------------------------------------------------
mkdir -p "${P}/usecases" "${P}/bin"; : > "${P}/playground"; cp -R "${ROOT}/engine" "${P}/engine"; mkdir -p "${P}/engine/providers/fake"
for uc in one:1:2 two:2:2; do IFS=: read -r n c w <<< "${uc}"; mkdir -p "${P}/usecases/${n}"
  printf 'title: T %s\ndescription: D\ninfrastructure:\n  clusters: %s\n  workers_per_cluster: %s\n' "${n}" "${c}" "${w}" > "${P}/usecases/${n}/usecase.yaml"; done
cat > "${P}/engine/providers/fake/provider.sh" <<'FAKE'
provider_cluster_name()         { printf 'fake-%s-%s' "$1" "$2"; }
provider_context()              { printf 'ctx-%s' "$1"; }
provider_context_id()           { printf '%s' "${1#ctx-}"; }
provider_require_managed_name() { :; }
provider_check_available()      { echo "available" >> "${FAKE_LOG}"; }
provider_require_runtime()      { :; }
provider_list()                 { local pre=""; if [ $# -gt 0 ]; then pre="fake-$1-"; fi; awk -v p="${pre}" 'index($0, p) == 1' "${FAKE_STATE}" 2>/dev/null || true; }
provider_exists()               { grep -Fxq -- "$1" "${FAKE_STATE}" 2>/dev/null; }
provider_init()                 { echo "init" >> "${FAKE_LOG}"; }
provider_create()               { echo "create workers=$1 ${*:2}" >> "${FAKE_LOG}"; printf '%s\n' "${@:2}" >> "${FAKE_STATE}"; }
provider_connect()              { echo "connect $1" >> "${FAKE_LOG}"; }
provider_status()               { echo "status $*" >> "${FAKE_LOG}"; }
provider_info()                 { echo "info $* services=${INFO_SERVICES-unset}" >> "${FAKE_LOG}"; }
provider_destroy()              { local c; echo "destroy $*" >> "${FAKE_LOG}"; for c in "$@"; do grep -vxF -- "${c}" "${FAKE_STATE}" > "${FAKE_STATE}.new" || true; mv "${FAKE_STATE}.new" "${FAKE_STATE}"; done; }
provider_validate_connectivity(){ echo "validate $*" >> "${FAKE_LOG}"; }
provider_endpoint() {
  echo "endpoint $*" >> "${FAKE_LOG}"
  case "$1" in host-port) printf '4242' ;; cluster-address) printf '10.9.9.9' ;; *) return 2 ;; esac
}
FAKE
for tool in docker kind; do printf '#!/bin/sh\necho "FORBIDDEN %s $*" >> "%s/forbidden.log"\nexit 1\n' "${tool}" "${P}" > "${P}/bin/${tool}"; chmod +x "${P}/bin/${tool}"; done
export FAKE_LOG="${P}/calls.log" FAKE_STATE="${P}/state"; : > "${FAKE_LOG}"; : > "${FAKE_STATE}"
run() { ( cd "${P}" && unset KUBECONFIG && PATH="${P}/bin:${PATH}" PLAYGROUND_PROVIDER=fake "$@" 2>&1 ); }
calls() { cat "${FAKE_LOG}"; }

out="$(run bash engine/usecase-list.sh)"; [ "${out}" = "$(printf 'one\t0\ntwo\t0')" ] && grep -q '^available$' "${FAKE_LOG}" && r=ok || r=bad
check "usecase-list.sh: availability and clusters come from the provider" "$r" "${out}"
out="$(run bash engine/usecase-list.sh --names)"; [ "${out}" = "$(printf 'one\ntwo')" ] && r=ok || r=bad; check "usecase-list.sh --names" "$r" "${out}"

out="$(run bash engine/usecase-run.sh start two)"; rc=$?
{ [ "${rc}" = 0 ] && grep -qx 'create workers=2 fake-two-1 fake-two-2' "${FAKE_LOG}" && grep -qx 'validate fake-two-1 fake-two-2' "${FAKE_LOG}" \
  && grep -qx 'connect fake-two-1' "${FAKE_LOG}" && grep -qx 'connect fake-two-2' "${FAKE_LOG}" && grep -qE '^info fake-two-1 fake-two-2 services=$' "${FAKE_LOG}" \
  && grep -q 'Platform ready on: fake-two-1 fake-two-2 (services: none)' <<< "${out}"; } && r=ok || r=bad
check "start (2 clusters): create with the workers, stacks step, connectivity validation, info (services off)" "$r" "rc=${rc} $(calls | tr '\n' '|')"
: > "${FAKE_LOG}"; out="$(run bash engine/usecase-run.sh start one)"; rc=$?
{ [ "${rc}" = 0 ] && grep -qx 'create workers=2 fake-one-1' "${FAKE_LOG}" && ! grep -q '^validate' "${FAKE_LOG}"; } && r=ok || r=bad
check "start (1 cluster): no inter-cluster validation" "$r" "rc=${rc} $(calls | tr '\n' '|')"

out="$(run bash engine/usecase-list.sh)"; [ "${out}" = "$(printf 'one\t1\ntwo\t2')" ] && r=ok || r=bad; check "list counts the provider's clusters per use case" "$r" "${out}"
out="$(run bash engine/usecase-clusters.sh two)"; [ "${out}" = "$(printf 'fake-two-1\t4242\t4242\tctx-fake-two-1\t10.9.9.9\t30082\t30084\nfake-two-2\t4242\t4242\tctx-fake-two-2\t10.9.9.9\t30082\t30084')" ] && r=ok || r=bad
check "usecase-clusters.sh: host ports, context, address and NodePorts all come from the provider" "$r" "${out}"
out="$(run bash engine/usecase-clusters.sh 'Bad_Name')"; rc=$?; [ "${rc}" = 2 ] && r=ok || r=bad; check "usecase-clusters.sh refuses an invalid name" "$r" "rc=${rc}"
out="$(run bash engine/managed-clusters.sh | sort)"; [ "${out}" = "$(printf 'fake-one-1\nfake-two-1\nfake-two-2')" ] && r=ok || r=bad; check "managed-clusters.sh lists the provider's clusters" "$r" "${out}"

: > "${FAKE_LOG}"; out="$(run env FORCE=1 bash engine/usecase-run.sh stop two)"; rc=$?
{ [ "${rc}" = 0 ] && grep -qx 'destroy fake-two-1 fake-two-2' "${FAKE_LOG}"; } && r=ok || r=bad; check "stop: only the use case's clusters are destroyed, through the provider" "$r" "rc=${rc} $(calls | tr '\n' '|')"
out="$(run env FORCE=1 bash engine/usecase-run.sh stop two)"; grep -q 'has no cluster, nothing to delete' <<< "${out}" && r=ok || r=bad; check "stop of a use case without clusters is a no-op" "$r" "${out}"
out="$(run bash engine/usecase-list.sh)"; [ "${out}" = "$(printf 'one\t1\ntwo\t0')" ] && r=ok || r=bad; check "the other use case is untouched" "$r" "${out}"

: > "${FAKE_LOG}"
run env WORKERS=3 bash engine/infra-run.sh up fake-x-1 >/dev/null; run bash engine/infra-run.sh info fake-x-1 >/dev/null; run bash engine/infra-run.sh status fake-x-1 >/dev/null
out="$(run env PLATFORM_SERVICES= bash engine/infra-run.sh platform-up fake-x-1)"; run bash engine/infra-run.sh down fake-x-1 >/dev/null
{ grep -qx 'create workers=3 fake-x-1' "${FAKE_LOG}" && grep -qE '^info fake-x-1 ' "${FAKE_LOG}" && grep -qx 'status fake-x-1' "${FAKE_LOG}" \
  && grep -qx 'connect fake-x-1' "${FAKE_LOG}" && grep -qx 'destroy fake-x-1' "${FAKE_LOG}" && grep -q 'Platform ready on: fake-x-1' <<< "${out}"; } && r=ok || r=bad
check "infra-run.sh: up (WORKERS), info, status, platform-up and down go through the provider" "$r" "$(calls | tr '\n' '|')"
out="$(run bash engine/infra-run.sh bogus)"; rc=$?; [ "${rc}" != 0 ] && grep -q 'Usage' <<< "${out}" && r=ok || r=bad; check "infra-run.sh refuses an unknown action" "$r" "rc=${rc} ${out}"
out="$(run env PLATFORM_SERVICES=nope bash engine/stacks/up.sh fake-one-1)"; rc=$?; [ "${rc}" != 0 ] && grep -q "Unknown service 'nope'" <<< "${out}" && r=ok || r=bad; check "stacks/up.sh still refuses an unknown service" "$r" "rc=${rc} ${out}"
out="$(run env PLATFORM_SERVICES= bash engine/stacks/up.sh fake-missing-9)"; rc=$?; [ "${rc}" != 0 ] && grep -q 'Cluster fake-missing-9 does not exist' <<< "${out}" && r=ok || r=bad; check "stacks/up.sh refuses a cluster the provider does not know" "$r" "rc=${rc} ${out}"

[ ! -s "${P}/forbidden.log" ] && r=ok || r=bad; check "nothing called docker or kind: the generic engine used only the provider" "$r" "$(cat "${P}/forbidden.log" 2>/dev/null)"
echo; [ "${FAIL}" = 0 ] && echo "ALL PROVIDER TESTS PASSED" || echo "SOME PROVIDER TESTS FAILED"; exit "${FAIL}"
