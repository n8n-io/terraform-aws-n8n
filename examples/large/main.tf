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
# /20 private subnets are mandatory at this node count. m7i.4xlarge has 8 ENIs
# × 30 IPs each. With WARM_ENI_TARGET=1 (default), 25 nodes pre-warm
# 25 × 8 × 30 = 6,000 IPs — exhausting two /24s (508 usable IPs total) before
# any pod is scheduled. Two /20s give 8,188 usable IPs with ample headroom.
#
# The VPC CNI addon (below) locks WARM_ENI_TARGET=0 so warm pools consume only
# 2 IPs per node instead of a full ENI worth. Without this, even /20s can
# exhaust under rolling upgrades when old + new nodes overlap.
#
# Two NAT Gateways (one per AZ) prevent a single NAT from becoming an HA
# bottleneck at this traffic volume.

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
  private_subnets = ["10.0.64.0/20", "10.0.80.0/20"]

  enable_nat_gateway     = true
  single_nat_gateway     = false
  one_nat_gateway_per_az = true
  enable_dns_hostnames   = true
  enable_dns_support     = true

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
  certificate_arn = var.certificate_arn

  n8n_license_key = var.n8n_license_key

  # ── External database (Aurora) via PgBouncer ──────────────────────────────────
  # Aurora is created in aurora.tf, PgBouncer in pgbouncer.tf. n8n connects to
  # the PgBouncer ClusterIP service in the `pgbouncer` namespace; PgBouncer
  # terminates SSL on its upstream leg to Aurora.
  #
  # create_database = false tells the module to skip creating its own RDS
  # instance and use db_host / db_password instead. The flag is a static
  # boolean so the module's `count` expressions resolve at plan time —
  # `db_host` itself is computed (known after apply) and can't gate count.
  #
  # db_postgresdb_ssl_enabled = false because PgBouncer<->Aurora handles SSL;
  # the n8n -> PgBouncer leg is plain TCP within the cluster.
  create_database           = false
  db_host                   = "${kubernetes_service.pgbouncer.metadata[0].name}.${kubernetes_namespace.pgbouncer.metadata[0].name}.svc.cluster.local"
  db_password               = random_password.aurora.result
  db_postgresdb_ssl_enabled = false

  # ── Compute ───────────────────────────────────────────────────────────────────
  # m7i.4xlarge: 16 vCPU, 64 GB. Intel x86_64 — required with AL2023_x86_64_STANDARD
  # AMI type. Graviton (m7g.*) requires AL2023_ARM_64_STANDARD.
  # Floor of 10 keeps scheduling warm; 50 max covers 2,400 req/s peak.
  node_instance_type = "m7i.4xlarge"
  node_desired       = 10
  node_min           = 10
  node_max           = 50

  # ── Redis ─────────────────────────────────────────────────────────────────────
  redis_node_type = "cache.r6g.large"

  # ── DB pool per n8n pod ───────────────────────────────────────────────────────
  # 5 TypeORM slots per pod. In transaction mode, PgBouncer queues connections
  # for the ~1ms they are needed — pool of 5 handles concurrency=40 without
  # timeouts. PgBouncer's own server-pool sizing lives in pgbouncer.tf.
  db_postgresdb_pool_size = 5

  # ── Webhook processors ────────────────────────────────────────────────────────
  # Floor of 30: 10 pods saturated at ~960 req/s in benchmarks; 30 handles
  # 500 concurrent VUs cleanly. 4 Gi memory limit halved failure rate vs 2 Gi
  # under sustained 500 VU load.
  n8n_webhook_hpa_min_replicas = 30
  n8n_webhook_hpa_max_replicas = 80
  n8n_webhook_memory_request   = "1Gi"
  n8n_webhook_memory_limit     = "4Gi"

  # ── Workers ───────────────────────────────────────────────────────────────────
  # concurrency=40: doubles throughput per pod vs 20, halves pod count needed.
  # 856 req/s target ÷ concurrency=40 = 22 workers at steady state.
  # Floor of 20 keeps the queue draining during idle periods.
  n8n_worker_keda_min_replicas = 20
  n8n_worker_keda_max_replicas = 160
  n8n_worker_concurrency       = 40

  # ── Execution settings ────────────────────────────────────────────────────────
  # Raise the hard concurrency cap from 100 to 2,000 — the default throttles
  # workers before any infrastructure bottleneck at this scale.
  # 24-hour pruning is critical at this throughput: 14-day retention rapidly
  # accumulates hundreds of millions of rows in execution_entity, and
  # autovacuum cannot keep up with concurrent write load at that table size.
  n8n_execution_concurrency_limit = 2000
  n8n_pruning_max_age             = 24
  n8n_pruning_max_count           = 5000000

  # ── Helm timeout ──────────────────────────────────────────────────────────────
  # Default 600s is too tight for ~52 pods at min replicas (and up to 240+ at
  # max). 1800s gives time for image pulls, init containers, and KEDA/HPA
  # propagation across the cluster.
  n8n_helm_timeout = 1800

  tags = local.common_tags

  depends_on = [module.vpc, aws_rds_cluster_instance.writer]
}

# ── VPC CNI warm-IP tuning ────────────────────────────────────────────────────
# Default WARM_ENI_TARGET=1 pre-warms one full ENI per node. On m7i.4xlarge
# (8 ENIs × 30 IPs), 10 nodes exhaust a /20 before any pod is scheduled.
# WARM_IP_TARGET=2 limits the warm pool to 2 IPs per node — 10 nodes use
# only 20 IPs instead of 2,400, leaving subnets viable at full scale.
# This must be applied after the cluster exists — depends_on enforces ordering.

resource "aws_eks_addon" "vpc_cni" {
  cluster_name                = module.n8n.cluster_name
  addon_name                  = "vpc-cni"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  configuration_values = jsonencode({
    env = {
      WARM_ENI_TARGET   = "0"
      WARM_IP_TARGET    = "2"
      MINIMUM_IP_TARGET = "2"
    }
  })

  depends_on = [module.n8n]
}
