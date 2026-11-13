# pg4k-tde

EDB Postgres for Kubernetes (PG4K) with Transparent Data Encryption (TDE). Work in progress: this use case currently provides the infrastructure definition and the operator installation only.

| | |
|---|---|
| Infrastructure | 1 Kind cluster (`cnpg-lab-pg4k-tde-1`), 3 workers |
| Services started by **Start** | cert-manager, MinIO, Prometheus, Grafana (see `usecase.yaml`) |
| Operator | PG4K 1.30.1 in `postgresql-operator-system`, installed by `./01_install_operators.sh` |

## Run it

```bash
./playground usecase start pg4k-tde
```

Open its terminal in the Web UI and run `./01_install_operators.sh`.

## Prerequisites

- An EDB subscription token: copy `.env.example` to `.env` at the repository root and set `EDB_SUBSCRIPTION_TOKEN`.
- Network access to `get.enterprisedb.io` and `docker.enterprisedb.com`.

## Not yet implemented

EPAS cluster manifests, TDE configuration, OpenBao integration and demonstration scenarios. The `edb-pull-secret` is created only in the operator namespace; the namespace of the future EPAS cluster will need it as well.

## Cleanup

**Stop** deletes the Kind cluster.
