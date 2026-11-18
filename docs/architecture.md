# Architecture

```
Host Docker Engine
├── cnpg-playground            (Compose service: Bash, Make, Docker CLI, Kind, kubectl, Helm, ttyd)
│     ├── :8080  ──────────────► published on 127.0.0.1:8080 (Web UI + API: FastAPI)
│     ├── :7681  ──────────────► published on 127.0.0.1:7681 (ttyd, embedded by the Web UI)
│     ├── /var/run/docker.sock ◄─ host socket
│     ├── /workspace           ◄─ project directory (bind mount); /usecases -> /workspace/usecases
│     └── /root/.kube          ◄─ named volume `kube`
└── Kind cluster nodes         (sibling containers on the `kind` network)
      ├── cnpg-lab-<usecase>-<n>-control-plane   (clusters owned by use cases)
      └── cnpg-lab-<usecase>-<n>-worker<k>
```

## The `playground` CLI

`./playground` (Bash 3.2 compatible, no GNU Make) is the single entry point, and the only place that knows about Docker Compose. It has two contexts, detected from `/.dockerenv` and the project root (`/workspace` inside the container):

```
host                                           Playground container
────                                           ────────────────────
./playground doctor|install|start|stop|        (host-only commands refuse to run here)
  restart|status|uninstall|purge|version
        │  docker compose / docker CLI
        ▼
./playground infra|usecase ...  ── docker exec ──►  /workspace/playground infra|usecase ...
                                                        │  runs the engine scripts directly
                                                        ▼
                                                   engine/*, usecases/*/{install,status,cleanup}.sh
```

The web backend calls the same CLI (`./playground usecase start|stop <name> [--force]`) as a subprocess, so the Web UI and the terminal share one code path. The CLI adds no lifecycle logic of its own: it validates names, unsets `KUBECONFIG` (lifecycle always uses the shared kubeconfig) and runs the existing scripts. Reference: [cli.md](cli.md).

Version: the `VERSION` file is the single source; the CLI reads it, the backend serves it at `/api/meta`, and the page shows it next to the title.

Ownership for cleanup: Kind clusters are recognized by Kind's `io.x-k8s.kind.cluster` container label **and** the `<prefix>-<usecase>-<n>` name; Compose resources by the project label (`name: cnpg-operator-playground` in `compose.yaml`). `purge` deletes nothing else.

## Docker Compose

One service, `playground`, built from the `Dockerfile` (Debian slim, tools downloaded per `TARGETARCH` so the same file builds for amd64 and arm64). The entrypoint joins the `kind` network, starts the FastAPI backend (uvicorn, port 8080), then runs `ttyd`, which starts one Bash per connection (`engine/terminal.sh`, no session manager). Both listen on all container interfaces, but Compose only publishes them as `127.0.0.1:8080` and `127.0.0.1:7681`, so they are reachable from the local machine only.

## Docker-outside-of-Docker

The host's `/var/run/docker.sock` is mounted into the container and only the Docker **CLI** is installed. No Docker daemon runs inside. When Kind creates a cluster, the node containers are started by the **host** engine, as siblings of the playground container, not children of it. Consequences:

- Nodes are visible with `docker ps` on the host.
- Paths given to Docker are interpreted by the host. This is why the Kind config is read inside the container and passed to Kind directly, and why nothing bind-mounts container paths into nodes.
- Cluster containers outlive the playground container; stop them with `./playground usecase stop <name>` (or `./playground infra down <cluster>`).

## Kind networking

Kind publishes each API server on a random `127.0.0.1` port **of the Docker host**. Inside the playground container, `127.0.0.1` is the container itself, so the default kubeconfig does not work. On Docker Desktop the node IPs are inside a VM and unreachable from macOS, so IP routing is not an option either.

Solution (no hardcoded IPs):

1. Kind nodes attach to the Docker bridge network `kind`.
2. `join_kind_network` (`engine/infrastructure/kind/common.sh`) runs `docker network connect kind cnpg-playground` (once; shared by all clusters), idempotently. Docker's embedded DNS on this user-defined network resolves node container names.
3. `kind export kubeconfig --internal` writes a kubeconfig whose server is `https://<cluster>-control-plane:6443`, the name resolved dynamically by Docker DNS.

This works the same on Docker Desktop and Docker Engine on Linux. `engine/entrypoint.sh` joins the container to `kind` (creating the network if needed) **before ttyd starts**, on every container start, so it also survives recreation. This ordering matters: attaching a network to a running container resets open ttyd WebSockets, and ttyd then SIGHUPs the shell (killing a running `playground infra up`). The scripts keep a fallback join that logs a warning.

## Platform services (monitoring and object storage)

`platform/monitoring/install.sh` (Prometheus and Grafana selectable with `PROMETHEUS_ENABLED` / `GRAFANA_ENABLED`, one `kube-prometheus-stack` release), `platform/object-storage/install.sh` and `platform/cert-manager/install.sh` take **one Kubernetes context** (`kind-<cluster>`) and pass it explicitly to `kubectl` and `helm`; the current context is never changed. `./playground infra platform-up` simply loops over the playground clusters and calls them, so they work for 1, 2 or N clusters.

- **Monitoring:** kube-prometheus-stack (values derived from the CNPG sample config). The CNPG dashboard is imported through the Grafana API (`POST /api/dashboards/db`, fixed uid, `overwrite: true`, so reruns update it in place and never duplicate it) and set as the org home dashboard. The API is reached through a temporary `kubectl port-forward` (stopped on exit), and the installer checks that exactly one dashboard exists and that its Prometheus data source answers queries. The dashboard JSON is unchanged; it picks the default `Prometheus` data source through its `DS_PROMETHEUS` variable. The dashboard opens on the last 5 minutes with a 2 s refresh (SPEC-007.1.5, SPEC-007.1.6): it is set in the dashboard JSON, and `grafana.ini` `dashboards.min_refresh_interval = 1s` in `values.yaml` is required, otherwise Grafana rejects the import. The CNPG PostgreSQL PodMonitor (`cluster.yaml`) scrapes every 2 s (timeout 1 s), the rest of the stack every 30 s, and the Grafana datasource minimum step is 2 s (`defaultDatasourceScrapeInterval`). CNPG caches the results of its monitoring queries for 30 s by default, which would hide anything faster than that: `cluster.yaml` sets `spec.monitoring.metricsQueriesTTL: 0s` so they run at every scrape (an idle instance then shows ~14 commits/s of monitoring traffic in `xact_commit`).
- **Object storage:** the MinIO chart with multi-arch images, standalone mode; the chart's post-install job creates the `cnpg` bucket, which the installer verifies.
- Both are pinned to the control-plane (label `playground.edb.io/role=platform`, taint tolerated); workers stay free for PostgreSQL.

### Host access and port discovery

Kind nodes are sibling containers of the **host** engine, so the `extraPortMappings` in `engine/infrastructure/kind/cluster.yaml` (`hostPort: 0`, `127.0.0.1`) are published on the host, where your browser runs. Docker picks a free port per cluster and keeps it while the container exists, so there are no collisions and no state file. `infra-info` combines two live sources: the Service's NodePort from Kubernetes, and `docker port` (through the socket) for the host port.

Because `localhost` in the playground container is not the host, the installers never probe those URLs; they use `kubectl` (`exec`, `rollout status`, `wait`) instead. This avoids depending on Docker Desktop's port forwarding from inside the container.

Limitations: published ports bind `127.0.0.1` only (reachable from the local machine, not the LAN); mappings are fixed at cluster creation; on Docker Desktop, ports are forwarded by the VM layer, and Kind node IPs are not reachable from macOS, so only the published ports are usable from the host.

## Use cases and cluster ownership

A use case (`usecases/<name>/`) **owns its Kind clusters**. Clusters are named `<prefix>-<usecase>-<n>` (prefix `cnpg-lab`). `usecase.yaml` (SPEC-012: `title`, `description`, `infrastructure.clusters`, `infrastructure.workers_per_cluster`; the identifier is the directory name) declares what it needs, and the engine runs the lifecycle (`engine/usecase-run.sh start|stop|status`, called by `./playground usecase`, so also by the Web UI) with the helpers of `engine/usecase.sh`: `usecase_start` calls `usecase_provision`, which runs `up.sh` (creates missing clusters, reuses compatible ones, refuses incompatible ones) and `platform-up.sh` (the services enabled in `usecase.yaml` `services` -- cert-manager, MinIO, Prometheus, Grafana -- on each cluster, independently; selection passed in `PLATFORM_SERVICES`, default for a standalone run: MinIO, Prometheus, Grafana); Start installs no PostgreSQL operator or plugin (SPEC-011): operators are installed by the scenarios, with the reusable installers under `platform/operators/`. With more than one cluster, `usecase_validate_connectivity` then checks that every control plane is on the `kind` network and that every cluster's API answers from every other. `usecase_delete` (Stop) deletes exactly the clusters matching `^<prefix>-<usecase>-[0-9]+$`; because everything lives in the clusters, nothing else needs uninstalling.

Safety rules, all enforced in `engine/infrastructure/kind/common.sh`: the low-level scripts only act on explicitly named clusters (there is no delete-all); a name must match `<prefix>-<name>-<n>`; an existing cluster with the wrong node count or without host port mappings is never recreated implicitly.

Each cluster gets its own pod/service CIDRs by index (`10.243+n.0.0/16`, `10.95+n.0.0/16`) so clusters on the shared `kind` network never overlap. Nodes are labelled `playground.edb.io/role=platform` (control-plane: operators, monitoring) or `postgres` (workers: scenario workloads).

Host-facing and in-cluster addresses are kept apart: Grafana and MinIO URLs on `localhost:<port>` are for the host browser; manifests use the in-cluster MinIO service `minio.object-storage.svc.cluster.local:9000`.

## Terminals (Web UI)

One ttyd process serves every terminal tab (SPEC-007.1.7). It runs `engine/terminal.sh` for each browser connection and accepts `?arg=<use case>` (`--url-arg`, passed as the first argument); the script validates the name against `engine/usecase-list.sh --names`, writes the terminal's kubeconfig file, goes to the starting directory and `exec`s an interactive Bash. There is no session manager: **one connection = one Bash process**. Opening a tab starts a Bash, reloading the page (F5) or closing the tab ends it and starts a new one, and a dropped WebSocket ends it too; a command running in it is interrupted. Nothing in Kubernetes or PostgreSQL depends on the terminal. ttyd stays unauthenticated and bound to 127.0.0.1; the browser can pass a use case name only, never a command. The API (`GET /api/terminals`) only lists the tabs: the backend does not start, inspect or stop shells. The entrypoint still joins the `kind` network before ttyd starts. History: the Web terminal ran through tmux until SPEC-007.1.7 (persistent sessions, but wheel and selection were owned by tmux).

Split view (SPEC-009): a use case tab is a grid of one to four iframes, each on the same ttyd. ttyd starts one process per WebSocket connection, so each panel is its own Bash with no backend change; panels 2-4 add a second `?arg=<N>` (`terminal.sh <usecase> <N>`, validated 2-4, use case terminals only) and get their own kubeconfig file `playground-uc-<usecase>-p<N>.yaml`, always rewritten to the use case's initial context (never inherited, never copied credentials; clusters and users still come from the shared `~/.kube/config`). Layout is CSS Grid driven by the panel count; closing a panel removes its iframe, so ttyd ends only that Bash. Draggable separators only change the grid template (`--cx`/`--cy` on the pane): iframes resize in place and ttyd refits xterm.js, so nothing reconnects. Nothing is persisted.

Kubernetes contexts: terminals share one kubeconfig, whose `current-context` would otherwise be global. Each terminal tab has a private file holding only `current-context`, and `engine/shell/bashrc` exports `KUBECONFIG=<private file>:~/.kube/config` inside the terminals. This is the standard client mechanism, so `kubectl`, `k` and `helm` resolve the same context with no wrappers (tested: kubectl merges both files, takes `current-context` from the first, writes `use-context` to the first only, and leaves the shared file untouched). `engine/terminal.sh` initializes the file when a terminal starts, keeping the context it already has (a context you selected survives a browser refresh; the file is rewritten with that context alone, since a cluster or user copied into it would shadow the shared kubeconfig and break kubectl after a cluster is recreated): cluster 1 of the use case via the Kind naming helpers (`cluster_name`, `cluster_context`), or the shared default for Playground. `kind` writes into the first KUBECONFIG file, so lifecycle commands never see the terminal's `KUBECONFIG` (the `playground` CLI unsets `KUBECONFIG` before running the engine scripts, like the backend, which never has it) and a `kind` function in the terminal points it at the shared file.

Status bar: `GET /api/status?terminal=<id>` is read-only. It never starts or runs anything in a terminal. The context is read from the terminal's private kubeconfig file (the file the shell's `kubectl`/`helm` write to), only when that file exists (the tab was opened at least once; otherwise `no-session`); it is reported as `ok`, `unavailable` (not in the shared kubeconfig, checked with `kubectl config get-contexts`, cached by the file's mtime), `none` or `no-session`, never as an inferred default. Clusters come from `engine/usecase-clusters.sh` (`usecase_clusters` + `host_port`, i.e. what Docker published for the fixed Grafana/MinIO-console NodePorts 30082/30084); a URL is returned only if a TCP connect to `<cluster>-control-plane:<nodePort>` over the kind network succeeds. Results are cached 5 s per use case, and a Docker/Kind failure becomes `error` in a normal 200 response. URLs use the request's host name, valid because the ports are published on the host's 127.0.0.1 and the UI is bound there too.

Docker resources: `GET /api/docker/resources` returns a cached snapshot. One collector thread (started by the first request, stopping 30 s after the last one) runs every 5 s: `docker info` (CPUs, memory and container counts of the Engine; it exits 0 with empty fields when the daemon is unreachable, which is treated as an error, not as zeros), `engine/managed-clusters.sh` (the existing `managed_clusters` helper, failing when Kind cannot be queried), `docker ps -a` with the Kind cluster label to attribute nodes, then a single `docker stats --no-stream` limited to the running playground nodes (all subprocesses use argument lists). Nodes are matched by Docker label, so the worker count is never assumed, and clusters of other tools are excluded. Failure keeps the last good snapshot and sets `stale` and `error`; with no snapshot at all the data fields are `null`.

Terminal encoding and scrollback (SPEC-007.1.7): the container has no UTF-8 locale configured, so `engine/terminal.sh` exports `LANG=C.UTF-8` (present in Debian) before starting Bash: readline editing and Vim then treat the terminal as UTF-8 (no image setting needed). Scrollback is xterm.js's own: ttyd client option `scrollback=10000` (`-t scrollback=10000` in the Dockerfile; ttyd's default is 1000). Mouse selection, Cmd+C / Cmd+V and wheel/trackpad scrolling are xterm.js defaults, with no modifier key, custom JavaScript or `macOptionClickForcesSelection`: only Vim (alternate screen) and full-screen programs that enable mouse reporting capture the mouse. Multi-line pastes are bracketed by Bash's readline (inserted intact, run on Enter). The shell exports `clear` as `clear -x` (`engine/shell/bashrc`) because plain `clear` sends ESC[3J, which erases the scrollback; `ui_watch` (`engine/lib/ui.sh`) draws on the alternate screen with a plain cursor-home/erase, in a subshell, and leaves it on exit through an EXIT trap (Enter, or Ctrl+C, whether it runs in a scenario script or is called at the prompt), so its frames never reach the scrollback. Operations report `started_at`, `elapsed` and `since_finished`, computed on the server clock; the page only extends them locally between polls with a single 1 s ticker.

## Web API overview

| Endpoint | Purpose |
|---|---|
| `GET /api/meta` | Playground metadata: the version, read from the `VERSION` file |
| `GET /api/usecases` | Discovered use cases with status, cluster count and last operation |
| `POST /api/usecases/{name}/start`, `/stop` | Run `./playground usecase start|stop` in the background (stop needs `{"confirm": true}`) |
| `GET /api/usecases/{name}/operation?offset=` | State and next chunk of the operation log |
| `GET /api/terminals` | Terminal tabs (Playground and one per use case); no session state |
| `GET /api/status?terminal=<id>` | Read-only: effective context, clusters, Grafana/MinIO links |
| `GET /api/docker/resources` | Read-only cached Docker/Playground resource snapshot |
| `/api/ai-builder/{health,generate,status,review,approve,publish,auth/*,conversations…}` | Server-side proxy to the optional AI Builder container (`http://ai-builder:8099`, bearer token kept on the server): [AI Builder](ai-builder.md) |

Everything except start/stop/connect and the AI Builder generate/approve/publish/conversation proxy is read-only. In the AI Builder, Claude Code runs in a container where `usecases/` is a read-only mount; published Labs are written only by a separate `ai-publisher` container after an explicit approval (SPEC-023, [AI Builder](ai-builder.md)). The specification history is in `docs/specs/`.

## Kubernetes configuration persistence

`/root/.kube` is a named volume, so the kubeconfig outlives container restarts and recreation. The cluster itself lives in the host Docker Engine, independent of the playground container. After `docker compose restart`, `kubectl` works immediately.

## Security implications of mounting the Docker socket

Access to the Docker socket is equivalent to root on the host: the container can start privileged containers, mount any host path, and read or delete other containers' data (including non-playground ones). The web terminal has no authentication, so anything that can reach `127.0.0.1:7681` on the host (any local user or process) gets that power.

This is acceptable only for a single-user local POC. Do not expose ports 7681 and 8080 beyond localhost, do not change the binding to `0.0.0.0`, and do not run this on shared or remote hosts without adding authentication and rethinking the isolation model.
