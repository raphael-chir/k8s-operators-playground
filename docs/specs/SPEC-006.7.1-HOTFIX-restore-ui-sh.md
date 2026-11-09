# SPEC-006.7.1-HOTFIX — Restore Original ui.sh Behavior

| | |
|---|---|
| Status | Implemented |
| Document type | Original specification, preserved verbatim |
| Source | Claude Code session transcript (project history), user message 2026-11-05T11:14:42.834Z UTC |
| Original specification | Available (see the last section) |

## Summary

Regression fix: the shared scenario UI library had been simplified to plain text and had to be restored.

## Implemented behavior

- `engine/lib/ui.sh` was restored from the reference project (read-only copy of `lib/ui.sh`): boxed banners, `▶ Press Enter to continue ...`, green `❯` command prefix, original colors and spacing.
- The only retained difference is the functional `exec su -m` in `ui_login` (keeps `KUBECONFIG`, working directory and prompt).
- The Bash prompt stays configured only in `engine/shell/bashrc`; `ui.sh` does not touch `PS1`.

## Implementation

- `engine/lib/ui.sh`, `README.md`.

## Later corrections and follow-ups

Cause: the previous round interpreted "harmonize" as "simplify". Rendering problems that remained were traced to tmux in SPEC-006.7.1-HOTFIX-2.

## Verification

Real `single-cnpg` scenario run up to its first modifying step (private tmux server): banner, pause lines, command prefix, Enter, Ctrl+C, `ui_watch`, prompt and `KUBECONFIG` checked.

## Known limitations

None recorded beyond the general ones in `docs/specs/README.md`.

## Original specification (verbatim)

~~~~~text
SPEC-006.7.1-HOTFIX — Restore Original ui.sh Behavior

Context

The previous UX changes unintentionally modified the visual behavior of the shared scenario UI library:

engine/lib/ui.sh

This is a regression.

The original scenario interface used:

* Boxed scenario banners.
* Colored interactive prompts.
* Green arrow indicators.
* Colored command prefixes.
* Consistent spacing.
* Interactive pause and command helpers.

The recent changes replaced these elements with plain text.

This was not the intended behavior.

Objective

Restore the original ui.sh appearance and behavior exactly as it existed before SPEC-006.7.1-FIX.

At the same time, preserve the new Killercoda-style Bash prompt in the Web terminal.

1. Restore ui.sh

Inspect:

* Current engine/lib/ui.sh.
* Git history.
* The version preceding SPEC-006.7.1-FIX.
* The reference implementation in ../cnpg-operator-playground-local, if needed.

The reference project must remain read-only.

Restore the original implementations of the shared UI functions.

In particular, restore:

* Scenario banners.
* ui_pause.
* ui_command.
* ui_watch.
* Interactive colors.
* Prompt symbols.
* Original spacing and formatting.

Expected examples:

╭────────────────────────────────────────────────────────────────────────╮
│                                                                        │
│  Step 01 - Welcome to the EDB CloudNativePG Demo!                      │
│  Deploy a CNPG community cluster with Barman plugin connect to Minio.  │
│                                                                        │
╰────────────────────────────────────────────────────────────────────────╯
▶ Press Enter to continue ...
❯ kubectl config use-context kind-cnpg-lab-single-cnpg-1
Switched to context "kind-cnpg-lab-single-cnpg-1".
▶ Press Enter to continue ...

Preserve the original colors.

Do not simplify these prompts.

Do not replace their symbols with $.

2. Preserve the Web Terminal Bash Prompt

The Web terminal must continue using the Killercoda-style Bash prompt.

Example:

root@playground:/workspace/usecases/single-cnpg/scenarios#

Requirements:

* Username and hostname in green.
* Full working directory in blue.
* Conventional # or $ prompt character.
* Directory updates automatically after cd.

Configure this through:

engine/shell/bashrc

Do not configure Bash PS1 through ui.sh.

3. Separate Responsibilities

Maintain a clear separation:

Component    Responsibility
engine/shell/bashrc    Interactive Bash prompt
engine/lib/ui.sh    Scenario presentation and interactive helpers
engine/terminal.sh    Terminal session initialization

Do not attempt to unify the Bash prompt and scenario prompts into one implementation.

They serve different purposes.

The required consistency is visual quality, not identical prompt characters.

4. Preserve Functional Fixes

The previous changes also addressed environment preservation during scenario execution.

Do not blindly revert unrelated functional fixes.

In particular, investigate the change from:

exec su - "$user"

to:

exec su -m "$user"

If this change is necessary to preserve KUBECONFIG, retain the functional behavior while restoring the original UI appearance.

Avoid unrelated modifications.

5. Validation

Run an existing scenario and verify:

1. Boxed banners are restored.
2. Green interactive arrows are restored.
3. Command prefixes use the original symbols.
4. Colors are restored.
5. Enter-to-continue works.
6. Ctrl+C works.
7. ui_watch works.
8. Scenario commands execute normally.
9. The Bash prompt remains unchanged after scenario completion.
10. KUBECONFIG remains isolated.
11. The working directory remains unchanged.

Do not modify individual scenario scripts.

Do not recreate or destroy Kind clusters for testing.

6. Constraints

* Minimal hotfix.
* Restore the original UI behavior.
* No redesign.
* No new dependencies.
* No modifications to the reference project.
* No use case renaming.
* No changes to ttyd or tmux.
* No changes to Kubernetes context isolation.

Deliverables

Provide:

1. Root cause of the regression.
2. Functions restored.
3. Modified files.
4. Validation results.

Final Instruction

This is a regression fix, not a UI redesign.

Restore the original ui.sh presentation while preserving the Killercoda-style Bash prompt.

Do not implement additional features.
~~~~~
