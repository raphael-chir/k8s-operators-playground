#!/usr/bin/env bash
# Host-side collector (runs on the Mac / Linux machine, NOT in the container): the container only sees the Docker VM, so the real host CPU
# and RAM are sampled here and written to <repo>/.host-metrics.json, which the bind-mounted Web backend reads (web/app.py _host_metrics).
# Started by ./playground start/restart, stopped by stop/uninstall/purge, and it exits by itself when the Playground container is not running.
# Bash 3.2 compatible; macOS (top, vm_stat, sysctl) and Linux (/proc). Usage: host-metrics.sh [container-name] [interval-seconds]
CONTAINER="${1:-cnpg-playground}"; INTERVAL="${2:-5}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${ROOT_DIR}/.host-metrics.json"
CHECKS="${ROOT_DIR}/.host-checks"     # the non-OK diagnostics, read by the pre-provisioning check inside the container (engine/lib/hostcheck.sh)
source "${ROOT_DIR}/engine/lib/hostcheck.sh"
D_PCT=null; D_AVAIL=null; D_TOTAL=null; W_COUNT=0; W_CRIT=0; W_TITLES=""   # disk and diagnostic summary, refreshed on every sample (refresh_checks)
write() {   # <cpu%> <cpus> <used bytes> <total bytes>
  printf '{"ts": %s, "os": "%s", "cpu_percent": %s, "cpus": %s, "mem_used_bytes": %s, "mem_total_bytes": %s, "disk_percent": %s, "disk_avail_bytes": %s, "disk_total_bytes": %s, "warnings": %s, "critical": %s, "warning_titles": "%s"}\n' "$(date +%s)" "${HOST_OS}" "$1" "$2" "$3" "$4" "${D_PCT}" "${D_AVAIL}" "${D_TOTAL}" "${W_COUNT}" "${W_CRIT}" "${W_TITLES}" > "${OUT}.tmp" && mv "${OUT}.tmp" "${OUT}"
}
refresh_checks() {   # the same diagnostics as ./playground doctor; read-only
  local recs p t u a pct
  # Collected into a file, not a command substitution: HC_DISK (the one df of this run) stays in this shell, so the disk is measured once.
  hostcheck_collect all > "${CHECKS}.recs" 2>/dev/null || true
  recs="$(cat "${CHECKS}.recs" 2>/dev/null || true)"; rm -f "${CHECKS}.recs"
  { echo "#ts=$(date +%s)"; printf '%s\n' "${recs}" | grep -v '|OK|' | grep -v '^$'; } > "${CHECKS}.tmp" 2>/dev/null && mv "${CHECKS}.tmp" "${CHECKS}"
  W_COUNT="$(printf '%s\n' "${recs}" | grep -cE '\|(WARNING|CRITICAL)\|')" || true
  W_CRIT="$(printf '%s\n' "${recs}" | grep -c '|CRITICAL|')" || true
  W_TITLES="$(printf '%s\n' "${recs}" | awk -F'|' '$2 == "WARNING" || $2 == "CRITICAL" { printf "%s%s", (n++ ? "; " : ""), $3 }' | tr -d '"\\')"
  read -r p t u a pct <<< "${HC_DISK:-}"
  if [ -n "${pct:-}" ] && [ "${pct}" -ge 0 ] 2>/dev/null; then D_PCT="${pct}"; D_TOTAL=$(( t * 1024 )); D_AVAIL=$(( a * 1024 )); else D_PCT=null; D_AVAIL=null; D_TOTAL=null; fi
}
trap 'rm -f "${OUT}" "${OUT}.tmp" "${CHECKS}" "${CHECKS}.tmp" "${CHECKS}.recs"; exit 0' TERM INT HUP
prev_total=0; prev_idle=0
case "$(uname -s)" in      # the host OS: macos | windows (Linux running under WSL2) | linux
  Darwin) HOST_OS=macos ;;
  Linux) if grep -qi microsoft /proc/version 2>/dev/null; then HOST_OS=windows; else HOST_OS=linux; fi ;;
  *) HOST_OS=unknown ;;
esac
sample() {
  local cpu cpus used total
  case "$(uname -s)" in
    Darwin)
      cpus="$(sysctl -n hw.ncpu)"; total="$(sysctl -n hw.memsize)"
      # Second sample of `top` is the usage over the last second (the first is since boot).
      cpu="$(top -l 2 -n 0 -s 1 2>/dev/null | awk '/^CPU usage/ { idle = $(NF-1); sub(/%/, "", idle); v = 100 - idle } END { if (v != "") printf "%.1f", v }')"
      # "Memory used" like Activity Monitor: active + wired + compressed pages
      used="$(vm_stat | awk -v t="${total}" '/page size of/ { ps = $8 } /^Pages active/ { a = $3 } /^Pages wired down/ { w = $4 } /^Pages occupied by compressor/ { c = $5 } END { gsub(/\./, "", a); gsub(/\./, "", w); gsub(/\./, "", c); if (ps > 0) printf "%.0f", (a + w + c) * ps }')" ;;
    Linux)
      cpus="$(nproc)"; total=$(( $(awk '/^MemTotal/ { print $2 }' /proc/meminfo) * 1024 ))
      used=$(( total - $(awk '/^MemAvailable/ { print $2 }' /proc/meminfo) * 1024 ))
      read -r _ u n s idle rest < /proc/stat; local t=$(( u + n + s + idle ))
      cpu="$(awk -v t="${t}" -v i="${idle}" -v pt="${prev_total}" -v pi="${prev_idle}" 'BEGIN { if (t > pt) printf "%.1f", 100 * (1 - (i - pi) / (t - pt)) }')"
      prev_total="${t}"; prev_idle="${idle}"; sleep 1 ;;
    *) return 1 ;;
  esac
  [ -n "${cpu}" ] && [ -n "${used}" ] && write "${cpu}" "${cpus}" "${used}" "${total}"
}
[ "${BASH_SOURCE[0]}" = "$0" ] || return 0     # sourced (tests/hostcheck.sh): only the functions
while [ "$(docker inspect -f '{{.State.Running}}' "${CONTAINER}" 2>/dev/null)" = "true" ]; do
  refresh_checks || true     # every sample (~6 s): the pre-start confirmation trusts the file for 20 s (engine/lib/hostcheck.sh HC_FRESH_SECONDS)
  sample || true
  sleep "${INTERVAL}"
done
rm -f "${OUT}" "${OUT}.tmp" "${CHECKS}" "${CHECKS}.tmp" "${CHECKS}.recs"
