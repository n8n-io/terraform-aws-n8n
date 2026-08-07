locals {
  common_tags = merge(
    {
      ManagedBy = "terraform"
      Project   = "n8n"
    },
    var.tags,
  )
}

data "aws_caller_identity" "current" {}

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

# ── Customer-managed S3 bucket (stand-in) ────────────────────────────────────
# Everything in this section is playing the part of infrastructure a customer
# already has running before they ever point this module at it. It is plain
# Terraform, entirely independent of the n8n module: nothing here is created
# by, or known to, module "n8n" below except through existing_s3_bucket_name.
#
# A real customer-managed bucket exercises the same module input without any
# of this: delete this section, and set the module's existing_s3_bucket_name
# to your existing bucket's own name directly. See "Adapting to your real
# infrastructure" in this example's README.
#
# Deliberately secured with its own public-access block and SSE-S3 encryption
# configuration here, entirely independent of the module: s3.tf's design
# leaves a customer-managed bucket's security configuration to its owner, not
# to this module, so this example's stand-in configures its own rather than
# relying on the module to do it.

resource "aws_s3_bucket" "customer_managed" {
  # checkov:skip=CKV_AWS_21:Versioning would defeat n8n's own pruning, same reasoning as this module's own aws_s3_bucket.n8n (s3.tf): n8n prunes execution data in S3 itself, and with versioning enabled those deletes only write delete markers.
  # checkov:skip=CKV_AWS_18:Server access logging needs a second bucket to receive the logs, which this single-bucket stand-in does not create, same reasoning as this module's own aws_s3_bucket.n8n.
  # checkov:skip=CKV_AWS_144:Cross-region replication needs a destination bucket in a second region, which this single-region example does not create.
  # checkov:skip=CKV_AWS_145:Deliberately SSE-S3 (see the encryption configuration below), not SSE-KMS: this stand-in models a plausible minimum-viable customer bucket, not this module's own KMS-by-default posture (s3_kms_encryption_enabled). A real customer-managed bucket's actual encryption is the caller's decision, wired through s3_kms_key_arn if it is SSE-KMS.
  # checkov:skip=CKV2_AWS_61:No lifecycle configuration, by design, same reasoning as this module's own aws_s3_bucket.n8n: leaving object expiry to the caller is the only option that cannot silently delete data n8n still references.
  # checkov:skip=CKV2_AWS_62:Event notifications exist to drive downstream consumers, and nothing in this stand-in or the module consumes S3 events.
  bucket = "customer-managed-n8n-${var.cluster_name}-${data.aws_caller_identity.current.account_id}"

  force_destroy = var.customer_managed_s3_force_destroy

  tags = merge(local.common_tags, { Name = "customer-managed-n8n-${var.cluster_name}" })
}

resource "aws_s3_bucket_public_access_block" "customer_managed" {
  bucket = aws_s3_bucket.customer_managed.id

  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "customer_managed" {
  bucket = aws_s3_bucket.customer_managed.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# ── n8n ───────────────────────────────────────────────────────────────────────
# create_s3_bucket = false: the module creates no S3 bucket, public-access
# block, or encryption configuration of its own, and attaches its IAM policy
# and Pod Identity role to the bucket above instead: exactly as it would at a
# real customer-managed bucket.

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

  # ── Customer-managed S3 wiring ──────────────────────────────────────────────
  create_s3_bucket        = false
  existing_s3_bucket_name = aws_s3_bucket.customer_managed.id

  tags = local.common_tags

  # Explicit module-level dependency ensures the ENTIRE VPC (including NAT
  # gateway routes, IGW, etc.) and the stand-in bucket both stay up until n8n
  # is fully destroyed.
  depends_on = [module.vpc, aws_s3_bucket.customer_managed]
}
