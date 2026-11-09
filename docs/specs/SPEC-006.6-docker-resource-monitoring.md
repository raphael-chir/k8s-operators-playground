# SPEC-006.6 — Docker Resource Monitoring

| | |
|---|---|
| Status | Implemented |
| Document type | Original specification, preserved verbatim |
| Source | Claude Code session transcript (project history), user message 2026-11-05T09:48:34.908Z UTC |
| Original specification | Available (see the last section) |

## Summary

A bar with the CPU, memory, Kind node and cluster counts of the Playground, and the Docker Engine's capacity.

## Implemented behavior

- `GET /api/docker/resources` returns a cached snapshot. One collector thread (started by the first request, stopped 30 s after the last) runs every 5 s: `docker info`, `engine/managed-clusters.sh`, `docker ps -a` with Kind's cluster label, one `docker stats --no-stream` limited to the running Playground nodes.
- Only nodes of clusters named by the playground convention count as Playground resources; other containers appear only in the Engine-wide numbers. The worker count is never assumed. Clusters of removed use cases still count.
- On failure the last snapshot is kept and marked `stale`; with none, the data fields are `null`. `docker info` exits 0 with empty fields when the daemon is unreachable; that is treated as an error, never as zeros.

## Implementation

- `web/app.py` (collector), `engine/managed-clusters.sh`, `web/static/app.js`, `style.css`.

## Later corrections and follow-ups

CPU presentation changed in SPEC-006.7.1 (percentage of Engine capacity). Tooltips: SPEC-006.7.1-FIX.

## Verification

Tested by the implementer at API, WebSocket-protocol and fake-DOM level (scripts kept outside the repository). No real browser was available to the implementer; the project owner reported manual validation of the features as a whole (SPEC-006.9, context section), but the individual manual checks are not recorded.

## Known limitations

- The Playground container's own CPU/RAM is not included.
- CPU is one `docker stats` sample; values can lag up to about 9 s.

## Original specification (verbatim)

~~~~~text
SPEC-006.6 — Docker Resource Monitoring

1. Context

The CNPG Operator Playground currently provides:

* One Docker Compose Playground container.
* Multiple Kind clusters running as sibling Docker containers.
* A Bash/Makefile lifecycle engine.
* FastAPI backend.
* Vanilla HTML/CSS/JavaScript frontend.
* ttyd + tmux persistent terminal sessions.
* Dynamic use case discovery.
* Sidebar Start/Stop controls.
* Colored Operation logs.
* Independent Kubernetes contexts per terminal.
* Dynamic bottom status bar with Kind clusters, Grafana and MinIO links.

The following specifications are implemented and validated:

* SPEC-006.1 — Web UI Foundation
* SPEC-006.2 — Dynamic Use Case Discovery
* SPEC-006.3 — Start/Stop Controls
* SPEC-006.3.1 — Colored Operation Logs
* SPEC-006.4 — Multi-Terminal Workspace
* SPEC-006.4.1 — Terminal Tabs Lifecycle
* SPEC-006.4.2 — Kubernetes Context Initialization & Isolation
* SPEC-006.5 — Dynamic Status Bar

We now want to replace the existing Docker resources placeholder with actual monitoring information.

2. Objective

Implement lightweight Docker resource monitoring directly in the existing Web UI.

Display:

1. CPU consumption.
2. Memory consumption.
3. Running Docker container count.
4. Running Kind cluster count.

The monitoring must update automatically.

It must not interfere with the existing Playground operations.

Design principles

* KISS.
* Read-only monitoring.
* Reuse Docker CLI.
* No additional monitoring infrastructure.
* No Prometheus queries.
* No new Docker containers.
* No frontend frameworks.

3. Monitoring Scope

Distinguish between two scopes.

3.1 Docker Engine

Display global Docker Engine information:

* Total memory available to Docker.
* Number of running containers.
* Number of stopped containers, if inexpensive to retrieve.

3.2 Playground workloads

Display the resources consumed by the Playground environment:

* CPU usage of running Kind node containers.
* Memory usage of running Kind node containers.
* Number of running Kind node containers.
* Number of running Kind clusters.

Include the Playground container itself in resource totals only if explicitly identified and labeled separately.

Do not silently mix unrelated Docker workloads into Playground resource totals.

Important

The Docker Engine may contain containers unrelated to this project.

Only include Kind node containers belonging to the CNPG Operator Playground when calculating Playground workload consumption.

Use existing cluster naming conventions and discovery helpers.

Do not hardcode use case names.

4. Expected UI

Use the existing Docker resources section in the Web UI.

Suggested layout:

┌───────────────────────────────┐
│ DOCKER RESOURCES              │
│                               │
│ CPU          145%             │
│ Memory       5.8 / 16 GB      │
│ Containers   8 running        │
│ Clusters     2 running        │
│                               │
│ Updated 3 seconds ago         │
└───────────────────────────────┘

The values above are examples only.

Display requirements

* Keep the existing dark theme.
* Use compact resource indicators.
* Avoid large charts.
* Use simple progress bars where meaningful.
* Display clear units.
* Avoid unnecessary animations.

CPU interpretation

Docker reports container CPU percentages relative to one logical CPU.

Therefore:

* 100% represents approximately one fully utilized logical CPU.
* A multi-core workload can exceed 100%.
* Do not cap the displayed CPU value at 100%.

If a CPU progress bar is used, normalize against the Docker Engine’s available logical CPUs.

Clearly distinguish:

* Raw Docker CPU percentage.
* Percentage of total Docker CPU capacity.

Do not present these as the same metric.

Memory interpretation

Display memory usage using consistent units.

Example:

Memory: 5.8 GiB / 16 GiB

The denominator must come from Docker Engine memory capacity, not from the macOS host.

Do not confuse Docker Desktop’s allocated memory with the Mac’s total physical RAM.

5. Data Collection

5.1 Docker CLI

Prefer:

docker stats --no-stream
docker info
docker ps

Inspect the existing Docker helper functions before adding new ones.

Use structured output where possible:

docker stats --no-stream --format '{{json .}}'

Avoid parsing human-readable tables when structured output is available.

5.2 Container discovery

Identify Kind node containers belonging to the Playground.

Prefer Docker metadata and labels when available.

Otherwise, reuse the existing Kind naming convention:

cnpg-lab-<usecase>-<index>-control-plane
cnpg-lab-<usecase>-<index>-worker
cnpg-lab-<usecase>-<index>-worker2
...

Do not rely on a fixed number of worker nodes.

Avoid counting unrelated Kind clusters.

5.3 Cluster discovery

Reuse the existing Kind discovery logic.

Count actual running Kind clusters belonging to valid Playground use cases.

Do not infer the cluster count solely from the number of containers.

Distinguish between:

* Existing Kind clusters.
* Clusters with running node containers.

If a cluster exists but its Docker nodes are stopped, do not report it as fully running.

5.4 CPU usage

Collect CPU usage for the selected Playground containers.

Sum the individual Docker CPU percentages.

Example:

Kind node A:  35%
Kind node B:  42%
Kind node C:  18%
Total:        95%

This represents approximately 0.95 logical CPU cores.

Do not interpret it as 95% of the entire Docker Engine.

5.5 Memory usage

Sum the memory consumption of the selected Kind node containers.

Use Docker-reported memory usage.

Do not sum memory limits and present them as actual usage.

Convert values consistently to MiB or GiB.

5.6 Docker Engine capacity

Retrieve:

* Total memory.
* Number of logical CPUs.

Use Docker Engine information.

Do not use macOS host metrics.

6. Backend API

Add a read-only endpoint.

Suggested:

GET /api/docker/resources

Example response:

{
  "engine": {
    "cpus": 14,
    "memory_total_bytes": 17179869184,
    "containers_running": 9,
    "containers_stopped": 2
  },
  "playground": {
    "cpu_percent": 145.2,
    "memory_used_bytes": 6227702579,
    "kind_containers_running": 8,
    "kind_clusters_running": 2
  },
  "updated_at": "2026-11-05T10:30:00Z",
  "error": null
}

The values above are illustrative.

Backend requirements

* Read-only.
* No Docker mutations.
* No Kubernetes mutations.
* No shell injection.
* Use subprocess argument lists.
* Validate and parse Docker output.
* Handle Docker Engine errors.
* Return structured JSON.
* Keep API responses reasonably fast.

Important

Do not run expensive Docker statistics collection for every HTTP request.

Implement a lightweight cache.

7. Refresh Strategy

The existing frontend uses approximately 3-second polling.

However, docker stats --no-stream can take longer than simple metadata queries.

Recommended behavior

* Collect resource statistics every 5 seconds.
* Cache the latest successful result.
* Allow frontend polling every 3–5 seconds.
* Avoid overlapping Docker statistics collection.
* Return cached values immediately when available.

A simple in-memory cache is sufficient.

No database or external cache.

Concurrency

If multiple browser windows request monitoring simultaneously:

* Do not launch multiple identical docker stats commands.
* Reuse the same cached snapshot.
* Prevent concurrent refreshes.

Timeout

Apply reasonable timeouts to Docker commands.

If collection fails:

* Preserve the last successful snapshot.
* Mark the data as stale.
* Return a clear error.

Do not report zero resource consumption when Docker is unreachable.

8. Frontend

Replace the existing Docker resources placeholder.

Display:

CPU

CPU: 145%

Optionally:

CPU: 145% (~1.45 cores)

Memory

RAM: 5.8 / 16 GiB

Containers

Containers: 8

Clusters

Clusters: 2

Additional information

Display the age of the last successful measurement.

Example:

Updated 4s ago

If Docker is unavailable:

Docker unavailable
Last update: 25s ago

UI requirements

* Preserve the existing layout.
* Preserve the sidebar.
* Preserve terminal tabs.
* Preserve the bottom status bar.
* Preserve the Operation log panel.
* Do not reload the page.
* Do not steal terminal focus.
* Do not introduce a charting library.

9. Resource Accounting

Resource monitoring must be explicit about what is measured.

Playground resources

By default, calculate resource usage for:

* Kind control-plane containers.
* Kind worker containers.

Only include containers belonging to Playground-managed clusters.

Docker Engine resources

Display global capacity separately.

Example:

Playground RAM: 5.8 GiB
Docker capacity: 16 GiB

Do not claim that the remaining memory is entirely available to Playground workloads.

Other Docker containers and Docker Engine overhead may consume memory.

Container counts

Distinguish:

* Total running Docker containers.
* Running Kind node containers belonging to Playground.

If space is limited, prioritize the Playground count.

10. Validation

Test A — Docker Engine

Verify that:

* Docker CPU count matches docker info.
* Docker memory capacity matches docker info.
* Running container count matches docker ps.
* Stopped container count matches Docker metadata.

Test B — Playground container discovery

Verify that:

* All Playground Kind nodes are included.
* Unrelated Docker containers are excluded.
* No fixed worker count is assumed.
* Multiple use cases are supported.

Test C — CPU and memory

Compare API values against:

docker stats --no-stream

Verify:

* CPU percentages are correctly summed.
* Memory units are correctly converted.
* No containers are counted twice.

Test D — Multiple clusters

With two running Kind clusters:

* Verify both are counted.
* Verify their nodes are included.
* Verify resources are aggregated correctly.

Do not create or destroy existing user clusters solely for this test.

Test E — Cache

Verify:

* Repeated API calls reuse cached data.
* Concurrent requests do not launch duplicate collections.
* Data refreshes after the configured interval.
* The API remains responsive.

Test F — Docker unavailable

Simulate Docker Engine unavailability.

Verify:

* The API reports an error.
* Previously collected data is marked stale.
* The frontend does not display misleading zero values.
* The rest of the Web UI continues functioning.

Test G — Browser

Verify:

* CPU is displayed.
* RAM is displayed.
* Container count is displayed.
* Cluster count is displayed.
* Values refresh automatically.
* The layout remains readable.

Test H — Regression

Verify:

* Terminal tabs remain functional.
* tmux sessions remain persistent.
* Kubernetes context isolation remains functional.
* kubectl and Helm remain consistent.
* Sidebar Start/Stop still works.
* Colored Operation logs still work.
* Dynamic Grafana/MinIO links still work.
* Existing Kind clusters remain untouched.

11. Constraints

* KISS architecture.
* No additional Docker containers.
* No Prometheus deployment.
* No new frontend framework.
* No database.
* No new monitoring agent.
* No changes to Kind provisioning.
* No changes to existing use case scripts.
* No modifications to the reference project.
* Preserve existing ttyd/tmux architecture.
* Preserve Docker networking behavior.
* Preserve Kubernetes context isolation.
* Preserve existing Start/Stop operations.

12. Deliverables

Provide:

1. Architecture decisions.
2. Modified files.
3. Docker resource collection mechanism.
4. Container and cluster identification logic.
5. Example API response.
6. Cache and refresh behavior.
7. Validation results.
8. Known limitations.

Implementation Instructions

First inspect the existing Docker infrastructure and monitoring placeholder.

Explain briefly:

* How Playground containers will be identified.
* How CPU and memory will be calculated.
* How Docker Engine capacity will be retrieved.
* How the cache will prevent excessive Docker calls.

Then implement SPEC-006.6 only.

Do not redesign the existing Web UI.

Do not modify unrelated components.
~~~~~
