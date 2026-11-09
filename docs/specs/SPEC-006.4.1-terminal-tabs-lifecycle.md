# SPEC-006.4.1 — Terminal Tabs Lifecycle

| | |
|---|---|
| Status | Implemented |
| Document type | Original specification, preserved verbatim |
| Source | Claude Code session transcript (project history), user message 2026-11-04T23:05:19.374Z UTC |
| Original specification | Available (see the last section) |

## Summary

Terminal tabs follow the lifecycle of their use case.

## Implemented behavior

- A use case tab is visible when the use case has clusters, hidden while it is `starting`, and visible while `stopping`; Playground is always visible.
- Hiding a tab removes only its iframe; the tmux session and its kubeconfig file are kept, and no tab is switched automatically except when the active tab disappears (then Playground).

## Implementation

- `web/static/app.js` (`tabEligible`, `visibleTabs`, `syncTabs`, `selectTab`).

## Later corrections and follow-ups

None recorded beyond the general ones in `docs/specs/README.md`.

## Verification

Tested by the implementer at API, WebSocket-protocol and fake-DOM level (scripts kept outside the repository). No real browser was available to the implementer; the project owner reported manual validation of the features as a whole (SPEC-006.9, context section), but the individual manual checks are not recorded.

## Known limitations

- The page cannot tell whether a hidden tab's session still exists; it is listed by `/api/terminals` (`alive`).

## Original specification (verbatim)

~~~~~text
SPEC-006.4.1 — Terminal Tabs Lifecycle

1. Context

SPEC-006.4 introduced persistent terminal sessions using tmux and ttyd.

Currently, the Web UI displays one terminal tab for every discovered use case, regardless of whether its Kind clusters are running.

We want terminal tabs to appear only when their corresponding use case is started.

2. Objective

Make terminal tab visibility depend on the use case lifecycle.

Keep the existing tmux session management unchanged wherever possible.

Do not modify Kind provisioning or the existing Start/Stop implementation.

3. Expected Behavior

Use Case State    Terminal Tab
Stopped    Hidden
Starting    Hidden
Running    Visible
Stopping    Visible
Stopped after Stop    Hidden
Failed with no clusters    Hidden
Failed with existing clusters    Visible

The Playground terminal must always remain available.

Important: Running state

The current backend considers a use case Running when at least one associated Kind cluster exists.

However, a cluster can already exist while provisioning is still in progress.

Therefore:

* Do not display the tab during an active Start operation.
* Display it once Start completes successfully and at least one cluster exists.
* If Start fails but leaves clusters behind, display the tab so the user can investigate.
* If Stop fails and clusters remain, keep the tab visible.
* During Stop, keep the tab visible until the operation finishes.

Use the existing lifecycle status and operation state.

Do not introduce a new status management system.

4. Automatic Tab Discovery

Continue using the existing API and polling mechanism.

Every 3 seconds:

* Discover the available use cases.
* Check their lifecycle state.
* Add tabs for eligible use cases.
* Remove tabs for stopped use cases.

Do not reload the page.

Do not create duplicate tabs.

Do not create unnecessary tmux sessions.

5. Start Behavior

When the user clicks Start:

1. The existing Start operation begins.
2. The sidebar displays Starting.
3. No terminal tab appears during provisioning.
4. Once Start succeeds, the terminal tab appears automatically.
5. The current terminal selection remains unchanged.

Do not automatically switch to the newly created terminal.

The user can select it when needed.

6. Stop Behavior

When the user clicks Stop:

1. The existing confirmation dialog appears.
2. The user confirms.
3. The sidebar displays Stopping.
4. The terminal tab remains visible during shutdown.
5. Once Stop completes and no clusters remain, the tab disappears.

If the removed tab was selected:

* Automatically select Playground.
* Keep the Playground terminal session intact.

If another terminal was selected:

* Preserve the current selection.

If Stop fails and clusters remain, keep the tab visible.

7. tmux Session Preservation

Tab visibility and tmux session lifecycle are separate concerns.

Hiding or removing a tab must not kill an active tmux session or interrupt a running command.

Requirements:

* Do not terminate tmux sessions when a use case stops.
* Do not kill background commands.
* Do not reset shell history.
* Do not delete terminal-specific kubeconfig files.
* Reuse the existing tmux session if the use case is started again.

The browser may remove the corresponding iframe, but the underlying tmux session must remain alive.

Existing cleanup behavior

SPEC-006.4 introduced automatic cleanup of sessions belonging to removed use case directories.

Preserve that behavior for genuinely deleted directories.

However, stopping a use case is not equivalent to deleting its directory.

Do not clean up tmux sessions merely because a use case has stopped.

8. Sidebar Integration

Keep the existing sidebar behavior:

* All valid use cases remain visible in the sidebar.
* Running/Stopped status remains visible.
* Start/Stop buttons remain functional.
* Operation logs remain accessible.

Only terminal tab visibility changes.

Clicking a stopped use case in the sidebar must:

* Highlight the use case.
* Not create a terminal tab.
* Not create a tmux session.
* Not change the active terminal.

Clicking a running use case must select its terminal tab.

If the tab has not been opened before, create/connect its terminal on demand.

9. Backend

Prefer implementing tab eligibility using the existing API data.

Avoid introducing new endpoints unless necessary.

The frontend already receives:

* Use case name.
* Running/Stopped status.
* Cluster count.
* Latest operation state.

Use this information to determine whether the tab should be visible.

Do not duplicate lifecycle logic unnecessarily.

Security

Preserve existing terminal name validation.

Do not allow arbitrary shell commands through the API.

Do not change ttyd security or networking configuration.

10. Validation

Test A — Initial state

With:

* single-cnpg running.
* multi-cluster-dr running.
* A temporary stopped use case.

Verify:

* Playground tab is visible.
* Both running use case tabs are visible.
* The stopped use case has no terminal tab.
* All three use cases remain listed in the sidebar.

Test B — Start

Start the temporary use case.

Verify:

* Its tab remains hidden during Starting.
* Its tab appears after successful provisioning.
* No automatic tab selection occurs.
* No duplicate tab is created.

Test C — Stop

Stop the temporary use case.

Verify:

* Its tab remains visible during Stopping.
* Its tab disappears after successful shutdown.
* If selected, the UI returns to Playground.
* Other terminals remain unchanged.

Test D — Session persistence

1. Open a running use case terminal.
2. Set a shell variable and change directory.
3. Stop the use case.
4. Start the use case again.
5. Reopen its terminal.

Verify that the existing tmux session is reused and its shell state is preserved.

Test E — Failure handling

Verify:

* Failed Start with no clusters: no tab.
* Failed Start with remaining clusters: tab visible.
* Failed Stop with remaining clusters: tab visible.
* Docker/API error: do not incorrectly remove existing tabs.

Test F — Regression

Verify:

* Playground terminal.
* Existing ttyd functionality.
* Sidebar discovery.
* Start/Stop buttons.
* Colored Operation logs.
* Kubernetes context isolation.
* Existing Kind clusters remain untouched.

Use temporary test use cases.

Do not destroy single-cnpg or multi-cluster-dr for testing.

11. Constraints

* KISS.
* No additional dependencies.
* No additional Docker containers.
* No new frontend framework.
* No changes to Kind provisioning.
* No changes to use case lifecycle scripts.
* No modifications to the reference project.
* Preserve the existing tmux architecture.
* Preserve the Docker network initialization fix.

12. Deliverables

Provide:

1. Modified files.
2. Explanation of tab visibility rules.
3. Explanation of tmux session preservation.
4. Validation results.
5. Known limitations.

Implement SPEC-006.4.1 only.

Do not implement Kubernetes context improvements, bottom status bar enhancements or Docker resource monitoring yet.
~~~~~
