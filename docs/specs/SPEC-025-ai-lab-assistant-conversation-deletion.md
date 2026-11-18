# SPEC-025: Deleting a conversation

Status: implemented and verified with unit and API tests and Node UI tests (no browser test, no real Claude call, no container).

## Original request (verbatim)

> Add conversation deletion to the AI Lab Assistant.
> 1. UI: add a discreet delete action (trash icon) for each conversation; require confirmation before deletion; update the conversation list immediately after successful deletion; if the active conversation is deleted, return to the empty conversation state; keep the UI consistent with the new right-side panel.
> 2. Backend: add a DELETE endpoint using the existing API conventions; delete the conversation JSON record; delete its associated Claude Code session history when safely identifiable; clean up its isolated workspace only if it belongs exclusively to that conversation; never delete published Labs or shared files; prevent path traversal and unauthorized deletion; reject deletion while a conversation has an active Claude invocation.
> 3. Safety: ensure deletion is scoped strictly to the selected conversation; never use broad recursive cleanup of shared directories; preserve other conversations and their workspaces.
> 4. Tests: successful deletion; deletion of the active conversation; deletion while a turn is running; missing conversation; workspace isolation; no impact on published Labs.
> Keep the implementation minimal. Do not run browser tests or make real Claude calls. Use existing unit and API tests only. Report the changes and test results.

## Implemented

- `ai-builder/conversations.py`: `ConversationManager.delete(id)`. The id must match `c-YYYYMMDD-HHMMSS-xxxxxx` (404 otherwise, so `../x` never reaches the filesystem) and the conversation must exist (404) and be idle (409 while a turn runs). It then removes, by exact path only: the working copy `<state>/workspaces/<id>/` (named by the conversation's own id, so it belongs to it exclusively), the Claude Code files of the sessions the record lists (`<config>/projects/*/<uuid>.jsonl`, `<config>/projects/*/<uuid>/`, `<config>/session-env/<uuid>/`; only ids that are valid UUIDs, so a tampered record cannot point elsewhere), and last the record `<state>/conversations/<id>.json`. A file or symbolic link is unlinked (a link is never followed); a directory is removed with `rmtree` on that exact path; nothing is globbed in a way that can match another conversation's files or a parent directory. Failures while cleaning are returned as `warnings`; the record is kept when its own deletion fails.
- `ai-builder/server.py`: `DELETE /conversations/<id>` with the usual Host and bearer-token checks (any other DELETE path is 404).
- `web/ai_builder_proxy.py`, `web/app.py`: operation `conv_delete` and route `DELETE /api/ai-builder/conversations/{id}` (id validated, fixed upstream); the CSRF header `X-Requested-With: playground` is now required for every method but GET (it was POST only).
- `web/static/index.html`, `ai-builder.css`, `ai-builder.js`: a trash icon button beside the conversation selector, acting on the open conversation, with the same two-click confirmation as Reset (red "Delete?"), disabled without a conversation and while Claude answers; on success the list is updated, the active conversation is closed (empty state, no longer remembered) and a note says "Conversation deleted."; a 404 (already deleted elsewhere) ends the same way, a 409 or a network failure keeps everything and explains. The browser sends the CSRF header on every call that is not a GET.
- Tests: `Deletion` and `DeleteOverHttp` in `tests/ai_builder_editing_test.py` (12), a proxy test, and 7 Node UI tests in `tests/ai_builder_ui_test.js`.

## Known limitations

- The list offers one trash button for the open conversation, not one per row: the selector is a native `<select>`. Select a conversation, then delete it.
- Only session files for the ids recorded in the conversation are removed. A session that Claude Code created but the record never confirmed (a first call that crashed) is not identifiable and is left alone; it is small and harmless.
- A deleted conversation cannot be restored; its published changes (if any) stay published.
- Host mode (no `CLAUDE_CONFIG_DIR`) looks for sessions under `~/.claude` of the user running the AI Builder.
