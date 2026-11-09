# SPEC-007.1.1 — CNPG Standard Scenario Integration

| | |
|---|---|
| Status | Implemented; static and non-destructive validation done. **Runtime validation pending**: no imported scenario has been run against a live cluster |
| Document type | Original specification, preserved verbatim, with the implementation record |
| Source | Claude Code session transcript (project history), user message of 2026-11-05 |
| Original specification | Available (see the last section) |
| Target version | `1.0.0-rc.1` (unchanged) |

## Summary

Bring the CNPG workshop scenarios (`../se-demos-k8s-cnpg-workshop`, read-only) into `usecases/cnpg-standard/scenarios/`, adapted to the Playground (single dedicated Kind cluster, dynamic ports, per-terminal Kubernetes context) without redesigning them.

## Preflight comparison

Source (`cnpg-hands-on/`, one namespace and OS user per participant on a k3d/EC2 host; manifests are `envsubst` templates) against `usecases/cnpg-standard`.

| Source step | Purpose | Playground before | Action |
|---|---|---|---|
| 01 `check_environment` | Welcome, topology, operator pods, MinIO secret, URLs | Covered by `01_install-cnpg-cluster.sh` (topology, operator, secret) | Not imported: covered |
| 02 `deploy_cluster` | CRDs, `explain`, manifest, deploy a cluster **without** backup | Merged into `01_install-cnpg-cluster.sh` (cluster with the Barman plugin from the start) | Not imported: applying it after 01 would strip the plugin |
| 03 `check_cluster` | Pods, services, PVCs, logs, `describe` | Same inspection is the second half of `01_install-cnpg-cluster.sh` | Not imported: covered |
| 04 `add_barman_plugin` | ObjectStore + plugin on the cluster | Merged into 01 (the `ObjectStore` is in `cnpg-community-cluster.yaml`) | Not imported: covered |
| 05 `create_data` | `kubectl cnpg`, connection secret, `pgbench`, `psql` | Missing | Imported |
| 06 `backup_cluster` | Imperative and declarative backup | Missing | Imported |
| 07 `restore_cluster` | Recovery into a new cluster, scale | Missing | Imported |
| 08 `minor_upgrade` | `kubectl diff`, rolling minor upgrade | Missing | Imported (versions adapted) |
| 09 `cluster_administration` | promote, hibernate, fencing | Missing | Imported |
| 10 `major_upgrade` | Major upgrade by import into a new cluster | Missing | Imported (versions adapted) |
| 11 `cluster-failover` | Delete primary + PVCs, observe failover | Missing | Imported |
| 12 `major_upgrade_in_place` | In-place major upgrade | Missing | Imported (versions adapted) |
| 99 `reset_lab` | Delete clusters, backups, jobs, MinIO prefixes | Missing | Imported and adapted |

The existing `01_install-cnpg-cluster.sh` was compared and left unchanged. Numbering: the workshop numbers 05–12 and 99 are preserved; 02–04 are intentionally absent (documented in the use case README). No numbering conflict remains (unique prefixes, alphabetical = execution order; checked by `tests/scenarios.sh`).

Excluded source content: `provision.sh`, `infra/` (AWS EC2, ssh), `platform/setup/*` (k3d, OS users, ttyd, banner), `platform/install.sh`, `config.sh` (infrastructure and workshop sizing), `platform/resources/tests/*` load tests (not referenced by any scenario), `platform/resources/cnpg-dashboard.json` (the Playground ships its own), `lib/ui.sh` and `lib/logger.sh` (the Playground's `engine/lib/ui.sh` is the reference; it already replaces the workshop's `gum` version), `logs/`, `docs/images`.

Dependencies: the scenarios use `kubectl`, `kubectl cnpg` (plugin), `jq`, `less`, `base64`, `yq` and `watch`. All are in the image except `yq`, which only pretty-prints manifests; **no image change**: `scenarios/lib.sh` defines a `cat` fallback when `yq` is absent. `watch` is replaced by the existing `ui_watch`. Scenario 99 pulls `netiedge/minio-mc` (as in the workshop).

Hard-coded environment found in the source and its replacement: per-user namespace and `-${USER}` names → `default` namespace and fixed names (`cnpg-cluster`, `restored-cnpg-cluster`, `major-upgraded-cnpg-cluster`); `PUBLIC_IP:3010` / `:9010` → ports discovered from Docker and the NodePort Services (as `info.sh` does); label `node.workshop/role` → `playground.edb.io/role`; MinIO and Grafana credentials and endpoint taken from the Playground platform (same bucket and in-cluster endpoint); `kubectl config set-context --namespace` text removed (single namespace). Runtime state at preflight: no Playground container and no Kind node, so nothing was running that could be disturbed.

## Implemented behavior

- `scenarios/lib.sh` (new, not a scenario: no leading digit): `scenario_init` (cluster must answer, kubectl targets the use case cluster, Grafana and MinIO console URLs discovered), the `yq` fallback, constants (`default` namespace, in-cluster S3 endpoint, bucket).
- **Context isolation:** when the current context is not `kind-cnpg-lab-cnpg-standard-1`, the scenario prepends a private temporary file holding only `current-context` to `KUBECONFIG` (the Web terminal mechanism) and removes it on exit. The shared kubeconfig and the terminal's own file are never modified.
- Scenarios `05_create_data`, `06_backup_cluster`, `07_restore_cluster`, `08_minor_upgrade`, `09_cluster_administration`, `10_major_upgrade`, `11_cluster-failover`, `12_major_upgrade_in_place`, `99_reset_lab`: same text, order and prompts as the source; the only changes are listed below. Executable, resolve their paths from their own location (the engine enters the scenario directory), runnable from any working directory.
- Manifests `03-cnpg-cluster-backup`, `04-cnpg-cluster-restore`, `05-cnpg-cluster-minor-upgrade`, `06-cnpg-cluster-major-upgrade`, `07-cnpg-cluster-inplace-major-upgrade` (the workshop templates rendered with the use case's parameters: same cluster definition as `cnpg-community-cluster.yaml`, 1 Gi volumes, no namespace). `05` differs from the existing cluster manifest only by the image.
- `usecases/cnpg-standard/README.md` rewritten (architecture, prerequisites, scenario list and order, expected results, reset, limitations).

### Compatibility adaptations (the complete list)

1. `-${USER}` suffixes and `NAMESPACE`/`PUBLIC_IP` logic removed; fixed names in `default`.
2. Header replaced by the Playground's (ui.sh, engine/usecase.sh, `lib.sh`, `scenario_init`).
3. Grafana and MinIO links use the discovered host URLs.
4. `watch -c -n 1 …` → `ui_watch "…"` (the Playground convention; **Enter** returns instead of Ctrl+C), and the text says so; in 09 the `hibernate …;watch …` compound command is split into `ui_command` + `ui_watch`; the `ui_pause` that followed each watch is dropped because `ui_watch` already waits for Enter.
5. Versions: the cluster runs PostgreSQL 17.5 (community image, existing manifest), so the minor upgrade is 17.5 → 17.6 and the major upgrades go to 18 (`ghcr.io/cloudnative-pg/postgresql`) instead of the workshop's 16.4 → 16.5 → 17 (EDB images).
6. `99_reset_lab`: MinIO credentials read from `minio-secret` instead of constants; it also deletes the `minio-storage` ObjectStore and `minio-secret` created by step 01 so that 01 can be replayed; the `CLUSTERS` list and the warning text name this use case's resources. Backups and jobs of the dedicated `default` namespace are still deleted with `--all`, as in the workshop; the context is pinned to this cluster.

Unchanged on purpose (scenario logic is out of scope): the workshop's quirks, e.g. 07 scales to `--replicas=2` while its text says 3; 11 passes JSON-path quotes through `eval`; the in-place manifest (12) has no `plugins` section, so applying it removes WAL archiving. `engine/lib/ui.sh`, the engine, `compose.yaml`, the CLI, the Dockerfile and the other use cases are not modified.

## Validation

**Static and non-destructive (done), `tests/scenarios.sh`:** unique numbers and order; `lib.sh` not discovered; syntax, executable bit, use of `ui.sh`/`usecase.sh`; every referenced manifest exists and parses; no namespace or workshop label in manifests; no hard-coded user, IP, port, node, context name or Make; no secret patterns; source repository has no local change; **context isolation** with the real `kubectl` on a scratch kubeconfig (plain shell, terminal file on another context, already-correct context: the shared kubeconfig is never changed); **flow** of each of 05–12 and 99 with a fake `kubectl`/`docker`/`sleep` (exit 0, Unicode boxes, prompts, discovered URLs, from `/`, from the scenario and use case directories, `/tmp`, an arbitrary directory and as `./script`), every `kubectl` call after the first made with the private context file, shared kubeconfig unchanged, and the cluster-unreachable path stopping before any change. The fake run records the mutating commands each scenario would send (reviewed, never sent). `tests/static.sh` (syntax of all scripts, no Make), `tests/cli.sh` and `tests/engine.sh` still pass. Limits: the host has Bash 3.2, the container Bash 5; the engine logger needs 4.2+, so message texts of `die` are only asserted by `tests/engine.sh` inside the container.

**Runtime (pending, nothing claimed):** none of the scenarios was run on a cluster. Open items:

| # | Check (on a started `cnpg-standard`, from the Web terminal) | Status |
|---|---|---|
| 1 | `playground usecase start cnpg-standard`, then `01_install-cnpg-cluster.sh` to completion | Pending |
| 2 | 05: `pgbench` job completes, tables exist in `app` | Pending |
| 3 | 06: both backups `completed`, objects visible in the MinIO console | Pending |
| 4 | 07: `restored-cnpg-cluster` recovers the data; scale works | Pending |
| 5 | 08: image `ghcr.io/cloudnative-pg/postgresql:17.6` exists and pulls; rolling update completes | Pending |
| 6 | 09: promote, hibernate on/off, fencing on/off; `kubectl exec -it … pg_ctl status` works in ttyd | Pending |
| 7 | 10: image `:18` exists; the microservice import succeeds (needs the superuser secret and `pg_hba`) | Pending |
| 8 | 11: failover observed; the quote handling in `PRIMARY_POD` works | Pending |
| 9 | 12: in-place major upgrade supported by the installed operator (chart 0.29.1); behavior without `plugins` | Pending |
| 10 | 99: reset deletes only the listed resources, MinIO purge runs (`netiedge/minio-mc` pulls), then 01 can be replayed | Pending |
| 11 | In a Web terminal: Enter continues, `ui_watch` returns on Enter, Ctrl+C interrupts, boxes render, `less` pages | Pending |
| 12 | Two terminals on different contexts: scenario in one does not change the other | Pending |
| 13 | Grafana and MinIO URLs printed by the scenarios open in the host browser | Pending |

## Known limitations

See the use case README. The use case is **not** marked fully validated.

## Original specification (verbatim)

~~~~~text
SPEC-007.1.1 — CNPG Standard Scenario Integration

Project: CNPG Operator Playground
Target version: v1.0.0-rc.1
Target use case: cnpg-standard
Source repository: ../se-demos-k8s-cnpg-workshop
Status: To implement

⸻

1. Objective

Integrate the existing CNPG workshop scenarios into the cnpg-standard use case of CNPG Operator Playground.

The source project is located in the same parent directory as the Playground:

parent/
├── cnpg-operator-playground/
└── se-demos-k8s-cnpg-workshop/

The source repository must be treated as strictly read-only.

The goal is to reuse the existing workshop content while adapting it to the Playground architecture.

This is an integration task, not a redesign.

Do not introduce new scenarios or improve existing scenario logic at this stage.

Scenario improvements will be addressed in a separate specification.

⸻

2. Mandatory Preflight

Before making any modifications:

1. Inspect the source repository structure.
2. Identify all available scenarios.
3. Inspect the existing cnpg-standard implementation.
4. Compare source and target scenarios.
5. Identify missing, duplicated or modified scenarios.
6. Identify dependencies and required tools.
7. Identify hard-coded Kubernetes contexts, cluster names, ports and paths.
8. Inspect how the Playground manages infrastructure and Kubernetes contexts.
9. Inspect the current scenario execution conventions.
10. Check the current Docker and Kind runtime state.

Produce a short comparison report before making changes.

Safety constraints

* Do not modify the source repository.
* Do not overwrite working Playground scenarios without comparison.
* Do not modify the Playground engine unless strictly necessary.
* Do not modify engine/lib/ui.sh.
* Do not change Docker Compose or the Playground CLI unless required to resolve an integration blocker.
* Do not delete or restart existing clusters.
* Do not delete Kubernetes data.
* Do not modify existing kubeconfig files.
* Do not terminate tmux sessions.
* Do not modify unrelated use cases.

If a change requires disrupting running resources, request approval first.

⸻

3. Scenario Inventory

Create a comparison between:

Source:

../se-demos-k8s-cnpg-workshop/

Target:

usecases/cnpg-standard/

For every source scenario, identify:

* Scenario number.
* Scenario name.
* Purpose.
* Required infrastructure.
* Required Kubernetes resources.
* Required external dependencies.
* Existing equivalent in the Playground.
* Integration status.

Example:

Scenario    Source    Playground    Action
CNPG installation    Available    Available    Compare
PostgreSQL deployment    Available    Available    Compare
HA / failover    Available    Missing    Import
Backup / restore    Available    Missing    Import

This table is illustrative. Use the actual repository contents.

Preserve the original scenario numbering wherever possible.

Identify any numbering conflicts before importing files.

⸻

4. Scenario Integration

Target directory:

usecases/cnpg-standard/scenarios/

Reuse the existing source scripts and manifests.

Preserve:

* Scenario numbering.
* Scenario execution order.
* Interactive prompts.
* User-facing explanations.
* Kubernetes manifests.
* Existing demonstration logic.
* Existing cleanup procedures.

Adapt only what is necessary for Playground compatibility.

4.1 Project paths

All scripts must work from the Playground container.

Avoid absolute paths referring to the original source repository.

Scripts should resolve their dependencies relative to their own location or the Playground project root.

Do not assume that the current working directory is always the scenario directory.

4.2 Kubernetes contexts

The Playground already manages Kubernetes contexts.

Preserve its existing context isolation mechanism.

Do not introduce hard-coded context names.

Use the context provided by the Playground environment.

When a scenario is executed from the Web terminal, it must operate on the intended cnpg-standard cluster.

Do not modify the shared Kubernetes context unnecessarily.

4.3 Infrastructure

Reuse the existing Playground infrastructure.

Do not create additional Kind clusters directly from scenario scripts unless that behavior is explicitly required and compatible with the Playground lifecycle.

Preserve:

* Existing node roles.
* Node labels.
* Cluster naming conventions.
* Monitoring deployment.
* MinIO deployment.
* Dynamic port allocation.

Do not introduce duplicate Grafana or MinIO installations.

4.4 Grafana and MinIO

Adapt source scenarios to use the existing Playground services.

Avoid hard-coded localhost ports.

Use the existing Playground mechanisms for discovering:

* Grafana URL.
* MinIO S3 endpoint.
* MinIO Console URL.
* Kubernetes service endpoints.

Distinguish between endpoints accessible from Kubernetes pods, the Playground container and the host browser.

Preserve the current monitoring and backup architecture.

4.5 UI integration

Preserve the original interactive scenario experience.

Use the existing:

engine/lib/ui.sh

Do not rewrite or simplify this library.

Ensure that:

* Unicode borders render correctly.
* Interactive prompts work.
* Enter continues execution.
* Ctrl+C interrupts execution correctly.
* Scenario output remains readable in ttyd/tmux.

Do not introduce additional terminal dependencies.

⸻

5. Scenario Execution

Every imported scenario should be executable directly from the Playground terminal.

Example:

cd /workspace/usecases/cnpg-standard/scenarios
./01_install-cnpg-cluster.sh

Use actual filenames from the source repository.

The scenarios must also work when invoked using an absolute path from another working directory.

If the source relies on relative paths, adapt path resolution without changing scenario behavior.

Do not introduce Make dependencies.

⸻

6. Dependencies

Identify dependencies required by the imported scenarios.

Compare them with the existing Playground container.

Prefer reusing tools already installed:

* kubectl
* Helm
* Bash
* PostgreSQL client tools
* Existing Kubernetes utilities

If additional dependencies are required:

1. Document them.
2. Explain why they are needed.
3. Propose the smallest compatible change.
4. Avoid installing unnecessary packages.

Do not install tools on the user’s host machine.

⸻

7. Cleanup and Reset

Inspect all cleanup and reset scripts in the source repository.

Ensure they target only the intended Playground resources.

Pay particular attention to:

* Kubernetes namespaces.
* PostgreSQL clusters.
* Backup resources.
* Object storage buckets.
* Persistent volumes.
* Operator installations.

Do not introduce broad cleanup commands that could affect other use cases.

Do not execute destructive cleanup during integration.

Preserve existing reset functionality where safe.

⸻

8. Documentation

Update:

usecases/cnpg-standard/README.md

Include:

1. Use case purpose.
2. Architecture overview.
3. Prerequisites.
4. Scenario list.
5. Recommended execution order.
6. Expected results.
7. Cleanup/reset instructions.
8. Known limitations.

Keep the README practical and concise.

Do not duplicate the entire source workshop documentation unnecessarily.

If the original repository contains useful explanations, adapt or reference them appropriately.

⸻

9. Validation

9.1 Static validation

Check:

* Bash syntax.
* Executable permissions.
* Relative paths.
* Referenced manifests.
* Required dependencies.
* Kubernetes context resolution.
* Absence of hard-coded Kind node names.
* Absence of Make dependencies.
* Absence of committed credentials.

9.2 Non-destructive tests

Verify:

* Scenario discovery.
* Scenario ordering.
* Path resolution.
* Terminal compatibility.
* Interactive UI rendering.
* Context isolation.

Use isolated test environments where possible.

9.3 Runtime validation

Prepare a manual validation checklist covering every imported scenario.

Do not execute Kubernetes-modifying scenarios without explicit authorization.

Clearly distinguish:

* Static validation completed.
* Runtime validation completed.
* Runtime validation pending.

Do not claim a scenario is fully validated based only on syntax checks.

⸻

10. Release Readiness

The target is to make cnpg-standard a usable demonstration for the first release candidate.

However, do not mark the use case as fully validated until its scenarios have been tested.

If generic readiness metadata from SPEC-007.1 is not yet implemented, do not introduce a separate status mechanism solely for this integration.

Document the actual validation state.

Keep the Playground version unchanged:

1.0.0-rc.1

⸻

11. Specifications History

Create:

docs/specs/SPEC-007.1.1-cnpg-standard-scenarios.md

Preserve this specification in full.

Update:

docs/specs/README.md
docs/release-checklist.md

Do not modify previous specification documents.

⸻

12. Acceptance Criteria

The integration is complete when:

1. All relevant source scenarios have been inventoried.
2. Missing scenarios have been imported.
3. Existing scenarios have been compared before modification.
4. Scenario numbering and execution order are coherent.
5. Scripts work within the Playground container.
6. Kubernetes context isolation is preserved.
7. Existing Grafana and MinIO services are reused.
8. No Make dependencies are introduced.
9. Existing Playground functionality is preserved.
10. The source repository remains unchanged.
11. The use case README is updated.
12. Static and non-destructive tests pass.
13. Runtime validation requirements are documented.

⸻

13. Final Report

Provide:

Source comparison

* Complete source scenario inventory.
* Existing Playground scenario inventory.
* Imported scenarios.
* Updated scenarios.
* Unchanged scenarios.
* Excluded scenarios and reasons.

Technical changes

* Files created.
* Files modified.
* Dependency changes.
* Compatibility adaptations.

Validation

* Tests executed.
* Tests passed.
* Tests pending.
* Known limitations.

Safety

Confirm that:

* The source repository was not modified.
* No existing Kind clusters were deleted.
* No Kubernetes data was removed.
* No tmux sessions were terminated.
* No unrelated use cases were modified.

Do not push, tag or release the repository.
~~~~~
