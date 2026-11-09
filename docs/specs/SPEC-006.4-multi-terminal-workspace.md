# SPEC-006.4 — Multi-Terminal Workspace

| | |
|---|---|
| Status | Implemented |
| Document type | Original specification, preserved verbatim |
| Source | Claude Code session transcript (project history), user message 2026-11-04T22:48:18.059Z UTC |
| Original specification | Available (see the last section) |

## Summary

One persistent terminal per use case plus a permanent Playground terminal, built on one ttyd process and tmux sessions.

## Implemented behavior

- ttyd runs `engine/terminal.sh attach` with `--url-arg`: `?arg=<usecase>` selects the session; no argument = Playground. The script validates the name against `engine/usecase-list.sh --names`.
- Sessions are tmux sessions `playground-main` and `playground-uc-<name>`, created on first use and kept while the container runs. A dropped WebSocket ends only the tmux client; commands keep running.
- `GET /api/terminals` lists the tabs; `POST /api/terminals/{id}/connect` creates a session through the script (one creator at a time). Sessions of removed use cases are killed only when idle.
- Tabs and sidebar select each other without changing a Kubernetes context.
- Sessions do not survive recreating the container.

## Implementation

- `engine/terminal.sh`, `engine/shell/tmux.conf`, `Dockerfile` (`tmux`), `web/app.py` (terminal endpoints), `web/static/app.js` (tabs, iframes).

## Later corrections and follow-ups

Tab visibility: SPEC-006.4.1. Contexts: SPEC-006.4.2. Mouse/clipboard behavior: SPEC-006.7.1-FIX. UTF-8 rendering (`tmux -u`): SPEC-006.7.1-HOTFIX-2.

## Verification

Tested by the implementer at API, WebSocket-protocol and fake-DOM level (scripts kept outside the repository). No real browser was available to the implementer; the project owner reported manual validation of the features as a whole (SPEC-006.9, context section), but the individual manual checks are not recorded.

## Known limitations

- Several browser tabs attached to one session share it (size follows the most recently active).
- The idle-session reaper removes the session and its kubeconfig file when a use case directory disappears (relevant to SPEC-006.7.2).

## Original specification (verbatim)

~~~~~text
SPEC-006.4 — Multi-Terminal Workspace

1. Context

We are developing the CNPG Operator Playground, a lightweight Docker-based environment for Kubernetes and PostgreSQL demonstrations.

The current architecture includes:

* One Docker Compose Playground container.
* Kind clusters running as sibling Docker containers.
* A Bash/Makefile lifecycle engine.
* FastAPI backend.
* Vanilla HTML/CSS/JavaScript frontend.
* ttyd for the embedded terminal.
* Dynamic use case discovery.
* Sidebar Start/Stop controls.
* An Operation log panel with ANSI colors.

The following specifications are implemented and validated:

* SPEC-006.1 — Web UI Foundation
* SPEC-006.2 — Dynamic Use Case Discovery
* SPEC-006.3 — Start/Stop Controls
* SPEC-006.3.1 — Colored Operation Logs

The next objective is to provide independent, persistent terminal sessions for each use case.

2. Objective

Implement a multi-terminal workspace inspired by the killer.sh interface.

Each use case must have its own terminal session.

Users must be able to switch between terminals without losing:

* Shell history.
* Current working directory.
* Environment variables.
* Running commands.
* Interactive applications.
* Terminal output.

Switching between terminal tabs must never terminate an active command.

Keep the implementation simple and lightweight.

3. Architecture

Use:

* tmux for persistent shell sessions.
* ttyd for browser-based terminal access.
* FastAPI for session management.
* Vanilla JavaScript for terminal tab management.

Do not introduce React, Vue, Node.js, Redis, databases or additional Docker containers.

Important

Before implementing, inspect the existing ttyd configuration and determine the simplest reliable integration with tmux.

Prefer reusing the existing ttyd process if technically feasible.

However, do not force a single ttyd process to support multiple sessions if this introduces unnecessary complexity.

If multiple ttyd processes are required, explain the approach before implementing it.

4. Terminal Tabs

4.1 Default terminal

Keep a permanent terminal tab named:

Playground

This terminal:

* Starts in /workspace.
* Provides access to the existing Makefile commands.
* Is independent from the use case terminals.
* Must remain available even when no use cases exist.

4.2 Use case terminals

Create one terminal tab for each discovered use case.

Examples:

Playground | single-cnpg | multi-cluster-dr

Each terminal must:

* Start in /workspace/usecases/<name>.
* Have an independent shell.
* Maintain its own working directory.
* Maintain its own command history and environment.
* Support interactive commands.

The use case names must be discovered dynamically.

Do not hardcode single-cnpg or multi-cluster-dr.

4.3 Tab selection

Clicking a tab displays the corresponding terminal.

Requirements:

* The selected tab must be visually highlighted.
* Switching tabs must be immediate.
* The previous terminal session must remain alive.
* Running commands must continue executing.
* Returning to a tab must restore its terminal state.

Do not restart a shell when switching tabs.

4.4 Sidebar integration

The existing sidebar remains responsible for:

* Use case discovery.
* Running/Stopped status.
* Cluster count.
* Start/Stop actions.

Clicking a use case in the sidebar should select its corresponding terminal tab.

Clicking a terminal tab should also highlight the corresponding sidebar entry.

Selecting the Playground terminal should clear the use case selection.

Do not change the Kubernetes context automatically.

5. Persistent Sessions

5.1 tmux

Use tmux to manage persistent shell sessions.

Suggested session identifiers:

* playground-main
* playground-single-cnpg
* playground-multi-cluster-dr

These are examples only.

Use a safe and deterministic naming convention.

5.2 Session lifecycle

A terminal session should be created when first accessed.

It must remain available while the Playground container is running.

Switching tabs must not destroy the session.

Closing or refreshing the browser must not terminate the session.

Reopening the Web UI must reconnect to the existing session.

5.3 Use case lifecycle independence

Terminal sessions must be independent from Kind cluster lifecycle.

For example:

1. Start single-cnpg.
2. Open its terminal.
3. Execute a command.
4. Switch to multi-cluster-dr.
5. Return to single-cnpg.

The original shell must still exist.

Likewise, stopping a use case must not automatically destroy its terminal session.

5.4 Removed use cases

If a use case directory disappears:

* Remove its tab from the UI.
* Do not abruptly terminate a running shell.
* Avoid orphaned processes.

For this specification, implement a safe, minimal cleanup strategy and document its behavior.

Do not automatically kill a session containing a running command.

6. ttyd Integration

Preserve all existing terminal capabilities:

* Interactive shell.
* Command history.
* Tab completion.
* Ctrl+C.
* Terminal resizing.
* ANSI colors.
* Interactive applications such as less, watch, and vim.
* WebSocket connectivity.

Critical constraint

The existing implementation includes an important Docker networking fix:

The Playground container must join the Kind Docker network before ttyd starts.

Do not regress this behavior.

A WebSocket disconnection must not terminate an active tmux command.

Browser behavior

Ensure that:

* Switching tabs does not destroy the underlying terminal session.
* Hidden terminals do not interfere with keyboard input.
* Returning to a terminal restores proper focus.
* Terminal resizing works after switching tabs.

Use a simple implementation with terminal iframes or another lightweight approach compatible with ttyd.

Avoid unnecessary complexity.

7. Backend

Implement only the API endpoints required for terminal session management.

Suggested endpoints:

GET  /api/terminals
POST /api/terminals/{name}/connect

These are suggestions, not mandatory contracts.

The backend should:

* Validate terminal identifiers.
* Reuse existing use case discovery.
* Create tmux sessions when needed.
* Reconnect to existing sessions.
* Never execute arbitrary commands supplied by the browser.
* Prevent duplicate session creation.
* Return clear errors.

Do not expose unrestricted shell execution through FastAPI.

The interactive shell must remain accessible only through ttyd.

8. Frontend

Extend the existing interface rather than redesigning it.

Layout

Keep:

* Existing header.
* Existing sidebar.
* Existing Operation log panel.
* Existing bottom status bar.

Add a horizontal terminal tab bar above the terminal area.

Example:

┌───────────────────────────────────────────────────────────────┐
│ CNPG Operator Playground                                      │
├────────────────┬──────────────────────────────────────────────┤
│ USE CASES      │ Playground | single-cnpg | multi-cluster-dr  │
│                ├──────────────────────────────────────────────┤
│ single-cnpg    │                                              │
│ Running        │                                              │
│ [Stop]         │              ACTIVE TERMINAL                 │
│                │                                              │
│ multi-cluster  │                                              │
│ Running        │                                              │
│ [Stop]         │                                              │
│                │                                              │
├────────────────┴──────────────────────────────────────────────┤
│ Status bar                                                    │
└───────────────────────────────────────────────────────────────┘

Requirements

* Maintain the existing dark theme.
* Preserve responsive behavior.
* Avoid full-page reloads.
* Do not recreate terminal sessions unnecessarily.
* Keep the existing sidebar polling functional.
* Preserve the Operation log panel.

9. Kubernetes Context

Each terminal must maintain its own shell state.

However, Kubernetes context handling requires special attention.

Inspect how KUBECONFIG and kubectl config use-context are currently managed.

If terminals share the same kubeconfig file, changing the current context in one terminal may affect the others.

Do not assume tmux sessions automatically isolate Kubernetes contexts.

For this specification:

* Identify the existing kubeconfig behavior.
* Implement a minimal, safe isolation mechanism if needed.
* Preserve access to all existing Kind clusters.
* Do not automatically switch contexts when selecting tabs.
* Do not modify cluster provisioning logic.

Document the resulting behavior clearly.

10. Validation

Perform the following tests.

Test A — Independent shells

1. Open the Playground terminal.
2. Change its directory.
3. Open the single-cnpg terminal.
4. Verify its initial directory.
5. Change its directory.
6. Return to Playground.
7. Verify its original directory is preserved.

Test B — Persistent commands

1. Start a long-running command in one terminal.
2. Switch to another terminal.
3. Wait several seconds.
4. Return to the original terminal.
5. Verify the command continued running.

Test C — Browser refresh

1. Start an interactive shell session.
2. Execute commands.
3. Refresh the browser.
4. Reconnect.
5. Verify the shell state is preserved.

Test D — Interactive behavior

Verify:

* Ctrl+C.
* Tab completion.
* less.
* Terminal resize.
* ANSI colors.
* Shell history.

Test E — Dynamic discovery

1. Create a temporary valid use case directory.
2. Verify a terminal tab appears.
3. Open the terminal.
4. Verify its initial working directory.
5. Remove the temporary directory.
6. Verify the tab disappears without unexpectedly killing active commands.

Test F — Existing functionality

Verify:

* Sidebar discovery.
* Running/Stopped status.
* Start/Stop buttons.
* Operation log panel.
* Docker networking.
* Existing Kind clusters remain untouched.

Do not destroy existing clusters for testing.

11. Constraints

* KISS architecture.
* No additional Docker containers.
* No frontend frameworks.
* No database.
* No unnecessary dependencies.
* No modifications to the reference project.
* No changes to existing use case scripts.
* No changes to Kind provisioning.
* Preserve existing Start/Stop behavior.
* Preserve existing colored Operation logs.

12. Deliverables

Provide:

1. Architecture decisions, especially tmux/ttyd integration.
2. List of modified files.
3. Description of terminal session lifecycle.
4. Kubernetes context isolation behavior.
5. Validation results.
6. Known limitations.

Implementation Instructions

First inspect the existing implementation and explain the proposed tmux/ttyd integration.

Pay particular attention to:

* Terminal persistence.
* WebSocket behavior.
* Session lifecycle.
* Kubernetes context isolation.
* Docker network initialization.

Then implement SPEC-006.4 only.

Do not implement the bottom status bar enhancements or Docker resource monitoring yet.

Do not modify unrelated components.
~~~~~
