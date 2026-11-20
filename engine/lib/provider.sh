# Selects the Kubernetes provider and loads its contract (the provider_* functions). Sourced, not executed.
# The provider is chosen by PLAYGROUND_PROVIDER (default: kind), never by a use case. A provider is a directory
# engine/providers/<name>/ whose provider.sh implements the contract documented in engine/providers/kind/provider.sh.
# The generic engine calls only provider_* functions: it never names Kind, Docker or a node.
PLAYGROUND_PROVIDER="${PLAYGROUND_PROVIDER:-kind}"
if ! [[ "${PLAYGROUND_PROVIDER}" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]; then
  echo "Invalid Kubernetes provider name '${PLAYGROUND_PROVIDER}'" >&2; return 1
fi
PROVIDER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../providers" && pwd)/${PLAYGROUND_PROVIDER}"
if [ ! -f "${PROVIDER_DIR}/provider.sh" ]; then
  echo "Unknown Kubernetes provider '${PLAYGROUND_PROVIDER}' (no engine/providers/${PLAYGROUND_PROVIDER}/provider.sh)" >&2; return 1
fi
source "${PROVIDER_DIR}/provider.sh"
