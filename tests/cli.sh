#!/usr/bin/env bash
# CLI tests with a fake `docker` on PATH: every call is recorded, nothing real is touched, so the destructive
# commands (stop, restart, uninstall, purge) can be exercised safely. Bash 3.2 compatible. Run: tests/cli.sh
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
ROOT="$PWD"; CLI="${ROOT}/playground"
T="$(mktemp -d)"; trap 'rm -rf "${T}"' EXIT
mkdir -p "${T}/bin"; LOG="${T}/calls.log"; : > "${LOG}"
FAIL=0
check() { if [ "$2" = ok ]; then echo "PASS $1"; else echo "FAIL $1   [$3]"; FAIL=1; fi; }
# t <name> <expected-rc> <command...>: runs the CLI, captures output in $OUT and rc in $RC
run() { OUT="$("$@" 2>&1 </dev/null)"; RC=$?; }
calls() { cat "${LOG}"; }

# --- fake docker ---------------------------------------------------------------------------------------------
cat > "${T}/bin/docker" <<'FAKE'
#!/usr/bin/env bash
echo "docker $*" >> "${FAKE_LOG}"
case "$1" in
  --version) echo "Docker version 28.0.1, build x" ;;
  info) echo "14 17514426368" ;;
  inspect)
    case "$*" in
      *State.Running*) [ "${FAKE_RUNNING:-1}" = 1 ] && echo true || echo false ;;
      *State.Status*)  [ "${FAKE_RUNNING:-1}" = 1 ] && echo running || echo exited ;;
      *) [ "${FAKE_RUNNING:-1}" = 1 ] ;;
    esac ;;
  port) [ "${FAKE_RUNNING:-1}" = 1 ] && echo "127.0.0.1:8080" ;;
  exec) case "$*" in *pgrep*) [ "${FAKE_SESSIONS:-0}" -gt 0 ] && printf '41\n42\n' ;; esac ;;
  ps)
    case "$*" in
      *"-q"*label=io.x-k8s.kind.cluster=cnpg-lab-cnpg-standard-1*) printf 'id1\nid2\n' ;;
      *"-q"*) : ;;
      *label=io.x-k8s.kind.cluster*)
        printf 'cnpg-lab-cnpg-standard-1 running\ncnpg-lab-cnpg-standard-1 running\n'
        printf 'someone-elses-cluster-1 running\ncnpg-lab-lookalike running\n' ;;   # foreign + wrong pattern
    esac ;;
  volume) echo "cnpg-operator-playground_kube"; echo "cnpg-operator-playground_history" ;;
  rm) ;;
  compose)
    case "$*" in *" version"*) echo "2.33.1" ;; esac ;;
esac
exit 0
FAKE
chmod +x "${T}/bin/docker"
export FAKE_LOG="${LOG}" PATH="${T}/bin:${PATH}"
cli() { PLAYGROUND_CONTEXT=host "${CLI}" "$@"; }

# --- basics ---------------------------------------------------------------------------------------------------
V="$(cat VERSION)"
run cli version;  [ "${RC}" = 0 ] && [ "${OUT}" = "CNPG Operator Playground v${V}" ] && r=ok || r=bad; check "version prints v\$(VERSION)" "$r" "${OUT}"
run cli --help;   [ "${RC}" = 0 ] && grep -q "Usage:" <<< "${OUT}" && grep -q "purge " <<< "${OUT}" && grep -q "usecase start NAME" <<< "${OUT}" && r=ok || r=bad; check "--help lists the commands" "$r" "rc=${RC}"
run cli help;     [ "${RC}" = 0 ] && r=ok || r=bad; check "help alias" "$r"
run cli bogus;    [ "${RC}" = 2 ] && r=ok || r=bad; check "unknown command -> exit 2" "$r" "rc=${RC}"
PLAYGROUND_CONTEXT=container run "${CLI}" usecase bogus; [ "${RC}" = 2 ] && r=ok || r=bad; check "container: unknown usecase sub-command -> exit 2" "$r" "rc=${RC}"
PLAYGROUND_CONTEXT=container run "${CLI}" infra bogus;   [ "${RC}" = 2 ] && r=ok || r=bad; check "container: unknown infra sub-command -> exit 2" "$r" "rc=${RC}"
run cli infra;    [ "${RC}" = 1 ] && grep -q "Usage" <<< "${OUT}" && r=ok || r=bad; check "'infra' alone prints usage, no container needed" "$r" "rc=${RC}"

# --- host -> container routing ----------------------------------------------------------------------------------
: > "${LOG}"; FAKE_RUNNING=1 run cli infra info
grep -q "docker exec -i -w /workspace cnpg-playground /workspace/playground infra info" "${LOG}" && r=ok || r=bad; check "infra info is routed into the container" "$r" "$(calls | tail -2)"
: > "${LOG}"; FAKE_RUNNING=0 run cli usecase list
[ "${RC}" = 3 ] && ! grep -q "docker exec" "${LOG}" && r=ok || r=bad; check "container not running -> exit 3, nothing executed" "$r" "rc=${RC}"
PLAYGROUND_CONTEXT=container run "${CLI}" doctor;  [ "${RC}" = 2 ] && r=ok || r=bad; check "host-only command inside the container -> exit 2 (no loop)" "$r" "rc=${RC}"
PLAYGROUND_CONTEXT=container run "${CLI}" usecase start Bad_Name; [ "${RC}" = 1 ] && grep -qi "name is required" <<< "${OUT}" && r=ok || r=bad; check "container: invalid use case name rejected" "$r" "${OUT}"
PLAYGROUND_CONTEXT=container run "${CLI}" usecase status nope;    [ "${RC}" = 1 ] && grep -q "Unknown use case" <<< "${OUT}" && r=ok || r=bad; check "container: unknown use case rejected" "$r" "${OUT}"
PLAYGROUND_CONTEXT=container run "${CLI}" infra up;               [ "${RC}" = 1 ] && grep -q "at least one cluster" <<< "${OUT}" && r=ok || r=bad; check "container: infra up without a cluster name rejected" "$r" "${OUT}"
PLAYGROUND_CONTEXT=container run "${CLI}" usecase start --force x;  [ "${RC}" = 2 ] && r=ok || r=bad; check "container: --force only valid for stop" "$r" "rc=${RC}"

# --- stop / restart ------------------------------------------------------------------------------------------------
: > "${LOG}"; FAKE_RUNNING=1 run cli stop
[ "${RC}" = 0 ] && grep -q "docker compose .* stop" "${LOG}" && ! grep -q " down" "${LOG}" && grep -q "keep running" <<< "${OUT}" && r=ok || r=bad; check "stop = compose stop only, explains clusters keep running" "$r" "rc=${RC}"
: > "${LOG}"; FAKE_SESSIONS=2 FAKE_RUNNING=1 run cli restart
[ "${RC}" = 1 ] && ! grep -q "compose .* restart" "${LOG}" && r=ok || r=bad; check "restart with live sessions needs confirmation (refused without terminal)" "$r" "rc=${RC}"
# (the Web UI wait is bounded to 1 s: only the command issued matters here)
: > "${LOG}"; FAKE_SESSIONS=2 FAKE_RUNNING=1 PLAYGROUND_WAIT_TIMEOUT=1 run cli restart --yes
grep -q "compose .* restart" "${LOG}" && r=ok || r=bad; check "restart --yes issues compose restart" "$r" "$(calls | tail -2)"

# --- uninstall ---------------------------------------------------------------------------------------------------
: > "${LOG}"; run cli uninstall
[ "${RC}" = 1 ] && ! grep -q "compose .* down" "${LOG}" && r=ok || r=bad; check "uninstall refuses without confirmation (no terminal)" "$r" "rc=${RC}"
: > "${LOG}"; run cli uninstall --yes
[ "${RC}" = 0 ] && grep -q "compose .* down --rmi local" "${LOG}" && ! grep -q "down -v\| -v " "${LOG}" && ! grep -q "docker rm" "${LOG}" && r=ok || r=bad; check "uninstall --yes: compose down --rmi local, no volumes, no cluster removal" "$r" "$(calls)"
grep -q "Still present" <<< "${OUT}" && grep -q "cnpg-standard-1" <<< "${OUT}" && r=ok || r=bad; check "uninstall reports what remains" "$r" "${OUT}"

# --- purge ---------------------------------------------------------------------------------------------------------
: > "${LOG}"; run cli purge --dry-run
[ "${RC}" = 0 ] && grep -q "cnpg-lab-cnpg-standard-1" <<< "${OUT}" && ! grep -q "someone-elses" <<< "${OUT}" && ! grep -q "lookalike" <<< "${OUT}" && r=ok || r=bad; check "purge --dry-run lists only owned clusters (foreign and look-alike excluded)" "$r" "${OUT}"
! grep -qE "docker rm|compose .* down|prune" "${LOG}" && r=ok || r=bad; check "purge --dry-run deletes nothing" "$r" "$(calls)"
grep -q "kube" <<< "${OUT}" && grep -q "history" <<< "${OUT}" && r=ok || r=bad; check "purge --dry-run lists the project volumes (by Compose label)" "$r"
: > "${LOG}"; run cli purge
[ "${RC}" = 1 ] && ! grep -qE "docker rm|compose .* down" "${LOG}" && r=ok || r=bad; check "purge refuses without confirmation (no terminal)" "$r" "rc=${RC}"
: > "${LOG}"; run cli purge --yes
grep -q "docker rm -f -v id1 id2" "${LOG}" && grep -q "compose .* down -v --rmi local" "${LOG}" && r=ok || r=bad; check "purge --yes removes the owned cluster nodes and the compose resources" "$r" "$(calls | grep -E 'rm|down')"
! grep -qE "someone-elses|lookalike" "${LOG}" && ! grep -qE "prune|system" "${LOG}" && r=ok || r=bad; check "purge never touches foreign resources and never prunes" "$r" "$(calls)"
! grep -nE "docker (system|volume|image|container) prune|prune" "${CLI}" | grep -v "never\|No 'docker" >/dev/null && r=ok || r=bad; check "the CLI source contains no prune command" "$r"

# --- doctor / status (read-only) ----------------------------------------------------------------------------------
: > "${LOG}"; run cli doctor
grep -q "Docker Compose v2" <<< "${OUT}" && ! grep -qE "docker (rm|run|compose .* (up|down|build))" "${LOG}" && r=ok || r=bad; check "doctor is read-only (no run/rm/up/down/build)" "$r" "$(calls | tr '\n' ';' | cut -c1-200)"
: > "${LOG}"; run cli status
! grep -qE "docker (rm|run|compose .* (up|down|build|stop|restart))" "${LOG}" && r=ok || r=bad; check "status is read-only" "$r"
echo; [ "${FAIL}" = 0 ] && echo "ALL CLI TESTS PASSED" || echo "SOME CLI TESTS FAILED"; exit "${FAIL}"
