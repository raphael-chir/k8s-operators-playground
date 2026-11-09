# SPEC-007.1.5 — Grafana Dashboard Default Settings

| | |
|---|---|
| Status | Implemented in the repository and validated against a real Grafana 13.2.4 (same image as the chart) in throwaway containers. **Not applied to the running `cnpg-standard` cluster**: that needs `playground usecase start cnpg-standard` (a Helm upgrade that restarts Grafana), which requires authorization. **Not validated in a browser** (time picker and refresh selector display, panels refreshing every second) |
| Document type | Original specification, preserved verbatim, with the implementation record |
| Source | Claude Code session transcript (project history), user message of 2026-11-05 |
| Original specification | Available (see the last section) |
| Target version | `1.0.0-rc.1` (unchanged) |

## How the dashboard is provisioned

`platform/monitoring/install.sh` runs `helm upgrade --install` of kube-prometheus-stack with `values.yaml`, waits for Grafana, then imports `platform/monitoring/cnpg-dashboard.json` through the Grafana API (`POST /api/dashboards/db`, `overwrite: true`, fixed UID `cloudnative-pg`) and sets it as the home dashboard. Re-running updates the same dashboard in place (no duplicate). The dashboard was `now-7d` with a 30 s refresh; Grafana 13.2.4 enforced `minRefreshInterval` of 5 s (read from the running Grafana's `/api/frontend/settings`).

## Changes

| File | Change |
|---|---|
| `platform/monitoring/cnpg-dashboard.json` | `time.from` `now-7d` → `now-5m`; `refresh` `30s` → `1s`; `timepicker.refresh_intervals` added (`1s, 5s, 10s, 30s, 1m, 5m, 15m, 30m, 1h, 2h, 1d`) so that 1s is an entry of the dashboard's refresh selector (Grafana's default list starts at 5s). Text replacements only: the panels (66), queries, templating, UID and title are byte-identical (checked by parsing both versions: only `time`, `refresh` and `timepicker` differ) |
| `platform/monitoring/values.yaml` | `grafana.grafana.ini.dashboards.min_refresh_interval: 1s` (Helm values, not a file edited in a pod). It sits next to the existing `auth.anonymous` block and merges with the per-cluster cookie name that `install.sh` adds with `--set-string` |
| Docs | this record, the index, the release checklist, `docs/architecture.md` |

Nothing else changed: no new dependency, no second dashboard, `install.sh` unchanged.

## Validation (non-destructive)

Two throwaway `grafana/grafana:13.2.4` containers (the chart's version), the dashboard imported exactly like `install.sh` does:

| Check | Control (Grafana defaults) | With `min_refresh_interval = 1s` |
|---|---|---|
| `minRefreshInterval` reported by the frontend settings | `5s` | `1s` |
| Import of the new dashboard | **rejected**: `Dashboard refresh interval is too low` | accepted (`success`, uid `cloudnative-pg`) |
| Import twice (overwrite) | n/a | one dashboard titled CloudNativePG, version unchanged |
| Stored dashboard | n/a | `time` now-5m to now, `refresh` `1s`, `refresh_intervals` starting `1s`, 66 panels, uid and title unchanged |

So Grafana does not enforce a higher minimum once the value is set, and **the Grafana setting is required, not optional**: without it the import itself fails. This also fixes an ordering rule that `install.sh` already satisfies (Helm values first, dashboard import after). `values.yaml` parses as YAML (`yq`) with the new keys under `grafana.grafana.ini.dashboards`. The live cluster, its Grafana and its data were only read (frontend settings and the stored dashboard through a temporary port-forward), never changed.

## Not done / remaining

- **Applying it to the running cluster** (authorization needed): `playground usecase start cnpg-standard` (idempotent) runs the Helm upgrade, which changes Grafana's ConfigMap and restarts the Grafana pod (a few seconds without Grafana; Prometheus, PostgreSQL, MinIO and all data are untouched), then re-imports the dashboard. Importing the new dashboard JSON alone on the live cluster would fail (see above). New clusters get both automatically at `platform-up`.
- **Browser checks** for the project owner after that: the time picker shows *Last 5 minutes*, the refresh selector shows *1s*, panels refresh every second, the settings are still there after reopening. A person with edit rights who saves the dashboard from the UI can change them, and the next `usecase start` re-imports the defaults.
- A 1 s dashboard refresh queries Prometheus every second but does **not** increase the metrics collection frequency: the scrape interval is unchanged, so panels show new points only as fast as Prometheus scrapes (default 30 s with this stack). 66 panels refreshing every second also make the browser and Prometheus work harder on a small Docker VM.

## Original specification (verbatim)

~~~~~text
SPEC-007.1.5 — Grafana Dashboard Default Settings

Project: CNPG Operator Playground
Target: Grafana dashboards
Release: v1.0.0-rc.1
Priority: Low

1. Objective

Configure the existing Grafana dashboard to open automatically with:

* Time range: Last 5 minutes
* Auto-refresh: Every 1 second

These settings must be applied by default whenever a user opens the dashboard.

No manual configuration should be required.

2. Implementation

Inspect the existing Grafana dashboard provisioning configuration and JSON files.

Prefer modifying the existing dashboard JSON.

Set:

"time": {
  "from": "now-5m",
  "to": "now"
},
"refresh": "1s"

Ensure Grafana allows a 1-second refresh interval.

If necessary, configure the Grafana setting:

[dashboards]
min_refresh_interval = 1s

For Helm-based deployments, use the corresponding Grafana chart configuration rather than editing files inside a running Pod.

3. Requirements

* Keep the existing dashboard panels unchanged.
* Preserve existing Prometheus queries.
* Preserve dashboard UID and title.
* Do not create duplicate dashboards.
* Do not introduce additional dependencies.
* Apply the settings through the existing provisioning mechanism.
* Ensure settings persist after restarting the Playground.
* Keep the implementation minimal.

4. Validation

Verify:

1. Open the Grafana dashboard.
2. The time picker displays Last 5 minutes.
3. The refresh selector displays 1s.
4. Panels refresh automatically every second.
5. Settings remain configured after reopening the dashboard.
6. Existing panels and queries work correctly.

Check that Grafana does not enforce a higher minimum refresh interval.

Note that a 1-second dashboard refresh does not increase the Prometheus metrics collection frequency.

5. Constraints

* Do not modify unrelated Playground components.
* Do not recreate Kind clusters.
* Do not delete Grafana data or volumes.
* Do not modify existing PostgreSQL resources.
* Do not restart running services without authorization.
* Do not push or tag the repository.

6. Deliverables

* Minimal configuration changes.
* Updated dashboard JSON if applicable.
* Validation results.
* Any remaining limitations.

Create:

docs/specs/SPEC-007.1.5-grafana-default-settings.md

Update the specification index and release checklist.

Do not change the Playground version.

7. Implementation Instructions

1. Inspect the current Grafana configuration.
2. Identify the provisioned dashboard.
3. Apply the smallest necessary configuration changes.
4. Run non-destructive validation.
5. Report the results.

Do not stop after inspection to request permission for file edits.

Expected result: Grafana opens the CNPG dashboard with Last 5 minutes and automatic refresh every 1 second.
~~~~~
