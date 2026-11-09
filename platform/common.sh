# Helpers shared by the platform installers. Sourced, not executed.
# Installers take an explicit Kubernetes context and never change the current one.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/engine/lib/logger.sh"

CONTEXT=""

# Usage: use_context "$@"   (expects <kube-context> as the first argument)
use_context() {
  CONTEXT="${1:-}"
  [ -n "${CONTEXT}" ] || die "Usage: $0 <kube-context>"
  local tool
  for tool in kubectl helm; do
    command -v "${tool}" >/dev/null 2>&1 || die "${tool} is not installed"
  done
  kc get nodes >/dev/null 2>&1 || die "Context ${CONTEXT} is not reachable (does the cluster exist? try: playground infra status)"
}

kc() { kubectl --context "${CONTEXT}" "$@"; }

# Platform workloads run on the control-plane (tainted); its taint is tolerated in the values files.
label_control_plane() {
  log_run kubectl --context "${CONTEXT}" label nodes -l node-role.kubernetes.io/control-plane \
    playground.edb.io/role=platform --overwrite
}
