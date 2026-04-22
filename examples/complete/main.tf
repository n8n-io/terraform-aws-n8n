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
# EKS requires subnets in at least two availability zones. The VPC module
# handles the subnet tagging EKS and the AWS Load Balancer Controller need.
#
# A single NAT Gateway keeps costs low. For production HA, set
# single_nat_gateway = false and one_nat_gateway_per_az = true.

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

# ── ACM certificate ───────────────────────────────────────────────────────────
# Requests a TLS certificate for n8n_domain using DNS validation. AWS will not
# issue the certificate until you add the validation CNAME at your DNS provider.
# aws_acm_certificate_validation blocks for up to 15 minutes during apply; fetch
# the CNAME from the outputs during that window and add it at your registrar.

resource "aws_acm_certificate" "n8n" {
  domain_name       = var.n8n_domain
  validation_method = "DNS"

  tags = local.common_tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_acm_certificate_validation" "n8n" {
  certificate_arn = aws_acm_certificate.n8n.arn

  timeouts {
    create = "15m"
  }
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
  certificate_arn = aws_acm_certificate_validation.n8n.certificate_arn

  n8n_license_key = var.n8n_license_key

  tags = local.common_tags
}
