# SPEC-006.4.2-FIX — Kubernetes Context Initialization & Helm Consistency

| | |
|---|---|
| Status | Resolved: diagnosed, no code change |
| Document type | Original specification, preserved verbatim |
| Source | Claude Code session transcript (project history), user message 2026-11-05T08:41:15.079Z UTC |
| Original specification | Available (see the last section) |

## Summary

A bug report: a use case terminal started on another use case's context and Helm ignored the terminal context.

## Implemented behavior

- The investigation found that the three tmux shells had started before the SPEC-006.4.2 code was installed (older `bashrc` with a `kubectl`-only wrapper and an older `terminal.sh` that copied the shared context). A running Bash never re-reads `bashrc`.
- A shell started with the current code was verified: `KUBECONFIG` is set, `kubectl`, `k` and `helm` agree, and `helm list -A` equals `helm --kube-context <expected> list -A` (release names and timestamps).
- Existing sessions were not reset. The documented non-destructive correction is `source ~/.bashrc` (plus `kubectl config use-context ...`).

## Implementation

No code was changed for this specification.

## Later corrections and follow-ups

A related empty-value bug (`current-context: ""` written by kubectl) was fixed in SPEC-006.9.

## Verification

Verified as described above with a scratch terminal file and real clusters (read-only).

## Known limitations

- A shell started before the scheme stays inconsistent until it runs `source ~/.bashrc`.

## Original specification (verbatim)

~~~~~text
SPEC-006.4.2-FIX — Kubernetes Context Initialization & Helm Consistency

1. Context

The CNPG Operator Playground uses:

* Docker Compose.
* Kind clusters.
* FastAPI and vanilla JavaScript.
* ttyd + tmux for persistent terminal sessions.
* Independent terminals for each running use case.
* Per-terminal Kubernetes context isolation.

SPEC-006.4.2 introduced Kubernetes context isolation, but user testing revealed two remaining issues.

This specification is a targeted bug fix.

Do not redesign the existing architecture.

2. Problems Identified

Problem A — Incorrect initial Kubernetes context

When starting two use cases:

* single-cnpg
* multi-cluster-dr

The single-cnpg terminal correctly initializes its context:

kind-cnpg-lab-single-cnpg-1

However, the multi-cluster-dr terminal initially points to:

kind-cnpg-lab-single-cnpg-1

instead of:

kind-cnpg-lab-multi-cluster-dr-1

Manually executing:

kubectl config use-context kind-cnpg-lab-multi-cluster-dr-1

works correctly.

The context change remains isolated from the single-cnpg terminal.

Therefore, context isolation works, but automatic initialization is inconsistent.

Problem B — Helm ignores the terminal context

In both terminals:

echo "$KUBECONFIG"

returns an empty value.

The command:

kubectl config current-context

returns the correct terminal-specific context after manual selection.

However:

helm list -A

returns the same Helm releases in both terminals.

The deployment timestamps are identical.

For example:

cert-manager  08:27:59
cnpg          08:28:16
minio         08:26:32

But explicitly selecting the multi-cluster context:

helm --kube-context kind-cnpg-lab-multi-cluster-dr-1 list -A

returns different deployment timestamps:

cert-manager  08:26:46
cnpg          08:27:02
minio         08:25:32

This demonstrates that Helm without an explicit context is not using the terminal-specific Kubernetes context.

3. Objective

Fix both issues:

1. Automatically initialize each use case terminal with its own Kind cluster context.
2. Ensure kubectl, k and helm use the same active context within each terminal.

Preserve the existing isolation between terminals.

4. Required Investigation

Before implementing, inspect:

* engine/terminal.sh
* engine/shell/bashrc
* engine/shell/tmux.conf
* Existing terminal-specific kubeconfig files.
* Shared ~/.kube/config.
* Current KUBECONFIG environment handling.
* Existing kubectl wrapper/function.
* tmux session creation and reconnection.

Determine:

1. Why KUBECONFIG is empty in interactive terminals.
2. Why Helm uses the shared context.
3. Why multi-cluster-dr initially inherits the single-cnpg context.
4. Whether an existing tmux session or stale terminal kubeconfig explains the initialization problem.

Do not assume the cause before inspecting the implementation.

5. Required Fix — Native KUBECONFIG

Prefer a solution based on the native KUBECONFIG environment variable.

The same terminal configuration must be used by:

* kubectl
* k
* helm

Avoid maintaining separate context-selection mechanisms for each tool.

Important

The shared kubeconfig contains the authoritative cluster definitions and credentials.

Terminal-specific context selection must remain isolated.

Investigate whether a merged configuration such as:

export KUBECONFIG="$HOME/.kube/terminals/<session>.yaml:$HOME/.kube/config"

is appropriate.

Do not assume that this automatically guarantees correct write isolation.

Verify Kubernetes kubeconfig merge precedence and the behavior of:

kubectl config use-context <context>

The shared kubeconfig’s active context must never be modified by an interactive terminal.

Dynamic cluster discovery

Existing terminals must continue discovering newly created Kind clusters.

Do not require restarting tmux when a cluster is created.

Avoid copying the entire shared kubeconfig into each terminal unless there is a reliable synchronization strategy.

6. Required Fix — Automatic Initialization

For a newly created terminal session:

Terminal    Expected Context
Playground    Shared default context
single-cnpg    kind-cnpg-lab-single-cnpg-1
multi-cluster-dr    kind-cnpg-lab-multi-cluster-dr-1

Derive the context dynamically from the existing Kind naming helpers.

Do not hardcode use case names.

For multi-cluster use cases, select cluster 1 by default.

Existing sessions

Do not reset existing tmux sessions automatically.

Preserve:

* Running commands.
* Shell variables.
* Working directories.
* Explicitly selected Kubernetes contexts.
* Existing terminal-specific kubeconfig files.

If a session has already selected a context manually, preserve that choice.

If an existing session has an incorrect initial context but no reliable way to distinguish it from a deliberate user selection, do not overwrite it silently.

Provide a safe, non-destructive way to correct it.

7. Expected Behavior

Terminal single-cnpg

echo "$KUBECONFIG"
# Non-empty terminal-specific configuration
kubectl config current-context
# kind-cnpg-lab-single-cnpg-1
helm list -A
# Releases deployed on single-cnpg-1

Terminal multi-cluster-dr

echo "$KUBECONFIG"
# Non-empty terminal-specific configuration
kubectl config current-context
# kind-cnpg-lab-multi-cluster-dr-1
helm list -A
# Releases deployed on multi-cluster-dr-1

Context switching

In multi-cluster-dr:

kubectl config use-context kind-cnpg-lab-multi-cluster-dr-2

Then:

kubectl config current-context
# kind-cnpg-lab-multi-cluster-dr-2
helm list -A
# Releases from multi-cluster-dr-2

Meanwhile, single-cnpg must remain on its original context.

Explicit overrides

These must continue working:

kubectl --context <context> get pods -A
helm --kube-context <context> list -A

8. Backend and Provisioning Isolation

The FastAPI backend must continue using the existing shared Kubernetes configuration.

Start/Stop operations must not inherit a terminal-specific context.

Do not change:

* Kind provisioning.
* Existing use case scripts.
* Cluster naming.
* Start/Stop API behavior.
* Operation logs.
* Docker networking.
* ttyd WebSocket configuration.

The fix must be limited to interactive terminal context management.

9. Validation

Test A — Fresh terminal initialization

Create temporary fresh terminal sessions.

Verify:

* Each session receives the correct default context.
* KUBECONFIG is correctly initialized.
* No terminal inherits another use case’s context.

Test B — Helm consistency

In two different terminals:

kubectl config current-context
helm list -A

Compare the results against:

helm --kube-context <expected-context> list -A

The results must match for each terminal.

Do not rely solely on identical chart names.

Compare release metadata, including deployment timestamps.

Test C — Context isolation

Change the active context in terminal A.

Verify:

* kubectl follows the new context.
* Helm follows the new context.
* Terminal B remains unchanged.
* The shared kubeconfig remains unchanged.

Test D — Dynamic Kind discovery

Create a temporary Kind cluster.

Verify that an already-running terminal can discover and select it.

Delete the temporary cluster afterward.

Do not modify existing user clusters.

Test E — Persistent sessions

Verify:

* Browser refresh preserves the context.
* Switching tabs preserves the context.
* Reconnecting preserves the context.
* Existing tmux sessions remain alive.

Test F — Regression

Verify:

* Terminal tabs.
* Sidebar discovery.
* Start/Stop controls.
* Colored Operation logs.
* ttyd connectivity.
* Existing Kind clusters remain untouched.

Do not destroy or restart existing use cases for testing.

10. Constraints

* KISS.
* Minimal targeted changes.
* No new dependencies unless strictly necessary.
* No additional containers.
* No frontend redesign.
* No changes to Kind provisioning.
* No modifications to the reference project.
* No interruption of existing tmux sessions.
* No automatic context reset on tab switching.
* No modification of the shared kubeconfig’s active context.

11. Deliverables

Provide:

1. Root cause of both issues.
2. Explanation of the selected fix.
3. Modified files.
4. Behavior for fresh sessions.
5. Behavior for existing sessions.
6. Validation results.
7. Known limitations.

Implementation Instructions

Inspect the current implementation first.

Explain the root causes.

Implement the smallest reliable fix.

Prioritize native KUBECONFIG behavior shared by kubectl and Helm.

Preserve existing terminal sessions and Kubernetes resources.

Implement SPEC-006.4.2-FIX only.

Do not start SPEC-006.5 or SPEC-006.6.
~~~~~
