#!/usr/bin/env bash
# Container entrypoint: put the playground on the host's "kind" Docker network BEFORE ttyd starts.
# Joining a network later changes the container's network namespace and resets open ttyd
# WebSockets: ttyd then SIGHUPs the shell, killing a running `playground infra up`.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/infrastructure/kind/common.sh"

# Short terminal paths: /usecases -> /workspace/usecases (the files stay in the project). Idempotent; never replaces a real directory.
if [ ! -d /usecases ] || [ -L /usecases ]; then ln -sfn /workspace/usecases /usecases || log_warn "Could not create /usecases"; fi

# Never prevent the terminal from starting (e.g. Docker socket not mounted).
( ensure_kind_network ) || log_warn "Could not join the '${KIND_NETWORK}' network; Kind access will be set up on first use"

# Web UI (web/app.py) next to ttyd; its failure never prevents the terminal from starting.
if [ -f /workspace/web/app.py ]; then
  python3 -m uvicorn --app-dir /workspace/web app:app --host 0.0.0.0 --port 8080 --log-level warning &
fi

exec "$@"
