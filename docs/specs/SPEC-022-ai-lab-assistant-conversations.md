# SPEC-022: AI Lab Assistant, persistent read-only conversations (P1.2)

Status: implemented and verified with a scripted runner (mocked Claude), a fake DOM and a fake upstream server. **No real Claude call was made.** The behaviours that depend on the real CLI are listed under "To validate manually" and in `docs/ai-builder.md` (steps 14-21).

## Original request (verbatim)

> Implement P1.2 — Persistent Conversations for the AI Lab Assistant.
> Context: P1.1 is implemented and validated with a real Claude generation. The existing AI Builder works and must remain fully functional. We want to evolve it into a conversational Lab Assistant, without introducing an agent framework or unnecessary complexity.
> Goal: Allow users to start, continue, and reopen natural-language conversations with Claude Code.
> 1. Conversation lifecycle: create a conversation; send a message; continue an existing conversation; list and reopen conversations; preserve conversations across browser sessions and container restarts; support conversations associated with a Lab, without requiring a Lab.
> 2. Claude Code sessions: use --session-id for the first invocation; use --resume for subsequent invocations; capture structured JSON responses; store the session UUID; preserve Claude's native session files in the existing persistent volume; keep one Claude invocation at a time per conversation.
> 3. Usage tracking: reuse P1.1 metrics; track usage per turn and conversation; distinguish cumulative session costs from incremental turn costs; apply configurable per-call limits; introduce a configurable conversation budget with an 80% warning and a 100% stop; treat CLI cost figures as API-equivalent estimates, not actual subscription charges.
> 4. Context management: avoid injecting the full conversation history into every prompt; rely on Claude's native session continuity; track context growth; prepare for future session rotation and summarization; do not implement a complex memory system.
> 5. Security: conversation mode must initially be read-only; no Write, Edit, Bash, WebFetch or WebSearch tools; do not modify existing or published Labs; preserve current authentication and permission restrictions; do not expose credentials or raw session transcripts through the API.
> 6. Backend: reuse the existing Python service; use simple JSON persistence; reuse the existing execution and usage logic; add minimal API endpoints for conversation management; preserve all existing AI Builder endpoints and workflows.
> 7. UI: add a simple conversational interface to the existing AI Builder panel; display messages, responses, model, tokens and estimated cost; allow reopening previous conversations; show conversation budget and warnings; preserve the existing Generate/Validate/Review/Approve/Publish workflow.
> 8. Validation: add mocked tests for session creation, resume, persistence, budgets, usage accounting, concurrency and permissions; run existing test suites; do not perform real Claude calls automatically.
> Before implementation: inspect the existing architecture and explain the minimal integration plan. Then implement incrementally, avoiding unrelated refactoring. Report files changed, tests, limitations and any manual validation required.

## Implemented

- `ai-builder/conversations.py` (new): `ConversationManager` (create, list, get, send; one JSON file per conversation in `<state>/conversations/`, atomic writes, reload at start, a turn interrupted by a restart is recorded as failed); `conversation_args` (argument list, message last and never an option); per-turn thread through the same `run_process`, `parse_claude_json` and `extract_usage` as generation (P1.1); session handling (`--session-id` then `--resume`, fresh id when a first call produced no session, resume when Claude's session file exists); cost accounting (turn cost = difference of the cumulative session totals, tokens per call); budget (80% warning, 100% refusal, each call capped at the remaining budget); context tracking; limits (one running turn per conversation, 2 in total, none during a sign-in, 100 messages).
- `ai-builder/server.py`: `POST/GET /conversations`, `GET /conversations/<id>`, `POST /conversations/<id>/messages`; the sign-in manager treats a running conversation as busy.
- `ai-builder/builder.py`: `Config.conversation_budget_usd`, `Config.context_warn_tokens`, `Config.claude_missing()`; `run_process(env=)`; `secret_deny_rules()` and `attempt_failure()` extracted so generation and conversations share them (generation also denies `Read` of `<state>/conversations/**` now); the model entry of `extract_usage` carries `context_window`.
- `web/ai_builder_proxy.py`, `web/app.py`: `conv_create/list/get/send` operations and four routes (conversation id validated, own regex; messages forwarded without `\uXXXX` inflation; a 2 MB response limit for one conversation).
- `web/static/index.html`, `ai-builder.js`, `ai-builder.css`: tabs *Generate a use case* / *Conversations*; the generate flow is wrapped in a pane, unchanged; conversation select, new-conversation form (optional Lab), messages, per-reply model, tokens and estimated cost, budget bar with warnings, context hint, polling, double-send guard; only the conversation id is kept in `localStorage`.
- `compose.yaml`: `AI_BUILDER_CONVERSATION_BUDGET_USD` (10) and `AI_BUILDER_CONTEXT_WARN` (150000) passed with defaults.
- Tests: `tests/ai_builder_conversation_test.py` (40), `ConversationOperations` in `tests/ai_builder_proxy_test.py`, section 3 of `tests/ai_builder_ui_test.js`; wired into `tests/ai-builder.sh` and `tests/static.sh`.
- Not changed: generation, validation, review, approve, publish, authentication, the existing endpoints.

## Design decisions

- Read-only: `--tools=Read,Glob,Grep`, same three in `--allowedTools`, `Write`/`Edit`/`Bash`/`NotebookEdit`/`WebFetch`/`WebSearch` denied by rule, `--strict-mcp-config` (no connector tools), `CLAUDE_CODE_DISABLE_AUTO_MEMORY=1` (the P0.2 runaway was a model trying to write a memory file without tools), `dontAsk`, secrets and login directory denied for `Read`.
- The session id is not returned by the API (nothing needs it) and Claude's transcript is never read; only the existence of its file is tested.
- `total_cost_usd` is treated as the session's cumulative cost because that is what P0.1/P0.2 showed; this is an inference and is flagged for manual validation. If a total goes down, it is taken as reported.

## Known limitations

- Estimated cost only; a turn without usage (timeout, crash) counts as 0 and is reported as unmetered. A call killed by the timeout may have cost something.
- No session rotation or summarization yet: a long conversation gets a context warning and a hard stop at 100 messages. A resume re-reads the whole session (P0.2: about $2.5 for a large one).
- Conversations are never deleted from the panel; there is no editing of Labs yet (read-only by design).
- `--strict-mcp-config` and `CLAUDE_CODE_DISABLE_AUTO_MEMORY` were not exercised against the real CLI (the flag exists in `--help`, the variable name is a string in the binary).
- The panel layout of the new tab was not looked at in a browser.

## To validate manually

Steps 14-21 of `docs/ai-builder.md` (real account and browser): first message and resume, follow-up coherence, persistence across reload and container restart, read-only behaviour, cumulative-versus-per-call cost, budget warning and stop, concurrent tabs, effect of `--strict-mcp-config` on the initial token count.
