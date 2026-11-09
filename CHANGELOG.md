# Changelog

Versions follow [Semantic Versioning](https://semver.org/); the single source is the [`VERSION`](VERSION) file.

## 1.0.0-rc.1 (release candidate, not tagged)

First release candidate of the CNPG Operator Playground.

### Capabilities

- One CLI, `./playground` (Bash 3.2 on the host, no GNU Make): `doctor`, `install`, `start`, `stop`, `restart`, `status`, `uninstall`, `purge`, `usecase list|start|stop|status`, low-level `infra` commands.
- One Docker Compose container with Docker CLI, Kind, kubectl, Helm, ttyd, Vim, `kubectl cnpg` (community) and `kubectl cnp` (EDB), and a FastAPI Web UI on `127.0.0.1:8080`. Kind clusters are created as siblings through the host Docker socket.
- Web UI: dynamic use case discovery, Start/Stop with live logs, one persistent terminal per use case (split view up to 4 panels), an independent Kubernetes context per terminal, status bar, Docker resource monitor, light and dark themes.
- Declarative use cases (`usecases/<name>/usecase.yaml`: clusters, workers, platform services); the engine starts, reports and stops them. Platform services: cert-manager, MinIO, Prometheus, Grafana (Helm, pinned versions), each optional per use case.
- Scenario UI (`engine/lib/ui.sh`): rounded note boxes, typed commands with a live `☸ cluster-N ➜` prompt, `NO_COLOR` support.
- Tests: `tests/static.sh`, `cli.sh` (fake docker), `engine.sh`, `terminal.sh`, `monitoring.sh` (`helm template`), `scenarios.sh` (fake kubectl; see limitations).

### Use cases

| Use case | Status |
|---|---|
| `cnpg-standard` | CloudNativePG: 7 scenarios (operators, deploy, data, backup/restore, HA, administration, upgrades) and a reset. Checked with a fake `kubectl`; not replayed end to end on a live cluster for this release |
| `pgd4k-single-group` | EDB PGD for Kubernetes 2.2.0: 8 scenarios including a Kubernetes node drain under measured SQL load. Imported from the previous project; not run in this repository and not covered by automated tests. Needs an EDB subscription token (`.env`, see `.env.example`) |
| `cnpg-distributed-topology` | Two-cluster infrastructure only. Its single scenario references a manifest that does not exist yet |

### Release stabilization (this candidate)

- Added `.env.example`; `.gitignore` keeps it tracked while ignoring `.env`.
- Added the missing use case READMEs; corrected documentation that named a wrong token variable and location (`EDB_SUBSCRIPTION_TOKEN` in the root `.env`).
- Image: EDB `kubectl cnp` plugin 1.30.1 and the `ll` alias.

### Known limitations

- **Scenarios are out of scope for this release candidate**: they were not executed, simulated or validated in the review, and `tests/scenarios.sh` still targets an earlier scenario layout (it fails against the current scripts) and will be updated together with the scenarios.
- Without a `.env` file, the PGD4K operators scenario fails with Bash's own `No such file` error instead of a hint; copy `.env.example` first.

- Only macOS arm64 (Docker Desktop) was exercised; amd64 and Linux/Windows are expected to work, not validated. The amd64 download of the EDB plugin is untested.
- No authentication on the Web UI or terminal; the Docker socket is mounted (root-equivalent on the host): local use only, ports bound to `127.0.0.1`.
- Browser behavior was not checked by a person in every browser (see the checklist in `docs/release-checklist.md`).
- No license has been chosen; it must be decided before publication.
- The repository was not a Git repository when this was prepared, so tracked-file and history secret scans could not run; run one before publishing.

### Compatibility

Docker with Compose v2; about 8 GB of memory for Docker (12 GB for two clusters); network access to pull images and Helm charts.
