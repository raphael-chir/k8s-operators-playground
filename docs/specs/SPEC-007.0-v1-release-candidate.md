# SPEC-007.0 — V1 Release Candidate Preparation

| | |
|---|---|
| Status | Implemented; release candidate prepared; one regression corrected (see Later corrections). Platform validation (macOS amd64, Ubuntu, Windows/WSL2), the first live use case start and the license decision are open |
| Document type | Original specification, preserved verbatim |
| Source | Claude Code session transcript (project history), user message 2026-11-05T13:41:34.066Z UTC |
| Original specification | Available (see the last section) |
| Target version | `1.0.0-rc.1` (file `VERSION`) |

## Summary

Prepare the first release candidate: replace GNU Make with one Bash CLI (`./playground`), add install/start/stop/uninstall/purge lifecycle commands on top of Docker Compose, centralize the version, document installation and contribution, and record release readiness.

## Implemented behavior

- **CLI** (`playground`, Bash 3.2 compatible): host commands `doctor`, `install`, `start`, `stop`, `restart`, `status`, `uninstall`, `purge`, `version`, `help`; container commands `infra up|platform-up|down|info|status` and `usecase list|start|stop|status`, which the CLI routes into the running container with `docker exec` from the host. Context is detected from `/.dockerenv` and the project root (`/workspace`), so there is no dispatch loop. The macOS failure `mapfile: command not found` (engine scripts run on the host) cannot recur: engine scripts only run in the container.
- **Make removed.** All nine Make targets are covered (`help` is `--help`; `platform-up` is `infra platform-up`; `infra-test-network` named in the request never existed and is not offered). Equivalence was checked case by case before the Makefile was deleted: identical output and effect for status, down and info paths; the CLI uses CLI-style argument messages and propagates the engine's exit code (1) where Make reported 2 for every failure. The web backend now launches `./playground usecase start|stop <name> [--force]`; the `make` package was removed from the image; hint messages in the scripts and READMEs were migrated.
- **Lifecycle safety:** `stop` is `docker compose stop` (clusters keep running; stated explicitly); `restart` warns and asks when terminal sessions exist; `uninstall` removes the container, network and built image and keeps clusters and volumes; `purge --dry-run` previews and `purge` requires typing `purge` (or `--yes`) and deletes only Kind clusters (Kind label **and** playground name pattern) and Compose-labelled volumes, never pruning anything.
- **Doctor:** read-only checks for OS, architecture, Docker, Compose v2, daemon, memory and CPUs, socket, ports 8080/7681 (recognizing the Playground's own), WSL2 specifics (WSL1, repository on `/mnt/c`, Docker Desktop integration), Git.
- **Version:** `VERSION` (`1.0.0-rc.1`) is the single source: read by the CLI, served by the backend at `GET /api/meta`, shown in the header next to the title (small, theme-aware).
- **Repository:** `compose.yaml` pins `name: cnpg-operator-playground`; `.dockerignore` keeps the build context empty; `.gitignore` extended earlier.
- **Documentation:** concise `README.md`; `docs/installation.md` (platforms, resources, troubleshooting, image architecture matrix), `docs/cli.md`, `docs/user-guide.md` (the former detailed README), updated `docs/architecture.md`, `CLAUDE.md`, `CONTRIBUTING.md`, `docs/release-checklist.md`.
- **Tests:** `tests/engine.sh` (project-root resolution, added by Correction 1), `tests/static.sh` (syntax with the host Bash 3.2, Compose, help/version, no hard-coded version, no Make, links) and `tests/cli.sh` (the CLI against a fake `docker`, including stop, restart, uninstall and purge).
- **Image audit:** all 18 images installed by the charts, the CNPG manifest and the Playground (Debian, Kind node, PostgreSQL, CNPG, Barman plugin, Grafana, Prometheus stack, MinIO and client, cert-manager) publish linux/amd64 and linux/arm64. No image was replaced.

## Implementation

- Created: `playground`, `VERSION`, `.dockerignore`, `tests/cli.sh`, `tests/static.sh`, `CLAUDE.md`, `CONTRIBUTING.md`, `docs/installation.md`, `docs/cli.md`, `docs/user-guide.md`, `docs/release-checklist.md`, this document.
- Modified: `web/app.py` (CLI launch, `/api/meta`), `web/static/{index.html,style.css,app.js}` (version), `compose.yaml`, `Dockerfile` (no `make`), `engine/shell/bashrc` (`playground` function), hint messages and header comments in `engine/**`, `platform/common.sh`, `usecases/**` (comments and messages only; no scenario logic), `README.md`, `docs/architecture.md`, `docs/specs/README.md`.
- Removed: `Makefile`.

## Later corrections and follow-ups

### Correction 1: use cases could not start (project root marker)

- **Symptom:** starting either use case from the Web UI (and from the CLI) failed with `Cannot locate the project root from /workspace/usecases/<name>`.
- **Root cause:** `engine/usecase.sh` finds the project root by walking up from the use case directory until it sees the `Makefile` and `engine/`. Deleting the Makefile removed the marker, so every use case script (`install.sh`, `status.sh`, `cleanup.sh`) and every scenario failed at the first line. It had nothing to do with the working directory or with how `web/app.py` calls the CLI: the CLI resolves its own root from its file path and was correct; the marker lookup is inside the engine. The Makefile equivalence check had been run before the Makefile was deleted, and the checks run afterwards did not source `engine/usecase.sh`, so nothing caught it.
- **Fix (minimal):** the marker is now the `playground` CLI file (`engine/usecase.sh`); stale comments that still named the Makefile (`engine/usecase-list.sh`, `web/app.py`, `web/static/app.js`, `playground`) were corrected. No scenario and no lifecycle logic changed; host/container routing is unchanged.
- **Regression tests (`tests/engine.sh`):** the real `engine/usecase.sh` sourced from a temporary tree from `/`, the tree root, `usecases/`, the use case directory, `/tmp` and the repository, plus a relative invocation; a control run proves a missing marker reproduces the original error; the marker must exist in the repository and must not be the Makefile. With the Playground running: the real `status.sh` of each use case and `playground usecase status <name>` from `/`, `/tmp`, `/workspace`, `/workspace/usecases/<name>` and its `scenarios/`, and each scenario's root resolution when the use case has no cluster (read-only). `tests/static.sh` and `tests/cli.sh` still pass.
- **Verified without starting clusters:** a throwaway use case run through the Web backend (start and stop) and through the CLI from three directories resolved `root=/workspace` and exercised the real `usecase_delete`. Starting the real use cases was not done: it creates clusters and needs the project owner's approval.

## Verification

- macOS arm64 (Docker Desktop, Bash 3.2.57): `doctor`, `install` (image built without `make`), `start` (idempotent), `restart`, `status`, `version`, `--help`, `purge --dry-run`, `infra info`, `usecase list`, routing, error paths and exit codes; the web backend's Start and Stop through the CLI with a throwaway use case (colored logs, `--force`); `tests/cli.sh` and `tests/static.sh` pass.
- `stop`, `uninstall` and `purge` were exercised only against a fake `docker`, by design; they were not run against the live environment.
- Running the rebuilt image (without `make`) was not done: recreating the Playground container was declined during the session, so the new image will be used on the next `./playground start` after the container is recreated.
- Not validated: macOS amd64, Ubuntu amd64, Windows 11 WSL2. No real browser was available; the Web UI version display and all earlier UI behavior remain to be checked by the project owner.

## Known limitations

- No license is defined for the repository (release blocker, see `docs/release-checklist.md`).
- `infra test-network` is not provided (no engine script implements it).
- `restart` and `stop` end terminal sessions (tmux lives in the container's processes); clusters are kept.
- The demo credentials `admin` / `password` (Grafana, MinIO) are deliberate and local-only.
- The repository is not a Git repository in the development tree, so no history audit for secrets was possible there.

## Original specification (verbatim)

~~~~~text
SPEC-007.0 — V1 Release Candidate Preparation

Project: CNPG Operator Playground
Target version: v1.0.0-rc.1
Status: To implement
Priority: Release preparation
Principle: KISS — One CLI, one codebase, one Docker Compose configuration.

⸻

1. Objective

Prepare CNPG Operator Playground for its first release candidate.

The Playground must be easy to install, start, operate, stop and uninstall on:

* macOS Apple Silicon (arm64)
* macOS Intel (amd64)
* Ubuntu Linux (amd64)
* Windows 11 using WSL2 and Docker Desktop (amd64)

The primary architectural change is to remove GNU Make as a project dependency and replace it with a single Bash CLI.

The final user experience should be:

git clone <repository-url>
cd cnpg-operator-playground
./playground doctor
./playground install
./playground start

Then open:

http://localhost:8080

No local installation of Kind, kubectl, Helm, Python, tmux or GNU Make should be required.

All Kubernetes tooling must remain inside the Playground container.

⸻

2. Mandatory Preflight

Before making changes:

1. Inspect the complete repository structure.
2. Read README.md, docs/architecture.md and docs/specs/.
3. Inspect the current Makefile and all its targets.
4. Identify every Make invocation throughout the repository.
5. Inspect Docker Compose and Dockerfile.
6. Identify scripts that execute on the host versus inside the container.
7. Inspect cluster lifecycle, terminal sessions, kubeconfig management and cleanup behavior.
8. Identify architecture-specific Docker images.
9. Inspect the current Web UI header and API endpoints.
10. Record the current Docker, Kind and tmux runtime state.

Produce a short implementation plan before modifying files.

Safety constraints

* Do not stop or delete running Kind clusters.
* Do not terminate existing tmux sessions.
* Do not delete kubeconfig files.
* Do not remove Docker volumes.
* Do not modify PostgreSQL data.
* Do not change existing CNPG scenarios.
* Do not modify the read-only reference repository.
* Preserve existing Web UI functionality.

If a change requires disrupting the running environment, report it and request approval first.

⸻

3. Remove GNU Make

3.1 Requirement

GNU Make must no longer be required to install, operate or develop the Playground.

Replace the Makefile interface with a single executable:

./playground

The CLI must reuse the existing Bash scripts.

Do not duplicate infrastructure or use case lifecycle logic.

3.2 Migration

Inventory all existing Make targets and establish their CLI equivalents.

Examples:

Previous command    New command
make infra-up    ./playground infra up
make infra-down    ./playground infra down
make infra-info    ./playground infra info
make infra-status    ./playground infra status
make infra-test-network    ./playground infra test-network
make usecase-up USECASE=name    ./playground usecase start name
make usecase-down USECASE=name    ./playground usecase stop name

These are examples, not an exhaustive mapping.

Inspect the actual Makefile and migrate every useful target.

Preserve the existing behavior, parameters and exit codes.

Where possible, use the existing scripts directly.

3.3 Remove Makefile

Once all functionality has been migrated and verified:

* Remove the Makefile.
* Remove all internal dependencies on Make.
* Update scripts and documentation.
* Ensure Docker images do not require Make for Playground operations.
* Update any automated tests that invoke Make.

Do not remove the Makefile until functional equivalence has been established.

The final repository must have no operational dependency on GNU Make.

⸻

4. Unified Playground CLI

4.1 Entry point

Create an executable file at the repository root:

playground

It must:

* Use Bash.
* Be compatible with Bash 3.2 or newer for host-side operations.
* Work on macOS, Ubuntu and WSL2.
* Resolve paths relative to its own location.
* Work regardless of the current working directory.
* Provide clear error messages.
* Return meaningful exit codes.
* Avoid unnecessary dependencies.
* Support --help.

Example:

./playground --help

Expected output:

CNPG Operator Playground v1.0.0-rc.1
Usage:
  ./playground <command> [options]
Lifecycle:
  doctor              Check prerequisites
  install             Build and prepare Playground
  start               Start Playground
  stop                Stop Playground
  restart             Restart Playground
  status              Show Playground status
  uninstall           Remove Playground installation
  purge               Remove Playground and its managed resources
Infrastructure:
  infra up            Create infrastructure
  infra down          Remove infrastructure
  infra info          Display infrastructure information
  infra status        Display infrastructure status
  infra test-network  Test infrastructure networking
Use Cases:
  usecase list         List available use cases
  usecase start NAME   Start a use case
  usecase stop NAME    Stop a use case
  usecase status NAME  Show use case status
Other:
  version             Display version
  help                Display help

Adapt command names where necessary to preserve the existing engine’s semantics.

Do not expose commands that cannot be implemented reliably.

4.2 Host and container execution

The CLI must support two execution contexts.

Host

Used for:

./playground doctor
./playground install
./playground start
./playground stop
./playground restart
./playground status
./playground uninstall
./playground purge
./playground version

These commands operate through Docker Compose.

Playground container

Used for:

./playground infra info
./playground infra status
./playground usecase list
./playground usecase start cnpg-standard
./playground usecase status cnpg-standard

The CLI must detect whether it is executing inside the Playground container.

For infrastructure and use case commands executed from the host, prefer routing through the running Playground container using Docker Compose.

For example:

./playground infra info

should transparently execute the appropriate internal command.

Users should not need to know whether a particular command runs inside or outside the container.

Avoid recursive CLI dispatch loops.

4.3 Bash compatibility

Host-side CLI code must not depend on Bash 4+ features.

In particular, avoid:

* mapfile
* readarray
* Associative arrays
* Bash 4-specific syntax

Existing internal scripts may continue using Bash 5, provided they execute exclusively inside the Playground container.

The current macOS failure:

engine/infrastructure/kind/info.sh:
mapfile: command not found

must be resolved through correct execution-context routing.

Do not introduce a requirement to upgrade the host’s Bash installation.

⸻

5. Installation and Lifecycle

5.1 Doctor

Command:

./playground doctor

Check:

1. Supported operating system.
2. CPU architecture (amd64 / arm64).
3. Docker installation.
4. Docker Engine availability.
5. Docker Compose v2.
6. Docker daemon connectivity.
7. Docker socket accessibility from the container architecture.
8. Available Docker memory and CPU resources.
9. Required host ports.
10. WSL2 configuration when applicable.
11. Docker Desktop WSL integration when applicable.
12. Git availability when relevant.

Output example:

CNPG Operator Playground — Prerequisites
[OK] Operating system: macOS
[OK] Architecture: arm64
[OK] Docker Engine
[OK] Docker Compose v2
[OK] Docker daemon connection
[OK] Docker memory: 16 GB
[OK] Docker CPUs: 14
[OK] Port 8080 available
[OK] Docker socket
Environment ready.

When a check fails, provide an actionable remediation message.

Use WARN for non-blocking resource recommendations.

The command must be read-only.

It must not install packages or modify the host.

If port 8080 is already occupied by this Playground, report that correctly rather than treating it as an unrelated conflict.

5.2 Install

./playground install

Responsibilities:

* Run prerequisite validation.
* Validate Docker Compose configuration.
* Build the Playground image.
* Prepare only the required local configuration.
* Preserve existing data and resources.
* Be safe to execute multiple times.

Installation must not automatically create Kind clusters.

Installation must not automatically start use cases.

5.3 Start

./playground start

Responsibilities:

* Start the Playground container using Docker Compose.
* Reuse existing configuration and persistent resources.
* Avoid rebuilding unnecessarily.
* Wait until the Web API is ready.
* Display the URL.

Example:

CNPG Operator Playground v1.0.0-rc.1
[OK] Playground started
[OK] Web UI ready
Open: http://localhost:8080

The command must be idempotent.

Do not restart existing Kind clusters.

5.4 Stop

./playground stop

Stop only the Playground application containers managed by Docker Compose.

Do not delete:

* Kind clusters
* Kubernetes data
* Docker volumes
* Kubeconfig files
* Use case directories

Because Kind clusters are independent Docker containers, explicitly explain that they may continue running after the Playground stops.

5.5 Restart

./playground restart

Restart the Playground application without recreating Kind clusters.

Preserve persistent terminal state wherever the existing architecture permits.

Document any unavoidable loss of live WebSocket connections.

5.6 Status

./playground status

Display:

* Playground version
* Application container state
* Web UI URL
* Docker availability
* Managed Kind clusters
* Active use cases, where detectable

The command must be read-only.

5.7 Uninstall

./playground uninstall

Remove the Playground application containers and project-specific installation resources.

Preserve:

* Kind clusters
* Kubernetes data
* Persistent volumes
* User files
* Kubeconfig files

Clearly report what remains.

Require confirmation before removing resources.

Support:

./playground uninstall --yes

for explicitly authorized non-interactive execution.

5.8 Purge

./playground purge

This is a destructive operation.

It must:

1. Display a complete inventory of resources proposed for deletion.
2. Identify the Playground-managed Kind clusters.
3. Identify relevant Docker volumes.
4. Identify persistent configuration and kubeconfig files.
5. Clearly distinguish project-managed resources from unrelated resources.
6. Require explicit confirmation.
7. Delete only resources whose ownership can be established.
8. Report any resources that could not be removed.

Never delete resources based solely on broad Docker name matching.

Never run:

docker system prune
docker volume prune

as part of Playground cleanup.

Do not delete unrelated Docker resources.

Do not remove source code or the Git repository.

Do not silently remove user-created data.

Support a read-only preview:

./playground purge --dry-run

For the initial release, if safe ownership detection is not possible for a resource, report it and leave it untouched.

⸻

6. Cross-Platform Compatibility

6.1 Supported platforms

Target:

Platform    Architecture    Runtime
macOS Apple Silicon    arm64    Docker Desktop
macOS Intel    amd64    Docker Desktop
Ubuntu 24.04+    amd64    Docker Engine + Compose
Windows 11    amd64    WSL2 Ubuntu + Docker Desktop

Windows commands must run from WSL2.

Do not require PowerShell scripts.

Recommend storing the repository inside the WSL2 Linux filesystem.

6.2 Docker images

Audit all images used by:

* Playground
* Kind
* CNPG
* PostgreSQL
* Grafana
* MinIO
* Prometheus
* Operators
* Supporting tools

Verify whether each image supports both linux/amd64 and linux/arm64.

Do not assume multiarchitecture support.

Produce a compatibility matrix.

If an image is unsupported on a target architecture, document the limitation and propose a minimal correction.

Do not silently replace product images or versions.

6.3 Docker networking

Verify:

* Docker socket mounting
* Kind networking
* Host port publication
* Dynamic Grafana and MinIO ports
* Web UI port 8080
* Browser access from the host
* Windows/WSL2 localhost forwarding
* Docker resource reporting

Preserve the existing dynamic port allocation.

Do not hard-code Kind node names.

6.4 Security

Bind the Web UI to localhost by default.

Do not expose the Docker control interface over the network.

Document the security implications of mounting the Docker socket.

Ensure that installation and diagnostic commands do not print secrets.

⸻

7. Version Management

7.1 Centralized version

Create:

VERSION

Initial content:

1.0.0-rc.1

This file must be the single source of truth.

Do not duplicate hard-coded version strings throughout the application.

7.2 CLI

./playground version

Expected output:

CNPG Operator Playground v1.0.0-rc.1

7.3 Web UI

Display the version in small text next to the Playground title in the top banner.

Example:

CNPG Operator Playground  v1.0.0-rc.1

Requirements:

* Subtle visual appearance.
* Compatible with EDB and Dark themes.
* Responsive layout.
* No change to existing header functionality.

7.4 Backend

Expose the version through the existing API architecture.

Prefer extending an existing metadata endpoint if appropriate.

The backend must read the central VERSION file.

The frontend must obtain the version from the backend rather than hard-coding it.

⸻

8. Documentation

8.1 README.md

Simplify the main README.

It should focus on getting started, not implementation details.

Suggested structure:

# CNPG Operator Playground
Overview
Features
Supported Platforms
Prerequisites
Quick Start
First Use Case
Stop / Uninstall
Documentation
Contributing

Quick Start:

git clone <repository-url>
cd cnpg-operator-playground
./playground doctor
./playground install
./playground start

Then:

http://localhost:8080

Include a short first-use tutorial:

1. Open the Web UI.
2. Select a use case.
3. Start the use case.
4. Open its terminal.
5. Execute a scenario.
6. Access Grafana and MinIO.
7. Stop the use case.

Include lifecycle examples:

./playground stop
./playground uninstall
./playground purge --dry-run

Keep the README concise.

Move advanced explanations into docs/.

Do not invent a repository URL.

8.2 Installation guide

Create:

docs/installation.md

Include:

* macOS prerequisites
* Ubuntu prerequisites
* Windows/WSL2 prerequisites
* Docker installation references
* Resource recommendations
* Troubleshooting
* Common Docker networking issues

Make must not appear as a prerequisite.

8.3 CLI reference

Create:

docs/cli.md

Document every supported command.

Explain:

* Host versus container execution
* Destructive commands
* Confirmation behavior
* Exit codes
* Common examples

8.4 Architecture

Update:

docs/architecture.md

Reflect the unified CLI and Docker Compose lifecycle.

Preserve the current architecture.

⸻

9. CLAUDE.md

Create a concise root-level:

CLAUDE.md

This is the operational guide for future Claude Code sessions.

Include:

* Project purpose
* Architecture overview
* Directory structure
* Unified CLI conventions
* Host/container execution boundaries
* Dynamic use case discovery
* Kubernetes context isolation
* Docker/Kind lifecycle constraints
* Web UI architecture
* Testing requirements
* Safety rules
* Documentation conventions

Explicitly reference:

docs/specs/README.md

Do not copy all historical specifications into CLAUDE.md.

The complete specifications remain in docs/specs/.

Include a rule requiring future changes to update the appropriate specifications and documentation.

⸻

10. CONTRIBUTING.md

Create:

CONTRIBUTING.md

Keep it practical.

Include:

1. Project setup.
2. Development workflow.
3. Repository conventions.
4. Adding a use case.
5. Scenario structure.
6. Naming conventions.
7. Testing expectations.
8. Documentation updates.
9. Pull request guidelines.
10. Security and secret-handling rules.

Explain that contributors must not commit:

* Credentials
* Private kubeconfigs
* EDB tokens
* Cloud secrets
* Private keys
* Runtime-generated files

⸻

11. Release Security and Repository Hygiene

Audit:

.gitignore
.dockerignore
Dockerfile
compose.yaml

Verify that runtime files are excluded appropriately.

Check for accidentally committed credentials.

If Git history is available, inspect it for secrets.

Do not print secret values in the report.

Do not rewrite Git history automatically.

Verify the repository’s licensing status.

Do not invent or add a license without explicit authorization.

If licensing or internal redistribution rights are unclear, report them as release blockers.

⸻

12. Tests

12.1 Static tests

Validate:

* Bash syntax
* Python syntax
* JavaScript syntax
* Docker Compose configuration
* CLI argument parsing
* CLI help output
* Version consistency
* Documentation links
* Absence of Make dependencies

12.2 CLI tests

Test:

./playground --help
./playground version
./playground doctor
./playground status
./playground infra info
./playground usecase list
./playground purge --dry-run

Verify correct exit codes and error messages.

Do not execute destructive commands against the existing environment.

12.3 Regression tests

Verify that the migration does not break:

* Web UI
* Sidebar
* Terminal tabs
* ttyd/tmux sessions
* Kubernetes context isolation
* Scenario execution
* Original ui.sh formatting
* Grafana access
* MinIO access
* Resource monitoring
* EDB/Dark themes
* Dynamic ports
* Use case discovery

12.4 Cross-platform validation

Prepare a validation checklist for:

* macOS arm64
* macOS amd64
* Ubuntu amd64
* Windows/WSL2 amd64

Do not claim a platform is validated unless tests have actually run on that platform.

If only macOS arm64 is available, report the others as pending validation.

12.5 Non-destructive execution

During implementation:

* Do not start or stop existing Kind clusters.
* Do not run purge or uninstall against the live environment.
* Do not destroy persistent data.
* Do not terminate live terminal sessions.

Use isolated tests and mocks where possible.

If testing requires modifying the current runtime, request approval first.

⸻

13. Specifications History

Create:

docs/specs/SPEC-007.0-v1-release-candidate.md

Preserve this specification in full.

Update:

docs/specs/README.md

Include:

* Specification ID
* Title
* Status
* Implementation summary
* Validation status
* Known limitations

Preserve the existing specifications and historical corrections.

⸻

14. Release Readiness

Prepare a release checklist:

docs/release-checklist.md

Include:

* Unified CLI implemented
* GNU Make removed
* Prerequisites documented
* macOS arm64 validated
* macOS amd64 validated
* Ubuntu amd64 validated
* Windows/WSL2 validated
* Installation validated
* Stop behavior validated
* Uninstall behavior validated
* Purge dry-run validated
* Version displayed in UI
* README updated
* CLAUDE.md created
* CONTRIBUTING.md created
* Security audit completed
* License status confirmed
* Automated tests passing
* Browser regression tests passing

The target version is:

v1.0.0-rc.1

Do not create a Git tag or push changes automatically.

Do not declare the final v1.0.0 release complete.

⸻

15. Acceptance Criteria

The specification is complete when:

1. GNU Make is no longer required anywhere in the project.
2. The Makefile has been removed after successful migration.
3. A single ./playground CLI provides all supported operations.
4. The CLI works from both host and Playground container contexts.
5. Host operations work with Bash 3.2+.
6. Installation and lifecycle operations are safe and idempotent.
7. Destructive cleanup requires explicit confirmation.
8. Cross-platform compatibility has been audited and documented.
9. The version is centrally managed as 1.0.0-rc.1.
10. The Web UI displays the version.
11. The README provides a simple Quick Start.
12. CLAUDE.md and CONTRIBUTING.md are available.
13. Automated tests cover the CLI and critical existing behavior.
14. No existing CNPG use case functionality has regressed.
15. The full specification is archived in docs/specs/.
16. Remaining platform validation and release blockers are clearly reported.

⸻

16. Final Report

At completion, provide:

Implementation

* Files created
* Files modified
* Files removed
* Make-to-CLI migration table

Validation

* Tests executed
* Tests passed
* Tests not executed
* Platform compatibility status

Safety

* Confirmation that existing clusters were preserved
* Confirmation that Kubernetes data was preserved
* Confirmation that tmux sessions were preserved

Release readiness

* Remaining blockers
* Manual tests required
* Recommended next steps before tagging v1.0.0-rc.1

Do not perform Git push, create a release or tag the repository without explicit authorization.
~~~~~
