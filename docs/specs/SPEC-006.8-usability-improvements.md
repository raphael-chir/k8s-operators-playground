# SPEC-006.8 — Playground Usability Improvements

| | |
|---|---|
| Status | Partially implemented: Vim and Grafana done, MinIO limitation documented |
| Document type | Original specification, preserved verbatim |
| Source | Claude Code session transcript (project history), user message 2026-11-05T12:02:54.591Z UTC |
| Original specification | Available (see the last section) |

## Summary

Vim with syntax highlighting, Grafana without login, and a convenient MinIO Console administrator access.

## Implemented behavior

- Vim: the full `vim` package replaces `vim-tiny`; settings in `engine/shell/vimrc` (version-controlled, loaded through `/root/.vimrc` written by the Dockerfile): syntax and filetype detection (including extension-less scripts with a shebang), line numbers, 2-space indentation (4 for shell), search highlighting, dark background. Verified in an image-built throwaway container and with colors through tmux.
- Grafana: `grafana.ini` `[auth.anonymous]` with `enabled = true` and `org_role = Viewer` in `platform/monitoring/values.yaml` (chart-rendered config verified). On the running clusters it was confirmed over HTTP: anonymous `/api/search` 200, anonymous admin endpoints 403, `admin`/`password` still valid.
- MinIO: investigated only. The installed build (`RELEASE.2025-09-07`) offers only the password form; a login-free administrator session would need OIDC or LDAP with an external identity provider. Its Console has no user, policy or group management (those endpoints return 404). Nothing was changed; credentials and buckets are untouched. The requested "MinIO administrator access improvements" are therefore **not** implemented.

## Implementation

- `Dockerfile`, `engine/shell/vimrc`, `platform/monitoring/values.yaml`, `README.md`.

## Later corrections and follow-ups

None recorded beyond the general ones in `docs/specs/README.md`.

## Verification

Vim: throwaway container and private tmux rendering checks. Grafana: throwaway Grafana of the same version, then read-only HTTP checks on all three live clusters. MinIO: read-only Console API probes. No real browser was available to the implementer.

## Known limitations

- Vim needs the rebuilt image (container recreation).
- Grafana: only clusters installed or upgraded after the values change have anonymous access; a Helm upgrade restarts Grafana (no persistent volume, so manual dashboard changes are lost).
- MinIO user/policy administration requires `mc admin` (not shipped).

## Original specification (verbatim)

~~~~~text
SPEC-006.8 — Playground Usability Improvements

1. Context

The CNPG Operator Playground provides a local Kubernetes demonstration environment based on:

* Docker Compose
* Kind
* Bash and Make
* FastAPI
* Vanilla JavaScript
* ttyd and tmux
* CloudNativePG
* Grafana
* MinIO

The Playground currently supports two dynamically discovered use cases:

* cnpg-standard
* cnpg-distributed-topology

Both use cases can be started and stopped independently through the Web UI.

The objective of SPEC-006.8 is to improve the daily user experience without changing the existing architecture.

This specification contains three independent improvements:

1. Vim syntax highlighting and editor configuration.
2. Grafana authentication-free access.
3. MinIO Console administrator access with simplified authentication.

Implement them incrementally.

⸻

PART A — Vim Configuration

2. Objective

Provide a fully functional Vim editor in every Playground terminal.

Vim must support syntax highlighting for:

* Kubernetes YAML manifests.
* Bash scripts.
* Shell scripts.
* JSON files.

The editor must work correctly inside the existing ttyd/tmux environment.

3. Installation

Inspect the current Dockerfile and installed packages.

Verify whether Vim is already installed.

If Vim is missing or lacks syntax highlighting support, install the appropriate full Vim package.

Avoid installing unnecessary editor plugins or dependencies.

Do not replace Vim with Neovim.

4. Vim Configuration

Provide a persistent default Vim configuration.

Recommended settings:

syntax on
filetype plugin indent on
set number
set autoindent
set expandtab
set tabstop=2
set shiftwidth=2
set softtabstop=2
set hlsearch
set incsearch
set showmatch
set background=dark

YAML-specific settings

Use two-space indentation:

autocmd FileType yaml setlocal expandtab tabstop=2 shiftwidth=2 softtabstop=2

Bash-specific settings

Use four-space indentation:

autocmd FileType sh setlocal expandtab tabstop=4 shiftwidth=4 softtabstop=4

Preserve automatic syntax detection.

Files ending in .yaml, .yml, .sh and .json must be highlighted appropriately.

Bash scripts without a .sh extension should be recognized when they contain an appropriate shebang.

5. Terminal Compatibility

Verify compatibility with:

* ttyd
* tmux
* UTF-8
* ANSI colors
* Existing terminal theme
* Existing Killercoda-style Bash prompt

Do not modify the terminal rendering fix introduced in SPEC-006.7.1:

tmux -u attach-session

Verify that Vim colors render correctly in both the Playground terminal and use case terminals.

6. Persistence

Vim must remain available after:

* Restarting the Playground container.
* Recreating the Playground container.
* Rebuilding the Docker image.
* Starting a new terminal session.

Do not rely on manual configuration inside a running container.

Prefer a Dockerfile-managed installation and a version-controlled Vim configuration.

Avoid modifying the user’s host configuration.

7. Validation

Verify:

vim --version

Check syntax highlighting support.

Test:

vim test.yaml
vim test.sh
vim test.json

Verify:

* Correct filetype detection.
* Syntax highlighting.
* Line numbers.
* Automatic indentation.
* Correct rendering inside ttyd/tmux.

Remove temporary test files afterward.

⸻

PART B — Grafana Anonymous Access

8. Objective

Opening Grafana from the Playground Web UI must provide direct access to dashboards without requiring a username or password.

The user must be able to:

* Browse dashboards.
* Inspect PostgreSQL and Kubernetes metrics.
* Explore existing panels.
* Change time ranges.
* Use dashboard variables.

No login screen should appear.

9. Authentication Configuration

Use Grafana’s native anonymous authentication.

Recommended configuration:

[auth.anonymous]
enabled = true
org_role = Viewer

The anonymous user must have Viewer permissions.

Do not enable anonymous Administrator access.

Preserve existing administrator credentials for operations requiring elevated privileges.

10. Helm Integration

Inspect the existing Grafana deployment configuration.

Grafana is currently deployed through the Playground monitoring stack.

Identify the existing Helm values and installation scripts.

Implement anonymous access through the existing configuration mechanism.

Prefer Helm values rather than modifying a running Grafana Pod manually.

Do not introduce a separate Grafana deployment.

11. Multi-Cluster Support

Both use cases must be supported.

For cnpg-standard:

* One Grafana instance.

For cnpg-distributed-topology:

* One Grafana instance per Kind cluster.

Each Grafana instance must allow anonymous Viewer access.

Preserve dynamic port discovery.

Do not hardcode host ports.

12. Validation

Verify:

1. Grafana is running.
2. The dynamically discovered URL is correct.
3. Opening the URL in a fresh browser session does not require login.
4. Dashboards are accessible.
5. Metrics remain available.
6. Existing Grafana credentials remain valid for administration.

Do not delete existing dashboards or configuration.

⸻

PART C — MinIO Console Authentication

13. Objective

Provide convenient access to the MinIO Console directly from the Playground Web UI.

The user wants full administrator capabilities, including:

* Creating and deleting buckets.
* Uploading and downloading objects.
* Deleting objects.
* Managing users.
* Managing access policies.
* Managing permissions.
* Performing all administration operations supported by the installed MinIO Console.

The preferred experience is to open the Console without manually entering credentials.

However, this must be implemented using a supported authentication mechanism.

14. Mandatory Technical Investigation

Before modifying MinIO, inspect:

1. Installed MinIO server version.
2. MinIO Docker image.
3. Helm chart and values.
4. Existing authentication configuration.
5. Existing administrator credentials management.
6. MinIO Console authentication capabilities.
7. Existing Console URL and port discovery.

Determine whether the installed MinIO version supports a documented mechanism for automatic administrator authentication.

Investigate supported options such as:

* Existing authenticated sessions.
* Supported SSO/OIDC integration.
* Other officially documented authentication mechanisms.

Do not assume that MinIO supports anonymous administrator access.

Required report

Before implementation, report:

* Current MinIO version.
* Current authentication mechanism.
* Available supported options.
* Recommended solution.
* Security implications.
* Whether a login-free administrator experience is technically achievable.

15. Security Constraints

Do not implement:

* Administrator credentials embedded in URLs.
* Credentials stored in frontend JavaScript.
* Credentials exposed through unauthenticated API endpoints.
* Browser-side password injection.
* Unsupported authentication bypasses.
* A custom reverse proxy that impersonates the administrator.
* Anonymous administrator access.

Do not disable MinIO authentication.

Do not expose administrator credentials through the Playground frontend.

This is a local demonstration environment, but administrator access must still use a supported authentication mechanism.

16. Preferred Implementation

If a supported and reasonably simple automatic authentication mechanism exists:

* Propose it.
* Explain its configuration.
* Explain its security implications.
* Implement it only if it does not require major architectural changes.

If no suitable mechanism exists:

* Keep MinIO’s native authentication.
* Preserve administrator access.
* Preserve existing credentials.
* Do not introduce a workaround.

In that case, report the limitation clearly.

A manual administrator login is acceptable if the alternative would require an unsupported or insecure implementation.

17. Multi-Cluster Support

MinIO must continue working in:

* cnpg-standard
* cnpg-distributed-topology

For distributed topology, each Kind cluster must retain its own MinIO instance.

Preserve:

* Existing buckets.
* S3 endpoints.
* Credentials.
* Backup configurations.
* Barman Cloud Plugin integration.
* Dynamic Console URLs.
* Dynamic S3 ports.

Do not change MinIO storage architecture.

18. Validation

Verify:

1. MinIO Console is accessible.
2. Administrator authentication works.
3. Buckets can be listed.
4. Administrator permissions remain intact.
5. Existing S3 API access remains functional.
6. CNPG backup configurations remain compatible.
7. No credentials are exposed in the frontend.

Do not create or delete real buckets during automated validation.

Use read-only checks whenever possible.

⸻

PART D — Implementation Strategy

19. Recommended Sequence

Step 1 — Preflight

Inspect the current implementation.

Identify:

* Dockerfile and Vim installation.
* Terminal configuration.
* Grafana Helm values.
* MinIO image and authentication settings.
* Existing running clusters and services.

Do not modify running resources during this step.

Step 2 — Vim

Implement the persistent Vim configuration.

Validate YAML, Bash and JSON syntax highlighting.

A Playground image rebuild may be necessary.

If rebuilding would interrupt active terminal sessions, explain the impact and request authorization first.

Step 3 — Grafana

Implement native anonymous Viewer access.

Prefer changes to the Helm configuration used for future deployments.

Do not automatically reinstall or restart running Grafana instances.

If existing instances require a Helm upgrade or restart, report the impact before proceeding.

Step 4 — MinIO

Investigate supported authentication mechanisms.

Implement only a supported, minimal solution.

If automatic administrator authentication is not reasonably achievable, preserve the current login mechanism and report the limitation.

Step 5 — Validation

Run non-destructive tests.

Provide manual browser validation steps.

⸻

PART E — Constraints

20. General Requirements

* Follow KISS principles.
* Minimal modifications.
* No architectural redesign.
* No new frontend framework.
* No new database.
* No unnecessary dependencies.
* No changes to CNPG scenario logic.
* No changes to Kind cluster topology.
* No hardcoded service ports.
* No changes to dynamic use case discovery.
* Preserve terminal isolation.
* Preserve Kubernetes contexts.
* Preserve the existing tmux UTF-8 fix.
* Preserve existing ui.sh behavior and rendering.
* Do not modify the original reference repository.
* Do not delete or recreate existing clusters.
* Do not terminate active tmux sessions.
* Do not delete MinIO buckets.
* Do not overwrite existing Grafana dashboards.

21. Scope

Implement only:

1. Vim syntax highlighting and configuration.
2. Grafana anonymous Viewer access.
3. MinIO authentication investigation and, if feasible, supported automatic authentication.

Do not implement:

* Template management.
* Use case cloning.
* Use case renaming.
* Use case deletion.
* New Kubernetes scenarios.
* Additional monitoring features.
* Playground stabilization.

⸻

PART F — Deliverables

22. Final Report

Provide:

Vim

* Installed Vim version.
* Configuration location.
* Supported syntax highlighting.
* Validation results.

Grafana

* Configuration changes.
* Authentication behavior.
* Multi-cluster compatibility.
* Validation results.

MinIO

* Installed version.
* Supported authentication mechanisms.
* Selected solution or documented limitation.
* Administrator permissions.
* Security considerations.

General

* Modified files.
* Tests performed.
* Tests not performed.
* Required rebuilds or restarts.
* Manual browser validation steps.

23. Acceptance Criteria

SPEC-006.8 is complete when:

* Vim is available in all Playground terminals.
* YAML manifests have syntax highlighting.
* Bash scripts have syntax highlighting.
* JSON files have syntax highlighting.
* Vim configuration survives container recreation.
* Grafana opens without login.
* Grafana dashboards are accessible with Viewer permissions.
* MinIO administrator functionality remains available.
* MinIO automatic authentication is implemented only if a supported and maintainable solution exists.
* Existing use cases continue working.
* No Kubernetes resources or data are lost.

Final Instruction

Start with a read-only preflight.

Implement Vim and Grafana incrementally.

Investigate MinIO authentication before changing it.

Do not interrupt running clusters or terminal sessions without explicit authorization.

Preserve the existing Playground architecture.

Implement SPEC-006.8 only.
~~~~~
