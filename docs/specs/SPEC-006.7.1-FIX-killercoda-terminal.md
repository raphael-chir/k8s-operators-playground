# SPEC-006.7.1-FIX — Killercoda-Style Terminal Experience

| | |
|---|---|
| Status | Implemented (scenario UI part reverted by SPEC-006.7.1-HOTFIX) |
| Document type | Original specification, preserved verbatim |
| Source | Claude Code session transcript (project history), user message 2026-11-05T10:51:27.592Z UTC |
| Original specification | Available (see the last section) |

## Summary

A Killercoda-like terminal: full-path prompt, native browser copy/paste, no Kubernetes warning in the Playground, targeted tooltips.

## Implemented behavior

- Prompt: `PS1='\[\e[1;32m\]\u@playground\[\e[0m\]:\[\e[1;34m\]\w\[\e[0m\]\$ '` in `engine/shell/bashrc` (green user@host, blue full path, `#` for root).
- Native clipboard: tmux `mouse off` and no outer alternate screen (`smcup@:rmcup@`), so xterm.js selects and copies natively; `terminal.sh` re-sources `tmux.conf` on attach. The Copy selection button, `/api/clipboard` and the iframe clipboard permission were removed.
- Playground context: a new Playground file never pins a context that does not exist; a dead one is dropped at shell start without a warning; a valid selection is preserved; use case terminals keep their warning.
- Tooltips (native `title`): sidebar toggle, CPU, RAM, Kubernetes context, MinIO link.
- The requested restyling of the scenario prompts in `ui.sh` was applied here and then reverted (see the hotfix).

## Implementation

- `engine/shell/bashrc`, `engine/shell/tmux.conf`, `engine/terminal.sh`, `web/app.py`, `web/static/*`.

## Later corrections and follow-ups

SPEC-006.7.1-HOTFIX restored `ui.sh`. SPEC-006.9 fixed the status of a kubectl-written empty context.

## Verification

Tested by the implementer at API, WebSocket-protocol and fake-DOM level (scripts kept outside the repository). No real browser was available to the implementer; the project owner reported manual validation of the features as a whole (SPEC-006.9, context section), but the individual manual checks are not recorded.

## Known limitations

- With mouse off, the wheel scrolls the browser's scrollback (ttyd default 1000 lines); the full tmux history needs `Ctrl-b [`. After a refresh the scrollback starts empty.
- Copy/paste behavior was protocol-checked only (tmux emits no mouse tracking or alternate screen); real-browser tests were listed as manual.

## Original specification (verbatim)

~~~~~text
SPEC-006.7.1-FIX — Killercoda-Style Terminal Experience

1. Context

The CNPG Operator Playground currently uses:

* FastAPI and vanilla JavaScript.
* ttyd 1.7.7.
* tmux for persistent terminal sessions.
* Bash with custom initialization.
* Independent Kubernetes contexts per terminal.
* Interactive scenario scripts using shared Bash UI helpers.

SPEC-006.7.1 introduced several UX improvements.

However, browser testing revealed remaining issues.

We want a terminal experience similar to the Kubernetes terminal provided by Killercoda.

The user provided a screenshot as the visual reference.

Focus on terminal usability, prompt consistency and native clipboard behavior.

Do not redesign the Playground architecture.

⸻

2. Objectives

Implement five targeted improvements:

1. Use a Killercoda-style Bash prompt showing the current filesystem path.
2. Harmonize interactive scenario prompts with the terminal appearance.
3. Enable native browser copy/paste without a dedicated Copy Selection button.
4. Remove unnecessary Kubernetes context warnings from the Playground terminal.
5. Add a few useful tooltips to ambiguous UI controls.

Preserve existing terminal sessions and Kubernetes context isolation.

⸻

PART A — Bash Prompt

3. Killercoda-Style Prompt

Visual reference

The Killercoda terminal displays a conventional Bash prompt:

root@controlplane:~$
root@controlplane:~/filesystem$

The username and hostname are displayed in green.

The current working directory is displayed in blue.

The prompt character uses a neutral color.

Required Playground prompt

Use the same visual structure:

root@playground:~#
root@playground:/workspace#
root@playground:/workspace/usecases/single-cnpg/scenarios#

These examples illustrate the desired format.

The displayed path must reflect the actual current directory.

Requirements

* Display the actual username.
* Display the hostname playground.
* Display the current working directory.
* Use ~ when inside the user’s home directory.
* Preserve $ for non-root users and # for root.
* Username and hostname in green.
* Working directory in blue.
* Prompt character in a neutral color.
* No Unicode decorations.
* No multiline prompt.
* No Kubernetes context embedded in PS1.

Recommended implementation

Use Bash PS1 with standard ANSI colors.

For example:

PS1='\[\e[1;32m\]\u@\h\[\e[0m\]:\[\e[1;34m\]\w\[\e[0m\]\$ '

Adapt the hostname configuration if necessary.

Do not blindly copy the example if it conflicts with the current shell initialization.

Important

Use \w, not \W.

\w displays the working directory path.

\W displays only the final directory name.

This distinction is essential.

Directory changes

The prompt must update automatically after:

cd ..
cd /tmp
cd /workspace

Do not implement custom directory tracking.

Use Bash’s native prompt expansion.

⸻

PART B — Scenario Prompt Consistency

4. Current Behavior

Scenario scripts use interactive prompts such as:

▶ Press Enter to continue ...

They may also display commands using:

❯ kubectl config use-context ...

These prompts use a different visual language from the Bash prompt.

Objective

Create a consistent terminal experience.

The scenario scripts should feel like part of the same terminal environment.

Recommended appearance

Use simple, consistent colors.

Example:

Step 01 - Welcome to the EDB CloudNativePG Demo!
Deploy a CNPG community cluster with Barman plugin.
Press Enter to continue...

When displaying a command:

$ kubectl config use-context kind-cnpg-lab-single-cnpg-1

After execution:

Switched to context "kind-cnpg-lab-single-cnpg-1".

When the scenario finishes or is interrupted:

root@playground:/workspace/usecases/single-cnpg/scenarios#

Requirements

* Preserve existing scenario functionality.
* Preserve Enter-to-continue behavior.
* Preserve Ctrl+C handling.
* Preserve command execution and output.
* Use consistent colors.
* Avoid unnecessary Unicode prompt symbols.
* Avoid overly decorative interactive prompts.
* Keep scenario instructions readable.

Implementation

Inspect the existing shared UI library:

engine/lib/ui.sh

Prefer central changes to shared prompt-rendering functions.

Do not modify individual scenario scripts unless absolutely necessary.

Important distinction

Do not replace interactive scenario input with Bash PS1.

Scenario prompts and Bash prompts have different purposes.

Only harmonize their appearance.

Existing scenario banners

Preserve useful scenario titles and descriptions.

Do not remove instructional content.

Simplify borders or decorative elements only where they make the interface unnecessarily verbose.

⸻

PART C — Native Clipboard

5. Objective

Provide copy/paste behavior similar to Killercoda.

Users should be able to:

1. Select terminal text using the mouse.
2. Copy using the operating system’s standard keyboard shortcut.
3. Paste into ChatGPT, Slack or another application.
4. Paste commands from the host computer into the terminal.

The user should not need a dedicated Copy Selection button.

6. Current Implementation

The Playground currently uses:

* ttyd 1.7.7.
* tmux.
* tmux mouse mode.
* A custom Copy Selection button.
* A backend clipboard endpoint.

The existing solution is functional but unnecessarily complex.

Investigation

Determine how tmux mouse handling interacts with browser text selection.

Inspect:

* engine/shell/tmux.conf
* ttyd startup options.
* ttyd terminal client behavior.
* Existing keyboard shortcuts.
* Browser clipboard capabilities.
* Current clipboard endpoint.

Preferred solution

Use native browser text selection.

The user should be able to select terminal output directly with the mouse.

Do not require holding Shift during normal text selection.

tmux considerations

tmux mouse mode may intercept mouse selection.

Investigate whether disabling or adjusting tmux mouse handling provides the desired behavior.

For example:

set -g mouse off

Do not apply this setting blindly.

Evaluate its impact on:

* Mouse selection.
* Terminal scrolling.
* tmux scrollback.
* Interactive applications.
* Existing terminal behavior.

Prefer the simplest reliable configuration.

Clipboard behavior

Expected shortcuts:

Platform    Copy    Paste
macOS    Cmd+C    Cmd+V
Linux    Ctrl+Shift+C    Ctrl+Shift+V
Windows    Ctrl+Shift+C    Ctrl+Shift+V

Browser support may vary.

Preserve Ctrl+C as the terminal interrupt shortcut.

Important

Do not globally intercept Ctrl+C.

Do not implement a JavaScript clipboard handler unless native behavior is insufficient.

Do not introduce a clipboard library.

Do not replace ttyd or tmux.

Remove obsolete clipboard functionality

Once native selection works:

* Remove the Copy Selection button.
* Remove its frontend JavaScript.
* Remove the dedicated clipboard API endpoint if no longer used.
* Remove unused clipboard helpers.

Avoid leaving dead code.

Validation

Test:

* Mouse selection without Shift.
* Copy selected text.
* Paste into a host application.
* Paste text into the Web terminal.
* Copy multiline output.
* Ctrl+C interrupt.
* Browser refresh.
* Switching terminal tabs.

Browser testing

If a real browser is unavailable, do not claim clipboard functionality is validated.

Document the exact manual tests required.

⸻

PART D — Playground Kubernetes Context

7. Current Problem

When opening the Playground terminal, the following warning appears:

Kubernetes context kind-cnpg-lab-single-cnpg-1 does not exist yet
(its cluster is not created): kubectl and helm fail until it does.

This warning is unnecessary.

The Playground terminal is a general-purpose terminal.

It must not depend on a specific Kind cluster.

8. Expected Behavior

Playground terminal

When no Kubernetes clusters exist:

* Do not display a warning.
* Do not automatically select a nonexistent context.
* Do not fail terminal initialization.
* Allow normal shell commands.

Example:

root@playground:/workspace#

Use case terminals

Continue initializing the appropriate Kubernetes context.

If a use case’s expected cluster is unavailable, a relevant warning may still be displayed.

Context selection

If the user manually selects a valid context in the Playground terminal, preserve that selection.

Do not reset it automatically.

Important

Do not change the Kubernetes context of other terminals.

Do not modify the shared kubeconfig’s active context.

Do not delete existing Kubernetes context definitions.

Status bar

When no valid context exists for the Playground terminal:

* Display — or No context.
* Do not display a stale context as active.
* Do not show an unnecessary warning.

The terminal and status bar must remain consistent.

⸻

PART E — Targeted Tooltips

9. Objective

Improve discoverability without cluttering the interface.

Only add tooltips where the meaning of a control is not obvious.

Recommended tooltips

Element    Tooltip
Sidebar toggle    Show sidebar / Hide sidebar
CPU indicator    Percentage of total Docker Engine CPU capacity
RAM indicator    Memory used by Playground Kind nodes
Kubernetes context    Current Kubernetes context for this terminal
MinIO link    Open MinIO Console

No tooltip required

Do not add tooltips to obvious controls such as:

* Start
* Stop
* Playground tab
* Use case tabs
* Grafana links
* Start timer

Implementation

Prefer native HTML attributes:

title="Show sidebar"

No tooltip library.

No custom popover framework.

Keep the implementation minimal.

⸻

PART F — Validation

10. Prompt Validation

Verify:

* Prompt matches the Killercoda-style reference.
* Username and hostname are green.
* Working directory is blue.
* Full path is displayed.
* cd updates the path.
* Root uses #.
* Non-root uses $.
* Prompt remains consistent after scenario execution.

11. Scenario Validation

Verify:

* Interactive prompts remain functional.
* Enter-to-continue works.
* Ctrl+C works.
* Command output remains visible.
* Scenario banners remain readable.
* Kubernetes context remains unchanged unless explicitly modified by the scenario.
* KUBECONFIG remains isolated.

12. Clipboard Validation

Verify:

* Mouse selection works without Shift.
* Native copy works.
* Native paste works.
* Multiline output can be copied.
* Ctrl+C interrupts commands.
* tmux sessions remain persistent.
* Browser refresh does not break clipboard behavior.

13. Playground Context Validation

Verify:

* Playground opens without warnings when no clusters exist.
* No invalid context is automatically selected.
* The status bar displays No context when appropriate.
* A manually selected valid context remains selected.
* Use case terminals retain their independent contexts.

14. Regression Validation

Verify:

* Sidebar Start/Stop.
* Start timer.
* Sidebar collapse/expand.
* Terminal tabs.
* tmux persistence.
* Kubernetes context isolation.
* kubectl/Helm consistency.
* Grafana/MinIO links.
* Docker resource monitoring.
* Operation logs.

Do not create or destroy existing Kind clusters unnecessarily.

Do not modify the shared Kubernetes context during tests.

⸻

PART G — Constraints

* KISS.
* Minimal targeted changes.
* No new dependencies.
* No frontend framework.
* No additional containers.
* No terminal emulator replacement.
* No changes to Kind provisioning.
* No changes to use case identifiers.
* No changes to Kubernetes context naming.
* No modifications to the reference project.
* No destruction of existing clusters.
* No interruption of existing tmux sessions.

⸻

PART H — Deliverables

Provide:

1. Root cause of the Playground Kubernetes warning.
2. Final Bash PS1 configuration.
3. Scenario prompt changes.
4. Clipboard configuration and limitations.
5. Removed clipboard-related code.
6. Tooltip changes.
7. Modified files.
8. Validation results.
9. Manual browser tests still required.

Final Instructions

Inspect the current implementation first.

Explain the root causes briefly.

Implement the smallest reliable changes.

Prioritize native browser selection and clipboard behavior.

Preserve tmux session persistence and Kubernetes context isolation.

Do not rename the use cases.

Do not start SPEC-006.7.2.

Do not begin the stabilization phase.
~~~~~
