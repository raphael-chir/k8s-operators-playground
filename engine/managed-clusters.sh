#!/usr/bin/env bash
# Read-only: the names of the existing Kind clusters that belong to the playground (managed_clusters in
# engine/lib/provider.sh: <prefix>-<usecase>-<n> with Kind, and with k3d when installed), one per line. Foreign clusters are ignored.
# Exits non-zero if Kind cannot be queried, so callers never mistake "cannot tell" for "none".
# Used by the Web UI resource monitor (web/app.py).
set -Eeuo pipefail
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${PROJECT_ROOT}/engine/lib/provider.sh"

provider_check_available || exit 2
provider_list
# The other internal provider (k3d), when this image has it: its clusters count too. Never fatal (k3d is optional).
if [ "${PLAYGROUND_PROVIDER}" = kind ] && command -v k3d >/dev/null 2>&1; then
  PLAYGROUND_PROVIDER=k3d bash -c 'source "$1/engine/lib/provider.sh"; provider_check_available && provider_list' _ "${PROJECT_ROOT}" 2>/dev/null || true
fi
