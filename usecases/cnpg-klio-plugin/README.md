# CNPG Klio Plugin (`cnpg-klio-plugin`)

A CloudNativePG lab for backup and recovery with the [Klio](https://github.com/cloudnative-pg/klio) plugin. You install the plugin, deploy a Klio server (Tier 1 local volume, Tier 2 MinIO), protect a 3-instance PostgreSQL cluster with it, take on-demand and scheduled base backups, and restore a new cluster from the backup plus the WAL stream.

> **Status: draft, not run.** This use case was generated without access to the Klio repository or a live cluster. The Klio-specific values are best-effort assumptions, listed below. Check them before a demo.

## Infrastructure

- 1 Kind cluster, 3 workers (one PostgreSQL instance per worker)
- Services: cert-manager (TLS for CNPG-I and mTLS between the Klio sidecars and the server), MinIO (Klio Tier 2, bucket `cnpg`, prefix `klio`)
- No Prometheus or Grafana

## Scenarios

| Script | Content |
|---|---|
| `01_install_operators.sh` | Install CloudNativePG (Helm chart 0.29.1) and the Klio plugin from its release manifest (`KLIO_VERSION` / `KLIO_MANIFEST_URL` can be overridden); list the Klio CRDs and API resources |
| `02_deploy_klio_server.sh` | Issue a private CA, server and client certificates with cert-manager; create `minio-secret` and `klio-encryption`; `kubectl explain` the Server CRD; deploy and inspect `klio-server` |
| `03_deploy_cluster.sh` | Deploy the `klio-config` PluginConfiguration and the `klio-cluster` Cluster (3 instances, plugin `klio.enterprisedb.io`); show the injected sidecar, plugin status and `pg_stat_archiver`; load pgbench (100,000 accounts) |
| `04_backup.sh` | On-demand backup `klio-cluster-backup` (`--method plugin --plugin-name klio.enterprisedb.io`); daily `ScheduledBackup` `klio-cluster-daily` (immediate); write a `klio_demo` marker row after the backups and switch WAL; Klio server logs; list the Tier 2 copy in MinIO |
| `05_restore.sh` | Bootstrap `klio-restored` from the Klio server (`bootstrap.recovery` + `externalClusters` plugin source); verify the pgbench count and the `klio_demo` marker row (recovered from WAL) |
| `06_reset_lab.sh` | With confirmation: delete the backups, scheduled backup, pgbench job, both clusters, the Klio PluginConfiguration, Server and its `klio-server` PVCs, the MinIO prefix `cnpg/klio/`, and the Klio certificates and secrets. CloudNativePG and the Klio plugin stay installed (restart from 02) |

## Manifests

- `manifests/klio-certificates.yaml`: self-signed `Issuer`, `klio-ca` CA `Certificate` and `Issuer`, `klio-server-tls` certificate (DNS names of `klio-server` in namespace `default`) and `klio-client-tls` client certificate. Standard cert-manager API.
- `manifests/klio-server.yaml`: Klio `Server` named `klio-server`: TLS, Tier 1 volume (2Gi, encrypted with the `klio-encryption` password), Tier 2 S3 on the in-cluster MinIO (`http://minio.object-storage.svc.cluster.local:9000`, bucket `cnpg`, prefix `klio`).
- `manifests/cluster.yaml`: Klio `PluginConfiguration` `klio-config` (server address and client certificate), then the `Cluster` `klio-cluster`: PostgreSQL 17.5, 3 instances on workers labelled `playground.edb.io/role=postgres`, plugin `klio.enterprisedb.io` as WAL archiver, synchronous replication (ANY 1).
- `manifests/scheduled-backup.yaml`: `ScheduledBackup` `klio-cluster-daily` (daily at midnight, `immediate: true`, method `plugin`).
- `manifests/restore-cluster.yaml`: `Cluster` `klio-restored` (1 instance) recovered from the external cluster `origin` (Klio plugin, `serverName: klio-cluster`). It does not enable the Klio plugin for itself.

## Assumptions to verify against the Klio documentation

These values were not checked against https://github.com/cloudnative-pg/klio:

- Installation: release asset `https://github.com/cloudnative-pg/klio/releases/download/v<version>/manifest.yaml`, default version `0.1.0`, installed into `cnpg-system`. Override it without editing the script: `KLIO_VERSION=<x.y.z> ./01_install_operators.sh` or `KLIO_MANIFEST_URL=<url> ./01_install_operators.sh`. If Klio is distributed as a Helm chart, replace the `kubectl apply` step.
- API group and kinds: `klio.enterprisedb.io/v1alpha1`, `Server` and `PluginConfiguration`. Scenarios 01 to 03 list and `kubectl explain` them before applying, so the real names show up.
- Field names in `klio-server.yaml` (`tls`, `tier1`, `tier2.s3`, `encryption.passwordSecretRef`) and `cluster.yaml` (`serverAddress`, `clientSecretName`, `serverCASecretName`).
- Plugin name `klio.enterprisedb.io`, Cluster parameter `pluginConfigurationRef`, recovery parameter `serverName`, and `isWALArchiver: true`. If Klio streams WAL without `archive_command`, the `pg_stat_archiver` checks in 03 and 04 will stay at 0. The restore still replays the streamed WAL.
- The Klio server creates a Service named after the `Server` (`klio-server`, the name used in the certificate DNS names and `serverAddress`) and PVCs whose names contain `klio-server` (used by the reset).
- The Klio server writes its Tier 2 copy under the configured prefix, which is what 04 lists and 06 purges.

The CloudNativePG resources (`Cluster`, `Backup`, `ScheduledBackup`, `bootstrap.recovery`, `externalClusters[].plugin`), the cert-manager resources and the `kubectl cnpg` commands use their documented APIs.

## Usage

```bash
./playground usecase start cnpg-klio-plugin
```

Open the use case terminal in the Web UI and run the scenarios in order (01 to 05; 06 resets the lab).
