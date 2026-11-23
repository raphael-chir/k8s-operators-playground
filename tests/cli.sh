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
export PLAYGROUND_NO_HOST_METRICS=1 FAKE_LOG="${LOG}" PATH="${T}/bin:${PATH}"
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
# --- AI Builder, container mode: fake docker and fake curl, a TEMPORARY state directory and token (never the real ones) ----------
AIBT="${T}/aib"; mkdir -p "${AIBT}"
export REAL_CURL="$(command -v curl)"
cat > "${T}/bin/curl" <<'FAKE'
#!/usr/bin/env bash
# Only the AI Builder health calls (curl -K -, config on stdin) are faked; everything else reaches the real curl.
case " $* " in
  *" -K - "*) cat > "${FAKE_CURL_STDIN}"; [ "${FAKE_CURL_OK:-1}" = 1 ] && printf '{"status": "ok", "claude_credentials_present": %s}' "${FAKE_CREDS:-true}" || exit 22 ;;
  *) exec "${REAL_CURL}" "$@" ;;
esac
FAKE
chmod +x "${T}/bin/curl"
export FAKE_CURL_STDIN="${AIBT}/curl-stdin"
AIB_PORT_FREE="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
aib() { env AI_BUILDER_STATE_DIR="${AIBT}/state" AI_BUILDER_TOKEN_FILE="${AIBT}/token" AI_BUILDER_PORT="${AIB_PORT_FREE}" AI_BUILDER_WAIT_TIMEOUT=2 PLAYGROUND_CONTEXT=host "${CLI}" ai-builder "$@"; }

: > "${LOG}"; FAKE_RUNNING=0 run aib start
TOKEN="$(cat "${AIBT}/token" 2>/dev/null)"
[ "${RC}" = 0 ] && grep -q "compose .* --profile ai-builder up -d --build ai-builder" "${LOG}" && r=ok || r=bad; check "ai-builder start: compose up of the ai-builder service only (profile)" "$r" "rc=${RC} $(calls | tail -2)"
[ "${#TOKEN}" = 64 ] && [ "$(stat -f %Lp "${AIBT}/token" 2>/dev/null || stat -c %a "${AIBT}/token")" = 600 ] && r=ok || r=bad; check "ai-builder start: 64-character token created with mode 600" "$r"
! grep -qF "${TOKEN}" <<< "${OUT}$(calls)" && r=ok || r=bad; check "the token is never printed nor passed on a command line" "$r"
grep -qF "Authorization: Bearer ${TOKEN}" "${FAKE_CURL_STDIN}" && r=ok || r=bad; check "health is queried with the bearer token through curl's stdin" "$r"
[ -d "${AIBT}/state" ] && r=ok || r=bad; check "the state directory is created by the CLI (not by Docker, as root)" "$r"
! grep -qE "docker.sock|--privileged|docker run|compose .* down|docker rm" "${LOG}" && r=ok || r=bad; check "ai-builder start: no socket, no privilege, nothing removed" "$r"
: > "${LOG}"; FAKE_RUNNING=0 run aib start; [ "$(cat "${AIBT}/token")" = "${TOKEN}" ] && r=ok || r=bad; check "restart keeps the existing token" "$r"
FAKE_CREDS=false FAKE_RUNNING=0 run aib start; grep -q "ai-builder login" <<< "${OUT}" && r=ok || r=bad; check "start tells how to sign in when no Claude login exists" "$r" "${OUT}"
FAKE_RUNNING=0 FAKE_CURL_OK=0 run aib start; [ "${RC}" = 1 ] && grep -q "did not answer" <<< "${OUT}" && r=ok || r=bad; check "start fails clearly when the service does not answer" "$r" "rc=${RC}"
FAKE_RUNNING=1 run aib status; [ "${RC}" = 0 ] && grep -q "Claude login: present" <<< "${OUT}" && ! grep -qF "${TOKEN}" <<< "${OUT}" && r=ok || r=bad; check "ai-builder status: container, health, login presence" "$r" "${OUT}"
FAKE_RUNNING=0 run aib status; [ "${RC}" = 1 ] && grep -q "not running" <<< "${OUT}" && r=ok || r=bad; check "ai-builder status: not running -> exit 1" "$r"
: > "${LOG}"; FAKE_RUNNING=1 run aib stop
[ "${RC}" = 0 ] && grep -q "compose .* --profile ai-builder stop ai-builder" "${LOG}" && ! grep -qE "down|docker rm| -v " "${LOG}" && r=ok || r=bad; check "ai-builder stop: stops that service only, removes nothing" "$r" "$(calls | tail -2)"
: > "${LOG}"; FAKE_RUNNING=1 run aib login; [ "${RC}" = 1 ] && grep -q "needs a terminal" <<< "${OUT}" && ! grep -q "docker exec" "${LOG}" && r=ok || r=bad; check "ai-builder login without a terminal is refused" "$r" "${OUT}"
FAKE_RUNNING=0 run aib login; [ "${RC}" = 1 ] && grep -q "not running" <<< "${OUT}" && r=ok || r=bad; check "ai-builder login needs the container running" "$r"
run aib bogus; [ "${RC}" = 2 ] && r=ok || r=bad; check "ai-builder: unknown sub-command -> exit 2" "$r"
run aib host status; [ "${RC}" = 1 ] && grep -q "not running" <<< "${OUT}" && ! grep -q "compose" "${LOG}" && r=ok || r=bad; check "ai-builder host status: the host-mode fallback is explicit and does not touch Docker" "$r" "${OUT}"
grep -q "ai-builder host start|stop|status" <<< "$("${CLI}" --help)" && r=ok || r=bad; check "--help documents container commands and the host fallback" "$r"
unset FAKE_CURL_STDIN REAL_CURL

# --- host resource confirmation before `usecase start` (simulated host: /proc fixture, nothing is measured for real) -----------------------------
mkdir -p "${T}/proc/sys/fs/inotify"
printf 'processor: 0\nprocessor: 1\n' > "${T}/proc/cpuinfo"; printf 'MemTotal: 16000000 kB\nMemAvailable: 12000000 kB\n' > "${T}/proc/meminfo"
echo 8192 > "${T}/proc/sys/fs/inotify/max_user_instances"; echo 1048576 > "${T}/proc/sys/fs/inotify/max_user_watches"
gate() { OUT="$( ( ulimit -Sn 4096 2>/dev/null; HOSTCHECK_OS=linux HOSTCHECK_PROC="${T}/proc" "$@" ) 2>&1 </dev/null)"; RC=$?; }
: > "${LOG}"; gate cli usecase start cnpg-standard
[ "${RC}" = 0 ] && ! grep -q "Host resources" <<< "${OUT}" && grep -q "docker exec .*usecase start cnpg-standard" "${LOG}" && r=ok || r=bad; check "start gate: no resource issue -> starts immediately, no question" "$r" "rc=${RC} ${OUT}"
echo 20 > "${T}/proc/sys/fs/inotify/max_user_watches"
: > "${LOG}"; gate cli usecase start cnpg-standard
[ "${RC}" = 1 ] && grep -q "Host resources: 1 critical" <<< "${OUT}" && grep -q "re-run with --yes" <<< "${OUT}" && ! grep -q "docker exec" "${LOG}" && r=ok || r=bad
check "start gate: CRITICAL without a terminal -> refused (never waits for input), nothing started" "$r" "rc=${RC} ${OUT}"
grep -qE '^\[[0-9:]{8}\] \[WARN\] +Linux inotify limits.*\(CRITICAL\)|^\[[0-9:]{8}\] \[WARN\] +inotify.*\(CRITICAL\)' <<< "$(printf '%s' "${OUT}" | sed 's/\x1b\[[0-9;]*m//g')" && ! grep -qE '\[ERROR\].*(inotify|CRITICAL)' <<< "${OUT}" && r=ok || r=bad; check "start gate: a CRITICAL resource finding is a [WARN] saying (CRITICAL), never an [ERROR]" "$r" "${OUT}"
: > "${LOG}"; gate cli usecase start cnpg-standard --yes
[ "${RC}" = 0 ] && grep -q "Continuing (--yes)" <<< "${OUT}" && grep -q "docker exec .*usecase start cnpg-standard" "${LOG}" && ! grep -q -- "--yes" "${LOG}" && r=ok || r=bad
check "start gate: --yes accepts once and is not passed to the container (which never asks again)" "$r" "rc=${RC} ${OUT} | $(calls | tail -1)"
echo 300000 > "${T}/proc/sys/fs/inotify/max_user_watches"; echo 100 > "${T}/proc/sys/fs/inotify/max_user_instances"
: > "${LOG}"; gate cli usecase start cnpg-standard
[ "${RC}" = 1 ] && grep -q "Host resources: 1 warning" <<< "${OUT}" && ! grep -q "docker exec" "${LOG}" && r=ok || r=bad; check "start gate: a WARNING also needs confirmation" "$r" "rc=${RC} ${OUT}"
: > "${LOG}"; gate cli usecase start openshift-crc
! grep -q "Host resources" <<< "${OUT}" && r=ok || r=bad; check "start gate: an external use case is not checked against host resources" "$r" "${OUT}"
PLAYGROUND_CONTEXT=container run "${CLI}" usecase start cnpg-standard --yes; [ "${RC}" = 2 ] && grep -q "only applies to 'usecase stop'" <<< "${OUT}" && r=ok || r=bad; check "inside the container nothing changes: --yes is still not a start option" "$r" "rc=${RC} ${OUT}"
grep -q "usecase start NAME \[--yes\]" <<< "$("${CLI}" --help)" && r=ok || r=bad; check "--help documents --yes" "$r"
: > "${LOG}"; OUT="$(ulimit -Sn 4096 2>/dev/null; HOSTCHECK_OS=linux HOSTCHECK_PROC="${T}/proc" PLAYGROUND_CONTEXT=host "${CLI}" doctor --summary 2>&1)"; RC=$?
[ "${RC}" = 0 ] && grep -qE "^\[[0-9:]{8}\] \[INFO\] +Resource health: 1 warning" <<< "${OUT}" && r=ok || r=bad; check "doctor --summary: one line, severity counted correctly, exit 0" "$r" "rc=${RC} ${OUT}"
echo 20 > "${T}/proc/sys/fs/inotify/max_user_watches"; echo 8192 > "${T}/proc/sys/fs/inotify/max_user_instances"
OUT="$(ulimit -Sn 4096 2>/dev/null; HOSTCHECK_OS=linux HOSTCHECK_PROC="${T}/proc" PLAYGROUND_CONTEXT=host "${CLI}" doctor 2>&1)"; RC=$?
[ "${RC}" = 0 ] && grep -q "Resource health: 1 critical" <<< "${OUT}" && ! grep -q "Environment ready, with" <<< "${OUT}" && r=ok || r=bad; check "doctor: a CRITICAL resource is counted as critical (not a warning) and keeps exit code 0" "$r" "rc=${RC} $(tail -4 <<< "${OUT}")"
OUT="$(ulimit -Sn 4096 2>/dev/null; HOSTCHECK_OS=linux HOSTCHECK_PROC="${T}/proc" PLAYGROUND_CONTEXT=host "${CLI}" doctor --compact 2>&1)"
[ "$(grep -c '\[SUCCESS\]' <<< "${OUT}")" -lt 8 ] && grep -qE "\[INFO\] +Prerequisites: [0-9]* checks OK" <<< "${OUT}" && r=ok || r=bad; check "doctor --compact: prerequisites are counted, not listed" "$r" "${OUT}"
# --- operational messages use the engine's logger, checklists keep their tags ---
LOGRE='^\[[0-9][0-9]:[0-9][0-9]:[0-9][0-9]\] \[(SUCCESS|INFO|WARN|ERROR)\]'
run cli stop; grep -qE '^\[[0-9:]{8}\] \[SUCCESS\] +Playground stopped' <<< "${OUT}" && grep -qE '\[INFO\] +Kind and k3d clusters are independent' <<< "${OUT}" && r=ok || r=bad; check "stop: operational messages use the logger format" "$r" "${OUT}"
PLAYGROUND_CONTEXT=container run "${CLI}" start; [ "${RC}" = 2 ] && grep -qE '^\[[0-9:]{8}\] \[ERROR\] +.start. runs on the host' <<< "${OUT}" && r=ok || r=bad; check "errors use the logger format ([ERROR], stderr)" "$r" "${OUT}"
OUT="$(PLAYGROUND_CONTEXT=container "${CLI}" start 2>&1 >/dev/null </dev/null)"; grep -q '\[ERROR\]' <<< "${OUT}" && r=ok || r=bad; check "errors go to stderr" "$r" "${OUT}"
OUT="$(ulimit -Sn 4096 2>/dev/null; HOSTCHECK_OS=linux HOSTCHECK_PROC="${T}/proc" PLAYGROUND_CONTEXT=host "${CLI}" doctor 2>&1)"
grep -qE '^\[[0-9:]{8}\] \[SUCCESS\] +Docker CLI' <<< "${OUT}" && grep -qE '\[SECTION\] +Host resources' <<< "${OUT}" && ! grep -qE '\[OK\]|\[FAIL\]|\[CRIT\]' <<< "${OUT}" && r=ok || r=bad; check "doctor uses the logger style only (sections, levels, no checklist tags)" "$r" "$(head -5 <<< "${OUT}")"
# --- final recommendations, and no repetition inside 00-provision.sh ---
echo 20 > "${T}/proc/sys/fs/inotify/max_user_watches"; echo 100 > "${T}/proc/sys/fs/inotify/max_user_instances"
hc() { OUT="$( ( ulimit -Sn 4096 2>/dev/null; HOSTCHECK_OS=linux HOSTCHECK_PROC="${T}/proc" PLAYGROUND_CONTEXT=host "$@" ) 2>&1 </dev/null)"; RC=$?; }
hc "${CLI}" doctor --recommendations
[ "${RC}" = 0 ] && grep -qE '\[SECTION\] +Host resource recommendations' <<< "${OUT}" && grep -qE '\[WARN\] +Linux inotify limits \(CRITICAL\)' <<< "${OUT}" && r=ok || r=bad; check "recommendations: a section, with the resource, its severity as (CRITICAL) on a [WARN] line" "$r" "${OUT}"
grep -q 'max_user_watches   = 20' <<< "${OUT}" && grep -q 'sudo sysctl -w fs.inotify.max_user_instances=8192' <<< "${OUT}" && grep -q 'sudo sysctl -w fs.inotify.max_user_watches=524288' <<< "${OUT}" && r=ok || r=bad; check "recommendations: current value and the exact sysctl commands" "$r" "${OUT}"
grep -q 'sysctl fs.inotify.max_user_instances fs.inotify.max_user_watches' <<< "${OUT}" && grep -q 'not inside the Playground container' <<< "${OUT}" && grep -q 'sudo sysctl -w fs.inotify.max_user_instances=100' <<< "${OUT}" && grep -q 'sudo sysctl -w fs.inotify.max_user_watches=20' <<< "${OUT}" && r=ok || r=bad; check "recommendations: where the original values are (read them first; listed under Restore)" "$r" "${OUT}"
grep -q '\[ERROR\]' <<< "${OUT}" && r=bad || r=ok; check "recommendations: no [ERROR] for resource risks" "$r" "${OUT}"
grep -q 'Nothing was changed' <<< "${OUT}" && r=ok || r=bad; check "recommendations: states that nothing is executed" "$r"
echo 8192 > "${T}/proc/sys/fs/inotify/max_user_instances"; echo 1048576 > "${T}/proc/sys/fs/inotify/max_user_watches"
hc "${CLI}" doctor --recommendations
[ "${RC}" = 0 ] && grep -qE '\[INFO\] +Resource health: all OK' <<< "${OUT}" && ! grep -q 'recommendations' <<< "${OUT}" && r=ok || r=bad; check "recommendations: nothing actionable -> one 'Resource health' line, no section" "$r" "${OUT}"
# disk pressure advice comes from the same records (df stub on PATH)
printf '#!/bin/sh\necho "Filesystem 1024-blocks Used Available Capacity Mounted on"\ncase "$*" in *-Pi*) echo "/dev/x 1000000 1000 999000 1%% /m";; *) echo "/dev/x 100000000 99000000 3500000 99%% /m";; esac\n' > "${T}/bin/df"; chmod +x "${T}/bin/df"
mkdir -p "${T}/dockerroot"
OUT="$( ( ulimit -Sn 4096 2>/dev/null; export HOSTCHECK_OS=linux HOSTCHECK_PROC="${T}/proc" PLAYGROUND_CONTEXT=host HC_DOCKER_ROOT="${T}/dockerroot"; "${CLI}" doctor --recommendations ) 2>&1 </dev/null)"
grep -qE '\[WARN\] +Host disk usage \(CRITICAL\)' <<< "${OUT}" && grep -q 'docker system df' <<< "${OUT}" && grep -q 'docker builder du' <<< "${OUT}" && grep -q 'free space manually' <<< "${OUT}" && ! grep -q '\[ERROR\]' <<< "${OUT}" && r=ok || r=bad; check "recommendations: disk pressure -> inspect Docker disk usage, free space manually (never run)" "$r" "${OUT}"
rm -f "${T}/bin/df"
# wrapper: no repetition
: > "${LOG}"; OUT="$(PLAYGROUND_BIND_ADDRESS=0.0.0.0 PLAYGROUND_CONTEXT=host PLAYGROUND_NO_HINT=1 "${CLI}" install 2>&1 </dev/null)"
[ "$(grep -c 'PLAYGROUND_BIND_ADDRESS 0.0.0.0' <<< "${OUT}")" = 1 ] && ! grep -q 'Next: ./playground start' <<< "${OUT}" && r=ok || r=bad; check "install inside the wrapper: bind warning once, no 'Next:' hint" "$r" "${OUT}"
OUT="$(PLAYGROUND_BIND_ADDRESS=0.0.0.0 PLAYGROUND_CONTEXT=host "${CLI}" install 2>&1 </dev/null)"
grep -q 'Next: ./playground start' <<< "${OUT}" && grep -q 'PLAYGROUND_BIND_ADDRESS 0.0.0.0' <<< "${OUT}" && r=ok || r=bad; check "install on its own still shows its hint and the bind warning" "$r" "${OUT}"
OUT="$(PLAYGROUND_BIND_ADDRESS=0.0.0.0 PLAYGROUND_BIND_WARNED=1 PLAYGROUND_BANNER_DONE=1 PLAYGROUND_WAIT_TIMEOUT=1 PLAYGROUND_CONTEXT=host "${CLI}" start 2>&1 </dev/null)"
! grep -q 'PLAYGROUND_BIND_ADDRESS 0.0.0.0' <<< "${OUT}" && ! grep -q 'SECTION.*CNPG Operator Playground' <<< "${OUT}" && r=ok || r=bad; check "start inside the wrapper: no second bind warning, no second banner" "$r" "${OUT}"
OUT="$(PLAYGROUND_BIND_ADDRESS=0.0.0.0 PLAYGROUND_WAIT_TIMEOUT=1 PLAYGROUND_CONTEXT=host "${CLI}" start 2>&1 </dev/null)"
grep -q 'PLAYGROUND_BIND_ADDRESS 0.0.0.0' <<< "${OUT}" && grep -q 'SECTION.*CNPG Operator Playground' <<< "${OUT}" && r=ok || r=bad; check "start on its own keeps its banner and its bind warning" "$r" "${OUT}"
grep -q 'log_success "Playground ready!"$' 00-provision.sh && ! grep -q 'Next: ./playground start' 00-provision.sh && [ "$(tail -1 00-provision.sh | grep -c 'doctor --recommendations')" = 1 ] && r=ok || r=bad; check "00-provision.sh: 'Playground ready!', no 'Next:', recommendations last" "$r"
grep -q "doctor$" 00-provision.sh && r=bad || r=ok; check "00-provision.sh no longer runs doctor twice (install runs it once)" "$r"
echo; [ "${FAIL}" = 0 ] && echo "ALL CLI TESTS PASSED" || echo "SOME CLI TESTS FAILED"; exit "${FAIL}"
