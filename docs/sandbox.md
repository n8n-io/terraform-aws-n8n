# Sandbox profile

[`examples/small/`](../examples/small/) is already the module's cheapest
end-to-end reference, but it still runs the module's default multi-main
footprint: two main pods, two webhook processors, a worker with a task
runner sidecar, and a `t3.xlarge` node group sized to hold all three at
their default ceilings. This document describes a cheaper single-main
profile you can layer on top of `small` (or your own root module) today
using only existing inputs, and calls out the one piece `examples/small`
does not currently expose.

## What you can set today

Every input below is a plain override on the root module:

| Input | Sandbox value | Why |
|---|---|---|
| `n8n_main_hpa_min_replicas` | `1` | Single-main mode. Does not require `feat:multipleMainInstances`; a Business-tier license is enough. |
| `n8n_webhook_hpa_min_replicas` / `n8n_webhook_hpa_max_replicas` | `1` | One webhook processor. |
| `n8n_worker_keda_min_replicas` / `n8n_worker_keda_max_replicas` | `1` | One worker. |
| `node_min` | `1` | The Cluster Autoscaler's floor. |
| `node_max` | `2` | Leaves headroom for a rolling node replacement without paying for a second steady-state node. |
| `db_instance_class` | `db.t4g.micro` | Cheapest Graviton Burstable RDS class. Low `max_connections`; see the budget section below. |
| `db_postgresdb_pool_size` | `3` or lower | See the budget section below. |

`n8n_main_hpa_max_replicas` does not need to change: the effective main
ceiling already clamps to `1` in single-main mode
(`local.n8n_main_hpa_effective_max_replicas`, `locals.tf`), so the capacity
and connection-budget diagnostics both model one main pod regardless of
this input's own value.

### Not yet a passthrough on `examples/small`

`examples/small/variables.tf` only forwards `n8n_main_hpa_min_replicas` (and
the image/deletion-control inputs) to the module; it does not expose
`node_min`, `node_max`, `db_instance_class`, `db_postgresdb_pool_size`, or
the webhook/worker replica floors the way it forwards `n8n_main_hpa_min_replicas`
today. Applying this profile against that example therefore means either
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
`db.t4g.micro` (1 vCPU, 1 GiB) resolves to around 112 user connections.
Each main, worker, and webhook-processor pod can lazily open up to
`db_postgresdb_pool_size` connections against the same instance
(`db_postgresdb_pool_size` variable description), so the aggregate ceiling
is:

```text
db_postgresdb_pool_size * (main replicas + worker replicas + webhook replicas + any n8n_worker_pools ceilings)
```

At the single-main sandbox sizes above (1 main + 1 worker + 1 webhook = 3
pods), `db_postgresdb_pool_size = 3` requests up to 9 connections,
comfortably under `db.t4g.micro`'s ~112. The module's own shipped defaults
do not have this kind of headroom: at `db_instance_class = db.t3.small`
(the module default) with the default main/worker/webhook ceilings of
6/10/8 and the default `db_postgresdb_pool_size = 10`, the ceiling
arithmetic alone already requests 240 connections against db.t3.small's
own known default of ~225, before any `n8n_worker_pools` are added (see
[`examples/worker-pools/README.md`](../examples/worker-pools/README.md)'s
own connection-budget note). That specific combination predates this
check and the check deliberately leaves `db.t3.small` out of its table so
it stays quiet against the module's own untouched defaults, matching every
other advisory check in this module; moving off the default class (or
lowering the pool size or ceilings) is still worth doing for headroom, it
is just not something this one check enforces for that exact class.
Picking any *other* class in the curated table without adjusting the
ceilings is exactly what `check.db_postgresdb_pool_size_fits_known_max_connections`
(`database.tf`) does catch at plan time; it stays silent for instance
classes outside that table and for `create_database = false`, and it is
advisory only (it does not fail the plan or apply). Raising
`db_instance_class`, lowering `db_postgresdb_pool_size`, or lowering an
autoscaler ceiling all shrink the same number; see the check's own comment
in `database.tf` for the full curated table and for why PostgreSQL's
`superuser_reserved_connections` and RDS's own
`rds.rds_superuser_reserved_connections` leave the real headroom a few
connections tighter than the table's figure.

## Redis and S3

This profile does not change `redis_node_type` or `s3_force_destroy` from
`examples/small`'s defaults (`cache.t3.medium` and the module's own
teardown-friendly default): ElastiCache and S3 are already sized
independently of PostgreSQL and the node group, and `redis_node_type` is a
separate line-item on the bill either way.
