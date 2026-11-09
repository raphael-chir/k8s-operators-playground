#!/usr/bin/env bash
# Read-only: the names of the existing Kind clusters that belong to the playground (managed_clusters in
# engine/infrastructure/kind/common.sh: <prefix>-<usecase>-<n>), one per line. Foreign clusters are ignored.
# Exits non-zero if Kind cannot be queried, so callers never mistake "cannot tell" for "none".
# Used by the Web UI resource monitor (web/app.py).
set -Eeuo pipefail
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${PROJECT_ROOT}/engine/infrastructure/kind/common.sh"

kind get clusters >/dev/null 2>&1 || { echo "kind could not list clusters" >&2; exit 2; }
managed_clusters
