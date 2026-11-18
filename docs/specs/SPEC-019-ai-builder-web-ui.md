# SPEC-019: AI Builder Web UI panel

Status: implemented; verified with Node tests against a fake DOM and a scripted `fetch`. **Never opened in a real browser**: rendering, layout, themes and focus behavior are covered only by the manual checklist in [../ai-builder.md](../ai-builder.md). Builds on [SPEC-018](SPEC-018-ai-builder-api-proxy.md).

## Original request (summary)

Integrate the AI Use Case Builder into the existing Web UI: an "AI Builder" button in the navigation; a panel or modal in the existing design; a form (name, description, optional reference use case); availability and Claude authentication status; generate through the existing API; poll and display progress, validation results and errors; file selector with a readable source preview; explicit approval before publishing; publish and show success or failure; refresh the use case list after publication. Only the FastAPI proxy (never port 8099), no token or Claude credential exposed, `X-Requested-With: playground` on POST, graceful handling of a stopped, unavailable or unauthenticated AI Builder, no duplicate submission or double publication, existing UI preserved. Frontend only; no change to the generation logic or use cases; no browser-based Claude login yet; safe tests only.

## Implemented

- `web/static/ai-builder.js` (new, loaded after `app.js`; every top-level name is `AIB`-prefixed so it cannot clash with `app.js`), a header button and a `<dialog>` in `index.html`, styles at the end of `style.css` using the existing theme variables. `app.js` is unchanged; the panel calls its globals `refreshUseCases()` / `refreshTerminals()` and reads `items`.
- Behavior: see the "Web UI panel" section of the AI Builder document. Notable guards: `submit` ignores calls while a request is in flight, while a job exists or while the service is unavailable; the publish lock is taken before any `await`; approve is skipped when already approved; a publish that times out re-reads the server state.
- No backend change.
- Tests: `tests/ai_builder_ui_test.js` via `tests/ui.sh` (pure logic, behavior against a fake DOM, static rules: ids exist in `index.html`, no HTML sinks, no port or credential strings, a single `fetch` call site); `tests/static.sh` syntax-checks the script.

## Addendum: layout fix

Report: the modal rendered as an unstyled form (labels running into inputs, narrow fields, a tiny textarea, Close inside the status line). Reproduced in headless Chrome: the page renders exactly like that when `style.css` lacks the modal block, i.e. with a browser still holding an older cached `style.css` (static files carry no `Cache-Control`; this is the likely cause, not proven for the reporter's browser). With the current CSS the earlier layout was functional but compact (two-column fields, badge on the title line, 5-row textarea, 1040px) and had one real bug: `.aib-approve { display: flex }` overrode the `hidden` attribute, so a draft that failed validation still showed its approval box.

Fix: the modal styles moved to a new `web/static/ai-builder.css` (a new URL cannot be stale; every selector scoped under `#aib`; `style.css` is back to its original content), `#aib [hidden] { display: none !important }`, and the markup restructured without changing any id or the script: header (title, Close), status badge on its own line, stacked full-width fields, textarea at least 150px, modal 760px wide and responsive (under 640px: one column, full-width actions), readable progress stepper, error boxes, file list and preview, and approval block. Verified by rendering light, dark, narrow and each state in headless Chrome from static files with a stubbed `fetch`; new Node tests guard the scoping, the `hidden` rule, the geometry and the markup structure.

## Limits

No real browser run; the fake DOM does not check CSS, layout or accessibility behavior. Signing in to Claude from the page was not available in this phase (added by [SPEC-020](SPEC-020-ai-builder-browser-auth.md)). The job id is stored in `localStorage`. The Playground container must be restarted to expose the proxy routes (static files do not need it).
