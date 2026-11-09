#!/usr/bin/env bash
# Monitoring combinations (SPEC-012 services): renders kube-prometheus-stack with `helm template` for every
# Prometheus/Grafana combination, using the options platform/monitoring/install.sh itself builds (chart_options).
# Offline-safe: skipped without helm or without access to the chart repository. Nothing is installed anywhere.
# Run: tests/monitoring.sh
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
FAIL=0
check() { if [ "$2" = ok ]; then echo "PASS $1"; else echo "FAIL $1   [$3]"; FAIL=1; fi; }
command -v helm >/dev/null 2>&1 || { echo "SKIP monitoring templates (helm not installed)"; exit 0; }
T="$(mktemp -d)"; trap 'rm -rf "${T}"' EXIT
export HELM_CONFIG_HOME="${T}/c" HELM_CACHE_HOME="${T}/k" HELM_DATA_HOME="${T}/d"   # the user's Helm setup is untouched
VERSION="$(sed -n 's/^CHART_VERSION="\(.*\)"/\1/p' platform/monitoring/install.sh)"
helm repo add pc https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 &&
  helm pull pc/kube-prometheus-stack --version "${VERSION}" --untar --untardir "${T}/chart" >/dev/null 2>&1 ||
  { echo "SKIP monitoring templates (chart ${VERSION} not reachable)"; exit 0; }

# chart_options is taken from the installer (it only builds the OPTIONS array).
eval "$(sed -n '/^chart_options() {/,/^}/p' platform/monitoring/install.sh)"
kinds() { awk '/^apiVersion:/{a=$2} /^kind:/{print a"/"$2}' "$1" | sort -u; }
for combo in "true true" "true false" "false true" "false false"; do
  set -- ${combo}; PROMETHEUS_ENABLED="$1"; GRAFANA_ENABLED="$2"; chart_options
  out="${T}/p$1-g$2.yaml"; label="prometheus=$1 grafana=$2"
  helm template prometheus-community "${T}/chart/kube-prometheus-stack" -n monitoring --values platform/monitoring/values.yaml --include-crds \
    --set-string "grafana.grafana\\.ini.auth.login_cookie_name=x" ${OPTIONS[@]+"${OPTIONS[@]}"} > "${out}" 2> "${T}/err" && r=ok || r=bad
  check "${label}: chart renders" "$r" "$(head -2 "${T}/err")"
  grep -q 'monitoring.coreos.com/v1/Prometheus$' <<< "$(kinds "${out}")" && has_p=1 || has_p=0
  grep -q 'kind: Deployment' "${out}" && grep -q 'charts/grafana/templates/deployment.yaml' "${out}" && has_g=1 || has_g=0
  [ "${has_p}" = "$([ "$1" = true ] && echo 1 || echo 0)" ] && r=ok || r=bad; check "${label}: Prometheus object expected $([ "$1" = true ] && echo present || echo absent)" "$r"
  [ "${has_g}" = "$([ "$2" = true ] && echo 1 || echo 0)" ] && r=ok || r=bad; check "${label}: Grafana Deployment expected $([ "$2" = true ] && echo present || echo absent)" "$r"
  if [ "$1" = false ]; then
    ! grep -q 'type: prometheus' "${out}" && r=ok || r=bad; check "${label}: no Prometheus datasource" "$r"
    ! grep -q 'monitoring.coreos.com' "${out}" && r=ok || r=bad; check "${label}: no monitoring.coreos.com object (no CRD needed)" "$r"
    ! grep -q 'kind: CustomResourceDefinition' "${out}" && r=ok || r=bad; check "${label}: no Prometheus Operator CRD rendered" "$r"
  else
    grep -q 'kind: CustomResourceDefinition' "${out}" && r=ok || r=bad; check "${label}: Prometheus Operator CRDs rendered (control: the CRD check above is meaningful)" "$r"
    { [ "$2" = false ] || grep -q 'type: prometheus' "${out}"; } && r=ok || r=bad; check "${label}: Prometheus datasource kept when Grafana runs" "$r"
  fi
done
# both enabled = unchanged behavior: no extra option is passed to the chart
PROMETHEUS_ENABLED=true; GRAFANA_ENABLED=true; chart_options
[ "${#OPTIONS[@]}" = 0 ] && r=ok || r=bad; check "both enabled: no chart option added (same release as before)" "$r" "${OPTIONS[*]}"
echo; [ "${FAIL}" = 0 ] && echo "ALL MONITORING TESTS PASSED" || echo "SOME MONITORING TESTS FAILED"; exit "${FAIL}"
