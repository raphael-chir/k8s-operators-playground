#!/usr/bin/env bash
# Start the Playground from scratch: check prerequisites, build the image, start the container and the Web UI.
# Use cases are then started from the Web UI or with ./playground usecase start <name>.
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

./playground doctor
./playground install
./playground start

echo
echo "Playground ready!"   # the URLs (Local, and LAN when enabled) were printed by ./playground start above
echo
echo "EDB products need an EDB subscription token:"
echo "  cp .env.example .env     # then set EDB_SUBSCRIPTION_TOKEN in .env"
echo "The token is used by their operator scenarios (01_install_operators.sh) to create the"
echo "'edb-pull-secret' for docker.enterprisedb.com. .env is ignored by Git and by the Docker build."
echo "Community use cases (cnpg-standard) do not need it."
echo
echo "Optional AI Lab Assistant:"
echo "  ./playground ai-builder start"
echo "  Requires Claude Code authentication."