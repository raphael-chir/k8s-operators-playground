# SPEC-006.7.1-HOTFIX-2 — Restore Original Scenario UI Rendering (UTF-8)

| | |
|---|---|
| Status | Implemented |
| Document type | Original specification, preserved verbatim |
| Source | Claude Code session transcript (project history), user message 2026-11-05T11:30:17.227Z UTC |
| Original specification | Available (see the last section) |

## Summary

The scenario banners rendered with broken borders in the Web terminal.

## Implemented behavior

- Root cause: the container has no UTF-8 locale, so tmux treated the ttyd client as non-UTF-8 (`client_utf8 = 0`) and replaced `╭╮╰╯` and `❯` with `_` and redrew lines with VT100 graphics. The scenario helpers and Bash were not at fault: `ui.sh` output is byte-identical to the reference project's (macOS bash 3.2 vs the container's bash 5, with and without a UTF-8 locale).
- Fix: `engine/terminal.sh` attaches with `tmux -u attach-session`. Verified in the bytes sent through ttyd: real box characters, aligned 74-column rows.

## Implementation

- `engine/terminal.sh` (one line), `docs/architecture.md`.

## Later corrections and follow-ups

A locale block added to `bashrc` during the investigation was removed as unnecessary (tmux panes are already UTF-8).

## Verification

Protocol-level checks through the real ttyd WebSocket; box width, corners and colors compared; no real browser available to the implementer.

## Known limitations

- Already-open browser tabs stay non-UTF-8 until reloaded.
- The container locale is still POSIX outside tmux (matters only for `docker exec` tools); a permanent fix would be `ENV LANG=C.UTF-8` in the Dockerfile, not done to avoid recreating the container.
- The final visual check in a browser was left to the project owner.

## Original specification (verbatim)

~~~~~text
SPEC-006.7.1-HOTFIX-2 — Restore Original Scenario UI Rendering

Context

The scenario UI rendering has regressed following recent terminal UX changes.

The original implementation worked correctly in:

../cnpg-operator-playground-local

The current Web terminal displays broken Unicode borders, misaligned box characters and degraded interactive prompts.

The user has provided a screenshot showing the regression.

Previous attempts to reconstruct the original UI did not restore the expected appearance.

Objective

Restore the original scenario UI rendering exactly as it worked in the reference project.

Do not redesign or simplify the interface.

Do not approximate the original appearance.

1. Reference Implementation

The project:

../cnpg-operator-playground-local

is the authoritative reference for scenario UI behavior.

It is strictly read-only.

Inspect its original:

* ui.sh
* Shared Bash libraries
* Scenario scripts
* Terminal initialization
* Environment variables relevant to rendering

Compare them with the current Playground implementation.

Do not assume the regression is caused only by ui.sh.

2. Required Investigation

Compare the following between the original and current environments:

Scenario UI

* Exact ui.sh functions.
* Unicode characters.
* ANSI escape sequences.
* Color definitions.
* Box drawing.
* Terminal width calculations.
* Prompt rendering.
* Interactive command rendering.

Terminal environment

Inspect:

locale
printf '%s\n' "$LANG" "$LC_ALL" "$TERM"
tput colors
stty size

Also inspect:

* ttyd configuration.
* tmux configuration.
* TERM propagation.
* UTF-8 support.
* Terminal font settings.
* xterm.js rendering.
* Terminal width detection.

Determine whether the issue is caused by:

1. Modified UI functions.
2. Incorrect terminal environment.
3. Unicode width calculation.
4. ttyd/tmux configuration.
5. A combination of these factors.

3. Restore Original ui.sh

Restore the original scenario presentation functions from the reference implementation.

Preserve:

* Original boxed banners.
* Original border characters.
* Original colors.
* Original interactive arrows.
* Original command prefixes.
* Original spacing.
* Original Enter-to-continue behavior.
* Original ui_watch behavior.

Do not replace Unicode characters with ASCII approximations.

Do not simplify the banners.

Do not modify individual scenario scripts unless required to correct a demonstrated compatibility issue.

4. Preserve Functional Integration

The original ui.sh may require adaptations to the new Playground architecture.

Keep these adaptations minimal.

Preserve:

* Terminal-specific KUBECONFIG.
* Kubernetes context isolation.
* Existing scenario execution.
* Dynamic Kind naming.
* ttyd and tmux persistence.
* The Killercoda-style Bash PS1.
* The current working directory.

Do not blindly overwrite functional changes that are unrelated to presentation.

If the original library contains environment-specific behavior, isolate the necessary adaptation rather than rewriting the presentation functions.

5. Fix Terminal Rendering

If the original ui.sh still renders incorrectly, investigate and fix the terminal environment.

Verify:

* UTF-8 locale.
* Compatible TERM.
* Correct tmux terminal capabilities.
* Unicode box-drawing support.
* Correct terminal dimensions.

Avoid unnecessary configuration changes.

Do not change ttyd or tmux versions without demonstrating that a version incompatibility causes the issue.

6. Validation

Test A — Original vs Current

Execute the same scenario UI functions in:

1. The original reference environment, where practical.
2. The current Playground Web terminal.

Compare:

* Box alignment.
* Border characters.
* Colors.
* Prompt symbols.
* Spacing.

Test B — Scenario Rendering

Execute the first scenario of single-cnpg.

Verify that:

* The banner is properly aligned.
* All four corners render correctly.
* Horizontal borders are continuous.
* Vertical borders align.
* Interactive prompts display the original symbols.
* Command prefixes display correctly.
* Colors match the reference.

Test C — Terminal Behavior

Verify:

* The Bash prompt remains Killercoda-style.
* Working directory is preserved.
* Kubernetes context isolation works.
* Ctrl+C works.
* Enter-to-continue works.
* tmux sessions remain persistent.

Test D — Browser

The final visual result must be checked in a real browser.

If browser access is unavailable, explicitly state that visual validation remains pending.

Do not declare the rendering fixed based solely on Bash unit tests.

7. Constraints

* Reference project is read-only.
* Minimal targeted changes.
* No redesign.
* No new dependencies.
* No changes to use case names.
* No Kind cluster recreation.
* No changes to scenario logic.
* No unnecessary modifications to ttyd or tmux.

8. Deliverables

Provide:

1. Exact root cause of the rendering regression.
2. Differences found between original and current ui.sh.
3. Terminal environment differences, if relevant.
4. Modified files.
5. Validation results.
6. Remaining limitations.

Final Instruction

Stop approximating the original scenario UI.

Use the working implementation from ../cnpg-operator-playground-local as the source of truth.

Restore the original appearance and behavior.

Do not implement unrelated improvements.
~~~~~
