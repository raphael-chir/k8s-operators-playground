#!/usr/bin/env bash
# Static checks: syntax, Compose, CLI help/version, version single-sourcing, documentation links, no Make.
# Non-destructive (reads files; `docker compose config` only validates). Bash 3.2 compatible. Run: tests/static.sh
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
FAIL=0
check() { if [ "$2" = ok ]; then echo "PASS $1"; else echo "FAIL $1   [$3]"; FAIL=1; fi; }
V="$(cat VERSION)"

# --- syntax --------------------------------------------------------------------------------------------------
bad=""; n=0
for f in playground tests/*.sh $(find engine usecases -name '*.sh'); do n=$((n+1)); bash -n "$f" 2>/dev/null || bad="${bad} $f"; done
[ -z "${bad}" ] && r=ok || r=bad; check "bash -n on ${n} scripts (with $(bash --version | head -1 | sed 's/.*version \([0-9.]*\).*/bash \1/'))" "$r" "${bad}"
python3 -c "import ast,sys; ast.parse(open('web/app.py').read())" 2>/dev/null && r=ok || r=bad; check "python syntax (web/app.py)" "$r"
for f in ai-builder/*.py tests/ai_builder_test.py tests/ai_builder_compose_test.py tests/ai_builder_proxy_test.py tests/ai_builder_auth_test.py tests/ai_builder_conversation_test.py tests/ai_builder_editing_test.py web/ai_builder_proxy.py web/operations.py tests/operations_test.py; do python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$f" 2>/dev/null && r=ok || r=bad; check "python syntax (${f})" "$r"; done
if command -v node >/dev/null 2>&1; then node --check web/static/app.js 2>/dev/null && r=ok || r=bad; check "javascript syntax (web/static/app.js)" "$r"; node --check web/static/ai-builder.js 2>/dev/null && r=ok || r=bad; check "javascript syntax (web/static/ai-builder.js)" "$r"; node --check web/static/ai-markdown.js 2>/dev/null && r=ok || r=bad; check "javascript syntax (web/static/ai-markdown.js)" "$r"; else echo "SKIP javascript syntax (node not installed)"; fi
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then docker compose config -q 2>/dev/null && r=ok || r=bad; check "docker compose config is valid" "$r"; else echo "SKIP compose config (docker not available)"; fi
grep -q '^name: cnpg-operator-playground' compose.yaml && r=ok || r=bad; check "compose project name is pinned (ownership label for purge)" "$r"
[ -f .dockerignore ] && r=ok || r=bad; check ".dockerignore exists" "$r"

# --- host Bash 3.2 compatibility of the CLI (the engine runs in the container and may use Bash 4+) ------------
code="$(grep -vE '^[[:space:]]*#' playground)"   # comments may name the forbidden constructs
! grep -nE '\b(mapfile|readarray)\b|declare -A|local -A|\$\{[a-zA-Z_]+(\^\^|,,)\}|^\s*set -[a-zA-Z]*u' <<< "${code}" >/dev/null && r=ok || r=bad; check "playground has no Bash 4+ constructs and no set -u" "$r"

# --- CLI and version -----------------------------------------------------------------------------------------
[ "$(./playground version)" = "CNPG Operator Playground v${V}" ] && r=ok || r=bad; check "'./playground version' matches VERSION (${V})" "$r"
./playground --help | head -1 | grep -q "v${V}" && r=ok || r=bad; check "'--help' shows the same version" "$r"
for c in doctor install start stop restart status uninstall purge "infra up" "infra down" "infra info" "infra status" "usecase list" "usecase start" "usecase stop" "usecase status" version help; do ./playground --help | grep -q "  ${c}" || miss="${miss} ${c}"; done
[ -z "${miss}" ] && r=ok || r=bad; check "'--help' documents every command" "$r" "missing:${miss}"
[ "${V}" = "$(tr -d ' \n' < VERSION)" ] && r=ok || r=bad; check "VERSION is a single line" "$r"
# the version string must not be duplicated in code (docs may mention it)
dup="$(grep -rIlF "${V}" playground web engine platform usecases Dockerfile compose.yaml tests 2>/dev/null | grep -v '^tests/' )"
[ -z "${dup}" ] && r=ok || r=bad; check "version not hard-coded in code" "$r" "${dup}"
grep -q 'VERSION' web/app.py && r=ok || r=bad; check "backend reads the VERSION file" "$r"
grep -q '/api/meta' web/static/app.js && ! grep -q "v${V}" web/static/app.js && r=ok || r=bad; check "frontend gets the version from /api/meta" "$r"

# --- no Make ----------------------------------------------------------------------------------------------------
[ ! -e Makefile ] && [ ! -e makefile ] && [ ! -e GNUmakefile ] && r=ok || r=bad; check "no Makefile" "$r"
hits="$(grep -rInE '(^|[^a-zA-Z])make +(-C|-n|usecase-|infra-|platform-|help|install|all)|"make"|'"'make'"'|apt-get install[^\\]*\<make\>|^[[:space:]]+make[[:space:]]+[a-z]' playground web engine usecases Dockerfile compose.yaml README.md CONTRIBUTING.md 2>/dev/null | grep -v 'make them usable\|make the lister\|make sure\|make it \|make naming\|make future' )"
[ -z "${hits}" ] && r=ok || r=bad; check "no operational dependency on Make (code, Dockerfile, README)" "$r" "$(echo "${hits}" | head -3)"
grep -qE 'bash .*\bmake\b|\bmake\b.*git curl' Dockerfile && r=bad || r=ok; check "Dockerfile does not install make" "$r"

# --- documentation links --------------------------------------------------------------------------------------
broken=""
for f in README.md CONTRIBUTING.md; do
  d="$(dirname "$f")"
  for l in $(grep -oE '\]\([^)]+\)' "$f" | sed 's/^](//; s/)$//' | grep -vE '^(https?:|mailto:|#)' | sed 's/#.*//'); do
    [ -z "$l" ] && continue
    [ -e "${d}/${l}" ] || broken="${broken} ${f}->${l}"
  done
done
[ -z "${broken}" ] && r=ok || r=bad; check "relative links in the documentation resolve" "$r" "${broken}"
for f in README.md CONTRIBUTING.md; do [ -s "$f" ] || nof="${nof} $f"; done
[ -z "${nof}" ] && r=ok || r=bad; check "required documents exist" "$r" "${nof}"
echo; [ "${FAIL}" = 0 ] && echo "ALL STATIC CHECKS PASSED" || echo "SOME STATIC CHECKS FAILED"; exit "${FAIL}"
