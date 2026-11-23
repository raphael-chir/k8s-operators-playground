#!/usr/bin/env bash
# External Kubernetes provider tests (provider type external, usecases/openshift-crc). Offline: a throwaway HOME with hand-made
# kubeconfigs, a wrapper that records every kubectl call that would reach a cluster, and docker/kind/helm stubs that fail the test if used.
#  1. usecase.yaml: the minimal external manifest validates; bad ones are refused; Kind use cases keep validating; default provider is kind.
#  2. The external provider: context resolution, never creates, detach-only stop, name protection, no stack/scenario on start.
#  3. import.sh: only the configured context is accepted; a missing authentication plugin is reported.
#  4. ./playground doctor: the CRC line is informational and never changes the result.
#  5. Linux host forwarder (host-bridge.sh): socat container bound to the Compose gateway (fake docker/getent/kubectl); macOS path unchanged.
# Needs Bash >= 4: on a host with Bash 3.2 this file re-runs itself inside the running Playground container (section 4 then runs on the host side).
# Run: tests/external.sh
FAIL=0
HOST_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)"
check() { if [ "$2" = ok ]; then echo "PASS $1"; else echo "FAIL $1   [$3]"; FAIL=1; fi; }

# --- 4. doctor (always run on the host: doctor refuses to run in the container) -------------------------------------------------
doctor_tests() {
D="$(mktemp -d)"; mkdir -p "${D}/with" "${D}/without"
printf '#!/bin/sh\n[ "$1" = version ] && { echo "CRC version: 2.99.0+abcdef"; echo "OpenShift version: 4.22.0"; exit 0; }\necho "LIFECYCLE $*" >> "%s/crc.log"; exit 1\n' "${D}" > "${D}/with/crc"; chmod +x "${D}/with/crc"
doc() { PATH="$1:/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin" bash "${HOST_ROOT}/playground" doctor 2>&1 | sed 's/\x1b\[[0-9;]*m//g'; }
w="$(doc "${D}/with")"; n="$(PATH="${D}/without:/usr/bin:/bin:/usr/sbin:/sbin" bash "${HOST_ROOT}/playground" doctor 2>&1 | sed 's/\x1b\[[0-9;]*m//g')"
grep -qE '^\[[0-9:]{8}\] \[INFO\] +OpenShift Local \(CRC\): installed \(2.99.0\)$' <<< "${w}" && r=ok || r=bad; check "doctor: CRC installed -> '[INFO] OpenShift Local (CRC): installed (2.99.0)'" "$r" "$(grep -i crc <<< "${w}")"
grep -qE '^\[[0-9:]{8}\] \[INFO\] +OpenShift Local \(CRC\): not installed$' <<< "${n}" && r=ok || r=bad; check "doctor: CRC absent -> '[INFO] OpenShift Local (CRC): not installed'" "$r" "$(grep -i crc <<< "${n}")"
[ ! -e "${D}/crc.log" ] && r=ok || r=bad; check "doctor only asks crc for its version (no lifecycle command)" "$r" "$(cat "${D}/crc.log" 2>/dev/null)"
rm -rf "${D}"
}

if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  if command -v docker >/dev/null 2>&1 && [ "$(docker inspect -f '{{.State.Running}}' cnpg-playground 2>/dev/null)" = "true" ]; then
    echo "(Bash ${BASH_VERSION%%(*} here: the provider tests run inside the Playground container, the doctor tests on the host)"
    docker exec -i -e EXTERNAL_TEST_ROOT=/workspace -e SKIP_DOCTOR=1 cnpg-playground bash -s < "${BASH_SOURCE[0]}" || FAIL=1
    doctor_tests; exit "${FAIL}"
  fi
  echo "SKIP external provider tests (Bash >= 4 is needed: start the Playground container, or run them with Bash >= 4)"; exit 0
fi
ROOT="${EXTERNAL_TEST_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "${ROOT}" || exit 1
P="$(cd "$(mktemp -d)" && pwd -P)"; trap 'rm -rf "${P}"' EXIT
REAL_KUBECTL="$(command -v kubectl)"

# --- 1. usecase.yaml ----------------------------------------------------------------------------------------------------------
mkdir -p "${P}/repo/usecases" "${P}/repo/bin"; : > "${P}/repo/playground"; cp -R engine "${P}/repo/engine"
mk() { mkdir -p "${P}/repo/usecases/$1"; printf '%b' "$2" > "${P}/repo/usecases/$1/usecase.yaml"; }
mk crc 'name: crc\ndescription: Connect to an existing cluster\nprovider:\n  type: external\n  name: openshift\n  context: crc-admin\n'
mk badnoctx 'name: badnoctx\ndescription: d\nprovider:\n  type: external\n  name: openshift\n'
mk badkindctx 'name: badkindctx\ndescription: d\nprovider:\n  type: external\n  name: openshift\n  context: kind-x-1\n'
mk extras 'name: extras\ndescription: d\nprovider:\n  type: external\n  name: eks\n  context: c1\ninfrastructure:\n  clusters: 2\n  workers_per_cluster: 2\nservices:\n  minio: true\n'
mk badtype 'name: badtype\ndescription: d\nprovider:\n  type: nope\n  name: x\n  context: c1\ninfrastructure:\n  clusters: 1\n  workers_per_cluster: 1\n'
mk kindctx 'title: T\ndescription: d\nprovider:\n  type: internal\n  name: kind\n  context: c1\ninfrastructure:\n  clusters: 1\n  workers_per_cluster: 1\n'
mk futureprov 'title: T\ndescription: d\nprovider:\n  type: internal\n  name: minikube\ninfrastructure:\n  clusters: 1\n  workers_per_cluster: 1\n'
mk noname 'title: T\ndescription: d\nprovider:\n  type: internal\ninfrastructure:\n  clusters: 1\n  workers_per_cluster: 1\n'
mk eks 'name: eks\ndescription: d\nprovider:\n  type: external\n  name: eks\n  context: my-eks-context\n'
mk plain 'title: T\ndescription: d\ninfrastructure:\n  clusters: 1\n  workers_per_cluster: 1\n'
mk wrongname 'name: other\ndescription: d\nprovider:\n  type: external\n  name: eks\n  context: c1\n'
m() { ( source "${P}/repo/engine/lib/usecase-manifest.sh"; "$@" ); }
r="$(m usecase_manifest_check crc)"; [ -z "${r}" ] && r=ok || r=bad; check "the minimal external usecase.yaml (name, description, provider) validates: no infrastructure, services or scenarios needed" "$r" "${r}"
for c in "badnoctx:needs 'provider.context'" "badkindctx:must not be a Kind context" "badtype:unknown provider type" "kindctx:only for provider type external" "wrongname:must be the directory name" "futureprov:unsupported internal provider 'minikube'" "noname:'provider.name' is required"; do
  out="$(m usecase_manifest_check "${c%%:*}")"; grep -q -- "${c#*:}" <<< "${out}" && r=ok || r=bad; check "usecase.yaml refused: ${c%%:*} (${c#*:})" "$r" "${out}"
done
r="$(m usecase_manifest_check extras)"; [ -z "${r}" ] && [ -z "$(m usecase_services extras)" ] && r=ok || r=bad; check "an external manifest with infrastructure and services validates and both are ignored (no services enabled)" "$r" "${r}"
[ "$(m usecase_provider plain)" = kind ] && [ "$(m usecase_provider crc)" = external ] && [ "$(m usecase_provider eks)" = external ] && [ "$(m usecase_provider_name eks)" = eks ] && [ "$(m usecase_provider_type crc)" = external ] && r=ok || r=bad
check "resolution: no provider section = internal/kind; external + openshift or eks = the external implementation (name identifies the platform)" "$r" "$(m usecase_provider plain) $(m usecase_provider crc) $(m usecase_provider eks)"
out="$(PLAYGROUND_PROVIDER=$(m usecase_provider futureprov) bash -c "cd ${P}/repo && source engine/lib/provider.sh" 2>&1)"
grep -q "Unknown Kubernetes provider 'minikube'" <<< "${out}" && r=ok || r=bad; check "internal + minikube is never replaced by Kind: loading it fails clearly while it is not implemented" "$r" "${out}"
mkdir -p "${P}/repo/engine/providers/minikube"; printf 'provider_cluster_name() { printf "minikube-%%s-%%s" "$1" "$2"; }\nprovider_create() { echo "MINIKUBE-CREATE $*" >> "%s/minikube.log"; }\nprovider_context() { printf "minikube-%%s" "$1"; }\nprovider_list() { :; }\n' "${P}" > "${P}/repo/engine/providers/minikube/provider.sh"
out="$(m usecase_manifest_check futureprov)"; [ -z "${out}" ] && [ "$(m usecase_provider futureprov)" = minikube ] && r=ok || r=bad; check "internal + minikube resolves to engine/providers/minikube/provider.sh once that implementation exists" "$r" "${out}"
out="$(cd "${P}/repo/usecases/futureprov" 2>/dev/null; PLAYGROUND_PROVIDER=$(m usecase_provider futureprov) bash -c 'source ../../engine/lib/provider.sh; provider_create 2 "$(provider_cluster_name futureprov 1)"; provider_context x')"
grep -q 'MINIKUBE-CREATE 2 minikube-futureprov-1' "${P}/minikube.log" && r=ok || r=bad; check "internal provisioning uses the implementation selected by provider.name (the minikube provider, not Kind)" "$r" "$(cat "${P}/minikube.log" 2>/dev/null) ${out}"
rm -rf "${P}/repo/engine/providers/minikube"
[ "$(m usecase_config crc title)" = crc ] && [ "$(m usecase_config crc provider.context)" = crc-admin ] && r=ok || r=bad; check "title falls back to name; provider.context is read (not hardcoded to CRC)" "$r" ""
bad=""; for d in usecases/*/; do n="$(basename "${d}")"; [ "$(bash -c 'source engine/lib/usecase-manifest.sh; usecase_manifest_check "$1"; [ "$(usecase_provider "$1")" = "$2" ]' _ "${n}" "$([ "${n}" = openshift-crc ] && echo external || echo kind)" 2>&1)" = "" ] || bad="${bad} ${n}"; done
[ -z "${bad}" ] && r=ok || r=bad; check "every shipped use case validates with the expected provider (Kind ones unchanged, openshift-crc external)" "$r" "${bad}"
[ -f usecases/openshift-crc/usecase.yaml ] && [ "$(ls usecases/openshift-crc | tr '\n' ' ')" = "usecase.yaml " ] && r=ok || r=bad; check "usecases/openshift-crc holds only usecase.yaml (no scenarios, no manifests)" "$r" "$(ls usecases/openshift-crc)"

# --- 2. the external provider ------------------------------------------------------------------------------------------------
export HOME="${P}/home"; mkdir -p "${HOME}/.kube/external"
cat > "${P}/crc.yaml" <<'KC'
apiVersion: v1
kind: Config
clusters: [{name: api-crc-testing:6443, cluster: {server: "https://127.0.0.1:1"}}]
users: [{name: kubeadmin/api-crc-testing:6443, user: {token: not-a-real-token}}]
contexts: [{name: crc-admin, context: {cluster: "api-crc-testing:6443", user: "kubeadmin/api-crc-testing:6443"}}]
KC
cp "${P}/crc.yaml" "${HOME}/.kube/external/crc.yaml"
cat > "${HOME}/.kube/config" <<'KC'
apiVersion: v1
kind: Config
current-context: kind-keep-1
clusters: [{name: kind-keep-1, cluster: {server: "https://127.0.0.1:2"}}]
users: [{name: kind-keep-1, user: {token: other}}]
contexts: [{name: kind-keep-1, context: {cluster: kind-keep-1, user: kind-keep-1}}]
KC
# kubectl wrapper: `config ...` runs for real (offline); anything else is a call that would reach a cluster and is recorded.
cat > "${P}/repo/bin/kubectl" <<EOF
#!/bin/sh
case " \$* " in *" config "*) exec "${REAL_KUBECTL}" "\$@" ;; esac
echo "\$*" >> "${P}/cluster-calls.log"
case " \$* " in *"get --raw /readyz"*) [ -n "\${FAKE_READYZ_FAIL:-}" ] && { echo "dial tcp: connection refused" >&2; exit 1; }; echo ok; exit 0 ;; esac
exit 0
EOF
for t in docker kind helm crc; do printf '#!/bin/sh\necho "FORBIDDEN %s $*" >> "%s/forbidden.log"\nexit 1\n' "${t}" "${P}" > "${P}/repo/bin/${t}"; done
chmod +x "${P}"/repo/bin/*; : > "${P}/cluster-calls.log"; : > "${P}/forbidden.log"
export EXTERNAL_HOST_KUBECONFIG="${P}/no-host-kubeconfig"   # never the real mount
ext() { ( cd "${P}/repo" && PATH="${P}/repo/bin:${PATH}" PLAYGROUND_PROVIDER=external bash -c "source engine/lib/provider.sh; $*" 2>&1 ); }
export HOME
out="$(ext 'echo "$(provider_context "$(provider_cluster_name crc 1)")"; provider_cluster_name crc 1')"
[ "${out}" = "$(printf 'crc-admin\next-crc-1')" ] && r=ok || r=bad; check "context resolution: the context comes from usecase.yaml (provider_context)" "$r" "${out}"
out="$(ext 'provider_require_managed_name ext-plain-1' || true)"; grep -q 'not an external cluster' <<< "${out}" && r=ok || r=bad; check "a Kind use case's cluster name is refused by the external provider" "$r" "${out}"
out="$(ext 'provider_list crc; echo "[unattached]"; provider_list')"; [ "${out}" = "[unattached]" ] && r=ok || r=bad; check "not attached: nothing is listed, and no use case is enumerated globally" "$r" "${out}"
rm -f "${HOME}/.kube/external/crc.yaml"; out="$(EXTERNAL_HOST_KUBECONFIG="${P}/crc.yaml" ext 'provider_create 1 ext-crc-1 >/dev/null 2>&1; [ -f "${HOME}/.kube/external/crc.yaml" ] && echo imported-from-mount')"
[ "${out}" = imported-from-mount ] && r=ok || r=bad; check "start imports the one configured context from the read-only host kubeconfig mount (no manual import)" "$r" "${out}"
cp "${P}/crc.yaml" "${HOME}/.kube/external/crc.yaml"; ext 'provider_destroy ext-crc-1' >/dev/null
out="$(ext 'provider_connect ext-crc-1; provider_list crc')"; [ "${out}" = "ext-crc-1" ] && r=ok || r=bad; check "connect attaches the imported context (listed once attached)" "$r" "${out}"
shared="$(KUBECONFIG="${HOME}/.kube/config" "${REAL_KUBECTL}" config view -o jsonpath='{.current-context} {.contexts[*].name}')"
[ "${shared}" = "kind-keep-1 kind-keep-1 crc-admin" ] || [ "${shared}" = "kind-keep-1 crc-admin kind-keep-1" ] && r=ok || r=bad; check "attaching keeps the existing contexts and never changes the shared current-context" "$r" "${shared}"
[ "$(stat -c %a "${HOME}/.kube/config" 2>/dev/null || stat -f %Lp "${HOME}/.kube/config")" = 600 ] && r=ok || r=bad; check "the shared kubeconfig stays mode 600" "$r" ""
: > "${P}/cluster-calls.log"
out="$(ext 'provider_create 3 ext-crc-1; echo rc=$?')"; grep -q 'API .* reachable, TLS verified' <<< "${out}" && grep -qx 'rc=0' <<< "${out}" && [ "$(sort -u "${P}/cluster-calls.log")" = "--context crc-admin --request-timeout=15s get --raw /readyz" ] && r=ok || r=bad
check "start (provider_create): only a read-only readiness probe reaches the cluster; nothing is created (workers argument ignored)" "$r" "${out} | $(cat "${P}/cluster-calls.log")"
out="$(FAKE_READYZ_FAIL=1 ext 'provider_create 1 ext-crc-1; echo rc=$?' )"
grep -q 'cannot reach' <<< "${out}" && ! grep -qx 'rc=0' <<< "${out}" && [ -z "$(ext 'provider_list crc')" ] && r=ok || r=bad; check "start on an unreachable cluster fails with a diagnosis and leaves the use case detached" "$r" "${out}"
: > "${P}/cluster-calls.log"
out="$(ext 'provider_connect ext-crc-1; provider_destroy ext-crc-1; echo rc=$?; provider_list crc')"
c2="$(KUBECONFIG="${HOME}/.kube/config" "${REAL_KUBECTL}" config get-contexts -o name | tr '\n' ' ')"
grep -q 'external cluster was not touched' <<< "${out}" && [ "${c2}" = "kind-keep-1 " ] && [ ! -s "${P}/cluster-calls.log" ] && [ -f "${HOME}/.kube/external/crc.yaml" ] && r=ok || r=bad
check "stop (provider_destroy) only detaches: no call reaches the cluster, other contexts stay, the credentials file is kept for a restart" "$r" "${out} | ${c2} | $(cat "${P}/cluster-calls.log")"
out="$(ext 'provider_destroy ext-plain-1; echo rc=$?' )"; ! grep -qx 'rc=0' <<< "${out}" && r=ok || r=bad; check "provider_destroy refuses a name that is not an external use case cluster (e.g. a Kind one)" "$r" "${out}"
# a full lifecycle through the generic engine: no stack, no helm, no docker/kind, no scenario
: > "${P}/cluster-calls.log"
out="$(cd "${P}/repo" && PATH="${P}/repo/bin:${PATH}" bash engine/usecase-run.sh start crc 2>&1 | sed 's/\x1b\[[0-9;]*m//g')"
! grep -qE 'Platform ready|Installing .*cert|helm' <<< "${out}" && grep -q 'Nothing was created or installed on the external cluster' <<< "${out}" && [ ! -s "${P}/forbidden.log" ] && r=ok || r=bad
check "usecase start (generic engine): attaches and validates, installs no stack, calls no docker/kind/helm/crc" "$r" "${out##*$'\n'} | $(cat "${P}/forbidden.log")"
out="$(cd "${P}/repo" && PATH="${P}/repo/bin:${PATH}" FORCE= bash engine/usecase-run.sh stop crc 2>&1 | sed 's/\x1b\[[0-9;]*m//g')"
grep -q 'Detached' <<< "${out}" && ! grep -qi 'Delete these Kind' <<< "${out}" && [ ! -s "${P}/forbidden.log" ] && r=ok || r=bad; check "usecase stop (generic engine): detaches without any Kind deletion prompt" "$r" "${out}"
! grep -nE '(^|[;&|(`$[:space:]])(docker|kind|crc|podman)[[:space:]]+(ps|inspect|exec|network|run|get|create|delete|export|load|start|stop|setup|cleanup)' $(ls engine/providers/external/*.sh | grep -v host-bridge.sh) | grep -vE '^[^:]*:[0-9]+:[[:space:]]*#' | grep -q . && r=ok || r=bad; check "the external provider never calls kind, docker or a crc lifecycle command (only host-bridge.sh uses docker, section 5)" "$r" ""

# --- 3. import.sh ---------------------------------------------------------------------------------------------------------------
imp() { ( cd "${P}/repo" && PATH="${P}/repo/bin:${PATH}" bash engine/providers/external/import.sh "$@" 2>&1 ); }
rm -f "${HOME}/.kube/external/crc.yaml"
out="$("${REAL_KUBECTL}" --kubeconfig "${P}/crc.yaml" config view --raw --minify --context crc-admin | imp crc)"
[ -f "${HOME}/.kube/external/crc.yaml" ] && [ "$(stat -c %a "${HOME}/.kube/external/crc.yaml" 2>/dev/null || stat -f %Lp "${HOME}/.kube/external/crc.yaml")" = 600 ] && ! grep -q 'not-a-real-token' <<< "${out}" && ! grep -qE '^current-context: [^"]' "${HOME}/.kube/external/crc.yaml" && r=ok || r=bad
check "import: stores only the context (mode 600, no current-context) and never prints a credential" "$r" "${out}"
out="$("${REAL_KUBECTL}" --kubeconfig "${P}/crc.yaml" config view --raw --minify --context crc-admin | imp plain)"; grep -q 'does not use provider type external' <<< "${out}" && r=ok || r=bad; check "import refuses a use case that is not external" "$r" "${out}"
sed 's/token: not-a-real-token/exec: {apiVersion: client.authentication.k8s.io\/v1beta1, command: aws-not-installed}/' "${P}/crc.yaml" > "${P}/exec.yaml"
rm -f "${HOME}/.kube/external/crc.yaml"
out="$("${REAL_KUBECTL}" --kubeconfig "${P}/exec.yaml" config view --raw --minify --context crc-admin | imp crc)"
grep -q "aws-not-installed.*not installed" <<< "${out}" && [ ! -f "${HOME}/.kube/external/crc.yaml" ] && r=ok || r=bad; check "import: a missing authentication plugin is reported clearly, nothing is imported" "$r" "${out}"
out="$(printf 'apiVersion: v1\nkind: Config\n' | imp crc)"; grep -q "Expected exactly the context 'crc-admin'" <<< "${out}" && r=ok || r=bad; check "import refuses a kubeconfig without exactly the configured context" "$r" "${out}"

# --- 5. Linux host forwarder (host-bridge.sh) --------------------------------------------------------------------------------
H="${P}/hb"; mkdir -p "${H}/bin" "${H}/state/c"; export HB_STATE="${H}/state"
GETENT_REAL="$(command -v getent || echo /usr/bin/getent)"
cat > "${H}/bin/docker" <<'EOF'
#!/usr/bin/env bash
S="${HB_STATE}"; echo "$*" >> "${S}/docker.log"
case "$1" in
  network) [ -f "${S}/network.json" ] && cat "${S}/network.json" || exit 1 ;;
  inspect) f="${S}/c/$2.json"; [ -f "${f}" ] && cat "${f}" || exit 1 ;;
  logs) echo "socat: Address already in use" ;;
  rm) rm -f "${S}/c/${3}.json" ;;
  run)
    shift; name=""; labels=()
    while [ $# -gt 0 ]; do case "$1" in
      --name) name="$2"; shift 2 ;; --label) labels+=("$2"); shift 2 ;;
      --restart|--network|--cap-drop|--cap-add|--security-opt|--pids-limit|--memory) shift 2 ;;
      -d|--read-only) shift ;; *) break ;; esac; done
    image="$1"; shift; cmd="$*"
    [ ! -f "${S}/c/${name}.json" ] || { echo "Conflict: name in use" >&2; exit 125; }
    running=true; [ -z "${FAKE_RUN_DEAD:-}" ] || running=false
    case "${cmd}" in *so-bindtodevice*) [ -z "${FAKE_DEV_FAIL:-}" ] || running=false ;; esac
    l="$(printf '%s\n' "${labels[@]}" | jq -R 'split("=") | {(.[0]): (.[1:] | join("="))}' | jq -s add)"
    jq -n --argjson l "${l}" --arg i "${image}" --argjson r "${running}" '[{State:{Running:$r},RestartCount:0,Config:{Image:$i,Labels:$l}}]' > "${S}/c/${name}.json"
    echo "container-id" ;;
esac
exit 0
EOF
cat > "${H}/bin/getent" <<EOF
#!/bin/sh
case "\$1 \$2" in
  "hosts host.docker.internal") [ -n "\${FAKE_HDI:-}" ] && { echo "192.168.65.254 host.docker.internal"; exit 0; }; exit 2 ;;
  "ahostsv4 api.crc.testing") echo "127.0.0.1 STREAM api.crc.testing"; exit 0 ;;
  "ahostsv4 remote.example.com") echo "203.0.113.9 STREAM remote.example.com"; exit 0 ;;
esac
exec "${GETENT_REAL}" "\$@"
EOF
cat > "${H}/bin/kubectl" <<EOF
#!/bin/sh
case " \$* " in *" config "*) exec "${REAL_KUBECTL}" "\$@" ;; esac
case " \$* " in *"get --raw /readyz"*)
  ctx=""; prev=""; for a in "\$@"; do [ "\$prev" = --context ] && ctx="\$a"; prev="\$a"; done
  server="\$("${REAL_KUBECTL}" config view --minify --context "\$ctx" -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null)"
  printf '%s' "\${server}" | grep -Eq "\${FAKE_OK_SERVER:-^\$}" && { echo ok; exit 0; }
  echo "dial tcp: connection refused" >&2; exit 1 ;;
esac
exit 0
EOF
chmod +x "${H}"/bin/*
cat > "${H}/state/network.json" <<'EOF'
[{"Id":"0123456789abcdef0123","Options":{},"IPAM":{"Config":[{"Subnet":"172.22.0.0/16","Gateway":"172.22.0.1"}]}}]
EOF
cat > "${H}/host-kc.yaml" <<'KC'
apiVersion: v1
kind: Config
clusters: [{name: "api-crc-testing:6443", cluster: {server: "https://api.crc.testing:6443"}}]
users: [{name: u1, user: {token: tok-secret-1}}, {name: u2, user: {token: tok-secret-2}}]
contexts: [{name: crc-admin, context: {cluster: "api-crc-testing:6443", user: u1}}, {name: crc2-admin, context: {cluster: "api-crc-testing:6443", user: u2}}]
KC
mk crc2 'name: crc2\ndescription: second use case on the same CRC\nprovider:\n  type: external\n  name: openshift\n  context: crc2-admin\n'
cp -R engine/. "${P}/repo/engine/"
export HOSTBRIDGE_PROBE_CMD=true HOSTBRIDGE_WAIT_TICKS=3
hbreset() { rm -rf "${H}/state/c" "${H}/state/docker.log"; mkdir -p "${H}/state/c"; : > "${H}/state/docker.log"; rm -f "${HOME}/.kube/external/"*.yaml; rm -f "${HOME}/.kube/config"; : > "${HOME}/.kube/config"; }
hb() { ( cd "${P}/repo" && PATH="${H}/bin:${P}/repo/bin:${PATH}" EXTERNAL_HOST_KUBECONFIG="${HB_KC:-${H}/host-kc.yaml}" PLAYGROUND_PROVIDER=external bash -c "source engine/lib/provider.sh; $*" 2>&1 | sed 's/\x1b\[[0-9;]*m//g' ); }
dlog() { cat "${H}/state/docker.log"; }
stored_server() { "${REAL_KUBECTL}" --kubeconfig "${HOME}/.kube/external/$1.yaml" config view --raw -o jsonpath='{.clusters[0].cluster.server} {.clusters[0].cluster.tls-server-name}'; }
export FAKE_OK_SERVER='^https://172\.22\.0\.1:6443$'

# Linux, loopback-only API: the forwarder is started with the exact security properties, kubeconfig rewritten, TLS name kept.
hbreset; out="$(hb 'provider_create 1 ext-crc-1; echo rc=$?')"
run1="$(dlog | grep '^run ')"
[ "$(stored_server crc)" = "https://172.22.0.1:6443 api.crc.testing" ] && grep -qx 'rc=0' <<< "${out}" && grep -q 'reachable, TLS verified' <<< "${out}" && r=ok || r=bad
check "Linux + loopback-only API: server rewritten to the Compose gateway with the original TLS name, TLS verified, start succeeds" "$r" "$(stored_server crc) | ${out}"
grep -q -- '--network host' <<< "${run1}" && grep -q 'alpine/socat@sha256:[0-9a-f]\{64\}' <<< "${run1}" && grep -q -- '--name cnpg-extproxy-6443' <<< "${run1}" && grep -q 'TCP4-LISTEN:6443,bind=172.22.0.1,so-bindtodevice=br-0123456789ab,fork,reuseaddr TCP4:127.0.0.1:6443' <<< "${run1}" && r=ok || r=bad
check "forwarder: host network, image pinned by digest, listens on the gateway only, bound to the bridge interface, targets 127.0.0.1" "$r" "${run1}"
! grep -q '0\.0\.0\.0' <<< "$(dlog)" && ! grep -q 'bind=,\|bind=0' <<< "${run1}" && r=ok || r=bad; check "the listener is never 0.0.0.0" "$r" "${run1}"
grep -q -- '--label io.cnpg-playground.owner=cnpg-operator-playground' <<< "${run1}" && grep -q -- '--label io.cnpg-playground.role=external-proxy' <<< "${run1}" && grep -q -- '--label io.cnpg-playground.listen=172.22.0.1:6443' <<< "${run1}" && grep -q -- '--restart unless-stopped' <<< "${run1}" && grep -q -- '--cap-drop ALL' <<< "${run1}" && grep -q -- '--read-only' <<< "${run1}" && r=ok || r=bad
check "forwarder: explicit ownership labels, restart unless-stopped (restored after a daemon restart), dropped capabilities, read-only" "$r" "${run1}"
! grep -q 'tok-secret' <<< "${out}" && r=ok || r=bad; check "no credential is printed" "$r" ""

# Reuse + a second use case on the same endpoint (CRC's contexts share one cluster entry): one forwarder, no recreation.
out="$(hb 'provider_create 1 ext-crc2-1; echo rc=$?')"
[ "$(dlog | grep -c '^run ')" = 1 ] && ! dlog | grep -q '^rm ' && grep -q 'Reusing the host forwarder' <<< "${out}" && grep -qx 'rc=0' <<< "${out}" && r=ok || r=bad
check "a second use case on the same endpoint reuses the healthy forwarder (no run, no rm)" "$r" "${out} | $(dlog | grep -E '^(run|rm)')"
out="$(hb 'provider_create 1 ext-crc-1 >/dev/null; echo rc=$?')"; [ "$(dlog | grep -c '^run ')" = 1 ] && ! dlog | grep -q '^rm ' && r=ok || r=bad; check "restarting an attached use case never recreates a healthy forwarder" "$r" "$(dlog | grep -E '^(run|rm)')"
out="$(hb 'provider_destroy ext-crc-1; provider_list crc2')"
! dlog | grep -q '^rm ' && grep -q 'stays: another external use case still uses it' <<< "${out}" && grep -qx 'ext-crc2-1' <<< "${out}" && r=ok || r=bad
check "detaching one of two use cases keeps the forwarder and the other use case's shared cluster entry" "$r" "${out} | $(dlog | grep '^rm ')"
out="$(hb 'provider_destroy ext-crc2-1')"
dlog | grep -q '^rm -f cnpg-extproxy-6443$' && [ "$(dlog | grep -c '^rm ')" = 1 ] && grep -q 'forwarder cnpg-extproxy-6443 removed' <<< "${out}" && r=ok || r=bad
check "detaching the last use case removes the forwarder (and only that container)" "$r" "${out} | $(dlog | grep '^rm ')"
! dlog | grep -E '^(rm|run|stop|kill)' | grep -qv 'cnpg-extproxy-\|--name cnpg-extproxy' && r=ok || r=bad; check "docker is only asked to manage cnpg-extproxy-* containers (never CRC)" "$r" "$(dlog | grep -E '^(rm|run|stop|kill)')"

# Restart restore: the forwarder vanished (daemon reboot, manual removal) while the use case stays attached -> recreated on start.
hbreset; hb 'provider_create 1 ext-crc-1' >/dev/null; rm -f "${H}/state/c/cnpg-extproxy-6443.json"; : > "${H}/state/docker.log"
out="$(HB_KC=/nonexistent hb 'provider_create 1 ext-crc-1; echo rc=$?')"
[ "$(dlog | grep -c '^run ')" = 1 ] && grep -qx 'rc=0' <<< "${out}" && r=ok || r=bad; check "a vanished forwarder is restored by start, from the stored credentials alone (no host kubeconfig needed)" "$r" "${out}"
# Stale (wrong listen label / not running) is replaced, not reused.
jq '.[0].State.Running=false' "${H}/state/c/cnpg-extproxy-6443.json" > "${H}/x" && mv "${H}/x" "${H}/state/c/cnpg-extproxy-6443.json"; : > "${H}/state/docker.log"
hb 'provider_create 1 ext-crc-1' >/dev/null; dlog | grep -q '^rm -f cnpg-extproxy-6443' && [ "$(dlog | grep -c '^run ')" = 1 ] && r=ok || r=bad; check "a stopped forwarder is replaced" "$r" "$(dlog | grep -E '^(run|rm)')"

# Interface binding unavailable: still bound to the gateway only, with a warning.
hbreset; out="$(FAKE_DEV_FAIL=1 hb 'provider_create 1 ext-crc-1; echo rc=$?')"
grep -q 'TCP4-LISTEN:6443,bind=172.22.0.1,fork,reuseaddr' <<< "$(dlog | grep '^run ' | tail -1)" && ! dlog | grep '^run ' | tail -1 | grep -q so-bindtodevice && grep -q 'Could not bind the forwarder to the interface' <<< "${out}" && grep -qx 'rc=0' <<< "${out}" && r=ok || r=bad
check "bridge-interface binding unavailable: retried on the gateway address only, with a warning" "$r" "${out}"

# Failure paths: nothing is left behind, the original server is kept, TLS is never disabled.
hbreset; out="$(FAKE_RUN_DEAD=1 hb 'provider_create 1 ext-crc-1; echo rc=$?')"
! grep -qx 'rc=0' <<< "${out}" && grep -q 'did not become usable on 172.22.0.1:6443' <<< "${out}" && grep -q 'ufw' <<< "${out}" && [ -z "$(ls "${H}/state/c")" ] && r=ok || r=bad
check "a forwarder that cannot listen is reported (firewall hint, nothing applied), removed again, and start fails" "$r" "${out}"
hbreset; mkdir -p "${H}/state/c"; echo '[{"State":{"Running":true},"RestartCount":0,"Config":{"Image":"x","Labels":{}}}]' > "${H}/state/c/cnpg-extproxy-6443.json"
out="$(hb 'provider_create 1 ext-crc-1; echo rc=$?')"
! dlog | grep -q '^rm ' && ! dlog | grep -q '^run ' && grep -q 'is not a Playground forwarder: it was left alone' <<< "${out}" && r=ok || r=bad; check "a container with the forwarder's name but without the Playground labels is never touched" "$r" "${out}"
hbreset; mv "${H}/state/network.json" "${H}/state/network.bak"; out="$(hb 'provider_create 1 ext-crc-1; echo rc=$?')"; mv "${H}/state/network.bak" "${H}/state/network.json"
! dlog | grep -q '^run ' && ! grep -qx 'rc=0' <<< "${out}" && r=ok || r=bad; check "no usable gateway: no forwarder is started" "$r" "${out}"
sed 's/"Gateway":"172.22.0.1"/"Gateway":"0.0.0.0"/' "${H}/state/network.json" > "${H}/state/network.bad"; cp "${H}/state/network.json" "${H}/state/network.ok"; cp "${H}/state/network.bad" "${H}/state/network.json"
hbreset; out="$(hb 'provider_create 1 ext-crc-1; echo rc=$?')"; cp "${H}/state/network.ok" "${H}/state/network.json"
! dlog | grep -q '^run ' && r=ok || r=bad; check "a 0.0.0.0 gateway is refused" "$r" "$(dlog | grep '^run ')"
# Not a loopback endpoint: never forwarded.
hbreset; sed 's#https://api.crc.testing:6443#https://remote.example.com:6443#' "${H}/host-kc.yaml" > "${H}/remote-kc.yaml"
out="$(HB_KC="${H}/remote-kc.yaml" hb 'provider_create 1 ext-crc-1; echo rc=$?')"
! dlog | grep -q '^run ' && [ "$(stored_server crc | cut -d' ' -f1)" = "https://remote.example.com:6443" ] && r=ok || r=bad; check "a non-loopback unreachable API is not forwarded (server kept as is)" "$r" "$(stored_server crc)"

# macOS / Docker Desktop: host.docker.internal resolves -> the Linux path is never taken.
hbreset; out="$(FAKE_HDI=1 FAKE_OK_SERVER='^https://host\.docker\.internal:6443$' hb 'provider_create 1 ext-crc-1; echo rc=$?')"
[ "$(stored_server crc)" = "https://host.docker.internal:6443 api.crc.testing" ] && grep -qx 'rc=0' <<< "${out}" && ! dlog | grep -q . && r=ok || r=bad
check "macOS: host.docker.internal is used exactly as before and docker is never called" "$r" "$(stored_server crc) | $(dlog)"
hbreset; out="$(FAKE_HDI=1 FAKE_OK_SERVER='^$' hb 'provider_create 1 ext-crc-1; echo rc=$?')"
! dlog | grep -q . && [ "$(stored_server crc)" = "https://api.crc.testing:6443 " ] && r=ok || r=bad; check "macOS with CRC stopped: original server kept, no forwarder, docker never called" "$r" "$(stored_server crc) | $(dlog)"
# Direct connectivity (e.g. CRC in system mode, reachable from the container): untouched, no forwarder.
hbreset; out="$(FAKE_OK_SERVER='^https://api\.crc\.testing:6443$' hb 'provider_create 1 ext-crc-1; echo rc=$?')"
! dlog | grep -q . && grep -qx 'rc=0' <<< "${out}" && r=ok || r=bad; check "an API that already answers directly keeps its server and starts no forwarder" "$r" "${out}"
! grep -q 'docker\.sock' engine/providers/external/host-bridge.sh && grep -q 'so-bindtodevice' engine/providers/external/host-bridge.sh && ! grep -qE 'iptables|nft |ufw (allow|enable)|sysctl|route_localnet' <(grep -vE '^[[:space:]]*#' engine/providers/external/host-bridge.sh | grep -v 'log_error') && r=ok || r=bad
check "host-bridge.sh changes no firewall rule, route or sysctl (the ufw text is only part of an error message)" "$r" ""

[ -n "${SKIP_DOCTOR:-}" ] || doctor_tests
exit "${FAIL}"
