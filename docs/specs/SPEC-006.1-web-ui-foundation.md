# SPEC-006.1 — Minimal Web UI Foundation

| | |
|---|---|
| Status | Implemented |
| Document type | Original specification, preserved verbatim |
| Source | Claude Code session transcript (project history), user message 2026-11-04T22:14:56.571Z UTC |
| Original specification | Available (see the last section) |

## Summary

A FastAPI + plain HTML/CSS/JavaScript page that embeds the existing ttyd terminal, with a dark layout.

## Implemented behavior

- `http://127.0.0.1:8080/` serves a page with a header (connection indicator), a sidebar, the terminal (ttyd embedded as an iframe) and footer areas.
- The raw ttyd terminal stays on `127.0.0.1:7681`.
- The connection indicator polls ttyd and shows its availability.

## Implementation

- `web/app.py` (FastAPI, static files), `web/static/index.html`, `style.css`, `app.js`.
- `Dockerfile`: `python3-fastapi`, `python3-uvicorn`; `EXPOSE 8080`.
- `compose.yaml`: port `127.0.0.1:8080:8080`.
- `engine/entrypoint.sh`: starts uvicorn in the background after joining the `kind` network and before `exec`-ing ttyd.

## Later corrections and follow-ups

Header, status bar and sidebar were extended by every later specification. The look was changed by SPEC-006.8.1.

## Verification

Tested by the implementer at API, WebSocket-protocol and fake-DOM level (scripts kept outside the repository). No real browser was available to the implementer; the project owner reported manual validation of the features as a whole (SPEC-006.9, context section), but the individual manual checks are not recorded.

## Known limitations

- The page cannot see the state of the ttyd WebSocket (cross-origin iframe).
- The Web UI and ttyd are unauthenticated and bound to `127.0.0.1` only.

## Original specification (verbatim)

~~~~~text
SPEC-006.1 — Minimal Web UI Foundation

Context

We have a working CNPG Operator Playground running inside Docker Compose.

The current architecture includes:

* A Playground container with a working ttyd Web terminal.
* Bash / Make orchestration.
* Kind clusters managed through the Docker socket.
* CNPG operators, Prometheus/Grafana and MinIO.
* Multiple independently managed use cases.

Both existing use cases (single-cnpg and multi-cluster-dr) have been successfully tested from scratch.

We now want to progressively improve the user interface, inspired by killer.sh.

This specification is the first incremental step. Keep it extremely simple.

Objective

Create a minimal Web UI that embeds the existing ttyd terminal.

The terminal must remain the central component of the application.

Do not change the existing Kubernetes or use case lifecycle architecture.

1. Technology

Preferred stack:

* Python FastAPI for serving the Web UI.
* Plain HTML, CSS and vanilla JavaScript.
* Existing ttyd terminal.
* Existing Docker Compose Playground container.

No React, Vue, Node.js, database or additional containers.

If an even simpler approach is possible without compromising future extensibility, explain it before implementation.

2. User Interface

Create a dark interface with the following layout:

┌──────────────────────────────────────────────────────────────┐
│ CNPG Operator Playground                        ● Connected  │
├──────────────────┬───────────────────────────────────────────┤
│                  │                                           │
│ USE CASES        │                                           │
│                  │                                           │
│ Coming soon      │              ttyd terminal                │
│                  │                                           │
│                  │                                           │
│                  │                                           │
│                  │                                           │
├──────────────────┴───────────────────────────────────────────┤
│ Docker resources: Coming soon                                │
├──────────────────────────────────────────────────────────────┤
│ Cluster: — │ Grafana: — │ MinIO: — │ Context: —               │
└──────────────────────────────────────────────────────────────┘

Requirements

* Dark theme inspired by modern terminal environments.
* Terminal occupies approximately 75–80% of the available width.
* Sidebar width approximately 220px.
* Header with application name.
* Terminal connection indicator.
* Placeholder sidebar.
* Placeholder Docker resources bar.
* Placeholder bottom status bar.
* Responsive layout.
* No unnecessary animations or UI frameworks.

3. ttyd Integration

Reuse the existing ttyd installation.

Requirements:

* Preserve the existing interactive Bash environment.
* Preserve colors, autocomplete and command history.
* Preserve terminal resizing.
* Preserve interactive commands, including less, watch and Bash prompts.
* Preserve Ctrl+C handling.
* Preserve the Docker network initialization fix that prevents ttyd WebSocket disconnections.
* Avoid introducing unnecessary reverse proxies.

Investigate the simplest reliable integration method.

If using an iframe, verify that ttyd permits embedding and that WebSocket connections work correctly.

Ensure terminal resizing works when the browser window changes size.

4. Docker Compose

Keep a single Playground container.

Expose the new Web UI through a dedicated HTTP port.

Keep the existing ttyd port available during migration for debugging.

The application must start automatically with Docker Compose.

Avoid rebuilding or modifying the existing Kubernetes infrastructure.

5. Project Structure

Suggested structure:

web/
├── app.py
└── static/
    ├── index.html
    ├── app.js
    └── style.css

Adapt to existing project conventions if necessary.

6. Strict Scope

Do NOT implement yet:

* Dynamic use case discovery.
* Start / Stop buttons.
* Multiple terminal sessions.
* tmux.
* Scenario management.
* Docker resource monitoring.
* Grafana / MinIO dynamic links.
* Kubernetes context management.
* Additional API endpoints beyond those required to serve the UI.

Do not modify the existing use case scripts or Kubernetes provisioning logic.

Do not modify the reference project ../cnpg-operator-playground-local.

7. Validation

After implementation:

1. Start the Playground using the existing Docker Compose workflow.
2. Open the new Web UI.
3. Verify that the existing ttyd terminal is fully functional.
4. Execute:

pwd
make help
kubectl version --client
docker ps

5. Verify terminal resizing.
6. Verify interactive shell behavior.
7. Verify that the existing ttyd URL still works.
8. Verify that no Kind clusters have been created, deleted or modified.

Expected Deliverables

* Minimal working Web UI.
* Existing ttyd terminal embedded.
* Docker Compose integration.
* Short summary of modified files.
* Exact URL to access the interface.
* Validation results.

Important: Implement SPEC-006.1 only. Do not proceed to subsequent specifications without approval.
~~~~~
