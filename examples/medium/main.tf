locals {
  aws_partner_attribution_tags = {
    for k, v in { "aws-apn-id" = var.aws_partner_attribution_tag } : k => v if v != ""
  }

  common_tags = merge(
    {
      ManagedBy = "terraform"
      Project   = "n8n"
    },
    # aws-apn-id is reserved for aws_partner_attribution_tag, so a tags entry
    # cannot override it or bring it back after the input is set to "".
    { for k, v in var.tags : k => v if k != "aws-apn-id" },
    local.aws_partner_attribution_tags,
  )
}

# ── VPC ───────────────────────────────────────────────────────────────────────
# /24 private subnets are sufficient for up to ~15 nodes of this size.
# m6i.2xlarge has 4 ENIs × 15 IPs each; 5 nodes × 4 ENIs × 15 IPs = 300 IPs,
# well within the 254 usable IPs per /24.

data "aws_availability_zones" "available" {
  # checkov:skip=CKV_AWS_394:Region-portable example intentionally discovers AZs instead of hardcoding region-specific zone identities; see docs/versioning.md for the accepted replacement risk.
  # slice(..., 0, 2) bounds the count, not the zone identities. A changed list
  # can replace subnets. Pin the existing zones in long-lived deployments and
  # review the plan before applying.
  state = "available"
}

module "vpc" {
  # checkov:skip=CKV_TF_1:A commit hash cannot be expressed for a Terraform Registry source: this address takes a `version` constraint, and pinning a SHA would mean switching to a `git::` source, which is the weaker supply-chain posture the check exists to discourage. Registry releases are immutable per published version. Annotated per call rather than suppressed repo-wide, so the check still fires if a genuinely mutable git:: source is ever added.
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${var.cluster_name}-vpc"
  cidr = "10.0.0.0/16"

  azs             = slice(data.aws_availability_zones.available.names, 0, 2)
  public_subnets  = ["10.0.1.0/24", "10.0.2.0/24"]
  private_subnets = ["10.0.10.0/24", "10.0.11.0/24"]

  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true
  enable_dns_support   = true

  public_subnet_tags = {
    "kubernetes.io/role/elb"                    = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"           = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }

  tags = local.common_tags
}

# ── n8n ───────────────────────────────────────────────────────────────────────

module "n8n" {
  source = "../.."

  aws_partner_attribution_tag = var.aws_partner_attribution_tag

  aws_region      = var.aws_region
  cluster_name    = var.cluster_name
  n8n_domain      = var.n8n_domain
  vpc_id          = module.vpc.vpc_id
  private_subnets = module.vpc.private_subnets
  public_subnets  = module.vpc.public_subnets
  vpc_cidr_block  = module.vpc.vpc_cidr_block
  route53_zone_id = var.route53_zone_id

  n8n_license_key                  = var.n8n_license_key
  n8n_image_repository             = var.n8n_image_repository
  n8n_image_tag                    = var.n8n_image_tag
  n8n_task_runner_image_tag        = var.n8n_task_runner_image_tag
  n8n_task_runner_image_repository = var.n8n_task_runner_image_repository
  n8n_custom_extensions_path       = var.n8n_custom_extensions_path
  n8n_image_pull_secrets           = var.n8n_image_pull_secrets

  n8n_additional_domains = var.n8n_additional_domains

  # ── Execution data ────────────────────────────────────────────────────────────
  # Left at "database" so this example works on any license. At this tier's
  # volume, execution-data writes are usually the dominant write load on the
  # database, so "s3" is the first lever to reach for when RDS is the
  # bottleneck. It reuses the bucket and Pod Identity role the module already
  # creates for binary data, so nothing else changes. Read the execution data
  # section of the root README first: it needs n8n >= 2.27 and an Enterprise
  # license, it does not backfill, and it changes the durability posture of
  # execution history.
  n8n_execution_data_storage_mode = var.n8n_execution_data_storage_mode

  # ── Data-resource deletion controls ─────────────────────────────────────────
  # All of these default to null, which lets the module's own defaults apply.
  # They are exposed here so the medium example's production-considerations
  # checklist can be implemented without wrapping or forking the module.
  db_backup_retention_period   = var.db_backup_retention_period
  db_deletion_protection       = var.db_deletion_protection
  db_skip_final_snapshot       = var.db_skip_final_snapshot
  db_final_snapshot_identifier = var.db_final_snapshot_identifier
  db_delete_automated_backups  = var.db_delete_automated_backups
  s3_force_destroy             = var.s3_force_destroy

  # ── Compute ──────────────────────────────────────────────────────────────────
  # m6i.2xlarge: 8 vCPU, 32 GB. 5 nodes = 40 vCPU / 160 GB cluster.
  # Floor of 5 prevents cold-start scheduling delays during traffic spikes.
  node_instance_type = "m6i.2xlarge"
  node_desired       = 5
  node_min           = 5
  node_max           = 15

  # ── Database ─────────────────────────────────────────────────────────────────
  # db.m6g.2xlarge: 8 vCPU, 32 GB. Memory-optimized keeps the execution_entity
  # working set in shared_buffers. gp3 gives 3,000 baseline IOPS (vs gp2 burst).
  db_instance_class    = "db.m6g.2xlarge"
  db_allocated_storage = 200
  # Storage Autoscaling ceiling: storage can double before it stops growing.
  # Raise db_max_allocated_storage to let it grow further. See the root
  # module's db_max_allocated_storage description before turning it off.
  db_max_allocated_storage = 400

  # ── Redis ─────────────────────────────────────────────────────────────────────
  # Kept at large for this tier. Measured upgrade trigger: the no-op webhook
  # workload capped at 869 req/s on cache.r6g.large and reached 897-906 req/s
  # on cache.r6g.2xlarge (round-2 T-B/T-C passes). If this tier's sustained
  # throughput approaches that figure, move Redis up a size before tuning
  # anything else.
  redis_node_type = "cache.r6g.large"

  # ── Main pods ─────────────────────────────────────────────────────────────────
  # Mains carry neither webhooks (disableProductionWebhooksOnMainProcess) nor
  # manual executions (the chart sets OFFLOAD_MANUAL_EXECUTIONS_TO_WORKERS), so
  # this ceiling tracks concurrent editor and REST API users rather than this
  # tier's executions/day. 24 is 4× the module default, matching how the worker
  # ceiling scales from the default 10 to this tier's 40.
  #
  # Floor of 3 matches the warm-floor approach the webhook and worker pods take
  # here: one leader plus two followers, so a node drain still leaves two serving
  # the editor while the PodDisruptionBudget only guarantees one.
  #
  # Costs 28,800m of the ~115,000m this node group can schedule at the ceiling.
  # At pool_size=10, all maximum replicas (24 main + 50 webhook + 40 worker)
  # expose an aggregate maximum of 1,140 connections against db.m6g.2xlarge's
  # roughly 3,600-connection limit. pg-pool creates these lazily, so measure
  # concurrent database operations and pool-wait time before changing the cap.
  n8n_main_hpa_min_replicas = var.n8n_main_hpa_min_replicas
  n8n_main_hpa_max_replicas = 24

  # ── Webhook processors ────────────────────────────────────────────────────────
  # Minimum floor of 5 ensures warm pods are ready before traffic ramps.
  # Max of 50 raises both the warm floor and the ceiling over the module default
  # (2/4), which this tier's node group has the CPU to schedule.
  # 2 Gi memory limit prevents OOM under concurrent in-flight requests.
  n8n_webhook_hpa_min_replicas = 5
  n8n_webhook_hpa_max_replicas = 50
  n8n_webhook_memory_limit     = "2Gi"

  # ── Workers ───────────────────────────────────────────────────────────────────
  # pool_size=10 is a per-process lazy maximum, not a value derived from worker
  # or workflow concurrency. Keep aggregate database capacity within the budget
  # described above.
  n8n_worker_keda_min_replicas = 5
  n8n_worker_keda_max_replicas = 40
  db_postgresdb_pool_size      = 10

  # ── Execution settings ────────────────────────────────────────────────────────
  # Chart 2.0 rejects setting both n8n_worker_concurrency and
  # n8n_execution_concurrency_limit, so only one can govern per-worker
  # concurrency now. Re-benched on a pre-release chart 2.0 build (the
  # n8n-io/n8n-hosting#250 tree, before `2.0.0-rc.1` was published; not
  # re-run on `2.0.0-rc.1`) after the chart 2.0 move (the 1.x value here
  # was n8n_execution_concurrency_limit = 200, which is what workers actually
  # ran at under 1.x — n8n_worker_concurrency = 20 never took effect because
  # n8n always prefers N8N_CONCURRENCY_PRODUCTION_LIMIT when it is set).
  # Re-benched twice: a CPU-bound workload (light Code node, no $env) and an
  # I/O-bound one (webhook -> HTTP Request node calling an in-cluster
  # endpoint -> Set node), both against this tier's worker CPU budget
  # (n8n_worker_cpu_limit's default of 1000m), KEDA pinned at the floor of 5
  # workers, sweeping n8n_worker_concurrency over 10/20/50/100/200 with
  # 5-minute saturating closed-loop runs:
  #   - CPU-bound: 10 gives ~62 completed executions/s, p95 ~5.1s, worker CPU
  #     pegged at its 1000m limit throughout. 20-50 are flat (~60/s, same CPU
  #     ceiling); 100-200 are slightly down (~58-59/s) with p95 growing to
  #     8.4s and 12.8s — more concurrent work competing for one CPU core adds
  #     scheduling overhead with no throughput to show for it.
  #   - I/O-bound at a fast (500ms) in-cluster call: same story. 10 gives
  #     ~81/s, already CPU-pegged at 1000m; 20-200 are flat-to-worse (~58-60/s,
  #     p95 up to 16s at 200). n8n's own per-execution overhead (data
  #     cloning, execution bookkeeping, queue housekeeping), not the network
  #     wait, is what consumes the CPU, so a sub-second call behaves like a
  #     CPU-bound node: 10 is already enough concurrency to keep the CPU busy,
  #     and more just adds contention.
  #   - I/O-bound at a slow (2s) call — representing a slow upstream API —
  #     inverts this: at 10, worker CPU sits at only ~27% (280m), because each
  #     slot now spends most of its time waiting, not computing, and
  #     throughput is capped at ~24/s by the slot count itself. Raising to 50
  #     restores full CPU utilization and more than doubles throughput to
  #     ~57/s — landing on the same ~60/s ceiling as every other setting,
  #     just reached with more concurrency because each execution occupies
  #     its slot ~4x longer.
  # In every case the ceiling is this tier's worker CPU budget (~60-80/s
  # completed executions across 5 workers at 1000m each, confirmed by RDS
  # staying under 10% CPU and Redis under 4% the entire time — never the
  # constraint). What differs by workload is how much concurrency it takes to
  # reach that ceiling: workflows that are CPU-bound or make fast (sub-second)
  # calls are already there at 10; workflows dominated by slow upstream calls
  # need more concurrency to keep the CPU fed, and should be benched the same
  # way before raising this. n8n_execution_concurrency_limit = 10 with
  # n8n_worker_concurrency = null reproduced the CPU-bound ~60/s, confirming
  # the two knobs are equivalent at this value; n8n_worker_concurrency is kept
  # because it is the knob the module now treats as primary.
  #
  # 10 — n8n's own default — is the right default for this example: it is the
  # measured optimum for CPU-bound and typical fast-call workflows, which is
  # what this tier's sizing otherwise assumes, and the previous effective 200
  # bought no throughput on either shape while costing tail latency. If most
  # of your workflows wait on slow external calls instead, re-bench and raise
  # this (watching worker CPU with `kubectl top`; we saw worker memory grow
  # with concurrency too — up to ~1.3 Gi of the 2Gi n8n_worker_memory_limit at
  # concurrency 200 — so watch that alongside CPU). If CPU is already pegged
  # at low concurrency, as it is for this tier's assumed workload, raise
  # n8n_worker_cpu_limit instead of this; raising concurrency further will not
  # help.
  #
  # Live-scaling validation (KEDA unpinned at this example's real 5-40 bounds,
  # node group left at 5-15, both HPAs at their real bounds): A/B on a
  # stepped load ramp (idle -> 60 -> 120 -> 175 -> 400 req/s, each held
  # several minutes) comparing n8n_worker_concurrency = 10 against the old
  # chart-1.x-equivalent (n8n_worker_concurrency = null,
  # n8n_execution_concurrency_limit = 200). Both reached ~40 workers and
  # ~300-320 completed executions/s at the 400 req/s step, and neither came
  # close to the 15-node ceiling (one extra node beyond the 5-node floor
  # covered 40 workers + 30+ webhook-processor pods); RDS peaked around 50%
  # CPU and ~600-700 connections and Redis around 20-27% CPU — this tier's
  # database and cache sizing holds at the 400 req/s step on both settings.
  # KEDA scaled the worker Deployment itself (confirmed via `kubectl get
  # deployment n8n-worker -o jsonpath='{.spec.replicas}'`, not pinned by the
  # chart), reaching 40 replicas within about 40 seconds of load crossing
  # capacity, and a Helm upgrade applied mid-scale-out (40 replicas) did not
  # reset the Deployment back to any chart default — confirmed replicas
  # stayed at 40 through the upgrade.
  #
  # Where the two settings differ sharply is scaling *visibility* and tail
  # latency, not peak throughput: at concurrency 200, BullMQ lets each worker
  # claim up to 200 jobs into "active" immediately, so bull:jobs:wait (KEDA's
  # primary trigger) stayed at 0 for the entire test even while active queued
  # above 2,900 and p95 latency reached 24-26s at the saturating step — the
  # backlog becomes invisible to the autoscaler and sits queued inside the
  # worker process instead of Redis. At concurrency 10, the same backlog
  # shows up in bull:jobs:wait where KEDA can see and react to it, and p95 at
  # the same step was 10-13s. Concurrency 200 also produced the only
  # `Database ping failed` messages seen in either run (two occurrences,
  # both self-recovered, no pod restarts) during its saturating step, against
  # none at concurrency 10 — DB_PING timeouts show up under this live-scaling
  # test at concurrency 200 but not at concurrency 10, and not at all in the
  # earlier fixed-worker-count sweep above, further evidence for the value
  # below, not a reason to change it.
  # 7-day pruning keeps the execution_entity table at a manageable size without
  # losing useful debugging history. Caveat for sustained high rates: n8n's
  # hard deletion is hardcoded at a 100 executions/s ceiling (~8.6M/day,
  # leader-only), so retention math stops holding as sustained completion
  # rates approach 100/s; see the large example's warning for the mechanism.
  n8n_worker_concurrency = 10
  n8n_pruning_max_age    = 168
  n8n_pruning_max_count  = 500000

  # ── TLS proxy support ───────────────────────────────────────────────────────
  # Outbound CA trust, inbound proxy hop count, and proxy routing env. See
  # docs/tls-proxy.md.
  n8n_extra_ca_pem = var.n8n_extra_ca_pem
  n8n_proxy_hops   = var.n8n_proxy_hops
  n8n_extra_env    = var.n8n_extra_env

  tags = local.common_tags

  depends_on = [module.vpc]
}
