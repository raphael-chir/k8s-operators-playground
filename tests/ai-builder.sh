#!/usr/bin/env bash
# AI Builder tests: Python unittest with mocks. The real Claude Code CLI is never started; no Docker, Kind, kubectl,
# Helm or generated scenario is run. Run: tests/ai-builder.sh
#
# Isolation: every test uses a temporary state directory (AI_BUILDER_STATE_DIR) and a spare port. The repository's real
# .ai-builder/ (jobs, drafts, PID, log) is never written, stopped or deleted; a fingerprint taken before and after
# proves it. Nothing in this file removes .ai-builder.
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
command -v python3 >/dev/null 2>&1 || { echo "SKIP python3 not installed"; exit 0; }
T="$(mktemp -d)"; trap 'rm -rf "${T}"' EXIT           # only this temporary directory is ever removed
rc=0; chk() { if [ "$2" = ok ]; then echo "PASS $1"; else echo "FAIL $1"; rc=1; fi; }
# Fingerprint of the real state: names, sizes, contents of jobs/ and drafts/ (the server log and PID change by design).
fp() { [ -d .ai-builder ] || { echo "none"; return; }; find .ai-builder/jobs .ai-builder/drafts -type f 2>/dev/null | LC_ALL=C sort | while read -r f; do shasum "$f"; done | shasum; }
BEFORE="$(fp)"
real_pid=""; [ -r .ai-builder/server.pid ] && real_pid="$(cat .ai-builder/server.pid)"

export AI_BUILDER_STATE_DIR="${T}/state" PYTHONDONTWRITEBYTECODE=1
python3 -I tests/ai_builder_test.py 2>&1 | tail -40; [ "${PIPESTATUS[0]}" = 0 ] || rc=1
# Browser sign-in (ai-builder/auth.py) with a FAKE claude script in a PTY: no real login, logout or generation
python3 -I -W error::ResourceWarning tests/ai_builder_auth_test.py 2>&1 | tail -8; [ "${PIPESTATUS[0]}" = 0 ] || rc=1
# AI Lab Assistant conversations (SPEC-022): scripted runner, no Claude call
python3 -I -W error::ResourceWarning tests/ai_builder_conversation_test.py 2>&1 | tail -8; [ "${PIPESTATUS[0]}" = 0 ] || rc=1
# Conversational Lab editing (SPEC-023): working copy, publisher service, permissions, review/undo/reset, conflicts, publication
python3 -I -W error::ResourceWarning tests/ai_builder_editing_test.py 2>&1 | tail -8; [ "${PIPESTATUS[0]}" = 0 ] || rc=1
# Playground -> AI Builder proxy (web/ai_builder_proxy.py) against a fake upstream server on 127.0.0.1
python3 -I -W error::ResourceWarning tests/ai_builder_proxy_test.py 2>&1 | tail -8; [ "${PIPESTATUS[0]}" = 0 ] || rc=1

# Host-mode CLI lifecycle (the explicit `ai-builder host ...` fallback; container mode is covered by tests/cli.sh with a fake docker) on a free port and a temporary state. `python3` stands in for the claude binary, which is never run.
PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
export AI_BUILDER_PORT="${PORT}" AI_BUILDER_CLAUDE=python3
S="${AI_BUILDER_STATE_DIR}"; mkdir -p "${S}/jobs" "${S}/drafts/20260101-000000-abcdef/demo"
echo hello > "${S}/drafts/20260101-000000-abcdef/demo/usecase.yaml"
cat > "${S}/jobs/20260101-000000-abcdef.json" <<JSON
{"job_id": "20260101-000000-abcdef", "name": "demo", "status": "completed", "phase": "done", "files": ["usecase.yaml"],
 "validation": {"passed": true, "errors": []}, "validated": true, "review": {"state": "pending"}, "published": false, "attempts": [], "error": null}
JSON
status_of() { curl -fsS -m 3 "http://127.0.0.1:${PORT}/status/20260101-000000-abcdef" 2>/dev/null | grep -o '"status": "[a-z]*"'; }
./playground ai-builder host start >/dev/null 2>&1 && ./playground ai-builder host start 2>&1 | grep -q "already running" && chk "ai-builder start (no duplicate)" ok || chk "ai-builder start (no duplicate)" bad
curl -fsS -m 3 "http://127.0.0.1:${PORT}/health" 2>/dev/null | grep -q '"status": "ok"' && chk "health answers on 127.0.0.1" ok || chk "health answers on 127.0.0.1" bad
./playground ai-builder host status >/dev/null 2>&1 && chk "ai-builder status" ok || chk "ai-builder status" bad
[ "$(status_of)" = '"status": "completed"' ] && chk "a job is served by the running service" ok || chk "a job is served by the running service" bad
./playground ai-builder host stop >/dev/null 2>&1; ./playground ai-builder host status >/dev/null 2>&1 && chk "ai-builder stop" bad || chk "ai-builder stop" ok
./playground ai-builder host start >/dev/null 2>&1
[ "$(status_of)" = '"status": "completed"' ] && [ -f "${S}/drafts/20260101-000000-abcdef/demo/usecase.yaml" ] && chk "job and draft persist across a service restart" ok || chk "job and draft persist across a service restart" bad
./playground ai-builder host stop >/dev/null 2>&1

# Container definition, from the rendered Compose model (`docker compose config` only: nothing is built or started).
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  printf '%064d' 0 > "${T}/token"
  export AI_BUILDER_TOKEN_FILE="${T}/token"
  docker compose --profile ai-builder config --format json > "${T}/full.json" 2>"${T}/full.err" && docker compose config --format json > "${T}/plain.json" 2>>"${T}/full.err" \
    && python3 -I tests/ai_builder_compose_test.py "${T}/full.json" "${T}/plain.json" || { rc=1; head -5 "${T}/full.err" 2>/dev/null; }
else
  echo "SKIP compose model checks (docker compose not available)"
fi

# Regression: the real state and the production service are untouched
[ "$(fp)" = "${BEFORE}" ] && chk "real .ai-builder jobs and drafts unchanged by the test suite" ok || chk "real .ai-builder jobs and drafts unchanged by the test suite" bad
[ -z "${real_pid}" ] || { [ "$(cat .ai-builder/server.pid 2>/dev/null)" = "${real_pid}" ] && kill -0 "${real_pid}" 2>/dev/null; } && chk "production service PID file and process unaffected" ok || chk "production service PID file and process unaffected" bad
! grep -nE 'rm +-[a-z]*r[a-z]* +[^#]*\.ai-builder' "$0" | grep -v '^\s*[0-9]*:\s*#' | grep -vE '^[0-9]+:#' >/dev/null && chk "no command in this script removes .ai-builder" ok || chk "no command in this script removes .ai-builder" bad
[ "${rc}" = 0 ] && echo "ALL AI BUILDER TESTS PASSED" || echo "SOME AI BUILDER TESTS FAILED"; exit "${rc}"
