# Helpers shared by the platform installers. Sourced, not executed.
# Installers take an explicit Kubernetes context and never change the current one.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/logger.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/provider.sh"   # provider_context_id (the only provider-specific fact a stack needs)

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
