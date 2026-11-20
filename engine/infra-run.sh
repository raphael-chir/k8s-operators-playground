#!/usr/bin/env bash
# Infrastructure commands, run by `./playground infra up|platform-up|down|info|status [CLUSTER...]` (container side).
# The CLI validates its arguments and calls this; the Kubernetes provider (engine/lib/provider.sh) does the work, so the
# CLI never names a provider's scripts. WORKERS (exported by the CLI) is the number of workers for `up`.
# Usage: infra-run.sh up|platform-up|down|info|status <cluster>...
set -Eeuo pipefail
ENGINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${ENGINE_DIR}/lib/logger.sh"
source "${ENGINE_DIR}/lib/provider.sh"
action="${1:-}"; [ $# -gt 0 ] && shift
case "${action}" in
  up)          provider_create "${WORKERS:-}" "$@" ;;
  platform-up) exec bash "${ENGINE_DIR}/stacks/up.sh" "$@" ;;
  down)        provider_destroy "$@" ;;
  info)        provider_info "$@" ;;
  status)      provider_status "$@" ;;
  *) die "Usage: $0 up|platform-up|down|info|status [cluster...]" ;;
esac
