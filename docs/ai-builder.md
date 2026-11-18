# AI Use Case Builder

Generates a **draft** use case from a natural-language description with the Claude Code CLI, lets you review it, then publishes it into `usecases/`. Specifications: [SPEC-016](specs/SPEC-016-ai-usecase-builder-mvp.md) (service), [SPEC-017](specs/SPEC-017-ai-builder-container.md) (container). The Web UI is not connected yet.

```
Generate -> Validate -> Review -> Publish -> Run
```

It runs as an **optional container** (Compose profile `ai-builder`) with Claude Code installed in the image. The earlier **host mode** (`ai-builder host ...`) still works as a temporary fallback.

## Prerequisites

- Container mode: Docker (as for the Playground). Nothing else on the host: no Python, no Claude Code.
- Host mode (fallback): Python 3 and the `claude` CLI signed in on the host.
- A Claude account for the sign-in (`./playground ai-builder login`).

## Container mode

```bash
./playground ai-builder start     # builds the image on first use, starts cnpg-ai-builder on 127.0.0.1:8099
./playground ai-builder login     # interactive: Claude prints a URL, open it in your browser, paste the code back
./playground ai-builder status    # container, health, and whether a Claude login exists (never its content)
./playground ai-builder stop      # stops only this container; jobs, drafts and the login are kept
./playground ai-builder logout    # removes the login from the claude-auth volume
```

`./playground start` does **not** start it (profile). `./playground stop`, `uninstall` and `purge` include it; `purge` also removes the `claude-auth` volume (you sign in again), but never `.ai-builder/` or `usecases/`.

### What is mounted

| In the container | From | Mode | Why |
|---|---|---|---|
| `/workspace/{ai-builder,.claude,CLAUDE.md,VERSION,docs,engine,platform,usecases}` | the repository | **read-only** | the service and what the agent reads. Nothing else is mounted: no `.env`, `.git`, `compose.yaml`, `tests`, `web`. |
| `/state` | `./.ai-builder/` (bind) | read-write | jobs, drafts, conversations and Lab working copies, kept in the repository tree (git-ignored) |
| `/home/builder` | volume `claude-auth` | read-write | the Claude login. Never in the image, the repository or an environment variable |
| `/run/secrets/ai_builder_token` | `./.ai-builder-token` (compose secret) | read-only | the API bearer token (mode 600, git-ignored, created by `start`) |

No Docker socket, no `privileged`, all capabilities dropped, `no-new-privileges`, read-only root filesystem (tmpfs `/tmp`), user 1000, memory and PID limits. The container has no Docker, Kind, kubectl or Helm.

**Published Labs are read-only in this container, at the operating-system level** (SPEC-023). Since the container cannot switch users, a writable `usecases/` mount anywhere in it would be writable by Claude Code too, protected only by permission flags. So the writable mount lives in a second, tiny container, `ai-publisher` (same image, no Claude Code, no login, no port on the host, `/state` mounted read-only, the usecases directory as its only writable mount). `./playground ai-builder start|stop` handle both. When you publish (a generated use case or a changed Lab), the AI Builder asks the publisher, which does **not** trust the request: it recomputes the content hash of the draft or working copy (it must equal what you approved), validates it again, and for a replacement refuses when the published Lab no longer matches the one the working copy was made from. If the publisher is down, nothing is published and there is no local fallback. Host mode (no containers) still publishes directly from the AI Builder process.

### Network and token

The API listens on `0.0.0.0` **inside** the container (the service refuses to do so without a token) and is published on the host loopback only (`127.0.0.1:8099`). The Playground container reaches it as `http://ai-builder:8099` on the Compose network (the Kind network is not involved). Every route except `GET /health` needs `Authorization: Bearer <contents of .ai-builder-token>`; `/health` without the token returns only `{"status": "ok"}`. The token is compared in constant time, never printed, never put on a command line. Allowed `Host` names: `ai-builder`, `cnpg-ai-builder`, `127.0.0.1`, `localhost`.

### Sign-in

Two equivalent ways, both running Claude Code's own `claude auth login` inside the container and storing the login in the `claude-auth` volume (it survives container restarts and `stop`/`start`; `purge` and `logout` remove it):

- from the Playground page: **Connect to Claude** in the AI Builder panel (see "Browser sign-in" below);
- from a terminal: `./playground ai-builder login` (and `logout`).

The host's own Claude login (macOS Keychain) is never shared. `/health` (with the token) reports `claude_credentials_present`, which only tests that a credentials file exists and never reads it.

Linux note: the container user is 1000. The host files it writes (`.ai-builder/`, published use cases) and the token it reads must be usable by that uid.

## Host mode (temporary fallback)

```bash
./playground ai-builder host start|stop|status     # 127.0.0.1:8099, host Python + host claude, no token
```

Same code, same API, state in `.ai-builder/`. Start only one of the two modes: container `start` refuses while host mode runs. Settings: `AI_BUILDER_PORT` (8099), `AI_BUILDER_TIMEOUT` (900 s per Claude Code run), `AI_BUILDER_MODEL` (default `sonnet`), `AI_BUILDER_MAX_BUDGET_USD` (default 3 per run), `AI_BUILDER_STATE_DIR`. See *Execution limits and usage*.

## Execution limits and usage

Every Claude Code run is started with explicit limits and its result is recorded (SPEC-021):

| Setting | Default | Effect |
|---|---|---|
| `AI_BUILDER_MODEL` | `sonnet` | passed as `--model` on every run; never left to the CLI default. Only letters, digits and `._[]-` are accepted, otherwise the service refuses to start |
| `AI_BUILDER_TIMEOUT` | `900` | seconds per run; on expiry the whole process group (the CLI and anything it started) is killed with SIGKILL |
| `AI_BUILDER_MAX_BUDGET_USD` | `3` | passed as `--max-budget-usd`; Claude Code stops itself at this spend and the job fails with "the per-call budget of $N was reached" |

An empty, malformed, zero or negative value falls back to the default: a limit is never switched off by a typo. In the container the three variables come from `compose.yaml` (`${VAR:-default}`), so `AI_BUILDER_MAX_BUDGET_USD=1 ./playground ai-builder start` changes them. The budget and timeout apply to each run: a generation with one correction pass can spend up to twice the budget.

Runs use `--output-format json`. Each entry of a job's `attempts` (returned under `claude` by `GET /status/<id>?detail=1`) gains `model`, `timeout`, `max_budget_usd` and `usage`: `input_tokens`, `output_tokens`, `cache_read_input_tokens`, `cache_creation_input_tokens`, `total_cost_usd`, `duration_ms`, `duration_api_ms`, `num_turns`, `subtype`, `is_error`, `stop_reason` and `models` (per model tokens and `cost_usd`). Any field the CLI does not report is `null`; the job never fails because usage is missing. The job's `usage` field (also in `GET /status/<id>`) totals the attempts (`calls`, `calls_with_usage`, tokens, cost, duration); it is `null` for jobs created before this feature. Only numbers and short labels are stored, plus the reply text tail that was already kept (`output_tail`); nothing from the login or the process environment.

Limits: costs are what the CLI reports (a subscription login may report a list-price cost that is not billed); a run killed by the timeout reports no usage; the cap is per run, not per day or per user.

## Conversations (AI Lab Assistant)

Besides one-shot generation, the AI Builder keeps **persistent conversations** with Claude Code (SPEC-022): read-only, except that a conversation about a Lab can also change a working copy of it (SPEC-023, below). They are listed, reopened and continued from the *Conversations* tab of the panel, survive a browser reload and a container restart, and may be about one existing Lab or about none.

- **Sessions.** The first message of a conversation starts a Claude Code session with `--session-id <uuid>`; every next message uses `--resume <uuid>`. Claude's own session files stay in the `claude-auth` volume (`~/.claude/projects/…`), so the history is never pasted into a prompt: each call sends only the new message. The session id stays on the server (it is not in any API answer). If a first call produced no session (timeout, crash), the next message starts a fresh one; if Claude's session file exists, the conversation resumes it even after an interrupted turn.
- **One call at a time per conversation** (a second message gets 409), at most 2 Claude calls at once across conversations, and none while a Claude sign-in is in progress. A sign-in cannot start while a conversation is answering.
- **Read-only.** Claude gets only `Read`, `Glob` and `Grep` (`--tools`, `--allowedTools`); `Write`, `Edit`, `Bash`, `NotebookEdit`, `WebFetch` and `WebSearch` are denied by rule as well, secrets, `.git`, job files, other conversations and the Claude login are not readable, MCP servers are not loaded (`--strict-mcp-config`), Claude's auto-memory is switched off (`CLAUDE_CODE_DISABLE_AUTO_MEMORY=1`), and the system prompt says the conversation is read-only by default. This is the policy of every message, except a message that asks for a change in a conversation **about a Lab**, which may also Write/Edit inside that conversation's working copy (see *Discussing and changing a Lab*). A conversation never writes a published Lab: the container cannot (read-only mount). The permission policy is a Claude Code policy, not an operating-system sandbox, which is why the published Labs' protection is the mount, not the flags.
- **Records.** One JSON file per conversation in `.ai-builder/conversations/` (git-ignored), written atomically: title, Lab, budget, the messages (your text and Claude's reply, replies shortened above 8000 characters) and the usage of each turn. It is not Claude's transcript. A conversation stops at 100 messages. A turn interrupted by a restart is recorded as failed.

### Discussing and changing a Lab (SPEC-023)

A conversation about a Lab is also where you change it, in the same chat, with no mode to choose. Three things are kept apart:

| | Where | Who can write it |
|---|---|---|
| **Published Lab** | `usecases/<lab>/` | only the `ai-publisher` container, when you publish |
| **Working copy** | `.ai-builder/workspaces/<conversation>/work/`, made from the published Lab the first time a change is requested | Claude Code (Write/Edit on that one directory) |
| **Claude session** | `--session-id` / `--resume`, in the `claude-auth` volume | Claude Code; it only carries the dialogue |

The session never holds the files: changes live in the working copy, so Undo and Reset do not touch the session (Claude is told in its next message what you undid, reset or published). The working copy survives a reload and a container restart.

- **When Claude may edit.** A message that asks for a change (add, remove, rename, change, fix, improve, create, apply, "go ahead", ajoute, supprime, modifie, corrige…) gets `Write` and `Edit` for that message, allowed only inside the working copy (`Write(<working copy>/**)`); the repository and the publish directory are denied by rule. The conversation then stays editable for follow-ups ("make it shorter") until you Reset, start over or publish. Every other message keeps the read-only tools (`Read`, `Glob`, `Grep`), and can still read the working copy to answer about pending changes. `Bash`, `WebFetch` and `WebSearch` are never enabled. The match is deliberately generous: a false positive only lets Claude write into an isolated copy you can undo; a miss makes Claude describe the change and ask you to tell it to apply it.
- **Light snapshots.** The initial state and the state before each editing message are stored as a manifest (`path → sha256`) plus the few file contents not stored yet (content-addressed, deduplicated, unreferenced contents removed). There is no copy of the Lab per message. Undo returns to the state before the last editing message (the last 20 are kept), Reset to the Lab as it was when the copy was made. No Git, no database.
- **Pending changes.** The conversation shows "N files changed in the working copy … not published" with **Review changes**, **Undo** and **Reset** (Reset and "Start over" take two clicks). *Review changes* lists modified, added and deleted files, shows a readable diff of each, the result of the validation and any conflict. A message whose edit would grow the Lab past 300 files or 4 MB is rolled back.
- **Publishing.** In the review: tick the approval, then **Publish**. The request carries the hash of the reviewed content; the AI Builder re-validates, checks for a conflict, and asks the publisher, which checks all of it again and swaps the Lab in (`renameat2` exchange where the filesystem allows it, otherwise two renames with automatic rollback). Nothing is ever published automatically, and publication is refused while a generation job runs. Afterwards the working copy becomes the new baseline and the conversation continues.
- **Conflicts.** If `usecases/<lab>/` changed after the working copy was made (someone published, or you edited it by hand), the panel says so, Publish stays off, and **Start over from the published Lab** drops the working copy so the change can be asked for again on top of what is published now. Nothing is overwritten.
- **Limits.** The OS boundary protects published Labs only. Within `/state`, Claude could (if its permission policy failed) alter another conversation's working copy; its own reads are not restricted to its working copy.

API (all need the token; also under `/api/ai-builder/conversations/<id>/…` in the Playground, POST with the CSRF header):

| Request | Answer |
|---|---|
| `GET /conversations/<id>/review` | `changes` (added, modified, deleted), `diff` (per file, bounded), `validation`, `conflict`, `can_publish`, `tree_hash` (what an approval is bound to) |
| `POST /conversations/<id>/undo` · `reset` · `discard` | the conversation (409 when nothing to undo, no working copy, or the conversation is answering) |
| `POST /conversations/<id>/publish` `{"approve": true, "tree_hash"}` | `{lab, published, changes, run, conversation}`; 400 without approval, 409 for a changed working copy, validation failure, conflict or a running generation, 503 publisher down |

The conversation view gains `workspace` (`exists`, `editing`, `changes`, `can_undo`, `conflict`, `publications`), `can_edit`, and each message `edit` and `changed`. `read_only` is now true only for a conversation without a Lab.

### Cost and budgets

Costs are the CLI's **API-equivalent estimates**, not what a subscription is charged. The CLI reports `total_cost_usd` as the **running total of the session** (seen in the P0 experiments), so the cost of a turn is the difference between two consecutive totals; tokens are per call. A conversation shows both: per turn `cost_usd` (incremental) and `cli_total_cost_usd` (cumulative as reported), and `usage.cost_usd` for the conversation (sum of the increments). A turn that reports no usage (timeout, crash) counts as 0 and is listed in `usage.unmetered_turns`.

| Setting | Default | Effect |
|---|---|---|
| `AI_BUILDER_CONVERSATION_BUDGET_USD` | `10` | budget of each conversation, fixed when it is created. At 80% the panel warns; at 100% sending is refused (409) |
| `AI_BUILDER_MAX_BUDGET_USD` | `3` | per call, as for generation; a call is also capped at what is left of the conversation budget |
| `AI_BUILDER_TIMEOUT` | `900` | seconds per call |
| `AI_BUILDER_CONTEXT_WARN` | `150000` | context size (tokens) above which the conversation is flagged "large" |

**Context growth** is tracked per turn (`context.last_tokens` ≈ input + cache read + cache creation tokens per request, averaged over the call; `peak_tokens`; the model's `window`; `sessions` = number of Claude sessions used), so a later release can rotate or summarize a long session. Today a long conversation only gets a warning, and a resume re-reads the whole session (the P0.2 run showed a large resume costing about $2.5).

### API

| Request | Answer |
|---|---|
| `POST /conversations` `{"title"?, "lab"?}` | 201, the conversation (`lab` must be an existing use case, otherwise 404) |
| `GET /conversations` | `{"conversations": [id, title, lab, status, turns, cost_usd, budget_state, …]}`, newest first (at most 100) |
| `GET /conversations/<id>` | `messages` (user, assistant, status, error, model, usage, `cost_usd`, `cli_total_cost_usd`, seconds), `pending`, `usage`, `budget`, `context`, `limits`, `read_only`, `cost_basis` |
| `POST /conversations/<id>/messages` `{"message"}` | 202 and the conversation with `pending`; poll `GET /conversations/<id>` until `status` is `idle`. 400 for an empty message or one over 4000 characters, 404 unknown, 409 busy, full, over budget or sign-in in progress, 503 no CLI |
| `DELETE /conversations/<id>` | `{deleted, workspace_removed, sessions_removed, warnings}` (SPEC-025). 404 unknown or malformed id, 409 while Claude is answering in it. Removes the record, the Claude Code session files the record lists (`projects/*/<uuid>.jsonl`, `projects/*/<uuid>/`, `session-env/<uuid>/`, exact names, UUIDs only) and `.ai-builder/workspaces/<id>/`; never a published Lab, a draft, another conversation or a shared directory; symbolic links are unlinked, never followed. Needs the token (and, through the Playground, the CSRF header) |

The same four routes exist under `/api/ai-builder/conversations…` in the Playground (same CSRF header on POST, same fixed upstream and token handling). The conversation id (`c-YYYYMMDD-HHMMSS-xxxxxx`) is validated before it is used in a path.

## Deleting files and whole Labs (SPEC-026)

- **A file of a Lab** is an ordinary edit: ask in the conversation ("remove scenarios 03 and 04"), approve with *Allow changes*. During that one approved message Claude has a `delete_file` tool (MCP server `ai-builder/labfs_mcp.py`) that removes one file of an approved working copy; `usecase.yaml`, directories and symlinks are refused. The review lists deleted files as *deleted*, Undo and Reset bring them back, and publishing replaces the Lab with the validated tree. A running environment is not changed by a publication: stop and start the Lab to use the new version.
- **A whole Lab**: ask to delete it ("delete the clickhouse-operator Lab"). Claude only creates a request. The Playground checks that the Lab is **stopped** (Docker, fail closed); if it is not, the conversation says so, you stop it from the Playground and tell Claude, and the check runs again. A card then asks you to type the exact Lab name. The Lab is moved, not erased, to `usecases/.trash/<lab>-<UTC time>-<token>/`; the conversation's working copy is kept until the conversation is deleted.
- **Restore a deleted Lab** (host, from the repository root): `mv usecases/.trash/<lab>-<time>-<token> usecases/<lab>` (the `.json` file next to each trash entry repeats the command). The trash is git-ignored, not discovered as a Lab and never purged: remove old entries by hand.

## API

Container mode requires the token:

```bash
TOKEN="$(cat .ai-builder-token)"      # host mode: no Authorization header
curl -s -X POST 127.0.0.1:8099/generate -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d '{
  "name": "cnpg-readonly-demo2",
  "description": "Demonstrate read-only queries on CNPG replicas",
  "reference_usecase": "cnpg-standard"}'
# {"job_id": "20261116-234338-6ff6e0", "status": "running"}
curl -s -H "Authorization: Bearer $TOKEN" 127.0.0.1:8099/status/<job_id>
```

| Request | Rules |
|---|---|
| `name` | 3-40 chars, lowercase letters, digits, single hyphens, starts with a letter; must not be an existing use case (also in the publish directory) or a non-failed draft (409) |
| `description` | 10-2000 chars, no control characters |
| `reference_usecase` | optional, an existing use case (default `cnpg-standard`) |
| other fields | refused. One job at a time (409). JSON `Content-Type`, body at most 16 KB |

`/status/<job_id>` returns `status` (`pending`, `running`, `completed`, `failed`), `phase`, `files`, `validation`, `validated`, `error`, `draft` and the Claude Code attempts (exit code, duration, output tail). A validation failure, a Claude Code error or a timeout gives `failed`; the draft stays on disk.

## Review, publish, run

```bash
curl -s -H "Authorization: Bearer $TOKEN" 127.0.0.1:8099/review/<job_id>           # validation + the text of every draft file
curl -s -X POST -H "Authorization: Bearer $TOKEN" 127.0.0.1:8099/approve/<job_id>   # validated drafts only, pinned to a hash of the files
curl -s -X POST -H "Authorization: Bearer $TOKEN" 127.0.0.1:8099/publish/<job_id>   # -> usecases/<name>/
./playground usecase start <name>                                                    # Run: the existing engine, never the AI Builder
```

Publish needs a draft that is approved, **byte-identical to what was approved**, still valid, not overlapping a running job, with no existing `usecases/<name>`. The files are copied to a hidden staging directory **inside the publish directory** (same filesystem, ignored by the use case discovery), scripts are made executable, and one `rename` puts the use case in place: it is all there or not there. If anything fails the staging directory is removed and nothing is created. The builder never starts a use case or runs a scenario; read the draft before approving.

## Drafts and validation

`.ai-builder/drafts/<job-id>/<name>/` mirrors `usecases/<name>/` (`usecase.yaml`, `README.md`, `NN_*.sh`, `manifests/`). Job records are in `.ai-builder/jobs/`. The directory is git-ignored; `./playground` never deletes it.

Validation is static: `usecase.yaml` (engine's YAML subset), `bash -n` on every script, scenario names and numbering, scenario structure (shebang, `set -Eeuo pipefail`, engine libraries sourced, `main "$@"`, `ui_note`/`ui_command`/`ui_pause`), referenced manifests exist and parse, no symlinks or stray files, and **no repository file created, changed or deleted outside the draft** (SHA-256 snapshot before and after). An invalid draft goes back to Claude Code once for correction.

## Security model and limits

- Claude Code runs with `--permission-mode dontAsk`, only `Read`, `Glob`, `Grep`, `Write`, `Edit`, write and edit allowed only under the job's draft directory, and reads of the token, the login directory, `/run/secrets`, `/proc`, job records, `.env` and `.git` denied. No permission bypass.
- In the container the **kernel** now enforces most of this: the repository (including `usecases/`) is mounted read-only and holds no secrets, so only `/state` and the login volume are writable by the agent. **The agent runs with the same user and mounts as the service**, so within `/state` (drafts, conversations, working copies) the boundary is still Claude Code's permission policy: it could, if that policy failed, write into another draft or working copy there. Published Labs are out of its reach: the only writable mount of them is in the separate `ai-publisher` container (see *What is mounted*). The post-run snapshot detects changes to the repository view but does not undo them.
- Host mode keeps the weaker model of the first version (permission policy only; the whole repository is writable by the agent's user).
- The agent can read the mounted repository directories and the login volume is denied by rule, not by mount (the same user owns it). Anything the agent reads is sent to Anthropic: that is how the feature works.
- The description is passed as quoted data; prompt injection cannot be ruled out, hence the restricted tools.
- Edits you make in `usecases/` or the mounted directories while a job runs are reported as violations.
- **Never run against the real CLI yet:** the Claude Code flags, the permission rule syntax, `--add-dir` for `/state` and the browser sign-in flow in a container are unverified. The first Docker validation (below) is the test.

## Tests

`tests/ai-builder.sh`: request validation, duplicates, job lifecycle, correction attempt, timeout, Bash/YAML validation, path traversal, token and host checks, separate publish directory and staging cleanup, host-mode CLI lifecycle on a free port and a temporary state, and the rendered Compose model (`docker compose config`: no socket, non-root, read-only mounts, loopback-only port, no credentials in the environment). `tests/ai_builder_proxy_test.py` (same wrapper) covers the proxy against a fake upstream server. `tests/ui.sh` runs `tests/ai_builder_ui_test.js` (Node): the panel script against a fake DOM and a scripted fetch. `tests/cli.sh` covers the container commands with a fake docker. No test starts a container, runs Claude Code, Kind, Kubernetes, Helm or a scenario, and none touches the real `.ai-builder/`.

## First Docker validation (manual, in this order)

```bash
docker compose --profile ai-builder config -q            # the Compose model is valid
./playground ai-builder host status                       # host mode must not be running (stop it first if it is)
./playground ai-builder start                             # builds the image (pins Claude Code 2.1.326), starts the container
./playground ai-builder status
./playground ai-builder login                             # open the URL, paste the code
docker exec cnpg-ai-builder claude --version              # 2.1.326
docker exec cnpg-ai-builder sh -c 'touch /workspace/x'    # must FAIL: read-only
docker exec cnpg-ai-builder sh -c 'ls /workspace /workspace/.env' # no .env, no .git
docker exec cnpg-ai-builder id                            # uid 1000
# then one real generation (curl above), /review, /approve, /publish on a throwaway name, and check ./usecases/<name>
```

## Playground API proxy (`/api/ai-builder/*`)

The Playground backend (`web/ai_builder_proxy.py`, routes in `web/app.py`) forwards six operations to `http://ai-builder:8099` (`AI_BUILDER_URL`) on the Compose network. The browser talks only to the Playground (`127.0.0.1:8080`); the token never leaves the server.

| Playground route | AI Builder route | Notes |
|---|---|---|
| `GET /api/ai-builder/health` | `GET /health` | **Always 200**: `{"available": true/false, "state": ready, not_signed_in, claude_missing, stopped, not_configured, timeout, error, ...}` plus `version`, `busy`, `claude_credentials_present` when available |
| `POST /api/ai-builder/generate` | `POST /generate` | JSON object, at most 16 KB |
| `GET /api/ai-builder/status/<job_id>` | `GET /status/<job_id>` | |
| `GET /api/ai-builder/review/<job_id>` | `GET /review/<job_id>` | |
| `POST /api/ai-builder/approve/<job_id>` | `POST /approve/<job_id>` | |
| `POST /api/ai-builder/publish/<job_id>` | `POST /publish/<job_id>` | |

- **Token:** read for each request from `/workspace/.ai-builder-token` (the repository bind mount; `AI_BUILDER_TOKEN_FILE` overrides it). The file is created by `./playground ai-builder start`, so no Compose change and no restart are needed after that. It is never returned, logged or put in an error.
- **Destination:** fixed. A request only picks one of the six operations; the job id must match `YYYYMMDD-HHMMSS-xxxxxx` and the path is built from a template. No header, cookie or query string of the browser request is forwarded.
- **Errors:** upstream statuses and messages (`error`, `details`) are returned unchanged (400, 404, 409, 500...). Added by the proxy: **503** `state: stopped` (AI Builder not running, with the start command), **503** `state: not_configured` (no token file yet), **504** timeout, **502** for an invalid or oversized upstream answer and when the AI Builder rejects the token (a server-side problem the browser cannot fix).
- **Limits:** connect 3 s; read 5 s (health), 10 s (status), 15 s (review), 30 s (generate, approve), 60 s (publish); request body 16 KB; response 1 MB.
- **Local access model:** same as the rest of the API (published on the host loopback only), plus two cheap protections for the new routes: the `Host` must be `localhost`, `127.0.0.1` or `[::1]` (more via `AI_BUILDER_PROXY_ALLOWED_HOSTS`), and every `POST` needs `X-Requested-With: playground`, which a web page of another site cannot send without a CORS preflight that this API never grants. A future UI must send that header.
- **Loading it:** `web/app.py` is read when uvicorn starts, so the running Playground container needs a restart (`./playground restart`, which closes open terminals) to expose these routes.

Examples (from the host):

```bash
curl -s 127.0.0.1:8080/api/ai-builder/health
curl -s -X POST 127.0.0.1:8080/api/ai-builder/generate -H 'X-Requested-With: playground' -H 'Content-Type: application/json' \
  -d '{"name":"my-demo","description":"Demonstrate something useful"}'
curl -s 127.0.0.1:8080/api/ai-builder/status/<job_id>
```

## Browser sign-in

**What the installed CLI supports (Claude Code 2.1.x, inspected from `--help` and the binary; no login was ever started to find out).** `claude auth login [--claudeai | --console | --sso] [--email E]` is an interactive terminal screen. It prints an official sign-in address and the prompt `Paste code here if prompted >`; after the user signs in with their browser, the web page shows a code, which is pasted back; the screen then says `Login successful`. The CLI has its own OAuth client with an automatic callback on a local port (not reachable from the user's browser when Claude runs in a container) and this manual code path. `claude auth status --json` (field `loggedIn`) and `claude auth logout` are non-interactive. There is no device flow, no token-exchange command and no way to pass the code as an argument. So the AI Builder drives that one screen through a PTY. It is not a terminal for the browser, and it is not an OAuth client of ours. Claude Code's long-lived `setup-token` flow also exists but is not used here.

**Backend (`ai-builder/auth.py`, only in the container).** One session at a time, separate from generation jobs (a sign-in is refused while a job runs and the other way round). It starts exactly `claude auth login` with a method flag from a fixed list and an optional validated `--email` (separate argv elements, no shell), scans the output for the first `https://` address on `claude.ai`, `claude.com` or `anthropic.com`, then waits for the code.

| AI Builder route | Purpose |
|---|---|
| `GET /auth/status` | `{logged_in, expires_at, enabled, session}`; `session` = `state` (`starting`, `awaiting_browser`, `verifying`, `succeeded`, `failed`, `cancelled`), `method`, `url` (while active), `awaiting_code`, `seconds_left`, a fixed `error` |
| `POST /auth/login` | `{method?: claudeai|sso|console, email?}` starts the session (409 if one runs or a job runs) |
| `POST /auth/code` | `{code}`: the authorization code, validated (no address, no spaces), written once to the screen |
| `POST /auth/cancel`, `/auth/logout` | stop the session; sign out (refused while a sign-in or a job runs) |

The same routes exist under `/api/ai-builder/auth/{status,login,code,cancel,logout}` in the Playground (same proxy rules: fixed destination, token on the server, `X-Requested-With: playground` on every POST, 16 KB body limit). The proxy also passes **only allow-listed fields** of an answer to the browser and replaces the submitted code with `[redacted]` if an answer ever contained it.

Success is never taken from the screen alone: after `Login successful` (or the screen exiting) the backend asks `claude auth status` and only then reports `succeeded`. Timeouts: 10 minutes for the whole sign-in (`AI_BUILDER_LOGIN_TIMEOUT`), 45 s to get an address, 90 s to verify a code. A wrong code, a timeout, an early exit and a "success" without a stored login are `failed` with a fixed message; cancelling or any end kills the login process group and reaps it.

**Host mode is excluded.** Without `CLAUDE_CONFIG_DIR` (set only in the container image) `/auth/*` answers 403 and starts nothing, because `claude auth logout` would sign the developer out of their own terminal. (`AI_BUILDER_ALLOW_HOST_AUTH=1` overrides it.)

**Secrets.** The authorization code is validated, written to the PTY and forgotten: it is not stored on the session, in a job file, in an exception, in a response or in any log (the access log prints the request line only; the proxy and uvicorn log no bodies; the panel never logs). The raw terminal output (which may echo the code or the account e-mail) is not stored or returned: a short in-memory window is scanned and cleared whenever the session ends. Stored credentials are never read by the AI Builder. The code input is a password field, is cleared before the request is sent, and the panel keeps the code nowhere (no variable, no `localStorage`). Answers carry booleans, states, the official address and fixed messages only.

**Panel flow.** Connect to Claude → choose the method (Claude subscription, SSO, Anthropic Console) and optionally an e-mail → Start sign-in → open the official link (also "Copy link") and sign in → copy the code the last page shows → paste it and Submit → the panel polls, shows *Connected to Claude*, refreshes the status and enables generation. Cancel, wrong code, timeout and expiry are handled in place; a generation job that failed on authentication points back to Connect.

**Limits.** The exact screen of the real CLI was never driven (it needs a real login): the phrases it is matched on (`Paste code here`, `Login successful`, `Invalid authorization code`), the `auth status` fields and the way the screen accepts a pasted line are taken from the binary's strings and may differ. If the CLI changes them, the sign-in fails closed (a fixed message) and `./playground ai-builder login` remains the fallback. The corporate (SSO) flow runs entirely in Claude's own pages: if it needs something a container browser flow cannot give (device checks, a callback to the same machine), it fails there and is not worked around. The sign-in address is shown to the user and opened by them; the container never opens a browser. The panel cannot tell a revoked token from an expired one before a status check (checked at most every 25 s while the panel is open).

## Web UI panel

The **✦ AI Assistant** button in the header opens the AI Lab Assistant, a panel docked on the right of the Playground (see *The AI Lab Assistant panel* below). The code is `web/static/ai-builder.js` (the panel), `web/static/ai-markdown.js` (Markdown and syntax highlighting), the markup is in `index.html` and the styles in `web/static/ai-builder.css` (its own file; every selector is scoped under `#aib`, apart from the panel's own layout hooks). It uses only `/api/ai-builder/*` of the Playground (never port 8099, never a token) and builds the page with `textContent`, never HTML strings. Static files are served from the bind mount: reload the page. If the panel ever looks like an unstyled form, the browser is using an older cached `style.css`/`ai-builder.css`: do a hard reload (Cmd+Shift+R). The API routes need the Playground restart noted above.

1. **Availability.** A badge shows *Ready · Claude signed in*, *Claude not signed in*, *Not running* or *Unreachable*, rechecked every 10 s while the panel is open. When the AI Builder is stopped or not set up, the banner gives `./playground ai-builder start`. When Claude is not signed in (or the stored login is no longer valid) the panel offers **Connect to Claude**; a signed-in container offers **Disconnect**. Generation is disabled in those cases and while a sign-in runs.
2. **Form.** Name (same rules as the server, and not an existing use case), description (10-2000 characters), optional reference use case (from the use case list). Invalid input is refused before any request.
3. **Progress.** Generate → Validate → Review → Publish, the current phase (including the single automatic correction), elapsed time, validation errors, the error message and, on failure, the tail of Claude Code's output. The job id is kept in the browser's `localStorage` (not a secret), so a page reload resumes the job.
4. **Review.** A file selector (`usecase.yaml`, `README.md`, scenarios in order, manifests) and a read-only source preview with line numbers. A draft that failed validation can be inspected but has no approval controls.
5. **Approval and publication.** The user must tick *I reviewed the generated files and approve publishing...*; one click then calls `approve` and `publish` (publish only, if the draft was already approved). Buttons are locked while a call is in flight, a second click or a second submission sends nothing, and if a publish request times out the panel asks the server for the true state instead of guessing. On success the Playground use case list and tabs are refreshed and the panel shows `./playground usecase start <name>`.

Every POST carries `X-Requested-With: playground`.

### The AI Lab Assistant panel (SPEC-024)

A docked, resizable panel replaces the former modal. Nothing changed in the backend or in the API.

- **Layout.** The panel is a third column of `<main>` (after the sidebar and the terminals). Opening it shrinks the terminal column instead of covering it; closing gives the room back. Only the CSS variable `--aib-w` changes: the terminal iframes are resized in place and ttyd refits itself, exactly as for the sidebar toggle and the split separators. The panel adds no resize logic for the terminals; its single window `resize` listener only keeps the panel's own width within limits. On a window narrower than 800 px the panel is a full-screen overlay (the workspace is not resized).
- **Open and close.** The header button **✦ AI Assistant** toggles it (`aria-expanded`), the **✕** button closes it, and the focus goes to the composer on open and back to the header button on close. Polling stops while it is closed; a reply that is still being written is followed again when you reopen it.
- **Width.** Drag the divider (or focus it and use ←/→, Shift for bigger steps, Home/End, double-click to reset). 320 px to 720 px, always leaving 280 px to the terminals. The width is kept in `localStorage` (`aibPanelWidth`, default 440 px). While you drag, the terminals ignore the pointer so they cannot swallow it.
- **Assistant (the main view).** A conversation selector, **＋ New** (a compact row: choose a Lab or none) and a discreet trash button that deletes the open conversation (two clicks: the first turns it into a red "Delete?", the second deletes; disabled while Claude is answering in it; after deletion the list is updated and the panel returns to the empty state); the title, a **Lab** chip, model, message count, context size and the estimated cost against the budget (unobtrusive, with a tooltip saying it is not a charge); replies rendered as Markdown (headings, lists, tables, quotes, inline code, links limited to http(s) and mailto) with **syntax-highlighted code blocks** (bash, YAML, JSON, SQL, diff) and a **Copy** button each; your own message as plain text. Everything is built with DOM nodes and `textContent`: HTML in a reply is shown as text, never run. The composer is sticky at the bottom, grows with its text, **Enter sends** and **Shift+Enter** adds a line (an IME composition never sends). Smart scrolling: the list follows the conversation while you are at the bottom, keeps your position when you scrolled up and then offers **↓ New messages**.
- **What the status line says.** *Ready · waiting for your message*; *Claude is thinking · 00:12…* (the time since the conversation's real `pending.started`); *Claude is working on your request (editing is enabled for this message)* when the backend marked the running message as editable; *Sending…*; *Validating the changes and preparing the review…*; *Undoing…*, *Resetting…*, *Starting over…*; *Publishing to usecases/<lab>…*; the last failed reply's error; *Claude is not available right now*. Each comes from a request in flight or from a field the backend returns; there are no progress percentages and no guessed sub-steps ("analyzing", "reading the Lab" and so on are never shown because nothing reports them). The indicator animates (not with `prefers-reduced-motion`) and `aria-busy` follows it.
- **Changes.** A compact bar above the composer ("2 files changed in the working copy … · not published") with **Review changes** / **Hide changes**, **Undo**, **Reset** (two clicks) and, when the published Lab changed, **Start over from the published Lab** (two clicks). The review opens above the composer without hiding the conversation: validation state, a collapsible list of changed files, a diff viewer (added/removed lines colored, content highlighted by the file's language), the approval checkbox and **Publish**, which stays off until validation passes, there is no conflict and the approval is ticked. Undo, Reset, Start over and Publish report their result in a line under the conversation.
- **Generate a new Lab** is the second tab; the form, progress, review and publish steps are unchanged.
- **Themes and accessibility.** Colors come from the Playground's tokens; the code and diff colors have light and dark values. Real landmarks and roles (`aside`, tabs, a labelled `separator`, `log`, `status`), visible focus rings, names on every control, no animation of the width.

Checks: `tests/ui.sh` (Node and a fake DOM: logic, Markdown, highlighting, layout rules, flows) and `tests/ui-browser.sh` (the real page in headless Chrome: docked layout, workspace resized and not covered, terminal viewport following, drag, limits, persistence, scrolling, sticky composer, Markdown and diff rendering, narrow full-screen, light and dark). The second one is skipped when Chrome is not installed.

### Manual validation (a browser is required: these are not covered by the automated tests)

1. Reload the Playground page; the header shows **✦ AI Assistant**; the use case list, terminals and theme toggle still work.
2. With the AI Builder stopped: open the panel; badge *Not running*, banner with the start command, *Generate draft* disabled.
3. `./playground ai-builder start` (not signed in): badge *Claude not signed in* and a **Connect to Claude** button; after signing in (step 8, or `./playground ai-builder login`): *Ready · Claude signed in* within 10 s.
4. Try an invalid name and a short description; try an existing use case name: inline errors, no request.
5. Generate a draft: steps advance, elapsed time runs, a double click on *Generate draft* creates one job. Close and reopen the panel, then reload the page: the job resumes.
6. When done, browse each file; the preview shows line numbers and no HTML is interpreted. Check light and dark themes and a narrow window.
7. Publish without ticking the box (button disabled), then with it: one *Published as usecases/...* message, the use case appears in the sidebar without a reload, a second click does nothing. Stop the AI Builder during a poll: the panel says it cannot be reached and recovers when it returns.

### Manual validation of the browser sign-in (a real account and browser are required; none of this is covered by the automated tests)

8. In the panel select **Connect to Claude**, keep *Claude subscription* (or choose SSO and enter your e-mail), **Start sign-in**. Within a few seconds the *Open the Claude sign-in page* link and the code field appear; if not, the failure message says why (and `docker logs cnpg-ai-builder` has nothing about codes).
9. Open the link, sign in, copy the code from the last page, paste it, **Submit code**: the panel shows *Connected to Claude*, the badge turns *Ready · Claude signed in*, **Disconnect** appears.
10. `docker exec cnpg-ai-builder claude auth status` reports a login; `./playground ai-builder stop && ./playground ai-builder start`: still signed in.
11. Try a wrong code (expect the fixed *did not accept* message and *Try again*), **Cancel sign-in** during a session, and a second *Start* in another tab (expect "already in progress").
12. **Disconnect** (two clicks) → *not signed in*; reconnect. `grep -c` your code in `docker logs cnpg-ai-builder` and `docker logs cnpg-playground`: must be 0.
13. If the sign-in screen of your Claude Code version differs (no address, code never accepted), note what the panel reports: the fallback is `./playground ai-builder login`.

### Manual validation of conversations (real Claude calls and a browser are required; none of this is covered by the automated tests)

Run after rebuilding and restarting the AI Builder (`./playground ai-builder stop && ./playground ai-builder start`) and restarting the Playground container for the new proxy routes (`./playground restart` closes terminals), then hard-reload the page. Expect a few cents per message.

14. Open **✦ AI Assistant → ＋ New**, pick a Lab, **Start**. Ask "Which scenarios does this Lab have?" The panel shows *Claude is reading and answering…*, then the reply with model, tokens and `est.` cost, and the budget bar moves.
15. Ask a follow-up that needs the first answer ("Explain the second one"): the reply must be coherent (the session is resumed). `docker exec cnpg-ai-builder sh -c 'ls -l /home/builder/.claude/projects/*/'` lists one `<uuid>.jsonl` (do not print its content).
16. Reload the page, reopen the panel: the conversation is listed and reopens with all messages. Then `./playground ai-builder stop && ./playground ai-builder start`, reopen it and send another message: it must still remember the earlier ones.
17. Ask it to "edit the README of this Lab": it must explain but change nothing (`git status` / the Lab files unchanged; `.ai-builder/drafts/` unchanged). Ask for a web search: it cannot.
18. Check the costs: per message `cost_usd` should be the difference of consecutive `cli_total_cost_usd` (`GET /conversations/<id>` on the AI Builder with the token). If the totals turn out to be per call instead of cumulative, tell us: the accounting assumes cumulative.
19. Lower the budget (`AI_BUILDER_CONVERSATION_BUDGET_USD=0.3 ./playground ai-builder start`), new conversation, send messages: the 80% warning shows, then at 100% sending is refused with a clear message.
20. Send from two browser tabs at once to the same conversation: one gets *still answering*. Start a generation in the other tab at the same time: both work.
21. Check `--strict-mcp-config` removed the connector tools: the first message of a new conversation should report far fewer input and cache tokens than the ~97k seen in P0.1 (this flag was not part of the P0 experiments).

### Manual validation of Lab editing (real Claude calls, a browser and the rebuilt containers are required; none of this is covered by the automated tests)

Run after `./playground ai-builder stop && ./playground ai-builder start` (builds the image and starts **both** `cnpg-ai-builder` and `cnpg-ai-publisher`) and `./playground restart` for the proxy routes. Use a throwaway copy of a Lab (for example `cp -R usecases/cnpg-standard usecases/edit-test`), not a Lab you care about.

22. `docker ps` lists `cnpg-ai-builder` and `cnpg-ai-publisher`. Prove the OS boundary: `docker exec cnpg-ai-builder sh -c 'touch /workspace/usecases/edit-test/x'` must fail ("Read-only file system"), and `docker exec cnpg-ai-publisher sh -c 'touch /state/x'` must fail too; `docker inspect cnpg-ai-builder --format '{{json .Mounts}}'` has no writable `usecases` mount.
23. **Conversations → New conversation → Lab `edit-test`**. Ask a question ("what does scenario 01 do?"): no pending-changes bar, and `ls .ai-builder/workspaces` has no directory for it. Then ask "Add a short section about failover to the README": the bar appears ("1 file changed … not published"), `usecases/edit-test/README.md` is unchanged, and `.ai-builder/workspaces/<id>/work/README.md` has the change.
24. **Review changes**: the file list, a readable diff and "Validation passed". **Undo**: the bar disappears and the working copy equals the Lab. Ask again; **Reset** (two clicks): same.
25. Ask for a change that breaks the Lab ("delete usecase.yaml"): the review says validation failed and Publish stays off. **Undo**.
26. Make a good change, review, tick the approval, **Publish**: `usecases/edit-test/` has the change, no `.staging-*` or `.old-*` entries remain in `usecases/`, and the new content shows in the sidebar Lab after refresh. Ask for another change and publish again.
27. Conflict: make a change, then edit `usecases/edit-test/README.md` by hand, then Review: the conflict banner shows and Publish is disabled. **Start over from the published Lab**, ask again, publish.
28. Reload the page and restart `./playground ai-builder stop && ./playground ai-builder start` with a pending change: reopening the conversation shows the same pending changes, Undo still works, and the next message still remembers the earlier dialogue.
29. `docker stop cnpg-ai-publisher`, then Publish: a clear "publisher is not reachable" message and nothing published; `docker start cnpg-ai-publisher` and retry.
30. Check that Claude really stayed inside its working copy while editing (`git status`/`ls usecases/` unchanged except for what you published), that a plain question never grants Write/Edit (`docker logs` do not show tool details; check the answer says it cannot edit), and the unverified assumptions in SPEC-023.

### Manual validation of the redesigned panel (a real browser and the real stack are required; `tests/ui-browser.sh` covers the layout with stubs)

Reload the page with a hard reload (Cmd+Shift+R): the static files come from the bind mount, and an old cached `style.css`/`ai-builder.css` gives a broken layout.

31. Open a use case terminal, then **✦ AI Assistant**: the terminal shrinks and keeps working (type in it; run something that fills the screen, such as `ls -l /usr/bin`). Drag the divider: the terminal's Bash line wraps to the new width (ttyd refits) and nothing reconnects. Collapse the sidebar (☰) with the panel open, split a terminal, switch tabs: everything still works.
32. Reload the page and reopen the panel: the width you left is restored. Resize the browser window below 800 px: the panel becomes full screen; widen it again: the docked layout returns.
33. Start a conversation about a Lab and ask for a script: the reply shows Markdown, a highlighted code block and a **Copy** button that puts exactly the code on the clipboard. While Claude works the status line says *Claude is thinking · mm:ss…*, the composer is locked, and the page stays usable; a screen reader announces the state changes.
34. Scroll up in a long conversation while a reply arrives: your position is kept and **↓ New messages** appears. Press **Enter** to send, **Shift+Enter** for a new line; type a long message and watch the box grow up to its limit.
35. Ask for a change, **Review changes**: the conversation stays visible above, the diff is colored, Publish is off until you tick the approval; with a failing validation it stays off. Try Undo, Reset, and a conflict (edit the published Lab by hand).
36. Switch between light and dark (☾): panel, code blocks and diffs stay readable. Tab through the panel with the keyboard only: the order is header, tabs, conversation list, messages, changes, composer; the divider can be focused and moved with the arrow keys.
37. **Generate a new Lab** (second tab): generate, review, publish a throwaway use case as before.
