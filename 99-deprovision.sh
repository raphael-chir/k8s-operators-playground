#!/usr/bin/env bash
# Full cleanup: deletes the Playground's Kind clusters, its Docker volumes, container and image.
# Only resources owned by the Playground are removed (see docs/cli.md). It asks for confirmation;
# preview first with: ./playground purge --dry-run
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

./playground purge "$@"
