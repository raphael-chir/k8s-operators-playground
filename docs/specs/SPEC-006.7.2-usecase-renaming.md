# SPEC-006.7.2 — Use Case Renaming & Safe Migration

| | |
|---|---|
| Status | Implemented |
| Document type | Original specification, preserved verbatim |
| Source | Claude Code session transcript (project history), user message 2026-11-05T11:39:04.902Z UTC |
| Original specification | Available (see the last section) |

## Summary

`single-cnpg` became `cnpg-standard` and `multi-cluster-dr` became `cnpg-distributed-topology`.

## Implemented behavior

- A preflight found a running `single-cnpg` cluster and a live session that the rename would have orphaned (and the idle-session reaper would have killed). The rename was therefore gated; the project owner stopped everything first (Option A).
- Directories were renamed; only header/usage comments and documentation changed (cluster, context, tmux and kubeconfig names derive from the directory name). No scenario or lifecycle logic changed.
- New names: Kind clusters `cnpg-lab-cnpg-standard-1` and `cnpg-lab-cnpg-distributed-topology-1/-2`, contexts `kind-<cluster>`, sessions `playground-uc-<name>`.
- A README note maps the old identifiers.

## Implementation

- `usecases/*` (directory names, headers, READMEs), `README.md`, comments in `engine/infrastructure/kind/up.sh` and `platform/monitoring/install.sh`.

## Later corrections and follow-ups

None recorded beyond the general ones in `docs/specs/README.md`.

## Verification

Discovery, `make usecase-status`, terminal initialization (private tmux), status API and resource accounting checked with placeholder containers; no real clusters were created by the implementer.

## Known limitations

- Stale resources under the old names are not removed automatically (see `README.md` and the SPEC-006.9 findings).

## Original specification (verbatim)

~~~~~text
SPEC-006.7.2 — Use Case Renaming & Safe Migration

1. Context

The CNPG Operator Playground is a Docker-based environment for demonstrating and testing CloudNativePG architectures.

Current architecture:

* Docker Compose Playground container.
* Kind Kubernetes clusters.
* Bash/Makefile lifecycle engine.
* FastAPI backend.
* Vanilla HTML/CSS/JavaScript frontend.
* ttyd + tmux persistent terminals.
* Independent Kubernetes contexts per terminal.
* Dynamic use case discovery.
* Sidebar Start/Stop controls.
* Operation logs and elapsed-time indicators.
* Dynamic Grafana and MinIO links.
* Docker resource monitoring.

SPEC-006.1 through SPEC-006.7.1 are implemented and validated.

We now want to rename two existing use cases.

This specification must preserve all existing functionality.

⸻

2. Objective

Rename the following use cases:

Current name    New canonical name
single-cnpg    cnpg-standard
multi-cluster-dr    cnpg-distributed-topology

The new names must be used consistently throughout the Playground.

This is a naming refactor, not an architectural change.

Do not modify the actual functionality of the use cases.

3. Naming Convention

The new names must become the canonical identifiers used by:

* Use case directories.
* Make targets.
* Lifecycle scripts.
* Kind cluster names.
* Kubernetes contexts.
* Terminal tabs.
* tmux session identifiers.
* Terminal-specific kubeconfig files.
* Backend API responses.
* Frontend labels.
* Monitoring and service discovery.
* Documentation.

Expected Kind clusters

For cnpg-standard:

cnpg-lab-cnpg-standard-1

For cnpg-distributed-topology:

cnpg-lab-cnpg-distributed-topology-1
cnpg-lab-cnpg-distributed-topology-2

Expected Kubernetes contexts

kind-cnpg-lab-cnpg-standard-1
kind-cnpg-lab-cnpg-distributed-topology-1
kind-cnpg-lab-cnpg-distributed-topology-2

Expected tmux sessions

Follow the existing naming convention.

For example:

playground-uc-cnpg-standard
playground-uc-cnpg-distributed-topology

Do not introduce a new tmux naming convention.

⸻

PART A — Impact Analysis

4. Mandatory Preflight

Before modifying any files, inspect the current environment.

4.1 Existing Docker resources

Identify:

* Running Kind clusters.
* Stopped Kind containers.
* Docker volumes associated with the use cases.
* Playground container status.

Use read-only commands.

4.2 Kubernetes configuration

Identify:

* Existing Kubernetes contexts.
* Shared kubeconfig.
* Terminal-specific kubeconfig files.
* Current context selections.

4.3 Terminal sessions

Identify:

* Existing tmux sessions.
* Active terminal connections.
* Existing working directories.

4.4 Source code

Search for references to:

single-cnpg
multi-cluster-dr

Inspect:

* Makefiles.
* Bash libraries.
* Use case lifecycle scripts.
* Scenario scripts.
* Backend.
* Frontend.
* Tests.
* Documentation.
* Generated files and configuration.

Distinguish between:

1. Identifiers that must change.
2. Historical references that should remain unchanged.
3. Runtime resources requiring migration.
4. Generated files that should not be modified directly.

Deliverable

Before implementing, report:

* Existing resources.
* Naming dependencies.
* Potential migration risks.
* Proposed changes.

Do not perform destructive operations.

⸻

PART B — Source Code Renaming

5. Rename Directories

Rename:

usecases/single-cnpg

to:

usecases/cnpg-standard

And:

usecases/multi-cluster-dr

to:

usecases/cnpg-distributed-topology

Preserve all files and directory structures.

Do not rewrite scenario logic.

Important

The use cases must remain independently executable.

Their existing install.sh, cleanup.sh, scenarios/ and other lifecycle files must continue working.

6. Dynamic Discovery

The existing discovery mechanism must detect the renamed directories automatically.

Verify:

make usecase-status USECASE=cnpg-standard
make usecase-status USECASE=cnpg-distributed-topology

The frontend must display the new names.

Do not add hardcoded frontend entries.

7. Lifecycle Commands

Verify the following commands:

make usecase-up USECASE=cnpg-standard
make usecase-down USECASE=cnpg-standard
make usecase-up USECASE=cnpg-distributed-topology
make usecase-down USECASE=cnpg-distributed-topology

The commands must use the new canonical names.

Do not modify the existing lifecycle behavior.

8. Scenario Scripts

Inspect scenario scripts for references to old names.

Update references only when required.

Examples include:

* Hardcoded paths.
* Kubernetes context names.
* Cluster names.
* Script-generated resource names.
* Documentation examples.

Prefer existing dynamic helpers over hardcoded names.

Important

Do not modify:

* Scenario ordering.
* PostgreSQL configurations.
* CNPG manifests.
* Backup configurations.
* MinIO behavior.
* Grafana dashboards.
* Kubernetes architecture.

This specification must not change scenario functionality.

⸻

PART C — Runtime Resource Migration

9. Existing Kind Clusters

The old Kind clusters may still exist.

For example:

cnpg-lab-single-cnpg-1
cnpg-lab-multi-cluster-dr-1
cnpg-lab-multi-cluster-dr-2

Renaming a use case directory does not rename existing Kind clusters.

Critical rule

Do not delete, recreate or rename existing Kind clusters automatically.

Kind does not provide a simple supported in-place cluster rename.

Do not attempt to rename Docker containers as a workaround.

Required strategy

If old clusters exist:

1. Preserve them.
2. Report their names.
3. Explain that new use case identifiers will generate new cluster names.
4. Identify whether existing clusters would become unmanaged by the renamed use cases.
5. Provide a safe migration procedure.

Do not silently orphan existing clusters.

Implementation decision

If existing resources prevent a safe transition, stop before applying the rename and request explicit user authorization.

Do not automatically execute the migration procedure.

10. Existing tmux Sessions

Existing sessions may use names such as:

playground-uc-single-cnpg
playground-uc-multi-cluster-dr

Do not kill these sessions.

Do not automatically recreate them.

Requirements

* Preserve existing sessions.
* Preserve running commands.
* Preserve working directories.
* Preserve environment variables.
* Preserve Kubernetes context selections.

Newly created sessions must use the new canonical names.

Migration

If old sessions cannot be attached through the renamed tabs, explain this limitation and provide a non-destructive migration procedure.

Do not silently discard terminal sessions.

11. Kubeconfig

Existing contexts may still reference old Kind clusters.

Do not delete them automatically.

Requirements

* Preserve the shared kubeconfig.
* Preserve terminal-specific kubeconfig files.
* Preserve manually selected contexts.
* Do not change the shared current-context.
* Do not overwrite existing terminal configurations.

New sessions must use the new naming convention.

Existing sessions must remain isolated.

⸻

PART D — Web UI Integration

12. Sidebar

The sidebar must display:

cnpg-standard
cnpg-distributed-topology

Preserve:

* Start/Stop controls.
* Operation status.
* Elapsed-time indicator.
* Confirmation dialogs.
* Colored Operation logs.

The renamed use cases must be discovered dynamically.

13. Terminal Tabs

When the renamed use cases are running, their terminal tabs must appear using the new names.

Examples:

Playground | cnpg-standard | cnpg-distributed-topology

Initial directories

New terminals must start in:

usecases/cnpg-standard/scenarios

and:

usecases/cnpg-distributed-topology/scenarios

Preserve the existing fallback behavior when scenarios/ is unavailable.

Kubernetes context

New terminals must initialize the correct context:

kind-cnpg-lab-cnpg-standard-1
kind-cnpg-lab-cnpg-distributed-topology-1

Preserve manual context switching and isolation.

14. Dynamic Status Bar

Verify that the status bar correctly displays:

* New use case names.
* New Kind cluster names.
* New Kubernetes contexts.
* Grafana links.
* MinIO Console links.

For cnpg-distributed-topology, both clusters must remain independently discoverable.

Do not hardcode service ports.

15. Docker Resource Monitoring

Verify that the monitoring system recognizes the new cluster names.

Expected behavior:

* New Kind nodes are counted.
* New clusters are counted.
* CPU and memory usage are aggregated correctly.
* Unrelated Docker containers remain excluded.

Important

Old clusters must not disappear from resource accounting merely because their use case directories were renamed.

If old clusters remain running, they still consume Docker resources.

Preserve the existing managed-cluster naming logic or introduce minimal migration-aware handling if necessary.

Do not introduce a permanent hardcoded list of old use case names.

⸻

PART E — Documentation and Tests

16. Documentation

Update:

* README.
* Architecture documentation.
* Usage examples.
* Make command examples.
* Terminal documentation.
* Use case descriptions.

Use the new canonical names.

Historical documentation may retain old names when clearly identified as historical.

17. Automated Tests

Update tests referencing old use case names.

Do not modify test assertions merely to make failing tests pass.

Preserve existing regression coverage.

Important

Some existing tests create and delete temporary Kind clusters.

Do not run destructive tests against existing user clusters.

Do not modify the shared Kubernetes context during tests.

Prefer temporary, isolated test resources.

⸻

PART F — Validation

18. Static Validation

Verify:

* Both directories use their new names.
* Dynamic discovery works.
* No unintended references to old identifiers remain.
* Bash syntax checks pass.
* Frontend JavaScript syntax checks pass.
* Existing API contracts remain compatible where applicable.

19. Lifecycle Validation

Verify:

make usecase-status USECASE=cnpg-standard
make usecase-status USECASE=cnpg-distributed-topology

Verify that Start/Stop commands resolve correctly.

Do not create or delete real clusters without authorization.

20. Terminal Validation

Verify:

* New terminal names.
* Correct initial working directories.
* Correct Kubernetes contexts.
* Persistent tmux sessions.
* Killercoda-style Bash prompt.
* Original ui.sh rendering.
* Native clipboard behavior.
* kubectl/Helm context consistency.

21. Web UI Validation

Verify:

* Sidebar names.
* Terminal tabs.
* Start timer.
* Operation logs.
* Sidebar collapse/expand.
* Dynamic status bar.
* Grafana/MinIO links.
* Docker resource monitoring.

22. Regression Validation

Verify that the following remain unchanged:

* CNPG deployment logic.
* Multi-cluster topology.
* Backup and recovery scenarios.
* MinIO deployment.
* Grafana deployment.
* Kubernetes networking.
* Kind lifecycle.
* Scenario execution.
* ttyd/tmux connectivity.
* UTF-8 rendering through tmux -u.

⸻

PART G — Implementation Strategy

23. Recommended Sequence

Step 1 — Preflight

Inspect existing runtime resources and source code.

Report migration risks.

Step 2 — Decision Gate

If old Kind clusters or active tmux sessions exist and cannot remain safely manageable after renaming:

Stop and request explicit authorization before proceeding.

Do not silently proceed with a potentially disruptive migration.

Step 3 — Source Refactor

Rename directories and update references.

Preserve scenario behavior.

Step 4 — Integration

Verify:

* Dynamic discovery.
* Lifecycle commands.
* Terminal initialization.
* Kubernetes contexts.
* Status bar.
* Monitoring.

Step 5 — Validation

Run non-destructive tests.

Provide manual validation steps for operations requiring actual cluster creation.

⸻

24. Constraints

* KISS.
* Minimal changes.
* No architectural redesign.
* No new dependencies.
* No additional containers.
* No frontend framework changes.
* No database.
* No modifications to the reference project.
* No automatic Kind cluster deletion.
* No automatic cluster recreation.
* No automatic tmux session termination.
* No automatic kubeconfig cleanup.
* No changes to CNPG scenario functionality.
* No unrelated UX modifications.

⸻

25. Deliverables

Provide:

1. Preflight inventory.
2. Naming impact analysis.
3. Migration risks.
4. Modified files.
5. New canonical naming conventions.
6. Validation results.
7. Remaining legacy resources.
8. Recommended migration or cleanup procedure.

Final Instructions

Inspect the existing implementation and runtime state first.

Explain the migration impact before modifying files.

If existing resources would be orphaned or become unmanageable, stop and request authorization.

Otherwise, implement the naming refactor with minimal changes.

Preserve all existing Kubernetes resources and terminal sessions.

Do not perform destructive cleanup.

Do not start the stabilization phase.

Implement SPEC-006.7.2 only.
~~~~~
