# SPEC-006.5 — Dynamic Status Bar

| | |
|---|---|
| Status | Implemented |
| Document type | Original specification, preserved verbatim |
| Source | Claude Code session transcript (project history), user message 2026-11-05T09:33:51.677Z UTC |
| Original specification | Available (see the last section) |

## Summary

The bottom bar shows the selected terminal's use case, state, actual Kubernetes context, Kind clusters and Grafana/MinIO links.

## Implemented behavior

- `GET /api/status?terminal=<id>` is read-only: it never creates or writes to a tmux session.
- The context is what the terminal resolves (its own kubeconfig file, then the shared current context), reported as `ok`, `unavailable`, `none` or `no-session`; it is never inferred from the use case name.
- Clusters come from `engine/usecase-clusters.sh` (`usecase_clusters` + `host_port`); a Grafana or MinIO Console link is returned only if the node port accepts a TCP connection. Results are cached 5 s. URLs use the host name the page was opened with.
- The page renders with `textContent` only, links use `target="_blank" rel="noopener noreferrer"`, and the bar refreshes with the tab and every 3 s.

## Implementation

- `web/app.py` (`status`, `_terminal_context`, `_usecase_clusters`), `engine/usecase-clusters.sh`, `web/static/app.js`, `style.css`.

## Later corrections and follow-ups

Playground handling of missing contexts: SPEC-006.7.1-FIX. Empty `current-context` handling: SPEC-006.9.

## Verification

Tested by the implementer at API, WebSocket-protocol and fake-DOM level (scripts kept outside the repository). No real browser was available to the implementer; the project owner reported manual validation of the features as a whole (SPEC-006.9, context section), but the individual manual checks are not recorded.

## Known limitations

- The fixed NodePorts (30082, 30084) are duplicated in `web/app.py` and `engine/usecase-clusters.sh` (documented, not shared).
- Up to about 8 s lag after a cluster change (polling plus cache).

## Original specification (verbatim)

~~~~~text
SPEC-006.5 — Dynamic Status Bar

1. Context

The CNPG Operator Playground currently provides:

* One Docker Compose Playground container.
* Kind clusters managed through Make/Bash.
* FastAPI backend.
* Vanilla JavaScript frontend.
* ttyd + tmux persistent terminal sessions.
* One terminal per running use case.
* A permanent Playground terminal.
* Dynamic sidebar discovery.
* Start/Stop controls.
* Colored Operation logs.
* Independent Kubernetes contexts for each terminal.

The following specifications are implemented and validated:

* SPEC-006.4 — Multi-Terminal Workspace
* SPEC-006.4.1 — Terminal Tabs Lifecycle
* SPEC-006.4.2 — Kubernetes Context Initialization & Isolation

The Web UI already contains a placeholder bottom status bar.

We now want to populate it with useful runtime information.

2. Objective

Implement a dynamic bottom status bar displaying information about the currently selected terminal.

The status bar must provide:

1. Active terminal / use case.
2. Current Kubernetes context.
3. Associated Kind clusters.
4. Grafana access links.
5. MinIO Console access links.

The information must update automatically without requiring a page reload.

Keep the implementation KISS.

3. Expected UI

Example when single-cnpg is selected:

┌──────────────────────────────────────────────────────────────────────────────┐
│ single-cnpg │ Running │ kind-cnpg-lab-single-cnpg-1 │ Grafana ↗ │ MinIO ↗  │
└──────────────────────────────────────────────────────────────────────────────┘

Example when multi-cluster-dr is selected:

┌───────────────────────────────────────────────────────────────────────────────────────────┐
│ multi-cluster-dr │ Running │ Cluster 1 │ Cluster 2 │ Grafana 1 ↗ │ MinIO 1 ↗ │ Grafana 2 ↗ │ MinIO 2 ↗ │
└───────────────────────────────────────────────────────────────────────────────────────────┘

These are illustrative layouts.

Adapt the presentation to the existing dark theme.

Avoid overcrowding the status bar.

4. Active Terminal

The status bar must reflect the selected terminal tab.

Playground

Display:

* Terminal: Playground.
* Current Kubernetes context.
* No use case-specific Grafana or MinIO links.

Use case terminal

Display:

* Use case name.
* Running/Stopping status.
* Current Kubernetes context.
* Associated Kind clusters.
* Grafana and MinIO links for each cluster.

Important

Switching terminal tabs must only update the displayed information.

It must not:

* Change Kubernetes contexts.
* Restart tmux sessions.
* Reconnect terminals unnecessarily.
* Execute commands in the interactive shell.
* Modify Kubernetes resources.

5. Kubernetes Context

5.1 Current context

Display the actual Kubernetes context associated with the selected tmux session.

Examples:

kind-cnpg-lab-single-cnpg-1
kind-cnpg-lab-multi-cluster-dr-1
kind-cnpg-lab-multi-cluster-dr-2

Do not simply infer the current context from the use case name.

The user may have manually switched contexts using:

kubectl config use-context <context>

The status bar must reflect that change.

5.2 Context updates

The context must update automatically after a manual change in the terminal.

For example:

kubectl config use-context kind-cnpg-lab-multi-cluster-dr-2

The status bar should then display:

kind-cnpg-lab-multi-cluster-dr-2

No page reload should be required.

5.3 Context isolation

Preserve the existing terminal-specific kubeconfig mechanism.

Do not modify the shared kubeconfig.

Do not change the selected context when switching tabs.

5.4 Missing context

If no valid Kubernetes context is selected, display:

No context

Do not silently select another context.

6. Kind Cluster Discovery

Use the existing Kind naming and discovery helpers.

Do not hardcode cluster names.

Single-cluster use case

Display its associated Kind cluster.

Multi-cluster use case

Display every associated Kind cluster.

For example:

multi-cluster-dr
├── cnpg-lab-multi-cluster-dr-1
└── cnpg-lab-multi-cluster-dr-2

Cluster identification

Clearly distinguish:

* Kind cluster name.
* Kubernetes context name.

For example:

Cluster: cnpg-lab-multi-cluster-dr-1
Context: kind-cnpg-lab-multi-cluster-dr-1

Avoid duplicating this information unnecessarily in the UI.

Important

Cluster discovery must remain read-only.

Do not modify cluster lifecycle behavior.

7. Grafana and MinIO Links

7.1 Existing infrastructure

Each Kind cluster may expose:

* Grafana.
* MinIO S3 endpoint.
* MinIO Console.

The Playground already uses dynamically allocated host ports.

Inspect the existing implementation to determine how these ports are assigned and retrieved.

Reuse existing helpers wherever possible.

Do not introduce hardcoded port values.

7.2 Grafana

For each cluster, display a clickable Grafana link when available.

Example:

Grafana 1 ↗
Grafana 2 ↗

The link must open in a new browser tab.

7.3 MinIO

For each cluster, display a clickable MinIO Console link when available.

Example:

MinIO 1 ↗
MinIO 2 ↗

Use the MinIO Console port, not the S3 API port.

7.4 URL construction

The existing Playground UI is accessible through localhost.

However, URLs returned to the browser must be reachable from the user’s machine.

Do not blindly use container-internal hostnames or IP addresses.

Inspect the current port exposure and forwarding mechanisms.

Prefer constructing URLs using the same browser-accessible hostname as the Playground UI when appropriate.

For example:

http://127.0.0.1:<dynamic-port>

Only use this form if it is actually reachable from the browser.

7.5 Unavailable services

If Grafana or MinIO is not installed or its port cannot be resolved:

* Do not display a broken link.
* Show an unavailable indicator or omit the link.
* Do not treat this as a fatal API error.

A running Kind cluster does not necessarily mean all its services are ready.

8. Backend API

Add a minimal read-only endpoint.

Suggested:

GET /api/status?terminal=<terminal-id>

Example response:

{
  "terminal": "multi-cluster-dr",
  "usecase": "multi-cluster-dr",
  "status": "running",
  "context": "kind-cnpg-lab-multi-cluster-dr-2",
  "clusters": [
    {
      "name": "cnpg-lab-multi-cluster-dr-1",
      "context": "kind-cnpg-lab-multi-cluster-dr-1",
      "grafana_url": "http://127.0.0.1:54481",
      "minio_console_url": "http://127.0.0.1:54483"
    },
    {
      "name": "cnpg-lab-multi-cluster-dr-2",
      "context": "kind-cnpg-lab-multi-cluster-dr-2",
      "grafana_url": "http://127.0.0.1:54484",
      "minio_console_url": "http://127.0.0.1:54486"
    }
  ]
}

The URLs and ports above are examples only.

Do not hardcode them.

Backend requirements

* Read-only operations.
* Validate terminal identifiers.
* Reuse existing use case discovery.
* Reuse existing Kind helpers.
* Read the actual terminal-specific Kubernetes context.
* Resolve dynamic service ports.
* Return structured JSON.
* Handle unavailable Docker/Kubernetes services gracefully.

Do not execute commands inside active interactive terminal sessions.

Do not create tmux sessions merely to retrieve status.

Important

The API must distinguish between:

* A terminal session that exists.
* A terminal session that has not yet been created.
* A Kubernetes context that is unavailable.

Do not report an inferred default context as though it were the actual current context of an existing session.

9. Frontend

Extend the existing bottom status bar.

Requirements

* Update when the selected tab changes.
* Refresh automatically every 3 seconds.
* Avoid full-page reloads.
* Preserve terminal focus.
* Preserve existing sidebar polling.
* Preserve the Operation log panel.
* Maintain the existing dark theme.

Dynamic behavior

When switching from:

single-cnpg → multi-cluster-dr

The status bar must update:

* Use case name.
* Current Kubernetes context.
* Cluster list.
* Grafana links.
* MinIO links.

Multiple clusters

For multi-cluster use cases, present links grouped by cluster.

A compact dropdown or expandable section is acceptable if needed.

Avoid creating a large or complex UI component.

Security

External links must use safe URL handling.

Open links using:

target="_blank" rel="noopener noreferrer"

Do not inject unsanitized backend values into HTML.

10. Refresh and Performance

The existing frontend polls status approximately every 3 seconds.

Reuse this mechanism where practical.

Avoid:

* Repeated expensive Kubernetes API queries.
* Repeated Docker calls for information that can be obtained cheaply.
* Creating unnecessary subprocesses.
* Restarting terminal sessions.

Prefer existing Docker/Kind metadata for service discovery.

If needed, use a short-lived backend cache.

Do not introduce Redis or a database.

11. Validation

Test A — Playground

Select the Playground terminal.

Verify:

* Playground is displayed.
* Its actual Kubernetes context is displayed.
* No use case-specific service links appear.

Test B — Single-cluster use case

Select a running single-cluster use case.

Verify:

* Correct use case name.
* Correct Kind cluster.
* Correct Kubernetes context.
* Correct Grafana URL.
* Correct MinIO Console URL.

Open both links in a browser.

Test C — Multi-cluster use case

Select multi-cluster-dr.

Verify:

* Both Kind clusters are listed.
* Each cluster has its own Grafana link.
* Each cluster has its own MinIO Console link.
* No URLs are mixed between clusters.

Test D — Context switching

In a use case terminal:

kubectl config use-context <another-context>

Verify:

* The status bar updates automatically.
* The selected terminal remains unchanged.
* Other terminals retain their contexts.

Test E — Start/Stop lifecycle

Using a temporary test use case:

1. Start the use case.
2. Verify its terminal tab appears.
3. Verify the status bar displays its cluster.
4. Stop the use case.
5. Verify the terminal tab disappears.
6. Verify the status bar returns to Playground if necessary.

Do not destroy existing user clusters.

Test F — Unavailable services

Verify:

* Missing Grafana does not break the status bar.
* Missing MinIO does not break the status bar.
* Docker errors are handled gracefully.
* No invalid links are displayed.

Test G — Regression

Verify:

* Terminal tabs remain persistent.
* Kubernetes context isolation remains functional.
* kubectl and Helm remain consistent.
* Sidebar Start/Stop still works.
* Colored Operation logs still work.
* ttyd WebSocket connectivity remains functional.
* Existing Kind clusters remain untouched.

12. Constraints

* KISS architecture.
* No additional Docker containers.
* No new frontend framework.
* No database.
* No modifications to Kind provisioning.
* No modifications to existing use case scripts.
* No changes to terminal session lifecycle.
* No changes to Kubernetes context isolation.
* No modifications to the reference project.
* Preserve existing Docker networking behavior.

13. Deliverables

Provide:

1. Architecture decisions.
2. Modified files.
3. Backend API response example.
4. Dynamic Grafana/MinIO port discovery mechanism.
5. Kubernetes context retrieval mechanism.
6. Validation results.
7. Known limitations.

Implementation Instructions

First inspect the existing implementation.

Pay particular attention to:

* Dynamic port allocation.
* Grafana and MinIO exposure.
* Existing Kind discovery helpers.
* Terminal-specific kubeconfig files.
* tmux session lifecycle.
* Existing frontend polling.

Explain the proposed implementation briefly.

Then implement SPEC-006.5 only.

Do not implement Docker resource monitoring yet.

Do not modify unrelated components.
~~~~~
