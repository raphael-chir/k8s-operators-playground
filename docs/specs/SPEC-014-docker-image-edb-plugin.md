# SPEC-014: Docker image: EDB `kubectl cnp` plugin and `ll` alias

Status: implemented and verified in throwaway containers from the rebuilt image; the running `cnpg-playground` container still uses the previous image until it is recreated.

## Implemented

- `Dockerfile`: `ARG EDB_CNP_PLUGIN_VERSION=1.30.1`; the existing binary-install step also downloads the official release asset `kubectl-cnp_<version>_linux_<x86_64|arm64>.tar.gz` of `github.com/EnterpriseDB/kubectl-cnp` (the source listed in EDB's plugin documentation) into `/usr/local/bin`. `kubectl cnpg` is unchanged.
- `engine/shell/bashrc`: `alias ll='ls -lah --color=auto'` (bind-mounted, so persistent and defined once).

## Verification

`kubectl plugin list` shows `kubectl-cnp` and `kubectl-cnpg`; `kubectl cnp --help` works; `kubectl cnpg version` reports 1.30.1; `ll` resolves to the alias in an interactive Bash. Run on aarch64 only: the x86_64 asset path was not run.

## Original request (condensed)

Add the official EDB `kubectl cnp` plugin to the Docker image without removing `kubectl cnpg` and without inventing URLs or versions; add `alias ll='ls -lah --color=auto'` for interactive Bash, persistent across container recreation and not duplicated; rebuild and validate (`kubectl plugin list`, `kubectl cnp --help`, `ll`); do not touch clusters or PGDGroups; minimal changes.
