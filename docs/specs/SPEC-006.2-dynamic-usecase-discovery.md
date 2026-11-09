# SPEC-006.2 — Dynamic Use Case Discovery

| | |
|---|---|
| Status | Implemented |
| Document type | Original specification, preserved verbatim |
| Source | Claude Code session transcript (project history), user message 2026-11-04T22:25:09.691Z UTC |
| Original specification | Available (see the last section) |

## Summary

The sidebar lists the use cases found on disk, with their status and number of Kind clusters, refreshed automatically.

## Implemented behavior

- `GET /api/usecases` returns `[{name, status, clusters, operation}]`.
- A valid use case is a directory under `usecases/` with `install.sh`, `status.sh` and `cleanup.sh` and a name the Makefile accepts.
- `status` is `running` when the use case owns at least one Kind cluster, otherwise `stopped`.
- The sidebar refreshes every 3 s, keeps the selection, and keeps the last known list on an error (an error is never shown as "stopped").
- No naming logic lives in the backend: discovery is delegated to a script.

## Implementation

- `engine/usecase-list.sh` (read-only; `--names` mode skips Docker/Kind; exits 2 with a message when Docker or Kind is unreachable).
- `web/app.py` `_discover()`; `web/static/app.js` sidebar rendering.

## Later corrections and follow-ups

Operation state was added to the same response by SPEC-006.3. Directory names changed in SPEC-006.7.2 without any code change here.

## Verification

Tested by the implementer at API, WebSocket-protocol and fake-DOM level (scripts kept outside the repository). No real browser was available to the implementer; the project owner reported manual validation of the features as a whole (SPEC-006.9, context section), but the individual manual checks are not recorded.

## Known limitations

None recorded beyond the general ones in `docs/specs/README.md`.

## Original specification (verbatim)

~~~~~text
SPEC-006.2 — Dynamic Use Case Discovery

Context

SPEC-006.1 is implemented and validated in a real browser.

The Playground now has:

* FastAPI serving a lightweight Web UI.
* A working embedded ttyd terminal.
* A sidebar placeholder.
* A Docker resources placeholder.
* A bottom status bar placeholder.

Objective

Replace the sidebar placeholder with automatic discovery of available use cases and their runtime status.

Keep the implementation minimal.

Requirements

1. Automatic discovery

Discover use cases dynamically from /workspace/usecases/.

A valid use case must have the lifecycle scripts required by the existing Makefile.

Do not hardcode use case names.

2. Runtime status

For each discovered use case, determine:

* Name.
* Running or Stopped.
* Number of existing Kind clusters.

Reuse the existing cluster naming and discovery logic.

For multi-cluster use cases, report the actual number of clusters.

Do not infer Running solely from the presence of a directory.

3. Backend

Add a read-only endpoint:

GET /api/usecases

Example response:

{
  "usecases": [
    {
      "name": "single-cnpg",
      "status": "running",
      "clusters": 1
    },
    {
      "name": "multi-cluster-dr",
      "status": "running",
      "clusters": 2
    }
  ]
}

Use the existing Docker CLI or Bash helpers.

Avoid duplicating the cluster naming logic in Python.

Handle Docker errors gracefully rather than incorrectly reporting Stopped.

4. Frontend

Display the discovered use cases in the left sidebar.

For each use case, show:

* Name.
* Status indicator.
* Running / Stopped label.
* Number of active clusters.

Refresh automatically every 3 seconds without reloading the page.

Preserve the selected use case during refreshes.

If a new use case directory appears, add it automatically.

If a use case is removed, remove it from the list.

5. Interaction

Clicking a use case should only select and highlight it.

Do not execute any commands.

Do not change the Kubernetes context.

Do not create terminal tabs yet.

6. Constraints

Do not modify:

* Existing use case scripts.
* Kind provisioning logic.
* Platform installation.
* ttyd integration.
* Docker network initialization.

No new containers, frameworks or databases.

No Start/Stop buttons yet.

Validation

Verify:

1. Both existing use cases are discovered.
2. Their running cluster counts are correct.
3. A temporary valid use case directory appears automatically.
4. Removing that temporary directory updates the sidebar.
5. Stopping a use case updates its status.
6. The embedded terminal continues working normally.

Do not destroy existing clusters solely for testing.

Deliverables

* Modified files.
* API response example.
* Validation results.
* Any limitations.

Implement SPEC-006.2 only.
~~~~~
