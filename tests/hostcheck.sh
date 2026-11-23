#!/usr/bin/env bash
# Host diagnostics (engine/lib/hostcheck.sh, shared by `./playground doctor`, the host sampler and the pre-provisioning check).
# Everything is simulated: /proc is a fixture directory, df / docker / sysctl are stubs on PATH. Nothing real is measured or changed; the
# sysctl stub records every call so the test proves that no setting is ever modified. Bash 3.2 compatible. Run: tests/hostcheck.sh
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
ROOT="$PWD"; FAIL=0
check() { if [ "$2" = ok ]; then echo "PASS $1"; else echo "FAIL $1   [$3]"; FAIL=1; fi; }
T="$(cd "$(mktemp -d)" && pwd -P)"; trap 'rm -rf "${T}"' EXIT
mkdir -p "${T}/bin" "${T}/proc/sys/fs/inotify"
cat > "${T}/bin/df" <<'STUB'
#!/bin/sh
echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
case "$*" in
  *-Pi*) echo "/dev/x ${FAKE_DF_I:-1000000 1000 999000 1%} /m" | sed 's/^\(\/dev\/x [0-9]* \)\([0-9]*\) \([0-9]*\) /\1\2 \3 /';;
  *) echo "/dev/x ${FAKE_DF_K:-100000000 40000000 60000000 40%} /m";;
esac
STUB
cat > "${T}/bin/docker" <<'STUB'
#!/bin/sh
[ "$1" = info ] && { echo "${FAKE_DOCKER_ROOT:-/tmp}"; exit 0; }; exit 1
STUB
cat > "${T}/bin/sysctl" <<'STUB'
#!/bin/sh
echo "sysctl $*" >> "${SYSCTL_LOG}"; case "$1" in -n) echo 8;; esac
STUB
chmod +x "${T}/bin/"*
export PATH="${T}/bin:${PATH}" SYSCTL_LOG="${T}/sysctl.log" HOSTCHECK_PROC="${T}/proc"; : > "${SYSCTL_LOG}"
printf 'processor\t: 0\nprocessor\t: 1\nprocessor\t: 2\nprocessor\t: 3\n' > "${T}/proc/cpuinfo"
printf 'MemTotal:       16000000 kB\nMemAvailable:   12000000 kB\n' > "${T}/proc/meminfo"
echo 8192 > "${T}/proc/sys/fs/inotify/max_user_instances"; echo 1048576 > "${T}/proc/sys/fs/inotify/max_user_watches"
echo "Linux version 6.8.0-generic" > "${T}/proc/version"
run() { ( source engine/lib/hostcheck.sh; "$@" ); }                 # a clean shell per call
rec() { run hostcheck_collect "${2:-}" | grep "^$1|"; }              # record <id> [provider]
status() { rec "$1" "${2:-}" | cut -d'|' -f2; }
export HOSTCHECK_OS=linux FAKE_DOCKER_ROOT="${T}"                    # the docker "data directory" is a directory that exists

# --- environment detection ---
[ "$(run hostcheck_env)" = linux ] && r=ok || r=bad; check "native Linux is detected" "$r" "$(run hostcheck_env)"
out="$(HOSTCHECK_OS=Linux; echo "5.15.153.1-microsoft-standard-WSL2" > "${T}/proc/version"; export HOSTCHECK_OS; run hostcheck_env)"
[ "${out}" = wsl2 ] && r=ok || r=bad; check "WSL2 is detected from /proc/version" "$r" "${out}"
out="$(HOSTCHECK_OS=macos run hostcheck_env)"; [ "${out}" = macos ] && r=ok || r=bad; check "macOS is detected" "$r" "${out}"
echo "Linux version 6.8.0-generic" > "${T}/proc/version"

# --- Linux: healthy host, every check OK ---
bad=""; for id in cpu memory disk inodes inotify fds; do [ "$(status ${id})" = OK ] || bad="${bad} ${id}=$(status ${id})"; done
[ -z "${bad}" ] && r=ok || r=bad; check "a healthy Linux host reports OK for CPU, memory, disk, inodes, inotify and open files" "$r" "${bad}"
rec cpu | grep -q '|4|' && r=ok || r=bad; check "CPU cores are counted" "$r" "$(rec cpu)"
rec memory | grep -q '11.4 GiB available of 15.3 GiB' && r=ok || r=bad; check "memory reports available and total" "$r" "$(rec memory)"

# --- inotify: warning with exact correction and restore commands ---
echo 128 > "${T}/proc/sys/fs/inotify/max_user_instances"; echo 65536 > "${T}/proc/sys/fs/inotify/max_user_watches"
x="$(rec inotify)"
[ "$(cut -d'|' -f2 <<< "${x}")" = WARNING ] && r=ok || r=bad; check "low inotify limits are a WARNING" "$r" "${x}"
fix="$(cut -d'|' -f7 <<< "${x}")"; restore="$(cut -d'|' -f8 <<< "${x}")"
[ "${fix}" = "sudo sysctl -w fs.inotify.max_user_instances=8192;;sudo sysctl -w fs.inotify.max_user_watches=524288" ] && r=ok || r=bad; check "inotify correction = recommended values (8192 / 524288)" "$r" "${fix}"
[ "${restore}" = "sudo sysctl -w fs.inotify.max_user_instances=128;;sudo sysctl -w fs.inotify.max_user_watches=65536" ] && r=ok || r=bad; check "inotify restore = the previous values" "$r" "${restore}"
txt="$(run hostcheck_text "${x}")"
grep -q '^\[WARNING\] Linux inotify limits' <<< "${txt}" && grep -q '^Impact:' <<< "${txt}" && grep -q '^  sudo sysctl -w fs.inotify.max_user_instances=8192' <<< "${txt}" && grep -q '^Restore the previous value:' <<< "${txt}" && r=ok || r=bad
check "the text block shows current / recommended / impact / correction / restore" "$r" "${txt}"
echo 8192 > "${T}/proc/sys/fs/inotify/max_user_instances"; echo 20 > "${T}/proc/sys/fs/inotify/max_user_watches"
[ "$(status inotify)" = CRITICAL ] && r=ok || r=bad; check "absurdly low inotify limits are CRITICAL" "$r" "$(status inotify)"
echo 600 > "${T}/proc/sys/fs/inotify/max_user_instances"; echo 300000 > "${T}/proc/sys/fs/inotify/max_user_watches"
[ "$(status inotify)" = OK ] && r=ok || r=bad; check "inotify between the advisory floor and the recommendation is OK (a recommendation is not a requirement)" "$r" "$(status inotify)"
echo 8192 > "${T}/proc/sys/fs/inotify/max_user_instances"; echo 1048576 > "${T}/proc/sys/fs/inotify/max_user_watches"

# --- WSL2: correction targets the shared WSL2 kernel ---
echo "5.15.153.1-microsoft-standard-WSL2" > "${T}/proc/version"; echo 128 > "${T}/proc/sys/fs/inotify/max_user_instances"
x="$(HOSTCHECK_OS=Linux rec inotify)"
grep -q 'wsl --shutdown' <<< "${x}" && grep -q 'one kernel' <<< "${x}" && r=ok || r=bad; check "WSL2 inotify advice names the shared WSL2 kernel and 'wsl --shutdown'" "$r" "${x}"
HOSTCHECK_OS=Linux; export HOSTCHECK_OS
x="$(echo 'MemTotal: 16000000 kB
MemAvailable: 1000000 kB' > "${T}/proc/meminfo"; rec memory)"
grep -q 'wslconfig' <<< "${x}" && r=ok || r=bad; check "WSL2 memory advice points to .wslconfig" "$r" "${x}"
HOSTCHECK_OS=linux; export HOSTCHECK_OS; echo "Linux version 6.8.0-generic" > "${T}/proc/version"; echo 8192 > "${T}/proc/sys/fs/inotify/max_user_instances"

# --- memory severities ---
printf 'MemTotal: 16000000 kB\nMemAvailable: 1500000 kB\n' > "${T}/proc/meminfo"; [ "$(status memory)" = WARNING ] && r=ok || r=bad; check "memory below 2 GiB available is a WARNING" "$r" "$(status memory)"
printf 'MemTotal: 16000000 kB\nMemAvailable: 300000 kB\n' > "${T}/proc/meminfo"; [ "$(status memory)" = CRITICAL ] && r=ok || r=bad; check "memory below 512 MiB available is CRITICAL" "$r" "$(status memory)"
rm -f "${T}/proc/meminfo"; [ "$(status memory)" = UNAVAILABLE ] && r=ok || r=bad; check "unreadable memory is UNAVAILABLE, not zero" "$r" "$(status memory)"
printf 'MemTotal: 16000000 kB\nMemAvailable: 12000000 kB\n' > "${T}/proc/meminfo"

# --- disk and inodes ---
export FAKE_DF_K="100000000 99000000 3500000 99%"; x="$(rec disk)"
[ "$(cut -d'|' -f2 <<< "${x}")" = CRITICAL ] && grep -q '99% used, 3.3 GiB available' <<< "${x}" && grep -q 'DiskPressure' <<< "${x}" && r=ok || r=bad; check "99% disk: CRITICAL, shows available space and explains DiskPressure" "$r" "${x}"
grep -q 'never runs it for you' <<< "${x}" && r=ok || r=bad; check "disk advice never prunes automatically" "$r" "${x}"
export FAKE_DF_K="100000000 87000000 13000000 87%"; [ "$(status disk)" = WARNING ] && r=ok || r=bad; check "87% disk is a WARNING" "$r" "$(status disk)"
export FAKE_DF_K="100000000 40000000 60000000 40%"
export FAKE_DF_I="1000000 960000 40000 96%"; [ "$(status inodes)" = CRITICAL ] && r=ok || r=bad; check "96% inodes is CRITICAL" "$r" "$(status inodes)"
export FAKE_DF_I="1000000 910000 90000 91%"; [ "$(status inodes)" = WARNING ] && r=ok || r=bad; check "91% inodes is a WARNING" "$r" "$(status inodes)"
export FAKE_DF_I="0 0 0 -"; [ "$(status inodes)" = UNAVAILABLE ] && r=ok || r=bad; check "a filesystem without an inode table is UNAVAILABLE" "$r" "$(status inodes)"
unset FAKE_DF_I
FAKE_DOCKER_ROOT="${T}/not-visible"; export FAKE_DOCKER_ROOT
[ "$(status disk)" = UNAVAILABLE ] && r=ok || r=bad; check "Docker's data directory not visible (Docker Desktop VM): disk is UNAVAILABLE, not the distro's disk" "$r" "$(rec disk)"
FAKE_DOCKER_ROOT="${T}"; export FAKE_DOCKER_ROOT

# --- open files ---
x="$(run bash -c 'ulimit -Sn 256; source engine/lib/hostcheck.sh; hostcheck_collect | grep "^fds|"')"
cut -d'|' -f2 <<< "${x}" | grep -q WARNING && grep -q 'ulimit -n 256' <<< "${x}" && r=ok || r=bad; check "a low open-file limit is a WARNING with a restore command" "$r" "${x}"

# --- macOS: existing behavior kept, unmeasurable things reported as unavailable ---
cat > "${T}/bin/sysctl" <<'STUB'
#!/bin/sh
echo "sysctl $*" >> "${SYSCTL_LOG}"; case "$2" in hw.ncpu) echo 10;; hw.memsize) echo 17179869184;; esac
STUB
cat > "${T}/bin/vm_stat" <<'STUB'
#!/bin/sh
printf 'Mach Virtual Memory Statistics: (page size of 16384 bytes)\nPages free: 100000.\nPages inactive: 200000.\nPages speculative: 10000.\n'
STUB
chmod +x "${T}/bin/"*; export HOSTCHECK_OS=macos HOME="${T}"
all="$(run hostcheck_collect)"; ids="$(cut -d'|' -f1 <<< "${all}" | tr '\n' ' ')"
[ "${ids}" = "cpu memory disk inotify " ] && r=ok || r=bad; check "macOS checks: CPU, memory, disk, inotify (no inodes, no ulimit)" "$r" "${ids}"
[ "$(status inotify)" = UNAVAILABLE ] && grep -q "Docker Desktop's VM" <<< "$(rec inotify)" && r=ok || r=bad; check "macOS inotify is UNAVAILABLE and says why (never a container value)" "$r" "$(rec inotify)"
rec cpu | grep -q '|10|' && rec memory | grep -q '4.7 GiB available of 16.0 GiB' && r=ok || r=bad; check "macOS CPU and memory are read from sysctl / vm_stat" "$r" "$(rec cpu) $(rec memory)"
unset HOSTCHECK_OS; HOSTCHECK_OS=linux; export HOSTCHECK_OS

# --- providers and security ---
[ -z "$(run hostcheck_collect external)" ] && r=ok || r=bad; check "an external provider gets no host check (its cluster is not on this host)" "$r" "$(run hostcheck_collect external)"
[ -n "$(run hostcheck_collect kind)" ] && [ -n "$(run hostcheck_collect k3d)" ] && r=ok || r=bad; check "kind and k3d get the host checks" "$r"
grep -q 'sysctl -w\|-w ' "${SYSCTL_LOG}" && r=bad || r=ok; check "diagnostics never run sysctl -w (no kernel parameter is modified)" "$r" "$(cat "${SYSCTL_LOG}")"
hits="$(grep -nE '^[^#]*\b(docker (system|image) prune|sudo)\b' engine/lib/hostcheck.sh | grep -vE "_hc_rec|fix=|restore=|printf|\"sudo|\{fix" )"
[ -z "${hits}" ] && r=ok || r=bad; check "hostcheck.sh only prints corrections (no sudo/prune is ever executed)" "$r" "${hits}"

# --- pre-provisioning check: reads the host sampler's file, warns, never blocks ---
export PROJECT_ROOT="${T}/pr"; mkdir -p "${PROJECT_ROOT}"
# logger.sh needs Bash 4 (printf %T): the preflight only calls log_info / log_warn, so plain stand-ins keep this test runnable on Bash 3.2
pf() { ( log_info() { echo "INFO $*"; }; log_warn() { echo "WARN $*"; }; source engine/lib/hostcheck.sh; set -Eeuo pipefail; hostcheck_preflight "$1"; echo "rc=$?" ) 2>&1; }
out="$(pf kind)"; grep -q 'not available' <<< "${out}" && grep -q 'rc=0' <<< "${out}" && r=ok || r=bad; check "no sampler file: an information line, rc 0" "$r" "${out}"
x="disk|CRITICAL|Host disk usage|99% used, 3.4 GiB available of 100 GiB on /var/lib/docker|less than 85% used|Below 10% free the kubelet reports DiskPressure.|Free disk space before provisioning.|"
printf '#ts=%s\n%s\n' "$(date +%s)" "${x}" > "${PROJECT_ROOT}/.host-checks"
out="$(pf k3d)"; grep -q 'WARN.*\[CRITICAL\] Host disk usage' <<< "${out}" && grep -q 'DiskPressure' <<< "${out}" && grep -q 'Free disk space before provisioning' <<< "${out}" && grep -q 'rc=0' <<< "${out}" && r=ok || r=bad
check "k3d start: the disk warning is logged with impact and correction, and does not block (rc 0)" "$r" "${out}"
out="$(pf external)"; ! grep -q 'DiskPressure' <<< "${out}" && grep -q 'rc=0' <<< "${out}" && r=ok || r=bad; check "external start: no host warning" "$r" "${out}"
printf '#ts=%s\n%s\n' "$(( $(date +%s) - 3600 ))" "${x}" > "${PROJECT_ROOT}/.host-checks"
out="$(pf kind)"; ! grep -q 'DiskPressure' <<< "${out}" && grep -q 'not available' <<< "${out}" && r=ok || r=bad; check "a stale sampler file is not trusted" "$r" "${out}"
printf '#ts=%s\n' "$(date +%s)" > "${PROJECT_ROOT}/.host-checks"
out="$(pf kind)"; grep -q 'no warning' <<< "${out}" && r=ok || r=bad; check "fresh file without warnings: one information line" "$r" "${out}"

# --- the sampler (engine/host-metrics.sh) publishes disk and the warning summary through the same functions ---
export HOSTCHECK_OS=linux; : > "${SYSCTL_LOG}"
echo 128 > "${T}/proc/sys/fs/inotify/max_user_instances"
mkdir -p "${T}/repo/engine/lib"; cp engine/host-metrics.sh "${T}/repo/engine/"; cp engine/lib/hostcheck.sh "${T}/repo/engine/lib/"
out="$(bash -c 'source "$1/repo/engine/host-metrics.sh"; refresh_checks; write 5.0 4 100 200; cat "${OUT}"; head -1 "${CHECKS}" | cut -c1-4; grep -c "|" "${CHECKS}"' _ "${T}" 2>&1)"
grep -q '"disk_percent": 40' <<< "${out}" && grep -q '"warnings": 1' <<< "${out}" && grep -q '"warning_titles": "Linux inotify limits"' <<< "${out}" && grep -q '^#ts=' <<< "${out}" && r=ok || r=bad
check "the sampler writes disk_percent, the warning count/titles and the .host-checks file" "$r" "${out}"
[ -z "$(grep -n 'sysctl -w' "${SYSCTL_LOG}")" ] && r=ok || r=bad; check "the sampler never modifies a setting" "$r"

[ "${FAIL}" = 0 ] && echo "ALL HOSTCHECK TESTS PASSED" || { echo "SOME HOSTCHECK TESTS FAILED"; exit 1; }
