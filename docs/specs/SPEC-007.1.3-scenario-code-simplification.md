# SPEC-007.1.3 — CNPG Standard Scenario Code Simplification

| | |
|---|---|
| Status | Implemented; static and fake-`kubectl` validation done. **Runtime validation pending**: no scenario has run against a live cluster |
| Document type | Original specification, preserved verbatim, with the implementation record |
| Source | Claude Code session transcript (project history), user message of 2026-11-05 (it supersedes earlier SPEC-007.1.3 drafts) |
| Original specification | Available (see the last section) |
| Target version | `1.0.0-rc.1` (unchanged) |
| Relation | Simplifies the scripts of [SPEC-007.1.2](SPEC-007.1.2-cnpg-standard-simplification.md); that document is historical and unchanged. Where they differ, this one describes the current code |

## Summary

The six scenarios and the reset are now plain command sequences: `scenarios/lib.sh` is removed, the validation, readiness loops, rerun detection and helper functions are gone, and only scenario 01 selects the Kubernetes context.

## Implemented behavior

| Scenario | Before (lines) | After | Reduction |
|---|---|---|---|
| `01_deploy_cluster.sh` | 68 | 55 | 19% |
| `02_data_workload.sh` | 61 | 46 | 25% |
| `03_backup_restore.sh` | 71 | 50 | 30% |
| `04_high_availability.sh` | 59 | 49 | 17% |
| `05_cluster_administration.sh` | 59 | 48 | 19% |
| `06_postgresql_upgrades.sh` | 143 | 54 | 62% |
| `99_reset_lab.sh` | 104 | 72 | 31% |
| `lib.sh` | 48 | removed | 100% |
| **Total** | **613** | **374** | **39%** |

(01–05 shrink less because the interactive template, the `ui_note` introduction and the step texts are kept as required.)

- **Context:** `01` starts with `kubectl config use-context ${KUBE_CONTEXT}` (shown as a typed command; `KUBE_CONTEXT` comes from `engine/usecase.sh`, which every scenario still sources for the project root). 02–06 do not touch the context and use the terminal's own `KUBECONFIG` as is. `99` only compares the current context with the use case's before deleting anything (it is destructive, and no longer selects it for you).
- **URLs:** `03` shows the MinIO console URL with the Playground's existing `engine/infrastructure/kind/info.sh` (`bash ${KIND_DIR}/info.sh ${CLUSTER}`). `01` does not show URLs: they are in the Web UI (owner's edit).
- **01:** use-context, nodes, operator pods, a plain `kubectl create secret generic minio-secret` (owner's edit: not idempotent, a second run fails with Kubernetes' normal "already exists"), the manifest opened with `vim` (owner's edit, interactive), `apply -f manifests/cluster.yaml`, status watch, pods. No existence check.
- **02:** connection URI, `pgbench` init job, `count(*)`, 15 s workload job. No dataset check.
- **03:** `kubectl cnpg backup --backup-name cnpg-cluster-backup`, wait for `completed`, backups, MinIO URL, the manifest opened with `vim` (owner's edit) and `apply` of `manifests/restore-cluster.yaml` (PostgreSQL 17.5 Bookworm, matching the backup), status watch, row count and version on the restored cluster.
- **04:** replica and primary found with `cnpg.io/instanceRole` label selectors; `promote`; the new primary found again; one `ui_confirm`, then `delete pod --grace-period=0 --force`; watch and status. PVCs untouched.
- **05:** merge patches for `instances` 3 → 2 → 3 and the `cnpg.io/hibernation` annotation on/off, each followed by a pod watch; status.
- **06:** `SHOW server_version`; the minor merge patch to `17.6-standard-bookworm`; the major upgrade after one `ui_confirm`, as one JSON patch (`imageName` → `18-standard-bookworm`, plus the Barman `serverName` `cnpg-cluster-pg18`); watch of pods and jobs; `SELECT version()` and `kubectl cnpg status`. The images are written in the commands, not in variables.
- **99:** unchanged in scope and in isolation (named Backups of the two clusters, jobs `pgb-init`/`pgb-run`, the two clusters, MinIO prefixes `cnpg/cnpg-cluster/`, `cnpg-cluster-pg18/`, `restored-cnpg-cluster/` through one `netiedge/minio-mc:RELEASE.2025-01-17T23-25-50Z` pod, then the ObjectStore and the secret), with explicit confirmation; a MinIO failure is reported with exit code 1 and keeps the secret and ObjectStore. It keeps a bucket access check and a guard that skips empty prefixes, because `mc rm` fails on a missing prefix and a legitimate reset would otherwise be reported as failed.
- Unchanged: `engine/lib/ui.sh`, the engine, the CLI, the Web UI, Compose, the Dockerfile, the manifests, the other use case.

### Removed

- **Helper library and functions:** `lib.sh` (`scenario_init`, `scenario_use_cluster_context` with its private `KUBECONFIG` file and EXIT trap, `scenario_service_url`, `scenario_require_cluster_ready`, the `yq` fallback), and in 06 `pg_version`, `pods_on_image`, `minor_upgrade`, `major_upgrade`. Scripts keep only the template's `show_instruct`, `play` and `main`.
- **Validation and recovery:** reachability, readiness and context checks, existing-cluster and existing-dataset detection (01, 02, 03), the source/target OS comparison, the completed-backup requirement, the unexpected-image refusal, the readiness and rollout polling loops, the unavailability probe loop with timestamps, the WAL-switch/archiver counter check, the post-upgrade backup, `local` variables used only to hold constants.
- **Dependencies:** `yq` (manifests are opened with `vim`).

### Decisions and deviations to review

1. **Major upgrade command.** The only earlier working implementation found is the workshop's step 12 (`../se-demos-k8s-cnpg-workshop`, apply a Cluster with the next major image); `../cnpg-operator-playground-local` has none. Its sequence (image change, watch, check) is reused. One deliberate addition is kept inside the same single patch: the Barman `serverName`, because the CNPG 1.30 documentation says the plugin does not separate archives after `pg_upgrade` (new system identifier). Remove that operation from the patch if you prefer the workshop's exact behavior; archiving may then conflict.
2. **`use-context` in a plain shell.** In a Web terminal it only changes that terminal's `KUBECONFIG` file. Run from a plain container shell, it changes the shared kubeconfig's current-context, which `CLAUDE.md` forbids features and tests to do; the specification requires it, so it is implemented as asked.
3. **No safety nets, as specified:** replaying a scenario on existing resources fails with Kubernetes' error; replaying 01 on an upgraded cluster would re-apply the 17.5 manifest (the README says to reset first). A scenario can move on before the previous step finished if Enter is pressed early.
4. **UI calls.** The specification's example uses `ui_step "…"` and `ui_watch kubectl get pods`; the existing library has `ui_step` as a numbered banner and `ui_watch "<command string>"`. The unchanged template conventions (`ui_info`, `ui_command` typing then running the command, `ui_watch "…"`, `ui_pause`, `ui_confirm`) are kept. Two confirmations are kept (04 failure, 06 major, plus 99) because they guard a disruptive action, not a state check.

## Validation

**Done, `tests/scenarios.sh`:** exactly the six scenarios and the reset in `scenarios/` (no `lib.sh`, nothing else), discovery order, executable, syntax, template (ui.sh, usecase.sh, `main`), no function other than `show_instruct`/`play`/`main`, no `|| true`, no `KUBECONFIG` handling, no `lib.sh`/`scenario_*` reference; context rule (`use-context ${KUBE_CONTEXT}` only in 01, no `use-context`/`current-context` in 02–06); exactly the two manifests, referenced and valid; Bookworm image tags; reset image equals the platform's pinned image; dynamic primary/replica commands present; no obsolete references, workshop environment, Make, gum, broad deletion or secrets; reference repositories unmodified. With a fake `kubectl`/`docker`/`sleep` (see the test header): each scenario runs end to end (rc 0, boxes, prompts), commands and their order (backup before restore, switchover before the pod deletion, minor before major), the refused confirmations (04, 06, 99 change nothing), the discovered primary pod, the upgrade patches, the reset scope (own Backups only, named jobs, three prefixes, image, `MC_HOST`, secret removed only after the MinIO step), the MinIO failure path and the wrong-context stop, all kubectl calls under the terminal's own `KUBECONFIG`, absolute-path and relative runs from several directories. The fake validates no Kubernetes or CNPG behavior. Removed with the code they tested: the helper isolation tests, rerun and refusal-of-bad-state tests, the unreachable-cluster tests.

**Runtime (pending, nothing claimed):**

| Test | Expected result | Status |
|---|---|---|
| 01 | `use-context` works in the Web terminal; healthy 3-instance 17.5 cluster | Pending |
| 02 | Dataset created, count shown, workload job completes | Pending |
| 03 | `--backup-name` accepted, backup `completed` in MinIO; restored cluster healthy, rows equal | Pending |
| 04 | Labels `cnpg.io/instanceRole` present; switchover; pod deletion and automatic recovery, PVCs intact | Pending |
| 05 | Scaling 3 → 2 → 3; hibernation by annotation stops and resumes the pods | Pending |
| 06 | Minor upgrade to 17.6; in-place major upgrade to 18 on the same cluster; `serverName` patch accepted; WAL archiving OK in `kubectl cnpg status` afterwards | Pending |
| 99 | MinIO client pod authenticates and removes only the three prefixes; an unrelated bucket object remains; scenario resources gone; replay of 01 succeeds | Pending |
| Web terminal | Enter, `ui_watch`, confirmations, boxes, `less`, `kubectl exec` in ttyd/tmux | Pending |

The use case is not marked validated.

## Original specification (verbatim)

~~~~~text
SPEC-007.1.3 — CNPG Standard Scenario Code Simplification

Project: CNPG Operator Playground
Target: usecases/cnpg-standard
Release: v1.0.0-rc.1
Type: Code simplification and maintainability
Status: To implement

This specification supersedes all previous SPEC-007.1.3 drafts and clarifications.

⸻

1. Objective

Simplify the CNPG Standard scenarios as much as possible.

The scenarios are executable tutorials, not production automation scripts.

They should resemble commands that a Sales Engineer would execute manually in a terminal.

The main goals are:

* Extremely simple Bash scripts.
* Minimal lines of code.
* Direct Kubernetes and PostgreSQL commands.
* No unnecessary validation.
* No defensive programming.
* No scenario-specific helper library.
* Easy manual maintenance.
* Consistent interactive presentation.

Prefer simplicity over robustness.

A scenario may fail if the environment is not in the expected state. This is acceptable in an educational Playground.

Users should be able to investigate and troubleshoot errors themselves.

⸻

2. Fundamental Design Principle

Each scenario should be a straightforward sequence of commands.

Example:

ui_step "Scale PostgreSQL to 2 instances"
kubectl patch cluster cnpg-cluster \
  --type merge \
  -p '{"spec":{"instances":2}}'
ui_watch kubectl get pods
ui_step "Scale PostgreSQL back to 3 instances"
kubectl patch cluster cnpg-cluster \
  --type merge \
  -p '{"spec":{"instances":3}}'

Avoid abstractions such as:

check_cluster_health
validate_cluster_state
ensure_cluster_exists
patch_cluster_safely
wait_for_cluster_ready
verify_expected_replicas

The Kubernetes commands must remain directly visible.

Do not turn simple shell scripts into a framework.

⸻

3. Remove Scenario-Specific Helper Libraries

Remove:

usecases/cnpg-standard/scenarios/lib.sh

Do not replace it with another shared helper library.

Do not copy its entire implementation into individual scenarios.

Instead:

1. Identify the commands genuinely required by each scenario.
2. Keep those commands directly in the script.
3. Remove unnecessary validation and initialization.
4. Reuse existing Playground UI functions.

The existing engine/lib/ui.sh must remain unchanged.

Do not introduce new generic helper functions.

⸻

4. Kubernetes Context Management

Only the first scenario must explicitly select the Kubernetes context.

Scenario 01

At the beginning of 01_deploy_cluster.sh:

kubectl config use-context "$KUBE_CONTEXT"

Use the context provided by the Playground.

Scenarios 02–06

Do not change the Kubernetes context.

Do not validate the context.

Do not perform connectivity checks.

Use the context already selected by scenario 01.

Preserve the Playground’s existing isolated KUBECONFIG.

Do not introduce additional context management logic.

⸻

5. Error Handling Philosophy

Remove unnecessary defensive programming.

Specifically, remove:

* Repeated resource existence checks.
* Cluster health checks before every operation.
* Kubernetes connectivity checks.
* Dependency validation.
* Complex Bash conditionals.
* Automatic retries.
* Automatic recovery.
* Generic error handling functions.
* Extensive logging.
* Repeated verification loops.
* Unnecessary fallback logic.

Let Kubernetes and PostgreSQL return their normal errors.

Do not hide failures with || true.

Do not add code simply to make scenarios appear more robust.

A simple set -e is acceptable if compatible with the existing scenario template.

Do not add complex error handling around it.

⸻

6. Interactive Presentation

Preserve the existing scenario UI conventions.

Keep:

* Scenario titles.
* Step descriptions.
* Command presentation.
* Interactive pauses.
* Watch screens.
* Completion messages.

Reuse existing functions from engine/lib/ui.sh.

Do not modify that library.

Keep explanations concise.

The scenario must remain readable directly from its Bash source.

Avoid unnecessary comments.

The UI should guide the user without introducing complex execution logic.

⸻

7. Dynamic Commands

Dynamic discovery is acceptable when required by the demonstration.

Primary identification

For example:

PRIMARY=$(kubectl get pods \
  -l cnpg.io/instanceRole=primary \
  -o jsonpath='{.items[0].metadata.name}')

Use the correct CNPG labels for the installed operator.

Replica identification

Use simple Kubernetes selectors.

PostgreSQL connection

Retrieve the necessary credentials or connection information with direct kubectl commands.

Dynamic service URLs

Reuse the existing Playground mechanisms for Grafana and MinIO.

Do not hard-code dynamic host ports.

Do not wrap these operations in additional helper functions.

Keep only the dynamic logic that is genuinely necessary.

⸻

8. Scenario Scope

Keep the six scenarios defined in SPEC-007.1.2.

01 — Deploy Cluster

01_deploy_cluster.sh

Keep:

* Kubernetes context selection.
* MinIO Secret creation.
* Barman ObjectStore configuration.
* CNPG Cluster deployment.
* Cluster status display.

Use the existing manifests.

Keep the Secret creation idempotent using a simple kubectl create --dry-run=client | kubectl apply command.

Do not add checks to determine whether the cluster already exists.

Let Kubernetes handle resource conflicts.

02 — Data & Workload

02_data_workload.sh

Keep:

* PostgreSQL connection.
* Dataset initialization.
* A simple SQL query.
* A short workload.

Avoid elaborate dataset existence checks.

If the dataset already exists, let the relevant command report the error.

03 — Backup & Restore

03_backup_restore.sh

Keep:

* Backup creation.
* Backup status observation.
* Restore Cluster deployment.
* Restored data verification.

Use the existing restore manifest.

Avoid additional validation layers.

Preserve the correct PostgreSQL version for restoring an existing physical backup.

Do not add complex version detection.

04 — High Availability

04_high_availability.sh

Keep:

* Primary identification.
* Controlled switchover.
* Primary identification after switchover.
* Primary Pod deletion to simulate failure.
* Automatic failover observation.

Dynamic primary identification is necessary and must remain.

Avoid generic cluster health validation functions.

Use direct CNPG and Kubernetes commands.

05 — Cluster Administration

05_cluster_administration.sh

Keep:

* Scaling from 3 to 2 instances.
* Scaling back to 3 instances.
* Hibernation.
* Resumption.
* Cluster status observation.

Prefer kubectl patch.

Avoid helper functions and complex readiness loops.

06 — PostgreSQL Upgrades

06_postgresql_upgrades.sh

Keep:

* PostgreSQL minor upgrade.
* PostgreSQL in-place major upgrade.
* PostgreSQL version verification.
* Cluster status observation.

Important: the major upgrade implementation already worked in the previous repository.

Inspect the existing implementation and reuse its proven commands.

Do not redesign the major upgrade workflow.

Do not introduce complex compatibility checks or preflight validation.

Use the known working PostgreSQL images and upgrade sequence.

Prefer simple kubectl patch commands where supported.

Keep the major upgrade in-place.

Do not introduce an import-based migration into a new cluster.

The script should remain a simple sequence of commands.

⸻

9. Manifest Management

Preserve the simplified manifest structure established by SPEC-007.1.2.

Do not recreate obsolete manifests.

Prefer direct kubectl patch commands for:

* Scaling.
* Hibernation and resumption.
* PostgreSQL minor upgrades.
* PostgreSQL major upgrades.

Keep only the manifests required for:

* Initial Cluster deployment.
* Barman ObjectStore.
* Restore Cluster deployment.
* Other resources that genuinely require declarative configuration.

Do not create version-specific manifests.

Do not generate YAML dynamically when a simple Kubernetes command is sufficient.

⸻

10. Reset Utility

Keep:

99_reset_lab.sh

This utility is different from the educational scenarios.

It performs destructive cleanup and may therefore retain the minimal logic required to:

* Identify scenario-owned resources.
* Delete the CNPG clusters.
* Delete scenario-owned Backups and Jobs.
* Remove only scenario-owned MinIO prefixes.
* Preserve unrelated Kubernetes and MinIO resources.
* Report cleanup failures.

Keep the existing verified MinIO Client image:

netiedge/minio-mc:RELEASE.2025-01-17T23-25-50Z

Do not introduce another MinIO Client image.

Preserve the explicit reset confirmation.

Do not use broad deletion commands such as kubectl delete backup --all.

Simplify the implementation where possible, but do not compromise cleanup isolation.

⸻

11. Code Style

Follow these rules:

1. Keep scripts short.
2. Use direct commands.
3. Avoid custom functions.
4. Avoid nested conditionals.
5. Avoid unnecessary variables.
6. Avoid repeated validation.
7. Avoid unnecessary comments.
8. Avoid generic wrappers.
9. Keep important Kubernetes commands visible.
10. Preserve the existing UI template.

A scenario should be understandable by reading it from top to bottom.

Do not optimize for maximum robustness.

Do not optimize for maximum test coverage.

Optimize for readability and manual maintainability.

Aim for a few dozen lines per scenario whenever practical.

Do not impose an artificial line limit if a scenario genuinely requires more commands.

⸻

12. Playground Compatibility

Preserve:

* Existing Playground architecture.
* Existing isolated KUBECONFIG.
* Existing scenario discovery.
* Existing UI helpers.
* Existing dynamic service URLs.
* Existing Kind cluster naming.
* Existing CNPG and Barman installation.
* Existing monitoring infrastructure.

Do not modify:

* Playground engine.
* engine/lib/ui.sh.
* CLI.
* Web UI.
* Docker Compose.
* Dockerfile.
* Other use cases.

Do not introduce new dependencies.

⸻

13. Validation

Run static and non-destructive tests.

Verify:

* Bash syntax.
* Executable permissions.
* Scenario discovery.
* Manifest references.
* Removal of lib.sh.
* Correct Kubernetes context selection in scenario 01.
* No context switching in scenarios 02–06.
* Preservation of essential dynamic commands.
* Preservation of reset isolation.

Update tests to match the simplified scripts.

Remove obsolete tests that enforce unnecessary defensive behavior.

Do not reintroduce complexity just to satisfy tests.

Runtime validation will be performed separately.

Do not execute Kubernetes-modifying scenarios without authorization.

⸻

14. Documentation

Create:

docs/specs/SPEC-007.1.3-scenario-code-simplification.md

Update:

* Specification index.
* Release checklist.
* CNPG Standard README if necessary.

Preserve previous specifications.

Do not change the Playground version.

Do not push or tag the repository.

⸻

15. Acceptance Criteria

The implementation is complete when:

1. All six scenarios are simplified.
2. scenarios/lib.sh is removed.
3. No unnecessary helper functions remain.
4. No excessive validation remains.
5. Kubernetes commands are directly visible.
6. Only scenario 01 selects the Kubernetes context.
7. Scenarios 02–06 reuse the current context.
8. Dynamic primary identification remains functional.
9. Existing UI conventions are preserved.
10. Minor and in-place major upgrades remain implemented.
11. The known working major upgrade approach is reused.
12. Obsolete manifests are not reintroduced.
13. Reset remains isolated and functional.
14. Static tests pass.
15. The scripts are easy to maintain manually.

⸻

16. Final Report

Provide:

Code simplification

A table showing:

* Scenario name.
* Previous line count.
* New line count.
* Percentage reduction.

Removed complexity

List:

* Removed helper functions.
* Removed validation logic.
* Removed abstractions.
* Removed unnecessary variables.

Preserved functionality

Confirm:

* All six scenarios remain functional in principle.
* Major upgrade commands are preserved.
* Dynamic primary identification remains.
* UI conventions remain unchanged.
* Reset isolation is preserved.

Validation

Report:

* Static tests executed.
* Test results.
* Runtime tests pending.

Safety

Confirm:

* No reference repositories modified.
* No Playground engine changes.
* No unrelated use cases modified.
* No Kubernetes resources modified during refactoring.
* No Git push or tag.

⸻

17. Implementation Instructions

Proceed directly with implementation.

1. Inspect the existing six scenarios.
2. Inspect the previous working major upgrade implementation.
3. Remove unnecessary checks and abstractions.
4. Remove scenarios/lib.sh.
5. Simplify each scenario.
6. Preserve the UI presentation.
7. Update tests.
8. Update documentation.
9. Run static tests.
10. Provide the final report.

Do not stop after inspection to ask for permission to edit files.

Do not execute destructive runtime operations.

Final objective: six simple, readable, executable tutorials that a Sales Engineer can understand and modify manually without learning a custom scripting framework.
~~~~~
