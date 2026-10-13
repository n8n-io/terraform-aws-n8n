# Sandbox profile

[`examples/small/`](../examples/small/) is already the module's cheapest
end-to-end reference, but it still runs the module's default multi-main
footprint: two main pods, two webhook processors, a worker with a task
runner sidecar, and a `t3.xlarge` node group sized to hold all three at
their default ceilings. This document describes a cheaper single-main
profile you can layer on top of `small` (or your own root module) today
using only existing inputs, and lists which of those inputs
`examples/small` does not currently forward.

## What you can set today

Every input below is a plain override on the root module:

| Input | Sandbox value | Why |
|---|---|---|
| `n8n_main_hpa_min_replicas` | `1` | Single-main mode. Does not require `feat:multipleMainInstances`; a Business-tier license is enough. |
| `n8n_webhook_hpa_min_replicas` / `n8n_webhook_hpa_max_replicas` | `1` | One webhook processor. |
| `n8n_worker_keda_min_replicas` / `n8n_worker_keda_max_replicas` | `1` | One worker. |
| `node_min` | `1` | The Cluster Autoscaler's floor. |
| `node_desired` | `1` | Matches `node_min`; only applies at creation (Cluster Autoscaler owns the count afterward), but `node_desired`'s own validation requires it to sit within `[node_min, node_max]`, and its module default of `3` would fail a fresh apply of this profile otherwise. |
| `node_max` | `2` | Leaves headroom for a rolling node replacement without paying for a second steady-state node. |
| `db_instance_class` | `db.t4g.micro` | Cheapest Graviton Burstable RDS class. Low `max_connections`; see the budget section below. |
| `db_multi_az` | `false` | Drops the Multi-AZ standby, which the module enables by default and which roughly doubles the database cost. A sandbox does not need failover. |
| `db_postgresdb_pool_size` | `3` or lower | See the budget section below. |

`n8n_main_hpa_max_replicas` does not need to change: the effective main
ceiling already clamps to `1` in single-main mode
(`local.n8n_main_hpa_effective_max_replicas`, `locals.tf`), so the capacity
and connection-budget diagnostics both model one main pod regardless of
this input's own value.

### Not yet a passthrough on `examples/small`

Of the inputs in the table above, `examples/small/variables.tf` forwards only
`n8n_main_hpa_min_replicas` to the module. It does not expose `node_min`,
`node_desired`, `node_max`, `db_instance_class`, `db_multi_az`,
`db_postgresdb_pool_size`, or the webhook/worker replica floors and
ceilings. Applying this profile against that example therefore means either
invoking the module directly from your own root module (see `module "n8n"`
in `examples/small/main.tf` for the wiring `small` already does), or adding
the missing passthroughs to a copy of `examples/small` yourself, following
the `nullable = true`, default-`null` shape every existing passthrough there
uses.

## PostgreSQL connection budget

RDS computes PostgreSQL's default `max_connections` from the selected
`db_instance_class`'s memory: `LEAST({DBInstanceClassMemory/9531392}, 5000)`
([AWS docs: "Quotas and constraints for Amazon RDS", `max_connections`
row](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/CHAP_Limits.html)).
Evaluated against nominal memory, `db.t4g.micro` (2 vCPUs, 1 GiB) resolves
to around 112 connections. That figure is an estimate, not the live value:
AWS documents that `DBInstanceClassMemory` is smaller than the nominal GiB
figure, because memory is reserved for the operating system and RDS
management processes. One community report observed 81 on a `db.t3.micro`
running PostgreSQL 14.10. Run `SHOW max_connections` on your instance for
the live value.
Each main, worker, and webhook-processor pod can lazily open up to
`db_postgresdb_pool_size` connections against the same instance
(`db_postgresdb_pool_size` variable description), so the aggregate ceiling
is:

```text
db_postgresdb_pool_size * (main replicas + worker replicas + webhook replicas + any n8n_worker_pools ceilings)
```

These are configured steady-state ceilings. Pods added during a rolling
update are not counted, so leave some headroom. While
`n8n_worker_keda_pause = true`, the worker term uses
`n8n_worker_keda_paused_replica_count` when that is larger than
`n8n_worker_keda_max_replicas`. If you clear the count while still paused,
KEDA keeps the workers at their current number, which can still be above
the maximum. The check then counts only the maximum.

At the single-main sandbox sizes above (1 main + 1 worker + 1 webhook = 3
pods), `db_postgresdb_pool_size = 3` requests up to 9 connections,
well below the nominal-memory estimate, but confirm the instance's connection budget before relying on it. The module's own shipped defaults
(`db_instance_class = db.t3.small`, main/worker/webhook ceilings of 6/10/4,
`db_postgresdb_pool_size = 9`) request up to 180 connections, before any
`n8n_worker_pools` are added (see
[`examples/worker-pools/README.md`](../examples/worker-pools/README.md)'s
own connection-budget note).

On a live `db.t3.small` running PostgreSQL 18.6 with the default parameter
group, `SHOW max_connections` returned 191, not the 225 the formula gives
against nominal memory. Of those, 3 are reserved for superusers
(`superuser_reserved_connections`) and 4 for RDS's internal role
(`rds.rds_reserved_connections`), and n8n's role can use neither, which
leaves 184. A further 2 slots (`reserved_connections`) are usable by n8n's
master user through `rds_superuser`, but not by a role without it. So the
module's defaults fit with a margin of 4 connections, assuming every pod
fills its pool at the same time. RDS's own management connections and any
other client you connect also draw from the same 184.

Raising `n8n_webhook_hpa_max_replicas` back to its old default of `8`
(216 connections), raising `db_postgresdb_pool_size` back to `10` (200), or
raising `n8n_main_hpa_max_replicas` or `n8n_worker_keda_max_replicas`
without also raising `db_instance_class` pushes demand past that budget;
see `n8n_webhook_hpa_max_replicas`'s own description for the tradeoff.
`check.db_postgresdb_pool_size_fits_known_max_connections` (`database.tf`)
warns about that at plan time for every class in its curated table. Only
the `db.t3.small` entry is measured. `db.t4g.small`, which has the same
nominal memory, reuses that measurement by assumption rather than the
formula's 225. The others are the formula against nominal memory, so the
live value can be lower and a silent check does not prove the ceilings fit
for them. The check also stays silent for instance
classes outside that table and for `create_database = false`, and it is
advisory only (it does not fail the plan or apply). A larger-memory class
raises the capacity up to the formula's cap, while a lower
`db_postgresdb_pool_size` or autoscaler ceiling reduces modeled demand; see
the check's own comment in `database.tf` for the full curated table and the
reserved-connections subtraction.

## Redis and S3

This profile does not change `redis_node_type` or `s3_force_destroy` from
`examples/small`'s defaults (`cache.t3.medium` and the module's own
teardown-friendly default): ElastiCache and S3 are already sized
independently of PostgreSQL and the node group, and `redis_node_type` is a
separate line-item on the bill either way.
