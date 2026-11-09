# CLAUDE.md: operating guide for Claude Code sessions

## Purpose

CNPG Operator Playground: a local, single-user environment to demonstrate and test CloudNativePG. One Docker Compose container (Docker CLI, Kind, kubectl, Helm, ttyd, Vim, a FastAPI Web UI) creates **sibling** Kind clusters through the host Docker socket. Target version in `VERSION`.

History of every specification and what was implemented: **`docs/specs/README.md`**. Do not copy it here; read it before changing a feature.

## Layout

```
playground                      the one CLI (Bash 3.2 on the host). No GNU Make anywhere.
VERSION                         single source of the version
compose.yaml, Dockerfile        one service; the repo is bind-mounted at /workspace
engine/                         container-side engine: lib/{logger,ui}.sh, usecase*.sh, terminal.sh,
                                infrastructure/kind/*, shell/{bashrc,vimrc}
platform/                       Helm installers: monitoring, object-storage, cert-manager, operators
usecases/<name>/                usecase.yaml (incl. services), NN_*.sh scenarios at the use case root, manifests/, README.md: discovered dynamically; start/status/stop are the engine's (engine/usecase-run.sh)
web/                            FastAPI backend (app.py) + vanilla JS frontend (static/)
tests/                          cli.sh (fake-docker CLI tests), engine.sh (project-root resolution), scenarios.sh (cnpg-standard scenarios, fake kubectl), static.sh (syntax, links, version, no Make)
docs/                           installation, cli, user-guide, architecture, release-checklist, specs/
```

## Conventions that must hold

- **One CLI.** Lifecycle goes through `./playground`; the web backend calls it too. Do not reintroduce Make, and do not duplicate lifecycle logic in the CLI: it validates and calls the existing scripts.
- **Host vs container.** Host code (`playground` host commands) must stay Bash 3.2 compatible: no `mapfile`/`readarray`, no associative arrays, no `set -u`. Engine scripts run only inside the container (Bash 5) and may use `mapfile`. `infra`/`usecase` commands route into the container (`docker exec`); the CLI detects its context (`/.dockerenv` and root `/workspace`), so there are no dispatch loops. Host-only commands refuse to run in the container.
- **Project root.** Engine scripts find it by walking up to the directory that holds `playground` and `engine/` (`engine/usecase.sh`); never use a file that may be removed as a marker, and keep it independent of the working directory (`tests/engine.sh`).
- **Dynamic discovery.** A use case is a directory under `usecases/` with a valid `usecase.yaml` (title, description, `infrastructure.clusters`, `infrastructure.workers_per_cluster`, optional `services` booleans: cert_manager, minio, prometheus, grafana, missing = false; the id is the directory name; no per-use-case lifecycle scripts, SPEC-012). Never hard-code use case names, cluster names or host ports; names derive from the directory (`cnpg-lab-<usecase>-<n>`, context `kind-<cluster>`, terminal file `playground-uc-<usecase>.yaml`). Grafana/MinIO host ports are read from Docker.
- **Kubernetes context isolation.** Each terminal has `~/.kube/terminals/<terminal>.yaml` (only `current-context`; split panels 2-4 of a use case tab use `playground-uc-<usecase>-p<N>.yaml`, SPEC-009) and `KUBECONFIG=<that file>:~/.kube/config`. Lifecycle commands and the backend use the shared kubeconfig (the CLI unsets `KUBECONFIG`). Never change the shared current-context from a feature or a test.
- **Scenario UI.** `engine/lib/ui.sh` is the reference scenario presentation (SPEC-013: rounded `ui_note` boxes, `◆` instructions, one-line `☸ cluster-N ➜ command` prompt, `↳  Enter to continue`, ANSI 256 palette); do not restyle it further. The Bash prompt lives only in `engine/shell/bashrc`. The Web terminal is ttyd + Bash with no session manager (SPEC-007.1.7): do not reintroduce tmux; `engine/terminal.sh` sets `LANG=C.UTF-8`.
- **Web UI.** Frontend builds DOM with `textContent` (never `innerHTML` with backend values); read-only endpoints stay read-only; themes are CSS variables.
- **Ownership-based cleanup.** `purge` deletes only Kind clusters with Kind's label and the playground name pattern, and Docker resources with the Compose project label. Never use `docker system prune` or `docker volume prune`.

## Safety rules for sessions

- The user's running Kind clusters, terminals, kubeconfigs, volumes, MinIO buckets and PostgreSQL data are not yours to stop, delete, recreate or reset without explicit approval. Recreating the Playground container ends all open terminals (one Bash each): ask first.
- Test destructive paths (`stop`, `restart`, `uninstall`, `purge`) with `tests/cli.sh` (fake docker), never against the live environment.
- The sibling repository `../cnpg-operator-playground-local` is a read-only reference.
- Do not print or commit secrets. Do not tag, push or release without being asked.

## Testing

Run before finishing a change: `tests/static.sh`, `tests/cli.sh`, `tests/engine.sh`, `tests/monitoring.sh` (helm template, needs network) and `tests/scenarios.sh` (currently out of date with the scenarios: being reworked with them; do not rely on it); for web/engine changes also exercise the API (`/api/usecases`, `/api/status`, `/api/docker/resources`, `/api/meta`) and, when possible, a throwaway use case. Do not claim browser behavior was tested unless it was; list manual checks instead.

## Documentation rule

Every change updates the docs that describe it: `README.md` (quick start only), `docs/user-guide.md`, `docs/cli.md`, `docs/architecture.md`, the affected use case README, and **a specification document in `docs/specs/`** (new `SPEC-<id>-<name>.md` with the original request preserved verbatim, plus a row in `docs/specs/README.md`). Statuses must reflect what is actually implemented and verified.
