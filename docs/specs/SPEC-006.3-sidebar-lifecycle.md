# SPEC-006.3 — Use Case Start / Stop Controls

| | |
|---|---|
| Status | Implemented |
| Document type | Original specification, preserved verbatim |
| Source | Claude Code session transcript (project history), user message 2026-11-04T22:30:16.005Z UTC |
| Original specification | Available (see the last section) |

## Summary

Start and Stop buttons in the sidebar run the existing Make targets asynchronously and expose their progress and logs.

## Implemented behavior

- `POST /api/usecases/{name}/start` and `/stop` start `make -C /workspace usecase-up|usecase-down USECASE=<name>` in the background (argument list, no shell). Stop adds `FORCE=1` and requires `{"confirm": true}`; the page asks through a confirmation dialog.
- An in-memory registry keeps the latest operation per use case; one active operation per use case (409 otherwise).
- `GET /api/usecases/{name}/operation?offset=` returns the state and the next chunk of the log (never cutting a line or a UTF-8 character); logs are files under `/tmp/playground-operations/`.
- The sidebar shows the busy state, the result and a "logs" link that opens the log panel.

## Implementation

- `web/app.py` (`_launch`, `_watch`, `operation`), `web/static/app.js` (buttons, dialog, log polling), `style.css`.

## Later corrections and follow-ups

Colors in the log: SPEC-006.3.1. Elapsed-time indicator: SPEC-006.7.1. Names of the use cases: SPEC-006.7.2.

## Verification

Tested by the implementer at API, WebSocket-protocol and fake-DOM level (scripts kept outside the repository). No real browser was available to the implementer; the project owner reported manual validation of the features as a whole (SPEC-006.9, context section), but the individual manual checks are not recorded.

## Known limitations

- The registry is in memory: restarting the web server (not the container's clusters) forgets past operations.
- Stop deletes the use case's clusters and everything in them (stated in the dialog).

## Original specification (verbatim)

~~~~~text
SPEC-006.3 — Use Case Start / Stop Controls

Context

SPEC-006.1 and SPEC-006.2 are implemented and validated.

The Web UI provides:

* A working embedded ttyd terminal.
* Automatic use case discovery.
* Running / Stopped status and cluster counts.
* Automatic refresh every 3 seconds.

Objective

Add Start / Stop controls to the existing sidebar.

Reuse the existing Makefile and Bash lifecycle scripts without changing their behavior.

Keep the implementation KISS.

Requirements

1. Sidebar controls

For each use case:

* Stopped → Start button.
* Running → Stop button.
* Starting / Stopping → disabled button with progress indication.

Clicking Start or Stop must not change the selected use case or Kubernetes context.

2. Backend

Add minimal API endpoints:

POST /api/usecases/{name}/start
POST /api/usecases/{name}/stop
GET  /api/usecases/{name}/operation

Execute the existing commands:

make -C /workspace usecase-up USECASE=<name>
make -C /workspace usecase-down USECASE=<name>

Validate the use case name and directory using the existing Makefile conventions.

Do not execute commands through a shell with untrusted user input.

3. Asynchronous execution

Start / Stop operations can take several minutes.

Requirements:

* Do not block HTTP requests during provisioning.
* Run operations asynchronously.
* Track operation state: starting, stopping, succeeded, failed.
* Capture stdout and stderr.
* Prevent concurrent lifecycle operations on the same use case.
* Prevent conflicting operations against the same Kind clusters.
* Report errors clearly.

A simple in-memory operation registry is sufficient for this version.

No database, Redis, Celery or additional services.

4. Logs

Provide a minimal way to inspect operation output.

The terminal remains the primary interactive workspace.

Do not inject commands into an active ttyd session.

A small expandable log panel or modal is sufficient.

Preserve ANSI-colored output where practical, but avoid introducing a large dependency solely for log rendering.

5. Stop confirmation

Before executing Stop, display a confirmation dialog explaining:

* All Kind clusters belonging to this use case will be deleted.
* PostgreSQL resources and data stored in those clusters will be lost.
* Other use cases will remain untouched.

Require explicit confirmation.

6. Status refresh

Continue refreshing use case status automatically.

Display Starting / Stopping while an operation is active.

When an operation finishes, update the sidebar.

If an operation fails, show an error and allow the user to inspect logs.

7. Safety

* Never delete clusters belonging to another use case.
* Never silently recreate existing clusters.
* Preserve the existing Docker network initialization fix.
* Do not restart the Playground container during an active lifecycle operation.
* Do not modify the reference project.
* Do not modify existing use case scripts or provisioning logic.

8. Validation

Test:

1. Start a temporary test use case from the UI/API.
2. Verify progress and logs.
3. Verify the resulting Kind cluster.
4. Stop it after confirmation.
5. Verify complete cluster deletion.
6. Verify other use cases remain untouched.
7. Verify concurrent clicks cannot launch duplicate operations.
8. Verify the terminal remains functional.

Do not start or stop the existing single-cnpg or multi-cluster-dr use cases solely for testing.

Deliverables

* Modified files.
* API endpoints.
* Validation results.
* Known limitations.

Implement SPEC-006.3 only.
~~~~~
