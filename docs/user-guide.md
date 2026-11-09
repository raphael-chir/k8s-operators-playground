# User guide

Detailed usage of the Playground (the short version is in the [README](../README.md); command reference in [cli.md](cli.md); architecture in [architecture.md](architecture.md)). Commands below run on the host as `./playground ...`; inside a Playground terminal, type `playground ...` (a shell function pointing at `/workspace/playground`).


## Start

```bash
./playground doctor      # check the prerequisites (read-only)
./playground install     # build the image (no cluster is created)
./playground start       # start the Playground and wait for the Web UI
```

Open <http://localhost:8080> (the Web UI). The raw terminal at <http://127.0.0.1:7681/> is kept for debugging and starts a Playground terminal (a new Bash per connection). Both are bound to `127.0.0.1` and have **no authentication**. Installation details per platform: [installation.md](installation.md).

## Use cases

A **use case owns its Kind clusters**: `usecase start` creates them, `usecase stop` deletes them. This is the normal way to use the playground.

```bash
./playground usecase start cnpg-standard   # create the cluster(s), install monitoring + MinIO (no PostgreSQL operator), print the URLs
./playground usecase status cnpg-standard   # nodes, platform, operator, URLs, scenarios
./playground usecase stop cnpg-standard   # delete the use case's Kind cluster(s) [--force skips the confirmation]
```

| Use case | Kind clusters | What it provides |
|---|---|---|
| `cnpg-standard` | `cnpg-lab-cnpg-standard-1` | 1 control-plane + 3 workers; a 3-instance CNPG cluster with WAL archiving to MinIO (Barman Cloud plugin) |
| `cnpg-distributed-topology` | `cnpg-lab-cnpg-distributed-topology-1`, `-2` | Two independent clusters (own Grafana, MinIO, bucket, operator, non-overlapping pod/service CIDRs), connectivity validated. No PostgreSQL yet |
| `pgd4k-single-group` | `cnpg-lab-pgd4k-single-group-1` | EDB Postgres Distributed for Kubernetes 2.2.0: Start provides monitoring and MinIO only (operators are not installed by Start); scenarios deploy a 3-node PGDGroup. Needs `EDB_SUBSCRIPTION_TOKEN` in the `.env` file at the repository root (copy `.env.example`; [README](../usecases/pgd4k-single-group/README.md)); imported from the previous project, not run in this one yet |

`usecase start` is idempotent: existing healthy clusters are reused. An existing cluster that does not fit (wrong node count, no host port mappings) stops it with an error; it is **never recreated automatically**. Open the printed URLs in your **host** browser. Credentials: `admin` / `password` (local demo only).

**Renamed use cases (historical)**: `single-cnpg` is now `cnpg-standard` and `multi-cluster-dr` is now `cnpg-distributed-topology`. Cluster, context and terminal-file names follow the use case name, so clusters and sessions created under the old names (`cnpg-lab-single-cnpg-1`, `cnpg-lab-multi-cluster-dr-1/-2`, `playground-uc-single-cnpg`, ...) are not owned by the new use cases. Remove leftovers explicitly: `./playground infra down CLUSTER=<old cluster name>`, and, if wanted, `kubectl config delete-context <old context>` and `~/.kube/terminals/<old session>.yaml`. Old clusters still count in the Docker resources bar.

Cluster names are `<prefix>-<usecase>-<n>` (`CLUSTER_PREFIX`, default `cnpg-lab`, the previous project's convention; clusters it created with these names are treated as the use case's own). A use case only ever sees clusters matching its own exact pattern, so `./playground usecase stop cnpg-standard` leaves every other cluster, including other use cases', untouched.

### Cleanup

`usecase stop` deletes the use case's Kind clusters, which removes everything inside them (Helm releases, MinIO data, PostgreSQL volumes). Use cases have no external resources. It asks for confirmation (`--force` skips it) and is a no-op when nothing exists. To replay a scenario, run `usecase stop` then `usecase start`.

## Scenarios

Scenarios are plain Bash built on `engine/lib/ui.sh` (`ui_command` shows (a one-line prompt `☸ cluster-N ➜ command`, where N comes from the current Kubernetes context) then runs a command, `ui_pause` waits for Enter, `ui_watch` refreshes a command until Enter). Run them from any directory, e.g. `./usecases/cnpg-standard/02_deploy_cluster.sh`. They find the project root, use case and Kubernetes contexts by themselves (`engine/usecase.sh`); nothing needs to be exported. The context of cluster *n* is `kind-<prefix>-<usecase>-<n>`.

## Low-level commands (debugging)

These act only on **explicitly named** clusters (`<prefix>-<name>-<n>`, several allowed) and refuse any name outside the playground pattern. There is no delete-all.

| Target | Description |
|---|---|
| `./playground infra up CLUSTER... [--workers N]` | Create the Kind cluster(s) only (`WORKERS=n`, default 1). Reuses a compatible existing one. |
| `./playground infra platform-up CLUSTER...` | Install Prometheus/Grafana (CNPG dashboard as home page) and MinIO (bucket `cnpg`) on each cluster independently. `PLATFORM_SERVICES=cert_manager,minio,prometheus,grafana` (any subset) selects services; unset = MinIO, Prometheus and Grafana. |
| `./playground infra status [CLUSTER...]` | Nodes of the clusters (default: all playground clusters). |
| `./playground infra info [CLUSTER...]` | Node status and Grafana / MinIO Console / MinIO S3 URLs. |
| `./playground infra down CLUSTER...` | Delete the named cluster(s). |

The platform installers also run directly for one cluster: `platform/monitoring/install.sh <kube-context>`, `platform/object-storage/install.sh <kube-context>`.

### Directory structure

```
engine/lib/logger.sh, ui.sh     shared libraries (single copy each; ui.sh is independent of Kind; `ui_command` only reads the current kubectl context for its prompt)
engine/usecase.sh               resolves PROJECT_ROOT, USECASE, CLUSTER, KUBE_CONTEXT for use case scripts
engine/usecase-list.sh          read-only use case discovery (names, cluster counts)
engine/usecase-clusters.sh      read-only clusters and host ports of one use case (status bar)
engine/managed-clusters.sh      read-only list of playground clusters (resource monitoring)
engine/terminal.sh              starts the Bash of a terminal tab (used by ttyd, one Bash per connection)
engine/shell/                   bashrc (prompt, KUBECONFIG), vimrc
engine/infrastructure/kind/     cluster lifecycle, node labels, info
platform/                       monitoring, object-storage, cert-manager, operators/cnpg-community
usecases/<name>/                usecase.yaml, NN_*.sh scenarios, manifests/ (use case manifests)
web/                            FastAPI backend (app.py) and static frontend (static/)
docs/                           architecture.md and specs/ (specifications history)
```

## Platform services and port discovery

**Platform services per use case.** `usecase.yaml` has a `services` section with explicit booleans (`cert_manager`, `minio`, `prometheus`, `grafana`; a missing key is `false`); Start installs only the enabled ones, on every cluster, and status and access information report only those. The three use cases enable all four. The section applies when a cluster is provisioned: changing it never installs or removes anything on a running cluster. Operators and plugins are never installed by Start; a scenario (or the installers under `platform/operators/`) installs them, and those installers install cert-manager themselves if it is missing, whatever the manifest says. Prometheus needs to be enabled for scenarios that create PodMonitors; Grafana without Prometheus starts with no data source.

Each cluster has its own independent Prometheus/Grafana (`monitoring` namespace), MinIO (`object-storage` namespace) and bucket `cnpg`. They run on the control-plane node. Nothing is shared between clusters.

**Access to Grafana and the MinIO Console** (local demo credentials, same on every cluster):
- **Grafana** opens without login: anonymous visitors are read-only **Viewers** (browse dashboards, change time ranges, use variables). Log in at `/login` with `admin` / `password` to make changes. This is set in `platform/monitoring/values.yaml` (`[auth.anonymous]`) and applies to clusters installed or upgraded after the change; a running Grafana keeps its old settings until `./playground usecase start <name>` (or `infra platform-up`) is re-run on it, which restarts the Grafana pod (it has no persistent volume: dashboards are re-imported by the install, manual changes are lost).
- **MinIO Console** asks for a login: `admin` / `password`. A login-free administrator session is not possible with a supported mechanism: the Console of the installed MinIO build (`RELEASE.2025-09-07`) only offers the password form, and the alternatives (OIDC / LDAP) need an external identity provider. Its Console also has no user, policy or group management (those endpoints do not exist in this build); buckets and objects are fully manageable. User and policy administration is available through the `mc admin` command line.

Host ports are never hardcoded. Kind publishes fixed NodePorts (Grafana 30082, MinIO S3 30083, Console 30084) on a **free, Docker-chosen port of the host's `127.0.0.1`**. `./playground infra info` reads the real port from Docker (`docker port <cluster>-control-plane <nodePort>`), so it is always correct, including after `docker compose restart`. Ports stay the same while the cluster exists.

Inside the playground container `localhost` is the container, not your host, so the printed `http://localhost:<port>` URLs are meant for your host browser. In-cluster address of MinIO: `http://minio.object-storage.svc.cluster.local:9000`.

## Terminal features

- Killercoda-style prompt (`root@playground:/usecases/cnpg-standard#`), ANSI colors, standard Bash shortcuts (Ctrl+C, Ctrl+R, arrows).
- **Autocompletion** (Tab) for `kubectl`, `helm`, `kind`, `docker` commands, loaded automatically. `k` is an alias for `kubectl` with completion. kubectl resource names complete once the cluster is up.
- **Persistent history**: stored in the `history` Docker volume (`/root/.history`), saved after every command, so it survives `docker compose restart` and is never written into the project directory.
- **Customization**: edit `engine/shell/bashrc` (prompt, aliases, history settings). It is bind-mounted, so no rebuild is needed: run `source ~/.bashrc` or open a new terminal.
- **Logs**: scripts print timestamped `[HH:MM:SS] [SECTION|INFO|SUCCESS|WARN|ERROR]` lines using `engine/lib/logger.sh`, including the live output of Kind and kubectl, colored only on a terminal (`NO_COLOR=1` disables).

## Web UI terminals (tabs)

http://127.0.0.1:8080/ shows one terminal tab per use case (labelled with the `title` of its `usecase.yaml`) next to a permanent **Playground** tab (the sidebar and the tabs select each other; selecting never changes a Kubernetes context).

- **Terminals**: each tab is its own **Bash** behind the one ttyd process (`engine/terminal.sh`, started by ttyd with `--url-arg`): Playground (starts in `/usecases`) and one per use case (starts in `/usecases/<name>`, where its scenarios are; `/usecases` is a symlink to `/workspace/usecases` created at container start). There is no session manager: **refreshing the browser (F5) or closing the tab ends that Bash and a new one starts**, so a command running in it is interrupted and its shell state (variables, working directory, `less`/`vim`) and scrollback are gone. Switching between the Web UI's tabs keeps each terminal as it is (only a use case tab that disappears loses its Bash). Typing `exit` ends it; reload to start a fresh one. Kubernetes and PostgreSQL are never affected by a terminal ending. Run long operations with `./playground ...` or Kubernetes itself, not as a foreground command you may refresh away.
- **Independent of clusters**: `usecase start`/`usecase stop` never touch terminals.
- **Split Terminal** (use case tabs only): the **Split Terminal** button next to the tabs adds a terminal beside the current ones, up to **4** per use case tab (1 = full, 2 = side by side, 3 = one on the left and two stacked on the right, 4 = 2x2). Each one is its own Bash (own history, scrollback and kubeconfig file `~/.kube/terminals/playground-uc-<usecase>-p<N>.yaml`) and starts on cluster 1 of the use case; `kubectl config use-context` in one never affects the others. Terminal 1 is the tab's own terminal and cannot be closed; terminals 2-4 have a **✕** that ends only that Bash. Typical use: run a scenario in terminal 1 and watch pods or operator logs in another. Drag the separator between terminals to resize them (each keeps a minimum size; double-click a separator for an even split). Splits and sizes are not remembered: a browser refresh (or a use case tab that disappears) returns to a single terminal.
- **Removed use cases**: the tab disappears with its Bash. Terminals do not survive `docker compose restart/up --force-recreate` (the container's processes restart).
- **Kubernetes context per terminal**: all terminals share `~/.kube/config` (clusters, users, contexts, so every cluster stays reachable and new ones appear immediately), but each terminal tab has `~/.kube/terminals/<terminal>.yaml` holding only its own `current-context`. The shell exports the standard `KUBECONFIG=<that file>:~/.kube/config`, so `kubectl`, `k` and `helm` always agree, and `kubectl config use-context ...` changes **that terminal only** (the shared file is never written; `helm --kube-context` still overrides).
  - **Initial context**: a use case terminal starts on cluster 1 of its use case (`kind-<prefix>-<usecase>-1`, derived from the Kind naming helpers); Playground starts on the shared default context. This happens when a terminal starts, never when a tab is selected. A terminal file that already has a context is kept, so a context you chose survives a browser refresh; delete `~/.kube/terminals/<terminal>.yaml` before reloading to start from the initial context again.
  - **Missing cluster**: the terminal still starts on that context and prints a notice; kubectl/helm fail with "context was not found" (never falling back to another cluster) until the cluster exists, then work in the same terminal. Same after a cluster is deleted: a stale context fails clearly, other contexts keep working.
  - **Lifecycle commands** (`./playground usecase ...`, `./playground infra ...`) and the Web UI backend always use the shared kubeconfig (the CLI unsets `KUBECONFIG` before running the engine scripts); a manual `kind` in a terminal also writes to the shared file (a `kind` function), because kind would otherwise write into the terminal's file. Running project scripts directly (not through the CLI) inside a terminal makes them use the terminal's `KUBECONFIG`.
- **Status bar** (bottom): shows the selected tab, read-only and refreshed every 3 s: use case, state (Running/Starting/Stopping), the terminal's **actual** Kubernetes context (read from its `~/.kube/terminals/<session>.yaml`, so a `kubectl config use-context` shows up within 3 s; `No context` if none, `(not found)` if the cluster is gone, `(terminal not started)` before the tab was first opened), and each Kind cluster of the use case with **Grafana ↗** and **MinIO ↗** (console) links that open in a new tab. A link appears only when the service answers; otherwise `Grafana —` / `MinIO —`. Ports are the Docker-published host ports (`engine/usecase-clusters.sh`, same lookup as `./playground infra info`), and the host name is the one the page was opened with. Hover a cluster to see its Kind cluster and context names. The Playground terminal shows `No context` when no valid context is selected (it does not depend on any cluster). Selecting a tab never sends anything to the shell.
- **Docker resources** (bar above the status bar, `GET /api/docker/resources`, read-only): **Playground** numbers cover only the Kind node containers of playground clusters (found through Kind's `io.x-k8s.kind.cluster` label, restricted to the playground naming convention via `engine/managed-clusters.sh`), never other containers: `CPU` is the share of the Docker Engine's total CPU capacity (percentage and bar), followed by `used / total cores`; it comes from Docker's raw percentage summed over those nodes (100% = one logical CPU), shown in the tooltip, `RAM` is their summed memory in use against the **Docker Engine's** total memory (not the Mac's; other containers and Docker overhead use part of the rest), `Kind nodes` their count with the Engine-wide running count next to it, `Clusters` the playground clusters whose nodes are all running (`N of M` when some exist with stopped nodes). The playground container itself is not included. A background collector refreshes a cached snapshot every 5 s only while a page is open; if Docker cannot be queried the last values stay, flagged "Docker unavailable, last values" with their age, and nothing is ever shown as zero.
- **Prompt**: `root@playground:/usecases#`, Killercoda style: green `user@playground`, blue full working directory (`~` for home, from bash's own `\w`), `#` for root and `$` for other users. It is `PS1` in `engine/shell/bashrc`, the only place that sets it. Scenario presentation is separate (`engine/lib/ui.sh`: boxed banners, `↵ Press Enter to continue...` under a gray separator, `◆` instructions, `┌─ use case  ☸ context` / `└─➜ command`); scenarios run as child processes, so the Bash prompt is the same after they finish or are interrupted (Ctrl+C), and `ui_login` uses `su -m` to keep the prompt, directory and terminal `KUBECONFIG`.
- **Scrolling and copy/paste** (SPEC-007.1.7): native xterm.js behavior. The mouse wheel and the macOS trackpad scroll the terminal's own history (10000 lines, with a scrollbar); drag with the left button to select text (multi-line included, no modifier key); copy with Cmd+C (macOS) or Ctrl+Shift+C (Linux/Windows) and paste with Cmd+V / Ctrl+Shift+V (multi-line pastes are inserted intact and run when you press Enter). Ctrl+C with a selection still interrupts the running command on macOS; Cmd+C copies. `clear` keeps the scrollback (it runs `clear -x`), and `ui_watch` and Vim run on the alternate screen: their frames never enter the history and the previous display returns when you press Enter, quit Vim, or press Ctrl+C. Output beyond 10000 lines scrolls out of the history.
- **Vim**: the full `vim` package is installed (Dockerfile) with syntax highlighting for YAML, shell scripts (including extension-less files with a shebang) and JSON. Settings are in `engine/shell/vimrc` (version-controlled, loaded through `/root/.vimrc`, editable live): line numbers, 2-space indentation (4 for shell), search highlighting, dark background.
- **Look and theme**: the UI follows the EDB "Blue Coal" palette (Blue Coal, Deep, Abyss, Slate, Mist, Frost, with Gold Leaf for the header bar and the active-tab underline) and uses Roboto / Roboto Condensed when installed on your machine (system fonts otherwise; nothing is downloaded). Light is the default; the **☾ Dark / ☀ Light** button in the header switches the theme and remembers it in the browser. Colors are CSS variables at the top of `web/static/style.css`. The terminals (ttyd) and the operation log panel stay dark in both themes.
- **Sidebar**: 293 px wide; the ☰ button in the header hides/shows it (layout only: terminals, sessions and running commands are untouched). The choice is remembered in the browser.
- **Start timer**: while a use case starts, its sidebar entry shows `Starting… MM:SS` (from the backend's operation timestamp, so it survives refreshes); on success it shows `Running — MM:SS` for a few seconds, on failure `start failed (exit N) — MM:SS`.
- The raw terminal at http://127.0.0.1:7681/ is kept for debugging: it starts an independent Playground terminal.

## Persistence

The kubeconfig lives in the `kube` named volume (`/root/.kube`) and shell history in the `history` volume. `docker compose restart` keeps the clusters and `kubectl` working. Terminals (one Bash per tab) end when the page is reloaded and when the container restarts or is recreated (the clusters, volumes and history do not).

## Stop, uninstall, purge

```bash
./playground usecase stop <name>   # delete a use case's Kind clusters (or the Stop button in the Web UI)
./playground stop                  # stop the Playground; Kind clusters keep running
./playground uninstall             # remove the Playground container and image; keeps clusters and volumes
./playground purge --dry-run       # preview a full cleanup; ./playground purge performs it after confirmation
```

Stop the use cases **before** removing the Playground if you want their clusters gone: Kind node containers belong to the host Docker Engine and are not removed by Compose. Details and safety rules: [cli.md](cli.md).

## Known limitations

- Each use case cluster has 4 nodes (1 control-plane + 3 workers; PostgreSQL instances use required pod anti-affinity). `cnpg-standard` needs about 8 GiB of Docker memory and `cnpg-distributed-topology` (two clusters) about 12 GiB or more.
- `cnpg-standard` has seven scenarios (operators, deploy, data, backup and restore, high availability, administration, upgrades) and `99_reset_lab.sh`, which replays them without recreating the cluster; see its README. Scenario 07 ends with a disruptive in-place major upgrade, so run it last. They need `kubectl cnpg`, which the image includes.
- `cnpg-distributed-topology`'s scenario was carried over unchanged from the previous project, which never shipped its `manifests/` directory: it runs on cluster 1 and stops at `kubectl apply -f manifests/cnpg-community-cluster.yaml`. Its README says so; the operator is not installed by any scenario of this use case yet.
- Pressing Ctrl+C during a `ui_watch` step stops the whole scenario and returns to the shell; press Enter to continue instead (the scenario texts say Enter).
- Terminal tabs: the page cannot see the state of each ttyd WebSocket (cross-origin iframes); a closed connection is shown by ttyd inside the tab ("press Enter to reconnect"), and reconnecting starts a new Bash. Each browser tab or ttyd connection is its own independent Bash.
- Mounting the Docker socket gives the container root-equivalent control of the host Docker Engine; local use only (see `docs/architecture.md`).
- Kind clusters are shared with the host Docker Engine: other Kind clusters on the host are visible. Kind publishes the platform NodePorts on free ports of the host's `127.0.0.1` (see "Platform services and port discovery").
- Host port mappings are set when a cluster is created; a cluster created without them cannot gain them (run `./playground infra down` then `./playground infra up`).
- Platform images are pulled from the internet.
- Other Kind clusters on the host are ignored. A cluster left by the previous project under the same name (`cnpg-lab-<usecase>-<n>`) is adopted by `usecase start` if compatible, and deleted by `usecase stop`.
