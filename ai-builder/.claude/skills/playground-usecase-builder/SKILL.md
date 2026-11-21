---
name: playground-usecase-builder
description: Generate new use cases for the CNPG Operator Playground using existing project conventions.
---

# Playground Use Case Builder

You are an expert in Kubernetes, PostgreSQL, CNPG and the CNPG Operator Playground.

## Instructions

1. Read the repository sources and the reference use cases.
2. Analyze existing use cases before generating anything.
3. Reuse the existing use case structure and conventions.
4. Reuse existing platform components and installation mechanisms.
5. Follow existing scenario conventions, including ui_info, ui_command and ui_pause.
6. Generate numbered scenarios and a README.md for new internal use cases. Only usecase.yaml is mandatory: README.md, scenarios and manifests are optional, and a README.md may be deleted when the user asks (never recreate it unasked).
7. Generate Kubernetes manifests only when needed.
8. Do not modify existing use cases, engine, platform, web or tests.
9. Do not execute scenarios, Docker, Kind, Kubernetes or Helm commands.
10. Do not install dependencies.
11. Perform static validation only.
12. Summarize all generated files and any remaining assumptions.

## usecase.yaml

- Editing an existing use case: leave usecase.yaml untouched unless the user explicitly asks for a manifest change. Never change its `provider:` section unless explicitly asked.
- Internal use case (`provider.type: internal`, name `kind` or `k3d`; no provider section means internal/kind): `title`, `description`, `infrastructure.clusters` and `infrastructure.workers_per_cluster` are required; `services` (cert_manager, minio, prometheus, grafana: true|false) is optional.
- External use case (`provider.type: external`, with `provider.name` e.g. openshift and `provider.context`, the kubeconfig context): the user owns the cluster. Never add `infrastructure` or `services`; they do not apply and are ignored. Copy the conventions of usecases/openshift-crc/usecase.yaml.
- Scenario structure (shebang, `set -Eeuo pipefail`, sourced libraries, `main "$@"`, numbering) and the `ui_note`, `ui_command` and `ui_pause` helpers are recommended conventions, not requirements. Validation only warns about them. Placeholder and incomplete scenarios are allowed: never add or rewrite anything just to satisfy an optional convention. Only syntax errors, unsafe paths, invalid `usecase.yaml` and references to missing manifests block publishing.
- Unknown extra fields are allowed. Keep the existing simple `key: value` / one nested level syntax.

## Output

Create the new use case under usecases/<usecase-name>/.

The generated use case must follow the existing repository conventions exactly.
