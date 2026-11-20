#!/usr/bin/env bash
# Host-side collector (runs on the Mac / Linux machine, NOT in the container): the container only sees the Docker VM, so the real host CPU
# and RAM are sampled here and written to <repo>/.host-metrics.json, which the bind-mounted Web backend reads (web/app.py _host_metrics).
# Started by ./playground start/restart, stopped by stop/uninstall/purge, and it exits by itself when the Playground container is not running.
# Bash 3.2 compatible; macOS (top, vm_stat, sysctl) and Linux (/proc). Usage: host-metrics.sh [container-name] [interval-seconds]
CONTAINER="${1:-cnpg-playground}"; INTERVAL="${2:-5}"
OUT="$(cd "$(dirname "$0")/.." && pwd)/.host-metrics.json"
write() {   # <cpu%> <cpus> <used bytes> <total bytes>
  printf '{"ts": %s, "os": "%s", "cpu_percent": %s, "cpus": %s, "mem_used_bytes": %s, "mem_total_bytes": %s}\n' "$(date +%s)" "${HOST_OS}" "$1" "$2" "$3" "$4" > "${OUT}.tmp" && mv "${OUT}.tmp" "${OUT}"
}
trap 'rm -f "${OUT}" "${OUT}.tmp"; exit 0' TERM INT HUP
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
while [ "$(docker inspect -f '{{.State.Running}}' "${CONTAINER}" 2>/dev/null)" = "true" ]; do
  sample || true
  sleep "${INTERVAL}"
done
rm -f "${OUT}" "${OUT}.tmp"
