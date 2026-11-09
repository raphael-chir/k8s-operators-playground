# SPEC-015: Final RC1 readiness review

Status: review done and safe fixes applied. Scope was narrowed at the owner's request: scenarios and their tests were intentionally excluded (not executed, not edited).

## Findings and changes

| Priority | Finding | Action |
|---|---|---|
| P0 | `tests/static.sh` failed: documentation linked to use case READMEs that did not exist | Wrote `README.md` for the three use cases |
| P0 | `tests/engine.sh` assumed all four services in every use case and the old `Press Enter` text | Updated `tests/engine.sh` (valid manifest, only known service keys; new pause text) |
| P1 | `tests/scenarios.sh` is out of date with the flattened layout and rewritten scenarios (renamed `01`-`07`, prompt context call, scale/hibernate/fencing, pause text) | **Not changed**: scenarios are out of scope; it fails today. Update it with the scenario work |
| P1 | No `.env.example`; `.gitignore` pattern `.env.*` would have ignored it; docs named `EDB_TOKEN` in a per-use-case `.env` while the scenario reads `EDB_SUBSCRIPTION_TOKEN` from the root `.env` | Added `.env.example`, `!.env.example`, corrected the docs; no scenario was touched (a missing `.env` still gives Bash's own error) |
| P1 | Docs and `CLAUDE.md` still described the two-line prompt and six scenarios | Updated |
| P1 | No `CHANGELOG.md` | Added |
| P1 | `cnpg-distributed-topology` scenario applies a manifest that does not exist | Documented in its README, the user guide and the changelog; not invented |
| P2 | `pgd4k-single-group`: unused `manifests/ha-tester.yaml`, `manifests/pgd-availability-monitor.yaml` (older copy of the monitor), `lib/pgd.sh`, `archive/`; no `99` reset | Kept and listed in the use case README; no scenario or file removed |
| P2 | Version string is `1.0.0-rc.1` (SemVer form) while the request writes `rc1` | Unchanged: it is consistent everywhere (`VERSION`, CLI, `/api/meta`); the tag would be `v1.0.0-rc.1` |

## Security review

`.env` (one variable, the EDB token) is in `.gitignore` and `.dockerignore` (the build context is empty: `*`); the image copies nothing; no secret literal found in tracked content by pattern search (the only credentials are the documented local `admin` / `password` demo values). The Git checks (`git ls-files`, history) could not run: the directory is not a Git repository. Rotate the EDB token if `.env` was ever committed elsewhere.

## Verification

Run: `tests/static.sh`, `tests/cli.sh`, `tests/engine.sh`, `tests/terminal.sh`, `tests/monitoring.sh`, `bash -n` on every script, `docker compose config`, read-only API calls on the running Web UI. NOT TESTED (intentionally excluded from scope): every scenario, `tests/scenarios.sh`, live scenarios on a cluster, the PGD4K use case (needs an EDB token and a cluster), the amd64 build, other platforms, a browser, `shellcheck` and YAML validators (not installed).

## Original request (condensed)

"CNPG Operator Playground: Final RC1 Readiness Review": audit the repository for release-blocking issues without restructuring it (architecture, configuration and security including `.env`/`.env.example`/Docker, scripts, use case consistency incl. the PGD4K node-drain availability scenario and its monitoring limitations, tests, documentation incl. README/CONTRIBUTING/CLAUDE.md, version and `CHANGELOG.md`); classify P0/P1/P2, fix safe P0/P1, document, validate, and report with one of READY FOR RC1 / READY WITH KNOWN LIMITATIONS / NOT READY. Do not commit, push, tag or release; do not deploy or destroy clusters; mark untestable items NOT TESTED.
