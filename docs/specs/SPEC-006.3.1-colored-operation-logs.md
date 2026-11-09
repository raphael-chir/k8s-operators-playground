# SPEC-006.3.1 — Preserve Logger Colors in Web UI

| | |
|---|---|
| Status | Implemented |
| Document type | Original specification, preserved verbatim |
| Source | Claude Code session transcript (project history), user message 2026-11-04T22:43:08.250Z UTC |
| Original specification | Available (see the last section) |

## Summary

The colors of the project's logger are kept in the operation log panel.

## Implemented behavior

- `engine/lib/logger.sh` colors output on a terminal or when `PLAYGROUND_FORCE_COLOR=1`; the backend sets it when launching operations. `NO_COLOR` still wins. The palette is unchanged.
- The page converts ANSI SGR sequences (256-color foreground, bold, reset) to DOM nodes with `textContent` only (no HTML injection), carrying style state across polling chunks so a sequence split between two chunks renders correctly.

## Implementation

- `engine/lib/logger.sh` (one condition), `web/app.py` (environment of the launched process), `web/static/app.js` (`appendAnsi`, `applySgr`, `color256`).

## Later corrections and follow-ups

The log panel stays dark in both themes (SPEC-006.8.1) because its colors are designed for a dark background.

## Verification

Tested by the implementer at API, WebSocket-protocol and fake-DOM level (scripts kept outside the repository). No real browser was available to the implementer; the project owner reported manual validation of the features as a whole (SPEC-006.9, context section), but the individual manual checks are not recorded.

## Known limitations

None recorded beyond the general ones in `docs/specs/README.md`.

## Original specification (verbatim)

~~~~~text
SPEC-006.3.1 — Preserve Logger Colors in Web UI

Context

SPEC-006.3 is implemented and validated.

The Start/Stop buttons work correctly, and the Web UI displays operation logs in real time.

However, the log panel displays plain text, while our existing Bash logger uses ANSI colors.

Objective

Display the original Bash logger colors in the Web UI log panel.

Keep the implementation minimal and preserve the existing logging behavior.

Requirements

1. Bash logger

Inspect lib/logger.sh and its current color detection mechanism.

Introduce an optional environment variable, for example:

PLAYGROUND_FORCE_COLOR=1

When enabled, the logger should emit its existing ANSI colors even when stdout is redirected.

Default behavior must remain unchanged.

Do not modify the existing color palette, log format or timestamps.

2. Backend

When FastAPI starts a use case operation:

* Set PLAYGROUND_FORCE_COLOR=1 in the subprocess environment.
* Preserve ANSI escape sequences in captured logs.
* Keep the existing asynchronous execution and log polling.
* Do not affect normal terminal execution.

3. Frontend

Render ANSI colors safely in the existing log panel.

Requirements:

* Support the ANSI SGR color sequences actually emitted by our logger.
* Preserve line breaks and formatting.
* Escape untrusted HTML.
* Do not use innerHTML with unsanitized log content.
* Avoid introducing a large JavaScript dependency.
* Keep incremental log polling working correctly.
* Handle ANSI sequences split across polling chunks.

If a small ANSI-to-HTML parser is sufficient, implement it locally.

4. Validation

Test:

* INFO messages retain their original color.
* SUCCESS messages retain their original color.
* ERROR messages retain their original color.
* SECTION messages retain their original color.
* Timestamps and formatting remain unchanged.
* Logs continue streaming correctly.
* The terminal’s existing logger behavior remains unchanged.
* No regression in Start/Stop operations.

Constraints

* No additional containers.
* No new frameworks.
* No changes to Kubernetes provisioning.
* No changes to existing use cases.
* Do not modify the reference project.
* Keep changes limited to the logger and Web UI logging components.

Implement SPEC-006.3.1 only.
~~~~~
