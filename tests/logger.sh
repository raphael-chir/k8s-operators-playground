#!/usr/bin/env bash
# engine/lib/logger.sh under whichever Bash runs this file (macOS /bin/bash 3.2 on a Mac, Bash 5 on Linux), and under the Playground container's
# Bash 5 when it is running (read-only `docker exec`: nothing is changed). The line format must be identical everywhere:
# "[HH:MM:SS] [LEVEL] message", INFO/SUCCESS/SECTION on stdout, WARN/ERROR on stderr, and a log call never aborts a `set -e` script.
# Run: tests/logger.sh
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
FAIL=0
check() { if [ "$2" = ok ]; then echo "PASS $1"; else echo "FAIL $1   [$3]"; FAIL=1; fi; }
RE='^\[[0-9][0-9]:[0-9][0-9]:[0-9][0-9]\] \[(INFO|SUCCESS|SECTION|WARN|ERROR)\] +'

body='source engine/lib/logger.sh
log_info i; log_success s; log_section c; log_warn w; log_error e
printf "[10:00:00] [WARN] from-stream\nplain\n" | log_stream
log_run bash -c "echo out; exit 3" || echo "log_run-rc=$?"
echo reached'
suite() {   # <label> <command prefix...>: runs the body with that shell
  local label="$1"; shift
  local out err; out="$("$@" bash -c "${body}" 2>"${TMPDIR:-/tmp}/logger.err.$$")"; err="$(cat "${TMPDIR:-/tmp}/logger.err.$$")"; rm -f "${TMPDIR:-/tmp}/logger.err.$$"
  local bad; bad="$(printf '%s\n' "${out}" "${err}" | grep -vE "${RE}|^$|^reached$|^log_run-rc=3$")"
  [ -z "${bad}" ] && r=ok || r=bad; check "${label}: every line is '[HH:MM:SS] [LEVEL] message'" "$r" "${bad}"
  grep -qE '^\[[0-9:]{8}\] \[INFO\] +i$' <<< "${out}" && grep -qE '\[SUCCESS\] s$' <<< "${out}" && grep -qE '\[SECTION\] c$' <<< "${out}" && r=ok || r=bad; check "${label}: INFO, SUCCESS and SECTION go to stdout" "$r" "${out}"
  grep -qE '\[WARN\] +w$' <<< "${err}" && grep -qE '\[ERROR\] +e$' <<< "${err}" && ! grep -q '\[WARN\] *w$' <<< "${out}" && r=ok || r=bad; check "${label}: WARN and ERROR go to stderr" "$r" "${err}"
  grep -qE '\[WARN\] +from-stream$' <<< "${err}" && grep -qE '\[INFO\] +plain$' <<< "${out}" && r=ok || r=bad; check "${label}: log_stream keeps levels and logs plain lines as INFO" "$r" "${out} / ${err}"
  grep -q 'log_run-rc=3' <<< "${out}" && grep -q 'Command failed (exit 3)' <<< "${err}" && r=ok || r=bad; check "${label}: log_run returns the command's exit code and logs the failure" "$r" "${out} / ${err}"
  out="$("$@" bash -c 'set -Eeuo pipefail; source engine/lib/logger.sh; log_info a; log_warn b; log_error c; echo reached' 2>/dev/null)"
  grep -q '^reached$' <<< "${out}" && r=ok || r=bad; check "${label}: a log call never aborts a 'set -Eeuo pipefail' script" "$r" "${out}"
  out="$("$@" env NO_COLOR=1 bash -c 'source engine/lib/logger.sh; log_info plain' 2>&1)"
  ! grep -q $'\033' <<< "${out}" && r=ok || r=bad; check "${label}: NO_COLOR removes the colors" "$r"
  out="$("$@" env PLAYGROUND_FORCE_COLOR=1 bash -c 'source engine/lib/logger.sh; log_info colored' 2>&1)"
  grep -q $'\033\\[38;5;117m' <<< "${out}" && r=ok || r=bad; check "${label}: PLAYGROUND_FORCE_COLOR keeps the colors for captured output (the Web log panel)" "$r"
}
suite "this shell (Bash ${BASH_VERSION%%(*})" env
if command -v docker >/dev/null 2>&1 && [ "$(docker inspect -f '{{.State.Running}}' cnpg-playground 2>/dev/null)" = "true" ]; then
  ver="$(docker exec cnpg-playground bash -c 'echo ${BASH_VERSION%%(*}')"
  # same body, run in the container on the same repository (bind-mounted at /workspace): the lines must have the same format
  out="$(docker exec -w /workspace cnpg-playground bash -c "${body}" 2>&1)"
  bad="$(printf '%s\n' "${out}" | grep -vE "${RE}|^$|^reached$|^log_run-rc=3$")"
  [ -z "${bad}" ] && grep -q 'log_run-rc=3' <<< "${out}" && r=ok || r=bad; check "container (Bash ${ver}): same line format and behavior" "$r" "${bad}"
else echo "SKIP container Bash 5 check (the Playground is not running)"; fi
# the CLI itself: operational messages use the logger, checklists keep their tags
out="$(PLAYGROUND_CONTEXT=host ./playground version 2>&1)"; grep -q '^CNPG Operator Playground v' <<< "${out}" && r=ok || r=bad; check "the CLI still loads (it sources the logger under this Bash)" "$r" "${out}"
echo; [ "${FAIL}" = 0 ] && echo "ALL LOGGER TESTS PASSED" || { echo "SOME LOGGER TESTS FAILED"; exit 1; }
