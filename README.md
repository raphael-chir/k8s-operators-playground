[![Generic badge](https://img.shields.io/badge/Version-1.0.0--rc.1-blue.svg)](https://shields.io/)
[![Maintenance](https://img.shields.io/badge/Maintained%3F-yes-green.svg)](https://GitHub.com/Naereen/StrapDown.js/graphs/commit-activity)
![Maintainer](https://img.shields.io/badge/maintainer-raphael.chir@enterprisedb.com-blue)
# CNPG Operator Playground

A local playground for [CloudNativePG](https://cloudnative-pg.io/) on Kubernetes. One container holds the tooling (Docker CLI, Kind, kubectl, Helm, Vim); a Web UI at <http://localhost:8080> starts and stops the use cases and gives each one a persistent terminal. Version: see [`VERSION`](VERSION) (`1.0.0-rc.1` is a release candidate).

## Overview

Each **use case** owns its own Kind clusters, with Prometheus/Grafana and MinIO installed (PostgreSQL operators are installed by the scenarios, not by Start), plus interactive scenarios to follow in the terminal.

## Features

- Web UI: use case discovery, Start/Stop with live colored logs and an elapsed-time indicator
- One Web terminal per use case (ttyd + Bash; a browser refresh starts a new shell) and a general Playground terminal
- Independent Kubernetes context per terminal; `kubectl`, `k` and `helm` always agree
- Status bar with the cluster, context, Grafana and MinIO links; Docker resource monitor
- EDB light theme and a dark theme; Vim with YAML/Bash/JSON highlighting
- Three use cases: [`cnpg-standard`](usecases/cnpg-standard/README.md) (CloudNativePG, one cluster, backups to MinIO), [`cnpg-distributed-topology`](usecases/cnpg-distributed-topology/README.md) (two clusters, infrastructure only for now) and [`pgd4k-single-group`](usecases/pgd4k-single-group/README.md) (EDB PGD for Kubernetes, needs an EDB subscription token in `.env`)
- One command-line interface, `./playground`; no GNU Make

## Supported platforms

| Platform | Architecture | Runtime | Status |
|---|---|---|---|
| macOS (Apple Silicon) | arm64 | Docker Desktop | developed and tested here |
| macOS (Intel) | amd64 | Docker Desktop | expected to work, not validated |
| Ubuntu 24.04+ | amd64 | Docker Engine + Compose v2 | expected to work, not validated |
| Windows 11 | amd64 | WSL2 (Ubuntu) + Docker Desktop | expected to work, not validated |

Every image used supports both amd64 and arm64 ([details](docs/installation.md#image-architecture-support)). Validation per platform is tracked in [docs/release-checklist.md](docs/release-checklist.md).

## Prerequisites

Docker (Docker Desktop, or Docker Engine) with Docker Compose v2, about 8 GB of memory for Docker (12 GB for two clusters) and Git. Nothing else: Kind, kubectl, Helm, Python and Make are **not** needed on your machine. Details: [docs/installation.md](docs/installation.md).

## Quick start

```bash
git clone <repository-url>
cd cnpg-operator-playground
./playground doctor
./playground install
./playground start
```

Then open <http://localhost:8080>.

## First use case

1. Open the Web UI at <http://localhost:8080>.
2. Select `cnpg-standard` in the sidebar.
3. Click **Start**. The logs open below; the first start takes several minutes (images are pulled).
4. When it is running, its terminal tab appears. Open it: it starts in the use case's directory, where its scenarios are.
5. Run the scenarios in order, `./01_install_operators.sh` to `./07_postgresql_upgrades.sh` (Enter continues each step; `./99_reset_lab.sh` cleans up the lab so it can be replayed). Each use case has a README with its scenarios.
6. Use the status bar links to open **Grafana** (no login needed) and **MinIO** (`admin` / `password`).
7. Click **Stop** when done: it deletes the use case's clusters.

## Stop and uninstall

```bash
./playground stop               # stop the Playground; Kind clusters keep running
./playground uninstall          # remove the Playground container and image (asks first)
./playground purge --dry-run    # preview a full cleanup (clusters, volumes); nothing is deleted
```

`./playground purge` deletes only what the Playground owns, after an explicit confirmation. See [docs/cli.md](docs/cli.md).

## Documentation

| | |
|---|---|
| [docs/installation.md](docs/installation.md) | Prerequisites per platform, resources, troubleshooting |
| [docs/cli.md](docs/cli.md) | Every `./playground` command, exit codes, safety rules |
| [docs/user-guide.md](docs/user-guide.md) | Use cases, terminals, status bar, ports, known limitations |
| [docs/architecture.md](docs/architecture.md) | How it works |
| [docs/specs/README.md](docs/specs/README.md) | History of the specifications |
| [docs/release-checklist.md](docs/release-checklist.md) | Release readiness |

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Operational notes for AI-assisted sessions are in [CLAUDE.md](CLAUDE.md).

## Supported operators

CloudNativePG community (with the Barman Cloud plugin) and EDB Postgres Distributed for Kubernetes 2.2.0 (PGD4K, with the EDB PG4K operator). Operators are installed by the scenarios, not by Start. The image also ships `kubectl cnpg` (community) and `kubectl cnp` (EDB).

## EDB token

Only `pgd4k-single-group` needs it: `cp .env.example .env` and set `EDB_SUBSCRIPTION_TOKEN`. `.env` is ignored by Git and is not copied into the image.

## Release candidate status and known limitations

`1.0.0-rc.1` is a release candidate. See [CHANGELOG.md](CHANGELOG.md) and [docs/release-checklist.md](docs/release-checklist.md). In short:

- Only macOS arm64 was exercised; other platforms are expected to work, not validated.
- The scenarios are not validated for this release candidate (they will be tested and improved separately; `tests/scenarios.sh` is out of date), and the Web UI was not checked by a person in every browser.
- `cnpg-distributed-topology` has no working scenario yet; `pgd4k-single-group` scenarios are imported and not covered by automated tests.
- The Web UI and terminal have no authentication and mount the Docker socket: local use only.

## License

No license has been defined for this repository yet; this is a release blocker (see the checklist).
