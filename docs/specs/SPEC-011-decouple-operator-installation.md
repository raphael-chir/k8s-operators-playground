# SPEC-011 — Decouple Operator Installation from Use Case Provisioning

Status: implemented and reviewed statically. Not run live (no cluster was started or recreated).

## Implementation

- `usecases/{cnpg-standard,cnpg-distributed-topology,pgd4k-single-group}/install.sh`: the operator step is removed (`install_operators` in the two CNPG use cases, the `pgd4k` installer call and `read_edb_token` in the PGD use case). Start now runs `usecase_provision` (Kind clusters, nodes, networking, monitoring, MinIO) and prints the access information; the distributed topology still validates inter-cluster connectivity.
- Unchanged: `engine/`, `platform/` (the reusable operator installers, their versions, cert-manager), every scenario, the CLI, the Web UI, the terminal.
- Docs: the root README, `docs/user-guide.md`, `docs/architecture.md` and the three use case READMEs now say that Start provisions Kubernetes plus monitoring and MinIO, and that operators and plugins are installed by the scenarios.

## Limitations (by design of this spec)

- The existing scenarios were not modified. They still assume the operator is present (for example `cnpg-standard` scenario 01 reads "already installed by the Playground" and runs `kubectl get pods -n cnpg-system`, and the PGD scenarios expect `pgd-operator-system`), so until the scenarios install the operator (a follow-up spec) they will fail on a freshly started use case. Clusters started before this change keep their operators.
- `./playground usecase status` shows the operator lines as "Not ready / not installed" until an operator is installed.
- For `pgd4k-single-group`, `EDB_TOKEN` is no longer checked at Start; it is read by whatever installs the operator.
- Reset (`99_reset_lab.sh`) and `usecase stop` are unchanged: stop deletes the clusters, and with them any operator.

## Original request (condensed: no requirement dropped)

~~~~~
SPEC-011 — Decouple Operator Installation from Use Case Provisioning

Objective: separate Kubernetes infrastructure provisioning from PostgreSQL operator and plugin installation. Starting a use case must provision only the Kubernetes infrastructure and shared platform services (Kind clusters, node configuration, networking, Prometheus, Grafana, MinIO). Operator and plugin installation will be managed explicitly by scenario scripts in a future implementation. Keep this change minimal (KISS).

3.1 Remove automatic operator installation from the three use case install.sh scripts (CNPG Community, EDB PostgreSQL, PGD4K operators, the Barman Cloud plugin, operator-specific dependencies such as cert-manager when installed through these installers). For PGD4K, remove the EDB token validation from the Start workflow if it is only required for operator installation.
3.2 Preserve infrastructure provisioning (Kind creation, node labels and configuration, networking and dynamic ports, Prometheus, Grafana, MinIO, lifecycle commands).
3.3 Do not modify the reusable operator installers: no configurable versions, no changed hardcoded versions, no Helm refactoring, no cert-manager changes.
3.4 Do not modify any existing scenario scripts, including scenario 01.
3.5 Update only the documentation directly affected: Start provisions Kubernetes and shared platform services; operators and plugins are not installed automatically; operator installation is managed through scenarios.
4. Out of scope: scenario development, operator version management, upgrades or downgrades, uninstall mechanisms, reset changes, Web UI, terminal, new automated tests, infrastructure refactoring.
5. Validation: lightweight code review only (Start no longer invokes operator installers; provisioning unchanged; installers and scenarios untouched); do not start or recreate live clusters.
6. Acceptance: starting each of the three use cases installs no operator or plugin; infrastructure and platform services as before; no operator versions or scenarios modified; CLI and Web UI workflows unchanged.
7. Deliverables: modified files, summary, confirmation of acceptance criteria, limitations. No additional features.
~~~~~
