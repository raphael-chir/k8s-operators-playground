# Release checklist: v1.0.0-rc.1

Target: `1.0.0-rc.1` (the `VERSION` file). `[x]` = done and verified as described; `[ ]` = open. Nothing here is tagged, pushed or released: that needs explicit authorization. This is a release **candidate** checklist; v1.0.0 is not declared.

## Implementation

- [x] Unified CLI implemented (`./playground`, Bash 3.2 compatible)
- [x] GNU Make removed (Makefile deleted after an equivalence check; the `make` package is out of the image; no operational reference left: `tests/static.sh`)
- [x] Prerequisites documented (`docs/installation.md`; Make is not a prerequisite)
- [x] Version centralized (`VERSION`), shown by the CLI, served at `/api/meta`
- [ ] Version displayed in the UI: implemented; **needs a look in a browser** (small text next to the title, light and dark themes)
- [x] README updated (concise quick start); `docs/cli.md`, `docs/installation.md`, `docs/user-guide.md`, `docs/architecture.md`
- [x] CLAUDE.md created
- [x] CONTRIBUTING.md created
- [x] Specification archived (`docs/specs/SPEC-007.0-v1-release-candidate.md`)

## Validation by platform

| Platform | Status | Evidence / what is missing |
|---|---|---|
| macOS arm64 (Docker Desktop) | Partially validated | `doctor`, `install`, `start`, `restart`, `status`, routing, `purge --dry-run`, Web backend Start/Stop through the CLI. Not run live: `stop`, `uninstall`, `purge` (fake docker only), a full use case start from the new image |
| macOS amd64 | [ ] Pending | not run |
| Ubuntu 24.04 amd64 | [ ] Pending | not run |
| Windows 11 WSL2 amd64 | [ ] Pending | not run |

Image architecture support (amd64 + arm64) was audited from the registries: all images pass ([docs/installation.md](installation.md#image-architecture-support)). That is not a substitute for running each platform.

## Behavior checks

- [x] Installation validated on macOS arm64 (`./playground install` builds the image)
- [ ] Stop behavior validated live (covered by `tests/cli.sh` with a fake docker: `compose stop` only, clusters untouched)
- [ ] Uninstall behavior validated live (fake docker: `compose down --rmi local`, no volumes, no clusters)
- [x] Purge dry-run validated (real and fake docker; foreign and look-alike clusters excluded in the test)
- [ ] **Real use case start** (both) from the Web UI and the CLI after the project-root correction: verified only with a throwaway use case; needs the owner's approval because it creates clusters
- [ ] **`cnpg-standard` scenarios (SPEC-007.1.2 and the simplified scripts of SPEC-007.1.3): runtime validation, release-blocking for this use case.** Static and fake-`kubectl` checks pass (`tests/scenarios.sh`); the scripts are deliberately check-free, so an early Enter or a replay without reset fails with Kubernetes' own error. Still to run on a live cluster, with the Web terminal: 01 deploy (`use-context` in the Web terminal), 02, 03 backup and restore, 04 switchover and failover, 05 scaling and hibernation, 06 minor then **in-place major upgrade to PostgreSQL 18** (version, Barman and WAL archiving afterwards), 99 reset (MinIO client pod, scenario backups removed, an unrelated object kept) and the replay of 01. The use case is not marked validated
- [ ] **Web terminal scrollback (SPEC-007.1.4)**: implemented, image rebuilt, container recreated, validated with the live ttyd and a headless xterm.js (history, `ui_watch`, resize, independent sessions, context isolation); **not by a person in a browser**. In a browser: wheel and trackpad scroll the history (position indicator, back to the bottom returns), a scenario start and `ui_watch` keep it, resize and reload keep it; selecting text works with Option (macOS) or Shift (Windows, Linux)
- [ ] **Web terminal without tmux (SPEC-007.1.7)**: implemented, image rebuilt, container recreated, validated against the live ttyd with headless Chrome (scrollback 10000, drag selection, Cmd+C/V, Vim, `ui_watch` from a script and from a prompt, resize, refresh = new Bash, independent terminals and contexts, kubectl reaches the cluster); **supersedes the tmux behavior of SPEC-007.1.4**. Also fixes stale cluster data in a terminal kubeconfig file. Open: a person checks trackpad scrolling, Cmd+C / Cmd+V and F5 in a desktop browser
- [ ] **Grafana defaults (SPEC-007.1.5)**: dashboard JSON and `values.yaml` changed and validated against a real Grafana 13.2.4 (import accepted with `min_refresh_interval = 1s`, rejected without). Open: apply to the running `cnpg-standard` with `playground usecase start cnpg-standard` (restarts Grafana: authorization), then in a browser check *Last 5 minutes*, refresh *1s* and panels refreshing every second
- [ ] **Near real-time monitoring (SPEC-007.1.6)**: applied (PodMonitor 2 s/1 s, datasource 2 s, dashboard 2 s, `metricsQueriesTTL: 0s`), measured: samples every 2.00 s, SQL-derived metrics change at every scrape, scrape 41–67 ms, no restart, resources acceptable. Open: confirm a role change appears within ~2 s during a real switchover (scenario 04), and a browser check of *Last 5 minutes* / *2s*
- [ ] Image rebuilt without `make` actually running (needs the container recreated: `./playground start` after review; not done in the development session)

## Quality and security

- [x] Automated tests passing: `tests/static.sh`, `tests/cli.sh`, `tests/engine.sh`, `tests/terminal.sh`, `tests/monitoring.sh` (`tests/scenarios.sh`: see below)
- [ ] Browser regression tests passing: **manual**, checklist below
- [x] Security audit completed (see the report of SPEC-007.0): no secrets found in the tree; demo credentials are deliberate; `.dockerignore`, `.gitignore` checked
- [ ] **License status confirmed: BLOCKER.** The repository has no license file and no license statement. Redistribution rights must be decided by the owner before publishing. No license was added.
- [ ] Git history audit: not possible in the development tree (not a Git repository). Run a secret scan on the real repository before publishing.

## Manual browser checklist (project owner)

1. `./playground doctor`, `install`, `start`; open <http://localhost:8080>: the version `v1.0.0-rc.1` is visible next to the title, in both themes, and the header still works (sidebar button, theme switch, connection indicator).
2. Start `cnpg-standard` from the sidebar; check the timer, the colored logs, the tab, Grafana (no login) and MinIO links, the Docker resources bar; open the terminal, run the seven scenarios in order (01 to 07; boxed banner, Enter, `ui_watch` returns on Enter, confirmations, Ctrl+C), `kubectl` and `helm` agree; the URLs printed by the scenarios open; then `99_reset_lab.sh` and replay 02 (07 is disruptive: last).
3. Start `cnpg-distributed-topology`: both clusters, links per cluster; switch contexts in one terminal without affecting the other.
4. Stop both use cases from the Web UI.
5. `./playground stop`, then `./playground start`: clusters (if any were left running) are untouched; terminals restart empty.
6. `./playground purge --dry-run` lists only Playground resources.

## Release review (SPEC-015)

- [x] Static, CLI, engine, terminal and monitoring tests pass
- [ ] Scenarios and `tests/scenarios.sh`: NOT TESTED, intentionally excluded from this review; the test targets the earlier scenario layout and fails today
- [x] `.env.example` added; `.env` ignored by Git and by the Docker build context; no secret literal in the tree (pattern search)
- [x] Use case READMEs and `CHANGELOG.md` added
- [ ] Git checks (`git ls-files`, history scan): NOT TESTED, the development tree is not a Git repository
- [ ] Live runs of `cnpg-standard` scenarios and of `pgd4k-single-group` (needs an EDB token): NOT TESTED
- [ ] `cnpg-distributed-topology` has no working scenario (missing manifest)
- [ ] `shellcheck` and a YAML linter: not installed here, NOT TESTED

## Before tagging `v1.0.0-rc.1`

Resolve the license blocker; run the checklist on at least one more platform; confirm the manual browser list; decide whether to tag. Do not push or tag from automation.
