#!/usr/bin/env bash
# Regression tests for project-root resolution (SPEC-007.0 correction): the engine and the CLI must find the project
# whatever the working directory, and must not depend on any file that was removed (the old Makefile marker).
#  A. host-side: the real engine/usecase.sh sourced from a temporary tree, from many directories (no Docker needed),
#     plus a control run proving the test detects a missing marker.
#  B. container-side (skipped when the Playground is not running): the real use case scripts and the CLI, read-only
#     (status commands only; nothing is started, stopped or created).
# Run: tests/engine.sh
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
ROOT="$PWD"; FAIL=0
check() { if [ "$2" = ok ]; then echo "PASS $1"; else echo "FAIL $1   [$3]"; FAIL=1; fi; }
T="$(cd "$(mktemp -d)" && pwd -P)"; trap 'rm -rf "${T}"' EXIT

# --- A. temporary tree: <T>/{playground,engine -> repo engine,usecases/probe/p.sh} ----------------------------
mkdir -p "${T}/usecases/probe"; ln -s "${ROOT}/engine" "${T}/engine"; : > "${T}/playground"
cat > "${T}/usecases/probe/p.sh" <<'PROBE'
#!/usr/bin/env bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../engine/usecase.sh" || exit 1
printf 'ROOT=%s USECASE=%s CLUSTER=%s CONTEXT=%s CWD=%s\n' "${PROJECT_ROOT}" "${USECASE}" "${CLUSTER}" "${KUBE_CONTEXT}" "$(pwd)"
PROBE
want="ROOT=${T} USECASE=probe CLUSTER=cnpg-lab-probe-1 CONTEXT=kind-cnpg-lab-probe-1 CWD=${T}/usecases/probe"
for cwd in "/" "${T}" "${T}/usecases" "${T}/usecases/probe" "/tmp" "${ROOT}"; do
  out="$(cd "${cwd}" && bash "${T}/usecases/probe/p.sh" 2>&1)"
  [ "${out}" = "${want}" ] && r=ok || r=bad; check "engine/usecase.sh resolves the root from cwd=${cwd#"${T}"}$( [ "${cwd}" = "${T}" ] && echo '(root)')" "$r" "${out}"
done
# relative invocation of the script, from its own directory
out="$(cd "${T}/usecases/probe" && bash ./p.sh 2>&1)"; [ "${out}" = "${want}" ] && r=ok || r=bad; check "relative invocation (bash ./p.sh)" "$r" "${out}"
# control: without the marker the original failure is reproduced (so these tests really detect it)
rm -f "${T}/playground"
out="$(cd / && bash "${T}/usecases/probe/p.sh" 2>&1)"; echo "${out}" | grep -q "Cannot locate the project root" && r=ok || r=bad; check "control: a missing marker is detected ('Cannot locate the project root')" "$r" "${out}"
# the marker the engine looks for must exist in the real repository, and must not be a removed file
marker="$(grep -oE '\$\{PROJECT_ROOT\}/[A-Za-z_.-]+"' engine/usecase.sh | head -1 | sed 's/.*}\///; s/"//')"
[ -n "${marker}" ] && [ -e "${ROOT}/${marker}" ] && [ "${marker}" != "Makefile" ] && r=ok || r=bad; check "root marker used by engine/usecase.sh exists in the repository (${marker})" "$r"

# --- A2. usecase.yaml services (SPEC-012): strict validation, missing = false, scenarios reached through /usecases -----------
# A copy of the engine next to a throwaway use case: the parser reads usecases/<name>/usecase.yaml relative to common.sh.
M="$(cd "$(mktemp -d)" && pwd -P)"; trap 'rm -rf "${M}" "${T}"' EXIT
cp -R "${ROOT}/engine" "${M}/engine"; mkdir -p "${M}/usecases"
manifest() { mkdir -p "${M}/usecases/$1"; printf '%s\n' "${@:2}" > "${M}/usecases/$1/usecase.yaml"; }
head_="title: T"; desc_="description: D"
manifest ok "${head_}" "${desc_}" "infrastructure:" "  clusters: 2" "  workers_per_cluster: 3" "services:" "  cert_manager: true" "  minio: false" "  grafana: true"
chk() { ( source "${M}/engine/infrastructure/kind/common.sh"; usecase_manifest_check "$1" ) 2>&1; }
svc() { ( source "${M}/engine/infrastructure/kind/common.sh"; usecase_services "$1" ); }
[ -z "$(chk ok)" ] && r=ok || r=bad; check "manifest with a services section is valid" "$r" "$(chk ok)"
[ "$(svc ok)" = "cert_manager,grafana" ] && r=ok || r=bad; check "enabled services only; false and missing (minio, prometheus) are not installed" "$r" "$(svc ok)"
manifest nosvc "${head_}" "${desc_}" "infrastructure:" "  clusters: 1" "  workers_per_cluster: 1"
{ [ -z "$(chk nosvc)" ] && [ -z "$(svc nosvc)" ]; } && r=ok || r=bad; check "no services section: valid, nothing requested" "$r" "$(chk nosvc)"
manifest badbool "${head_}" "${desc_}" "infrastructure:" "  clusters: 1" "  workers_per_cluster: 1" "services:" "  minio: yes"
chk badbool | grep -q "services.minio' must be true or false" && r=ok || r=bad; check "non-boolean service value refused" "$r" "$(chk badbool)"
manifest typo "${head_}" "${desc_}" "infrastructure:" "  clusters: 1" "  workers_per_cluster: 1" "services:" "  prometeus: true"
chk typo | grep -q "unknown service 'prometeus'" && r=ok || r=bad; check "unknown service key (typo) refused" "$r" "$(chk typo)"
manifest zero "${head_}" "${desc_}" "infrastructure:" "  clusters: 0" "  workers_per_cluster: 1"
chk zero | grep -q "positive integer" && r=ok || r=bad; check "clusters: 0 still refused" "$r" "$(chk zero)"
for n in $(ls "${ROOT}/usecases"); do
  [ -f "${ROOT}/usecases/${n}/usecase.yaml" ] || continue
  s="$(source "${ROOT}/engine/infrastructure/kind/common.sh"; usecase_manifest_check "${n}" 2>&1; usecase_services "${n}")"
  # Each use case chooses its services: the manifest is valid and only known service keys are requested.
  case ",${s}," in *[!a-z_,]*|*,,*) r=bad ;; *) r=ok ;; esac
  for k in $(echo "${s}" | tr ',' ' '); do case "${k}" in cert_manager|minio|prometheus|grafana) ;; *) r=bad ;; esac; done
  check "${n}: valid manifest, requests only known services (${s:-none})" "$r" "${s}"
done
# A scenario started through the /usecases symlink must still find the project root (pwd -P in engine/usecase.sh).
L="${M}/link"; mkdir -p "${M}/real/usecases/probe" "${M}/real/engine"; touch "${M}/real/playground"
cp "${ROOT}/engine/usecase.sh" "${M}/real/engine/usecase.sh"; cp -R "${ROOT}/engine/lib" "${ROOT}/engine/infrastructure" "${M}/real/engine/"
ln -s "${M}/real/usecases" "${L}"
printf '#!/usr/bin/env bash\nsource "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../engine/usecase.sh"\necho "ROOT=${PROJECT_ROOT} UC=${USECASE}"\n' > "${M}/real/usecases/probe/p.sh"
out="$(cd "${L}/probe" && bash ./p.sh 2>&1)"; [ "${out}" = "ROOT=${M}/real UC=probe" ] && r=ok || r=bad
check "scenario run from a symlinked usecases directory finds the project root" "$r" "${out}"

# --- B. real scripts inside the running Playground (read-only) -------------------------------------------------------
if command -v docker >/dev/null 2>&1 && [ "$(docker inspect -f '{{.State.Running}}' cnpg-playground 2>/dev/null)" = "true" ]; then
  names="$(docker exec cnpg-playground bash /workspace/engine/usecase-list.sh --names)"
  for n in ${names}; do
    for cwd in / /tmp /workspace "/workspace/usecases/${n}"; do
      [ -d "${ROOT}${cwd#/workspace}" ] || [ "${cwd}" = / ] || [ "${cwd}" = /tmp ] || continue
      out="$(docker exec -w "${cwd}" cnpg-playground bash /workspace/engine/usecase-run.sh status "${n}" 2>&1)"; rc=$?
      if [ "${rc}" = 0 ] && ! grep -q "Cannot locate" <<< "${out}"; then r=ok; else r=bad; fi
      check "usecase-run.sh status ${n} from cwd=${cwd} (rc=0)" "$r" "rc=${rc} $(echo "${out}" | head -1)"
      out="$(docker exec -w "${cwd}" cnpg-playground /workspace/playground usecase status "${n}" 2>&1)"; rc=$?
      if [ "${rc}" = 0 ] && ! grep -q "Cannot locate" <<< "${out}"; then r=ok; else r=bad; fi
      check "playground usecase status ${n} from cwd=${cwd}" "$r" "rc=${rc} $(echo "${out}" | head -1)"
    done
    # the scenario resolves its root first; with no cluster it then stops with 'not reachable' / 'context not found' (never starts anything)
    clusters="$(docker exec cnpg-playground bash /workspace/engine/usecase-list.sh | awk -F'\t' -v n="${n}" '$1==n {print $2}')"
    if [ "${clusters:-0}" = 0 ]; then
      sc="$(ls "${ROOT}/usecases/${n}/"[0-9]*.sh 2>/dev/null | head -1)"
      if [ -n "${sc}" ]; then
        out="$(docker exec -w "/workspace/usecases/${n}" cnpg-playground bash "/workspace/usecases/${n}/$(basename "${sc}")" 2>&1 </dev/null)"
        if ! grep -q "Cannot locate" <<< "${out}" && grep -qE "Enter to continue|not reachable|context not found" <<< "${out}"; then r=ok; else r=bad; fi
        check "scenario of ${n}: root resolved, then stops cleanly without a cluster (at its first pause or the missing cluster)" "$r" "$(echo "${out}" | tail -1)"
      fi
    else
      echo "SKIP scenario root check for ${n} (it has running clusters: a scenario would run interactively)"
    fi
  done
else
  echo "SKIP container-side checks (the Playground is not running)"
fi
echo; [ "${FAIL}" = 0 ] && echo "ALL ENGINE TESTS PASSED" || echo "SOME ENGINE TESTS FAILED"; exit "${FAIL}"
