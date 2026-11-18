# SPEC-021: AI Execution Manager (P1.1)

Status: implemented and verified with mocked runners only (86 AI Builder unit tests, all suites green). **No real Claude call was made by the tests.** Real CLI behaviour (`--output-format json` result shape, budget stop, `--no-session-persistence` with JSON) was observed in the P0.1/P0.2 experiments; a first real generation after this change is still to be run by a person.

## Original request (summary)

Introduce a lightweight AI Execution Manager into the existing AI Builder, focused on token efficiency, execution safety and usage tracking, without redesigning the application or adding an agent framework: explicit model selection (Sonnet by default, configurable, no implicit model); per-invocation timeout and `--max-budget-usd` with sensible defaults, and a timeout that terminates the complete subprocess tree; capture of the CLI JSON output with input, output, cache-read and cache-creation tokens, total cost, duration and per-model usage, tolerating missing metrics; persistence next to the job metadata with no database, no extra files and no credentials; the one-shot workflow, permission restrictions, draft isolation and publication unchanged (no Bash, WebSearch or WebFetch, no persistent conversations). Tests without real API calls for JSON parsing, missing fields, budget exhaustion, timeout, model configuration and existing-job compatibility.

## Implemented

- `ai-builder/builder.py`: `Config` (`AI_BUILDER_MODEL` default `sonnet`, validated; `AI_BUILDER_TIMEOUT` 900; `AI_BUILDER_MAX_BUDGET_USD` 3; invalid values fall back to the defaults); `claude_args` adds `--output-format json`, `--model`, `--max-budget-usd` (the model is no longer omitted when unset); `run_process` bounds the wait after killing the process group; `parse_claude_json`, `extract_usage`, `sum_usage`; `_attempt` stores `model`, `timeout`, `max_budget_usd`, `usage` and the reply text (not the raw JSON) in `output_tail`; `JobManager._failure` reports timeout, budget stop (`error_max_budget_usd`), non-zero exit and `is_error` distinctly; `public_view` adds the job `usage` totals.
- `compose.yaml`: `AI_BUILDER_MODEL`, `AI_BUILDER_TIMEOUT`, `AI_BUILDER_MAX_BUDGET_USD` passed with defaults.
- Unchanged: tool list, allow and deny rules, `dontAsk`, `--no-session-persistence`, validation, review, approve, publish, auth, proxy and UI (the UI ignores the new fields; old jobs load with `usage: null`).
- Tests: `tests/ai_builder_test.py` class `ExecutionManager` (19 tests).

## Known limitations (for P1.2)

- The cap is per run; no per-job, per-day or per-Lab budget yet, and a killed run reports no usage.
- A runaway turn was observed in P0.2 (one prompt produced 128k output tokens before finishing); the budget now bounds it, but the output length is not otherwise limited.
- The Web UI does not display usage yet.
- Process-tree kill relies on the process group; a descendant that starts its own session would survive (the pipes are abandoned after 10 s).
- Whether the JSON result is identical with `--no-session-persistence` and the exact exit code on budget stop were inferred from P0 runs with sessions on; confirm on the first real generation.

## Original request (verbatim)

> We are starting P1.1 of the AI Lab Assistant project. Goal: introduce a lightweight AI Execution Manager into the existing AI Builder, focusing on token efficiency, execution safety, and usage tracking. IMPORTANT: The current AI Builder works end-to-end. Preserve all existing behavior, APIs, authentication, validation, review, approval, and publication. Do not redesign the application or introduce an agent framework.
> Step 1 — Inspect: ai-builder/builder.py, Claude CLI invocation and subprocess handling, job persistence and status reporting, Docker configuration, existing model and timeout settings; identify the smallest safe integration points.
> Step 2 — Implement: (1) Explicit model selection: Sonnet default, configurable through existing settings where possible, no implicit model selection. (2) Execution limits: configurable timeout per Claude invocation; configurable --max-budget-usd per invocation; sensible defaults that do not break legitimate Lab generation; timeout terminates the complete subprocess tree. (3) Usage tracking: capture Claude CLI JSON output; record input_tokens, output_tokens, cache_read_input_tokens, cache_creation_input_tokens, total_cost_usd, execution duration, model usage when available; handle missing or incomplete metrics gracefully. (4) Persistence: store usage metrics alongside existing job metadata; no database or excessive files; no credentials or unnecessary sensitive output. (5) Compatibility: preserve the one-shot workflow, permission restrictions, draft isolation and publication; do not enable Bash, WebSearch or WebFetch; no persistent conversations yet.
> Step 3 — Validate: run existing tests and add focused tests for JSON response parsing, missing usage fields, budget exhaustion, timeout handling, model configuration, existing job compatibility. Do not trigger real Claude API calls during automated tests.
> Step 4 — Report: files changed, configuration defaults, tests executed and results, compatibility risks, remaining limitations for P1.2. Keep the implementation minimal, maintainable, and aligned with the existing architecture. Do not modify unrelated Playground components.
