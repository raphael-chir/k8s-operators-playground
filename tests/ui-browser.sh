#!/usr/bin/env bash
# Real-browser check of the AI Lab Assistant panel layout: the REAL index.html and stylesheets in headless Chrome with a
# stand-in terminal iframe, stubbed API routes and a scripted driver (tests/ui_browser_page.py). It measures what a fake DOM cannot:
# the docked layout, that the workspace is resized and not covered, that the terminal's own viewport shrinks and grows with its column (what xterm.js refits to), the drag and
# the limits, scrolling, the sticky composer, Markdown/diff rendering, the narrow full-screen panel and both themes.
# Needs Chrome or Chromium (skipped otherwise). Starts no container and calls neither Docker, Kubernetes nor Claude. Run: tests/ui-browser.sh
set -u
cd "$(dirname "$0")/.."
CHROME="${CHROME_BIN:-}"
if [ -z "${CHROME}" ]; then
  for c in "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" "/Applications/Chromium.app/Contents/MacOS/Chromium" google-chrome google-chrome-stable chromium chromium-browser; do
    if [ -x "${c}" ] || command -v "${c}" >/dev/null 2>&1; then CHROME="${c}"; break; fi
  done
fi
if [ -z "${CHROME}" ]; then echo "SKIP real-browser layout checks (no Chrome or Chromium found; set CHROME_BIN)"; exit 0; fi
T="$(mktemp -d)"; trap 'rm -rf "${T}"' EXIT
rc=0

run_case() {   # name, mode, size, [dark]
  local name="$1" mode="$2" size="$3" dark="${4:-}"
  python3 -I tests/ui_browser_page.py "${T}/${name}.html" "${mode}" ${dark} || { echo "FAIL ${name}: page generation"; rc=1; return; }
  "${CHROME}" --headless=new --disable-gpu --no-sandbox --hide-scrollbars --user-data-dir="${T}/profile-${name}" --window-size="${size}" \
    --virtual-time-budget=20000 --dump-dom "file://${T}/${name}.html" > "${T}/${name}.dom" 2> "${T}/${name}.err"
  python3 -I - "${T}/${name}.dom" "${name}" <<'PY' || rc=1
import html, json, re, sys
dom = open(sys.argv[1], encoding="utf-8", errors="replace").read()
m = re.search(r'<pre id="out"[^>]*>(.*?)</pre>', dom, re.S)
if not m or not m.group(1).strip():
    print(f"FAIL {sys.argv[2]}: the page produced no result (Chrome did not run the driver)"); sys.exit(1)
rows, bad = json.loads(html.unescape(m.group(1))), 0
for r in rows:
    print(("PASS " if r["ok"] else "FAIL ") + f"[{sys.argv[2]}] " + r["name"] + ("" if r["ok"] else f"   [{r['detail']}]"))
    bad += 0 if r["ok"] else 1
sys.exit(1 if bad or not rows else 0)
PY
}

run_case wide-light wide 1400,900
run_case saved-width saved 1400,900
run_case wide-dark wide 1400,900 dark
run_case narrow narrow 700,800
[ "${rc}" = 0 ] && echo "ALL BROWSER LAYOUT CHECKS PASSED" || echo "SOME BROWSER LAYOUT CHECKS FAILED"
exit "${rc}"
