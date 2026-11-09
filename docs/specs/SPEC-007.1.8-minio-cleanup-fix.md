# SPEC-007.1.8: Fix MinIO Cleanup (cnpg-standard)

| | |
|---|---|
| Status | Implemented; validated non-destructively (`mc rm --dry-run` against the live MinIO, fake-`kubectl` tests). The real reset was **not** run |
| Document type | Original request, preserved verbatim, with the investigation and implementation record |
| Source | Claude Code session transcript (project history), user message of 2026-11-05 |
| Target version | `1.0.0-rc.1` (unchanged) |
| Relation | Fixes the MinIO part of `99_reset_lab.sh` (see [SPEC-007.1.2](SPEC-007.1.2-cnpg-standard-simplification.md), [SPEC-007.1.3](SPEC-007.1.3-scenario-code-simplification.md)) |

## Root cause (checked, not assumed)

| Question | Finding |
|---|---|
| Leftover `minio-reset-mc` pod? | None existed. A killed run could leave one (`AlreadyExists` on the next run, reproduced with a stuck pod), so the script now removes it first |
| `kubectl run --rm -i` exit status? | Propagated correctly, in the foreground and in the background (rc 1 on a failing `mc`, pod deleted either way) |
| `ui_spin` hides the error? | **Yes.** `ui_spin` runs the command with `>/dev/null 2>&1` in the background: the client's message ("Access Denied", "Invalid secret key") never reached the user, only "Failed to purge MinIO prefix" |
| Quoting of the generated `sh -c`? | Correct for the lab credentials |
| Credentials | In the live cluster `minio-secret` existed with **no keys** (`DATA 0`). The script reads `MINIO_ACCESS_KEY`/`MINIO_SECRET_KEY` from it, sent empty credentials, and `mc` answered `Access Denied` (reproduced with `--dry-run`). With the lab credentials the same commands work. The empty secret was not touched |
| Prefix match | **Second bug.** `minio/cnpg/cnpg-cluster` (no trailing slash) is a string prefix and also matched `cnpg-cluster-pg18/…` (dry-run listing showed the pg18 objects). With the slash only the intended prefix matches |

Remaining content when checked: only delete markers (`DEL`) under `cnpg-cluster-pg18/` (8) and `restored-cnpg-cluster/` (5); `cnpg-cluster/` was already empty.

## Change (`usecases/cnpg-standard/scenarios/99_reset_lab.sh`)

- `ui_spin` removed around `kubectl run`: the output and the error of `mc` are visible.
- `mc alias set` no longer sends its output to `/dev/null`: a wrong credential is reported (`Invalid secret key`), a good one prints nothing.
- Trailing slash on every prefix: `mc rm --recursive --force --versions minio/cnpg/<prefix>/` (the proven command, versions and delete markers included).
- `kubectl delete pod minio-reset-mc --ignore-not-found` before the loop (after the confirmation): an interrupted earlier run cannot block this one. `--rm` already removes the pod after a normal or failed run; `--quiet` hides the attach hint.
- Everything else is unchanged: the listing, the confirmation, the order (Backups, jobs, clusters, three prefixes, ObjectStore and secret only after a successful purge, final status), and the stop on failure that keeps the secret and ObjectStore for a retry.

If the purge reports `Invalid secret key` or `Access Denied`, check that the secret has both keys: `kubectl get secret minio-secret -o json | jq '.data | keys'` (scenario 01 creates it with both).

## Validation (non-destructive)

| Check | Result |
|---|---|
| `kubectl run --rm -i --quiet` with `mc rm --dry-run` on the three prefixes (live MinIO, lab credentials) | `cnpg-cluster/`: nothing to remove (rc 0); `cnpg-cluster-pg18/`: 8 delete markers; `restored-cnpg-cluster/`: 5; each prefix only touches itself |
| Wrong password | `mc: <ERROR> Invalid secret key`, rc 1, pod removed |
| Leftover pod | `AlreadyExists` reproduced; the pre-delete lets the next run start |
| Empty secret | `Access Denied` visible (the original failure) |
| `tests/scenarios.sh` | 52 checks pass: the three runs (each with `--versions` and the slash), no bucket-level removal, pod removed before the first run, no `ui_spin`, the client's error visible on failure with exit 1 and the secret/ObjectStore kept, success only after cleanup |
| `tests/static.sh` | pass |

No object was deleted, the reset was not run, no container or cluster was rebuilt or recreated, nothing was pushed or tagged. The tests were also realigned with the current `99_reset_lab.sh` (the per-cluster backup query, the `|| true` of its resource listing, the success message): they still described an earlier version.

## Original request (verbatim)

~~~~~
Fix MinIO Cleanup — cnpg-standard

Context

The script usecases/cnpg-standard/scenarios/99_reset_lab.sh fails during MinIO cleanup:

Purging MinIO prefix: cnpg-cluster
✗ Failed to purge MinIO prefix cnpg-cluster.

However, manual testing inside a Kubernetes pod confirmed that MinIO connectivity, credentials and the mc command work correctly.

The following command successfully removed all remaining objects and delete markers:

mc rm --recursive --force --versions minio/cnpg/cnpg-cluster/

Verification returned no objects:

mc ls --recursive --versions minio/cnpg/cnpg-cluster/

The bucket contains three prefixes:

* cnpg-cluster/
* cnpg-cluster-pg18/
* restored-cnpg-cluster/

Objective

Fix the MinIO cleanup in 99_reset_lab.sh while keeping the script simple and educational.

KISS: minimal changes, no unnecessary abstractions.

Required Changes

1. Investigate the actual failure

Focus on the execution of kubectl run from the reset script.

Check:

* Whether the temporary minio-reset-mc pod already exists.
* Whether kubectl run --rm -i correctly propagates the command's exit status.
* Whether ui_spin interferes with interactive pod execution or hides the actual error.
* Whether the generated shell command is correctly quoted.

Do not assume the cause before checking.

2. Simplify the MinIO cleanup

Keep the proven command:

mc rm --recursive --force --versions minio/cnpg/<prefix>/

Use the existing MinIO client image.

Prefer a straightforward kubectl run invocation.

Avoid ui_spin around kubectl run --rm -i if it interferes with execution or hides errors.

Do not introduce new helpers, retry loops, Jobs or additional dependencies.

3. Handle temporary pod cleanup

Ensure that a failed execution does not prevent subsequent resets because of a leftover temporary pod.

Keep the solution minimal.

4. Preserve the existing reset behavior

The script must continue to:

1. Display existing Kubernetes resources.
2. Ask for confirmation.
3. Delete the lab's CNPG backups.
4. Delete the lab's workload jobs.
5. Delete the lab's CNPG clusters.
6. Purge the three MinIO prefixes, including object versions and delete markers.
7. Delete the ObjectStore and MinIO secret only after successful cleanup.
8. Display the final status.

Do not delete unrelated Kubernetes resources or MinIO objects.

5. Validate without destroying data

Do not execute the full reset script.

Do not delete any additional MinIO objects during investigation.

Use non-destructive commands to verify connectivity, credentials and pod execution.

Add a minimal regression test for the cleanup command.

If a destructive test is necessary, request authorization first.

Acceptance Criteria

* MinIO cleanup works from the reset script.
* All three prefixes are targeted correctly.
* Object versions and delete markers are removed.
* Errors are visible instead of being hidden.
* No leftover temporary pod prevents future execution.
* The script remains short and readable.
* No unrelated Playground functionality is modified.

Deliverables

1. Corrected 99_reset_lab.sh.
2. Brief explanation of the root cause.
3. Results of non-destructive validation.

Do not execute the reset, rebuild containers, recreate clusters, push or tag.
~~~~~
