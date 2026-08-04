locals {
  common_tags = merge(
    {
      ManagedBy = "terraform"
      Project   = "n8n"
    },
    var.tags,
  )
}

# ── VPC ───────────────────────────────────────────────────────────────────────
# /24 private subnets are sufficient for up to ~15 nodes of this size.
# m6i.2xlarge has 4 ENIs × 15 IPs each; 5 nodes × 4 ENIs × 15 IPs = 300 IPs,
# well within the 254 usable IPs per /24.

data "aws_availability_zones" "available" {
  state = "available"
}

module "vpc" {
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

  aws_region      = var.aws_region
  cluster_name    = var.cluster_name
  n8n_domain      = var.n8n_domain
  vpc_id          = module.vpc.vpc_id
  private_subnets = module.vpc.private_subnets
  public_subnets  = module.vpc.public_subnets
  vpc_cidr_block  = module.vpc.vpc_cidr_block
  route53_zone_id = var.route53_zone_id

  n8n_license_key           = var.n8n_license_key
  n8n_image_repository      = var.n8n_image_repository
  n8n_image_tag             = var.n8n_image_tag
  n8n_task_runner_image_tag = var.n8n_task_runner_image_tag

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

  # ── Redis ─────────────────────────────────────────────────────────────────────
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
  # Costs 28,800m of the ~115,000m this node group can schedule at the ceiling,
  # and 240 of db.m6g.2xlarge's ~3,600 connections at pool_size=10.
  n8n_main_hpa_min_replicas = 3
  n8n_main_hpa_max_replicas = 24

  # ── Webhook processors ────────────────────────────────────────────────────────
  # Minimum floor of 5 ensures warm pods are ready before traffic ramps.
  # Max of 50 raises both the warm floor and the ceiling over the module default
  # (2/8), which this tier's node group has the CPU to schedule.
  # 2 Gi memory limit prevents OOM under concurrent in-flight requests.
  n8n_webhook_hpa_min_replicas = 5
  n8n_webhook_hpa_max_replicas = 50
  n8n_webhook_memory_limit     = "2Gi"

  # ── Workers ───────────────────────────────────────────────────────────────────
  # concurrency=20: doubles throughput per pod vs the default 10.
  # pool_size=10 satisfies the rule pool_size >= concurrency / 2 for direct RDS.
  n8n_worker_keda_min_replicas = 5
  n8n_worker_keda_max_replicas = 40
  n8n_worker_concurrency       = 20
  db_postgresdb_pool_size      = 10

  # ── Execution settings ────────────────────────────────────────────────────────
  # Concurrency limit of 200 gives 2× headroom over the worker floor × concurrency.
  # 7-day pruning keeps the execution_entity table at a manageable size without
  # losing useful debugging history.
  n8n_execution_concurrency_limit = 200
  n8n_pruning_max_age             = 168
  n8n_pruning_max_count           = 500000

  tags = local.common_tags

  depends_on = [module.vpc]
}
