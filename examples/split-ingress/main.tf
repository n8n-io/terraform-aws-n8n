locals {
  common_tags = merge(
    {
      ManagedBy = "terraform"
      Project   = "n8n"
    },
    var.tags,
  )

  # Webhook traffic is served from its own hostname because a single DNS name
  # can only alias one load balancer. The admin host resolves to the internal
  # ALB, this one to the public ALB.
  webhook_domain = "${var.webhook_subdomain}.${var.n8n_domain}"
}

# ── VPC ───────────────────────────────────────────────────────────────────────
# Both subnet tag sets matter here, unlike the single-ALB examples. The AWS Load
# Balancer Controller discovers subnets by tag: kubernetes.io/role/elb for the
# internet-facing ALB, kubernetes.io/role/internal-elb for the internal one. A
# missing internal-elb tag is the usual cause of an internal Ingress that never
# provisions an ALB.
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

# ── n8n ───────────────────────────────────────────────────────────────────────
# create_ingress = false hands routing to this example. The module still builds
# everything the Ingresses point at, and stops managing the Route53 alias record
# it would otherwise revert on every plan.

module "n8n" {
  source = "../.."

  aws_region      = var.aws_region
  cluster_name    = var.cluster_name
  n8n_domain      = var.n8n_domain
  vpc_id          = module.vpc.vpc_id
  private_subnets = module.vpc.private_subnets
  public_subnets  = module.vpc.public_subnets
  vpc_cidr_block  = module.vpc.vpc_cidr_block

  create_ingress = false

  # The module issues and validates one certificate covering both hostnames.
  # ingress.tf attaches it via the module's certificate_arn output. Set
  # route53_zone_id, not certificate_arn: the two are mutually exclusive, and
  # the Route 53 path is what lets the module own the certificate.
  route53_zone_id        = var.route53_zone_id
  n8n_additional_domains = [local.webhook_domain]

  # Without this, n8n hands out webhook URLs on the admin host, which resolves
  # to the internal ALB and is unreachable from the internet, so every external
  # caller silently fails to deliver.
  n8n_webhook_url = "https://${local.webhook_domain}"

  n8n_license_key = var.n8n_license_key
  n8n_image_tag   = var.n8n_image_tag

  tags = local.common_tags

  # Explicit module-level dependency ensures the ENTIRE VPC (including NAT
  # gateway routes, IGW, etc.) stays up until n8n is fully destroyed. Without
  # this, Terraform may delete NAT routes in parallel: nodes in private
  # subnets lose API-server connectivity, LBC pods die, and the Ingress
  # finalizer can never be removed.
  depends_on = [module.vpc]
}
