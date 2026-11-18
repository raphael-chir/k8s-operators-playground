#!/usr/bin/env bash
# Web UI tests (AI Builder panel): Node, no browser, no network. The panel script runs against a fake DOM and a scripted
# fetch; nothing starts Docker, Claude Code, Kind, Kubernetes or Helm. Skipped when Node is not installed. Run: tests/ui.sh
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
command -v node >/dev/null 2>&1 || { echo "SKIP UI tests (node not installed)"; exit 0; }
node --check web/static/app.js && node --check web/static/ai-markdown.js && node --check web/static/ai-builder.js || { echo "FAIL javascript syntax"; exit 1; }
node tests/ai_builder_ui_test.js
