#!/usr/bin/env bash
# Non-destructive tests of the cnpg-standard scenarios. No cluster, no Docker, no network:
#  A. static: the six scenarios + reset, no helper library, manifests, images, context rule, no leftovers.
#  B. each scenario run end to end with a FAKE kubectl/docker/sleep on PATH: the commands sent, the prompts, the
#     upgrade patches, the reset scope and its failure path. This is NOT a runtime validation of the scenarios.
# Bash 3.2 compatible (macOS host). Run: tests/scenarios.sh   (a few minutes: the scenarios "type" their commands)
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
ROOT="$PWD"; FAIL=0; UC="${ROOT}/usecases/cnpg-standard"; SC="${UC}"
check() { if [ "$2" = ok ]; then echo "PASS $1"; else echo "FAIL $1   [$3]"; FAIL=1; fi; }
ok_if() { if eval "$2"; then check "$1" ok; else check "$1" bad "$3"; fi; }
T="$(mktemp -d)"; trap 'rm -rf "${T}"' EXIT

# --- A. static --------------------------------------------------------------------------------------------------
SIX="01_deploy_cluster.sh 02_data_workload.sh 03_backup_restore.sh 04_high_availability.sh 05_cluster_administration.sh 06_postgresql_upgrades.sh"
ALLSC="${SIX} 99_reset_lab.sh"
ok_if "the use case root holds exactly the six scenarios and the reset as scripts (no lib.sh, no scenarios/ directory)" '[ "$(ls "${SC}"/*.sh | xargs -n1 basename | tr "\n" " ")" = "${ALLSC} " ] && [ ! -e "${SC}/scenarios" ]' "$(ls "${SC}"/*.sh | xargs -n1 basename | tr '\n' ' ')"
ok_if "scenario discovery ([0-9]*.sh) lists the six and the reset, in order" '[ "$(cd "${SC}" && ls [0-9]*.sh | tr "\n" " ")" = "${ALLSC} " ]'
for f in ${ALLSC}; do
  p="${SC}/${f}"; bad=""
  [ -x "${p}" ] || bad="${bad} not-executable"
  bash -n "${p}" 2>/dev/null || bad="${bad} syntax"
  grep -q 'engine/lib/ui.sh' "${p}" && grep -q 'engine/usecase.sh' "${p}" && grep -q '^main "\$@"' "${p}" || bad="${bad} template"
  extra="$(grep -E '^[A-Za-z_][A-Za-z0-9_]*\(\)' "${p}" | grep -vE '^(show_instruct|play|main)\(\)')"; [ -z "${extra}" ] || bad="${bad} helper-function"
  grep -qE 'lib\.sh|scenario_[a-z_]+|KUBECONFIG|kubectl --context' "${p}" && bad="${bad} helper/context-logic"
  # `|| true` only displays an optional listing in 99 (kubectl get ... || true); nowhere else
  [ "${f}" = 99_reset_lab.sh ] || ! grep -q '|| true' "${p}" || bad="${bad} defensive"
  [ -z "${bad}" ] && r=ok || r=bad; check "${f}: executable, valid syntax, template, no helper function, no lib, no '|| true' except the listing of 99, no KUBECONFIG handling" "$r" "${bad}"
done
ok_if "context: only 01 selects it, with the Playground's KUBE_CONTEXT" 'grep -q "kubectl config use-context \${KUBE_CONTEXT}" "${SC}/01_deploy_cluster.sh" && ! grep -lE "use-context|current-context" "${SC}"/0[2-6]*.sh | grep -q .'
ok_if "manifests are exactly cluster.yaml and restore-cluster.yaml, both referenced" '[ "$(ls "${UC}/manifests" | tr "\n" " ")" = "cluster.yaml restore-cluster.yaml " ] && grep -q "manifests/cluster.yaml" "${SC}/01_deploy_cluster.sh" && grep -q "manifests/restore-cluster.yaml" "${SC}/03_backup_restore.sh"'
bad=""
for m in "${UC}"/manifests/*.yaml; do
  if command -v yq >/dev/null 2>&1; then yq eval '.' "${m}" >/dev/null 2>&1 || bad="${bad} $(basename "${m}"):yaml"; fi
  grep -qE '^[[:space:]]*namespace:' "${m}" && bad="${bad} $(basename "${m}"):namespace"
  ! grep -q 'playground.edb.io' "${m}" || bad="${bad} $(basename "${m}"):node-label"
done
command -v yq >/dev/null 2>&1 || echo "SKIP manifest YAML parsing (yq not installed)"
ok_if "manifests: valid YAML, no namespace, no Playground node label (the control-plane taint keeps PostgreSQL on the workers)" '[ -z "${bad}" ]' "${bad}"
cl="${UC}/manifests/cluster.yaml"
ok_if "cluster.yaml: 3 instances, Barman plugin as WAL archiver, ObjectStore, PodMonitor, PostgreSQL 17.5 bookworm" \
  'grep -q "instances: 3" "${cl}" && grep -q "isWALArchiver: true" "${cl}" && grep -q "kind: ObjectStore" "${cl}" && grep -q "kind: PodMonitor" "${cl}" && grep -q "postgresql:17.5-standard-bookworm$" "${cl}"'
ok_if "restore-cluster.yaml: recovery from the 17.5 bookworm backup" 'grep -q "recovery:" "${UC}/manifests/restore-cluster.yaml" && grep -q "serverName: cnpg-cluster$" "${UC}/manifests/restore-cluster.yaml" && grep -q "postgresql:17.5-standard-bookworm$" "${UC}/manifests/restore-cluster.yaml"'
imgs="$(grep -hoE 'cloudnative-pg/postgresql:[A-Za-z0-9._-]+' "${UC}"/manifests/*.yaml "${SC}"/*.sh | sort -u | sed 's#cloudnative-pg/postgresql:##' | tr '\n' ' ')"
ok_if "PostgreSQL images are explicit Bookworm tags: ${imgs}" '[ "${imgs}" = "17.5-standard-bookworm 17.6-standard-bookworm 18-standard-bookworm " ]'
mc="$(sed -n 's/^MC_IMAGE="\(.*\)"/\1/p' "${SC}/99_reset_lab.sh")"
plat="$(awk '/^mcImage:/{f=1} f&&/repository:/{r=$2} f&&/tag:/{print r":"$2; exit}' "${ROOT}/engine/stacks/minio/values.yaml")"
ok_if "reset uses the platform's pinned MinIO client image (${mc})" '[ -n "${mc}" ] && [ "${mc}" = "${plat}" ]' "platform: ${plat}"
ok_if "dynamic commands kept: primary and replica found by label (04), version checks and upgrade patches (06)" 'grep -q "instanceRole=primary" "${SC}/04_high_availability.sh" && grep -q "instanceRole=replica" "${SC}/04_high_availability.sh" && grep -q "type merge" "${SC}/06_postgresql_upgrades.sh" && grep -q "type json" "${SC}/06_postgresql_upgrades.sh" && grep -q "SHOW server_version" "${SC}/06_postgresql_upgrades.sh"'
hits="$(grep -nE '01_install|05_create_data|06_backup_cluster|07_restore|08_minor|09_cluster_admin|10_major|11_cluster-fail|12_major|scenarios/manifests|microservice|major-upgraded|cnpg-community-cluster|fencing|lib\.sh' "${SC}"/*.sh "${UC}"/manifests/*.yaml "${UC}/README.md")"
ok_if "no obsolete script, manifest, import-upgrade or lib.sh reference in the use case" '[ -z "${hits}" ]' "$(echo "${hits}" | head -3)"
hits="$(grep -rnE '01_install-cnpg|05_create_data|scenarios/manifests|(06_backup|07_restore|08_minor|09_cluster_admin|10_major|11_cluster-fail|12_major)[a-z_-]*\.sh' "${ROOT}/README.md" "${ROOT}/tests/engine.sh" "${ROOT}/web" "${ROOT}/engine" 2>/dev/null | grep -v 'cnpg-distributed-topology')"
ok_if "no reference to a removed scenario in the other docs, tests, web and engine" '[ -z "${hits}" ]' "$(echo "${hits}" | head -3)"
hits="$(grep -nE '\$\{?USER\}?|PUBLIC_IP|ipify|:3010|:9010|:4200|node\.workshop|k3d|ec2-user|WORKSHOP_|cnpg-hands-on|kind-cnpg-lab|cnpg-lab-[a-z]|localhost:[0-9]|(^|[^a-zA-Z])make( |$)|Makefile|gum ' "${SC}"/*.sh "${UC}"/manifests/*.yaml | grep -v 'make sure')"
ok_if "no workshop user/IP/port/node/context hard-coded, no Make, no gum" '[ -z "${hits}" ]' "$(echo "${hits}" | head -3)"
hits="$(grep -nE 'delete [^|;]*--all|--namespace| -n default' "${SC}"/*.sh)"
ok_if "no broad deletion (--all) and no namespace switching in any scenario" '[ -z "${hits}" ]' "${hits}"
hits="$(grep -rnE 'BEGIN [A-Z ]*PRIVATE KEY|AKIA[0-9A-Z]{12}|ghp_[A-Za-z0-9]{20}|xox[bp]-' "${UC}")"
ok_if "no secrets in the use case (admin/password are the documented local MinIO/Grafana defaults)" '[ -z "${hits}" ]' "${hits}"
SRCREPO="${ROOT}/../se-demos-k8s-cnpg-workshop"; REFREPO="${ROOT}/../cnpg-operator-playground-local"
if [ -d "${SRCREPO}/.git" ] && command -v git >/dev/null 2>&1; then
  ok_if "workshop repository has no local modification" '[ -z "$(git -C "${SRCREPO}" status --porcelain 2>/dev/null)" ]'
else echo "SKIP workshop repository check (no Git repository)"; fi
[ ! -d "${REFREPO}" ] || ok_if "previous local Playground: no file modified since this repository's VERSION file" '[ -z "$(find "${REFREPO}" -path "${REFREPO}/.git" -prune -o -type f -newer "${ROOT}/VERSION" -print | head -1)" ]'
echo "INFO scenario sizes (lines): $(cd "${SC}" && wc -l *.sh | tr -s ' ' | tr '\n' ',' | sed 's/,$//')"

# --- B. flows with a fake kubectl / docker / sleep ----------------------------------------------------------------
FB="${T}/fakebin"; LOG="${T}/calls.log"; mkdir -p "${FB}" "${T}/h/.kube"; : > "${LOG}"
CTX="kind-cnpg-lab-cnpg-standard-1"
printf 'apiVersion: v1\nkind: Config\ncurrent-context: %s\n' "${CTX}" > "${T}/term.yaml"
cat > "${FB}/kubectl" <<'FAKE'
#!/usr/bin/env bash
echo "KC=${KUBECONFIG}|kubectl $*" >> "${FAKE_LOG}"
a="$*"
case "${a}" in
  "config current-context") echo "${FAKE_CTX:-kind-cnpg-lab-cnpg-standard-1}" ;;
  "cnpg") echo "A plugin to manage your CloudNativePG clusters" ;;
  *"get nodes"*) echo "node Ready" ;;
  *"get svc"*"minio-console"*) echo 30090 ;;
  *"get svc"*) echo 30080 ;;
  *"instanceRole=replica"*) echo cnpg-cluster-2 ;;
  *"instanceRole=primary"*) echo cnpg-cluster-1 ;;
  *"spec.cluster.name=='restored-cnpg-cluster'"*) echo b-two ;;
  *"spec.cluster.name=='cnpg-cluster'"*) echo b-one ;;
  *"data.uri"*) printf 'postgresql://app@cnpg-cluster-rw:5432/app' | base64 ;;
  *MINIO_ACCESS_KEY*) printf 'admin' | base64 ;;
  *MINIO_SECRET_KEY*) printf 'password' | base64 ;;
  *"run minio-reset-mc"*) [ "${FAKE_MC_FAIL:-0}" = 1 ] && { echo "mc: <ERROR> Unable to initialize" >&2; exit 1; } || echo "mc ok" ;;
  *) echo "(fake kubectl) ${a}" ;;
esac
exit 0
FAKE
printf '#!/usr/bin/env bash\ncase "$1" in port) echo "0.0.0.0:31000" ;; esac\nexit 0\n' > "${FB}/docker"
# info.sh is the Playground's own URL mechanism (it needs Bash >= 4.2 and runs in the container): answered here, everything else runs the real bash
printf '#!/bin/sh\ncase "$1" in */info.sh) echo "KC=${KUBECONFIG}|bash $*" >> "${FAKE_LOG}"; echo "Grafana:       http://localhost:31000"; echo "MinIO Console: http://localhost:31001"; exit 0 ;; esac\nexec %s "$@"\n' "$(command -v bash)" > "${FB}/bash"
printf '#!/usr/bin/env bash\nexit 0\n' > "${FB}/sleep"
printf '#!/bin/sh\nexec cat "$@"\n' > "${FB}/vim"   # scenarios may open a manifest in vim: the fake just prints it
chmod +x "${FB}/kubectl" "${FB}/docker" "${FB}/sleep" "${FB}/bash" "${FB}/vim"
yes '' | head -n 400 > "${T}/yes.txt"    # Enter at every prompt (a file: command substitution would strip the newlines)
yes n  | head -n 400 > "${T}/no.txt"     # 'n' at every prompt: pauses continue, confirmations are refused
ALL="${T}/all.log"; : > "${ALL}"
# run <script> <yes|no> [VAR=value ...]  -> OUT, RC; LOG holds this run's kubectl calls
run() {
  local script="$1" input="$2"; shift 2; : > "${LOG}"
  OUT="$(cd / && env HOME="${T}/h" KUBECONFIG="${T}/term.yaml:${T}/h/.kube/config" TERM=xterm-256color NO_COLOR=1 FAKE_LOG="${LOG}" PATH="${FB}:${PATH}" "$@" bash "${SC}/${script}" < "${T}/${input}.txt" 2>&1)"; RC=$?
  cat "${LOG}" >> "${ALL}"
}
called() { grep -qF -- "$1" "${LOG}"; }
nocall() { ! grep -qF -- "$1" "${LOG}"; }
line()   { grep -nF -- "$1" "${LOG}" | head -1 | cut -d: -f1; }
noerr()  { ! grep -qE "Cannot locate|No such file|command not found|unbound variable|syntax error" <<< "${OUT}"; }
boxes()  { grep -qE '[╭╮╰╯┌┐└┘│─]' <<< "${OUT}" && grep -q 'Press Enter to continue' <<< "${OUT}"; }

run 01_deploy_cluster.sh yes
ok_if "01: rc=0, boxes and prompts; the Playground's context is the first thing selected" '[ "${RC}" = 0 ] && noerr && boxes && [ "$(line "config use-context ${CTX}")" = 1 ]' "rc=${RC} $(head -2 "${LOG}")"
ok_if "01: MinIO secret created, then cluster.yaml applied, then the status watch; nothing deleted" 'called "create secret generic minio-secret --from-literal=MINIO_ACCESS_KEY=admin --from-literal=MINIO_SECRET_KEY=password" && called "apply -f manifests/cluster.yaml" && [ "$(line "create secret")" -lt "$(line "cluster.yaml")" ] && called "cnpg status cnpg-cluster" && nocall " delete "'
run 02_data_workload.sh yes
ok_if "02: connection secret, pgbench init then query then workload, jobs waited for" '[ "${RC}" = 0 ] && called "pgbench --job-name pgb-init cnpg-cluster" && called "wait --for=condition=complete job/pgb-init" && called "SELECT count(*)" && called "--job-name pgb-run" && noerr' "rc=${RC}"
run 03_backup_restore.sh yes
ok_if "03: plugin backup, waited until completed, then the restore manifest, data and version checked on the restored cluster" '[ "${RC}" = 0 ] && called "cnpg backup cnpg-cluster --backup-name cnpg-cluster-backup --method plugin --plugin-name barman-cloud.cloudnative-pg.io" && called "jsonpath={.status.phase}=completed backup/cnpg-cluster-backup" && called "apply -f manifests/restore-cluster.yaml" && [ "$(line "cnpg backup")" -lt "$(line "restore-cluster.yaml")" ] && called "psql restored-cnpg-cluster" && called "SHOW server_version" && noerr' "rc=${RC}"
run 04_high_availability.sh yes
ok_if "04: replica and primary discovered by label; switchover, then the discovered primary pod deleted, volumes untouched" '[ "${RC}" = 0 ] && called "cnpg promote cnpg-cluster cnpg-cluster-2" && called "delete pod cnpg-cluster-1 --grace-period=0 --force" && [ "$(line "cnpg promote")" -lt "$(line "delete pod")" ] && ! grep -E "delete .*(pvc|pv)\b" "${LOG}" | grep -q .' "rc=${RC}"
run 04_high_availability.sh no
ok_if "04: failure refused at the confirmation -> no pod deleted" 'called "cnpg promote" && nocall " delete "'
run 05_cluster_administration.sh yes
ok_if "05: scale 3 -> 2 -> 3 and hibernation on -> off, all by merge patch; ends resumed; no manifest applied" '[ "${RC}" = 0 ] && called "\"instances\":2" && called "\"instances\":3" && [ "$(line "\"instances\":2")" -lt "$(line "\"instances\":3")" ] && called "cnpg.io/hibernation\":\"on" && [ "$(grep "cnpg.io/hibernation" "${LOG}" | tail -1 | grep -c "\"off\"")" = 1 ] && nocall "apply -f"' "rc=${RC}"
run 06_postgresql_upgrades.sh yes
ok_if "06: minor merge patch to 17.6 bookworm, then ONE json patch (18 bookworm + Barman serverName), in that order" '[ "${RC}" = 0 ] && called "type merge -p {\"spec\":{\"imageName\":\"ghcr.io/cloudnative-pg/postgresql:17.6-standard-bookworm\"}}" && called "type json" && called "ghcr.io/cloudnative-pg/postgresql:18-standard-bookworm" && called "/spec/plugins/0/parameters/serverName" && called "cnpg-cluster-pg18" && [ "$(line "type merge")" -lt "$(line "type json")" ]' "rc=${RC}"
ok_if "06: versions and status displayed; in place (no apply, no create, no delete)" 'called "SHOW server_version" && called "SELECT version()" && called "cnpg status cnpg-cluster" && nocall "apply -f" && nocall "create cluster" && nocall " delete "'
run 06_postgresql_upgrades.sh no
ok_if "06: major upgrade refused at the confirmation -> only the minor patch was sent" '[ "${RC}" = 0 ] && called "type merge" && nocall "type json"'
for s in 02_data_workload.sh 03_backup_restore.sh 04_high_availability.sh 05_cluster_administration.sh 06_postgresql_upgrades.sh; do
  run "${s}" yes; ok_if "${s}: no context call, every kubectl call under the terminal's own KUBECONFIG" '! grep -qE "use-context|current-context" "${LOG}" && ! grep "^KC=" "${LOG}" | grep -vF "KC=${T}/term.yaml:${T}/h/.kube/config|" | grep -q .' "$(grep -E 'use-context|current-context' "${LOG}" | head -1)"
done
run 99_reset_lab.sh yes
ok_if "99: deletes the Backups of the two lab clusters only (not foreign ones), the jobs by name, the two clusters, no --all" '[ "${RC}" = 0 ] && called "delete backup.postgresql.cnpg.io b-one" && called "delete backup.postgresql.cnpg.io b-two" && nocall "b-foreign" && called "delete job pgb-init pgb-run --ignore-not-found" && called "delete cluster.postgresql.cnpg.io cnpg-cluster --ignore-not-found" && called "delete cluster.postgresql.cnpg.io restored-cnpg-cluster --ignore-not-found" && ! grep -q -- "--all" "${LOG}"' "rc=${RC}"
ok_if "99: pinned MinIO client image, one run per scenario prefix, each with versions and a trailing slash (cnpg-cluster must not match cnpg-cluster-pg18), no bucket-level removal" '[ "$(grep -c "run minio-reset-mc" "${LOG}")" = 3 ] && called "--image=${mc}" && called "mc rm --recursive --force --versions minio/cnpg/cnpg-cluster/" && called "mc rm --recursive --force --versions minio/cnpg/cnpg-cluster-pg18/" && called "mc rm --recursive --force --versions minio/cnpg/restored-cnpg-cluster/" && [ "$(grep -c "mc rm " "${LOG}")" = 3 ] && ! grep -qE "mc rb|minio/cnpg/( |\"|$)" "${LOG}"' "$(grep -c 'run minio-reset-mc' "${LOG}") runs"
ok_if "99: a pod left by an interrupted run is removed before the first MinIO run; the run keeps its output (no spinner) and a failed run cannot block the next" '[ "$(line "delete pod minio-reset-mc --ignore-not-found")" -lt "$(line "run minio-reset-mc")" ] && grep -q -- "--rm" "${SC}/99_reset_lab.sh" && ! grep -q "ui_spin" "${SC}/99_reset_lab.sh"'
ok_if "99: the cleanup command is the proven one (mc rm --recursive --force --versions) with the alias set in the same sh -c" 'grep -q "mc alias set minio" "${SC}/99_reset_lab.sh" && grep -q "mc rm --recursive --force --versions minio/\${MINIO_BUCKET}/\${prefix}/" "${SC}/99_reset_lab.sh"'
ok_if "99: ObjectStore and secret removed only after the MinIO cleanup; operator, plugin, monitoring untouched" '[ "$(line "run minio-reset-mc")" -lt "$(line "delete secret minio-secret")" ] && nocall "helm" && nocall "cnpg-system" && nocall "delete namespace" && grep -q "reset completed" <<< "${OUT}"'
run 99_reset_lab.sh no
ok_if "99: refused at the confirmation -> nothing deleted, no MinIO pod" '[ "${RC}" = 0 ] && nocall " delete " && nocall "minio-reset-mc"' "rc=${RC}"
run 99_reset_lab.sh yes FAKE_MC_FAIL=1
ok_if "99: MinIO failure: the client's own error is visible, exit code 1, secret and ObjectStore kept for a retry, no success claimed" '[ "${RC}" = 1 ] && grep -q "mc: <ERROR> Unable to initialize" <<< "${OUT}" && grep -q "Failed to purge MinIO prefix" <<< "${OUT}" && nocall "delete secret minio-secret" && nocall "delete objectstores" && ! grep -q "Lab reset completed" <<< "${OUT}"' "rc=${RC}"
ok_if "the only manifests ever applied are cluster.yaml and restore-cluster.yaml" '! grep -E "apply -f" "${ALL}" | grep -vE "apply -f manifests/(cluster|restore-cluster).yaml$" | grep -q .'
for cwd in "${SC}" "${UC}" /tmp "${T}"; do
  OUT="$(cd "${cwd}" && env HOME="${T}/h" KUBECONFIG="${T}/term.yaml" TERM=xterm-256color NO_COLOR=1 FAKE_LOG="${LOG}" PATH="${FB}:${PATH}" bash "${SC}/03_backup_restore.sh" < "${T}/yes.txt" 2>&1)"; RC=$?
  ok_if "03 run by absolute path from cwd=${cwd#"${ROOT}"/}: manifest found" '[ "${RC}" = 0 ] && noerr && grep -q "kind: Cluster" <<< "${OUT}"' "rc=${RC} $(echo "${OUT}" | tail -1)"
done
OUT="$(cd "${SC}" && env HOME="${T}/h" KUBECONFIG="${T}/term.yaml" TERM=xterm-256color NO_COLOR=1 FAKE_LOG="${LOG}" PATH="${FB}:${PATH}" bash ./02_data_workload.sh < "${T}/yes.txt" 2>&1)"; RC=$?
ok_if "02 run as ./02_data_workload.sh from its directory" '[ "${RC}" = 0 ]' "rc=${RC}"
echo "INFO distinct mutating commands recorded from the fake runs (never sent):"
grep -hE 'kubectl (apply|delete|create|patch|run|cnpg (backup|promote|pgbench))' "${ALL}" | sed 's/^KC=[^|]*|/  /' | cut -c1-170 | sort -u

[ "${FAIL}" = 0 ] && echo "ALL SCENARIO TESTS PASSED" || echo "SCENARIO TESTS FAILED"
exit "${FAIL}"
