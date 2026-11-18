# SPEC-020: AI Builder browser sign-in

Status: implemented and verified with a fake `claude` script (in a real PTY), a fake DOM and mocked routes. **No real login, logout or generation was ever run**; the real CLI's login screen was inspected only through `--help` and the strings of its binary. Documentation: [../ai-builder.md](../ai-builder.md) ("Browser sign-in"). Builds on [SPEC-017](SPEC-017-ai-builder-container.md), [SPEC-018](SPEC-018-ai-builder-api-proxy.md) and [SPEC-019](SPEC-019-ai-builder-web-ui.md).

## Original request (summary)

Let users authenticate Claude Code from the Playground Web UI without a terminal: a "Connect to Claude" action when not authenticated; an interactive Claude Code login session inside the AI Builder container; the official authentication URL shown to the user; a secure way to submit an authorization code if the CLI needs one; automatic detection of success; logout and reconnection; persistence across container restarts (the existing volume); handling of expired sessions, failures and timeouts; no concurrent login sessions. Narrow endpoints in the AI Builder, exposed through the existing proxy, controls in the existing modal; a controlled PTY interaction if required, no general web terminal. Never expose stored credentials, never log or persist authorization codes, keep the local access model and the CSRF protection, no arbitrary command execution, sessions isolated from generation jobs. Investigate the CLI first, do not assume an OAuth callback or device API, do not write a custom OAuth client, do not bypass corporate authentication; explain limitations instead of an insecure workaround. Mocked lifecycle tests (URL extraction, sessions, timeout, cancellation, logout), leak checks, safe suites only, no real login/logout/generation, no Docker/Kubernetes/Helm/scenarios.

## Detected mechanism

`claude auth login [--claudeai|--console|--sso] [--email E]` (interactive screen needing a TTY): official sign-in address plus `Paste code here if prompted >`; the browser's last page shows a code; `Login successful. Press Enter to continue`. `claude auth status --json` (`loggedIn`) and `claude auth logout` are non-interactive. The CLI contains its own OAuth client (automatic localhost callback, manual code path). No device flow, no token-exchange command, no code-as-argument. Hence a PTY session that only reads the address and writes the pasted code.

## Implemented

- `ai-builder/auth.py` (`AuthManager`), routes `GET /auth/status`, `POST /auth/login|code|cancel|logout` in `server.py`; `AI_BUILDER_LOGIN_TIMEOUT`.
- Proxy operations `auth_*` and routes `/api/ai-builder/auth/*` with a response allow-list and redaction of the submitted code; the panel gets **Connect to Claude**, a method (and optional e-mail) form, the official link with "Copy link", a password-type code field, a poller, Cancel, **Disconnect** (two clicks), expired-session and job-auth-failure hints.
- Safety: fixed argv; address allow-list (https, claude.ai/claude.com/anthropic.com); code shape check; one session; no overlap with generation; success only after `auth status`; fixed error messages; raw screen never stored or returned; host mode refused (a host `logout` would sign the developer out).
- Tests: `tests/ai_builder_auth_test.py` (28), 6 proxy tests, 20 UI tests; found and fixed while writing them: a retained screen buffer (the echoed code), an unreaped process, a race on an immediately exiting process, an unknown status being read as "expired", errors erased by the poller, host-mode logout.

## Limits and risks

The real screen was not driven: matched phrases, `auth status` fields and the way a pasted line is accepted come from the binary's strings. A corporate/SSO flow that needs more than "open link, paste code" is not worked around. Anything the user pastes goes to Claude Code only. The panel's status check starts a `claude` process (at most every 25 s while open).
