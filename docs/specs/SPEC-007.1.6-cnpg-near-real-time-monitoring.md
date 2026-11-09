# SPEC-007.1.6 — CNPG Near Real-Time Monitoring

| | |
|---|---|
| Status | Implemented and applied to the running `cnpg-standard`, including `spec.monitoring.metricsQueriesTTL: 0s` (approved). Prometheus stores a sample every 2.00 s and every SQL-derived metric now changes at each scrape (measured). Not validated in a browser; no role change was exercised (failover and switchover were excluded) |
| Document type | Original specification, preserved verbatim, with the implementation record |
| Source | Claude Code session transcript (project history), user message of 2026-11-05 |
| Original specification | Available (see the last section) |
| Target version | `1.0.0-rc.1` (unchanged) |
| Relation | Replaces the 1 s dashboard refresh of [SPEC-007.1.5](SPEC-007.1.5-grafana-default-settings.md) with 2 s (the minimum refresh stays 1 s); that record is historical |

## Finding that decides the outcome: CNPG caches its query results for 30 s

The CNPG documentation ("Output caching") says the outputs of monitoring queries are cached for thirty seconds by default, so that PostgreSQL does not run the monitoring queries at every scrape; `cluster.spec.monitoring.metricsQueriesTTL` controls it (zero disables the cache). The field exists in the running CRD (CNPG 1.30.1), and the default queries ConfigMap sets no `cache_seconds`. Measured, not assumed:

- **Direct exporter polling** (`/metrics` of `cnpg-cluster-2`, one request every 2 s for 70 s): 35 of 35 requests succeeded, 7 to 55 ms (average 14 ms), about 463 series per response. `cnpg_pg_stat_database_xact_commit` changed in 2 of 34 consecutive polls; `cnpg_collector_collection_duration_seconds` changed twice.
- **Stored by Prometheus at 2 s** (60 samples over 2 minutes): `cnpg_pg_stat_database_xact_commit{app}` changed value at 4 instants, **32 s apart**; `cnpg_last_update_timestamp` and `cnpg_pg_stat_checkpointer_*` likewise only a few times. Metrics that change on every sample: `cnpg_cache_hits`, `cnpg_collector_collections_total`, `cnpg_collector_collection_duration_seconds`, the Go runtime metrics and `scrape_duration_seconds` (14 of 110 series).
- `cnpg_pg_replication_in_recovery` (the role), `cnpg_pg_replication_lag`, `cnpg_backends_total` and `cnpg_collector_up` showed **no change in the 2-minute window**, which is expected for a healthy idle cluster; whether the SQL-derived role and replication metrics lag a role change by up to 30 s was **not** observed (a failover or switchover was not allowed), but they come from the same cached queries (`pg_replication`, `pg_stat_replication`, `backends`, `pg_stat_database`), so with the default cache a role change is visible up to about 30 s late. Pod availability (`up`) is not cached.
- The PostgreSQL statistics views themselves also have their own flush behavior, not measured here.

Conclusion at that point: the pipeline stored fresh samples every 2 s and answered every scrape, but **SQL-derived metrics carried up to 30 s of exporter-side delay**; a 2 s scrape alone did not give 2 s visibility. The only supported mechanism is a Cluster-spec field, which needed approval: see *Follow-up* below, where it was applied.

## Changes applied

| File | Change |
|---|---|
| `usecases/cnpg-standard/manifests/cluster.yaml` | The `cnpg-cluster` PodMonitor endpoint gets `interval: 2s` and `scrapeTimeout: 1s`. Name, selector, labels and port unchanged; the Cluster document is unchanged (checked with a document diff); no second PodMonitor |
| `platform/monitoring/values.yaml` | `grafana.sidecar.datasources.defaultDatasourceScrapeInterval: 2s` (the datasource's minimum query step). Datasource UID, name and URL unchanged |
| `platform/monitoring/cnpg-dashboard.json` | `refresh` `1s` → `2s`; `timepicker.refresh_intervals` = `1s, 2s, 5s, 10s, 30s, 1m, 5m` (`nowDelay` kept); `time` stays `now-5m`..`now`. The 66 panels, queries, templating, UID and title are identical |

Applied to the running cluster: the PodMonitor object alone with `kubectl apply` (a diff showed only the two new fields; the Cluster and ObjectStore were not re-applied), then `./playground usecase start cnpg-standard` (Helm values and dashboard re-import; the cluster was kept). Prometheus reloaded its configuration without restarting; this time Grafana's sidecar picked up the datasource change without restarting Grafana.

## Validation

**Prometheus (effective configuration and measured samples):** global interval 30 s (timeout 10 s); operator PodMonitor 30 s / 10 s; CNPG PostgreSQL PodMonitor **2 s / 1 s**; three targets `up`, no `lastError`; over 90 s each instance has **45 samples (expected about 45), spacing min/avg/max 1.99/2.00/2.01 s, no gap above 3 s**, `min(up)` 1; scrape duration 11 to 12 ms (maximum 45 to 51 ms in the window).

**Grafana (read from the running instance, not from the Helm values):** version 13.2.4; `minRefreshInterval` 1 s; Prometheus datasource `timeInterval` **2 s** (UID `prometheus`, URL unchanged); dashboard `now-5m`..`now`, refresh `2s`, selector with `2s`; 66 panels; one dashboard titled CloudNativePG (version 2, UID unchanged). Of the 118 dashboard queries, 97 ran successfully through Grafana's datasource proxy (average 4 ms, maximum 8 ms), 20 use variables I could not resolve and were skipped, 1 failed: the *First Recoverability Point* table query matches both `cnpg_collector_first_recoverability_point` and the Barman plugin's `barman_cloud_cloudnative_pg_io_first_recoverability_point` and returns "vector cannot contain metrics with the same labelset"; it fails identically straight against Prometheus and is unchanged, so it **predates this change** (not fixed: dashboard queries must be preserved).

**Exporter, Prometheus and Grafana compared at the same instant** (`cnpg-cluster-2`): `cnpg_collector_up` 1, `cnpg_pg_replication_in_recovery` 1 in all three, ages 0.0 s. Direct exporter and Prometheus agree; Grafana returns the same sample.

**Resources, before (30 s) and after (2 s), Prometheus self-metrics:**

| | Before | After |
|---|---|---|
| Prometheus resident memory | 467 MB | 520 MB |
| Prometheus CPU (cores, 5 m / 90 s window) | 0.0119 | 0.0135 |
| Samples ingested per second (whole stack) | 2401 | 3082 |
| Head series | 75 910 | 76 380 |
| CNPG scrape duration | 10 to 42 ms | 11 to 12 ms (max 51 ms) |
| Scrape failures | 0 | 0 |
| Prometheus restarts | 0 | 0 |

The extra ingestion (+681 samples/s) matches 1423 samples per scrape × 3 targets going from every 30 s to every 2 s; the series count is essentially unchanged. Grafana responsiveness was measured only after the change (dashboard GET 15 ms, queries 4 ms average); there is no earlier measurement. The memory difference is within normal growth of the head block and was measured over minutes, not hours; disk grows about 1423 samples × 0.47/s ≈ 660 samples/s extra, a few hundred MB over the 10-day retention (estimate). Acceptable on the local Playground; the stack was nowhere near its limits. With the cache disabled the exporter would also run its SQL queries at every scrape (collection measured at about 30 ms per instance every 2 s, about 1.5% of a core per instance, estimate).

**Integrity:** four Kind nodes Ready; `cnpg-cluster` (3/3) and `restored-cnpg-cluster` (1/1) healthy, same pods and PVCs, Cluster spec and monitoring settings untouched; the completed backup present; MinIO pod and volume unchanged; Prometheus, Alertmanager, operator, plugin and Grafana pods with no new restarts (`cnpg-cluster-1` still shows its one restart from 18:16, before this work). The snapshot diff against the state before the change was empty.

## Follow-up: `spec.monitoring.metricsQueriesTTL: 0s` (approved)

**Preconditions checked before touching the live cluster**
1. *`0s` disables the cache:* the installed CRD (CNPG 1.30.1) and the v1.30.1 API source say: "If not set, defaults to 30 seconds ... Setting this to zero disables the caching mechanism and can cause heavy load on the PostgreSQL server." The field is a Kubernetes duration, so `0s` is valid.
2. *No pod restart expected:* in the v1.30.1 source the exporter evaluates the TTL on every scrape from the live Cluster object (`Collect()` calls `cluster.GetMetricsQueriesTTL()`); the operator's rollout decision (`cluster_upgrade.go`: image, bootstrap image, projected volumes, PVCs, restart annotation, environment hash, scheduler, topology, pending PostgreSQL parameters) and the pod-spec generation (`pkg/specs`) contain no monitoring field. A server-side dry-run of the patch was accepted. Pod UIDs, start times and restart counts were recorded before and compared after.

**Applied:** `usecases/cnpg-standard/manifests/cluster.yaml` gets `monitoring.metricsQueriesTTL: 0s` (a document diff shows the rest of the Cluster spec unchanged), and the running Cluster received the one-field merge patch `{"spec":{"monitoring":{"metricsQueriesTTL":"0s"}}}` (the other monitoring fields, `customQueriesConfigMap` etc., were preserved). The operator's webhook answered with its expected warning about load.

**Results (after about 20 s and then 70 s of polling)**

| Check | Result |
|---|---|
| Pods | Same UIDs, start times and restart counts for all four PostgreSQL pods and the monitoring pods: **no restart**. Cluster healthy 3/3, primary unchanged |
| Prometheus cadence | 30 samples per instance in 60 s, spacing 1.99–2.00 s, no gap above 3 s, no failed scrape |
| Exporter, direct (35 requests every 2 s) | 35/35 ok, response 34 to 41 ms (was 7 to 55 ms with the cache); `cnpg_last_update_timestamp` advanced by exactly 2.0 s on every poll; `cnpg_cache_hits` stayed 0 (cache disabled) |
| SQL-derived metrics refreshed per scrape | `cnpg_pg_stat_database_xact_commit` and `_tup_fetched` changed in 34 of 34 polls (29 of 29 stored intervals); gaps between value changes **2 s (before: 32 s)** |
| Scrape duration vs the 1 s timeout | average 41–47 ms, maximum 53–67 ms over 5 minutes (before: about 11 ms with the cache): far below 1000 ms |
| Prometheus | 473 MB resident, 0.011 CPU cores, 3108 samples/s, 76 575 series, no restart (the ingestion rate is unchanged from the 2 s step: the cache only affected values, not the number of samples) |
| Grafana | health ok (2 ms); the datasource query returns the latest sample (age 0.0 s); no restart |

**Side effect to know about:** the monitoring queries are themselves transactions, so with the cache off the commit counter of an **idle** cluster rises by about 14–15 per second per instance (about 1 per second before). Any transactions-per-second panel will show that baseline until a real workload exceeds it. It is monitoring noise, not application load; the PostgreSQL load from the queries is about 40 ms of work per instance every 2 s (measured as scrape duration), roughly 2% of a core.

## Remaining limitations

1. **Role changes were still not exercised** (a failover or switchover was excluded). With the cache off, `cnpg_pg_replication_in_recovery`, the replication metrics and the backend counts are recomputed at every scrape, so a role change should now appear within about 2 s plus the dashboard refresh; this has to be confirmed in a scenario (for example scenario 04) by whoever runs it.
2. Replication lag (`cnpg_pg_replication_lag`) is computed from the last replayed transaction; on an idle primary it can grow without a real problem, regardless of scrape speed. (Currently 0: replicas are caught up.)
3. A 2 s refresh with 66 panels is heavier for the browser than before; the dashboard can be set to a slower refresh in the picker.
4. The browser display (*Last 5 minutes*, *2s*) has not been checked by a person. This monitoring is for visualization; precise downtime measurement needs an application-level test.
5. `restored-cnpg-cluster` has no PodMonitor and is not monitored. A new cluster created from `cluster.yaml` gets the 2 s interval and the uncached queries from the start.
6. The dashboard's *First Recoverability Point* table query fails (duplicate labelset between the CNPG and the Barman metric); it predates this work and was not changed.

## Original specification (verbatim)

~~~~~text
SPEC-007.1.6 — CNPG Near Real-Time Monitoring

Project: CNPG Operator Playground
Use case: cnpg-standard
Release: v1.0.0-rc.1
Priority: Medium
Status: Approved for implementation

1. Objective

Implement near-real-time monitoring for the CNPG Standard use case.

The monitoring pipeline must operate with a target interval of 2 seconds:

PostgreSQL / CNPG
       |
       | Metrics exposed through /metrics
       v
Prometheus
       | Scrape every 2s
       v
Grafana
       | Query and refresh every 2s
       v
CloudNativePG Dashboard
       | Last 5 minutes

The objective is to improve the visualization of:

* PostgreSQL primary/replica role changes.
* CNPG failovers and switchovers.
* Replication status and lag.
* PostgreSQL instance availability.
* Cluster state transitions.

The implementation must remain simple and preserve the existing Playground architecture.

Important: A 2-second scrape interval does not guarantee that every CNPG metric changes or is internally recomputed every 2 seconds. The implementation must verify the actual freshness of the relevant metrics.

⸻

2. Target Configuration

Component    Parameter    Target
Prometheus    Global scrape interval    30s (unchanged)
Prometheus    CNPG PostgreSQL scrape interval    2s
Prometheus    CNPG PostgreSQL scrape timeout    1s
Prometheus    CNPG operator scrape interval    30s (unchanged)
Grafana    Dashboard refresh    2s
Grafana    Dashboard time range    Last 5 minutes
Grafana    Prometheus datasource minimum interval    2s
Grafana    Minimum allowed refresh interval    1s (unchanged)
CNPG exporter    Metrics exposure    Verify freshness at 2s

Only the PostgreSQL instance metrics should be collected every 2 seconds.

Do not change the global Prometheus scrape interval.

⸻

3. Implementation

3.1 CNPG PodMonitor

File:

usecases/cnpg-standard/manifests/cluster.yaml

Locate the existing CNPG PostgreSQL PodMonitor.

Configure its metrics endpoint with:

spec:
  podMetricsEndpoints:
    - port: metrics
      interval: 2s
      scrapeTimeout: 1s

Adapt the YAML to the existing manifest structure.

Requirements:

* Preserve the existing PodMonitor name.
* Preserve existing selectors and labels.
* Preserve the existing metrics port.
* Do not modify the PostgreSQL Cluster specification.
* Do not create an additional PodMonitor.
* Do not modify the CNPG operator PodMonitor.

The existing three PostgreSQL instances must continue to be monitored.

3.2 Grafana Datasource

File:

platform/monitoring/values.yaml

Configure the Grafana Prometheus datasource:

grafana:
  sidecar:
    datasources:
      defaultDatasourceScrapeInterval: 2s

Preserve the existing datasource UID, name and URL.

Do not modify unrelated Helm values.

3.3 Grafana Dashboard

File:

platform/monitoring/cnpg-dashboard.json

Configure:

"time": {
  "from": "now-5m",
  "to": "now"
},
"refresh": "2s"

Ensure 2s is available in the dashboard refresh selector:

"timepicker": {
  "refresh_intervals": [
    "1s",
    "2s",
    "5s",
    "10s",
    "30s",
    "1m",
    "5m"
  ]
}

Preserve any other existing timepicker settings.

Requirements:

* Preserve all 66 dashboard panels.
* Preserve existing PromQL queries.
* Preserve the dashboard UID cloudnative-pg.
* Preserve the dashboard title CloudNativePG.
* Preserve existing variables and templating.
* Do not create duplicate dashboards.

The dashboard must open with:

Last 5 minutes / Refresh every 2 seconds.

⸻

4. CNPG Metrics Freshness

4.1 Objective

Verify that the CNPG metrics exporter exposes sufficiently fresh PostgreSQL metrics when scraped every 2 seconds.

The validation must distinguish between:

1. Prometheus scraping the endpoint every 2 seconds.
2. CNPG responding successfully to each scrape.
3. CNPG metrics reflecting the current PostgreSQL state.
4. Grafana displaying newly collected samples.

These are separate behaviors and must be validated independently.

4.2 Exporter Investigation

Inspect the existing CNPG exporter behavior.

Determine:

* Whether PostgreSQL metrics are collected on demand when /metrics is requested.
* Whether some metrics are cached internally.
* Whether some metrics are refreshed by background processes.
* Whether some metrics depend on PostgreSQL statistics update intervals.
* Whether specific CNPG metrics have a refresh frequency greater than 2 seconds.

Use the existing CNPG implementation and documentation.

Do not introduce a new exporter.

Do not modify PostgreSQL configuration unless a concrete limitation is identified and a change is explicitly approved.

4.3 Metrics to Investigate

Focus on metrics relevant to HA demonstrations.

Examples:

Metric category    Expected behavior
Primary/replica role    Reflect current PostgreSQL role
Replication status    Reflect current replication state
Replication lag    Reflect available PostgreSQL replication statistics
PostgreSQL availability    Reflect instance availability
Transaction counters    Increase when transactions occur
CNPG instance status    Reflect the latest state exposed by CNPG

Identify the actual metric names available in the running CNPG version.

Do not assume a metric exists without verifying it.

4.4 Runtime Freshness Validation

Perform read-only tests against the existing running CNPG cluster.

1. Query the /metrics endpoint repeatedly at 2-second intervals.
2. Verify that each request succeeds.
3. Measure response times.
4. Inspect metrics that should evolve naturally.
5. Compare direct exporter values with Prometheus samples.
6. Determine whether any internal refresh delay exists.

For counters or metrics that remain constant, do not interpret an unchanged value as stale without evidence.

Do not generate artificial database workloads without authorization.

Do not trigger failovers or switchovers during this validation.

4.5 Expected Result

Confirm whether:

* CNPG responds to every 2-second scrape.
* Relevant dynamic metrics reflect the latest available PostgreSQL state.
* No additional exporter-level refresh delay prevents effective 2-second monitoring.
* Prometheus stores fresh samples every 2 seconds.

If a metric is refreshed less frequently, document the limitation.

Do not attempt to force internal CNPG refresh intervals without first identifying a supported configuration mechanism.

⸻

5. Apply Changes to the Running Playground

Apply the configuration to the existing cnpg-standard use case.

Authorized operations:

1. Update the existing CNPG PodMonitor.
2. Apply the required Grafana Helm configuration.
3. Reimport the updated Grafana dashboard.
4. Restart Grafana if required.

Use the existing deployment mechanisms.

Do not introduce new deployment scripts.

Infrastructure Preservation

The following resources must remain intact:

* Kind cluster and nodes.
* Existing PostgreSQL clusters.
* PostgreSQL PVCs and data.
* Existing backups.
* MinIO and stored objects.
* Prometheus and its data.
* Existing Kubernetes resources unrelated to monitoring.

Do not execute educational scenarios.

Do not reset or recreate the use case.

Do not restart PostgreSQL, Prometheus or MinIO.

⸻

6. Validation

6.1 Prometheus Configuration

Verify:

* Effective CNPG PostgreSQL scrape interval: 2s.
* Effective CNPG PostgreSQL scrape timeout: 1s.
* All three CNPG PostgreSQL targets are UP.
* No scrape errors.
* Global Prometheus interval remains 30s.
* CNPG operator interval remains 30s.

6.2 Actual Collection Frequency

Query Prometheus to inspect actual sample timestamps.

For each PostgreSQL instance:

* Collect sample timestamps over a representative period.
* Calculate the observed interval between samples.
* Confirm approximately 2 seconds between samples.
* Check for missing samples.
* Check scrape duration and failures.

Do not rely exclusively on the configured interval.

6.3 Grafana Configuration

Verify:

* Dashboard default time range is now-5m to now.
* Dashboard refresh interval is 2s.
* Datasource minimum query interval is 2s.
* All 66 panels remain present.
* Dashboard UID and title remain unchanged.
* No duplicate dashboard exists.
* PromQL queries execute successfully.

Inspect the effective datasource configuration rather than relying only on Helm values.

6.4 Metrics Freshness

Compare:

* Direct CNPG /metrics responses.
* Prometheus samples.
* Grafana query results.

Report whether the monitoring pipeline provides approximately 2-second visibility for metrics that can update at that frequency.

Do not claim that all CNPG metrics are refreshed every 2 seconds unless verified.

6.5 Resource Consumption

Compare before and after:

* Prometheus CPU usage.
* Prometheus memory usage.
* CNPG metrics scrape duration.
* Scrape failures.
* Grafana responsiveness.

A 2-second scrape interval represents 15 times more frequent collection than the previous 30-second configuration.

Verify that this remains acceptable for the local Playground.

6.6 Infrastructure Integrity

Verify:

* All Kind nodes remain Ready.
* Existing PostgreSQL clusters remain healthy.
* PostgreSQL Pods and PVCs remain intact.
* MinIO remains healthy.
* Prometheus remains healthy.
* Existing backups remain available.
* No unexpected restarts occurred.

⸻

7. Documentation

Create:

docs/specs/SPEC-007.1.6-cnpg-near-real-time-monitoring.md

Update:

* Specification index.
* Release checklist.
* Monitoring documentation, where applicable.

Document the effective configuration and any identified limitations in CNPG metrics freshness.

Keep documentation changes minimal.

⸻

8. Constraints

* Follow the existing project architecture.
* Keep the implementation KISS.
* No new exporters.
* No additional monitoring components.
* No new scripts unless strictly necessary.
* No changes to unrelated use cases.
* No changes to PostgreSQL Cluster specifications.
* No changes to the Playground version.
* No destructive Kubernetes operations.
* No Git push or tag.

⸻

9. Expected Result

The CNPG Playground provides near-real-time monitoring:

CNPG PostgreSQL Instances
          |
          | /metrics
          |
          v
      Prometheus
       Scrape: 2s
          |
          v
       Grafana
      Refresh: 2s
      Query step: 2s
      Range: 5 minutes
          |
          v
   CloudNativePG Dashboard

Users should be able to observe PostgreSQL role changes, replication status and cluster transitions with significantly lower latency than the previous 30-second monitoring configuration.

Acceptance criteria:

1. Prometheus successfully collects CNPG metrics every 2 seconds.
2. CNPG exporter responsiveness and metric freshness are verified.
3. Grafana queries and refreshes at 2-second intervals.
4. All existing dashboard panels remain functional.
5. The Playground infrastructure remains intact.
6. Resource consumption remains acceptable.

This monitoring is intended for visualization.

Precise application downtime measurement must continue to use an independent application-level test.

⸻

10. Execution Instructions

1. Inspect the current monitoring configuration.
2. Investigate CNPG exporter behavior and metric freshness.
3. Capture the current infrastructure state.
4. Implement the minimal configuration changes.
5. Validate YAML and JSON syntax.
6. Apply the changes to the running Playground.
7. Verify effective Prometheus and Grafana settings.
8. Measure actual scrape frequency and exporter responsiveness.
9. Verify infrastructure integrity.
10. Run relevant non-destructive tests.
11. Update documentation.
12. Report results and remaining limitations.

Do not push or tag anything.
~~~~~
