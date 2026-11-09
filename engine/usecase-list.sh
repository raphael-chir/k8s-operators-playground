#!/usr/bin/env bash
# Read-only: list the valid use cases and how many Kind clusters each owns, as "<name><TAB><clusters>".
# A valid use case is a directory under usecases/ with a valid usecase.yaml (SPEC-012) and
# a name the CLI accepts (lowercase letters, digits, dashes). Cluster ownership is usecase_clusters (engine/infrastructure/kind/common.sh).
# With --names: only the names (no Docker or Kind access), used for the terminal tabs.
# With --meta: "<name><TAB><title><TAB><description>" (no Docker or Kind access), used by the Web UI.
# Exits non-zero (and prints nothing) if the Docker Engine or Kind cannot be queried, so callers never
# mistake "cannot tell" for "stopped". Used by the Web UI (web/app.py).
set -Eeuo pipefail
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${PROJECT_ROOT}/engine/infrastructure/kind/common.sh"

mode="${1:-}"

if [ -z "${mode}" ]; then
  docker info >/dev/null 2>&1 || { echo "Docker Engine unreachable" >&2; exit 2; }
  kind get clusters >/dev/null 2>&1 || { echo "kind could not list clusters" >&2; exit 2; }
fi

for dir in "${PROJECT_ROOT}"/usecases/*/; do
  name="$(basename "${dir}")"
  [[ "${name}" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] || continue
  [ -f "${dir}usecase.yaml" ] || continue
  reason="$(usecase_manifest_check "${name}")" || { echo "Skipping use case ${name}: ${reason}" >&2; continue; }
  case "${mode}" in
    --names) printf '%s\n' "${name}"; continue ;;
    --meta) printf '%s\t%s\t%s\n' "${name}" "$(usecase_config "${name}" title)" "$(usecase_config "${name}" description)"; continue ;;
  esac
  count="$(usecase_clusters "${name}" | grep -c . || true)"
  printf '%s\t%s\n' "${name}" "${count}"
done
