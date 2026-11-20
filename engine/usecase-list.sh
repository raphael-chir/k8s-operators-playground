#!/usr/bin/env bash
# Read-only: list the valid use cases and how many Kind clusters each owns, as "<name><TAB><clusters>".
# A valid use case is a directory under usecases/ with a valid usecase.yaml and
# a name the CLI accepts (lowercase letters, digits, dashes). Cluster ownership is provider_list (engine/lib/provider.sh).
# With --names: only the names (no Docker or Kind access), used for the terminal tabs.
# With --meta: "<name><TAB><title><TAB><description>"; with --providers: "<name><TAB><provider type><TAB><provider name>" (no Docker or Kind access), used by the Web UI.
# Exits non-zero (and prints nothing) if the Docker Engine or Kind cannot be queried, so callers never
# mistake "cannot tell" for "stopped". Used by the Web UI (web/app.py).
set -Eeuo pipefail
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${PROJECT_ROOT}/engine/lib/logger.sh"
source "${PROJECT_ROOT}/engine/lib/usecase-manifest.sh"
source "${PROJECT_ROOT}/engine/lib/provider.sh"

mode="${1:-}"

if [ -z "${mode}" ]; then
  provider_check_available || exit 2
fi

for dir in "${PROJECT_ROOT}"/usecases/*/; do
  name="$(basename "${dir}")"
  [[ "${name}" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] || continue
  [ -f "${dir}usecase.yaml" ] || continue
  reason="$(usecase_manifest_check "${name}")" || { echo "Skipping use case ${name}: ${reason}" >&2; continue; }
  case "${mode}" in
    --names) printf '%s\n' "${name}"; continue ;;
    --meta) printf '%s\t%s\t%s\n' "${name}" "$(usecase_config "${name}" title)" "$(usecase_config "${name}" description)"; continue ;;
    --providers) printf '%s\t%s\t%s\n' "${name}" "$(usecase_provider_type "${name}")" "$(usecase_provider_name "${name}")"; continue ;;
  esac
  if [ "$(usecase_provider "${name}")" = kind ]; then
    count="$(provider_list "${name}" | grep -c . || true)"
  else   # another provider: its functions would collide with Kind's, so ask it in its own process
    count="$(PLAYGROUND_PROVIDER="$(usecase_provider "${name}")" bash -c 'source "$1/engine/lib/provider.sh"; provider_list "$2" | grep -c . || true' _ "${PROJECT_ROOT}" "${name}")"
  fi
  printf '%s\t%s\n' "${name}" "${count}"
done
