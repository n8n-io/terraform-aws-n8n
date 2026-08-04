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
# Same VPC configuration as examples/small — EKS requires subnets in at
# least two availability zones.

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
# dns.tf in this example issues the ACM certificate and validates it via
# Cloudflare DNS records. The validated certificate_arn is passed here so
# the module stays AWS-only.

module "n8n" {
  source = "../.."

  aws_region      = var.aws_region
  cluster_name    = var.cluster_name
  n8n_domain      = var.n8n_domain
  vpc_id          = module.vpc.vpc_id
  private_subnets = module.vpc.private_subnets
  public_subnets  = module.vpc.public_subnets
  vpc_cidr_block  = module.vpc.vpc_cidr_block
  certificate_arn = aws_acm_certificate_validation.n8n.certificate_arn

  n8n_license_key           = var.n8n_license_key
  n8n_image_repository      = var.n8n_image_repository
  n8n_image_tag             = var.n8n_image_tag
  n8n_task_runner_image_tag = var.n8n_task_runner_image_tag

  # ── Execution data ──────────────────────────────────────────────────────────
  # Left at "database" so this example applies without the feat:executionDataS3
  # entitlement. This sizing sees the least traffic but has the least database
  # headroom to absorb it: db.t3.small with 50 GB of gp2 and a 150 IOPS
  # baseline, where sustained execution-data writes burn burst credits and the
  # volume fills. "s3" moves those payloads out of PostgreSQL entirely, reusing
  # the bucket and Pod Identity role the module already creates for binary data,
  # so nothing else changes. Read the execution data section of the root README
  # first: it needs n8n >= 2.27 and an Enterprise license with that entitlement,
  # it does not backfill, and it changes the durability posture of execution
  # history.
  n8n_execution_data_storage_mode = var.n8n_execution_data_storage_mode

  tags = local.common_tags

  # Explicit module-level dependency ensures the ENTIRE VPC (including NAT
  # gateway routes, IGW, etc.) stays up until n8n is fully destroyed. Without
  # this, Terraform may delete NAT routes in parallel — nodes in private
  # subnets lose API-server connectivity, LBC pods die, and the Ingress
  # finalizer can never be removed.
  depends_on = [module.vpc]
}
