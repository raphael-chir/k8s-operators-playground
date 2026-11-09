# SPEC-013: Modern Terminal UI

Status: implemented in `engine/lib/ui.sh` only; verified with a fake kubectl and a pseudo-terminal. Not checked in a real ttyd/xterm.js session.

## Implementation

- **Palette** (ANSI 256, `NO_COLOR` and non-tty output unchanged: no escape codes): `ui_section` 183 bold, `ui_info` 81 bold with a `◆` prefix (blank line kept), `ui_success` 114 bold, `ui_warn` 215 bold, `ui_error` 203 bold, borders 240.
- **`ui_command`** prints `┌─ <use case>  ☸ <context>` then `└─➜ <command>`: the command is typed with the unchanged `ui_type` and run with the unchanged `eval` (stdout, stderr and exit status preserved, no automatic pause). Use case: `$USECASE`, else derived from the working directory (`.../usecases/<name>/...`), else omitted. Context: `kubectl config current-context`, read at every call (never `KUBE_CONTEXT`, so a context switch inside a scenario shows at once); `no-context` when kubectl or the context is unavailable. The command color is reset right after `ui_type`'s newline.
- **`ui_pause`**: a 46-character gray separator, then an amber `↵ Press Enter to continue...`; no screen clearing, same `read`.
- Nothing removed or renamed (`ui_note`, `ui_step`, `ui_confirm`, `ui_input`, `ui_choose`, `ui_spin`, `ui_type`, `ui_watch`, `ui_login` untouched). `ui_watch` keeps its own prompt text. No scenario, engine, Web UI, PS1 or context change.

## Validation (nothing created in Kubernetes)

`bash -n`; successful command with stdout and stderr; exit status 7 preserved; context switch between two calls (a fake kubectl): `kind-a` then `kind-b`; kubectl missing or failing: `no-context`; colors in a pty and none with `NO_COLOR`; `ui_pause` blocks until Enter; the typing animation takes time proportional to the text. `tests/scenarios.sh` still passes.

## Limitations

- Not viewed in a browser terminal (glyphs `┌ └ ➜ ☸ ◆ ↵` depend on the font).
- Each `ui_command` runs `kubectl config current-context` (local, no cluster call).
- The color reset follows the newline printed by `ui_type`, so an interrupted typing (Ctrl+C) can leave the color on until the next reset.

## Later adjustments (current behavior)

The two-line prompt described above was replaced at the owner's request, in `engine/lib/ui.sh` only: `ui_command` prints a single line `☸ cluster-N ➜ command` (prompt bold mint 121, command bold white 255; N is the trailing number of the current context, the context itself when it has none, `no-context` otherwise); `ui_pause` prints `↳  Enter to continue` without a separator; `ui_note` renders a rounded box (border 60) sized to its content with a bold mint title, bold cyan `##` headings and `◆` bullets. These variants were checked with a fake kubectl and `NO_COLOR` output, not in a browser terminal.

## Original request

SPEC-013: modern DevOps terminal UI for the scenarios (Starship/Powerlevel10k style, Catppuccin palette), scope `engine/lib/ui.sh` only: the palette table above, a two-line `ui_command` prompt with use case and live Kubernetes context (`no-context` fallback, typing animation, eval and exit status preserved, no automatic pause), `◆` instructions, a separator before the amber pause, harmonized `ui_section`/`ui_success`/`ui_warn`/`ui_error`; Bash 3.2, NO_COLOR, non-interactive, ttyd/xterm.js; no scenario, engine, Web UI, PS1 or context change; the eight validation tests listed.
