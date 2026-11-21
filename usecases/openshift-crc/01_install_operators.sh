#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../engine/lib/ui.sh"
source "${SCRIPT_DIR}/../../engine/usecase.sh"
source "${SCRIPT_DIR}/../../.env"
export EDB_SUBSCRIPTION_TOKEN
: "${EDB_SUBSCRIPTION_TOKEN:?Missing EDB_SUBSCRIPTION_TOKEN in .env}"

show_instruct() {
  ui_note "
# 01 / Install the EDB operator with OLM

Install the EDB Postgres AI for CloudNativePG operator (package
cloud-native-postgresql) on OpenShift Local with the oc CLI and OLM.

## Objectives
- Configure EDB registry authentication
- Check the operator package in the certified-operators catalog
- Create the OLM Subscription (cluster-wide install)
- Verify the ClusterServiceVersion, CRDs and operator pod

## Prerequisites
- OpenShift Local (CRC) running, cluster-admin access
- EDB subscription token configured in .env

## Expected outcome
The operator is installed in openshift-operators and its CRDs are available.
"
  ui_pause
}

play() {
  ui_info "Switch to the OpenShift Kubernetes context"
  ui_command "oc config use-context ${KUBE_CONTEXT}"
  ui_pause

  ui_info "Verify the OpenShift identity and nodes"
  ui_command "oc whoami"
  ui_command "oc get nodes"
  ui_pause

  ui_info "Create the EDB registry pull secret in openshift-operators"
  ui_command 'oc -n openshift-operators create secret docker-registry postgresql-operator-pull-secret --docker-server=docker.enterprisedb.com --docker-username=k8s --docker-password="$EDB_SUBSCRIPTION_TOKEN" --dry-run=client -o yaml | oc apply -f -'
  ui_pause

  ui_info "Confirm the operator package is available in the certified-operators catalog"
  ui_command "oc get packagemanifests -n openshift-marketplace cloud-native-postgresql"
  ui_pause

  ui_info "Inspect install modes and channels"
  ui_command "oc describe packagemanifests -n openshift-marketplace cloud-native-postgresql"
  ui_pause

  ui_info "Review the Subscription manifest"
  ui_command "cat ${SCRIPT_DIR}/manifests/subscription.yaml"
  ui_pause

  ui_info "Create the Subscription (the default global-operators OperatorGroup is used)"
  ui_command "oc apply -f ${SCRIPT_DIR}/manifests/subscription.yaml"
  ui_pause

  ui_info "Wait for the InstallPlan to be created"
  ui_command "oc -n openshift-operators wait subscription/cloud-native-postgresql --for=jsonpath='{.status.installPlanRef.name}' --timeout=300s"
  ui_pause

  ui_info "Check the InstallPlan"
  ui_command "oc get installplan -n openshift-operators"
  ui_pause

  ui_info "Wait for the ClusterServiceVersion to succeed"
  ui_command "oc -n openshift-operators wait csv -l operators.coreos.com/cloud-native-postgresql.openshift-operators --for=jsonpath='{.status.phase}'=Succeeded --timeout=600s"
  ui_pause

  ui_info "Verify the ClusterServiceVersion"
  ui_command "oc get csv -n openshift-operators"
  ui_pause

  ui_info "Verify the operator CRDs"
  ui_command "oc get crd | grep postgresql"
  ui_pause

  ui_info "Verify the operator service account"
  ui_command "oc get serviceaccounts -n openshift-operators | grep postgresql-operator-manager"
  ui_pause

  ui_info "Verify the operator ClusterRole"
  ui_command "oc get clusterrole --selector=olm.owner.kind=ClusterServiceVersion | grep -i postgresql"
  ui_pause

  ui_info "Verify the operator pod"
  ui_command "oc get pods -n openshift-operators"
  ui_pause

  ui_success "EDB operator installed successfully with OLM!"
}

main() {
  clear
  show_instruct
  play
}

main "$@"
