# SPEC-017: AI Builder container (Phase 1)

Status: implemented and verified **statically only** (rendered Compose model, unit tests with mocks, CLI tests with a fake docker). The image has never been built, no container started, no Claude login made. Documentation: [../ai-builder.md](../ai-builder.md). Builds on [SPEC-016](SPEC-016-ai-usecase-builder-mvp.md).

## Original request (summary of the approved decisions)

Containerize the AI Builder backend and the Claude Code CLI: a dedicated Compose service `ai-builder` behind a Compose profile; the existing Python backend reused; Claude Code installed and pinned in the image; non-root user; no Docker socket; only the required repository directories mounted read-only; bind mounts for jobs, drafts and published use cases; Claude authentication in a dedicated persistent volume; API protected by a bearer token; host mode kept temporarily as an explicit fallback; CLI commands for container start, stop, status and interactive login; atomic publication preserved; tests and documentation; no change to existing use cases; never delete or reset `.ai-builder/`; no credential exposed through the Web API; no container started, no login, no Web UI integration in this phase.

## Implemented

- `ai-builder/Dockerfile` (Node 22 + Python 3 + bash, `@anthropic-ai/claude-code@2.1.326`, user 1000, no credential) and compose service `ai-builder` (profile, `read_only`, `cap_drop: ALL`, `no-new-privileges`, pids/memory limits, loopback-only published port, compose secret for the token, repository allowlist mounted read-only, `/state` and `/publish/usecases` bind mounts, volume `claude-auth`).
- Python: container settings (`AI_BUILDER_BIND`, `_ROOT`, `_STATE_DIR`, `_PUBLISH_DIR`, `_TOKEN_FILE`, `_ALLOWED_HOSTS`); bearer token (constant-time, all routes but a minimal `/health`); fail-closed when listening beyond loopback without a token; `/health` reports only whether a credentials file exists; extra deny rules (token, login directory, `/run/secrets`, `/proc`) and `--add-dir` for a draft outside the working directory.
- Atomic publish: staging inside the publish directory (same filesystem, hidden), single rename, cleanup in all failure paths, refused while a generation job runs, duplicate check in both the repository view and the publish directory.
- CLI: `ai-builder start|stop|status|login|logout` (container) and `ai-builder host start|stop|status` (previous behavior); `stop`, `uninstall` and `purge` include the profile.
- Tests: `tests/ai-builder.sh` (67 unit tests, host CLI lifecycle on a free port, rendered Compose model assertions, real `.ai-builder/` fingerprint), `tests/cli.sh` (container commands with a fake docker and curl). `tests/static.sh` checks the new Python files.

## Limits and open risks

Not built, not started, not signed in; the browser sign-in in a container, `--add-dir`, the permission rule syntax and the pinned npm package in the image are unverified. Within `/state` and `/publish/usecases` the agent is bound only by Claude Code's permission policy (same user). Linux uid mapping (container user 1000). `purge` removes the login volume. The host-mode fallback keeps the weaker isolation and is meant to be removed after validation.
