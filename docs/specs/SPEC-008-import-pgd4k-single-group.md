# SPEC-008: Import PGD4K Single Group Use Case

| | |
|---|---|
| Status | Implemented and checked statically (syntax, files, discovery, `.env`). **Not deployed or run**: the owner validates it manually |
| Document type | Original specification summary and implementation record |
| Source | Claude Code session transcript (project history), user message of 2026-11-05 |
| Target version | `1.0.0-rc.1` (unchanged) |

## Request (summary)
Import `pgd4k-single-group` from `../cnpg-operator-playground-local` (read-only) into `usecases/pgd4k-single-group/` with minimal changes, KISS, no new libraries; `.env` with the single parameter `EDB_TOKEN=` (never printed or committed, `.env.example` provided); lifecycle through `./playground usecase list|start|status|stop` and the Web UI; lightweight validation only; concise README; no engine change unless necessary; no push or tag.

## Imported
| Source | Target |
|---|---|
| `usecases/pgd4k-single-group/scenarios/{01_install-pgd4k-cluster,02_application-connectivity,03_high-availability}.sh`, `lib/pgd.sh`, `manifests/{pgd-certificates,pgd-cluster,pgd-availability-monitor}.yaml` | same paths |
| `platform/operators/pgd4k/{install.sh,barman-plugin-values.yaml,resources/operator-podmonitors.yaml}` | same paths |
| `install.sh`, `cleanup.sh` | rewritten to the new conventions (below); new `status.sh`, `README.md`, `.env.example`, `.env` |

Not imported: the source `README.md` (it described the use case as having no scenario and referred to `make`), the 250 KB `scenarios/log` file, the unapplied `resources/` manifests it mentioned (not present in the source tree).

## Changes compared with the source (compatibility only)
- **Scenarios:** header sources `engine/lib/ui.sh` and `engine/usecase.sh` (provides `USECASE`, `KUBE_CONTEXT`, enters the script directory) instead of `lib/ui.sh` and a hand-built context. Commands untouched.
- **Operator installer:** takes a kube context (as `platform/operators/cnpg-community`), uses `platform/common.sh` instead of `config.sh`/`lib/platform.sh`; `EDB_SUBSCRIPTION_TOKEN` renamed `EDB_TOKEN`, read from the environment (no `config.sh`). Versions, manifests, patches and checks unchanged.
- **Use case scripts:** `install.sh` reads `EDB_TOKEN` from the use case's `.env` (parsed with `sed`, not sourced, exported only for the operator installer, never printed), fails before creating a cluster if empty, then `usecase_provision` (1 cluster, 3 workers), the operator installer and the access summary. `cleanup.sh` = `usecase_delete` (only this use case's cluster). `status.sh` = `usecase_status` plus the PGD4K summary and `pgdgroups`.
- `.gitignore`: `!.env.example` added, since `.env.*` would otherwise hide it. `.env` stays ignored.
- No engine change.

## Compatibility notes
- `lib/pgd.sh` (scenario 03's helper functions) is kept as in the source, although the project simplified `cnpg-standard` to no helper library (SPEC-007.1.3): removing it would be a refactor of working scenario code. Say if you want it inlined.
- `usecase_status` prints the CNPG-community lines (`cnpg-system`) as "Not ready / not installed" for this use case; harmless, engine left unchanged.
- The cluster uses 3 workers (the source default); the PGDGroup places one node per worker.
- Docker memory: one use case with 4 nodes plus the PGD pods; Apple Silicon operand-image architecture is unverified (see the use case README).

## Checks
`bash -n` on all new scripts; files and manifests present; `.env` and `.env.example` contain exactly `EDB_TOKEN=`; the use case is discovered by `engine/usecase-list.sh` and the terminal tab list; `tests/static.sh`. No cluster, container or deployment was touched.

## Manual test
See the use case README: set `EDB_TOKEN`, `./playground usecase start pgd4k-single-group`, `status`, run scenarios 01 to 03 in the use case terminal, `usecase stop`.
