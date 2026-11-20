#!/usr/bin/env bash
# Runs INSIDE the Playground container. Usage: import.sh <usecase>   (stdin: a kubeconfig holding ONLY the use case's context, as
# produced on the host by `kubectl config view --minify --flatten --raw --context <ctx>`; ./playground usecase start does the piping).
# Stores it as ~/.kube/external/<usecase>.yaml (mode 600) after checks, without ever printing a credential or touching the cluster:
#   * exactly the configured context, with its original names, TLS settings and credentials;
#   * an authentication plugin (exec) that is missing in this image is reported, nothing is installed;
#   * if the API address does not work from inside Docker (api.crc.testing -> 127.0.0.1 is the container itself), it is tested again
#     through host.docker.internal with tls-server-name set to the original host, so TLS verification stays on.
set -Eeuo pipefail
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "${PROJECT_ROOT}/engine/lib/logger.sh"
source "${PROJECT_ROOT}/engine/lib/usecase-manifest.sh"
usecase="${1:-}"
[[ "${usecase}" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] || die "Usage: $0 <usecase> < kubeconfig"
[ "$(usecase_provider "${usecase}")" = external ] || die "Use case ${usecase} does not use provider type external"
want="$(usecase_config "${usecase}" provider.context)"

umask 077
tmp="$(mktemp)"; trap 'rm -f "${tmp}"' EXIT
cat > "${tmp}"
[ -s "${tmp}" ] || die "No kubeconfig received on stdin"
cfg() { KUBECONFIG="${tmp}" kubectl "$@"; }

json="$(cfg config view --raw -o json 2>/dev/null)" || die "The received kubeconfig is not valid"
[ "$(jq '.contexts | length' <<< "${json}")" = 1 ] && [ "$(jq -r '.contexts[0].name' <<< "${json}")" = "${want}" ] ||
  die "Expected exactly the context '${want}' in the received kubeconfig"
cluster="$(jq -r '.contexts[0].context.cluster' <<< "${json}")"
user="$(jq -r '.contexts[0].context.user' <<< "${json}")"
server="$(jq -r --arg c "${cluster}" '.clusters[] | select(.name == $c) | .cluster.server' <<< "${json}")"
[ -n "${server}" ] || die "Context '${want}' has no cluster server"

# External authentication plugin (cloud providers): report a missing command instead of installing tooling.
exec_cmd="$(jq -r --arg u "${user}" '.users[] | select(.name == $u) | .user.exec.command // empty' <<< "${json}")"
if [ -n "${exec_cmd}" ] && ! command -v "${exec_cmd}" >/dev/null 2>&1; then
  die "Context '${want}' authenticates through the command '${exec_cmd}', which is not installed in the Playground image. Not supported yet; nothing was imported."
fi

# Reachability class of the API with the credentials as they are: ok | auth (answers, credentials refused) | down.
probe() {   # <kubeconfig>
  local out
  if out="$(KUBECONFIG="$1" kubectl --context "${want}" --request-timeout=10s get --raw /readyz 2>&1)"; then echo ok; return; fi
  case "${out}" in *nauthorized*|*"must be logged in"*) echo auth ;; *) echo down ;; esac
}

state="$(probe "${tmp}")"
rewritten=""
if [ "${state}" = down ]; then
  hostport="${server#*://}"; hostport="${hostport%%/*}"; host="${hostport%%:*}"; port="${hostport##*:}"
  [ "${port}" != "${hostport}" ] || port=443
  alt="$(mktemp)"; cp "${tmp}" "${alt}"
  KUBECONFIG="${alt}" kubectl config set-cluster "${cluster}" --server="https://host.docker.internal:${port}" --tls-server-name="${host}" >/dev/null
  alt_state="$(probe "${alt}")"
  if [ "${alt_state}" != down ]; then mv "${alt}" "${tmp}"; state="${alt_state}"; rewritten="https://host.docker.internal:${port} (TLS name ${host})"; else rm -f "${alt}"; fi
fi

# Never carry a current-context: the shared one is not ours to change.
cfg config unset current-context >/dev/null 2>&1 || true
mkdir -p "${HOME}/.kube/external"; chmod 700 "${HOME}/.kube/external"
cp "${tmp}" "${HOME}/.kube/external/${usecase}.yaml"; chmod 600 "${HOME}/.kube/external/${usecase}.yaml"

log_success "Imported context '${want}' for use case ${usecase} (server ${rewritten:-${server}})"
case "${state}" in
  ok)   log_success "The API answers from the Playground container and TLS is verified" ;;
  auth) log_warn "The API answers, but the credentials were refused (expired token?). Log in again on the host, then rerun ./playground usecase start ${usecase}" ;;
  down) log_warn "The API at ${server} is not reachable from the Playground container (neither directly nor through host.docker.internal). Nothing was changed on the cluster, Docker or the host." ;;
esac
