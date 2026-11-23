#!/usr/bin/env bash
# Cleanup of partially created clusters (the Stop that Cancel reuses): engine/providers/kind/down.sh and the k3d provider_destroy remove, by the
# provider's own Docker label, the leftover containers of ONE cluster even when the provider no longer lists it (a creation killed half way),
# and only those. `docker`, `kind`, `k3d` are stubs that log their calls: nothing real is created, stopped or deleted.
# The stub call logs are the evidence (the engine's own log lines are not read). Run: tests/lifecycle.sh
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
FAIL=0
check() { if [ "$2" = ok ]; then echo "PASS $1"; else echo "FAIL $1   [$3]"; FAIL=1; fi; }
T="$(cd "$(mktemp -d)" && pwd -P)"; trap 'rm -rf "${T}"' EXIT
mkdir -p "${T}/bin"; export CALLS="${T}/calls"
# docker: `ps -aq --filter label=<k>=<cluster>` answers the ids registered in FAKE_CONTAINERS ("<label value> <id>" lines); `rm -f ids` is logged.
cat > "${T}/bin/docker" <<'STUB'
#!/bin/bash
echo "docker $*" >> "${CALLS}"
case "$1" in
  info) exit 0 ;;
  ps) filter="${@: -1}"; value="${filter#*=*=}"; awk -v v="${value}" '$1 == v { print $2 }' "${FAKE_CONTAINERS:-/dev/null}" ;;
  rm) exit 0 ;;
esac
STUB
cat > "${T}/bin/kind" <<'STUB'
#!/bin/bash
echo "kind $*" >> "${CALLS}"
[ "$1 $2" = "get clusters" ] && printf '%s\n' ${FAKE_KIND_CLUSTERS:-}; exit 0
STUB
cat > "${T}/bin/k3d" <<'STUB'
#!/bin/bash
echo "k3d $*" >> "${CALLS}"
[ "$1 $2" = "cluster list" ] && { printf '['; sep=""; for c in ${FAKE_K3D_CLUSTERS:-}; do printf '%s{"name":"%s"}' "${sep}" "${c}"; sep=","; done; printf ']\n'; }; exit 0
STUB
chmod +x "${T}/bin/"*; export PATH="${T}/bin:${PATH}"
printf 'cnpg-lab-demo-1 aaa111\ncnpg-lab-demo-1 aaa222\ncnpg-lab-demo-2 bbb111\ncnpg-lab-other-1 ccc111\n' > "${T}/containers"; export FAKE_CONTAINERS="${T}/containers"
removed() { grep '^docker rm -f' "${CALLS}" | sed 's/^docker rm -f //' | tr ' ' '\n' | sort | tr '\n' ' '; }
KD="engine/providers/kind/down.sh"

# --- Kind: the cluster is not listed any more (creation killed): its labeled containers are removed, nothing else ---
: > "${CALLS}"; FAKE_KIND_CLUSTERS="" bash "${KD}" cnpg-lab-demo-1 >/dev/null 2>&1; rc=$?
[ "${rc}" = 0 ] && [ "$(removed)" = "aaa111 aaa222 " ] && r=ok || r=bad; check "Kind: a partially created cluster (not listed) is cleaned by label; other clusters are untouched" "$r" "rc=${rc} removed=$(removed)"
grep -q 'docker ps -aq --filter label=io.x-k8s.kind.cluster=cnpg-lab-demo-1$' "${CALLS}" && r=ok || r=bad; check "Kind: the label filter is the exact cluster name" "$r" "$(grep 'docker ps' "${CALLS}")"
grep -q '^kind delete' "${CALLS}" && r=bad || r=ok; check "Kind: no 'kind delete' for a cluster that does not exist" "$r"
# --- a listed cluster is deleted by kind, then swept (idempotent second pass) ---
: > "${CALLS}"; FAKE_KIND_CLUSTERS="cnpg-lab-demo-1" bash "${KD}" cnpg-lab-demo-1 >/dev/null 2>&1
grep -q '^kind delete cluster --name cnpg-lab-demo-1' "${CALLS}" && r=ok || r=bad; check "Kind: a listed cluster is deleted with kind" "$r" "$(cat "${CALLS}")"
: > "${CALLS}"; FAKE_CONTAINERS=/dev/null bash "${KD}" cnpg-lab-demo-1 >/dev/null 2>&1; rc=$?
[ "${rc}" = 0 ] && [ -z "$(removed)" ] && r=ok || r=bad; check "Kind: nothing left, nothing to do (idempotent, rc 0)" "$r" "rc=${rc} $(removed)"
# --- several clusters: every cluster of the use case, never another use case ---
: > "${CALLS}"; FAKE_KIND_CLUSTERS="cnpg-lab-demo-1" bash "${KD}" cnpg-lab-demo-1 cnpg-lab-demo-2 >/dev/null 2>&1
[ "$(removed)" = "aaa111 aaa222 bbb111 " ] && r=ok || r=bad; check "Kind multi-cluster: cluster 1 (listed) and cluster 2 (half created) are both cleaned; 'other' is untouched" "$r" "$(removed)"
# --- names outside the playground pattern are refused before anything happens ---
: > "${CALLS}"; bash "${KD}" "kind" >/dev/null 2>&1; rc=$?
[ "${rc}" != 0 ] && [ -z "$(removed)" ] && r=ok || r=bad; check "Kind: a foreign cluster name is refused, nothing removed" "$r" "rc=${rc}"
: > "${CALLS}"; bash "${KD}" 'cnpg-lab-demo-1 --all' >/dev/null 2>&1; rc=$?
[ "${rc}" != 0 ] && [ -z "$(removed)" ] && r=ok || r=bad; check "Kind: a name with extra words is refused" "$r" "rc=${rc}"

# --- k3d ---
k3d_destroy() { ( PLAYGROUND_PROVIDER=k3d bash -c 'source engine/lib/provider.sh; provider_destroy "$@"' _ "$@" >/dev/null 2>&1 ); }
printf 'cnpg-lab-demo-1 k1\ncnpg-lab-demo-1 k2\ncnpg-lab-demo-1 k3\ncnpg-lab-other-1 z1\n' > "${T}/containers"
if command -v jq >/dev/null 2>&1; then
  : > "${CALLS}"; FAKE_K3D_CLUSTERS="" k3d_destroy cnpg-lab-demo-1; rc=$?
  [ "${rc}" = 0 ] && [ "$(removed)" = "k1 k2 k3 " ] && r=ok || r=bad; check "k3d: a half-created cluster (nodes + load balancer, not listed) is removed by its k3d label only" "$r" "rc=${rc} $(removed)"
  grep -q 'docker ps -aq --filter label=k3d.cluster=cnpg-lab-demo-1$' "${CALLS}" && r=ok || r=bad; check "k3d: the label filter is the exact cluster name" "$r" "$(grep 'docker ps' "${CALLS}")"
  : > "${CALLS}"; FAKE_K3D_CLUSTERS="cnpg-lab-demo-1" k3d_destroy cnpg-lab-demo-1
  grep -q '^k3d cluster delete cnpg-lab-demo-1' "${CALLS}" && r=ok || r=bad; check "k3d: a listed cluster is deleted with k3d" "$r" "$(cat "${CALLS}")"
  : > "${CALLS}"; k3d_destroy "other"; [ -z "$(removed)" ] && r=ok || r=bad; check "k3d: a foreign name is refused, nothing removed" "$r" "$(removed)"
else echo "SKIP k3d cleanup tests (jq not installed)"; fi

# --- the cleanup stays inside the providers: the generic engine names no Docker (also checked by tests/provider.sh) ---
grep -nE '^[^#]*docker' engine/usecase.sh engine/usecase-run.sh >/dev/null && r=bad || r=ok; check "the generic engine still names no Docker" "$r"

[ "${FAIL}" = 0 ] && echo "ALL LIFECYCLE TESTS PASSED" || { echo "SOME LIFECYCLE TESTS FAILED"; exit 1; }
