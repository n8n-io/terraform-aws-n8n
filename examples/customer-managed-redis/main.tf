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
# Identical to examples/small: EKS requires subnets in at least two
# availability zones, and the VPC module handles the subnet tagging EKS and
# the AWS Load Balancer Controller need.

data "aws_availability_zones" "available" {
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

# ── Customer-managed Redis (stand-in) ─────────────────────────────────────────
# Everything in this section is playing the part of infrastructure a customer
# already has running before they ever point this module at it. It is plain
# Terraform, entirely independent of the n8n module: nothing here is created
# by, or known to, module "n8n" below except through the reference variables
# it's wired to (redis_host, redis_auth_token, redis_transit_encryption_enabled).
#
# A real customer-managed Redis exercises the same module inputs without any
# of this: delete this section, and set the module's redis_host /
# redis_auth_token / redis_transit_encryption_enabled to your existing
# replication group's own primary_endpoint_address, AUTH token, and TLS
# posture. See "Adapting to your real infrastructure" in this example's
# README.
#
# Built as a two-node replication group (not the single-node cache cluster
# examples/small's module run creates) because that's what a real production
# customer-managed Redis looks like, and because AUTH tokens only exist on
# replication groups at all (see the root module's redis.tf for the same
# constraint on the module-managed path).

resource "aws_security_group" "customer_managed_redis" {
  # checkov:skip=CKV_AWS_382:Egress-all is intentional, same reasoning as this module's own security groups (redis.tf, database.tf): ElastiCache does not originate arbitrary outbound traffic, and restricting it risks silently breaking AWS API calls routed through the VPC without a matching VPC endpoint, for no real security benefit on a non-internet-facing managed service.
  name        = "customer-managed-redis-sg-${var.cluster_name}"
  description = "Allow Redis access from within the VPC"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description = "Redis from VPC"
    from_port   = 6379
    to_port     = 6379
    protocol    = "tcp"
    cidr_blocks = [module.vpc.vpc_cidr_block]
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, { Name = "customer-managed-redis-sg-${var.cluster_name}" })
}

resource "aws_elasticache_subnet_group" "customer_managed" {
  name       = "customer-managed-redis-subnet-group-${var.cluster_name}"
  subnet_ids = module.vpc.private_subnets

  tags = merge(local.common_tags, { Name = "customer-managed-redis-subnet-group-${var.cluster_name}" })
}

resource "aws_elasticache_replication_group" "customer_managed" {
  replication_group_id = "${var.cluster_name}-cm-redis"
  description          = "Stand-in for a customer-managed Redis, for the customer-managed-redis example"

  engine         = "redis"
  engine_version = "7.1"
  node_type      = var.customer_managed_redis_node_type
  port           = 6379

  num_cache_clusters         = 2
  automatic_failover_enabled = true
  multi_az_enabled           = true

  subnet_group_name  = aws_elasticache_subnet_group.customer_managed.name
  security_group_ids = [aws_security_group.customer_managed_redis.id]

  # checkov:skip=CKV_AWS_191:Encrypted at rest with the ElastiCache-managed key (at_rest_encryption_enabled below), not a Customer Managed Key: this stand-in models a plausible minimum-viable customer Redis, not this module's own CMK-capable posture (redis_kms_encryption_enabled). A real customer-managed Redis's actual key is the caller's decision.
  at_rest_encryption_enabled = true

  # Fresh create, so there's no staged migration to worry about (that dance
  # is only needed changing transit encryption / AUTH on an EXISTING
  # replication group; see the root module's redis.tf and README for why).
  # A first-time create can go straight to "required" plus an AUTH token.
  transit_encryption_enabled = true
  transit_encryption_mode    = "required"
  auth_token                 = var.customer_managed_redis_auth_token

  tags = local.common_tags
}

# ── n8n ───────────────────────────────────────────────────────────────────────
# create_elasticache = false: the module creates no ElastiCache cluster,
# replication group, subnet group, or security group of its own, and wires
# both n8n and the KEDA queue-depth triggers at the replication group above
# instead: exactly as it would at a real customer-managed Redis.

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

  n8n_license_key            = var.n8n_license_key
  n8n_image_repository       = var.n8n_image_repository
  n8n_image_tag              = var.n8n_image_tag
  n8n_task_runner_image_tag  = var.n8n_task_runner_image_tag
  n8n_custom_extensions_path = var.n8n_custom_extensions_path
  n8n_image_pull_secrets     = var.n8n_image_pull_secrets

  n8n_additional_domains          = var.n8n_additional_domains
  n8n_execution_data_storage_mode = var.n8n_execution_data_storage_mode

  # ── Customer-managed Redis wiring ───────────────────────────────────────────
  create_elasticache               = false
  redis_host                       = aws_elasticache_replication_group.customer_managed.primary_endpoint_address
  redis_port                       = 6379
  redis_auth_token                 = var.customer_managed_redis_auth_token
  redis_transit_encryption_enabled = true
  n8n_main_hpa_min_replicas        = var.n8n_main_hpa_min_replicas

  tags = local.common_tags

  # Explicit module-level dependency ensures the ENTIRE VPC (including NAT
  # gateway routes, IGW, etc.) and the stand-in Redis both stay up until n8n
  # is fully destroyed. Without this, Terraform may tear down the VPC or the
  # replication group before n8n's own destroy is done with them.
  depends_on = [module.vpc, aws_elasticache_replication_group.customer_managed]
}
