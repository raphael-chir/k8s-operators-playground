# SPEC-006.7.1 — Playground UX Improvements

| | |
|---|---|
| Status | Implemented (clipboard and prompt parts superseded by SPEC-006.7.1-FIX) |
| Document type | Original specification, preserved verbatim |
| Source | Claude Code session transcript (project history), user message 2026-11-05T10:18:34.542Z UTC |
| Original specification | Available (see the last section) |

## Summary

Seven UX improvements: scenarios start directory, compact prompt, clipboard, start timer, CPU visualization, wider and collapsible sidebar, prompt consistency after scenarios.

## Implemented behavior

- New use case sessions start in `usecases/<name>/scenarios` (use case root as fallback); existing sessions keep their directory.
- Start timer: operations report `started_at`, `elapsed`, `since_finished` (server clock); the sidebar shows `Starting… MM:SS`, `Running — MM:SS` briefly, or `failed … — MM:SS`, driven by one 1 s ticker that survives refreshes.
- CPU: percentage of total Engine capacity with a matching bar and `used / total cores`.
- Sidebar 220 → 293 px and collapsible (CSS class only, remembered in `localStorage`).
- Prompt consistency: scenarios are child processes and cannot change the prompt; the one exception, `ui_login`'s `exec su -`, lost `KUBECONFIG` and the directory, so it became `su -m`.

## Implementation

- `engine/terminal.sh`, `engine/shell/bashrc`, `engine/lib/ui.sh` (`su -m`), `web/app.py`, `web/static/*`.

## Later corrections and follow-ups

SPEC-006.7.1-FIX replaced the clipboard button with native selection and changed the prompt; SPEC-006.7.1-HOTFIX restored `ui.sh`; SPEC-006.7.1-HOTFIX-2 fixed the rendering root cause.

## Verification

Tested by the implementer at API, WebSocket-protocol and fake-DOM level (scripts kept outside the repository). No real browser was available to the implementer; the project owner reported manual validation of the features as a whole (SPEC-006.9, context section), but the individual manual checks are not recorded. The clipboard behavior was never tested in a real browser by the implementer.

## Known limitations

- The sidebar/timer/CPU parts are unchanged since; the rest see the follow-ups.

## Original specification (verbatim)

~~~~~text
SPEC-006.7.1 — Playground UX Improvements

1. Context

The CNPG Operator Playground currently provides:

* Docker Compose environment.
* Kind Kubernetes clusters.
* Bash/Makefile lifecycle engine.
* FastAPI backend.
* Vanilla HTML/CSS/JavaScript frontend.
* ttyd + tmux persistent terminal sessions.
* Independent Kubernetes contexts per terminal.
* Dynamic use case discovery.
* Sidebar Start/Stop controls.
* Colored Operation logs.
* Dynamic status bar with Grafana and MinIO links.
* Docker resource monitoring.

Specifications SPEC-006.1 through SPEC-006.6 are implemented.

We now want to improve the user experience before proceeding with use case renaming and stabilization.

2. Scope

Implement seven improvements:

1. Start use case terminals directly in their scenarios directory.
2. Replace the current Bash prompt with a short, conventional prompt.
3. Enable reliable copy/paste between the Web terminal and the host computer.
4. Add a discreet elapsed-time indicator during use case Start operations.
5. Clarify Docker CPU utilization visualization.
6. Preserve the same Bash prompt after scenario execution.
7. Increase the sidebar width by 33% and make it collapsible.

Explicitly out of scope

Do not rename:

* single-cnpg
* multi-cluster-dr

Do not modify Kind cluster naming conventions.

Do not modify Kubernetes context naming conventions.

These changes belong to SPEC-006.7.2.

⸻

PART A — Terminal Improvements

3. Initial Working Directory

Objective

When a new use case terminal is created, its shell must start directly inside the corresponding scenarios directory.

Examples:

usecases/single-cnpg/scenarios/
usecases/multi-cluster-dr/scenarios/

These paths are illustrative. Discover the actual project structure.

Requirements

* Resolve the use case directory dynamically.
* Do not hardcode use case names.
* Set the initial working directory only when creating a new tmux session.
* Preserve the working directory of existing tmux sessions.
* Do not change directories when switching browser tabs.
* Do not modify the Playground terminal’s initial directory.
* If scenarios does not exist, fall back to the use case root.

Important

Do not recreate existing tmux sessions just to change their working directory.

Existing sessions must remain untouched.

⸻

4. Compact Bash Prompt

Objective

Replace the existing prompt with a conventional Bash prompt.

Suggested format:

user@playground:scenarios$

For example:

root@playground:scenarios$

Requirements

* Display the actual username.
* Use a short hostname.
* Display only the current directory basename.
* Preserve $ or # depending on the user.
* Avoid absolute paths.
* Avoid Kubernetes context information.
* Avoid lengthy decorative symbols.
* Use subtle colors if desired.

Recommended implementation

Use Bash PS1.

Example:

PS1='\u@\h:\W\$ '

Adapt this to the existing shell configuration.

Do not introduce external prompt frameworks.

Kubernetes context isolation

Preserve:

* KUBECONFIG
* Terminal-specific context selection.
* Existing kubectl and Helm behavior.
* Existing shell aliases.

Do not replace or bypass the existing shell initialization mechanism.

⸻

5. Prompt Consistency After Scenario Execution

Objective

The Bash prompt must remain identical before and after executing a scenario.

Expected behavior:

root@playground:scenarios$ ./01-install.sh
[Scenario output]
root@playground:scenarios$

Investigation

Inspect:

* Existing scenario scripts.
* Shared Bash helpers.
* Shell initialization.
* Any code modifying PS1.
* Any scripts launching nested shells.
* Existing interactive prompt functions.

Requirements

* Preserve the same Bash prompt after scenario execution.
* Preserve the current working directory unless explicitly changed by the user.
* Preserve terminal-specific KUBECONFIG.
* Preserve Kubernetes context isolation.
* Preserve the existing interactive scenario prompts.

Important distinction

Scenario scripts may display their own interactive prompts.

Those are not necessarily Bash prompts.

Do not remove or redesign the existing scenario UI.

Implementation preference

Fix the issue centrally.

Avoid modifying every scenario script individually.

⸻

PART B — Web Terminal Clipboard

6. Copy/Paste Support

Objective

Allow reliable copy/paste between the Web terminal and applications running on the host computer.

Primary environment:

* macOS
* Desktop browser
* ttyd terminal embedded in an iframe
* tmux sessions

Required behavior

Copy terminal output

Users must be able to:

1. Select text using the mouse.
2. Copy the selection.
3. Paste it into another application.

Typical destinations:

* ChatGPT
* Text editor
* Slack
* Email

Paste into terminal

Users must be able to paste commands and multiline text from their host computer into the Web terminal.

Keyboard behavior

On macOS:

Shortcut    Expected behavior
Cmd+C with selected text    Copy selection
Cmd+V    Paste clipboard
Ctrl+C    Interrupt running command
Mouse selection    Select terminal output

Investigation

Inspect:

* ttyd startup options.
* ttyd version and native clipboard support.
* Browser clipboard permissions.
* iframe restrictions.
* Existing keyboard handlers.
* tmux mouse settings.

Implementation requirements

Prefer native ttyd functionality.

Avoid custom clipboard implementations unless necessary.

Do not replace ttyd or tmux.

Do not introduce a new terminal emulator.

Fallback

If browser security restrictions prevent native clipboard access, provide a simple and reliable alternative.

For example:

* A Copy Selection action.
* A supported keyboard shortcut.
* A documented native ttyd selection mechanism.

Do not claim that Cmd+C/Cmd+V work without testing them in a real browser.

Security

Do not enable unrestricted clipboard access.

Do not automatically copy terminal output without explicit user action.

⸻

PART C — Start Operation Timer

7. Elapsed-Time Indicator

Objective

Display a discreet timer when starting a use case.

Example:

single-cnpg    Starting... 00:18

Expected behavior

When Start is clicked:

* Show the timer immediately.
* Start counting elapsed time.
* Update every second.
* Display MM:SS.

Example:

Starting... 00:01
Starting... 00:02
Starting... 00:03

When Start succeeds:

Running — 01:24

Display the final duration briefly, then return to the normal Running state.

When Start fails:

Failed — 00:37

Preserve the existing error display.

Backend integration

Reuse the existing operation registry.

Prefer the backend’s operation start timestamp as the source of truth.

If necessary, extend the existing API response with:

{
  "operation": "start",
  "started_at": "2026-11-05T10:30:00Z",
  "status": "running"
}

Do not create a separate timer service.

Requirements

* Timer survives browser refresh.
* Timer survives tab switching.
* Multiple Start operations have independent timers.
* Timer stops when the corresponding operation completes.
* Timer does not restart when the frontend polls.
* No duplicate JavaScript intervals.

Constraints

Do not modify the Start/Stop execution logic.

Do not introduce a database.

Do not introduce additional backend workers.

⸻

PART D — Docker CPU Visualization

8. Clarify CPU Utilization

Current issue

The Docker Resources panel currently displays:

CPU 62% [small progress bar] ≈ 0.62 of 14 CPUs

The percentage appears high, while the progress bar indicates low utilization.

The values use different reference points.

Explanation

Docker CPU percentages are expressed relative to one logical CPU.

For example:

Docker CPU usage = 62%
Docker Engine CPUs = 14

Therefore:

Consumed CPU cores = 0.62
Total capacity usage = 0.62 / 14 × 100
                     = 4.43%

Required presentation

Use the percentage of total Docker Engine capacity as the primary metric.

Recommended:

CPU 4.4% [progress bar] 0.62 / 14 cores

Requirements

* Primary percentage matches the progress bar.
* Display consumed CPU cores.
* Display total available CPU cores.
* Preserve the underlying Docker CPU measurement.
* Handle CPU consumption greater than one logical CPU.
* Avoid misleading percentage labels.
* Keep the layout compact.

Formula

usedCores = dockerCpuPercent / 100;
capacityPercent = (usedCores / engineCpus) * 100;

Handle missing or zero CPU capacity gracefully.

Important

This is primarily a frontend presentation change.

Do not modify the backend resource collection logic unless strictly necessary.

⸻

PART E — Sidebar Improvements

9. Increase Sidebar Width

Objective

Increase the current sidebar width by approximately 33%.

Example

If the current sidebar width is:

240px

The new width should be approximately:

320px

Use the actual existing CSS value as the baseline.

Requirements

* Preserve the dark theme.
* Improve use case name readability.
* Preserve Start/Stop buttons.
* Preserve status indicators.
* Avoid unnecessary horizontal scrolling.
* Keep the terminal workspace responsive.

⸻

10. Collapsible Sidebar

Objective

Allow users to hide and restore the sidebar.

Expected behavior

Add a small toggle button in the existing UI.

When clicked:

* Hide the sidebar.
* Expand the terminal workspace.
* Keep the toggle visible.

Clicking again restores the sidebar.

Requirements

* No page reload.
* No terminal session restart.
* No ttyd iframe recreation.
* No Kubernetes context changes.
* No interruption of running commands.
* Preserve the selected terminal tab.
* Use a short CSS transition.

Persistence

Store the sidebar state in:

localStorage

After browser refresh, restore the previous visibility preference.

Important

Do not destroy or recreate terminal iframe elements when collapsing the sidebar.

Only modify CSS layout and visibility.

Responsive behavior

The sidebar must not prevent the terminal workspace from being usable on smaller screens.

The toggle must remain accessible in both expanded and collapsed states.

⸻

PART F — Validation

11. Terminal Validation

Verify:

* Fresh use case terminals start in scenarios.
* Playground terminal retains its initial directory.
* Existing tmux sessions retain their working directories.
* Bash prompt is compact.
* Prompt remains identical after scenario execution.
* Kubernetes context isolation remains functional.
* kubectl and Helm remain consistent.

12. Clipboard Validation

Verify in a real browser:

* Mouse selection works.
* Cmd+C copies selected terminal output.
* Cmd+V pastes into the terminal.
* Ctrl+C interrupts running commands.
* Multiline output can be copied.
* Clipboard behavior works after browser refresh.

If browser testing is unavailable, report this explicitly.

13. Timer Validation

Verify:

* Timer starts immediately.
* Timer increments every second.
* Timer survives browser refresh.
* Timer survives tab switching.
* Timer stops on success.
* Timer stops on failure.
* Multiple simultaneous Start operations have independent timers.

14. CPU Validation

Verify:

* Primary CPU percentage matches the progress bar.
* Consumed cores are calculated correctly.
* Total Docker CPU capacity is correct.
* CPU usage greater than one core is supported.
* Missing Docker metrics do not produce misleading values.

15. Sidebar Validation

Verify:

* Sidebar is approximately 33% wider.
* Sidebar collapses and expands.
* Toggle remains accessible.
* State persists after refresh.
* Terminal iframe elements are preserved.
* No terminal session is interrupted.
* Layout remains usable on smaller windows.

16. Regression Validation

Verify:

* Dynamic use case discovery.
* Start/Stop operations.
* Terminal tabs.
* tmux session persistence.
* ttyd WebSocket connectivity.
* Kubernetes context isolation.
* kubectl/Helm consistency.
* Operation logs.
* Grafana/MinIO links.
* Docker resource monitoring.

Do not destroy or recreate existing Kind clusters for testing.

Do not modify the shared Kubernetes context during regression tests.

⸻

PART G — Implementation Instructions

17. Recommended Implementation Order

Step 1 — Inspect

Inspect the existing:

* Terminal initialization.
* Bash prompt configuration.
* Scenario execution mechanism.
* ttyd clipboard behavior.
* Start operation registry.
* Docker CPU presentation.
* Sidebar CSS and JavaScript.

Step 2 — Terminal UX

Implement:

* Initial scenarios directory.
* Compact Bash prompt.
* Prompt consistency.
* Clipboard support.

Step 3 — Frontend UX

Implement:

* Start timer.
* CPU visualization.
* Sidebar width.
* Sidebar collapse/expand.

Step 4 — Validation

Run targeted tests and regression tests.

Do not interrupt existing user sessions.

18. Constraints

* KISS.
* Minimal targeted changes.
* No new frontend framework.
* No additional Docker containers.
* No database.
* No new terminal emulator.
* No modifications to Kind provisioning.
* No changes to use case identifiers.
* No changes to Kubernetes context naming.
* No modifications to the reference project.
* No destruction of existing Kind clusters.
* No interruption of existing tmux sessions.
* No unnecessary changes to scenario scripts.

19. Deliverables

Provide:

1. Root cause of prompt inconsistency.
2. Clipboard implementation details.
3. Start timer implementation.
4. CPU visualization changes.
5. Sidebar implementation.
6. Modified files.
7. Validation results.
8. Known limitations.

Final Instructions

Inspect the implementation first.

Explain the planned changes briefly.

Implement SPEC-006.7.1 incrementally.

Preserve all existing infrastructure and terminal sessions.

Do not rename the use cases.

Do not start SPEC-006.7.2.

Do not start the stabilization phase.
~~~~~
