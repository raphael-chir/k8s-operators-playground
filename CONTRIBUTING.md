# Contributing

## Setup

Install Docker with Compose v2 (see [docs/installation.md](docs/installation.md)), then:

```bash
./playground doctor && ./playground install && ./playground start
```

The repository is bind-mounted into the container at `/workspace`, so edits to scripts, `web/` and `engine/shell/*` take effect without a rebuild (the Web backend needs a restart: `./playground restart`). Only the `Dockerfile` needs `./playground install` and a container recreation.

## Workflow

1. Create a branch, make a small focused change.
2. Run `tests/static.sh`, `tests/cli.sh`, `tests/engine.sh`, `tests/terminal.sh` and, if you touch a use case's scenarios or the platform charts, `tests/monitoring.sh` (`tests/scenarios.sh` currently targets an earlier scenario layout and is being reworked with the scenarios).
3. Exercise what you changed (API calls, a throwaway use case, the scenario you touched). Never test destructive commands against your own environment: use `tests/cli.sh`.
4. Update the documentation and add or update the specification in `docs/specs/` (see below).
5. Open a pull request.

## Conventions

- Bash: `set -Eeuo pipefail` in engine scripts; host-side code in `playground` stays Bash 3.2 compatible (no `mapfile`, no associative arrays). Quote variables; no `eval` of user input.
- No GNU Make. No new dependency on the host: everything runs in the container.
- No hard-coded use case names, cluster names or ports (see [CLAUDE.md](CLAUDE.md)).
- Frontend: vanilla JS, DOM built with `textContent`; colors through the CSS variables of both themes.
- Comments explain *why*; keep them accurate when behavior changes.

## Adding a use case

1. Create `usecases/<name>/` (lowercase letters, digits and `-`).
2. Add `usecase.yaml` (`title`, `description`, `infrastructure.clusters`, `infrastructure.workers_per_cluster`, and a `services` section of true/false for `cert_manager`, `minio`, `prometheus`, `grafana`; copy an existing one). The engine starts, reports and stops the use case from it (`engine/usecase-run.sh`); there are no `install.sh`, `status.sh` or `cleanup.sh`. A use case owns its clusters, named `cnpg-lab-<name>-<n>`.
3. Put scenarios in `usecases/<name>/NN_description.sh` (plus `manifests/`). A scenario sources `engine/lib/ui.sh` and `engine/usecase.sh`, calls `usecase_require_cluster`, and uses `ui_note`, `ui_pause`, `ui_command`, `ui_watch`. Use `$KUBE_CONTEXT`, never a hard-coded context.
4. Add a `README.md` for the use case (purpose, scenarios, cleanup, limitations; see `usecases/cnpg-standard/README.md`). No other file needs to change: the CLI, the Web UI, terminals, status bar and monitoring discover it. Verify with `./playground usecase list`.

## Naming

Use case: kebab-case (`cnpg-standard`). Kind cluster `cnpg-lab-<usecase>-<n>`; context `kind-<cluster>`; terminal kubeconfig file `playground-uc-<usecase>.yaml`; scenario files `NN_name.sh`.

## Tests

`tests/static.sh` (syntax of Bash/Python/JS, Compose config, help and version consistency, documentation links, no Make), `tests/cli.sh` (the CLI against a fake `docker`, covering the destructive commands) and `tests/engine.sh` (project-root resolution from any working directory, plus read-only checks of the real use case scripts when the Playground runs). `tests/scenarios.sh` runs the `cnpg-standard` scenarios against a fake `kubectl` (paths, flow, UI, context isolation; nothing is sent to a cluster). New CLI behavior needs a case in `tests/cli.sh`.

## Documentation and specifications

Update `docs/` with the change. For a new feature or a significant fix, add `docs/specs/SPEC-<id>-<name>.md` (the request preserved verbatim, what was implemented, limitations, verification) and a row in `docs/specs/README.md`. State what was actually verified; do not claim browser or platform tests that did not run.

## Pull requests

Describe the change and its verification, list the docs and specs updated, and mention anything not tested (browser, other platforms). Keep PRs small. Do not include unrelated reformatting.

## Security and secrets

Secrets live in `.env` (copy `.env.example`; ignored by Git and by the Docker build context). Never commit credentials, tokens (including EDB tokens), cloud secrets, private keys, private kubeconfigs or runtime-generated files (logs, `.env`, swap files, `__pycache__`, kubeconfig copies). The demo credentials in the Helm values (`admin` / `password` for Grafana and MinIO) are deliberate, local-only and documented; do not reuse them elsewhere. Do not print secrets in logs or reports. Mounting the Docker socket is root-equivalent on the host: keep the ports bound to `127.0.0.1`.
