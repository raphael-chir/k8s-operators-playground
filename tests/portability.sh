#!/usr/bin/env bash
# Use case portability tests: the scenarios under usecases/ depend on the Kubernetes provider contract, never on Kind.
#  1. Static: no hardcoded Kind context or cluster name, no direct Docker/Kind call, no container name or IP in any scenario.
#  2. Kind provider: context and endpoint resolution, CLUSTER_PREFIX compatibility, multi-cluster connectivity (stub `docker`).
#  3. Every scenario of every use case runs against a FAKE provider (a temporary copy of the repository): `docker` and `kind`
#     are stubs that fail the test if called, `kubectl` and `helm` only record their arguments. Every kubectl context a scenario
#     uses must be the fake provider's, and the distributed-topology addresses must come from provider_endpoint.
#     Nothing real is created, started, stopped or deleted.
# The engine needs Bash >= 4. On a host with Bash 3.2 this file re-runs itself inside the running Playground container.
# Run: tests/portability.sh
if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  if command -v docker >/dev/null 2>&1 && [ "$(docker inspect -f '{{.State.Running}}' cnpg-playground 2>/dev/null)" = "true" ]; then
    echo "(Bash ${BASH_VERSION%%(*} here: running the portability tests inside the Playground container)"
    exec docker exec -i -e PORTABILITY_TEST_ROOT=/workspace cnpg-playground bash -s < "${BASH_SOURCE[0]}"
  fi
  echo "SKIP portability tests (Bash >= 4 is needed: start the Playground container, or run them with Bash >= 4)"; exit 0
fi
ROOT="${PORTABILITY_TEST_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "${ROOT}" || exit 1
FAIL=0
check() { if [ "$2" = ok ]; then echo "PASS $1"; else echo "FAIL $1   [$3]"; FAIL=1; fi; }
P="$(cd "$(mktemp -d)" && pwd -P)"; trap 'rm -rf "${P}"' EXIT
SCENARIOS="$(ls usecases/*/[0-9][0-9]_*.sh)"

# --- 1. static ---------------------------------------------------------------------------------------------------------------
h="$(grep -nE 'kind-|cnpg-lab|cnpg-test' ${SCENARIOS} || true)"
[ -z "${h}" ] && r=ok || r=bad; check "no scenario hardcodes a Kind context or a cluster name" "$r" "${h}"
h="$(grep -nE '(^|[^A-Za-z0-9._-])(docker|kind|podman|nerdctl|crc|k3d|minikube)[[:space:]]+(ps|inspect|exec|network|run|cp|logs|info|get|create|delete|export|load|images|pull|stop|start)' ${SCENARIOS} || true)"
[ -z "${h}" ] && r=ok || r=bad; check "no scenario calls docker, kind or another cluster tool directly" "$r" "${h}"
h="$(grep -nE '(^|[^0-9.])(10|172|192)\.[0-9]+\.[0-9]+\.[0-9]+|-control-plane|:6443|docker network|\.NetworkSettings' ${SCENARIOS} | grep -v 'node-role.kubernetes.io/control-plane' || true)"
[ -z "${h}" ] && r=ok || r=bad; check "no scenario names a node container, an IP address, a Docker network or the API port" "$r" "${h}"
h="$(grep -nE 'KUBECONFIG|kubectl config (set-context|set-cluster|delete|rename)|kind export' ${SCENARIOS} || true)"
[ -z "${h}" ] && r=ok || r=bad; check "no scenario changes kubeconfig contexts globally" "$r" "${h}"
for s in 03_deploy_primary 04_deploy_replica; do
  grep -q 'usecase_cluster_address' "usecases/cnpg-distributed-topology/${s}.sh" && r=ok || r=bad
  check "distributed-topology ${s}: the peer address comes from the provider" "$r" ""
done
grep -q 'provider_validate_connectivity' usecases/cnpg-distributed-topology/02_network_connectivity.sh && r=ok || r=bad
check "distributed-topology 02: connectivity is checked by the provider" "$r" ""
h="$(grep -niE 'docker|kind' usecases/*/manifests/*.yaml | grep -vE 'docker\.enterprisedb\.com|^[^:]*:[0-9]+:[[:space:]-]*kind:' || true)"
[ -z "${h}" ] && r=ok || r=bad; check "no manifest names Docker or Kind (besides image registries and the Kubernetes 'kind:' field)" "$r" "${h}"

# --- 2. the Kind provider with a stub docker ---------------------------------------------------------------------------------
mkdir -p "${P}/stub"
cat > "${P}/stub/docker" <<'STUB'
#!/bin/sh
# inspect: the control-plane IP only for containers listed in $STUB_IPS (name=ip,...); exec: the API readiness answer.
case "$1" in
  inspect) last=""; for a in "$@"; do last="$a"; done
           for e in $(echo "${STUB_IPS}" | tr ',' ' '); do [ "${e%%=*}" = "${last}" ] && { echo "${e#*=}"; exit 0; }; done; exit 0 ;;
  exec)    printf '%s' "${STUB_READYZ:-ok
200}"; exit 0 ;;
esac
exit 0
STUB
chmod +x "${P}/stub/docker"
kind_run() { ( PATH="${P}/stub:${PATH}" "$@" 2>&1 ); }
for pre in cnpg-lab cnpg-test acme-dev; do
  out="$(CLUSTER_PREFIX="${pre}" STUB_IPS="${pre}-uc-1-control-plane=172.30.0.11,${pre}-uc-2-control-plane=172.30.0.12" kind_run bash -c '
    source engine/lib/logger.sh; source engine/lib/provider.sh
    n1="$(provider_cluster_name uc 1)"; n2="$(provider_cluster_name uc 2)"
    echo "$n1 $(provider_context "$n1") $(provider_context_id "$(provider_context "$n2")") $(provider_endpoint cluster-address "$n2")"')"
  [ "${out}" = "${pre}-uc-1 kind-${pre}-uc-1 uc-2 172.30.0.12" ] && r=ok || r=bad
  check "Kind provider, CLUSTER_PREFIX=${pre}: name, context, id and peer address all follow the prefix" "$r" "${out}"
done
out="$(CLUSTER_PREFIX=cnpg-test STUB_IPS="cnpg-lab-uc-2-control-plane=172.30.0.99" kind_run bash -c 'source engine/lib/logger.sh; source engine/lib/provider.sh; provider_endpoint cluster-address "$(provider_cluster_name uc 2)"')"
[ -z "${out}" ] && r=ok || r=bad; check "an address is never taken from a cluster of another prefix" "$r" "${out}"

validate() { CLUSTER_PREFIX=cnpg-test STUB_IPS="$1" STUB_READYZ="${2-}" kind_run bash -c 'source engine/lib/logger.sh; source engine/lib/provider.sh; provider_validate_connectivity cnpg-test-uc-1 cnpg-test-uc-2; echo "rc=$?"'; }
out="$(validate 'cnpg-test-uc-1-control-plane=172.30.0.11,cnpg-test-uc-2-control-plane=172.30.0.12')"
grep -q 'Cluster 1 -> Cluster 2: Kubernetes API reachable' <<< "${out}" && grep -q 'Cluster 2 -> Cluster 1: Kubernetes API reachable' <<< "${out}" && grep -q 'rc=0' <<< "${out}" && r=ok || r=bad
check "provider_validate_connectivity: both directions reachable, succeeds" "$r" "${out}"
out="$(validate 'cnpg-test-uc-1-control-plane=172.30.0.11')"
grep -q 'Cluster 2 is not connected' <<< "${out}" && ! grep -q 'rc=0' <<< "${out}" && r=ok || r=bad
check "provider_validate_connectivity: a cluster that is not on the network fails" "$r" "${out}"
out="$(validate 'cnpg-test-uc-1-control-plane=172.30.0.11,cnpg-test-uc-2-control-plane=172.30.0.12' 'nope
503')"
grep -q 'Kubernetes API unreachable' <<< "${out}" && ! grep -q 'rc=0' <<< "${out}" && r=ok || r=bad
check "provider_validate_connectivity: an API that does not answer ok fails" "$r" "${out}"

# --- 3. every scenario against a fake provider ---------------------------------------------------------------------------------
mkdir -p "${P}/repo/bin"; : > "${P}/repo/playground"; cp -R engine usecases "${P}/repo/"; mkdir -p "${P}/repo/engine/providers/fake"
cat > "${P}/repo/engine/providers/fake/provider.sh" <<'FAKE'
provider_cluster_name()         { printf 'fake-%s-%s' "$1" "$2"; }
provider_context()              { printf 'ctx-%s' "$1"; }
provider_context_id()           { printf '%s' "${1#ctx-}"; }
provider_require_managed_name() { :; }
provider_check_available()      { :; }
provider_require_runtime()      { :; }
provider_list()                 { :; }
provider_exists()               { return 0; }
provider_init()                 { :; }
provider_create()               { :; }
provider_connect()              { :; }
provider_status()               { :; }
provider_info()                 { :; }
provider_destroy()              { :; }
provider_validate_connectivity(){ echo "validate $*" >> "${FAKE_LOG}"; echo "(fake) connectivity ok: $*"; }
provider_endpoint() {
  echo "endpoint $*" >> "${FAKE_LOG}"
  case "$1" in host-port) printf '4242' ;; cluster-address) printf '10.9.9.%s' "${2##*-}" ;; *) return 2 ;; esac
}
FAKE
B="${P}/repo/bin"
for tool in docker kind; do printf '#!/bin/sh\necho "FORBIDDEN %s $*" >> "%s/forbidden.log"\nexit 1\n' "${tool}" "${P}" > "${B}/${tool}"; chmod +x "${B}/${tool}"; done
# kubectl and helm record their arguments; kubectl answers "config current-context" like a terminal bound to cluster 1
for tool in kubectl helm; do printf '#!/bin/sh\necho "%s $*" >> "%s/kubectl.log"\n[ "$*" = "config current-context" ] && echo "${FAKE_CTX}"\nexit 0\n' "${tool}" "${P}" > "${B}/${tool}"; chmod +x "${B}/${tool}"; done
echo "EDB_SUBSCRIPTION_TOKEN=dummy-not-a-token" > "${P}/repo/.env"
for tool in vim less sleep jq curl openssl; do printf '#!/bin/sh\nexit 0\n' > "${B}/${tool}"; chmod +x "${B}/${tool}"; done
export FAKE_LOG="${P}/calls.log" FAKE_CTX="ctx-fake-x-1"; : > "${FAKE_LOG}"; : > "${P}/forbidden.log"; : > "${P}/kubectl.log"
ctxs() { grep -oE '(--context[= ]|use-context )[^ ]+' | sed -E 's/^(--context[= ]|use-context )//' | tr -d "'\"" || true; }
ran=0
for s in ${SCENARIOS}; do
  uc="${s#usecases/}"; uc="${uc%%/*}"; : > "${P}/kubectl.log"; : > "${P}/forbidden.log"
  out="$(cd "${P}/repo/usecases/${uc}" && yes '' 2>/dev/null | PATH="${B}:${PATH}" TERM=xterm PLAYGROUND_PROVIDER=fake FAKE_CTX="ctx-fake-${uc}-1" timeout 60 bash "./$(basename "${s}")" 2>&1; echo "rc=${PIPESTATUS[1]}")"
  rc="${out##*rc=}"
  # contexts the scenario shows and contexts kubectl actually received: all must be this use case's fake ones
  foreign="$( { ctxs < "${P}/kubectl.log"; sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g' <<< "${out}" | ctxs; } | grep -vE "^(ctx-fake-${uc}-[0-9]+|\\$\\{?[A-Za-z_0-9]+\\}?)$" | sort -u | tr '\n' ' ')"
  # The stubs return no data, so a scenario may legitimately stop at a step that needs real output (rc != 0): what is
  # asserted is that it ran its steps (a prompt was shown), used only the fake provider's contexts and called no docker/kind.
  steps="$(sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g' <<< "${out}" | grep -c '➜' || true)"
  { [ "${steps}" -ge 1 ] && [ -z "${foreign}" ] && [ ! -s "${P}/forbidden.log" ]; } && r=ok || r=bad
  check "${s}: runs against a fake provider (${steps} steps), only its contexts, no docker/kind call" "$r" "rc=${rc} foreign=[${foreign}] forbidden=[$(cat "${P}/forbidden.log")] $(sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g' <<< "${out}" | tail -3 | tr '\n' '|' | cut -c1-300)"
  ran=$((ran + 1))
done
[ "${ran}" -ge 30 ] && r=ok || r=bad; check "scenarios exercised: ${ran} (all use cases)" "$r" "${ran}"

# distributed topology: the cross-cluster addresses are the provider's, and the right way round
d="${P}/repo/usecases/cnpg-distributed-topology"
run_one() { ( cd "${d}" && yes '' 2>/dev/null | PATH="${B}:${PATH}" FAKE_CTX="ctx-fake-cnpg-distributed-topology-1" TERM=xterm PLAYGROUND_PROVIDER=fake timeout 60 bash "./$1" 2>&1 | sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g' ); }
: > "${FAKE_LOG}"; out="$(run_one 03_deploy_primary.sh)"
{ grep -qx 'endpoint cluster-address fake-cnpg-distributed-topology-2' "${FAKE_LOG}" && grep -q "sed 's/REPLICA_NODE_IP/10.9.9.2/g' manifests/cluster-primary.yaml" <<< "${out}"; } && r=ok || r=bad
check "03: the primary is told the REPLICA cluster's provider address (cluster 2)" "$r" "$(cat "${FAKE_LOG}")"
: > "${FAKE_LOG}"; out="$(run_one 04_deploy_replica.sh)"
{ grep -qx 'endpoint cluster-address fake-cnpg-distributed-topology-1' "${FAKE_LOG}" && grep -q "sed 's/PRIMARY_NODE_IP/10.9.9.1/g' manifests/cluster-replica.yaml" <<< "${out}"; } && r=ok || r=bad
check "04: the replica is told the PRIMARY cluster's provider address (cluster 1)" "$r" "$(cat "${FAKE_LOG}")"
: > "${FAKE_LOG}"; out="$(run_one 02_network_connectivity.sh)"
{ grep -qx 'validate fake-cnpg-distributed-topology-1 fake-cnpg-distributed-topology-2' "${FAKE_LOG}" && grep -q '10.9.9.1' <<< "${out}" && grep -q '10.9.9.2' <<< "${out}"; } && r=ok || r=bad
check "02: connectivity is validated by the provider for clusters 1 and 2, both addresses shown" "$r" "$(cat "${FAKE_LOG}")"

# --- 4. Web UI status: context, address and NodePorts come from the engine row (no Kind name derivation) -----------------------
if python3 -c 'import fastapi' 2>/dev/null; then
  out="$(WEB_DIR="${ROOT}/web" python3 - <<'PY' 2>&1
import os, sys, types, socket, threading, subprocess
sys.path.insert(0, os.environ["WEB_DIR"]); import app
srv = socket.socket(); srv.bind(("127.0.0.1", 0)); srv.listen(5); port = srv.getsockname()[1]
threading.Thread(target=lambda: [srv.accept() for _ in range(10)], daemon=True).start()
line = f"c-1\t41000\t42000\tctx-c-1\t127.0.0.1\t{port}\t1\n"   # Grafana NodePort answers, Console NodePort does not
subprocess.run = lambda *a, **k: types.SimpleNamespace(returncode=0, stdout=line, stderr="")
rows, err = app._usecase_clusters("x")
assert err is None and rows == [("c-1", "ctx-c-1", "41000", "42000", True, False)], rows
print("OK")
PY
)"
  [ "${out}" = OK ] && r=ok || r=bad; check "web/app.py: cluster context, address and NodePorts are taken from the engine row; service reachability uses them" "$r" "${out}"
else
  echo "SKIP web status check (fastapi not importable here)"
fi

exit "${FAIL}"
