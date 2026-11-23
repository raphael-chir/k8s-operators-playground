#!/usr/bin/env bash
# Start the Playground from scratch: check prerequisites, build the image, start the container and the Web UI.
# Use cases are then started from the Web UI or with ./playground usecase start <name>.
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source engine/lib/logger.sh      # the same "[HH:MM:SS] [LEVEL]" style as the CLI and the engine

# install runs the prerequisite and host resource checks itself (compact), once. The environment only removes repetition inside this wrapper
# (the "Next:" hint, the banner and the bind-address warning, already shown by install); each command still prints it when run on its own.
PLAYGROUND_NO_HINT=1 ./playground install
PLAYGROUND_BANNER_DONE=1 PLAYGROUND_BIND_WARNED=1 ./playground start

log_success "Playground ready!"
log_section "Next steps"
log_info "EDB products need an EDB subscription token: cp .env.example .env, then set EDB_SUBSCRIPTION_TOKEN in .env"
log_info "It is used by their operator scenarios (01_install_operators.sh) to create the 'edb-pull-secret' for docker.enterprisedb.com."
log_info ".env is ignored by Git and by the Docker build. Community use cases (cnpg-standard) do not need it."
log_info "Optional AI Lab Assistant (requires Claude Code authentication): ./playground ai-builder start"
./playground doctor --recommendations     # last: the host resource recommendations, only when there is something to act on
