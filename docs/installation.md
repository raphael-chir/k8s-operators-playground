# Installation

The only thing to install is Docker. Everything else (Kind, kubectl, Helm, Vim, Python) lives in the Playground container; Make is not used.

```bash
git clone <repository-url>
cd cnpg-operator-playground
./playground doctor      # tells you what is missing and how to fix it
./playground install
./playground start       # then open http://localhost:8080
```

`./playground doctor` is read-only: it never installs or changes anything.

## Resources

| | Minimum | Comfortable |
|---|---|---|
| Docker memory | 8 GB (one use case: 4 nodes) | 12 GB (`cnpg-distributed-topology`: two clusters, 8 nodes) |
| Docker CPUs | 4 | 6 or more |
| Disk | several GB for images and clusters (the Kind node image alone is about 1.3 GB) | |

Container images are pulled from the internet on first use.

## macOS (Apple Silicon and Intel)

1. Install [Docker Desktop](https://docs.docker.com/desktop/setup/install/mac-install/) and start it (it includes Compose v2).
2. Give Docker enough resources: Settings, Resources (memory 12 GB recommended).
3. Git comes with the Xcode command line tools (`xcode-select --install`).
4. The host's default Bash 3.2 is enough for `./playground`.

## Ubuntu (24.04 or newer, amd64)

1. Install [Docker Engine and the Compose plugin](https://docs.docker.com/engine/install/ubuntu/).
2. Let your user use Docker without sudo: `sudo usermod -aG docker $USER`, then log out and in.
3. `sudo apt install git curl` if missing (`curl` is optional: the CLI falls back to Bash).

## Windows 11 (WSL2 + Docker Desktop, amd64)

Run everything **inside a WSL2 Ubuntu shell**; no PowerShell scripts are needed.

1. Install WSL2 with Ubuntu (`wsl --install -d Ubuntu`).
2. Install [Docker Desktop for Windows](https://docs.docker.com/desktop/setup/install/windows-install/) and turn on Settings, General, "Use the WSL 2 based engine", then Settings, Resources, WSL integration for your Ubuntu distro.
3. Clone the repository into the WSL2 Linux filesystem (for example `~/cnpg-operator-playground`), **not** under `/mnt/c`: the Windows filesystem is slow and breaks file watching. `./playground doctor` warns about it.
4. Give Docker memory through Docker Desktop (or `%UserProfile%\.wslconfig`, `memory=12GB`).
5. Open `http://localhost:8080` in the Windows browser: localhost forwarding reaches the WSL2 ports. The Grafana and MinIO links of the status bar use the same host name.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `Cannot connect to the Docker daemon` | Start Docker Desktop / `sudo systemctl start docker`; on Linux check your user is in the `docker` group. |
| `Port 8080 is already in use` | Another program uses it (`lsof -nP -iTCP:8080 -sTCP:LISTEN`). If it is this Playground, `doctor` says so. |
| Web UI does not answer after `start` | `docker logs cnpg-playground`; run `./playground status`. |
| Kind cluster creation fails or pods stay pending | Not enough Docker memory: raise it (12 GB for two clusters). |
| `docker: command not found` in WSL2 | Enable WSL integration for the distro in Docker Desktop. |
| Terminals look broken (`_` instead of box characters) | Reload the browser tab: each connection starts a new Bash with a UTF-8 locale (`LANG=C.UTF-8`). |
| Grafana / MinIO link does nothing | The status bar shows a link only when the service answers; wait for the use case to finish starting. |

### Docker networking notes

- The Playground container mounts the host Docker socket (`/var/run/docker.sock`) and creates **sibling** Kind containers on the shared `kind` network; it joins that network at start-up.
- The Web UI (8080) and the raw terminal (7681) are published on `127.0.0.1` only.
- Grafana and MinIO use Docker-chosen free host ports on `127.0.0.1`; the Web UI reads them from Docker, nothing is hard-coded.
- Mounting the Docker socket gives the container root-equivalent control of the host's Docker Engine: use this on a personal workstation only, never on a shared or remote host, and never expose the ports beyond localhost (see [architecture.md](architecture.md)).

## Image architecture support

Checked on 2026-11-05 against the registries (`docker manifest inspect`) for the images installed by the platform charts, the CNPG cluster manifest and the Playground itself. The Playground image downloads Docker, Kind, kubectl, Helm, ttyd and the CNPG plugin per `TARGETARCH` (amd64 or arm64).

| Image | linux/amd64 | linux/arm64 |
|---|---|---|
| `dappros/minio:RELEASE.2025-09-07T16-13-09Z` | yes | yes |
| `debian:bookworm-slim` | yes | yes |
| `docker.io/grafana/grafana:13.2.4-distroless` | yes | yes |
| `ghcr.io/cloudnative-pg/cloudnative-pg:1.30.1` | yes | yes |
| `ghcr.io/cloudnative-pg/plugin-barman-cloud:v0.15.1` | yes | yes |
| `ghcr.io/cloudnative-pg/postgresql:17.5` | yes | yes |
| `ghcr.io/jkroepke/kube-webhook-certgen:1.11.0` | yes | yes |
| `kindest/node:v1.37.0` | yes | yes |
| `netiedge/minio-mc:RELEASE.2025-01-17T23-25-50Z` | yes | yes |
| `quay.io/jetstack/cert-manager-cainjector:v1.20.2` | yes | yes |
| `quay.io/jetstack/cert-manager-controller:v1.20.2` | yes | yes |
| `quay.io/jetstack/cert-manager-startupapicheck:v1.20.2` | yes | yes |
| `quay.io/jetstack/cert-manager-webhook:v1.20.2` | yes | yes |
| `quay.io/kiwigrid/k8s-sidecar:2.14.1` | yes | yes |
| `quay.io/prometheus-operator/prometheus-operator:v0.94.1` | yes | yes |
| `quay.io/prometheus/alertmanager:v0.34.1` | yes | yes |
| `quay.io/prometheus/prometheus:v3.15.0-distroless` | yes | yes |
| `registry.k8s.io/kube-state-metrics/kube-state-metrics:v2.20.0` | yes | yes |

All of them support both architectures, so no image is replaced. Images that charts pass as operator arguments (for example the Prometheus config reloader) and the images shipped inside `kindest/node` (CNI, local-path provisioner, CoreDNS, kube-proxy) are not in this static scan; the Kind node image is multi-architecture and was already used on arm64 here. Only macOS arm64 has been exercised end to end.
