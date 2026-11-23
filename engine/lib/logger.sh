#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# engine/lib/logger.sh
# Generic logging library (no Kind/Docker/Kubernetes knowledge): "[HH:MM:SS] [LEVEL] message".
# Adapted from the previous project's lib/logger.sh (file logging, spinner and ERR trap dropped).
# Bash 3.2 compatible (the host CLI sources it too). Source it; do not execute it. Colors only on a terminal (or with PLAYGROUND_FORCE_COLOR=1); NO_COLOR=1 or LOG_COLORS=false disables.
# INFO/SUCCESS/SECTION/DEBUG go to stdout, WARN/ERROR to stderr.
# -----------------------------------------------------------------------------

: "${DEBUG:=false}"
: "${LOG_COLORS:=true}"

_LOGGER_C_RESET=$'\033[0m'
_LOGGER_C_INFO=$'\033[38;5;117m'
_LOGGER_C_SUCCESS=$'\033[38;5;121m'
_LOGGER_C_WARN=$'\033[38;5;216m'
_LOGGER_C_ERROR=$'\033[38;5;204m'
_LOGGER_C_DEBUG=$'\033[38;5;246m'
_LOGGER_C_SECTION=$'\033[38;5;183m'

_logger_color_for() {
  case "$1" in
    INFO)    printf '%s' "${_LOGGER_C_INFO}" ;;
    SUCCESS) printf '%s' "${_LOGGER_C_SUCCESS}" ;;
    WARN)    printf '%s' "${_LOGGER_C_WARN}" ;;
    ERROR)   printf '%s' "${_LOGGER_C_ERROR}" ;;
    DEBUG)   printf '%s' "${_LOGGER_C_DEBUG}" ;;
    SECTION) printf '%s' "${_LOGGER_C_SECTION}" ;;
  esac
}

# Time of day for the line prefix, in _LOG_TS. Bash 4.2+ formats it itself (no process, the container's Bash 5); older Bash (the macOS /bin/bash 3.2,
# which the host-side ./playground may run under) has no %(...)T and asks `date`. The line is the same either way.
if [ "${BASH_VERSINFO[0]}" -gt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -ge 2 ]; }; then
  _log_time() { printf -v _LOG_TS '%(%H:%M:%S)T' -1; }
else
  _log_time() { _LOG_TS="$(date +%H:%M:%S)"; }
fi

# Single emission point. $1=level, $2=fd, rest=message. Always returns 0 (safe under set -e).
_log_emit() {
  local level="$1" fd="$2" color="" reset=""
  shift 2
  # The tty test happens here, not in $(...), where stdout is a pipe.
  # PLAYGROUND_FORCE_COLOR=1 keeps the colors when output is captured (the Web UI log panel);
  # NO_COLOR and LOG_COLORS=false still win.
  if { [ -t "${fd}" ] || [ "${PLAYGROUND_FORCE_COLOR:-}" = "1" ]; } && [ -z "${NO_COLOR:-}" ] && [ "${LOG_COLORS}" = "true" ]; then
    color="$(_logger_color_for "${level}")"
    reset="${_LOGGER_C_RESET}"
  fi
  _log_time
  printf '%s[%s] %-9s %s%s\n' "${color}" "${_LOG_TS}" "[${level}]" "$*" "${reset}" >&"${fd}"
  return 0
}

log_debug()   { [ "${DEBUG}" = "true" ] || return 0; _log_emit DEBUG   1 "$@"; }
log_info()    { _log_emit INFO    1 "$@"; }
log_success() { _log_emit SUCCESS 1 "$@"; }
log_section() { _log_emit SECTION 1 "$@"; }
log_warn()    { _log_emit WARN    2 "$@"; }
log_error()   { _log_emit ERROR   2 "$@"; }

die() { log_error "$@"; exit 1; }

# Pipe filter: logs each input line as it arrives (no buffering). Lines already in logger
# format keep their level; anything else becomes INFO. Strips carriage returns and ANSI codes.
log_stream() {
  local line level
  local re='^\[[0-9:]{8}\] \[(SECTION|SUCCESS|WARN|ERROR|DEBUG|INFO)\] *(.*)$'
  while IFS= read -r line || [ -n "${line}" ]; do
    line="${line%$'\r'}"
    line="$(sed $'s/\033\\[[0-9;?]*[a-zA-Z]//g' <<< "${line}")"
    [ -n "${line}" ] || continue
    if [[ "${line}" =~ ${re} ]]; then
      level="${BASH_REMATCH[1]}"
      case "${level}" in
        WARN|ERROR) _log_emit "${level}" 2 "${BASH_REMATCH[2]}" ;;
        *)          _log_emit "${level}" 1 "${BASH_REMATCH[2]}" ;;
      esac
    else
      _log_emit INFO 1 "${line}"
    fi
  done
  return 0
}

# Run a command with stdout+stderr streamed through log_stream. Returns the command's own
# exit code (not the filter's); logs [ERROR] on failure. Output stays visible either way.
log_run() {
  local rc
  "$@" 2>&1 | log_stream
  rc="${PIPESTATUS[0]}"
  [ "${rc}" -eq 0 ] || log_error "Command failed (exit ${rc}): $*"
  return "${rc}"
}
