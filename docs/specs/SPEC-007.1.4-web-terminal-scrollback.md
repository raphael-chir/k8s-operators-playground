# SPEC-007.1.4 — Web Terminal Scrollback Reliability

| | |
|---|---|
| Status | Implemented, image rebuilt and container recreated (with the owner's approval, see Follow-up), validated through the live ttyd with a headless xterm.js. **Not validated by a person in a browser** (wheel, trackpad, Option+drag selection) |
| Document type | Original specification, preserved verbatim, with the investigation and the implementation record |
| Source | Claude Code session transcript (project history), user message of 2026-11-05 |
| Original specification | Available (see the last section) |
| Target version | `1.0.0-rc.1` (unchanged) |

## Root cause

Two independent causes, both reproduced before any change (throwaway containers from the Playground image, same ttyd 1.7.7 and tmux 3.3a, a WebSocket client speaking ttyd's protocol, and the headless xterm.js engine that ttyd's page uses with its default 1000-line scrollback; the live Playground container and its sessions were not touched).

1. **Two competing scrollbacks.** `tmux.conf` disabled the alternate screen (`smcup@:rmcup@`, SPEC-006 era, to let the wheel scroll the browser and keep native selection). tmux then paints on the browser's normal screen and moves content with its own scroll and redraw sequences, which xterm.js does not turn into scrollback lines. Result with the old configuration: `seq 1 300` left **29 of 300** lines in the browser buffer; five repeated `seq 1000 1029` runs left 37 of 150 numbers, **8 duplicated and out of order**; a new connection to the same session (a tab switch or page reload) saw only the visible screen (0 of the 300 lines). tmux itself held everything, but the wheel never reached it. This is the truncated, partial, mixed history that was reported. Not a resize problem and not a normal limitation: the browser buffer was wrong.
2. **`clear` erases the history.** Inside tmux (`TERM=tmux-256color`) `clear` emits `ESC[H ESC[J ESC[3J`; the last sequence means "erase scrollback", and tmux obeys it by clearing the pane's whole history (measured: 60 numbers of history before, 0 after; xterm.js does the same to its own). Every scenario's `main()` starts with `clear`, and `ui_watch` runs it at every refresh (`engine/lib/ui.sh:291`), so history vanished as soon as a scenario or a watch ran. `tput clear` does the same, so wrapping a watch in the alternate screen with it would not help. `clear -x` omits `ESC[3J`.

Ruled out by measurement: tmux `history-limit` (50000, large enough), ttyd scrollback (irrelevant once xterm.js is on the alternate screen), terminal resizing (history intact after 120→90→150 columns once the two causes are fixed), ANSI sequences of the UI helpers other than `ESC[3J` (boxes, colors, typing are fine, box corners render).

## Implemented behavior

| File | Change |
|---|---|
| `engine/shell/tmux.conf` | Removed `smcup@:rmcup@` from `terminal-overrides` (tmux uses the alternate screen again) and set `mouse on`: the wheel or trackpad enters tmux copy-mode and scrolls its history (50000 lines); scrolling back to the bottom leaves it. One scrollback. Applied by the existing `source-file` on every attach |
| `engine/shell/bashrc` | `clear() { command clear -x "$@"; }` exported (`export -f clear`), so the scenarios' `clear` and `ui_watch`'s refresh clear the screen without erasing the history. Not modifying `engine/lib/ui.sh` |
| `Dockerfile` | ttyd client option `-t macOptionClickForcesSelection=true`: with tmux owning the mouse, native text selection needs a modifier; this makes it Option on macOS (Shift works on Windows and Linux by default). ttyd 1.7.7 was checked to deliver it to the page. Takes effect after an image rebuild |
| Docs | `docs/user-guide.md` (scrolling and selection), `docs/architecture.md`, release checklist, index |

Not changed in the first step: `engine/lib/ui.sh` (see Follow-up), the scenarios, the Web UI, the CLI, Compose, tmux session handling, Kubernetes contexts. `ui_watch` still uses `clear`-style refreshes (now `clear -x`).

## Before / after (harness results, same tests, `1000` lines xterm scrollback)

| Test | Before (old config) | After |
|---|---|---|
| 1. Long output `seq 1 300` | 29 of 300 lines in the browser; 271 missing | tmux history 300 of 300, in order; mouse-wheel scrolling (SGR wheel events) shows contiguous lines (e.g. 229..257, then 29..57) with a position indicator; scrolling down returns to the latest output |
| 2. Repeated commands | numbers duplicated (8) and out of order; markers lost | 5 of 5 `CMD` blocks and 150 of 150 numbers, in order |
| 3. `ui_watch`, then Enter | earlier history gone (0 of 5 markers, 1 of 300 numbers) | 5 of 5 markers and 300 of 300 numbers kept; the refresh frames remain in history (see limitations) |
| 4. Resize 120→90→150 | history already lost | history intact (300 of 300, 5 of 5), new output correct |
| 5. New connection to the same session (reload, tab switch) | sees only the visible screen | can scroll back through the full history |
| 6. Scrolling while output continues | not applicable (history incomplete) | after scrolling back to the latest output, 50 of 50 lines of a running loop are present, in order, prompt visible |
| 7. Scenario-like run (`clear`, banner, typed commands, pauses) | history wiped at the start | box corners render, 40 of 40 lines kept |
| 8. Independent sessions | n/a | each tmux session has its own history (a use case tab does not contain the Playground tab's output) |

The same harness against the repository's real files (mounted read-only in a fresh throwaway container) gave the "after" results. **Mouse-wheel and trackpad scrolling were simulated with the SGR mouse events that xterm.js sends; they were not performed by a person in a browser.**

## Follow-up (owner approved the scrollback changes, `ui_watch`, and the rebuild)

- **`ui_watch` (`engine/lib/ui.sh`)**: the one defect demonstrated was its refresh frames filling the history. It now enters the alternate screen (`ESC[?1049h`), redraws with cursor-home and erase-below instead of `clear` (which sends `ESC[3J` and would erase the history even on the alternate screen), and leaves the alternate screen when Enter is pressed. An `EXIT` trap restores the normal screen on Ctrl+C or any abort. Interface, texts, refresh interval and Enter handling are unchanged (`return 0` became `break 2`, plus the restore). Measured: refresh frames in history 0 (before: one per refresh); previous display and earlier output intact; Ctrl+C restores the normal screen and still aborts the script; wheel-up afterwards still reaches the earlier output.
- **Rebuild:** `./playground install` then `./playground start` (Compose recreated the container on the new image; the running tmux sessions ended as approved). Checked before and after: the four Kind nodes of `cnpg-standard`, all Docker volumes (`history`, `kube` included), the shared kubeconfig (same checksum), its contexts and the terminal context files, the PostgreSQL clusters `cnpg-cluster` and `restored-cnpg-cluster` (3 + 1 instances, healthy), and the completed backup are unchanged. The container's command now carries `-t macOptionClickForcesSelection=true`, and the live ttyd sends that preference to the page.
- **Live validation (real ttyd on port 7681, headless xterm.js):** the harness results of the table above, repeated on the recreated container (300 of 300 lines, contiguous wheel scrolling, 5 of 5 markers and 300 of 300 numbers after `ui_watch`, intact after a resize, a new connection scrolls back); the use case terminal keeps its isolated `KUBECONFIG` and context (`kind-cnpg-lab-cnpg-standard-1`), reaches the cluster with `kubectl`, and `ui_watch kubectl get pods` added 3 lines to a 139-line history.
- **Option selection:** ttyd's bundled xterm.js decides forced selection with `isMac ? altKey && macOptionClickForcesSelection : shiftKey`, and the live ttyd sends the option as `true`. An actual Option+drag in a browser was not performed by this session.

## Limitations

- **Selecting text needs a modifier** (Shift on Windows and Linux, Option on macOS) because tmux owns the mouse. Alternative if unacceptable: `mouse off` and `Ctrl-b [` for history, which brings back the unreliable partial browser scrollback.
- A pane left scrolled up (copy-mode) stays in copy-mode across a reload; scroll down or press `q` before typing.
- Programs that print their own frames with plain `clear` (outside `ui_watch`, the shell's `clear`) are fine: the shell's `clear` is `clear -x`; a program calling `tput clear` or `printf '\e[3J'` still erases the history.
- Real-browser checks (wheel, trackpad, Option+drag, window resize by dragging) remain for the project owner.

## Original specification (verbatim)

~~~~~text
SPEC-007.1.4 — Web Terminal Scrollback Reliability

Project: CNPG Operator Playground
Target: Web Terminal (ttyd / tmux)
Priority: High
Release: v1.0.0-rc.1

1. Problem

The Playground Web terminal does not reliably display command history when scrolling backward.

Observed symptoms:

* Previous command outputs become truncated.
* Some lines appear incorrectly rendered.
* Old and recent command outputs become mixed.
* Scrolling through the terminal history produces inconsistent results.

This significantly degrades the user experience.

2. Objective

Ensure that users can reliably scroll backward through previous command outputs without visual corruption.

The terminal must behave like a normal, reliable interactive terminal.

3. Investigation

Before changing anything, inspect:

* ttyd configuration.
* tmux configuration.
* xterm.js settings exposed by ttyd.
* Terminal initialization scripts.
* Scrollback/history settings.
* Terminal resizing behavior.
* Existing ui_watch implementation.
* ANSI escape sequences generated by UI helpers.

Determine whether the issue originates from:

1. tmux history and alternate screen handling.
2. ttyd/xterm.js scrollback configuration.
3. Terminal resizing and line reflow.
4. Interactive commands such as watch.
5. ANSI cursor movement or screen-clearing sequences.

Do not assume the root cause without investigation.

4. Expected Behavior

Users must be able to:

* Scroll backward using the mouse wheel or trackpad.
* Read previous command outputs correctly.
* Scroll forward to the latest output.
* Execute additional commands without corrupting history.
* Resize the terminal without mixing old and new output.

The behavior must remain consistent during long scenario executions.

5. Design Principles

Follow KISS.

Prefer configuration changes over new code.

Avoid:

* Custom JavaScript terminal implementations.
* Additional terminal libraries.
* Custom scrollback managers.
* Complex synchronization between ttyd and tmux.
* Unnecessary UI modifications.

Preserve the existing architecture.

6. tmux Configuration

Review:

* history-limit.
* Mouse support.
* Alternate-screen behavior.
* Terminal capabilities.
* Copy-mode scrolling.
* Terminal resize behavior.

Investigate whether mouse scrolling correctly enters tmux copy-mode rather than relying on an inconsistent browser-side history.

Avoid competing scrollback mechanisms.

Do not blindly disable the alternate screen, as full-screen terminal applications may depend on it.

7. ttyd / xterm.js

Review:

* ttyd version.
* Available xterm.js options.
* Scrollback buffer size.
* Terminal resize behavior.
* Renderer configuration.
* Compatibility with tmux.

Determine whether ttyd’s built-in configuration is sufficient.

Do not modify bundled third-party JavaScript unless absolutely necessary.

8. Interactive Commands

Inspect ui_watch and other commands that refresh terminal content.

Check whether they use:

* Screen clearing.
* Cursor repositioning.
* Alternate-screen buffers.
* Repeated full-screen redraws.

Ensure that interactive commands do not corrupt the history of previously executed commands.

Preserve the ability to monitor Kubernetes resources interactively.

Do not modify engine/lib/ui.sh unless a specific defect is demonstrated.

9. Validation

Reproduce the issue before applying a fix.

Test:

1. Long command output.
2. Repeated Kubernetes commands.
3. Scenario execution with multiple UI steps.
4. Mouse-wheel scrolling.
5. Trackpad scrolling.
6. Interactive ui_watch.
7. Terminal resizing.
8. Scrolling while commands continue producing output.
9. Returning to the latest output.
10. Multiple independent terminal sessions.

Verify that output is neither truncated nor visually mixed.

Distinguish normal terminal scrollback limitations from actual rendering corruption.

10. Constraints

* Preserve ttyd and tmux.
* Preserve existing terminal sessions.
* Preserve isolated Kubernetes contexts.
* Preserve Web UI behavior.
* Avoid unrelated changes.
* Do not modify scenario scripts unless necessary.
* Do not delete clusters or volumes.
* Do not terminate active sessions without authorization.

11. Acceptance Criteria

* Previous command outputs remain readable.
* No mixed or corrupted lines during scrolling.
* Scrolling behaves consistently.
* Interactive commands remain functional.
* Terminal resizing does not corrupt the visible history.
* Existing Playground functionality is preserved.
* The fix is minimal and maintainable.

12. Deliverables

1. Root-cause analysis.
2. Minimal corrective changes.
3. Before/after behavior.
4. Validation results.
5. Remaining limitations, if any.

Create:

docs/specs/SPEC-007.1.4-web-terminal-scrollback.md

Update the specification index and release checklist.

Do not change the Playground version.

Do not push or tag the repository.

13. Implementation Instructions

1. Inspect the current terminal implementation.
2. Identify the most likely root cause.
3. Reproduce the issue where possible.
4. Apply the smallest appropriate fix.
5. Run non-destructive tests.
6. Report the result.

Do not restart active sessions without authorization.

The priority is reliable terminal history, not adding new terminal features.
~~~~~
