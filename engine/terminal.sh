#!/usr/bin/env bash
# One terminal = one Bash process. ttyd runs this script for every browser connection; there is
# no session manager: opening, refreshing or closing a terminal starts or ends its Bash, nothing else.
#   terminal.sh [usecase [panel]]
# No use case = the Playground terminal (starts in /usecases); a use case terminal starts in
# /usecases/<name> (where its scenarios are) and is valid only for a use case reported by
# engine/usecase-list.sh. ttyd passes the page's ?arg=<usecase> as the first argument. Split view: an
# additional panel of a use case tab passes its number (2-4) as the second argument; it has its own kubeconfig file
# and always starts on the use case's context. Panel 1 is the tab's primary terminal, exactly as before.
set -Eeuo pipefail
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KUBE_TERMINALS_DIR="${KUBE_TERMINALS_DIR:-${HOME}/.kube/terminals}"
source "${PROJECT_ROOT}/engine/lib/usecase-manifest.sh"

fail() { echo "terminal: $*" >&2; exit 1; }

# A container created before the session manager was removed still runs ttyd with the former `attach` argument: ignore it.
[ "${1:-}" != attach ] || shift
usecase="${1:-}"
panel="${2:-}"
[ -z "${panel}" ] || { [ -n "${usecase}" ] && [[ "${panel}" =~ ^[2-4]$ ]]; } || fail "invalid panel"

# /usecases is a symlink to /workspace/usecases (created by engine/entrypoint.sh) that keeps the prompt short: Bash keeps
# the logical path through cd. A container started before the link existed falls back to the real directory.
usecases_dir=/usecases
[ -d "${usecases_dir}" ] || usecases_dir="${PROJECT_ROOT}/usecases"

if [ -z "${usecase}" ]; then
  session="playground-main"
  dir="${usecases_dir}"
else
  [[ "${usecase}" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] || fail "invalid use case name"
  # Captured first: grep -q closing the pipe early would make the lister fail under pipefail.
  names="$(bash "${PROJECT_ROOT}/engine/usecase-list.sh" --names)" || fail "use case discovery failed"
  grep -Fxq -- "${usecase}" <<< "${names}" || fail "unknown use case '${usecase}'"
  [ -n "${PLAYGROUND_PROVIDER:-}" ] || PLAYGROUND_PROVIDER="$(usecase_provider "${usecase}")"
  session="playground-uc-${usecase}"
  dir="${usecases_dir}/${usecase}"
  [ -z "${panel}" ] || session="${session}-p${panel}"
fi

source "${PROJECT_ROOT}/engine/lib/provider.sh"   # provider_cluster_name / provider_context (of the use case's provider)

# Context a new terminal starts with: a use case terminal selects cluster 1 of its use case (derived from the Kind
# naming helpers, whether or not that cluster exists yet); Playground selects the shared default context.
initial_context() {
  local context known
  if [ -n "${usecase}" ]; then
    provider_context "$(provider_cluster_name "${usecase}" 1)"
  else
    # Playground: the shared default, but never a context that does not exist (it does not depend on any cluster).
    context="$(env -u KUBECONFIG kubectl config current-context 2>/dev/null || true)"
    known="$(env -u KUBECONFIG kubectl config get-contexts -o name 2>/dev/null || true)"   # captured: grep -q + pipefail
    if [ -n "${context}" ] && grep -Fxq -- "${context}" <<< "${known}"; then
      printf '%s' "${context}"
    fi
  fi
}

# The terminal's own kubeconfig file holds only its current context. The shell lists it first in KUBECONFIG, ahead
# of the shared ~/.kube/config (clusters, users, contexts), see engine/shell/bashrc. A context this terminal already
# has is kept (an explicit selection survives a browser refresh). The file is rewritten with that context alone: kubectl
# resolves a cluster or user from the FIRST file that defines it, so any copy of them left in this file (old tools,
# a manual edit) would shadow the shared file and break kubectl after a cluster is recreated (stale certificates).
write_context_file() {
  local file="${KUBE_TERMINALS_DIR}/${session}.yaml" context=""
  mkdir -p "${KUBE_TERMINALS_DIR}"
  # A split panel never inherits: it begins on the use case's context (a refresh gives a fresh panel anyway).
  [ -n "${panel}" ] || context="$(sed -n 's/^current-context:[[:space:]]*//p' "${file}" 2>/dev/null | head -1 | tr -d "\"'")"
  [ -n "${context}" ] || context="$(initial_context)"
  { printf 'apiVersion: v1\nkind: Config\n'; [ -z "${context}" ] || printf 'current-context: %s\n' "${context}"; } > "${file}"
  printf '%s' "${file}"
}

# The container has no UTF-8 locale (LANG unset): without one, Bash editing and Vim treat the terminal as single-byte. C.UTF-8 ships with Debian; it is set here so no image rebuild setting is needed.
export LANG=C.UTF-8
export PLAYGROUND_KUBECONFIG
PLAYGROUND_KUBECONFIG="$(write_context_file)"
cd "${dir}"
exec bash
