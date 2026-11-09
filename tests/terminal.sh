#!/usr/bin/env bash
# Web terminal without a session manager (SPEC-007.1.7).
#  A. static: tmux is gone from every executable path; ttyd keeps >= 10000 lines of scrollback and no Option workaround.
#  B. engine/terminal.sh in a throwaway container from the Playground image (no Docker socket, no published port,
#     removed afterwards; skipped without Docker or the image): own kubeconfig file, working directory, UTF-8, validation.
# The browser behavior (scrolling, selection, Cmd+C/V, Vim, ui_watch, refresh) cannot be asserted here: see the spec.
# Run: tests/terminal.sh
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
ROOT="$PWD"; FAIL=0
check() { if [ "$2" = ok ]; then echo "PASS $1"; else echo "FAIL $1   [$3]"; FAIL=1; fi; }

hits="$(grep -rIil tmux Dockerfile compose.yaml playground engine web platform usecases 2>/dev/null | grep -v '/README.md$')"
[ -z "${hits}" ] && r=ok || r=bad; check "no tmux in Dockerfile, CLI, engine, web, platform, use cases" "$r" "${hits}"
[ ! -e engine/shell/tmux.conf ] && r=ok || r=bad; check "engine/shell/tmux.conf removed" "$r"
cmd="$(grep -E '^CMD \["ttyd"' Dockerfile)"
grep -q '"-t", "scrollback=10000"' <<< "${cmd}" && r=ok || r=bad; check "ttyd scrollback is 10000 lines" "$r" "${cmd}"
! grep -q macOptionClickForcesSelection Dockerfile && r=ok || r=bad; check "no macOptionClickForcesSelection workaround" "$r"
grep -q '"bash", "/workspace/engine/terminal.sh"\]' <<< "${cmd}" && r=ok || r=bad; check "ttyd runs terminal.sh directly (no wrapper, no attach)" "$r" "${cmd}"
grep -q 'clear() { command clear -x' engine/shell/bashrc && r=ok || r=bad; check "clear keeps the scrollback (clear -x)" "$r"
! grep -q '/connect' web/app.py web/static/app.js && r=ok || r=bad; check "no terminal connect endpoint or call" "$r"

IMG="$(docker inspect -f '{{.Config.Image}}' cnpg-playground 2>/dev/null)"
if command -v docker >/dev/null 2>&1 && [ -n "${IMG}" ] && docker image inspect "${IMG}" >/dev/null 2>&1; then
  run() { docker run --rm -i -v "${ROOT}:/workspace:ro" --entrypoint bash "${IMG}" /workspace/engine/terminal.sh "$@" 2>&1; }
  show='echo "CWD=$PWD FILE=$PLAYGROUND_KUBECONFIG LANG=$LANG"; cat "$PLAYGROUND_KUBECONFIG"; exit'
  out="$(echo "${show}" | run)"
  grep -q 'CWD=/workspace/usecases FILE=/root/.kube/terminals/playground-main.yaml LANG=C.UTF-8' <<< "${out}" && r=ok || r=bad; check "Playground terminal (no /usecases link yet): falls back to the real usecases directory, own kubeconfig file, UTF-8" "$r" "${out}"
  out="$(echo "${show}" | run cnpg-standard)"
  grep -q 'CWD=/workspace/usecases/cnpg-standard FILE=/root/.kube/terminals/playground-uc-cnpg-standard.yaml' <<< "${out}" && grep -q '^current-context: kind-cnpg-lab-cnpg-standard-1$' <<< "${out}" && r=ok || r=bad; check "use case terminal: use case dir, own file, its context" "$r" "${out}"
  # A file with copies of clusters/users (stale after a cluster is recreated) is cut down to its current-context.
  seed='mkdir -p /root/.kube/terminals; printf "apiVersion: v1\nkind: Config\nclusters:\n- name: stale\ncurrent-context: chosen-ctx\nusers:\n- name: stale\n" > /root/.kube/terminals/playground-main.yaml; exec bash /workspace/engine/terminal.sh'
  out="$(echo "${show}" | docker run --rm -i -v "${ROOT}:/workspace:ro" --entrypoint bash "${IMG}" -c "${seed}" 2>&1)"
  { grep -q '^current-context: chosen-ctx$' <<< "${out}" && ! grep -q 'stale' <<< "${out}"; } && r=ok || r=bad; check "terminal file keeps its context, drops stale clusters/users" "$r" "${out}"
  out="$(echo "${show}" | run attach cnpg-standard)"
  grep -q 'CWD=/workspace/usecases/cnpg-standard' <<< "${out}" && r=ok || r=bad; check "former 'attach' argument of an older container is ignored" "$r" "${out}"
  # Short paths: with the /usecases link (created by engine/entrypoint.sh), terminals start there and keep the logical path.
  runl() { docker run --rm -i -v "${ROOT}:/workspace:ro" --entrypoint bash "${IMG}" -c 'ln -s /workspace/usecases /usecases; exec bash /workspace/engine/terminal.sh "$@"' _ "$@" 2>&1; }
  out="$(echo "${show}" | runl)"
  grep -q 'CWD=/usecases FILE=/root/.kube/terminals/playground-main.yaml' <<< "${out}" && r=ok || r=bad; check "/usecases link: Playground terminal starts in /usecases" "$r" "${out}"
  out="$(echo "${show}" | runl cnpg-standard)"
  grep -q 'CWD=/usecases/cnpg-standard FILE=/root/.kube/terminals/playground-uc-cnpg-standard.yaml' <<< "${out}" && r=ok || r=bad; check "/usecases link: use case terminal starts in /usecases/<usecase>" "$r" "${out}"
  out="$(echo "${show}" | runl cnpg-standard 2)"
  grep -q 'CWD=/usecases/cnpg-standard FILE=/root/.kube/terminals/playground-uc-cnpg-standard-p2.yaml' <<< "${out}" && r=ok || r=bad; check "/usecases link: split panel starts in /usecases/<usecase>" "$r" "${out}"
  nav='cd ..; echo "UP1=$PWD"; cd ..; echo "UP2=$PWD"; cd /workspace; echo "WS=$PWD"; exit'
  out="$(echo "${nav}" | runl cnpg-standard)"
  grep -q 'UP1=/usecases$' <<< "${out}" && grep -q 'UP2=/$' <<< "${out}" && grep -q 'WS=/workspace$' <<< "${out}" && r=ok || r=bad; check "logical navigation: cd .. gives /usecases then /, and /workspace still works" "$r" "${out}"
  # Split view (SPEC-009): a panel has its own file, starts on the use case context, never inherits another's.
  out="$(echo "${show}" | run cnpg-standard 3)"
  { grep -q 'FILE=/root/.kube/terminals/playground-uc-cnpg-standard-p3.yaml' <<< "${out}" && grep -q '^current-context: kind-cnpg-lab-cnpg-standard-1$' <<< "${out}"; } && r=ok || r=bad; check "split panel: own kubeconfig file, use case context" "$r" "${out}"
  seed='mkdir -p /root/.kube/terminals; printf "apiVersion: v1\nkind: Config\ncurrent-context: other\n" > /root/.kube/terminals/playground-uc-cnpg-standard-p2.yaml; exec bash /workspace/engine/terminal.sh cnpg-standard 2'
  out="$(echo "${show}" | docker run --rm -i -v "${ROOT}:/workspace:ro" --entrypoint bash "${IMG}" -c "${seed}" 2>&1)"
  grep -q '^current-context: kind-cnpg-lab-cnpg-standard-1$' <<< "${out}" && r=ok || r=bad; check "split panel starts on the use case context, not a leftover one" "$r" "${out}"
  for bad in "cnpg-standard 1" "cnpg-standard 5" "cnpg-standard x"; do
    out="$(echo "${show}" | run ${bad})"; grep -q "invalid panel" <<< "${out}" && r=ok || r=bad; check "panel '${bad#* }' refused" "$r" "${out}"
  done
  out="$(echo "${show}" | run '' 2)"; grep -q "invalid panel" <<< "${out}" && r=ok || r=bad; check "panel without a use case refused" "$r" "${out}"
  out="$(echo "${show}" | run no-such-usecase)"; grep -q "unknown use case" <<< "${out}" && r=ok || r=bad; check "unknown use case is refused" "$r" "${out}"
  out="$(echo "${show}" | run '../etc')"; grep -q "invalid use case name" <<< "${out}" && r=ok || r=bad; check "invalid use case name is refused" "$r" "${out}"
else
  echo "SKIP container-side checks (Docker or the Playground image is not available)"
fi
echo; [ "${FAIL}" = 0 ] && echo "ALL TERMINAL TESTS PASSED" || echo "SOME TERMINAL TESTS FAILED"; exit "${FAIL}"
