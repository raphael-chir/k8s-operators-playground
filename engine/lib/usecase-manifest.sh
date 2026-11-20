# The use case manifest, usecases/<name>/usecase.yaml: parsing, services and validation. Provider independent
# (a use case never names a Kubernetes provider). Sourced, not executed; resolves usecases/ relative to this file
# (engine/lib/), so a copy of engine/ next to a throwaway usecases/ works (tests/engine.sh).
# usecases/<name>/usecase.yaml. Deliberately NOT a YAML parser: it reads the one flat schema
#   title: ...   description: ...   infrastructure: { clusters: N, workers_per_cluster: N }   (indented two spaces)
#   provider: { type: internal | external, name: kind | k3d | openshift | eks ..., context: <kubeconfig context> }   (optional; default internal/kind;
#             name is required when the section exists; context is required for external)
# Usage: usecase_config <usecase> <key>, key = title | name | description | infrastructure.clusters | infrastructure.workers_per_cluster |
#        provider.type | provider.name | provider.context | services.<name>
_usecase_config_raw() {
  awk -v want="$2" -v q="'" '
    /^[ \t]*(#|$)/ { next }
    { indent = match($0, /[^ ]/) - 1; line = substr($0, indent + 1)
      key = line; sub(/:.*/, "", key)
      val = line; sub(/^[^:]*:[ ]*/, "", val); sub(/[ ]+$/, "", val)
      if (indent == 0) { sec = ""; name = key; if (val == "") { sec = key; next } } else name = sec "." key
      gsub("^[\"" q "]|[\"" q "]$", "", val)
      if (name == want) { print val; exit } }' "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/usecases/$1/usecase.yaml" 2>/dev/null
}

# The value of a key; a missing `title` falls back to `name` (an external use case may declare only `name`).
usecase_config() {
  local value
  value="$(_usecase_config_raw "$1" "$2")"
  if [ -z "${value}" ] && [ "$2" = title ]; then value="$(_usecase_config_raw "$1" name)"; fi
  printf '%s\n' "${value}"
}

# The Kubernetes provider of a use case (usecase.yaml `provider:`). type = who owns the cluster lifecycle (internal: the Playground, external:
# the user); name = the Kubernetes product: for internal it selects the engine (engine/providers/<name>/), for external it only identifies the
# platform (openshift, eks...). No provider section = internal / kind (backward compatible).
usecase_provider_type() { local t; t="$(usecase_config "$1" provider.type)"; printf '%s' "${t:-internal}"; }
usecase_provider_name() {
  local n; n="$(usecase_config "$1" provider.name)"
  [ -n "${n}" ] || [ -n "$(usecase_config "$1" provider.type)" ] || n=kind
  printf '%s' "${n}"
}
# The provider IMPLEMENTATION to load (engine/providers/<it>/provider.sh): the shared external one, or the internal engine named by provider.name.
# An internal name is never replaced by Kind: an unsupported one fails when it is loaded (and in usecase_manifest_check).
usecase_provider() {
  if [ "$(usecase_provider_type "$1")" = external ]; then printf 'external'; else usecase_provider_name "$1"; fi
}

# Platform services a use case can request in usecase.yaml (section "services:", explicit true|false, missing = false).
PLATFORM_SERVICE_KEYS="cert_manager minio prometheus grafana"

# Prints the services the manifest enables, comma separated, in installation order (e.g. cert_manager,minio,grafana).
usecase_services() {
  local key list=""
  for key in ${PLATFORM_SERVICE_KEYS}; do
    [ "$(usecase_config "$1" "services.${key}")" != true ] || list="${list:+${list},}${key}"
  done
  printf '%s' "${list}"
}

# Succeeds when usecases/<usecase>/usecase.yaml exists with a title, a description, positive integer
# infrastructure values and, if present, a services section of known keys with true|false values;
# otherwise prints the reason and fails.
usecase_manifest_check() {
  local name="$1" key value file type pname
  file="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/usecases/${name}/usecase.yaml"
  [ -f "${file}" ] || { echo "usecases/${name}/usecase.yaml not found"; return 1; }
  for key in title description; do
    [ -n "$(usecase_config "${name}" "${key}")" ] || { echo "usecases/${name}/usecase.yaml: '${key}' is missing"; return 1; }
  done
  value="$(usecase_config "${name}" name)"
  [ -z "${value}" ] || [ "${value}" = "${name}" ] || { echo "usecases/${name}/usecase.yaml: 'name' must be the directory name (${name})"; return 1; }
  type="$(usecase_provider_type "${name}")"; pname="$(usecase_provider_name "${name}")"
  if [ -n "$(usecase_config "${name}" provider.type)$(usecase_config "${name}" provider.name)$(usecase_config "${name}" provider.context)" ]; then
    [[ "${pname}" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] || { echo "usecases/${name}/usecase.yaml: 'provider.name' is required with a provider section (e.g. kind, k3d, openshift, eks)"; return 1; }
  fi
  case "${type}" in
    internal)
      [ -z "$(usecase_config "${name}" provider.context)" ] || { echo "usecases/${name}/usecase.yaml: 'provider.context' is only for provider type external"; return 1; }
      [ "${pname}" != external ] && [ -f "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/providers/${pname}/provider.sh" ] ||
        { echo "usecases/${name}/usecase.yaml: unsupported internal provider '${pname}' (available: kind)"; return 1; } ;;
    external)
      value="$(usecase_config "${name}" provider.context)"
      [[ "${value}" =~ ^[A-Za-z0-9][A-Za-z0-9._:/@+-]*$ ]] || { echo "usecases/${name}/usecase.yaml: provider type external needs 'provider.context' (a kubeconfig context name)"; return 1; }
      case "${value}" in kind-*) echo "usecases/${name}/usecase.yaml: 'provider.context' must not be a Kind context (${value})"; return 1 ;; esac
      # An external cluster is user-managed: no stacks are installed on it, so a services section is refused (never silently ignored).
      grep -qE '^services:' "${file}" && { echo "usecases/${name}/usecase.yaml: 'services' is not allowed with provider type external (no stacks are installed on an external cluster)"; return 1; } ;;
    *) echo "usecases/${name}/usecase.yaml: unknown provider type '${type}' (expected: internal, external)"; return 1 ;;
  esac
  if [ "${type}" = internal ]; then
    for key in infrastructure.clusters infrastructure.workers_per_cluster; do
      value="$(usecase_config "${name}" "${key}")"
      [[ "${value}" =~ ^[1-9][0-9]*$ ]] || { echo "usecases/${name}/usecase.yaml: '${key}' must be a positive integer"; return 1; }
    done
  fi
  # Keys written under "services:" (a typo must not silently mean "false").
  for key in $(awk '/^[ \t]*(#|$)/ { next } /^[^ ]/ { sec = ($0 ~ /^services:[ ]*$/); next } sec { k = $1; sub(/:.*/, "", k); print k }' "${file}"); do
    case " ${PLATFORM_SERVICE_KEYS} " in
      *" ${key} "*) ;;
      *) echo "usecases/${name}/usecase.yaml: unknown service '${key}' (expected: ${PLATFORM_SERVICE_KEYS})"; return 1 ;;
    esac
  done
  for key in ${PLATFORM_SERVICE_KEYS}; do
    value="$(usecase_config "${name}" "services.${key}")"
    case "${value}" in
      ""|true|false) ;;
      *) echo "usecases/${name}/usecase.yaml: 'services.${key}' must be true or false"; return 1 ;;
    esac
  done
}
