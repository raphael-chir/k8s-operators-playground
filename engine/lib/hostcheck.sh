# Host resource diagnostics, ONE implementation shared by `./playground doctor`, the host-side sampler (engine/host-metrics.sh, which feeds
# the dashboard bar) and the pre-provisioning check (hostcheck_preflight, called by engine/usecase.sh). Sourced, never executed.
# Read-only: nothing here changes a setting. Corrections are only PRINTED, for the user to run (or not). Bash 3.2 compatible (macOS host).
#
# A record is one line:  id|STATUS|title|current|recommended|impact|fix|restore
#   STATUS: OK | WARNING | CRITICAL | UNAVAILABLE (cannot be measured reliably here: never replaced by a container figure)
#   ";;" separates the lines inside current / recommended / fix / restore.
# The thresholds are advisory (they only choose a severity, nothing is ever blocked): disk and inode levels follow the kubelet's default
# eviction thresholds (DiskPressure below 10% free), inotify values are the usual Kind/k3d recommendation, not a Kubernetes requirement.
# Test hooks: HOSTCHECK_OS (macos|linux|wsl2), HOSTCHECK_PROC (default /proc), and PATH stubs for df, sysctl, vm_stat, docker.

HC_PROC="${HOSTCHECK_PROC:-/proc}"
HC_INOTIFY_INSTANCES=8192
HC_INOTIFY_WATCHES=524288
HC_FRESH_SECONDS=20           # a sampler file older than this is not trusted (the sampler refreshes it every sample, ~6 s)

hostcheck_env() {             # linux | wsl2 | macos | other
  case "${HOSTCHECK_OS:-$(uname -s)}" in
    Darwin|macos) echo macos ;;
    wsl2) echo wsl2 ;;
    Linux|linux) if [ "${HOSTCHECK_OS:-}" != linux ] && grep -qi microsoft "${HC_PROC}/version" 2>/dev/null; then echo wsl2; else echo linux; fi ;;
    *) echo other ;;
  esac
}

_hc_rec() { printf '%s|%s|%s|%s|%s|%s|%s|%s\n' "$@"; }
_hc_kb() {                    # <kB> -> "3.4 GiB"
  awk -v k="$1" 'BEGIN { if (k >= 1048576) printf "%.1f GiB", k / 1048576; else printf "%.0f MiB", k / 1024 }'
}

# <path> -> "path total_kb used_kb avail_kb percent" (df -Pk), nothing when df cannot measure it.
_hc_df() {
  local out; out="$(df -Pk "$1" 2>/dev/null | awk 'NR == 2 { gsub("%", "", $5); print $2, $3, $4, $5 }')" || return 0
  [ -z "${out}" ] || printf '%s %s\n' "$1" "${out}"
}

# The filesystem that matters for Kubernetes node images and volumes: Docker's data directory on Linux / WSL2 when it is visible from here,
# the user's volume on macOS. Prints "path total used avail percent" or nothing (Docker Desktop's VM disk is not visible: UNAVAILABLE).
hostcheck_disk() {
  local env root=""; env="$(hostcheck_env)"
  case "${env}" in
    macos) root="${HOME:-/}" ;;
    linux|wsl2)
      # Docker's data directory does not change while the sampler runs: asked once per process (hostcheck_collect primes HC_DOCKER_ROOT in its own shell).
      root="${HC_DOCKER_ROOT:-}"
      [ -n "${root}" ] || root="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || true)"
      [ -n "${root}" ] || root="/var/lib/docker"
      [ -d "${root}" ] || return 0 ;;
    *) return 0 ;;
  esac
  _hc_df "${root}"
}

_hc_cpu() {
  local env n=""; env="$(hostcheck_env)"
  case "${env}" in
    macos) n="$(sysctl -n hw.ncpu 2>/dev/null || true)" ;;
    linux|wsl2) n="$(grep -c '^processor' "${HC_PROC}/cpuinfo" 2>/dev/null || true)"; [ "${n:-0}" -gt 0 ] 2>/dev/null || n="$(nproc 2>/dev/null || true)" ;;
  esac
  if ! [ "${n:-0}" -gt 0 ] 2>/dev/null; then _hc_rec cpu UNAVAILABLE "Host CPU cores" "unavailable" "" "" "" ""; return; fi
  if [ "${n}" -ge 2 ]; then _hc_rec cpu OK "Host CPU cores" "${n}" "" "" "" ""
  else _hc_rec cpu WARNING "Host CPU cores" "${n}" "2 or more" "The Kubernetes control plane and the workloads compete for a single CPU: provisioning is slow and probes time out." \
    "Give the machine or VM more CPUs." ""; fi
}

_hc_memory() {
  local env total="" avail=""; env="$(hostcheck_env)"
  case "${env}" in
    linux|wsl2)
      total="$(awk '/^MemTotal:/ { print $2 }' "${HC_PROC}/meminfo" 2>/dev/null || true)"
      avail="$(awk '/^MemAvailable:/ { print $2 }' "${HC_PROC}/meminfo" 2>/dev/null || true)" ;;
    macos)
      total="$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1024 ))"
      avail="$(vm_stat 2>/dev/null | awk '/page size of/ { ps = $8 } /^Pages free/ { f = $3 } /^Pages inactive/ { i = $3 } /^Pages speculative/ { s = $3 }
        END { gsub(/\./, "", f); gsub(/\./, "", i); gsub(/\./, "", s); if (ps > 0) printf "%.0f", (f + i + s) * ps / 1024 }')" ;;
  esac
  if ! [ "${total:-0}" -gt 0 ] 2>/dev/null || ! [ "${avail:-x}" -ge 0 ] 2>/dev/null; then
    _hc_rec memory UNAVAILABLE "Host memory" "unavailable" "" "" "" ""; return
  fi
  local cur; cur="$(_hc_kb "${avail}") available of $(_hc_kb "${total}")"
  local fix="Close other applications, or add memory."
  [ "${env}" != wsl2 ] || fix="Raise the WSL2 memory limit: [wsl2] memory=... in %UserProfile%\\.wslconfig, then run: wsl --shutdown"
  if [ "${avail}" -lt 524288 ]; then
    _hc_rec memory CRITICAL "Host memory" "${cur}" "2 GiB or more available" "Kind/k3d nodes and the Docker VM can be killed for lack of memory." "${fix}" ""
  elif [ "${avail}" -lt 2097152 ]; then
    _hc_rec memory WARNING "Host memory" "${cur}" "2 GiB or more available" "Low free memory: Kubernetes API timeouts and evicted Pods are likely when a use case starts." "${fix}" ""
  else _hc_rec memory OK "Host memory" "${cur}" "" "" "" ""; fi
}

_hc_disk() {
  local p t u a pct env; env="$(hostcheck_env)"
  read -r p t u a pct <<< "${HC_DISK:-$(hostcheck_disk)}"      # HC_DISK: measured once by hostcheck_collect
  if [ -z "${pct:-}" ] || ! [ "${pct}" -ge 0 ] 2>/dev/null; then
    case "${env}" in
      linux|wsl2) _hc_rec disk UNAVAILABLE "Docker data disk" "unavailable (Docker's data directory is not visible from here, e.g. Docker Desktop's VM)" "" "" "" "" ;;
      *) _hc_rec disk UNAVAILABLE "Host disk" "unavailable" "" "" "" "" ;;
    esac
    return
  fi
  local cur="${pct}% used, $(_hc_kb "${a}") available of $(_hc_kb "${t}") on ${p}"
  local impact="Below 10% free the kubelet reports DiskPressure: Pods are evicted or cannot be scheduled and image pulls fail (Kind/k3d nodes live on this disk)."
  local fix="Free disk space before provisioning. Review first, then for example: docker image prune (the Playground never runs it for you)"
  [ "${env}" != macos ] || fix="${fix};;Docker Desktop also has its own disk image limit (Settings > Resources > Disk image size)"
  if [ "${pct}" -ge 90 ]; then _hc_rec disk CRITICAL "Host disk usage" "${cur}" "less than 85% used" "${impact}" "${fix}" ""
  elif [ "${pct}" -ge 85 ]; then _hc_rec disk WARNING "Host disk usage" "${cur}" "less than 85% used" "${impact}" "${fix}" ""
  else _hc_rec disk OK "Host disk usage" "${cur}" "" "" "" ""; fi
}

_hc_inodes() {
  local p pct total free; case "$(hostcheck_env)" in linux|wsl2) ;; *) return 0 ;; esac   # APFS has no fixed inode table
  p="${HC_DISK%% *}"; [ -n "${HC_DISK:-}" ] || p="$(hostcheck_disk | awk '{ print $1 }' || true)"
  [ -n "${p}" ] || { _hc_rec inodes UNAVAILABLE "Host inodes" "unavailable" "" "" "" ""; return; }
  read -r total free pct <<< "$(df -Pi "${p}" 2>/dev/null | awk 'NR == 2 { gsub("%", "", $5); print $2, $4, $5 }' || true)"
  if ! [ "${total:-0}" -gt 0 ] 2>/dev/null || ! [ "${pct:-x}" -ge 0 ] 2>/dev/null; then
    _hc_rec inodes UNAVAILABLE "Host inodes" "unavailable (this filesystem reports no inode table)" "" "" "" ""; return
  fi
  local cur="${pct}% used, ${free} free of ${total} on ${p}"
  local impact="Without free inodes nothing new can be created, even with free space: image pulls and containerd fail, and the kubelet reports DiskPressure."
  local fix="Remove unused images and containers (review first): docker system df, then docker image prune"
  if [ "${pct}" -ge 95 ]; then _hc_rec inodes CRITICAL "Host inodes" "${cur}" "less than 90% used" "${impact}" "${fix}" ""
  elif [ "${pct}" -ge 90 ]; then _hc_rec inodes WARNING "Host inodes" "${cur}" "less than 90% used" "${impact}" "${fix}" ""
  else _hc_rec inodes OK "Host inodes" "${cur}" "" "" "" ""; fi
}

_hc_inotify() {
  local env inst watch; env="$(hostcheck_env)"
  case "${env}" in
    macos) _hc_rec inotify UNAVAILABLE "inotify limits" "unavailable (they belong to Docker Desktop's VM, not to macOS; macOS has no sysctl for them)" "" "" "" ""; return ;;
    linux|wsl2) ;;
    *) return 0 ;;
  esac
  inst="$(cat "${HC_PROC}/sys/fs/inotify/max_user_instances" 2>/dev/null || true)"; watch="$(cat "${HC_PROC}/sys/fs/inotify/max_user_watches" 2>/dev/null || true)"
  if ! [ "${inst:-x}" -ge 0 ] 2>/dev/null || ! [ "${watch:-x}" -ge 0 ] 2>/dev/null; then
    _hc_rec inotify UNAVAILABLE "inotify limits" "unavailable (cannot read fs.inotify.*)" "" "" "" ""; return
  fi
  local cur="max_user_instances = ${inst};;max_user_watches   = ${watch}"
  local rec="max_user_instances = ${HC_INOTIFY_INSTANCES};;max_user_watches   = ${HC_INOTIFY_WATCHES}"
  local fix="" restore="" status=OK
  if [ "${inst}" -lt "${HC_INOTIFY_INSTANCES}" ]; then
    fix="sudo sysctl -w fs.inotify.max_user_instances=${HC_INOTIFY_INSTANCES}"; restore="sudo sysctl -w fs.inotify.max_user_instances=${inst}"
  fi
  if [ "${watch}" -lt "${HC_INOTIFY_WATCHES}" ]; then
    fix="${fix:+${fix};;}sudo sysctl -w fs.inotify.max_user_watches=${HC_INOTIFY_WATCHES}"; restore="${restore:+${restore};;}sudo sysctl -w fs.inotify.max_user_watches=${watch}"
  fi
  [ "${inst}" -ge 512 ] && [ "${watch}" -ge 262144 ] || status=WARNING
  { [ "${inst}" -ge 64 ] && [ "${watch}" -ge 8192 ]; } || status=CRITICAL
  if [ "${status}" = OK ]; then _hc_rec inotify OK "inotify limits" "${cur}" "" "" "" ""; return; fi
  if [ "${env}" = wsl2 ]; then
    fix="${fix};;(run inside the WSL2 distro: all WSL2 distros and Docker Desktop's WSL2 backend share one kernel; the change is lost after: wsl --shutdown)"
  fi
  _hc_rec inotify "${status}" "Linux inotify limits" "${cur}" "${rec}" \
    "Kind/k3d nodes (kubelet, containerd, many Pods) can fail with 'too many open files' or 'no space left on device' under heavy workloads." "${fix}" "${restore}"
}

_hc_fds() {
  local n; case "$(hostcheck_env)" in linux|wsl2) ;; *) return 0 ;; esac
  n="$(ulimit -n 2>/dev/null)"
  if ! [ "${n:-x}" -ge 0 ] 2>/dev/null && [ "${n}" != unlimited ]; then _hc_rec fds UNAVAILABLE "Open-file limit (ulimit -n)" "unavailable" "" "" "" ""; return; fi
  if [ "${n}" = unlimited ] || [ "${n}" -ge 1024 ]; then _hc_rec fds OK "Open-file limit (ulimit -n)" "${n}" "" "" "" ""
  else _hc_rec fds WARNING "Open-file limit (ulimit -n)" "${n}" "1024 or more" \
    "Limit of this shell and the tools it starts (kubectl, helm, kind); containers use Docker's own limit, set by its service." \
    "ulimit -n 65536   (this shell only; the hard limit applies)" "ulimit -n ${n}"; fi
}

# hostcheck_collect [provider]: every record. An external provider's cluster is not on this host: no host check applies to it.
hostcheck_collect() {
  [ "${1:-}" != external ] || return 0
  # Measured once for the whole run (and Docker's data directory once per process): no repeated df / docker info. When called directly
  # (not in a command substitution) HC_DISK stays available to the caller, which is how the sampler reads the disk figures.
  case "$(hostcheck_env)" in linux|wsl2) [ -n "${HC_DOCKER_ROOT:-}" ] || HC_DOCKER_ROOT="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || true)" ;; esac
  HC_DISK="$(hostcheck_disk)"
  _hc_cpu; _hc_memory; _hc_disk; _hc_inodes; _hc_inotify; _hc_fds
}

# hostcheck_counts: reads records on stdin, prints "<critical> <warning> <unavailable>".
hostcheck_counts() {
  awk -F'|' '$2 == "CRITICAL" { c++ } $2 == "WARNING" { w++ } $2 == "UNAVAILABLE" { u++ } END { printf "%d %d %d\n", c, w, u }'
}
# hostcheck_summary: records on stdin -> "1 critical, 1 warning (2 not measurable here)" or "all OK" (an unavailable metric is information, not a problem).
hostcheck_summary() {
  local c w u out=""; read -r c w u <<< "$(hostcheck_counts)"
  [ "${c}" -eq 0 ] || out="${c} critical"
  [ "${w}" -eq 0 ] || out="${out:+${out}, }${w} warning$([ "${w}" -eq 1 ] || echo s)"
  out="${out:-all OK}"
  [ "${u}" -eq 0 ] || out="${out} (${u} not measurable here)"
  printf '%s\n' "${out}"
}

# hostcheck_text <record>: the human block. Corrections are printed for the user to run: nothing is executed.
hostcheck_text() {
  local rec="$1" id st title cur recm impact fix restore l
  IFS='|' read -r id st title cur recm impact fix restore <<< "${rec}"
  _blk() { [ -z "$2" ] || { printf '%s\n' "$1"; printf '%s\n' "$2" | sed 's/;;/\
/g; s/^/  /'; }; }
  case "${st}" in CRITICAL) printf 'Critical: %s\n' "${title}" ;; *) printf 'Warning: %s\n' "${title}" ;; esac
  _blk "Current:" "${cur}"; _blk "Recommended:" "${recm}"; _blk "Impact:" "${impact}"
  _blk "Correction (manual; the Playground never runs it):" "${fix}"; _blk "Restore the previous value:" "${restore}"
  unset -f _blk
}

# hostcheck_log <record>: that block through the shared logger (engine/lib/logger.sh must be sourced): the title line at its level (CRITICAL = ERROR,
# WARNING = WARN), the details as INFO lines.
hostcheck_log() {
  local st; st="$(printf '%s' "$1" | cut -d'|' -f2)"
  hostcheck_text "$1" | {
    IFS= read -r l
    if [ "${st}" = CRITICAL ]; then log_error "${l}"; else log_warn "${l}"; fi
    while IFS= read -r l; do log_info "${l}"; done
  }
}

# hostcheck_preflight <provider>: before provisioning, warnings in the operation log (stdout of usecase start). Never fails, never blocks.
# The measurements come from the host sampler (engine/host-metrics.sh), which runs on the real host: this code runs inside the container and
# must not present the container's view as the host's.
hostcheck_preflight() {
  local provider="${1:-kind}" file="${PROJECT_ROOT:-.}/.host-checks" ts now line shown=0
  [ "${provider}" != external ] || return 0
  ts="$(sed -n '1s/^#ts=//p' "${file}" 2>/dev/null || true)"; now="$(date +%s)"
  if ! [ "${ts:-x}" -ge 0 ] 2>/dev/null || [ $(( now - ts )) -gt "${HC_FRESH_SECONDS}" ]; then
    log_info "Host resource diagnostics are not available (the host-side sampler is not running). Run ./playground doctor on the host."
    return 0
  fi
  while IFS= read -r line; do
    case "${line}" in \#*|"") continue ;; esac
    case "$(printf '%s' "${line}" | cut -d'|' -f2)" in WARNING|CRITICAL) ;; *) continue ;; esac
    shown=1
    hostcheck_log "${line}"
  done < "${file}"
  [ "${shown}" = 1 ] || log_info "Host resources: no warning (details: ./playground doctor)"
  return 0
}
