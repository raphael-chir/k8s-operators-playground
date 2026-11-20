#!/usr/bin/env bash
# External Kubernetes provider tests (provider type external, usecases/openshift-crc). Offline: a throwaway HOME with hand-made
# kubeconfigs, a wrapper that records every kubectl call that would reach a cluster, and docker/kind/helm stubs that fail the test if used.
#  1. usecase.yaml: the minimal external manifest validates; bad ones are refused; Kind use cases keep validating; default provider is kind.
#  2. The external provider: context resolution, never creates, detach-only stop, name protection, no stack/scenario on start.
#  3. import.sh: only the configured context is accepted; a missing authentication plugin is reported.
#  4. ./playground doctor: the CRC line is informational and never changes the result.
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
grep -qx '\[INFO\] OpenShift Local (CRC): installed (2.99.0)' <<< "${w}" && r=ok || r=bad; check "doctor: CRC installed -> '[INFO] OpenShift Local (CRC): installed (2.99.0)'" "$r" "$(grep -i crc <<< "${w}")"
grep -qx '\[INFO\] OpenShift Local (CRC): not installed' <<< "${n}" && r=ok || r=bad; check "doctor: CRC absent -> '[INFO] OpenShift Local (CRC): not installed'" "$r" "$(grep -i crc <<< "${n}")"
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
mk badservices 'name: badservices\ndescription: d\nprovider:\n  type: external\n  name: eks\n  context: c1\nservices:\n  minio: true\n'
mk badtype 'name: badtype\ndescription: d\nprovider:\n  type: nope\n  name: x\n  context: c1\ninfrastructure:\n  clusters: 1\n  workers_per_cluster: 1\n'
mk kindctx 'title: T\ndescription: d\nprovider:\n  type: internal\n  name: kind\n  context: c1\ninfrastructure:\n  clusters: 1\n  workers_per_cluster: 1\n'
mk futureprov 'title: T\ndescription: d\nprovider:\n  type: internal\n  name: minikube\ninfrastructure:\n  clusters: 1\n  workers_per_cluster: 1\n'
mk noname 'title: T\ndescription: d\nprovider:\n  type: internal\ninfrastructure:\n  clusters: 1\n  workers_per_cluster: 1\n'
mk eks 'name: eks\ndescription: d\nprovider:\n  type: external\n  name: eks\n  context: my-eks-context\n'
mk plain 'title: T\ndescription: d\ninfrastructure:\n  clusters: 1\n  workers_per_cluster: 1\n'
mk wrongname 'name: other\ndescription: d\nprovider:\n  type: external\n  name: eks\n  context: c1\n'
m() { ( source "${P}/repo/engine/lib/usecase-manifest.sh"; "$@" ); }
r="$(m usecase_manifest_check crc)"; [ -z "${r}" ] && r=ok || r=bad; check "the minimal external usecase.yaml (name, description, provider) validates: no infrastructure, services or scenarios needed" "$r" "${r}"
for c in "badnoctx:needs 'provider.context'" "badkindctx:must not be a Kind context" "badservices:'services' is not allowed" "badtype:unknown provider type" "kindctx:only for provider type external" "wrongname:must be the directory name" "futureprov:unsupported internal provider 'minikube'" "noname:'provider.name' is required"; do
  out="$(m usecase_manifest_check "${c%%:*}")"; grep -q -- "${c#*:}" <<< "${out}" && r=ok || r=bad; check "usecase.yaml refused: ${c%%:*} (${c#*:})" "$r" "${out}"
done
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
! grep -nE '(^|[;&|(`$[:space:]])(docker|kind|crc|podman)[[:space:]]+(ps|inspect|exec|network|run|get|create|delete|export|load|start|stop|setup|cleanup)' engine/providers/external/*.sh | grep -vE '^[^:]*:[0-9]+:[[:space:]]*#' | grep -q . && r=ok || r=bad; check "the external provider never calls kind, docker or a crc lifecycle command" "$r" ""

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

[ -n "${SKIP_DOCTOR:-}" ] || doctor_tests
exit "${FAIL}"
