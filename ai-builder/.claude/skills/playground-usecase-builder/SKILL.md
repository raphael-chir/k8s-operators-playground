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
6. Generate numbered scenarios and a README.md.
7. Generate Kubernetes manifests only when needed.
8. Do not modify existing use cases, engine, platform, web or tests.
9. Do not execute scenarios, Docker, Kind, Kubernetes or Helm commands.
10. Do not install dependencies.
11. Perform static validation only.
12. Summarize all generated files and any remaining assumptions.

## Output

Create the new use case under usecases/<usecase-name>/.

The generated use case must follow the existing repository conventions exactly.
