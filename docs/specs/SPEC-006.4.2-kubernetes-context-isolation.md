# SPEC-006.4.2 — Kubernetes Context Initialization & Isolation

| | |
|---|---|
| Status | Implemented |
| Document type | Original specification, preserved verbatim |
| Source | Claude Code session transcript (project history), user message 2026-11-04T23:31:06.644Z UTC |
| Original specification | Available (see the last section) |

## Summary

Each terminal has its own selected Kubernetes context, initialized from the use case, while sharing one kubeconfig.

## Implemented behavior

- Each session has `~/.kube/terminals/<session>.yaml` holding only `current-context`. The shell exports `KUBECONFIG=<that file>:~/.kube/config`, the standard list honored by `kubectl`, `k` and `helm`; `use-context` writes only the first file.
- Initial context: cluster 1 of the use case (from the Kind naming helpers) for use case terminals; the shared default for Playground. An existing file with a context is kept.
- `kind` wrapper function and `unexport KUBECONFIG` in the Makefile keep lifecycle and Kind operations on the shared kubeconfig. The backend never sees a terminal `KUBECONFIG`.
- A notice is printed when the context's cluster does not exist yet; kubectl/helm fail with "context was not found", never falling back to another cluster.

## Implementation

- `engine/terminal.sh`, `engine/shell/bashrc`, `Makefile`.

## Later corrections and follow-ups

SPEC-006.4.2-FIX (diagnosis of sessions started before this scheme). Playground-specific handling: SPEC-006.7.1-FIX.

## Verification

Tested by the implementer at API, WebSocket-protocol and fake-DOM level (scripts kept outside the repository). No real browser was available to the implementer; the project owner reported manual validation of the features as a whole (SPEC-006.9, context section), but the individual manual checks are not recorded.

## Known limitations

- Running project scripts directly (not via `make`) inside a terminal uses the terminal's `KUBECONFIG`.
- A manual `kind create/export` in a terminal changes the shared current context (kind's own behavior), except through the `kind` wrapper.
- Terminal files are not cleaned up when a use case is deleted while no session exists.

## Original specification (verbatim)

~~~~~text
SPEC-006.4.2 — Kubernetes Context Initialization & Isolation

1. Context

The CNPG Operator Playground currently provides:

* One Docker Compose Playground container.
* Multiple Kind clusters.
* A Bash/Makefile lifecycle engine.
* FastAPI backend.
* Vanilla JavaScript frontend.
* ttyd and tmux for persistent terminal sessions.
* A permanent Playground terminal.
* One terminal per running use case.
* Sidebar Start/Stop controls.
* Colored Operation logs.

The following specifications are implemented and validated:

* SPEC-006.4 — Multi-Terminal Workspace
* SPEC-006.4.1 — Terminal Tabs Lifecycle

Current behavior

Each terminal has an independent tmux session.

A per-terminal kubeconfig mechanism was introduced to isolate kubectl context changes.

However, two problems remain:

1. Different use case terminals initially display the same Kubernetes context.
2. Helm may use the shared kubeconfig instead of the terminal-specific context.

This creates inconsistent behavior between terminals and Kubernetes tools.

2. Objective

Implement consistent Kubernetes context management across all terminal sessions.

Each use case terminal must automatically start with its corresponding Kubernetes context, and kubectl and Helm must always use the same context.

The solution must:

* Initialize the appropriate context automatically.
* Isolate context changes between terminals.
* Keep kubectl, k and Helm consistent.
* Preserve access to all available Kind clusters.
* Support dynamically created and deleted clusters.
* Preserve existing tmux sessions.
* Avoid modifying the shared kubeconfig’s active context.
* Avoid changing existing provisioning logic.

Keep the implementation KISS.

3. Expected Behavior

3.1 Default Kubernetes context

Terminal    Initial Kubernetes Context
Playground    Shared default context
single-cnpg    kind-cnpg-lab-single-cnpg-1
multi-cluster-dr    kind-cnpg-lab-multi-cluster-dr-1

These are examples, not hardcoded values.

Derive the context dynamically from the existing Kind naming conventions and helper functions.

For a multi-cluster use case, select cluster 1 by default.

3.2 Consistency between tools

Within the single-cnpg terminal:

kubectl config current-context
# kind-cnpg-lab-single-cnpg-1
helm list -A
# Must query kind-cnpg-lab-single-cnpg-1

Within the multi-cluster-dr terminal:

kubectl config current-context
# kind-cnpg-lab-multi-cluster-dr-1
helm list -A
# Must query kind-cnpg-lab-multi-cluster-dr-1

The k shortcut must behave exactly like kubectl.

3.3 Context switching

Within the multi-cluster-dr terminal:

kubectl config use-context kind-cnpg-lab-multi-cluster-dr-2

Expected behavior:

kubectl config current-context
# kind-cnpg-lab-multi-cluster-dr-2
helm list -A
# Must now query kind-cnpg-lab-multi-cluster-dr-2

No additional Helm configuration should be required.

Changing context in one terminal must not affect another terminal.

3.4 No automatic switching during navigation

Selecting another browser tab must not change Kubernetes contexts.

Context initialization happens when a terminal session is created, not every time the user selects its tab.

An explicitly selected context must remain unchanged.

4. Inspect Existing Implementation

Before modifying code, inspect:

* engine/terminal.sh
* engine/shell/bashrc
* engine/shell/tmux.conf
* engine/infrastructure/kind/common.sh
* engine/usecase-list.sh
* Existing per-terminal kubeconfig files.
* Shared ~/.kube/config.
* Current KUBECONFIG handling.
* Existing kubectl wrapper/function.
* Existing Helm invocation.
* tmux session initialization.

Determine the root cause of the current behavior.

Explain the proposed solution before implementing it.

5. Kubernetes Configuration Architecture

5.1 Prefer native KUBECONFIG

Prefer using the standard KUBECONFIG environment variable.

Both kubectl and Helm should use the same configuration automatically.

Avoid separate wrappers for kubectl and Helm unless strictly necessary.

5.2 Shared cluster definitions

The shared kubeconfig remains the authoritative source for:

* Cluster definitions.
* Credentials.
* Context definitions.
* Newly created Kind clusters.

Each terminal must have its own active context.

Do not duplicate cluster credentials unnecessarily.

5.3 Per-terminal context isolation

Maintain independent context selection for:

* Playground.
* Each use case terminal.

For example:

Playground       → context A
single-cnpg      → context B
multi-cluster-dr → context C

Changing context B must not modify A or C.

5.4 KUBECONFIG merge behavior

Investigate whether a configuration such as:

export KUBECONFIG="$HOME/.kube/terminals/<session>.yaml:$HOME/.kube/config"

can reliably provide:

* Per-terminal current-context.
* Shared cluster definitions.
* Native kubectl behavior.
* Native Helm behavior.

Do not assume this configuration works without testing it.

In particular, verify:

* How kubectl merges kubeconfig files.
* Where kubectl config use-context writes changes.
* Whether the shared kubeconfig remains unchanged.
* Whether Helm resolves the same context.
* Whether newly created Kind clusters become visible.

If this approach is unreliable, choose another minimal solution and explain why.

6. Automatic Context Initialization

6.1 Fresh terminal sessions

When a new use case terminal is created:

1. Identify the corresponding use case.
2. Determine its associated Kind clusters.
3. Select cluster 1 as the initial Kubernetes context.
4. Initialize the terminal-specific configuration.
5. Ensure kubectl and Helm use that context.

Do not hardcode use case names.

Reuse existing Kind naming helpers.

6.2 Playground terminal

The Playground terminal must use the shared default context when first created.

Subsequent context changes must remain isolated from the shared kubeconfig and other terminals.

6.3 Existing tmux sessions

Existing sessions must be preserved.

Requirements:

* Do not kill existing tmux sessions.
* Do not interrupt running commands.
* Do not reset shell variables or working directories.
* Do not overwrite an explicitly selected context.
* Do not silently reset existing kubeconfig files.

If an existing session cannot safely adopt the new configuration without restarting its shell, document the limitation and provide a non-destructive migration procedure.

Do not automatically terminate sessions to apply the change.

6.4 Missing clusters

If the expected Kind cluster does not exist:

* Do not silently select an unrelated cluster.
* Report the missing context clearly.
* Allow the terminal to remain usable.
* Allow the correct context to become available when the cluster is created.

Do not change the global context as a fallback.

7. Dynamic Cluster Discovery

Kind clusters can be created and deleted while terminal sessions remain open.

Requirements

An existing terminal must be able to discover newly created clusters without restarting tmux.

For example:

kubectl config get-contexts

must display newly available Kind contexts.

The user must be able to select one:

kubectl config use-context <new-context>

Both kubectl and Helm must then target that cluster.

When a cluster is deleted:

* Its stale context must not silently redirect commands to another cluster.
* Other clusters must remain accessible.
* The terminal’s selected context must not change unexpectedly.

Do not modify Kind provisioning solely to implement this feature.

8. Helm Integration

Helm must use the terminal’s active Kubernetes context by default.

Verify:

kubectl config current-context
helm list -A

Both must target the same cluster.

Also verify that explicit context selection continues to work:

helm --kube-context <context> list -A

Do not override explicit Helm options.

Do not introduce Helm-specific state that can become inconsistent with kubectl.

9. Existing Scripts Compatibility

Existing use case scripts may invoke:

* kubectl
* helm
* kind
* Explicit Kubernetes contexts.
* Shared kubeconfig configuration.

Requirements:

* Preserve all existing provisioning behavior.
* Preserve FastAPI Start/Stop operations.
* Preserve explicit --context and --kube-context arguments.
* Do not accidentally pass terminal-specific configuration to backend lifecycle operations.
* Do not modify existing use case scripts unless a demonstrated issue requires it.

Important

The terminal environment and the backend provisioning environment must remain independent.

Changing context in an interactive terminal must not affect the backend’s Start/Stop operations.

10. tmux Session Persistence

Preserve existing behavior:

* Browser refresh does not reset the context.
* Switching tabs does not reset the context.
* WebSocket reconnect does not reset the context.
* Stopping a use case does not delete its terminal kubeconfig.
* Restarting a use case reuses its existing terminal context where possible.
* A context explicitly selected by the user is never overwritten automatically.

No changes to ttyd networking or WebSocket behavior.

11. Validation

Use temporary terminal sessions and clusters.

Do not interrupt existing user sessions.

Test A — Automatic initialization

Create fresh terminal sessions for:

* Playground.
* A running single-cluster use case.
* A running multi-cluster use case.

Verify that each starts with the expected Kubernetes context.

Test B — kubectl / Helm consistency

For each terminal:

kubectl config current-context
kubectl get namespaces
helm list -A

Verify that kubectl and Helm target the same cluster.

Test C — Independent contexts

1. Create two independent terminal sessions.
2. Select different contexts.
3. Verify each terminal retains its own context.
4. Verify the shared kubeconfig’s active context remains unchanged.

Test D — Dynamic cluster discovery

1. Open a terminal.
2. Create a temporary Kind cluster.
3. Verify the terminal discovers the new context.
4. Switch to it.
5. Verify kubectl and Helm can access it.
6. Delete the temporary cluster.
7. Verify other contexts remain accessible.

Test E — Persistence

1. Select a context.
2. Disconnect the terminal.
3. Reconnect.
4. Verify the context is unchanged.
5. Verify Helm still uses the same context.

Test F — Existing sessions

Verify that existing tmux sessions:

* Remain alive.
* Preserve their working directory.
* Preserve running commands.
* Preserve explicitly selected Kubernetes contexts.

Do not kill existing sessions for testing.

Test G — Regression

Verify:

* Terminal tabs.
* Sidebar discovery.
* Start/Stop buttons.
* Colored Operation logs.
* ttyd WebSocket connectivity.
* Existing Kind clusters remain untouched.
* Backend provisioning still works.

12. Constraints

* KISS architecture.
* Prefer native Kubernetes client configuration.
* No additional Docker containers.
* No additional frontend frameworks.
* No database.
* No changes to Kind provisioning logic.
* No changes to use case scripts unless strictly necessary.
* No modifications to the reference project.
* Preserve existing ttyd/tmux architecture.
* Preserve the Docker network initialization fix.
* Preserve existing Start/Stop operations.

13. Deliverables

Provide:

1. Root cause of the current behavior.
2. Selected architecture and rationale.
3. Modified files.
4. Automatic context initialization behavior.
5. kubectl and Helm consistency guarantees.
6. Existing session migration behavior.
7. Validation results.
8. Known limitations.

Implementation Instructions

First inspect the existing implementation.

Explain the root cause and the proposed solution.

Then implement SPEC-006.4.2 only.

Prioritize:

1. Automatic context initialization per use case.
2. Native kubectl and Helm consistency.
3. Context isolation between terminals.
4. Dynamic cluster discovery.
5. Preservation of existing tmux sessions.

Do not implement bottom status bar enhancements or Docker resource monitoring yet.

Do not modify unrelated components.
~~~~~
