# CLI reference: `./playground`

The single entry point. It replaces GNU Make: no `make` is needed anywhere. It is one Bash script, written for **Bash 3.2** (the macOS default) on the host, and it finds the project from its own location, so it works from any directory (`/path/to/playground doctor`).

```
./playground --help
```

## Where commands run

| Commands | Run on | How |
|---|---|---|
| `doctor`, `install`, `start`, `stop`, `restart`, `status`, `uninstall`, `purge`, `version` | the host | Docker Compose and the Docker CLI |
| `infra …`, `usecase …` | inside the Playground container | the CLI detects it is on the host and runs the same command in the running container (`docker exec`), so you never need to know where it runs |

The CLI knows it is inside the container when `/.dockerenv` exists and the project root is `/workspace`; there it runs the engine scripts directly (they need Bash 4+, available in the image) and never re-dispatches, so there is no loop. Host-only commands refuse to run inside the container (exit 2). In a Playground terminal the same command is available as `playground …`.

The infra/usecase commands need the Playground to be running; otherwise they exit with code 3 and tell you to run `./playground start`.

## Lifecycle (host)

| Command | What it does |
|---|---|
| `doctor` | Read-only checks: OS, architecture, Docker, Compose v2, daemon, memory and CPUs, socket, ports 8080 and 7681 (reported as "in use by this Playground" when it is), WSL2 specifics, Git. `[WARN]` is non-blocking. Exit 1 on a blocking problem. |
| `install` | Runs `doctor`, validates `compose.yaml`, builds the image. Idempotent. Creates no cluster and starts no use case. |
| `start` | `docker compose up -d`, waits until the Web UI answers, prints the URL. Idempotent; does not touch Kind clusters. |
| `stop` | `docker compose stop`. Kind clusters are separate containers and **keep running**; volumes, kubeconfig and files are kept. Open terminals (one Bash each) end with the container. |
| `restart [--yes]` | `docker compose restart`. Open terminals (one Bash each) and WebSocket connections are closed by a restart; if terminals are open you are asked first (`--yes` skips the question). Kind clusters are untouched. |
| `status` | Read-only: version, container state, Web UI URL and readiness, Docker availability, Playground Kind clusters and use cases. |
| `uninstall [--yes]` | After confirmation: `docker compose down --rmi local`. Removes the container, its network and the built image. **Keeps** Kind clusters, the `kube` and `history` volumes and your files, and lists what remains. |
| `purge [--dry-run] [--yes]` | **Destructive.** See below. |
| `version` | `CNPG Operator Playground v<VERSION>` (the `VERSION` file). |

## `purge`

Shows an inventory first, then asks you to type `purge` (or pass `--yes` for an explicitly authorized non-interactive run). It deletes only resources whose ownership is established:

- **Kind clusters**: containers carrying Kind's cluster label **and** a name matching `<prefix>-<usecase>-<n>` (default prefix `cnpg-lab`). Other Kind clusters are never touched.
- **Docker volumes** carrying the Compose project label `cnpg-operator-playground` (kubeconfig, terminal state, shell history).
- The Playground container, its Compose network and image.

Never touched: other containers, networks (including the shared `kind` network), volumes and images, the repository and your files. `docker system prune` and `docker volume prune` are never run. Anything that cannot be removed is reported and left as it is (exit 1). `--dry-run` prints the inventory and deletes nothing.

## Infrastructure (container)

These act only on **explicitly named** clusters; there is no delete-all. Names must match `<prefix>-<name>-<n>`.

| Command | Previous Make target |
|---|---|
| `infra up CLUSTER… [--workers N]` | `make infra-up CLUSTER=… [WORKERS=n]` |
| `infra platform-up CLUSTER…` | `make platform-up CLUSTER=…` (env `PLATFORM_SERVICES`: comma separated subset of `cert_manager,minio,prometheus,grafana`; unset = `minio,prometheus,grafana`) |
| `infra down CLUSTER…` | `make infra-down CLUSTER=…` |
| `infra info [CLUSTER…]` | `make infra-info` |
| `infra status [CLUSTER…]` | `make infra-status` |

`infra test-network` (named in the release specification as an example) does not exist in the previous interface and no engine script implements it, so it is not offered.

## Use cases (container)

| Command | Previous Make target |
|---|---|
| `usecase list` | (new; the Web UI used `engine/usecase-list.sh`) |
| `usecase start NAME` | `make usecase-up USECASE=NAME` |
| `usecase stop NAME [--force]` | `make usecase-down USECASE=NAME [FORCE=1]` |
| `usecase status NAME` | `make usecase-status USECASE=NAME` |

`NAME` is a plain directory name under `usecases/`. `usecase stop` asks for confirmation unless `--force` is given (the Web UI passes it after its own confirmation dialog). Lifecycle commands always use the shared `~/.kube/config`: the CLI unsets `KUBECONFIG` first, like the Web backend.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Success |
| 1 | Failure: a failed check or command, a refused confirmation, an invalid argument value |
| 2 | Usage error: unknown command or option, host-only command inside the container |
| 3 | The Playground container is not running |

Engine scripts keep their own codes (for example `usecase list` returns 2 when Docker or Kind is unreachable). The old Make interface turned every failure into 2; the CLI passes the real code through.

## Environment

| Variable | Effect |
|---|---|
| `PLAYGROUND_WAIT_TIMEOUT` | Seconds to wait for the Web UI after `start`/`restart` (default 60) |
| `NO_COLOR` | Disable colors |
| `CLUSTER_PREFIX` | Cluster name prefix (default `cnpg-lab`) |
| `PLAYGROUND_CONTEXT` | `host` or `container`: override the context detection (tests only) |

## Examples

```bash
./playground doctor && ./playground install && ./playground start
./playground usecase list
./playground usecase start cnpg-standard
./playground usecase status cnpg-standard
./playground usecase stop cnpg-standard --force
./playground infra info
./playground stop
./playground purge --dry-run
```
