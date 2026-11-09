# SPEC-009 — Multi-Terminal Split View

Status: implemented and verified (headless Chrome against the live Web UI, plus WebSocket checks). No container rebuild is needed.

## Implementation

- **Review result.** ttyd starts one process per WebSocket connection, so several iframes on the same endpoint are already separate Bash processes. The only shared thing was the kubeconfig file, keyed by use case. `--url-arg` forwards every `arg` query parameter, which carries the panel number. No backend change was needed.
- `engine/terminal.sh [usecase [panel]]`: `panel` is 2-4 and only valid with a use case. A panel gets `playground-uc-<usecase>-p<N>.yaml`, rewritten on every start to the use case's initial context (never inherited, no credentials copied; clusters and users still come from the shared `~/.kube/config`). Panel 1 is exactly as before.
- `web/static/{index.html,app.js,style.css}`: a tab is a `.pane` (CSS Grid, `data-count` 1-4) of `.cell`s, each an iframe. The **Split Terminal** button (use case tabs only, hidden at 4) adds the lowest free slot; the **✕** on panels 2-4 removes the iframe, which ends only that Bash. The "Terminal N" label appears only when split. Hiding a use case tab or reloading the page drops every panel (no persistence).
- `tests/terminal.sh`: panel file, context, no inheritance, invalid panels refused.

## Enhancement: resizable panels

Draggable separators between panels (pointer events, no dependency). `app.js` adds one vertical and one horizontal separator per pane; dragging sets `--cx` / `--cy` (fractions) on the pane, and the grid template in `style.css` uses them. Layouts are unchanged: 2 = column boundary; 3 = column boundary plus the row boundary of the right column; 4 = column and row boundaries (shared by both columns / rows). Each side keeps at least 160 px; double-click a separator to return to an even split. Only the grid changes, so iframes resize in place: ttyd's own window-resize handler refits xterm.js, and no terminal is recreated or reconnected. Verified live: separator drags for 2, 3 and 4 panels, minimum sizes, double-click reset, pty rows/columns following the cells, same Bash processes, a `sleep` running in a panel unaffected, closing a panel still working, single terminal without separators. Resizing is not remembered (neither are splits).

## Limits

- Panel labels keep their slot number (closing 2 leaves 1, 3, 4 in that order).
- Panels are not remembered across a refresh, as specified.
- Selection, scrolling and copy/paste are unchanged (same ttyd iframes) but were not exercised in a desktop browser.

## Original request (condensed: the ASCII layout diagrams and some lists are shortened, no requirement is dropped)

~~~~~
SPEC-009 — Multi-Terminal Split View

Project: CNPG Operator Playground
Priority: Medium
Status: Implementation requested

1. Objective

Add the ability to split a use-case terminal into multiple independent terminal panels.

The primary use case is educational: users should be able to execute a guided scenario while simultaneously running their own commands.

Examples:

* Execute scenario commands manually.
* Watch Kubernetes pods during a failover.
* Follow CNPG operator logs.
* Run PostgreSQL queries while observing cluster behavior.

The existing single-terminal experience must remain unchanged.

2. Non-Negotiable Requirements

This feature must not introduce regressions.

Preserve:

* Existing ttyd/xterm.js architecture.
* Native scrolling and scrollback.
* Mouse text selection.
* Cmd+C / Cmd+V.
* Vim and interactive commands.
* ui_watch.
* Browser refresh behavior.
* Kubernetes context isolation.
* Existing use-case lifecycle.
* Playground CLI.
* Existing scenarios.

Do not reintroduce tmux.

Do not modify scenario scripts.

Do not refactor unrelated code.

Follow KISS principles.

3. User Experience

Default

When opening a use case, display exactly one terminal, as today.

No visible change to the existing terminal behavior.

Split

Add a Split Terminal button to the use-case terminal toolbar.

Clicking it creates an additional terminal.

Support up to 4 terminals per use-case tab.

Each terminal must have:

* Its own Bash session.
* Its own command history.
* Its own scrollback.
* Its own Kubernetes configuration.
* A close button.

The original terminal must remain available throughout.

Layout

Use automatic layouts: 1 terminal full; 2 terminals side by side; 3 terminals with Terminal 1 on the left and Terminals 2 and 3 stacked on the right; 4 terminals in a 2x2 grid.

Use CSS Grid or Flexbox.

No drag-and-drop, nested splits or complex window management.

Keep the implementation simple.

4. Kubernetes Context Management

This is a critical requirement.

All terminals belonging to the same use-case tab must start with the same Kubernetes context.

However, each terminal must have its own KUBECONFIG file.

This ensures:

* Changing context in Terminal 2 does not affect Terminal 1.
* A scenario can continue running independently.
* Every terminal initially targets the correct use-case cluster.

Reuse the existing kubeconfig initialization mechanism.

Extend it minimally to support a terminal/panel identifier.

Do not introduce a shared mutable kubeconfig.

Do not copy stale Kubernetes credentials.

Preserve the current approach that references the up-to-date cluster configuration.

5. Terminal Lifecycle

Opening a split

* Create a new Bash session.
* Initialize the correct Kubernetes context.
* Display the terminal immediately.
* Do not interrupt existing terminals.

Closing a split

* Terminate only that terminal's Bash session.
* Remove its panel.
* Automatically adjust the layout.
* Do not affect other terminals.

Closing the use-case tab

Preserve the existing tab lifecycle behavior.

Do not leave orphan terminal processes.

Browser refresh

Session persistence is not required.

After refresh, returning to a single terminal is acceptable.

Do not introduce persistence mechanisms.

Maximum terminals

Limit the number of panels to four.

Disable or hide the Split button when the limit is reached.

6. Technical Implementation

Before changing anything, inspect the current implementation of: ttyd terminal endpoints; backend terminal management; frontend terminal rendering; per-tab kubeconfig initialization; terminal lifecycle and cleanup.

Determine the smallest safe implementation.

Important:

Do not assume that opening multiple iframes against the same ttyd endpoint automatically provides isolated sessions.

Verify how the current ttyd server handles multiple connections.

Each panel must correspond to a distinct Bash process and a distinct kubeconfig.

Prefer reusing the existing ttyd infrastructure.

Do not introduce: tmux; another terminal server; a frontend framework; a new session manager; a generic terminal orchestration framework.

If the existing architecture cannot support independent terminals safely without significant changes, stop and explain the limitation before proceeding.

7. UI Design

Keep the existing Playground visual design.

Add only: a Split Terminal button; a small terminal label or number; a close button for additional panels.

The first terminal is the primary scenario terminal.

It should not be accidentally closed.

Do not redesign the toolbar, navigation or use-case tabs.

Ensure that resizing the browser adjusts terminal dimensions correctly.

Avoid unnecessary UI features.

8. Validation — Focused and Lightweight

Do not build an extensive test framework.

Checks: single-terminal mode; split creates an independent Bash; splits up to four; all terminals start with the correct Kubernetes context; changing context in one does not affect the others; closing one panel leaves the others running; closing the use-case tab cleans up its sessions; scrolling and copy/paste; Vim and ui_watch; browser refresh returns to a working terminal.

Use non-destructive commands only. Do not execute educational scenarios. Prefer a small number of targeted tests.

9. Infrastructure Safety

Do not: delete or recreate Kind clusters; modify PostgreSQL resources; modify MinIO buckets; reset use cases; modify scenario scripts; rebuild the Playground container without authorization; restart existing services without authorization; push or tag the repository.

10. Implementation Strategy

Phase 1 — Architecture Review. Phase 2 — Implementation (smallest viable solution). Phase 3 — Validation (focused, non-destructive). Phase 4 — Report: files modified, implementation approach, validation results, known limitations, whether a container rebuild is required.

11. Acceptance Criteria

The Playground still works exactly as before with one terminal; users can split a use-case tab into up to four terminals; every terminal has an independent Bash session and starts with the correct Kubernetes context; context changes remain isolated; closing a split does not affect other terminals; scrolling, selection and copy/paste remain natural; no Kubernetes infrastructure or data is modified.

Simplicity, reliability and backward compatibility take priority over additional functionality.

12. Execution Instructions

Proceed with the architecture review and implementation. Do not rebuild or restart the running Playground. If significant architectural changes are necessary, stop and request approval. Do not push or tag anything. Keep the final report concise.
~~~~~
