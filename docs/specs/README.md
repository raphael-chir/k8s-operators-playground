# Specifications history

Chronological record of the Playground's specifications (the SPEC-006 series, SPEC-007.0, SPEC-007.1.1, SPEC-007.1.2, SPEC-007.1.3, SPEC-007.1.4, SPEC-007.1.5, SPEC-007.1.6, SPEC-007.1.7, SPEC-007.1.8, SPEC-008, SPEC-009, SPEC-011, SPEC-012, SPEC-013, SPEC-014 and SPEC-015): what was asked, what was implemented, what was corrected later, and what is still limited. Newest decisions are at the bottom. Architecture overview: [`../architecture.md`](../architecture.md).

## Index

| ID | Specification | Status | Notes |
|---|---|---|---|
| [SPEC-006.1](SPEC-006.1-web-ui-foundation.md) | Web UI Foundation | Implemented | Initial Web interface (FastAPI + vanilla JS) |
| [SPEC-006.2](SPEC-006.2-dynamic-usecase-discovery.md) | Dynamic Use Case Discovery | Implemented | Directory-based discovery |
| [SPEC-006.3](SPEC-006.3-sidebar-lifecycle.md) | Sidebar Lifecycle | Implemented | Start/Stop, operation logs |
| [SPEC-006.3.1](SPEC-006.3.1-colored-operation-logs.md) | Colored Operation Logs | Implemented | Operation output keeps logger colors |
| [SPEC-006.4](SPEC-006.4-multi-terminal-workspace.md) | Multi-Terminal Workspace | Implemented | ttyd + tmux |
| [SPEC-006.4.1](SPEC-006.4.1-terminal-tabs-lifecycle.md) | Terminal Tabs Lifecycle | Implemented | Tabs follow the use case lifecycle; persistent sessions |
| [SPEC-006.4.2](SPEC-006.4.2-kubernetes-context-isolation.md) | Kubernetes Context Isolation | Implemented | Independent kubeconfigs per terminal |
| [SPEC-006.4.2-FIX](SPEC-006.4.2-FIX-helm-consistency.md) | Helm Consistency (bug report) | Resolved, no code change | Diagnosed as shells started before the scheme |
| [SPEC-006.5](SPEC-006.5-dynamic-status-bar.md) | Dynamic Status Bar | Implemented | Contexts, clusters, Grafana/MinIO links |
| [SPEC-006.6](SPEC-006.6-docker-resource-monitoring.md) | Docker Resource Monitoring | Implemented | CPU, RAM, nodes, clusters |
| [SPEC-006.7.1](SPEC-006.7.1-playground-ux-improvements.md) | Playground UX Improvements | Implemented | Terminal UX, timer, CPU %, sidebar; clipboard and prompt parts superseded by the FIX |
| [SPEC-006.7.1-FIX](SPEC-006.7.1-FIX-killercoda-terminal.md) | Killercoda-Style Terminal | Implemented | Prompt, native clipboard, Playground context, tooltips; its `ui.sh` restyling was reverted |
| [SPEC-006.7.1-HOTFIX](SPEC-006.7.1-HOTFIX-restore-ui-sh.md) | Restore Original ui.sh | Implemented | Hotfix 1 of 2: scenario UI restored |
| [SPEC-006.7.1-HOTFIX-2](SPEC-006.7.1-HOTFIX-2-utf8-rendering.md) | Scenario Rendering (UTF-8) | Implemented | Hotfix 2 of 2: `tmux -u` fixes the broken borders |
| [SPEC-006.7.2](SPEC-006.7.2-usecase-renaming.md) | Use Case Renaming | Implemented | `cnpg-standard`, `cnpg-distributed-topology` |
| [SPEC-006.8](SPEC-006.8-usability-improvements.md) | Usability Improvements | **Partially implemented** | Vim: done. Grafana anonymous Viewer: done. MinIO: investigated, no supported login-free admin mechanism, nothing changed |
| [SPEC-006.8.1](SPEC-006.8.1-ui-themes.md) | UI Themes | Implemented | EDB (light, default) / dark, `localStorage` |
| [SPEC-006.9](SPEC-006.9-playground-stabilization.md) | Playground Stabilization | Implemented, manual validation pending | This history, review, small fixes |
| [SPEC-007.0](SPEC-007.0-v1-release-candidate.md) | V1 Release Candidate Preparation | Implemented; platform validation and license open | `./playground` CLI replaces Make; `VERSION`; lifecycle (install/start/stop/uninstall/purge); docs; tests. Validated on macOS arm64 only (partially); amd64 macOS, Ubuntu and WSL2 pending; no license (blocker). Correction 1: project-root marker regression fixed, `tests/engine.sh` added |
| [SPEC-007.1.1](SPEC-007.1.1-cnpg-standard-scenarios.md) | CNPG Standard Scenario Integration | Implemented (static and non-destructive validation); **runtime validation pending** | Workshop scenarios 05–12 and 99 imported into `cnpg-standard` with their numbers; workshop 01–04 are covered by the existing `01_install-cnpg-cluster.sh`; adapted to the Playground (fixed names in `default`, discovered Grafana/MinIO URLs, `ui_watch`, private context file, versions 17.5→17.6 and 17→18). `tests/scenarios.sh` added. Not run on a live cluster yet |
| [SPEC-007.1.2](SPEC-007.1.2-cnpg-standard-simplification.md) | CNPG Standard Scenario Simplification | Implemented (static and fake-kubectl validation); **runtime validation pending** | Six scenarios (deploy, data, backup+restore, HA, administration, upgrades) + `99_reset_lab.sh`; two manifests in `manifests/`; minor upgrade and offline **in-place major upgrade** (17.5 → 17.6 → 18, Bookworm images, JSON patch incl. Barman `serverName`); reset limited to scenario-owned resources and MinIO prefixes with the platform's pinned `netiedge/minio-mc`. Supersedes the scenario set of SPEC-007.1.1. Not run on a live cluster yet |
| [SPEC-007.1.3](SPEC-007.1.3-scenario-code-simplification.md) | CNPG Standard Scenario Code Simplification | Implemented (static and fake-kubectl validation); **runtime validation pending** | `scenarios/lib.sh` removed; the six scenarios and the reset are plain command sequences (613 → 374 lines); only scenario 01 selects the context (`use-context "$KUBE_CONTEXT"`); no existence, health or readiness checks; dynamic primary/replica lookup kept; minor and in-place major upgrade by patch (Barman `serverName` in the same JSON patch); reset isolation kept. Describes the current scripts where it differs from SPEC-007.1.2 |
| [SPEC-007.1.4](SPEC-007.1.4-web-terminal-scrollback.md) | Web Terminal Scrollback Reliability | Implemented and validated with a real ttyd/tmux and headless xterm.js; **not validated by a person in a browser** | Root causes: (1) tmux without the alternate screen made xterm.js keep a second, partial scrollback (29 of 300 lines); (2) `clear` sends `ESC[3J` and erases tmux's history (every scenario start and every `ui_watch` refresh). Fix: alternate screen + `mouse on` (wheel = tmux copy-mode), exported `clear -x`, `ui_watch` on the alternate screen, ttyd `macOptionClickForcesSelection` (image rebuilt). Trade-off: text selection needs Shift/Option. Supersedes the `mouse off`/no-alternate-screen choice of the SPEC-006 series |
| [SPEC-007.1.5](SPEC-007.1.5-grafana-default-settings.md) | Grafana Dashboard Default Settings | Implemented and validated against a real Grafana 13.2.4 in throwaway containers; **not applied to the running cluster** and not validated in a browser | CNPG dashboard JSON: `now-5m`, `refresh` 1s, 1s added to the refresh list (panels, queries, UID, title unchanged); `values.yaml`: `dashboards.min_refresh_interval: 1s`, **required** (without it Grafana rejects the import: "Dashboard refresh interval is too low"). Applying it to a running cluster is a Helm upgrade that restarts Grafana (authorization needed) |
| [SPEC-007.1.6](SPEC-007.1.6-cnpg-near-real-time-monitoring.md) | CNPG Near Real-Time Monitoring | Applied to the running cluster; Prometheus samples every 2 s (measured: 2.00 s, no gaps); SQL-derived metrics were cached 30 s by CNPG's default (fixed by `metricsQueriesTTL: 0s`); `metricsQueriesTTL: 0s` applied with approval: SQL-derived metrics now change at every 2 s scrape (xact_commit gap 32 s → 2 s), no pod restart; role changes not yet exercised, not validated in a browser | CNPG PodMonitor `interval: 2s`/`scrapeTimeout: 1s`; Grafana datasource `timeInterval` 2s; dashboard refresh 2s (selector with 1s, 2s, 5s...). 66 panels unchanged; resources: Prometheus +53 MB, ingest 2401 → 3082 samples/s. Replaces the 1 s refresh of SPEC-007.1.5 |
| [SPEC-007.1.7](SPEC-007.1.7-web-terminal-simplification.md) | Web Terminal Simplification | tmux removed: ttyd starts one Bash per connection, scrollback 10000, native selection and copy/paste, no session persistence (refresh = new shell). Deployed and validated against the live ttyd with headless Chrome; also fixes `ui_watch` Ctrl+C at a prompt and stale cluster data in terminal kubeconfig files; not tested by a person in a desktop browser |
| [SPEC-007.1.8](SPEC-007.1.8-minio-cleanup-fix.md) | Fix MinIO Cleanup (cnpg-standard) | `99_reset_lab.sh`: the spinner hid the MinIO client's error, a prefix without trailing slash also matched `cnpg-cluster-pg18`, and a leftover pod could block a rerun; fixed. Validated with `mc rm --dry-run` against the live MinIO; the real reset was not run |
| [SPEC-008](SPEC-008-import-pgd4k-single-group.md) | Import PGD4K Single Group Use Case | `pgd4k-single-group` imported from the previous project with minimal changes (`.env` with `EDB_TOKEN` only, PGD4K operator installer, 3 scenarios); statically checked, not deployed or run |
| [SPEC-009](SPEC-009-multi-terminal-split-view.md) | Multi-Terminal Split View | **Split Terminal** button on use case tabs: up to 4 independent Bash panels per tab, each with its own kubeconfig file starting on the use case context; no backend, tmux or scenario change; verified with a live browser run and WebSocket checks |
| [SPEC-011](SPEC-011-decouple-operator-installation.md) | Decouple Operator Installation | Start provisions Kind clusters, monitoring and MinIO only; the three `install.sh` no longer call the operator installers (installers and scenarios untouched, so scenarios that expect an operator need a follow-up); not run live |
| [SPEC-012](SPEC-012-declarative-use-case-architecture.md) | Declarative Use Case Architecture | `usecase.yaml` per use case (title, description, clusters, workers, platform services); `/usecases` terminal paths; the engine runs start/status/stop and the inter-cluster validation; scenarios and manifests flattened to the use case root; Web UI shows titles |

Status meanings: **Implemented** = the behavior exists in the repository and was tested by the implementer at the API, protocol or fake-DOM level. **Partially implemented** = some parts were not done (see the document). Nothing is marked as verified in a real browser by the implementer: no browser was available. The project owner reported manual validation of the whole feature set in the SPEC-006.9 request; the individual checks are not recorded.

## Document types

- **Original specification, preserved verbatim**: the text of the request as written by the project owner, recovered from the Claude Code session transcript (`~/.claude/projects/.../*.jsonl`, outside the repository), with only the paste wrapper removed. All numbered specifications except 006.8.1 are of this kind.
- **Reconstructed specification** (SPEC-006.8.1 only): no formal original exists (the request was two chat messages, quoted verbatim). The behavior is documented from the current code.

Each document separates the original requirements (last section) from the implemented behavior, later corrections and known limitations. Behavior implemented for a requirement is described from the code and the session's test results, not copied from the request.

## Notes on the layout

- Four follow-up documents were added to the requested list because their originals exist and are distinct: `006.4.2-FIX`, `006.7.1-FIX`, `006.7.1-HOTFIX`, `006.7.1-HOTFIX-2`. The "SPEC-006.7.1 Hotfixes" row of the requested index is therefore two rows (the two UTF-8 related hotfixes), the first restoring `ui.sh` and the second fixing the actual encoding cause.
- A spec's file name does not change when the use cases were later renamed; the originals keep the old names (`single-cnpg`, `multi-cluster-dr`), which are historical.

## Requests before the numbering

Two requests preceded SPEC-006.1 and are kept here for completeness (verbatim).

<details><summary>Grafana session cookie per cluster (implemented in <code>platform/monitoring/install.sh</code>, <code>cookie_name</code>)</summary>

~~~~~text
We have successfully tested both use cases from scratch.

However, there is a Grafana authentication issue when multiple clusters are running.

Each cluster has its own Grafana instance exposed on a different localhost port.

When logging into Grafana A, then Grafana B, then Grafana C, returning to Grafana A redirects to the login page.

This appears to be a session cookie collision because browser cookies are scoped to hostname, not port.

Please implement a minimal fix:

1. Configure a unique Grafana auth.login_cookie_name for each Kind cluster.
2. Derive the cookie name deterministically from the cluster name.
3. Ensure the value is stable across Helm upgrades and container restarts.
4. Apply the configuration through the existing kube-prometheus-stack Helm values.
5. Preserve existing Grafana dashboards, data sources, credentials and dynamic ports.
6. Keep the implementation generic for any number of clusters.
7. Do not modify the previous project.

Example:

cnpg-lab-single-cnpg-1      → grafana_session_single_cnpg_1
cnpg-lab-multi-cluster-dr-1 → grafana_session_multi_cluster_dr_1
cnpg-lab-multi-cluster-dr-2 → grafana_session_multi_cluster_dr_2

Validate that three Grafana instances can remain authenticated simultaneously in the same browser.

Keep changes limited to Grafana configuration.
~~~~~

Result: each Grafana gets a deterministic `grafana_session_<cluster>` login cookie name (derived from the cluster name, stable across upgrades) so several Grafanas on `localhost` no longer log each other out. The shared `grafana_session_expiry` cookie remains shared.
</details>

<details><summary>Use case naming audit (read-only; no code change)</summary>

~~~~~text
Task: Audit Use Case Naming and Rename Compatibility

I want to verify whether the current CNPG Operator Playground architecture supports renaming a use case simply by renaming its directory.

This is an audit only. Do not modify any files or Kubernetes resources.

1. Analyze the current implementation

Inspect the relevant components:

* Makefile and use case lifecycle commands.
* Use case discovery and configuration.
* Kind cluster naming and creation.
* Kubernetes context resolution.
* Platform installation (Grafana, Prometheus, MinIO).
* CNPG operator and plugin installation.
* Scenario execution scripts.
* Cleanup and cluster deletion.

Identify where the use case name is obtained and how it propagates through the system.

2. Identify hardcoded dependencies

Search for references to existing use cases, particularly:

* single-cnpg
* multi-cluster-dr

Determine whether these references are necessary or could be derived dynamically from the directory name.

Also check for hardcoded cluster names, Kubernetes contexts, namespaces, paths and configuration values.

3. Evaluate a rename scenario

Consider the following example:

Before:
usecases/single-cnpg/
After:
usecases/cnpg-basic/

Expected behavior:

make usecase-up USECASE=cnpg-basic
make usecase-status USECASE=cnpg-basic
make usecase-down USECASE=cnpg-basic

Expected Kind cluster:

cnpg-lab-cnpg-basic-1

Determine whether these commands would work without modifying anything other than the directory name.

4. Evaluate naming convention flexibility

Check whether the cluster naming convention is centralized.

For example:

cnpg-lab-<usecase>-<cluster-index>

Determine how difficult it would be to change this convention globally without modifying individual use cases.

5. Report findings

Provide:

1. Current architecture: how use case names are resolved.
2. Rename compatibility: YES / PARTIAL / NO.
3. Hardcoded dependencies: exact files and relevant code locations.
4. Potential issues: cluster naming, contexts, scripts, cleanup, etc.
5. Recommended improvements: minimal changes required to make naming fully dynamic.
6. Impact assessment: whether these changes could affect existing use cases.

Constraints

* Read-only analysis.
* Do not modify files.
* Do not create or delete Kind clusters.
* Do not execute deployment or cleanup commands.
* Do not modify the reference project ../cnpg-operator-playground-local.
* Follow the existing KISS architecture.
* Avoid introducing unnecessary configuration files or abstractions.

Goal: Make the use case directory name the single source of truth for its identity, while keeping the cluster naming convention centralized and configurable.
~~~~~

Result: the audit concluded that cluster, context and session names derive from the use case directory name; this led to SPEC-006.7.2.
</details>
| [SPEC-013](SPEC-013-modern-terminal-ui.md) | Modern Terminal UI | `engine/lib/ui.sh` only: Catppuccin-style palette, one-line `☸ cluster-N ➜ command` prompt (live kubectl context), `◆` instructions, boxed `ui_note`, `↳  Enter to continue`. Verified with a fake kubectl and a pty; not seen in a real browser terminal. |
| [SPEC-014](SPEC-014-docker-image-edb-plugin.md) | Docker image: EDB plugin and `ll` | `kubectl cnp` 1.30.1 (official EnterpriseDB/kubectl-cnp release) next to `kubectl cnpg`; `ll` alias in the bind-mounted bashrc. Verified in throwaway containers (aarch64); the running container needs recreation |
| [SPEC-015](SPEC-015-rc1-readiness-review.md) | RC1 readiness review | Tests brought up to date, `.env.example`, use case READMEs, `CHANGELOG.md`, docs aligned; findings classified P0-P2; Git scan not possible (no repository) |
