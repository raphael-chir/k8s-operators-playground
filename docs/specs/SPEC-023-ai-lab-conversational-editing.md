# SPEC-023: Conversational Lab editing (P1.3)

Status: implemented and verified with a scripted runner (mocked Claude), a fake DOM, a fake upstream and the rendered Compose model. **No real Claude call was made, no container was built or started.** What depends on the real CLI, the rebuilt images and a browser is listed under "To validate manually" and in `docs/ai-builder.md` (steps 22-30).

## Original request (verbatim)

> Implement P1.3 — Conversational Lab Editing.
> Context: P1.1: Execution limits and usage tracking are implemented. P1.2: Persistent conversations are implemented and manually tested. Existing AI Builder generation and publication workflows must remain functional.
> Goal: Allow users to naturally discuss, inspect, and modify existing Labs through the same conversation. Do not introduce a rigid workflow, an agent framework, Git-based versioning, or a database.
> 1. Conversation behavior: keep the existing conversational interface. Users should be able to: ask questions about a Lab; request modifications to scripts, manifests or documentation; add, remove or improve scenarios; review the changes; continue discussing and refining the Lab; discard modifications; restore the initial Lab state. Do not require users to select a separate Discussion or Edit mode.
> 2. Isolated workspace: when a conversation needs to modify an existing Lab: create an isolated working copy; never edit the published Lab directly; preserve the original state for comparison and restoration; keep the workspace persistent across conversations and container restarts; prevent path traversal and access outside the authorized workspace.
> 3. Claude execution: reuse the existing Claude Code session and usage tracking. Read-only requests should retain restricted tools. Modification requests may use Write and Edit only inside the isolated workspace. Never allow Claude to write directly into published Labs. Do not enable Bash, WebFetch or WebSearch in this phase. IMPORTANT: The current container has a writable publication mount. Inspect and resolve this security boundary at the operating-system level before enabling conversational editing. Do not rely exclusively on Claude Code permission flags to protect published Labs.
> 4. Review and publication: a clear list of modified, added and deleted files; a readable diff; validation before publication; explicit user approval; atomic publication using the existing mechanisms; conflict detection if the published Lab changed since the working copy was created. No automatic publication.
> 5. Undo and Reset: undo the most recent modification; restore the initial Lab state; discard all pending modifications. Keep the implementation lightweight. Avoid creating a full copy of the Lab after every message.
> 6. UI: extend the existing Conversations tab. Keep the natural chat experience. Display pending changes and provide: Review changes, Undo, Reset, Publish. Avoid unnecessary controls or workflow steps.
> 7. Tests: mocked tests covering workspace isolation, read-only versus editing permissions, published Lab protection, diff generation, undo and reset, validation and publication, conflict detection, conversation persistence, existing AI Builder compatibility. Do not perform real Claude calls automatically.
> 8. Implementation approach: first inspect the existing architecture and propose the minimal design. Pay particular attention to the distinction between Claude's conversational session, the Lab working copy, and the published Lab. Explain how these three elements interact and how OS-level isolation is enforced. Then implement incrementally. Run all relevant tests and report results, limitations and manual validation steps.

## The three elements and the OS boundary

| | Where | Writable by |
|---|---|---|
| Published Lab | `usecases/<lab>/` | only the `ai-publisher` container |
| Working copy | `<state>/workspaces/<conversation>/work/` (+ content store and manifests) | Claude Code (Write/Edit on that directory), the service |
| Claude session | `--session-id`/`--resume`, `claude-auth` volume | Claude Code |

**Before this change** the `ai-builder` container, where Claude Code runs, mounted `./usecases` twice (read-only at `/workspace/usecases`, read-write at `/publish/usecases`); the container cannot change user (no capabilities, `no-new-privileges`), so permission flags were the only thing between Claude and the published Labs. **Now** that container has `usecases/` read-only only. A second service, `ai-publisher` (same image, `publisher.py`, no Claude Code, no login, no host port, `/state` read-only, `usecases/` its only writable mount, reached with the existing bearer token) is the only writer. The AI Builder never publishes locally in the container deployment: with the publisher down, publication fails and nothing is written. Host mode (no containers) keeps the previous direct publication and, as before, only the permission policy protects the repository there.

## Implemented

- `ai-builder/publishing.py` (new): `tree_hash`, `check_source`, `publish_tree` (name and source checks, content hash equal to the approved one, validation again, conflict check against the Lab's hash when replacing, staging directory plus `renameat2(RENAME_EXCHANGE)` or two renames with rollback, cleanup of `.staging-*`/`.old-*`), `remote_publish`. Replaces the inline staging code of `JobManager.publish` (same checks and messages for new use cases).
- `ai-builder/publisher.py` (new): the service (`POST /publish`, `GET /health`, Host allowlist, bearer token, `resolve_source`: only real directories under `<state>/drafts` or `<state>/workspaces`, no `..`, no symlink on the path).
- `ai-builder/workspace.py` (new): working copy per conversation: `create` (copies the published Lab, which is only read), content-addressed object store, manifests, `begin_turn`/`end_turn` (undo stack of 20, unchanged turns leave no step, a Lab grown past 300 files or 4 MB is rolled back), `undo`, `reset`, `rebase`, `discard`, `changes`, `diff` (bounded unified diffs, binary detection), `sanitize` (symbolic links never kept or followed), `safe_rel` on every path taken from a manifest.
- `ai-builder/conversations.py`: edit decision per message (`EDIT_RE` for a Lab conversation, then sticky until reset, start over or publish), lazy working copy, `turn_note` (per-message note with the working-copy path: Claude records the system prompt once per session, so per-message facts travel in the message), `conversation_args(work=, editing=)` (Write/Edit only for `<work>/**`, repository and publish directory denied by rule, `--add-dir` the working copy, Bash/Web never), per-turn `edit` and `changed`, `review`, `undo`, `reset`, `discard`, `publish` (explicit approval bound to the reviewed `tree_hash`, validation, conflict check, refused while a generation job runs), `workspace` in the view, notices to Claude about what the user undid, reset or published. `read_only` now means "no Lab".
- `ai-builder/server.py`: `GET /conversations/<id>/review`, `POST /conversations/<id>/{undo,reset,discard,publish}`.
- `ai-builder/builder.py`: `Config.publisher_url`, `publish_files()` (remote in the container deployment, local in host mode), `tree_hash` shared with `publishing`.
- `compose.yaml`: `ai-builder` loses the `/publish/usecases` mount and `AI_BUILDER_PUBLISH_DIR`, gains `AI_BUILDER_PUBLISHER_URL`; new service `ai-publisher`; both services use one image (`cnpg-ai-builder:local`). `playground`: `ai-builder start|stop` also start and stop `ai-publisher`.
- `web/ai_builder_proxy.py`, `web/app.py`: `conv_review/undo/reset/discard/publish` operations and routes (conversation id validated, CSRF header on the POSTs, 2 MB response limit for a review).
- `web/static/index.html`, `ai-builder.js`, `ai-builder.css`: pending-changes bar (counts, Review changes, Undo, Reset with a second click), review panel (files with their change, colored diff, validation, approval checkbox, Publish), conflict banner with "Start over from the published Lab", per-reply "changed …" line.
- Tests: `tests/ai_builder_editing_test.py` (58), additions to `tests/ai_builder_proxy_test.py`, `tests/ai_builder_compose_test.py` (the rendered model: no writable `usecases/` in the AI Builder, hardening of the publisher) and `tests/ai_builder_ui_test.js`; `tests/ai-builder.sh` and `tests/static.sh` updated.
- Not changed: generation, validation rules, review/approve of generated use cases (they now publish through the same publisher), authentication, the Playground container.

## Known limitations and assumptions

- The OS boundary protects **published Labs** only. Inside `/state`, Claude Code shares the user and the mount with the service: if its permission policy failed it could alter another conversation's working copy or a draft. Its reads are not restricted to its own working copy.
- A same-user process in the AI Builder could in principle forge an approval record in `/state`; publication still needs the token-authenticated call from the service and the publisher re-validates the content, but this is not a hard boundary against a fully compromised AI Builder process.
- `renameat2(RENAME_EXCHANGE)` is attempted first; on filesystems that do not support it (some bind mounts on macOS) the replacement uses two renames with automatic rollback, which leaves a very short window in which the Lab is missing. Not exercised on a real bind mount.
- The "this message asks for a change" decision is a keyword match, not an understanding of the request (English and French verbs). False positives only open an isolated copy; misses make Claude ask to be told to apply the change.
- Not exercised against the real CLI: the `Write(<path>/**)`/`Edit(<path>/**)` allow rules with `--add-dir` for a path outside the working directory, `Glob`/`Grep` on the added directory, the per-message note being honoured, and edits made through `Write` landing in the working copy.
- Publishing replaces whole files; there is no merge with a Lab that changed meanwhile (that is a conflict: start over).
- Undo steps are per editing message, not per file; the stack keeps 20. A timed-out or failed editing message keeps its partial changes (undoable).
- The narrow-window layout was not verified in a browser (headless Chrome refused a 420 px window); light, dark and conflict states were looked at in a wide window.

## To validate manually

Steps 22-30 of `docs/ai-builder.md`, in particular: the mount proof (`touch` on `usecases/` fails in `cnpg-ai-builder`), a question never creating a working copy, an edit landing only in the working copy, publication with and without the publisher, the conflict flow, and persistence across a container restart.
