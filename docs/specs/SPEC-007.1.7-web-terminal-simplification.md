# SPEC-007.1.7: Web Terminal Simplification

| | |
|---|---|
| Status | Implemented, deployed (image rebuilt, container recreated, with the owner's approval) and validated against the live ttyd with headless Chrome. Not tested by a person in a desktop browser |
| Document type | Original specification, preserved verbatim, with the implementation record |
| Source | Claude Code session transcript (project history), user message of 2026-11-05 |
| Target version | `1.0.0-rc.1` (unchanged) |
| Relation | Supersedes the tmux design of [SPEC-006.4](SPEC-006.4-multi-terminal-workspace.md) (persistent sessions) and the tmux parts of [SPEC-007.1.4](SPEC-007.1.4-web-terminal-scrollback.md) (tmux scrollback, Option-click selection). The `clear -x` and `ui_watch` alternate-screen fixes of 007.1.4 are kept |

## Result

One browser connection is one Bash. `engine/terminal.sh` (run by ttyd for every connection) validates the optional use case, writes the terminal's kubeconfig file, sets `LANG=C.UTF-8`, goes to the starting directory and `exec`s Bash. tmux is removed from the image, the CLI, the backend, the frontend, the tests and the docs.

| Area | Change |
|---|---|
| `Dockerfile` | `tmux` package removed; ttyd `-t scrollback=10000` (default 1000) replaces `-t macOptionClickForcesSelection=true`; ttyd runs `bash /workspace/engine/terminal.sh` (no `attach`) |
| `engine/terminal.sh` | No `ensure`/`attach`, no session logic. Keeps use case validation, the per-terminal kubeconfig file (`~/.kube/terminals/playground-main.yaml`, `playground-uc-<name>.yaml`, kept when it already has a context), starting directory; adds `export LANG=C.UTF-8` (replaces `tmux -u`); ignores a leading `attach` so a container created before this change keeps working |
| `engine/shell/tmux.conf` | Deleted |
| `engine/shell/bashrc` | Unchanged except a comment: `clear` still runs `clear -x` (ESC[3J would erase xterm.js's scrollback) |
| `web/app.py` | tmux helpers, `_busy`, orphan reaping and `POST /api/terminals/{id}/connect` removed; `GET /api/terminals` lists the tabs; status `no-session` now means the terminal's file does not exist yet |
| `web/static/app.js` | No connect call: the iframe is created directly; comments updated |
| `playground restart` | The "terminals will be closed" warning counts ttyd's child shells instead of tmux sessions |
| `tests/terminal.sh` | New: no tmux anywhere, scrollback 10000, no Option workaround, terminal.sh behavior in a throwaway container |
| `tests/cli.sh` | Fake `docker exec` answers the shell count instead of tmux |
| Docs | Architecture, user guide, CLI, installation, README, CONTRIBUTING, CLAUDE.md, release checklist, index |

Untouched: Kind clusters, PostgreSQL, PVCs, MinIO, Prometheus, Grafana, backups. No scenario was run, nothing was reset, nothing was pushed or tagged.

## Behavior

| Action | Result |
|---|---|
| Open a terminal | New Bash |
| Refresh (F5) / close / reopen | Bash ends; a new Bash starts (a running command is interrupted; ttyd shows a "leave page?" prompt on F5) |
| Another terminal or the raw port 7681 | Independent Bash |
| Container restart or recreate | All terminals end |
| Kubernetes context | `~/.kube/terminals/<terminal>.yaml` first in `KUBECONFIG`. A new terminal starts on the use case's cluster 1 (Playground: the shared default); a context chosen with `use-context` survives a refresh because an existing file is kept and a new connection never rewrites it |

Decision (owner): the per-tab kubeconfig file stays; no per-connection files. Two connections to the same tab (for example the raw port 7681 opened twice) share one context file.

## Validation

### Isolated test (Phase 1)
Throwaway container from the Playground image, project mounted, ttyd on a different port with `scrollback=10000` and no tmux; driven through the Chrome DevTools Protocol in headless Chrome 156 (real xterm.js and real mouse/keyboard events), then removed.

| Test | Result |
|---|---|
| scrollback option | 10000 |
| 400 lines | complete and ordered (1..400) |
| 10,500 lines | buffer capped at 10000 + screen; last lines intact |
| Mouse wheel | scrolls up |
| Left-drag, no modifier | multi-line selection |
| Cmd+C | selection reaches the clipboard exactly |
| Ctrl+C, no selection | SIGINT (`^C`, prompt back) |
| Multi-line paste (Cmd+V) | pasted intact (Bash's bracketed paste), runs both lines on Enter |
| Vim | alternate screen; on exit normal buffer and history intact |
| `ui_watch` (as a child script, like the scenarios) | alternate screen; Enter and Ctrl+C restore; history grows by 0 lines |
| `clear` | scrollback kept |
| Resize | xterm.js and `stty size` agree |
| Reload | new Bash PID, empty buffer; ttyd's `beforeunload` prompt appears |
| Two terminals (Playground, `?arg=cnpg-standard`) | different PIDs; use case terminal starts in `scenarios/`, own file, context `kind-cnpg-lab-cnpg-standard-1`, `LANG=C.UTF-8`; `use-context` in one leaves the other's file untouched |
| Closing the browser | no Bash left in the container |

Observation: `ui_watch` called directly in the interactive shell (not as a script) does not leave the alternate screen on Ctrl+C because its EXIT trap fires only when a shell exits. Scenarios always run it as a child script, so they are unaffected; it is not a regression (the same code ran under tmux).

### Repository tests
`tests/static.sh`, `tests/cli.sh`, `tests/engine.sh`, `tests/terminal.sh` pass; API checked in a throwaway container (`/api/terminals`, `/api/meta`, `/api/status?terminal=main`, `connect` gone).

## Follow-up changes made after approval

1. **`ui_watch` Ctrl+C from an interactive prompt** (`engine/lib/ui.sh`): the loop now runs in a subshell. Called straight at the prompt, Ctrl+C used to abort the function without running its EXIT trap (the trap only fires when a shell exits), leaving the alternate screen on, and `trap - EXIT` would have removed the caller's own EXIT trap. In the subshell the trap fires on Ctrl+C and Enter in both modes and the caller's trap is untouched. Verified in the browser, both invocation modes: alternate screen entered, Ctrl+C and Enter return to the normal screen, the shell stays usable, the caller's EXIT trap survives, no history growth. `tests/scenarios.sh` still passes.
2. **Stale cluster data in a terminal's kubeconfig file** (`engine/terminal.sh`, found during the live check; it predates this spec): the existing `cnpg-standard` terminal file (written at 17:05 UTC by an earlier scheme) held a full copy of the cluster, user and certificates. kubectl resolves a cluster from the first file that defines it, so after the Kind cluster was recreated, `kubectl` in that terminal failed with `x509: certificate signed by unknown authority`. `terminal.sh` now keeps only the file's `current-context` (or the initial context) and rewrites the file with that alone, every time a terminal starts. The kept-selection behavior is unchanged (the per-tab design stays). Tested in `tests/terminal.sh` (seeded file with stale entries) and live: both terminals reach the 4 nodes, file 75 bytes.

## Deployment (done)

`./playground install` (image rebuilt without tmux) and `./playground start` (container recreated). All terminals that were open ended. Kind node containers (same IDs), volumes, Kubernetes pods, PVCs and monitoring were compared before and after: identical. At that time the `default` namespace held no PostgreSQL resources (the use case had been restarted before this work; nothing in this change touched them).

### Live validation (after the rebuild)
| Check | Result |
|---|---|
| ttyd command | `ttyd ... -t scrollback 10000 bash /workspace/engine/terminal.sh`; tmux not installed, no tmux process |
| Scrollback | `term.options.scrollback` = 10000; 400 lines complete and ordered; 10,500 lines: buffer capped at 10040 with the last lines intact |
| Wheel, plain drag selection (multi-line), Cmd+C to the clipboard, Ctrl+C without selection, multiline paste (inserted intact, runs on Enter), Vim, `clear`, resize | pass |
| `ui_watch` | pass in both modes (see above) |
| Reload | new Bash PID, empty buffer; ttyd's `beforeunload` prompt appears |
| Contexts | two terminals independent; use case terminal in `scenarios/`, own file, `kind-cnpg-lab-cnpg-standard-1`; `use-context` in one leaves the other's file untouched |
| Web UI (port 8080) | tabs Playground and cnpg-standard, one ttyd iframe each, status bar shows the context; `/api/meta`, `/api/terminals`, `/api/usecases`, `/api/status`, `/api/docker/resources` healthy |
| Clusters | 4 Kind nodes Ready; `kubectl get nodes` works from both terminals |
| Repository tests | `static`, `cli`, `engine`, `terminal`, `scenarios` pass |

## Manual checks still to run (real browser, after the rebuild)
Trackpad scrolling feel and the scrollbar (wheel events were tested, not a physical trackpad); Cmd+C / Cmd+V in Safari and Chrome on macOS (tested with Chrome's copy and paste commands, headless); the F5 prompt wording.

## Limitations
- No session persistence by design.
- The context file is per tab (see above).
- A reload during a long foreground command interrupts it.

## Original specification (verbatim)

~~~~~
SPEC-007.1.7 — Web Terminal Simplification

Project: CNPG Operator Playground
Release: v1.0.0-rc.1
Priority: Critical
Status: Approved for implementation

1. Objective

Simplify the Playground Web terminal architecture by removing tmux and using ttyd/xterm.js directly with Bash.

The current tmux-based implementation introduces unnecessary complexity and usability regressions, particularly with mouse scrolling, text selection and copy/paste.

The target is a simple, reliable Web terminal similar to Killercoda.

Primary objective: native terminal usability over session persistence.

2. Target Architecture

Current

Browser
   |
   v
ttyd / xterm.js
   |
   v
tmux
   |
   v
Bash
   |
   v
kubectl / CNPG / Playground commands

Target

Browser
   |
   v
ttyd / xterm.js
   |
   v
Bash
   |
   v
kubectl / CNPG / Playground commands

Remove tmux from the terminal execution path.

Do not replace it with another session manager.

3. Functional Requirements

3.1 Scrolling

The Web terminal must support:

* Natural scrolling with a mouse wheel.
* Natural scrolling with a macOS trackpad.
* A standard scrollbar when supported by the terminal frontend.
* Reliable scrolling through long command outputs.
* No missing, duplicated or reordered lines.
* No unexpected jumps to the bottom while reviewing previous output.

The terminal must retain sufficient scrollback history for normal Playground usage.

Target: at least 10,000 lines.

3.2 Text Selection

Text selection must behave like a normal terminal:

* Left-click and drag to select text.
* No Option, Shift or other modifier required.
* Support multiline selection.
* Selection must work on previously displayed output.

3.3 Copy and Paste

On macOS:

* Cmd+C copies selected text to the system clipboard.
* Cmd+V pastes clipboard content into the terminal.
* Copying selected text must not interrupt the running command.
* When no text is selected, Ctrl+C must continue to send SIGINT.
* Multiline paste must work correctly.

Prefer the native ttyd/xterm.js clipboard behavior.

Do not implement custom clipboard JavaScript unless strictly necessary.

3.4 Interactive Applications

The following must continue to work:

* Bash interactive shell.
* Vim.
* kubectl.
* kubectl cnpg.
* psql.
* Existing Playground scenario scripts.
* ui_watch.
* Interactive prompts and confirmations.

Alternate-screen applications such as Vim must not corrupt the normal terminal history.

3.5 Browser Refresh

Session persistence is no longer required.

Expected behavior:

Action    Expected result
Open terminal    Start a new Bash session
Refresh browser (F5)    Start a new Bash session
Close terminal    Terminate its Bash session
Reopen terminal    Start a new Bash session
Temporary network disconnection    Session may terminate
Open another terminal    Start an independent Bash session

A browser refresh may interrupt the command currently running in that terminal.

This behavior is accepted.

A browser refresh must never reset Kubernetes infrastructure or PostgreSQL data.

3.6 Kubernetes Context Isolation

Preserve the existing terminal isolation mechanism.

Requirements:

* Each terminal must have its own KUBECONFIG.
* Opening a new terminal must not modify another terminal's Kubernetes context.
* Playground and use-case terminals must continue to select the appropriate contexts.
* Refreshing a terminal must initialize its Kubernetes context correctly.
* Existing Kind clusters must remain unchanged.

Do not replace isolated kubeconfig files with a shared mutable configuration.

4. Implementation

4.1 Remove tmux

Inspect the existing terminal implementation.

Identify all tmux dependencies in:

* Dockerfile.
* Container entrypoint.
* Terminal session management.
* Backend terminal endpoints.
* Shell initialization.
* Configuration files.
* Tests.
* Documentation.

Remove tmux from the terminal execution path.

Remove obsolete tmux configuration and session-management code where no longer needed.

Do not remove unrelated functionality.

4.2 Direct Bash Execution

Configure ttyd to launch Bash directly through the existing terminal initialization mechanism.

Preserve:

* Environment variables.
* Shell initialization.
* Existing Playground commands.
* Kubernetes context initialization.
* Working directory.
* Terminal dimensions and resize handling.

Avoid introducing new wrappers unless required for terminal initialization or Kubernetes context isolation.

4.3 ttyd / xterm.js Configuration

Use the existing ttyd installation.

Configure:

* Scrollback: at least 10,000 lines.
* Native mouse selection.
* Native copy/paste.
* Terminal resize support.
* Standard terminal keyboard behavior.

Remove the previous workaround:

macOptionClickForcesSelection=true

It should no longer be necessary.

Do not introduce a custom terminal frontend.

4.4 Clear and ui_watch

Preserve the existing improvements that prevent terminal history corruption.

Verify:

* clear clears the visible screen without unnecessarily erasing scrollback.
* ui_watch uses the alternate screen correctly.
* Repeated refreshes do not pollute terminal history.
* Enter restores the previous display.
* Ctrl+C exits cleanly.

Adapt these mechanisms only if necessary for direct ttyd/Bash operation.

5. Validation Strategy

Phase 1 — Isolated Testing

Before modifying the running Playground:

1. Create a temporary ttyd/Bash test environment.
2. Test without tmux.
3. Validate scrolling and text selection.
4. Validate copy/paste.
5. Validate Vim and alternate-screen behavior.
6. Validate ui_watch.
7. Validate browser refresh behavior.

Use a real browser when possible.

Do not rely exclusively on simulated terminal output.

Phase 2 — Implementation

If the isolated tests are successful:

1. Implement the minimal architecture changes.
2. Update existing tests.
3. Remove obsolete tmux dependencies.
4. Validate shell scripts and configuration.

Phase 3 — Playground Deployment

Do not rebuild or recreate the running Playground container without explicit authorization.

Once the implementation is ready:

1. Report the proposed changes.
2. Explain any impact on existing terminal sessions.
3. Request authorization before rebuilding or recreating the container.

6. Acceptance Tests

Test    Expected result
300+ lines of output    Complete, ordered history
10,000+ lines of output    Scrollback remains usable
Mouse wheel    Natural scrolling
macOS trackpad    Natural scrolling
Left-click + drag    Text selection
Cmd+C    Copy selected text
Cmd+V    Paste text
Multiline selection    Works
Multiline paste    Works
Vim    Opens and exits normally
ui_watch    No history pollution
Terminal resize    No corrupted output
Browser refresh    New Bash session
Multiple terminals    Independent sessions
Kubernetes contexts    Properly isolated
PostgreSQL clusters    Unchanged

Test both the Playground terminal and the use-case terminal.

7. Infrastructure Safety

The following resources must remain untouched:

* Kind clusters and nodes.
* PostgreSQL clusters and data.
* PostgreSQL PVCs.
* MinIO buckets and objects.
* Prometheus data.
* Grafana dashboards.
* Existing backups.

Do not execute educational scenarios.

Do not perform destructive Kubernetes operations.

Do not reset the Playground.

Do not push or tag the repository.

8. Documentation

Create:

docs/specs/SPEC-007.1.7-web-terminal-simplification.md

Update:

* Specification index.
* Architecture documentation.
* Release checklist.
* Terminal usage documentation, if applicable.

Remove obsolete references to tmux session persistence.

Document that refreshing the browser creates a new terminal session.

9. Design Principles

* KISS.
* Native terminal behavior.
* No session persistence.
* No additional dependencies.
* No custom JavaScript clipboard implementation.
* No unnecessary session-management abstractions.
* Preserve existing Kubernetes context isolation.
* Minimize code changes.

Do not introduce a replacement for tmux.

10. Expected Result

A reliable Web terminal with the following behavior:

Natural scrolling + normal text selection + standard copy/paste + reliable scrollback.

The terminal should behave as closely as possible to a conventional desktop terminal.

Browser refresh starts a new Bash session without affecting the underlying Kubernetes infrastructure.

11. Execution Instructions

1. Inspect the existing terminal architecture.
2. Identify tmux dependencies.
3. Validate direct ttyd/Bash operation in an isolated environment.
4. Implement the minimal changes.
5. Run non-destructive tests.
6. Document the results.
7. Report any limitations.
8. Request authorization before rebuilding the running Playground container.

Do not push or tag anything.
~~~~~
