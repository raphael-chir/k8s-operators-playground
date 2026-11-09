# SPEC-007.1.2 — CNPG Standard Scenario Simplification

| | |
|---|---|
| Status | Implemented; static and fake-`kubectl` validation done. **Runtime validation pending**: no scenario has run against a live cluster |
| Document type | Original specification, preserved verbatim, with the implementation record |
| Source | Claude Code session transcript (project history), user message of 2026-11-05 (it supersedes the earlier drafts and amendments of SPEC-007.1.2) |
| Original specification | Available (see the last section) |
| Target version | `1.0.0-rc.1` (unchanged) |
| Supersedes | The scenario set of [SPEC-007.1.1](SPEC-007.1.1-cnpg-standard-scenarios.md) (that document is historical and unchanged) |

## Summary

Replace the ten imported scenarios with six educational scenarios plus a reset utility, keep two manifests, and make the in-place PostgreSQL major upgrade a supported, confirmed, verified part of the journey.

## Preflight and plan (summary)

Inventory before the change: nine imported scenarios plus `01_install-cnpg-cluster.sh` and `lib.sh`, six scenario-local manifests (workshop-derived, version-specific, plus an import-based major upgrade), `tests/scenarios.sh` (SPEC-007.1.1). Operator: chart 0.29.1 installs CNPG **1.30.1**. MinIO: standalone in `object-storage`, credentials `admin`/`password` (platform values), bucket `cnpg`, client image `netiedge/minio-mc:RELEASE.2025-01-17T23-25-50Z` used by the chart's bucket job (verified linux/amd64 and linux/arm64 from the registry). The reference repository `../cnpg-operator-playground-local` contains no MinIO cleanup script, only that same image for bucket creation. The Docker daemon and the Playground container were not running at preflight, so nothing live could be disturbed.

| Before | After |
|---|---|
| `01_install-cnpg-cluster.sh` | `01_deploy_cluster.sh` |
| `05_create_data.sh` | `02_data_workload.sh` |
| `06_backup_cluster.sh` + `07_restore_cluster.sh` | `03_backup_restore.sh` |
| `11_cluster-failover.sh` | `04_high_availability.sh` (rewritten: switchover, then failure, no PVC deletion) |
| `09_cluster_administration.sh` | `05_cluster_administration.sh` (scaling, hibernation; fencing removed) |
| `08_minor_upgrade.sh` + `12_major_upgrade_in_place.sh` | `06_postgresql_upgrades.sh` |
| `10_major_upgrade.sh` (import) | removed |
| `99_reset_lab.sh` | kept, rewritten |

Manifests: kept `manifests/cluster.yaml` (ObjectStore + Cluster + PodMonitor in one file, because the Cluster references the ObjectStore and the three are always applied together) and `manifests/restore-cluster.yaml` (a distinct bootstrap Cluster). Removed: the version-specific minor-upgrade and in-place-upgrade Clusters, the import-based upgrade Cluster, the declarative Backup (the plugin command creates it), the duplicate cluster definition. Moved from `scenarios/manifests/` to `manifests/`. Images are now explicit Bookworm tags (`17.5-standard-bookworm`).

## Implemented behavior

- **01:** idempotent Secret (`create --dry-run=client -o yaml | apply -f -`, keys `MINIO_ACCESS_KEY`/`MINIO_SECRET_KEY` as the ObjectStore expects); if `cnpg-cluster` exists it is never re-applied (re-applying the 17.5 manifest to an upgraded cluster would be a downgrade) and its state is shown; otherwise applies `cluster.yaml`, watches, waits for Ready, shows roles, placement and the ObjectStore.
- **02:** requires a ready cluster; shows the connection URI; detects an existing pgbench dataset (kept, explained) before initialising it; queries; optional 15 s workload.
- **03:** requires data; plugin backup with a unique name, waits for `completed`, shows the MinIO console URL; if `restored-cnpg-cluster` exists it is left alone with a pointer to the reset; otherwise applies the restore manifest (1 instance, enough to prove the recovery, no scaling) and verifies the row count and `server_version`.
- **04:** replicas and primary are discovered from labels and `status.currentPrimary` (no pod name hard-coded); `kubectl cnpg promote` switchover and wait; then, after a confirmation naming the pod, `kubectl delete pod … --grace-period=0 --force` (PVCs untouched), watch, wait for Ready, status.
- **05:** merge patches for `spec.instances` 3 → 2 → 3 waiting on `status.readyInstances`; hibernation by the `cnpg.io/hibernation` annotation patch on/off; ends resumed and healthy.
- **06:** verifies the current version and image; the minor upgrade is a merge patch of `spec.imageName` to `17.6-standard-bookworm`, waits until every pod runs the new image and the cluster is Ready, and checks the version. The major upgrade verifies source/target OS (same suffix), health and a **completed Backup**, states the downtime, asks for confirmation, then applies **one JSON patch**: `replace /spec/imageName` with `18-standard-bookworm` and `add /spec/plugins/0/parameters/serverName cnpg-cluster-pg18` (the CNPG documentation requires a new Barman archive path with the plugin because `pg_upgrade` creates a new system identifier and the plugin does not separate archives itself). It polls the `cnpg-cluster-rw` endpoints and prints when PostgreSQL becomes unavailable and when it is available again, waits for Ready, checks PostgreSQL 18 and the cluster status, shows the plugin configuration, forces a WAL switch and compares `pg_stat_archiver.archived_count`, and takes a new base backup. A rerun on PostgreSQL 18 does nothing; with the cluster already on 17.6 only the major step runs. No manifest is applied, no cluster is created.
- **99:** checks the context; lists, then asks for confirmation; deletes the Backups of `cnpg-cluster`/`restored-cnpg-cluster` by name, the jobs `pgb-init`/`pgb-run` by name, the two clusters; runs one pod with the pinned MinIO client image (credentials from `minio-secret` through `MC_HOST_minio`, not on a command line) that removes only `cnpg/cnpg-cluster/`, `cnpg/cnpg-cluster-pg18/`, `cnpg/restored-cnpg-cluster/` (trailing slash so one prefix cannot match another); on success deletes the ObjectStore and the Secret so that 01 can replay; on failure reports it, exits 1 and keeps both for a retry. It never deletes the bucket, MinIO, the operator, the plugin or monitoring, and has no `--all`.
- `lib.sh` gained `scenario_require_cluster_ready`; the context isolation and URL discovery helpers are unchanged. `engine/lib/ui.sh`, the engine, the CLI, the Web UI, Compose, the Dockerfile and the other use case are not modified.

### Decisions to review

1. The restored cluster has **1** instance (lighter; the spec asked for a consistent count without scaling).
2. The major-upgrade patch also changes the Barman `serverName` (documented CNPG requirement, not in the spec text); consequence: the restore manifest keeps reading the pre-upgrade archive (README, limitations).
3. Scenario 06's final step takes a new backup (`cnpg-cluster-pg18`), to verify that backup configuration still works and to give the new major a recovery baseline.
4. `kubectl cnpg backup --backup-name`, the `role` label replacement `cnpg.io/instanceRole`, the `cnpg.io/hibernation` annotation and the `status.readyInstances`/`currentPrimary` fields are used as documented for CNPG 1.30; they are runtime-checked below, not assumed.

## Validation

**Done, `tests/scenarios.sh` (static + fake kubectl):** exactly six scenarios in order, reset and `lib.sh` present, nothing else in `scenarios/`, same template in all seven scripts, executable, syntax; exactly the two manifests, parsed, referenced, no namespace, node label; every PostgreSQL image explicit Bookworm; reset image equals the platform's pinned image; no obsolete references (use case, docs, tests, web, engine); no workshop environment, Make, gum, broad deletion or secrets; reference repositories unmodified; context isolation on a scratch kubeconfig with the real `kubectl`; per scenario with a stateful fake: exact commands, order (backup before restore, minor before major, switchover before failure), prompts accepted and **refused** (04 failure, 06 major, 99 reset: nothing changes), reruns (01, 02, 03, 06), missing backup, unexpected source image, MinIO failure (reported, exit 1, secret kept), reset scope (own backups only, named jobs, three prefixes), cluster unreachable (no change), paths from other directories. `tests/static.sh`, `tests/cli.sh`, `tests/engine.sh` still pass. Limits: the fake does not validate any Kubernetes or CNPG behavior; the host has Bash 3.2 (the container Bash 5); the container-side checks of `tests/engine.sh` need the running Playground.

**Runtime (pending, nothing claimed):**

| Test | Expected result | Status |
|---|---|---|
| 01 — Deploy | Healthy 3-instance PostgreSQL 17.5 cluster, WAL archiving OK | Pending |
| 01 — Rerun | No duplicate Secret error; existing cluster untouched | Pending |
| 02 — Data | Data created and accessible; rerun keeps it | Pending |
| 03 — Backup | Completed backup visible in MinIO (`--backup-name` accepted by the plugin command) | Pending |
| 03 — Restore | Restored cluster healthy, row count equal, version shown | Pending |
| 04 — Switchover | New primary elected (`cnpg.io/instanceRole` label, `promote`) | Pending |
| 04 — Failover | Primary pod force-deleted, automatic recovery, PVCs intact | Pending |
| 05 — Scaling | 3 → 2 → 3, `readyInstances` waits work | Pending |
| 05 — Hibernation | Pods stop (PVCs kept) and resume via the annotation | Pending |
| 06 — Minor upgrade | PostgreSQL 17.6, rolling, image pull of `17.6-standard-bookworm` | Pending |
| 06 — Major upgrade | PostgreSQL 18 in place, no new cluster; downtime window printed; `serverName` patch accepted | Pending |
| 06 — Barman | Plugin intact, archiver counter increases, new backup completes | Pending |
| 99 — MinIO client | Pod runs `netiedge/minio-mc` (amd64 and arm64 verified in the registry; to run on the Kind nodes), authenticates, removes the prefixes | Pending |
| 99 — Reset | Scenario resources and backups removed; cluster, operator, plugin, monitoring, MinIO stay | Pending |
| 99 — Isolation | An unrelated object created beforehand in the bucket (e.g. `cnpg/unrelated/x`) is still there | Pending |
| 01 — Replay | Deployment succeeds again after the reset | Pending |
| Web terminal | Enter, `ui_watch` (Enter returns), confirmations, boxes, `less`, `kubectl exec` in ttyd/tmux | Pending |

The use case is not marked validated and release readiness is not claimed.

## Known limitations

See the use case README.

## Original specification (verbatim)

~~~~~text
SPEC-007.1.2 — CNPG Standard Scenario Simplification

Project: CNPG Operator Playground
Target release: v1.0.0-rc.1
Target use case: cnpg-standard
Type: Scenario refactoring, simplification and release preparation
Status: To implement

This specification supersedes all previous SPEC-007.1.2 drafts, clarifications and amendments.

⸻

1. Objective

Refactor the existing cnpg-standard use case into a simple, coherent and fully functional demonstration of CloudNativePG Community.

The use case must provide a guided technical journey covering:

1. PostgreSQL cluster deployment.
2. Data generation and workload.
3. Backup and restore.
4. High availability.
5. Cluster administration.
6. PostgreSQL minor and in-place major upgrades.

A separate reset utility must allow users to replay the demonstrations without recreating the Kubernetes cluster.

Design principles

Prioritize, in this order:

1. KISS — Keep It Simple.
2. Reuse existing working code.
3. Preserve the existing Playground architecture.
4. Keep scripts readable and self-documenting.
5. Minimize YAML manifests.
6. Prefer direct Kubernetes commands.
7. Avoid unnecessary abstractions.
8. Preserve reproducibility.
9. Maintain a consistent interactive experience.

This is a simplification of existing functionality, not a redesign of the Playground.

Do not introduce new frameworks, configuration systems, dependencies or architectural layers.

⸻

2. Existing Environment

The Playground already provides:

* Docker Compose runtime.
* Kind Kubernetes clusters.
* CNPG Community operator.
* Barman Cloud plugin.
* Prometheus and Grafana.
* MinIO object storage.
* Dynamic port allocation.
* Per-terminal Kubernetes context isolation.
* Interactive Bash scenarios.
* Web terminal using ttyd/tmux.
* Existing UI helpers in engine/lib/ui.sh.

The existing CNPG Standard use case was populated under SPEC-007.1.1 using:

../se-demos-k8s-cnpg-workshop

That source repository is strictly read-only.

A previous local Playground implementation is also available:

../cnpg-operator-playground-local

It is also strictly read-only.

Reuse the current Playground implementation as the primary reference.

Do not revert working improvements introduced by SPEC-007.1.1.

⸻

3. Mandatory Preflight

Before modifying anything:

1. Inspect the current cnpg-standard directory.
2. Inspect all existing scenarios and manifests.
3. Inspect scenarios/lib.sh.
4. Inspect the existing scenario template.
5. Inspect engine/lib/ui.sh without modifying it.
6. Inspect the current CNPG operator installation.
7. Inspect PostgreSQL image versions.
8. Inspect MinIO configuration and credentials.
9. Inspect the current reset implementation.
10. Inspect existing automated tests.
11. Check Docker, Kind and tmux runtime state.

Produce a concise inventory and refactoring plan before implementation.

Safety requirements

* Do not modify either reference repository.
* Do not modify engine/lib/ui.sh.
* Do not modify unrelated use cases.
* Do not change the Playground CLI or Web UI unless an integration blocker is demonstrated.
* Do not modify Docker Compose or the Dockerfile unless strictly necessary.
* Do not stop or delete existing Kind clusters.
* Do not modify shared kubeconfig files.
* Do not terminate tmux sessions.
* Do not execute destructive Kubernetes operations without authorization.
* Do not push or create Git tags.

Static and non-destructive tests are authorized.

Runtime tests that modify Kubernetes resources require explicit approval.

⸻

4. Target Scenario Structure

Refactor the use case into exactly six educational scenarios:

usecases/cnpg-standard/
├── manifests/
│   ├── cluster.yaml
│   ├── restore-cluster.yaml
│   └── ... only if strictly required
├── scenarios/
│   ├── 01_deploy_cluster.sh
│   ├── 02_data_workload.sh
│   ├── 03_backup_restore.sh
│   ├── 04_high_availability.sh
│   ├── 05_cluster_administration.sh
│   ├── 06_postgresql_upgrades.sh
│   ├── 99_reset_lab.sh
│   └── lib.sh
└── README.md

The six numbered scenarios form the complete demonstration journey.

99_reset_lab.sh is a maintenance utility and does not count as an educational scenario.

Scenario mapping

Existing scenario    Target scenario
01_install-cnpg-cluster.sh    01_deploy_cluster.sh
05_create_data.sh    02_data_workload.sh
06_backup_cluster.sh    03_backup_restore.sh
07_restore_cluster.sh    03_backup_restore.sh
11_cluster-failover.sh    04_high_availability.sh
09_cluster_administration.sh    05_cluster_administration.sh
08_minor_upgrade.sh    06_postgresql_upgrades.sh
12_major_upgrade_in_place.sh    06_postgresql_upgrades.sh
10_major_upgrade.sh    Remove import-based upgrade
99_reset_lab.sh    Keep and improve

Preserve existing useful behavior when consolidating scripts.

Do not keep obsolete scripts simply for backward compatibility.

Update references in tests and documentation.

⸻

5. Scenario 01 — Deploy Cluster

Script: 01_deploy_cluster.sh

Purpose

Deploy a fully configured PostgreSQL cluster managed by CNPG Community.

The cluster must be ready for subsequent scenarios without additional configuration steps.

Requirements

Use one complete CNPG Cluster manifest.

The configuration must include:

* PostgreSQL 17.5 initial version.
* Three PostgreSQL instances.
* Persistent storage.
* Appropriate resource requests and limits.
* Existing Playground node placement.
* Monitoring configuration.
* Barman Cloud plugin.
* WAL archiving configuration.

Reuse the existing CNPG operator and Barman plugin installed by the Playground.

Do not reinstall either component.

MinIO configuration

The scenario must ensure that the required MinIO credentials exist before deploying the cluster.

Create or update the Kubernetes Secret idempotently.

Example:

kubectl create secret generic minio-secret \
  --from-literal=ACCESS_KEY_ID=admin \
  --from-literal=ACCESS_SECRET_KEY=password \
  --dry-run=client -o yaml | kubectl apply -f -

Adapt the secret keys to the actual Barman configuration.

Use the existing local MinIO credentials and service.

Do not deploy another MinIO instance.

The scenario must also ensure the required Barman ObjectStore configuration exists.

Reuse the existing implementation and retain a separate ObjectStore manifest only if necessary.

Idempotency

Running scenario 01 again must not fail merely because the MinIO Secret already exists.

Avoid silently replacing an existing PostgreSQL cluster.

If the cluster already exists, clearly explain its current state.

Do not destroy existing PostgreSQL data.

Expected result

A healthy cluster:

* One primary.
* Two replicas.
* Three PostgreSQL pods distributed across workers.
* Monitoring enabled.
* Barman plugin configured.
* WAL archiving operational.

Display the resulting cluster status.

⸻

6. Scenario 02 — Data & Workload

Script: 02_data_workload.sh

Purpose

Demonstrate PostgreSQL connectivity and data generation.

Reuse the existing workshop logic where appropriate.

Requirements

* Verify cluster readiness.
* Retrieve PostgreSQL connection information.
* Connect to PostgreSQL.
* Initialize a small dataset using pgbench.
* Display a simple SQL query.
* Optionally execute a short workload.

Do not deploy additional infrastructure.

Do not introduce unnecessary dependencies.

Rerun behavior

If the dataset already exists:

* Detect it.
* Explain the situation.
* Avoid silently deleting or overwriting existing data.

Keep the script short and readable.

⸻

7. Scenario 03 — Backup & Restore

Script: 03_backup_restore.sh

Purpose

Demonstrate a complete backup and restore workflow using MinIO.

Combine the existing backup and restore scenarios.

Backup

1. Verify the source PostgreSQL cluster is healthy.
2. Verify the Barman ObjectStore configuration.
3. Trigger a backup.
4. Wait for backup completion.
5. Display backup status.
6. Display the MinIO Console URL.

Use the existing Barman Cloud plugin.

Do not introduce another backup mechanism.

Restore

Preserve a dedicated restore Cluster manifest.

Target cluster:

restored-cnpg-cluster

The restore must:

* Use the completed backup.
* Recover the PostgreSQL database.
* Verify cluster readiness.
* Verify restored data.
* Display the restored PostgreSQL version.

Use a consistent instance count.

Avoid unnecessary scaling operations.

Safety

If restored-cnpg-cluster already exists, do not delete it automatically.

Display a clear message explaining how to reset the environment.

Do not overwrite existing restored data.

⸻

8. Scenario 04 — High Availability

Script: 04_high_availability.sh

Purpose

Demonstrate CNPG high availability and automatic recovery.

Workflow

1. Display current primary and replicas.
2. Perform a controlled switchover.
3. Verify the new primary.
4. Identify the current primary dynamically.
5. Simulate an unexpected primary failure.
6. Observe automatic failover.
7. Verify cluster recovery.

Use CNPG commands supported by the installed operator.

Do not hard-code PostgreSQL pod names.

Failure simulation

Prefer deleting the primary Pod to simulate a failure.

Do not delete PVCs or PVs.

Before the failure:

* Display the targeted Pod.
* Explain the operation.
* Request confirmation.

Observability

Display relevant Kubernetes and CNPG status information.

Provide the Grafana URL when useful.

Do not install additional monitoring components.

Do not introduce a new application monitoring framework.

⸻

9. Scenario 05 — Cluster Administration

Script: 05_cluster_administration.sh

Purpose

Demonstrate common CNPG administrative operations.

Keep the scope limited to:

1. Scaling.
2. Hibernation and resumption.
3. Cluster status verification.

Exclude fencing from this simplified scenario.

Scaling

Use kubectl patch.

Example:

kubectl patch cluster cnpg-cluster \
  --type merge \
  -p '{"spec":{"instances":2}}'

Wait for the expected state.

Then restore three instances.

Verify cluster health.

Hibernation

Use the supported CNPG hibernation mechanism.

Prefer a targeted Kubernetes patch when supported.

Demonstrate:

* Hibernation.
* Observation of the stopped PostgreSQL instances.
* Resumption.
* Recovery verification.

Do not leave the cluster hibernated at the end of a successful scenario.

⸻

10. Scenario 06 — PostgreSQL Upgrades

Script: 06_postgresql_upgrades.sh

Purpose

Demonstrate both:

1. PostgreSQL minor upgrade.
2. PostgreSQL offline in-place major upgrade.

Both operations are mandatory.

The major upgrade must not be replaced by an import into a new cluster.

Verified environment information

The previous investigation identified:

* CNPG operator: 1.30.1.
* Helm chart: 0.29.1.
* Initial PostgreSQL version: 17.5.
* Supported in-place major upgrade mechanism: pg_upgrade --link, triggered through the supported CNPG workflow.
* Requirement: source and target PostgreSQL images must use the same operating system distribution.

These findings must be rechecked against the actual repository configuration and installed operator before implementation.

PostgreSQL image compatibility

The previous investigation confirmed availability for both AMD64 and ARM64 of:

* 17.6-standard-bookworm
* 18-standard-bookworm

The initial PostgreSQL 17.5 image must also use a compatible Bookworm-based image.

Do not mix Bookworm and Trixie images during the major upgrade.

Do not assume that the unqualified :18 image is compatible.

Use explicit image tags.

Verify actual PostgreSQL image names and registry paths.

Minor upgrade

Target:

PostgreSQL 17.5 → 17.6

Use kubectl patch to update spec.imageName.

Example:

kubectl patch cluster cnpg-cluster \
  --type merge \
  -p '{"spec":{"imageName":"<validated-17.6-bookworm-image>"}}'

Verify:

* Rolling update progression.
* Pod readiness.
* Cluster health.
* PostgreSQL version.

The minor upgrade must complete successfully before the major upgrade begins.

In-place major upgrade

Target:

PostgreSQL 17.6 → 18

Use the officially supported CNPG 1.30.1 in-place major upgrade procedure.

The operation must:

1. Verify the current PostgreSQL version.
2. Verify the source image.
3. Verify the target image.
4. Verify operating system compatibility.
5. Verify cluster health.
6. Verify backup availability.
7. Explain the expected downtime.
8. Request explicit confirmation.
9. Trigger the supported in-place major upgrade.
10. Observe upgrade progression.
11. Verify PostgreSQL 18.
12. Verify cluster health.
13. Verify Barman configuration and WAL archiving.

Use kubectl patch where supported.

Do not apply a reduced Cluster manifest that removes existing configuration.

Do not use a migration into a separate PostgreSQL cluster.

Important constraints

The in-place major upgrade is disruptive.

The scenario must clearly communicate that PostgreSQL availability will be interrupted.

All CNPG instances may be unavailable during the operation.

Do not claim zero downtime.

A completed backup is required before proceeding.

If the necessary backup is missing, stop and explain how to create one.

Execution order

The recommended order is:

1. Minor upgrade.
2. Verify PostgreSQL 17.6.
3. Verify backup availability.
4. In-place major upgrade.
5. Verify PostgreSQL 18.

The major upgrade must be performed last in the overall learning journey.

Expected result

The original cnpg-cluster runs PostgreSQL 18.

No replacement cluster is created.

Barman and monitoring configuration remain intact.

WAL archiving remains operational.

⸻

11. Manifest Simplification

This section is mandatory.

Review every YAML manifest currently present in cnpg-standard.

Remove obsolete and redundant manifests.

Keep only essential manifests

Expected:

1. Main CNPG Cluster manifest.
2. Restore Cluster manifest.
3. Barman ObjectStore manifest, if required.
4. Any additional resource that genuinely requires a declarative manifest.

Two or three manifests should be sufficient in principle.

Do not force an artificial manifest count if it would compromise correctness.

Remove

* Version-specific Cluster manifests.
* Intermediate Barman configuration manifests.
* Import-based major upgrade manifests.
* Duplicate Cluster definitions.
* Obsolete workshop manifests.
* Manifests no longer referenced by scenarios.

Prefer kubectl patch

Use targeted patches for:

* PostgreSQL image changes.
* Scaling.
* Hibernation and resumption.
* Other simple Cluster configuration changes.

Example:

kubectl patch cluster cnpg-cluster \
  --type merge \
  -p '{"spec":{"instances":3}}'

Do not apply a complete Cluster manifest just to change one field.

Preserve configuration

Patches must preserve:

* Barman plugin.
* WAL archiving.
* Monitoring.
* Storage.
* Node placement.
* Other existing CNPG configuration.

Before deleting any manifest, verify that no script or test still references it.

⸻

12. Reset Lab

Script: 99_reset_lab.sh

Purpose

Restore the CNPG Standard use case to a clean initial state without deleting the Kind cluster.

The reset must remain a convenient, reliable utility.

MinIO Client

The previous investigation confirmed that the existing Playground uses:

netiedge/minio-mc:RELEASE.2025-01-17T23-25-50Z

This image was verified as available for:

* linux/amd64
* linux/arm64

Reuse this image.

Do not introduce another MinIO Client image.

Do not use an unverified minio/mc:latest.

Reference implementation

Inspect:

../cnpg-operator-playground-local

This repository is read-only.

The previous investigation found that it uses the same MinIO Client image for bucket creation, but does not contain the expected reset implementation.

Therefore:

* Reuse the verified image and existing MinIO configuration.
* Adapt the current 99_reset_lab.sh implementation.
* Do not assume the reference repository contains a tested cleanup script.

Cleanup scope

The reset must remove only scenario-owned resources.

Examples:

* cnpg-cluster
* restored-cnpg-cluster
* Scenario-created Backup resources.
* Scenario-created Jobs.
* Relevant MinIO backup prefixes.
* Scenario-created ObjectStore configuration, when appropriate.
* Scenario-created MinIO Secret, when appropriate.

MinIO cleanup

Use the MinIO Client to remove only the relevant scenario backup prefixes.

Preserve:

* MinIO deployment.
* MinIO service.
* MinIO bucket.
* Unrelated MinIO objects.

Do not delete the entire bucket.

Do not assume every object in the bucket belongs to CNPG Standard.

Kubernetes cleanup

Avoid broad deletion commands such as:

kubectl delete backup --all
kubectl delete jobs --all

Use explicit resource names or validated ownership selectors.

Do not delete unrelated resources in the default namespace.

Safety

Before executing:

1. Display the resources targeted for deletion.
2. Explain that PostgreSQL data and backups will be removed.
3. Request explicit confirmation.
4. Verify the intended Kubernetes context.

If MinIO cleanup fails, report the error.

Do not silently claim a successful reset.

Expected result

After reset:

* The Kind cluster still exists.
* CNPG operator remains installed.
* Barman plugin remains installed.
* Grafana and Prometheus remain available.
* MinIO remains available.
* Scenario-created PostgreSQL resources are removed.
* Scenario-owned backup objects are removed.
* Scenario 01 can be executed again.

⸻

13. Scenario Coding Standards

This section is critical.

The scenarios are educational scripts.

Sales Engineers should be able to read them and understand the operations being performed.

The source code itself is part of the learning experience.

Preserve the existing template

Inspect the current scenario template before editing.

All scenarios must use the same:

* Script header conventions.
* UI helpers.
* Section formatting.
* Interactive prompts.
* Command presentation.
* Error handling.
* Completion messages.

Use the existing engine/lib/ui.sh.

Do not modify engine/lib/ui.sh.

Readability

Prefer:

* Direct Kubernetes commands.
* Short command sequences.
* Meaningful variable names.
* Simple Bash control flow.
* Existing UI helpers.
* Minimal shared helpers.

Avoid:

* Excessive comments.
* Large helper libraries.
* Unnecessary abstractions.
* Complex Bash expressions.
* Deeply nested conditions.
* Repeated validation boilerplate.
* Generic execution frameworks.
* Dynamically generated YAML when a simple command is sufficient.

Self-documenting code

Comments should explain non-obvious technical behavior.

Do not write comments that merely repeat the next command.

Example of unnecessary commenting:

# Scale the cluster to 2 instances
kubectl patch cluster cnpg-cluster \
  --type merge \
  -p '{"spec":{"instances":2}}'

The command is already explicit.

Prefer concise UI explanations where educational context is useful.

Commands must remain visible

Do not hide important Kubernetes operations behind generic helper functions.

A reader should be able to identify the actual kubectl commands directly in the scenario.

Shared helpers are appropriate for:

* Project path resolution.
* Kubernetes context isolation.
* Existing UI integration.
* Dynamic service URL discovery.

They should not obscure the educational operations.

Consistency

All six scenarios must look and behave as though they were developed using the same template.

Do not mix different presentation styles.

⸻

14. Playground Compatibility

Preserve:

* Dynamic project root resolution.
* Per-terminal Kubernetes context isolation.
* Existing Kind cluster naming.
* Existing node labels.
* Dynamic Grafana and MinIO URLs.
* Existing monitoring stack.
* Existing Barman plugin.
* ttyd/tmux interactive behavior.
* Existing Playground CLI.

Do not hard-code:

* Kind node names.
* Kubernetes contexts.
* Host IP addresses.
* Dynamically allocated host ports.
* User-specific paths.

Do not introduce:

* Make.
* gum.
* New host dependencies.
* New container images unless strictly required.

The scenarios must work from the Playground Web terminal.

They must also work when invoked using an absolute path from another working directory.

⸻

15. Documentation

Update:

usecases/cnpg-standard/README.md

Include:

1. Use case purpose.
2. Architecture.
3. Prerequisites.
4. Six-scenario learning path.
5. Expected results.
6. Reset instructions.
7. Known limitations.
8. PostgreSQL upgrade prerequisites.

Update any other documentation referencing removed scripts.

Do not duplicate unnecessary workshop documentation.

Keep the README practical and concise.

⸻

16. Automated Validation

Update:

tests/scenarios.sh

Preserve existing meaningful test coverage.

Static tests

Verify:

* Exactly six educational scenarios.
* Reset utility present.
* Bash syntax.
* Executable permissions.
* Scenario discovery.
* Scenario ordering.
* Manifest references.
* Path resolution.
* Kubernetes context isolation.
* No obsolete script references.
* No Make dependencies.
* No committed secrets.

Scenario flow tests

Use fake Kubernetes commands where appropriate.

Verify:

* Expected commands.
* Correct Cluster names.
* Correct PostgreSQL image references.
* Correct patch operations.
* MinIO cleanup scope.
* Confirmation prompts.
* Error handling.

Do not confuse mocked execution with real Kubernetes validation.

⸻

17. Runtime Validation

Do not start or modify Kubernetes resources without explicit authorization.

Prepare a runtime checklist covering:

Test    Expected result
01 — Deploy    Healthy 3-instance PostgreSQL cluster
01 — Rerun    No duplicate Secret error
02 — Data    Data created and accessible
03 — Backup    Completed backup in MinIO
03 — Restore    Restored cluster healthy, data verified
04 — Switchover    New primary elected
04 — Failover    Automatic recovery
05 — Scaling    3 → 2 → 3 instances
05 — Hibernation    Cluster stops and resumes
06 — Minor upgrade    PostgreSQL 17.6
06 — Major upgrade    PostgreSQL 18 in-place
06 — Barman    WAL archiving remains operational
99 — Reset    Scenario resources and backups removed
99 — Isolation    Unrelated resources preserved
01 — Replay    Successful deployment after reset

Runtime validation must include the Web terminal experience.

Do not mark a scenario fully validated based only on static or mocked tests.

⸻

18. Specification History

Create:

docs/specs/SPEC-007.1.2-cnpg-standard-simplification.md

Preserve this complete specification.

Update:

* docs/specs/README.md
* docs/release-checklist.md

Do not modify historical specifications.

Keep the version unchanged:

1.0.0-rc.1

⸻

19. Acceptance Criteria

Implementation is complete when:

1. Exactly six educational scenarios exist.
2. The reset utility remains available.
3. CNPG deploys with Barman configured from the beginning.
4. MinIO credentials are initialized idempotently.
5. Data generation works.
6. Backup and restore are combined.
7. HA operations are consolidated.
8. Administration operations are simplified.
9. Minor upgrades use targeted patches.
10. In-place major upgrade is implemented using the supported CNPG mechanism.
11. PostgreSQL images use compatible OS distributions.
12. Barman configuration is preserved during upgrades.
13. Obsolete manifests are removed.
14. Reset uses the verified MinIO Client image.
15. Reset targets only scenario-owned resources.
16. Scripts respect the existing template.
17. Scripts remain short, readable and minimally commented.
18. Existing Playground functionality is preserved.
19. Automated tests pass.
20. Runtime validation requirements are documented.

Implementation completion and runtime validation are separate milestones.

Do not claim full release readiness until runtime tests have passed.

⸻

20. Final Report

Provide:

Scenario inventory

* Final six scenarios.
* Old-to-new mapping.
* Removed scripts.

Manifest cleanup

* Manifests retained.
* Manifests removed.
* Reason for each retained manifest.

PostgreSQL upgrades

* Operator version.
* PostgreSQL source and target versions.
* Image names and OS compatibility.
* Minor upgrade implementation.
* In-place major upgrade implementation.
* Barman preservation.

MinIO reset

* MinIO Client image.
* Image architecture compatibility.
* Cleanup scope.
* Safety measures.

Validation

* Automated tests executed.
* Tests passed.
* Runtime tests pending.
* Known limitations.

Safety confirmation

Explicitly confirm:

* Source repositories unchanged.
* Playground engine unchanged, or explain necessary modifications.
* engine/lib/ui.sh unchanged.
* No unrelated use cases modified.
* No existing Kind clusters deleted.
* No Kubernetes data removed.
* No tmux sessions terminated.

Do not push, tag or publish the repository.

⸻

21. Implementation Instructions

Proceed in this order:

1. Perform the read-only preflight.
2. Present a concise refactoring plan.
3. Implement the six scenarios.
4. Simplify the manifests.
5. Refactor the reset utility.
6. Update automated tests.
7. Update documentation.
8. Run static and non-destructive tests.
9. Provide the final implementation report.
10. Wait for user authorization before runtime validation.

Do not stop after the preflight merely to ask for permission to edit files.

You are authorized to implement the refactoring and run non-destructive tests.

You are not authorized to modify running Kubernetes resources or perform destructive runtime operations without explicit approval.

Final objective: a simple, readable and reproducible CNPG Standard demonstration suitable for the Playground v1.0.0-rc.1.
~~~~~
