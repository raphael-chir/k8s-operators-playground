#!/usr/bin/env bash
# Scheduling model of the Playground: no Playground-specific node labels; shared stacks, HA testers and availability monitors
# on the control-plane (native label + toleration of its NoSchedule taint); PostgreSQL on the workers by the taint alone, with its
# pod anti-affinity unchanged.
#  A. Static (sources only; no tools beyond grep): the custom labels are gone, nothing labels nodes, no PostgreSQL manifest selects a
#     node or tolerates the control-plane taint, anti-affinity is exactly what it was, HA testers/monitors and the Barman plugin
#     flags are pinned to the control-plane.
#  B. Rendered (needs helm, yq and the chart repositories; SKIP otherwise): the EFFECTIVE manifests of the three stacks and of the
#     Barman Cloud plugin, workload by workload (subcharts and hook jobs included).
# Run: tests/scheduling.sh
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
FAIL=0
check() { if [ "$2" = ok ]; then echo "PASS $1"; else echo "FAIL $1   [$3]"; FAIL=1; fi; }
CP='node-role.kubernetes.io/control-plane'

# --- A1. the custom labels are not used anywhere in the sources  -----------------------
hits="$(grep -rnE 'playground(\\+\.|\.)edb(\\+\.|\.)io' engine usecases web ai-builder playground compose.yaml Dockerfile 2>/dev/null | grep -v '^usecases/\.trash/' || true)"
[ -z "${hits}" ] && r=ok || r=bad; check "no source uses the Playground-specific node labels" "$r" "${hits}"
hits="$(grep -rnE 'label[[:space:]]+nodes?([^A-Za-z]|$)' engine playground 2>/dev/null | grep -v '^[^:]*:[0-9]*:[[:space:]]*#' || true)"
[ -z "${hits}" ] && r=ok || r=bad; check "provisioning and the stack installers label no node" "$r" "${hits}"
hits="$(grep -rnE '(get nodes|get node).* -L ' engine usecases/*/*.sh 2>/dev/null || true)"
[ -z "${hits}" ] && r=ok || r=bad; check "no scenario or script prints a custom node-label column" "$r" "${hits}"

# --- A2. PostgreSQL manifests: no node selector, no toleration, anti-affinity as before ------------------------------------------
# expected: <file> <podAntiAffinityType lines: required|preferred|none>
EXPECT="cnpg-standard/manifests/cluster.yaml required
cnpg-standard/manifests/restore-cluster.yaml required
cnpg-klio-plugin/manifests/cluster.yaml required
cnpg-klio-plugin/manifests/restore.yaml preferred
cnpg-klio-plugin/manifests/restore-cluster.yaml none
cnpg-distributed-topology/manifests/cluster-primary.yaml required
cnpg-distributed-topology/manifests/cluster-replica.yaml required
cnpg-edb-plugin/manifests/cluster-tde.yaml required
cnpg-edb-plugin/manifests/pgd-cluster.yaml none
pg4k-tde/manifests/cluster.yaml none
pg4k-tde/manifests/cluster-tde.yaml none
pg4k-tde/manifests/cluster-openbao.yaml none
pgd4k-single-group/manifests/pgd-cluster.yaml none"
a2="$(echo "${EXPECT}" | while read -r f want; do
  m="usecases/${f}"; [ -f "${m}" ] || { echo "FAIL ${f}: missing   [file not found]"; continue; }
  sel="$(grep -cE '^[[:space:]]*nodeSelector:' "${m}")"; tol="$(grep -cE '^[[:space:]]*tolerations:' "${m}")"
  got=none; grep -qE '^[[:space:]]*podAntiAffinityType:[[:space:]]*required' "${m}" && got=required; grep -qE '^[[:space:]]*podAntiAffinityType:[[:space:]]*preferred' "${m}" && got=preferred
  topo="$(grep -cE '^[[:space:]]*topologyKey:[[:space:]]*kubernetes.io/hostname' "${m}")"; [ "${want}" = none ] && wanttopo=0 || wanttopo=1
  if [ "${sel}" = 0 ] && [ "${tol}" = 0 ] && [ "${got}" = "${want}" ] && [ "${topo}" = "${wanttopo}" ]; then echo "PASS ${f}: no node selector, no toleration, anti-affinity ${want}$([ "${want}" = none ] || echo ' on kubernetes.io/hostname')"
  else echo "FAIL ${f}   [nodeSelector=${sel} tolerations=${tol} anti-affinity=${got} (want ${want}) topologyKey lines=${topo}]"; fi
done)"
echo "${a2}"; echo "${a2}" | grep -q '^FAIL' && FAIL=1; [ "$(echo "${a2}" | grep -c '^PASS')" = 13 ] || { echo "FAIL expected 13 PostgreSQL manifests checked   [got $(echo "${a2}" | grep -c '^PASS')]"; FAIL=1; }
# the control-plane carries a NoSchedule taint on every Kind cluster; PostgreSQL manifests neither select nor tolerate it

# --- A3. HA testers and availability monitors: pinned to the control-plane with the native label ------------------------------------
for f in usecases/pgd4k-single-group/manifests/ha-tester.yaml usecases/pgd4k-single-group/manifests/availability-monitor.yaml usecases/pgd4k-single-group/manifests/pgd-availability-monitor.yaml; do
  sel="$(grep -cE "^[[:space:]]+${CP}:[[:space:]]*\"\"" "${f}")"; tol="$(grep -cE "^[[:space:]]*-[[:space:]]*key:[[:space:]]*${CP}" "${f}")"; eff="$(grep -cE '^[[:space:]]*effect:[[:space:]]*NoSchedule' "${f}")"
  [ "${sel}" = 1 ] && [ "${tol}" = 1 ] && [ "${eff}" = 1 ] && r=ok || r=bad
  check "${f##*/}: nodeSelector ${CP} + its NoSchedule toleration" "$r" "selector=${sel} toleration=${tol} effect=${eff}"
done

# --- A4. the Barman Cloud plugin keeps its placement where it was pinned, with the native label --------------------------------------
for f in usecases/pgd4k-single-group/01_install_operators.sh usecases/pg4k-tde/01_install_operators.sh; do
  line="$(grep -E 'helm upgrade --install plugin-barman-cloud' "${f}")"
  case "${line}" in
    *"--set-json 'nodeSelector={\\\"${CP}\\\":\\\"\\\"}'"*"tolerations[0].key=${CP}"*"tolerations[0].effect=NoSchedule"*) r=ok ;; *) r=bad ;; esac
  check "${f}: plugin pinned with ${CP} and its toleration" "$r" "${line}"
done
for f in usecases/cnpg-standard/01_install_operators.sh usecases/cnpg-distributed-topology/01_install_operators.sh usecases/cnpg-edb-plugin/01_install_operators.sh; do
  line="$(grep -E 'helm upgrade --install plugin-barman-cloud' "${f}")"
  case "${line}" in *nodeSelector*|*tolerations*) r=bad ;; *) r=ok ;; esac
  check "${f}: plugin keeps its default placement (no scheduling flags, as before)" "$r" "${line}"
done

# --- B. the effective manifests --------------------------------------------------------------------------------------------------
for t in helm yq jq; do command -v "${t}" >/dev/null 2>&1 || { echo "SKIP rendered scheduling checks (${t} not installed)"; echo; [ "${FAIL}" = 0 ] && echo "ALL SCHEDULING TESTS PASSED (static part only)" || echo "SOME SCHEDULING TESTS FAILED"; exit "${FAIL}"; }; done
T="$(mktemp -d)"; trap 'rm -rf "${T}"' EXIT
export HELM_CONFIG_HOME="${T}/c" HELM_CACHE_HOME="${T}/k" HELM_DATA_HOME="${T}/d"   # the user's Helm setup is untouched
ver() { sed -n "s/^$2=\"\(.*\)\"/\1/p" "engine/stacks/$1/install.sh" | head -1; }
CM="$(ver cert-manager CERT_MANAGER_VERSION)"; MV="$(ver minio CHART_VERSION)"; PV="$(ver monitoring CHART_VERSION)"
BV="$(grep -oE 'plugin-barman-cloud [^"]*--version [0-9.]+' usecases/cnpg-standard/01_install_operators.sh | grep -oE '[0-9]+\.[0-9]+\.[0-9]+$' | head -1)"
{ helm pull oci://quay.io/jetstack/charts/cert-manager --version "${CM}" --untar --untardir "${T}/ch" \
  && helm pull minio --repo https://charts.min.io/ --version "${MV}" --untar --untardir "${T}/ch" \
  && helm pull kube-prometheus-stack --repo https://prometheus-community.github.io/helm-charts --version "${PV}" --untar --untardir "${T}/ch" \
  && helm pull plugin-barman-cloud --repo https://cloudnative-pg.github.io/charts --version "${BV}" --untar --untardir "${T}/ch"; } >/dev/null 2>&1 \
  || { echo "SKIP rendered scheduling checks (charts not reachable: cert-manager ${CM}, minio ${MV}, kube-prometheus-stack ${PV}, plugin ${BV})"; echo; [ "${FAIL}" = 0 ] && echo "ALL SCHEDULING TESTS PASSED (static part only)" || echo "SOME SCHEDULING TESTS FAILED"; exit "${FAIL}"; }
st=engine/stacks
helm template cert-manager "${T}/ch/cert-manager" -n cert-manager --set crds.enabled=true --values ${st}/cert-manager/values.yaml --include-crds > "${T}/cert-manager.yaml"
helm template minio "${T}/ch/minio" -n object-storage --values ${st}/minio/values.yaml > "${T}/minio.yaml"
helm template prometheus-community "${T}/ch/kube-prometheus-stack" -n monitoring --values ${st}/monitoring/values.yaml --include-crds --set-string "grafana.grafana\\.ini.auth.login_cookie_name=x" > "${T}/monitoring.yaml"
helm template plugin-barman-cloud "${T}/ch/plugin-barman-cloud" -n cnpg-system > "${T}/barman-default.yaml"
for ns in pgd-operator-system postgresql-operator-system; do
  helm template plugin-barman-cloud "${T}/ch/plugin-barman-cloud" -n "${ns}" --set-json "nodeSelector={\"${CP}\":\"\"}" --set "tolerations[0].key=${CP}" --set 'tolerations[0].operator=Exists' --set 'tolerations[0].effect=NoSchedule' > "${T}/barman-${ns}.yaml"
done
# one line per workload that carries a pod spec: kind/name <TAB> pinned-to-control-plane <TAB> tolerates-the-taint <TAB> uses-a-custom-label
workloads() {
  yq -o=json -I=0 '.' "$1" | jq -r 'select(.kind | IN("Deployment","StatefulSet","DaemonSet","Job","CronJob","Pod","Prometheus","Alertmanager","ThanosRuler"))
    | (if .kind == "CronJob" then .spec.jobTemplate.spec.template.spec elif .kind == "Pod" or (.kind | IN("Prometheus","Alertmanager","ThanosRuler")) then .spec else .spec.template.spec end) as $s
    | [(.kind + "/" + .metadata.name),
       (if ($s.nodeSelector // {}) | has("node-role.kubernetes.io/control-plane") then "pinned" else "unpinned" end),
       (if ([$s.tolerations // [] | .[] | select(.key == "node-role.kubernetes.io/control-plane" and .effect == "NoSchedule")] | length) > 0 then "tolerates" else "no-toleration" end),
       (if ($s.nodeSelector // {}) | keys | any(test("playground")) then "custom-label" else "native-only" end)] | @tsv'
}
for f in cert-manager minio monitoring; do
  workloads "${T}/${f}.yaml" > "${T}/${f}.w"
  total="$(wc -l < "${T}/${f}.w" | tr -d ' ')"
  # the kube-prometheus-stack admission webhook hook jobs have never had a selector or a toleration (they run on a worker, briefly, at install)
  bad="$(grep -vE 'Job/prometheus-community-kube-admission-(create|patch)' "${T}/${f}.w" | grep -vE $'\tpinned\ttolerates\tnative-only$' || true)"
  [ "${total}" -gt 0 ] && [ -z "${bad}" ] && r=ok || r=bad
  check "${f}: every workload with a pod spec (${total}, subcharts included) is pinned to the control-plane, tolerates its taint and uses no custom label" "$r" "${bad}"
done
adm="$(grep -E 'Job/prometheus-community-kube-admission-(create|patch)' "${T}/monitoring.w" | grep -cE $'\tunpinned\tno-toleration\tnative-only$')"
[ "${adm}" = 2 ] && r=ok || r=bad; check "monitoring: the two admission hook jobs keep their existing placement (unpinned, as before)" "$r" "${adm}"
for k in prometheus-community-kube-prometheus prometheus-community-grafana prometheus-community-kube-operator prometheus-community-kube-state-metrics prometheus-community-kube-alertmanager; do
  grep -q "/${k}"$'\t'pinned "${T}/monitoring.w" && r=ok || r=bad; check "monitoring: ${k} is pinned to the control-plane" "$r"
done
grep -q "Deployment/minio"$'\t'pinned "${T}/minio.w" && grep -q "Job/minio-post-job"$'\t'pinned "${T}/minio.w" && r=ok || r=bad; check "minio: server and bucket-creation job are pinned to the control-plane" "$r"
workloads "${T}/barman-default.yaml" | grep -q $'\tunpinned\tno-toleration\t' && r=ok || r=bad; check "plugin without flags: unpinned and without toleration (default placement, as before)" "$r"
for ns in pgd-operator-system postgresql-operator-system; do
  workloads "${T}/barman-${ns}.yaml" | grep -qE $'\tpinned\ttolerates\tnative-only$' && r=ok || r=bad; check "plugin with the ${ns} flags: pinned to the control-plane, tolerates its taint" "$r"
done
echo; [ "${FAIL}" = 0 ] && echo "ALL SCHEDULING TESTS PASSED" || echo "SOME SCHEDULING TESTS FAILED"; exit "${FAIL}"
