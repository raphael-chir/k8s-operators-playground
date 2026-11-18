# SPEC-016: AI Use Case Builder (backend MVP)

Status: implemented and verified with mocks (`tests/ai-builder.sh`); **never run against the real Claude Code CLI**. Web UI out of scope. Documentation: [../ai-builder.md](../ai-builder.md).

## Original request (summary)

Local, minimal service on the host that generates playground use case drafts from a natural-language description through `claude -p` and the existing `playground-usecase-builder` skill; `POST /generate`, `GET /status/{job_id}`; drafts under `.ai-builder/drafts/<job-id>/`, git-ignored; automatic static validation with one correction attempt; `./playground ai-builder start|stop|status`; bound to 127.0.0.1; one concurrent job; no unrestricted permission bypass; document the Docker reachability question; no change to the Web UI, the FastAPI backend or existing use cases; tests without the real CLI.

## Implemented

- `ai-builder/server.py` (HTTP, standard library), `builder.py` (request validation, jobs, Claude Code invocation), `validator.py` (static checks).
- CLI: `ai-builder start|stop|status` (host only; PID file checked against the process command line before any kill).
- Differences from the request, deliberate: the draft is `.ai-builder/drafts/<job-id>/<name>/` (the use case directory itself, to make publication a move); `status` is `failed` (with the draft kept and `validated: false`) when validation fails after the correction, instead of `completed` with `passed: false`; extra routes `GET /health`.
- Conflicts with conventions: the skill asks for output in `usecases/<name>/` and for `README.md`; the prompt overrides the location and keeps the README. PyYAML is not guaranteed on the host, so `usecase.yaml` is checked with the engine's own YAML subset and manifests with PyYAML only when installed.

## Addendum: Review and Publish

Request: "Generate → Validate → Review → Publish → Run". Added `GET /review/<id>`, `POST /approve/<id>` (validated drafts only; stores a hash of the draft) and `POST /publish/<id>` (approved, unchanged, re-validated, never overwrites, atomic rename, scripts made executable). Run is the existing `./playground usecase start <name>`; the builder never executes anything. Tested with mocks; no CLI commands for these steps yet (HTTP only).

## Limits

Permission-based isolation, not an OS sandbox. Real Claude Code invocation untested. No draft cleanup, no authentication (loopback only), Docker access not implemented (see the document).
