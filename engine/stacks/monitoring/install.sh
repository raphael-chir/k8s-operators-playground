#!/usr/bin/env bash
# Install or reconcile kube-prometheus-stack (Prometheus + Grafana) and the CNPG dashboard.
# Prometheus and Grafana are independent (same chart, conditional values): PROMETHEUS_ENABLED and GRAFANA_ENABLED
# (true|false, default true) select what is installed; both false installs nothing. The CNPG dashboard needs both.
# Usage: engine/stacks/monitoring/install.sh <kube-context>
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ../common.sh

CHART_VERSION="92.11.0"
RELEASE="prometheus-community"
NAMESPACE="monitoring"
# Local demo only: fixed credentials, set in values.yaml.
GRAFANA_USER="admin"
GRAFANA_PASSWORD="password"
PROMETHEUS_ENABLED="${PROMETHEUS_ENABLED:-true}"
GRAFANA_ENABLED="${GRAFANA_ENABLED:-true}"

# Browsers scope cookies by hostname, not port: every Grafana on localhost would share the default
# "grafana_session" cookie and log the others out. A per-cluster name fixes that. Derived from the
# context only (provider_context_id: kind-cnpg-lab-cnpg-distributed-topology-2 -> grafana_session_cnpg_distributed_topology_2), so it is
# stable across Helm upgrades and restarts.
cookie_name() {
  local name
  name="$(provider_context_id "${CONTEXT}")"
  printf 'grafana_session_%s' "${name//[^A-Za-z0-9]/_}"
}

# Chart values for what is NOT requested. Without Prometheus: no operator, Alertmanager, kube-state-metrics, rules or
# control-plane ServiceMonitors, no Grafana datasource, and no Prometheus Operator CRDs. The CRDs come from the
# chart's "crds" sub-chart (its crds/ directory, controlled by crds.enabled alone, not by the operator): Helm creates
# them on install only and never upgrades or deletes them. Grafana alone then has no datasource.
chart_options() {
  OPTIONS=()
  if [ "${PROMETHEUS_ENABLED}" != true ]; then
    OPTIONS+=(--set prometheus.enabled=false --set prometheusOperator.enabled=false --set alertmanager.enabled=false
      --set kubeStateMetrics.enabled=false --set crds.enabled=false --set defaultRules.create=false
      --set kubelet.enabled=false --set kubeApiServer.enabled=false --set coreDns.enabled=false --set kubeDns.enabled=false
      --set kubeEtcd.enabled=false --set kubeScheduler.enabled=false --set kubeProxy.enabled=false
      --set grafana.serviceMonitor.enabled=false --set grafana.sidecar.datasources.defaultDatasourceEnabled=false)
  fi
  [ "${GRAFANA_ENABLED}" = true ] || OPTIONS+=(--set grafana.enabled=false)
}

# An existing release is never reduced: a Helm upgrade without Prometheus would remove its Prometheus, operator and
# rules (the CRDs would stay, as Helm never deletes them), and without Grafana it would remove Grafana. A manifest
# change applies to new clusters only.
refuse_reduction() {
  helm status "${RELEASE}" --kube-context "${CONTEXT}" -n "${NAMESPACE}" >/dev/null 2>&1 || return 0
  if [ "${PROMETHEUS_ENABLED}" != true ] && kc get crd prometheuses.monitoring.coreos.com >/dev/null 2>&1; then
    log_warn "Monitoring is already installed with Prometheus on ${CONTEXT}: not reconfigured (an existing install is never reduced)"
    return 1
  fi
  if [ "${GRAFANA_ENABLED}" != true ] && kc -n "${NAMESPACE}" get deployment "${RELEASE}-grafana" >/dev/null 2>&1; then
    log_warn "Monitoring is already installed with Grafana on ${CONTEXT}: not reconfigured (an existing install is never reduced)"
    return 1
  fi
}

install_monitoring() {
  local cookie
  cookie="$(cookie_name)"
  chart_options
  log_info "Prometheus: ${PROMETHEUS_ENABLED}, Grafana: ${GRAFANA_ENABLED}"
  log_info "Grafana session cookie: ${cookie}"
  log_info "Installing kube-prometheus-stack ${CHART_VERSION}"
  log_run helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update
  log_run helm upgrade --install "${RELEASE}" prometheus-community/kube-prometheus-stack \
    --kube-context "${CONTEXT}" --namespace "${NAMESPACE}" --create-namespace \
    --version "${CHART_VERSION}" --values values.yaml \
    --set-string "grafana.grafana\\.ini.auth.login_cookie_name=${cookie}" \
    "${OPTIONS[@]}" \
    --hide-notes --wait --timeout 10m
}

wait_for_components() {
  local selector
  log_info "Waiting for monitoring pods"
  if [ "${PROMETHEUS_ENABLED}" = true ]; then
    for selector in "app.kubernetes.io/name=prometheus" "app=kube-prometheus-stack-operator"; do
      log_run kubectl --context "${CONTEXT}" -n "${NAMESPACE}" wait --for=condition=Ready pod -l "${selector}" --timeout=300s
    done
    log_success "Prometheus ready"
  fi
  if [ "${GRAFANA_ENABLED}" = true ]; then
    log_run kubectl --context "${CONTEXT}" -n "${NAMESPACE}" wait --for=condition=Ready pod -l "app.kubernetes.io/name=grafana" --timeout=300s
    log_success "Grafana ready"
  fi
}

# Grafana's API is reached through a temporary kubectl port-forward (the node ports are published on
# the provider's host, not on this container's localhost; kubectl is all a stack may assume). Same approach as the previous playground:
# POST the dashboard with overwrite=true on its fixed uid, so reruns update it in place (no duplicate).
GRAFANA_URL=""
PF_PID=""
PF_LOG=""

stop_port_forward() {
  [ -z "${PF_PID}" ] || kill "${PF_PID}" 2>/dev/null || true
  [ -z "${PF_LOG}" ] || rm -f "${PF_LOG}"
}

start_port_forward() {
  local i port
  PF_LOG="$(mktemp)"
  kubectl --context "${CONTEXT}" -n "${NAMESPACE}" port-forward --address 127.0.0.1 \
    "svc/${RELEASE}-grafana" :80 >"${PF_LOG}" 2>&1 &
  PF_PID=$!
  trap stop_port_forward EXIT
  for (( i = 1; i <= 30; i++ )); do
    port="$(sed -n 's/^Forwarding from 127.0.0.1:\([0-9]*\).*/\1/p' "${PF_LOG}" | head -n 1)"
    if [ -n "${port}" ]; then
      GRAFANA_URL="http://127.0.0.1:${port}"
      return 0
    fi
    kill -0 "${PF_PID}" 2>/dev/null || die "kubectl port-forward to Grafana failed: $(cat "${PF_LOG}")"
    sleep 1
  done
  die "kubectl port-forward to Grafana did not become ready"
}

# Usage: grafana_api <method> <path> [body-file]; prints the body, returns 1 on non-2xx.
grafana_api() {
  local method="$1" path="$2" body="${3:-}" status out
  out="$(mktemp)"
  status="$(curl -sS --max-time 30 -o "${out}" -w '%{http_code}' -u "${GRAFANA_USER}:${GRAFANA_PASSWORD}" \
    -X "${method}" -H 'Content-Type: application/json' ${body:+--data-binary @"${body}"} \
    "${GRAFANA_URL}${path}" || echo 000)"
  cat "${out}"; rm -f "${out}"
  case "${status}" in 2??) return 0 ;; *) log_error "Grafana API ${method} ${path}: HTTP ${status}" >&2; return 1 ;; esac
}

wait_for_grafana_api() {
  local i
  for (( i = 1; i <= 30; i++ )); do
    curl -fsS --max-time 5 "${GRAFANA_URL}/api/health" >/dev/null 2>&1 && { log_success "Grafana API is healthy"; return 0; }
    sleep 2
  done
  die "Grafana did not answer on /api/health"
}

import_dashboard() {
  local i uid response payload
  log_info "Importing CNPG dashboard"
  # An earlier version provisioned the dashboard from a ConfigMap; it would clash on the same uid.
  kc -n "${NAMESPACE}" delete configmap cnpg-dashboard --ignore-not-found >/dev/null
  payload="$(mktemp)"
  { printf '{"dashboard":'; cat cnpg-dashboard.json; printf ',"overwrite":true,"folderId":0}'; } > "${payload}"
  for (( i = 1; i <= 5; i++ )); do
    response="$(grafana_api POST /api/dashboards/db "${payload}")" && break
    [ "${i}" -lt 5 ] || { rm -f "${payload}"; die "CNPG dashboard import failed: ${response}"; }
    log_warn "Dashboard import attempt ${i}/5 failed, retrying"
    sleep 3
  done
  rm -f "${payload}"
  uid="$(jq -r '.uid // empty' <<< "${response}")"
  [ -n "${uid}" ] || die "Dashboard imported but no uid in response: ${response}"
  printf '{"homeDashboardUID":"%s"}' "${uid}" > "${payload}"
  grafana_api PATCH /api/org/preferences "${payload}" >/dev/null || { rm -f "${payload}"; die "Could not set the home dashboard"; }
  rm -f "${payload}"
  log_success "CNPG dashboard imported (uid ${uid}) and set as home dashboard"
}

# One dashboard with this title, and its Prometheus data source answers queries.
verify_dashboard() {
  local title count ds
  title="$(jq -r .title cnpg-dashboard.json)"
  count="$(grafana_api GET "/api/search?type=dash-db" | jq --arg t "${title}" '[.[] | select(.title == $t)] | length')"
  [ "${count}" = "1" ] || die "Expected 1 dashboard '${title}', found ${count}"
  ds="$(jq -r '.templating.list[] | select(.type == "datasource") | .current.value' cnpg-dashboard.json | head -n 1)"
  grafana_api GET "/api/datasources/proxy/uid/${ds}/api/v1/query?query=up" | jq -e '.status == "success"' >/dev/null ||
    die "Prometheus data source '${ds}' used by the dashboard does not answer queries"
  log_success "Dashboard '${title}' present once; data source '${ds}' (Prometheus) answers queries"
}

use_context "$@"
if [ "${PROMETHEUS_ENABLED}" != true ] && [ "${GRAFANA_ENABLED}" != true ]; then
  log_info "Monitoring not requested (Prometheus and Grafana disabled): nothing to install"
  exit 0
fi
log_section "Installing monitoring on ${CONTEXT}"
refuse_reduction || exit 0
install_monitoring
wait_for_components
if [ "${GRAFANA_ENABLED}" = true ]; then
  start_port_forward
  wait_for_grafana_api
  if [ "${PROMETHEUS_ENABLED}" = true ]; then
    import_dashboard
    verify_dashboard
  else
    log_info "Prometheus disabled: Grafana has no Prometheus data source and the CNPG dashboard is not imported"
  fi
fi
log_success "Monitoring ready on ${CONTEXT}"
