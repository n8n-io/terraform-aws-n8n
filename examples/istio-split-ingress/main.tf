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
  # NLB, this one to the public NLB.
  webhook_domain = "${var.webhook_subdomain}.${var.n8n_domain}"
}

# ── VPC ───────────────────────────────────────────────────────────────────────
# Both subnet tag sets matter here, unlike the single-ALB examples. The AWS Load
# Balancer Controller discovers subnets by tag: kubernetes.io/role/elb for the
# internet-facing NLB, kubernetes.io/role/internal-elb for the internal one,
# exactly as it does for the ALB-based examples. A missing internal-elb tag is
# the usual cause of an internal load balancer that never provisions.
#
# A single NAT Gateway keeps costs low. For production HA, set
# single_nat_gateway = false and one_nat_gateway_per_az = true.

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

# ── n8n ───────────────────────────────────────────────────────────────────────
# create_ingress = false hands routing to this example, exactly as it does in
# examples/split-ingress. The module still builds everything the Istio routes
# point at (the n8n-main and n8n-webhook-processor Services) and issues the
# ACM certificate this example's NLBs terminate TLS with (istio_tls_mode =
# "nlb", the default). It stops managing the Route53 alias record it would
# otherwise revert on every plan, since there is no module-owned load balancer
# to point one at.

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
  # gateways.tf attaches it via the module's certificate_arn output when
  # istio_tls_mode = "nlb". Set route53_zone_id, not certificate_arn: the two
  # are mutually exclusive, and the Route 53 path is what lets the module own
  # the certificate.
  route53_zone_id        = var.route53_zone_id
  n8n_additional_domains = [local.webhook_domain]

  # Without this, n8n hands out webhook URLs on the admin host, which resolves
  # to the internal NLB and is unreachable from the internet, so every
  # external caller silently fails to deliver.
  n8n_webhook_url = "https://${local.webhook_domain}"

  n8n_license_key            = var.n8n_license_key
  n8n_image_repository       = var.n8n_image_repository
  n8n_image_tag              = var.n8n_image_tag
  n8n_task_runner_image_tag  = var.n8n_task_runner_image_tag
  n8n_custom_extensions_path = var.n8n_custom_extensions_path
  n8n_image_pull_secrets     = var.n8n_image_pull_secrets

  # ── Execution data ──────────────────────────────────────────────────────────
  # Left at "database" so this example applies without the feat:executionDataS3
  # entitlement. See examples/split-ingress/main.tf for the full rationale;
  # unchanged here.
  n8n_execution_data_storage_mode = var.n8n_execution_data_storage_mode

  tags = local.common_tags

  # Explicit module-level dependency ensures the ENTIRE VPC (including NAT
  # gateway routes, IGW, etc.) stays up until n8n is fully destroyed. Without
  # this, Terraform may delete NAT routes in parallel: nodes in private
  # subnets lose API-server connectivity, the Istio gateway pods die, and
  # Helm's own uninstall can never complete cleanly.
  depends_on = [module.vpc]
}
