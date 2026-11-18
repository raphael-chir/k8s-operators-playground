# SPEC-018: AI Builder API proxy

Status: implemented; the proxy logic is tested against a fake upstream; the six FastAPI routes are verified **statically only**; nothing was run in the Playground container or against the real AI Builder. Documentation: [../ai-builder.md](../ai-builder.md) (section "Playground API proxy"). Builds on [SPEC-016](SPEC-016-ai-usecase-builder-mvp.md) and [SPEC-017](SPEC-017-ai-builder-container.md).

## Original request (summary)

Backend integration between the Playground FastAPI application (service `playground`) and the containerized AI Builder (service `ai-builder`, port 8099, bearer token, same Compose network): a proxy under `/api/ai-builder/` for health, generate, status, review, approve and publish; forward to `http://ai-builder:8099`; server-to-server bearer authentication with the existing token; never expose the token to the browser; graceful handling of a stopped or unavailable AI Builder; preserve upstream error codes and messages; timeouts and request-size limits; no change to the AI Builder generation logic or to existing use cases; no arbitrary proxy destination; no Claude credentials exposed; keep the existing local access model; mocked integration tests; no Docker, Kubernetes, Helm, Claude Code or scenario; no Web UI.

## Implemented

- `web/ai_builder_proxy.py` (standard library): fixed upstream (`AI_BUILDER_URL`), operation table with per-operation timeouts, job-id validation and path templates, fresh headers only, JSON-only bodies (16 KB) and responses (1 MB), token read per request from `/workspace/.ai-builder-token` (`AI_BUILDER_TOKEN_FILE`), Host allowlist, `X-Requested-With: playground` on POST, health always answerable (`available`, `state`).
- `web/app.py`: six thin routes before the static mount, a body reader capped at 16 KB for `generate`, a fail-safe construction of the proxy.
- Error mapping: upstream status and body preserved; added 503 (`stopped`, `not_configured`), 504, 502 (bad or oversized answer, or the AI Builder rejecting the token: reported as a server-side problem rather than a browser 401).
- Tests: `tests/ai_builder_proxy_test.py` (21 tests, fake upstream on loopback) run by `tests/ai-builder.sh`; static syntax checks in `tests/static.sh`.

## Compose configuration

No change. The services already share the project network, `ai-builder` resolves by service name, and the token file is reachable through the existing `.:/workspace` bind mount of the `playground` service (a compose secret would make `./playground start` depend on the optional token file). The running Playground container must be restarted to load the new routes (it closes open terminals).

## Limits

FastAPI wrappers and the container-side file path are not exercised; the Host/CSRF checks protect only the new routes (the existing start/stop routes keep their previous behavior); the token file is readable by anyone in the Playground container (root, with the Docker socket, as before).
