# SPEC-006.9 — Playground Stabilization & Specifications History

| | |
|---|---|
| Status | Implemented, pending the project owner's manual browser validation |
| Document type | Original specification, preserved verbatim |
| Source | Claude Code session transcript (project history), user message 2026-11-05T13:03:48.810Z UTC |
| Original specification | Available (see the last section) |

## Summary

Create the specifications history, document the theme enhancement, and review the Playground for small correctness and documentation issues without adding features.

## Implemented behavior

- `docs/specs/` holds one document per specification (original text preserved verbatim, recovered from the Claude Code transcript) and an index with accurate statuses.
- SPEC-006.8.1 (themes) is documented from the code, not assumed: persistence is `localStorage` key `theme` (confirmed), default light.
- Stabilization review (code, lifecycle, terminals, resources, documentation) with small fixes only; findings below. No cluster, session, kubeconfig, bucket or data was deleted, restarted or modified.

## Implementation

Fixes applied:
1. **Status bar vs kubectl mismatch.** kubectl writes `current-context: ""` into a terminal's file when the selection is dropped, and then resolves the shared context. `web/app.py` read the literal `""` and showed "No context" while the shell used `kind-cnpg-lab-cnpg-standard-1`. Parsing now treats empty and quoted values correctly (`_current_context`).
2. **Obsolete docstring** of `web/app.py` (it described only discovery and start/stop) now lists the real API.
3. **`.gitignore`** now ignores `__pycache__/` and `*.swp` (a `web/__pycache__` directory and a Vim swap file existed in the tree).
4. **README** corrected where it no longer matched the implementation: introduction ("first iteration, no CNPG"), start instructions (Web UI on 8080), prompt description, directory structure, cleanup commands (`make usecase-down`), "Kind node ports are not published" (they are published on `127.0.0.1`), tmux persistence note, a duplicated memory remark.
5. **`docs/architecture.md`**: diagram and Compose description now include the Web UI/FastAPI, plus a Web API overview table and the localhost warning for both ports.

## Later corrections and follow-ups

- `web/app.py`, `.gitignore`, `README.md`, `docs/architecture.md`, `docs/specs/*`.

## Verification

Non-destructive tests, all passing: Bash syntax of 27 scripts, Python and JavaScript syntax; discovery script vs API; all API endpoints plus negative cases (404/400, no start/stop effect); `make -n` resolution; live tmux options (mouse off, no alternate screen, `tmux -u`, all clients UTF-8); Playground/use case context logic on scratch homes; prompt, scenario rendering (real `cnpg-standard` scenario, read-only steps) and clipboard-mode checks on private tmux servers; Vim filetypes in the live container; theme logic (fake DOM) and served assets; Docker resource figures vs `docker stats`/`docker info`; Grafana anonymous Viewer and MinIO Console reachability on all three live clusters. Not tested: anything in a real browser.

## Known limitations

Findings left unchanged (reported to the project owner):
- `GET /api/usecases/{unknown}/operation` answers `200 {"state": "idle"}` while other endpoints answer 404 (harmless; the page only asks for known names).
- Fixed NodePorts 30082/30084 appear in `web/app.py` and `engine/usecase-clusters.sh`, besides the chart values and `cluster.yaml` (documented duplication).
- Cleanup candidates, none removed: old terminal files `playground-uc-multi-cluster-dr.yaml` and `playground-uc-single-cnpg.yaml` (no sessions); stale context `kind-cnpg-lab-pgd4k-single-group-1`; `.Makefile.swp` in the repository root (a Vim swap file, possibly an open editor); `web/__pycache__`; three unused anonymous Docker volumes and the `minikube` volume (not Playground resources); two untagged `kindest/node` images.

## Original specification (verbatim)

~~~~~text
SPEC-006.9 — Playground Stabilization & Specifications History

1. Context

The CNPG Operator Playground has reached a functional state.

The following features have been implemented and manually validated:

* Dynamic use case discovery.
* Web UI Start/Stop lifecycle.
* Colored operation logs.
* Multi-terminal workspace using ttyd and tmux.
* Independent Kubernetes contexts per terminal.
* Dynamic status bar with Grafana and MinIO links.
* Docker resource monitoring.
* Terminal UX improvements.
* UTF-8 rendering fix for scenario scripts.
* Use case renaming.
* Vim with YAML, Bash and JSON syntax highlighting.
* Grafana access without manual login.
* MinIO administrator access improvements.
* EDB and Dark themes with a theme switcher.

The current use cases are:

* cnpg-standard
* cnpg-distributed-topology

We now want to stabilize the Playground and maintain a structured history of its specifications.

⸻

PART A — Specifications History

2. Objective

Create a version-controlled specifications history inside the repository.

The documentation must provide:

1. A chronological list of specifications.
2. A description of each specification.
3. Its implementation status.
4. The corresponding implementation changes.
5. Known limitations, when applicable.
6. A trace of subsequent modifications.

The goal is to preserve the evolution of the project and make future maintenance easier.

3. Directory Structure

Create:

docs/
├── architecture.md
└── specs/
    ├── README.md
    ├── SPEC-006.1-web-ui-foundation.md
    ├── SPEC-006.2-dynamic-usecase-discovery.md
    ├── SPEC-006.3-sidebar-lifecycle.md
    ├── SPEC-006.3.1-colored-operation-logs.md
    ├── SPEC-006.4-multi-terminal-workspace.md
    ├── SPEC-006.4.1-terminal-tabs-lifecycle.md
    ├── SPEC-006.4.2-kubernetes-context-isolation.md
    ├── SPEC-006.5-dynamic-status-bar.md
    ├── SPEC-006.6-docker-resource-monitoring.md
    ├── SPEC-006.7.1-playground-ux-improvements.md
    ├── SPEC-006.7.2-usecase-renaming.md
    ├── SPEC-006.8-usability-improvements.md
    ├── SPEC-006.8.1-ui-themes.md
    └── SPEC-006.9-playground-stabilization.md

Also document the two UTF-8 hotfixes associated with SPEC-006.7.1.

Use consistent naming conventions.

Do not create duplicate specification documents.

⸻

4. Specifications Index

Create docs/specs/README.md.

Include a table containing:

ID    Specification    Status    Notes
SPEC-006.1    Web UI Foundation    Implemented    Initial Web interface
SPEC-006.2    Dynamic Use Case Discovery    Implemented    Directory-based discovery
SPEC-006.3    Sidebar Lifecycle    Implemented    Start/Stop
SPEC-006.3.1    Colored Operation Logs    Implemented    Operation output
SPEC-006.4    Multi-Terminal Workspace    Implemented    ttyd/tmux
SPEC-006.4.1    Terminal Tabs Lifecycle    Implemented    Persistent sessions
SPEC-006.4.2    Kubernetes Context Isolation    Implemented    Independent kubeconfigs
SPEC-006.5    Dynamic Status Bar    Implemented    Contexts and service links
SPEC-006.6    Docker Resource Monitoring    Implemented    CPU, RAM, nodes
SPEC-006.7.1    Playground UX Improvements    Implemented    Terminal UX
SPEC-006.7.1 Hotfixes    Terminal Rendering    Implemented    UTF-8 correction
SPEC-006.7.2    Use Case Renaming    Implemented    Canonical names
SPEC-006.8    Usability Improvements    Implemented    Vim, Grafana, MinIO
SPEC-006.8.1    UI Themes    Implemented    EDB / Dark
SPEC-006.9    Playground Stabilization    In Progress    Tests and documentation

Statuses must reflect the actual implementation state.

If a feature cannot be verified, mark it accordingly rather than assuming completion.

⸻

5. Historical Accuracy

IMPORTANT:

Do not invent original specification content.

First search for existing specifications in:

* Repository documentation.
* Project files.
* Available Claude Code conversation history.
* Existing implementation notes.

If the original specification is available, preserve its exact content where practical.

If it is unavailable, create a clearly identified reconstruction based on the current implementation.

Each reconstructed document must contain:

Document type: Reconstructed specification
Source: Current implementation and available project history
Original specification: Not available

Distinguish between:

* Original requirements.
* Implemented behavior.
* Later corrections.
* Known limitations.

Do not present reconstructed requirements as verbatim historical prompts.

⸻

PART B — EDB / Dark Theme Enhancement

6. Latest Implemented Enhancement

Document the latest user-requested improvement:

SPEC-006.8.1 — EDB / Dark Theme Switching

The Playground now supports two visual themes:

1. EDB Theme.
2. Dark Theme.

The user can switch between them directly from the Web UI.

Expected behavior

* Immediate theme switching.
* No Playground restart.
* No terminal session interruption.
* Consistent styling across the interface.
* Persistent theme selection across page reloads.

Inspect the actual implementation and document:

* Theme switcher location.
* CSS variables and styling mechanism.
* Theme persistence mechanism.
* Default theme.
* Affected UI components.

Do not assume that localStorage is used unless confirmed by the code.

Validation

Verify that:

* Both themes are available.
* Switching works.
* The selected theme persists as implemented.
* Terminal functionality remains unchanged.

Do not redesign the themes.

Do not modify the existing EDB branding.

This specification is for documenting and validating the already implemented feature.

⸻

PART C — Playground Stabilization

7. Objective

Stabilize the current implementation before adding new features.

No architectural redesign.

No new functional features.

8. Code Quality

Review:

* Bash scripts.
* FastAPI backend.
* JavaScript frontend.
* Docker configuration.
* Terminal lifecycle management.

Identify:

* Duplicated code.
* Unnecessary complexity.
* Hardcoded assumptions.
* Error handling gaps.
* Inconsistent naming.
* Obsolete comments.

Apply only small, justified fixes.

Avoid broad refactoring.

9. Lifecycle Reliability

Validate:

* Playground startup.
* Dynamic use case discovery.
* Use case Start/Stop.
* Operation logs.
* Terminal creation and persistence.
* Kubernetes context isolation.
* Status bar.
* Docker resource monitoring.

Do not automatically start or stop real clusters during this review.

10. Terminal Reliability

Verify:

* ttyd/tmux connectivity.
* UTF-8 rendering.
* Original ui.sh presentation.
* Killercoda-style prompt.
* Vim syntax highlighting.
* Terminal working directories.
* Kubernetes context isolation.

Preserve:

tmux -u attach-session

Do not modify the original scenario UI presentation.

11. Resource Cleanup

Identify:

* Obsolete Kubernetes contexts.
* Stale terminal kubeconfig files.
* Orphaned tmux sessions.
* Temporary files.
* Unused Docker resources.

Report findings before cleanup.

Do not automatically delete resources.

12. Documentation

Review and update:

* Main README.
* Installation instructions.
* Architecture documentation.
* Use case documentation.
* Specifications history.

Ensure documentation matches the actual implementation.

⸻

PART D — Validation

13. Non-Destructive Tests

Run:

* Bash syntax validation.
* Python syntax validation.
* JavaScript syntax validation.
* Use case discovery tests.
* API endpoint checks.
* Terminal configuration checks.
* Docker resource monitoring checks.

Do not:

* Delete clusters.
* Restart running clusters.
* Terminate tmux sessions.
* Delete MinIO buckets.
* Modify PostgreSQL data.
* Reset kubeconfigs.

14. Manual Validation

Provide a concise checklist for browser testing:

* EDB / Dark theme switching.
* Sidebar Start/Stop.
* Terminal tabs.
* Scenario rendering.
* Grafana.
* MinIO.
* Status bar.
* Docker resource monitoring.

The user will perform manual validation.

Do not claim that browser rendering has been tested unless it actually has.

⸻

PART E — Deliverables

15. Expected Deliverables

1. Complete specifications index.
2. Individual specification documents.
3. Documentation of the EDB / Dark theme enhancement.
4. Updated architecture documentation.
5. Stabilization findings.
6. Minimal corrective changes, if required.
7. Non-destructive test results.
8. Manual validation checklist.

16. Constraints

* KISS.
* Preserve the current architecture.
* Preserve both use cases.
* No new dependencies unless strictly necessary.
* No new features.
* No destructive operations.
* No automatic cluster recreation.
* No terminal session termination.
* No changes to PostgreSQL or CNPG scenario logic.
* Do not modify the original reference repository.

Final Instructions

Start with a read-only inventory of the existing documentation and implementation.

Create the specifications history using available historical sources.

Clearly identify reconstructed specifications.

Document the latest EDB / Dark theme enhancement.

Then perform a non-destructive stabilization review.

Report issues before making any potentially disruptive changes.

Implement SPEC-006.9 only.
~~~~~
