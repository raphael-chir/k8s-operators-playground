# SPEC-012 — Declarative Use Case Architecture

Status: implemented; static and fake-kubectl checks, CLI and engine tests, a throwaway-container check of the Web API. No live cluster was started, stopped or recreated.

## Implementation

- **`usecases/<name>/usecase.yaml`** for the three use cases: `title`, `description`, `infrastructure.clusters`, `infrastructure.workers_per_cluster`. The identifier is the directory name. `engine/infrastructure/kind/common.sh` holds `usecase_config` (reads exactly this flat schema, not a YAML parser) and `usecase_manifest_check` (title and description present, both numbers positive integers).
- **Engine lifecycle.** `engine/usecase-run.sh start|stop|status NAME` (called by `./playground usecase ...`, so by the Web UI too) runs `usecase_start` (`usecase_provision`, then, with more than one cluster, `usecase_validate_connectivity`, then the access information), `usecase_delete` (unchanged) or `usecase_status`. `engine/usecase.sh` accepts `PLAYGROUND_USECASE` (set by the runner) instead of deriving the use case from a calling script.
- **Connectivity validation** moved from `cnpg-distributed-topology/install.sh` to the engine and made generic: every control plane on the `kind` network, then every ordered pair's API `/readyz`; for two clusters this is the former 1→2 and 2→1.
- **Status** no longer contains cert-manager, CNPG, Barman or CRD logic: nodes, Grafana and MinIO state, access URLs, scenarios.
- **Discovery** (`engine/usecase-list.sh`): a use case needs a valid `usecase.yaml`; an invalid one is skipped with a warning and refused by `usecase start`. `--meta` prints `name, title, description` for the Web UI.
- **Flattened layout.** Scenario scripts, `manifests/` and (PGD) `lib/` moved to the use case root; `scenarios/`, `install.sh`, `cleanup.sh`, `status.sh` removed. Scenario edits are path-only: `../../../engine/` became `../../engine/` in the 11 scripts, `../manifests/` became `manifests/` in `cnpg-standard` 01 and 03.
- **Terminals** start in `usecases/<name>`. **Web UI:** `/api/usecases` and `/api/terminals` return `title` (and `description`); the sidebar, the tabs and the status bar show the title, the directory name stays the id.
- Existing tests updated for the new paths only (`tests/scenarios.sh`, `tests/engine.sh`); docs updated.

## Limitations

- The new backend code (titles) needs a uvicorn restart to be served; the engine and static files are live at once.
- Open terminals whose working directory was `.../scenarios` now sit in a deleted directory until `cd` or a refresh.
- `cnpg-distributed-topology/01_install-cnpg-cluster.sh` references `manifests/cnpg-community-cluster.yaml`, which has never existed in this repository (unchanged, outside this spec).
- The PGD use case no longer has product-specific status (`PGDGroup` listing); `platform/operators/pgd4k/install.sh --summary` is now unused.
- The bash reader accepts only the flat schema above; unknown keys are ignored.

## Addendum: terminal paths and declarative platform services

- **`/usecases` symlink.** `engine/entrypoint.sh` creates `/usecases -> /workspace/usecases` on every container start (idempotent, never replaces a real directory); the files stay in the project. `engine/terminal.sh` starts the Playground terminal in `/usecases` and use case terminals and split panels in `/usecases/<name>`, so the unchanged prompt shows `root@playground:/usecases/cnpg-standard#`. Bash keeps the logical path through `cd`, `cd ..` always works, `/workspace` is still reachable. A container started before the link exists falls back to the real directory. `engine/usecase.sh` resolves its caller with `pwd -P` so scenarios started through the link still find the project root. It takes effect at the next container start; nothing was created in the running container.
- **`services` section** of `usecase.yaml`: explicit booleans `cert_manager`, `minio`, `prometheus`, `grafana`; a missing key means `false`; an unknown key or a non-boolean value is refused by the manifest check. All three use cases enable all four (cert-manager for the Barman plugin and the PGD certificates, Prometheus for the PodMonitors, Grafana for the dashboard, MinIO for backups). `usecase_provision` passes the selection to `platform-up.sh` in the optional `PLATFORM_SERVICES` variable (comma separated); without it (`./playground infra platform-up`) the former behavior holds: MinIO, Prometheus and Grafana, no cert-manager. `info.sh` takes `INFO_SERVICES` so a disabled service is not shown; `usecase_status` reports only the requested services.
- **Monitoring.** Prometheus and Grafana are independent with the single `kube-prometheus-stack` chart (`PROMETHEUS_ENABLED`, `GRAFANA_ENABLED`, default true). Without Prometheus the installer also disables the operator, Alertmanager, kube-state-metrics, default rules, control-plane ServiceMonitors, the Prometheus Operator CRDs (`crds.enabled`: they live in the chart's `crds/` directory, are not tied to the operator, and Helm never upgrades or deletes them) and Grafana's Prometheus datasource; Grafana alone starts without a datasource and the CNPG dashboard is not imported. With both enabled no option is added: the release is the same as before. An existing release is never reduced (a manifest change applies to new clusters only).
- **cert-manager.** `platform/cert-manager/install.sh` is now also used by Start (it labels the platform node first). The operator installers are unchanged and still call it: it keeps an existing cert-manager, so there is no conflict. With `cert_manager: false`, an operator installer run by a scenario installs it anyway.
- **Parser.** The awk reader already handled two levels; it needed only validation (booleans, known keys). No dependency, no image rebuild.
- **Tests.** `tests/monitoring.sh` (new: `helm template` of the four combinations with the installer's own options, offline-safe), `tests/engine.sh` (services validation, symlinked scenario root) and `tests/terminal.sh` (link paths, logical navigation).

### Additional limitations

- Not run against a cluster (no cluster was created): the install of each service combination, `platform-up` with a selection, the Start sequence and the status lines are verified by `helm template`, syntax and a stubbed call chain only.
- Existing clusters are not touched: a manifest change applies at the next provisioning, and an existing monitoring release is not reduced.
- `/usecases` exists only after the container is restarted; terminals opened before that start in `/workspace/usecases`.
- Prometheus status reports the operator deployment (the Prometheus pod is a StatefulSet).

## Original request (condensed: no requirement dropped)

~~~~~
SPEC-012 — Declarative Use Case Architecture

Objective: simplify the architecture with a declarative usecase.yaml per use case and engine-managed lifecycle; remove redundant lifecycle scripts and flatten the directory structure. KISS, one source of truth, engine independent of PostgreSQL products, CLI and Web UI preserved, scenario behavior preserved.

Structure: usecases/<name>/ holds usecase.yaml, README.md, the NN_*.sh scenarios, manifests/ (and .env.example for PGD4K). Remove install.sh, cleanup.sh, status.sh and the scenarios/ directory (its contents move to the root). No renaming or renumbering of scenarios.

Schema: title, description, infrastructure.clusters, infrastructure.workers_per_cluster (positive integers). The identifier is the directory name (not duplicated in YAML). Kind is the only engine, no engine property. No operator versions, plugins, secrets or scenario definitions. No other properties without a concrete requirement.

Lifecycle: start (discover, read and validate usecase.yaml, provision Kind clusters via usecase_provision with idempotency and incompatible-cluster detection, nodes, networking, Prometheus, Grafana, MinIO, print access info; no operators, plugins or PostgreSQL), status (infrastructure only: cluster availability, nodes, shared platform services, access information; no CNPG/PGD4K logic), stop (usecase_delete: confirmation, --force, isolation between use cases).

Multi-cluster connectivity: preserve the validation of cnpg-distributed-topology/install.sh in the engine, generic (control planes on the Docker network, Kubernetes API connectivity between clusters, clear failures, existing failure behavior, bidirectional checks for two clusters), no hardcoded use case, no new YAML properties.

Flattening: move scenarios and manifests to the use case root; adapt only paths (ui.sh/usecase.sh imports, manifest references, scenario discovery in the CLI and Web UI, terminal working directories, README references, helpers). Do not modify commands, versions, PostgreSQL configuration or demonstration logic, nor ui_* implementations. Discovery: NN_description.sh at the use case root only, sorted, not recursive, not declared in YAML.

Web UI: discover through usecase.yaml, title as display name, description where supported, directory name as id; preserve Start, Stop, Status, scenarios, terminal tabs and split terminals.

PGD4K: keep .env/.env.example, no secrets in usecase.yaml, no EDB_TOKEN during provisioning, no changes to the operator installer or scenario logic, no PGD4K logic in the engine.

Compatibility: keep the CLI commands, use case ids and Kind cluster names; do not recreate or delete existing clusters; update all repository references to old paths.

Out of scope: new scenarios, renumbering, operator installation or versions, k3d, other engines, new monitoring, lifecycle features, hooks, unrelated refactoring.

Validation: no new test suites; valid manifests, discovery, CLI resolution, Web titles, scenario discovery, imports and manifest paths, multi-cluster validation available, Start installs no operator, no product logic in the generic lifecycle, running clusters untouched; do not start, stop or recreate live clusters.

Deliverables: architectural summary, modified/moved/deleted files, validation results, limitations and risks.
~~~~~

### Addendum request (condensed: no requirement dropped)

~~~~~
SPEC-012 additional requirements: terminal paths and declarative platform services

1. /usecases -> /workspace/usecases symlink created in engine/entrypoint.sh (persists across recreation, no manual creation in the running container); main terminal in /usecases, use case terminals and split panels in /usecases/<usecase>; Bash logical navigation; no PS1 change; pwd -P fix for scenario root discovery; no ttyd/WebSocket/SPEC-009 change.
2. services section (cert_manager, minio, prometheus, grafana): explicit booleans, missing = false, only enabled services installed, enabled on every cluster, all four enabled in the three use cases, optional environment variables to the platform scripts, standalone `infra platform-up` unchanged.
3. Prometheus and Grafana independent with the existing kube-prometheus-stack chart (all four combinations); verify with helm template; Grafana without a Prometheus datasource; check how the CRDs are installed and managed (disabling the operator does not remove CRDs); behavior unchanged when both are enabled.
4. cert-manager optional, operator installers unchanged, scenarios may install it later: document it.
5. Extend the awk parser for the two-level schema with strict integer and boolean validation; no generic parser.
6. Validation: update tests, static checks, helm template; no temporary Kind clusters; existing clusters, containers and uvicorn untouched.
7. Scope: preserve scenarios, operator installers, CLI, Web UI terminals, cluster naming; no unrelated refactoring. Report changes, validation and limitations not testable without a cluster.
~~~~~
