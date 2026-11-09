#!/usr/bin/env bash
# Use case lifecycle, run by `./playground usecase start|stop|status NAME` (and so by the Web UI).
# Everything a use case needs is declared in usecases/<name>/usecase.yaml; the functions are in engine/usecase.sh.
# Usage: usecase-run.sh start|stop|status <name>      (stop: FORCE=1 skips the confirmation)
set -Eeuo pipefail
action="${1:-}"; name="${2:-}"
[[ "${name}" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] || { echo "A use case name is required (a directory under usecases/)." >&2; exit 1; }
export PLAYGROUND_USECASE="${name}"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/usecase.sh"
case "${action}" in
  start)  usecase_start ;;
  stop)   usecase_delete ;;
  status) usecase_status ;;
  *) die "Usage: $0 start|stop|status <name>" ;;
esac
