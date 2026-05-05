# ── Locals ────────────────────────────────────────────────────────────────────
# Shared values derived from inputs: input aliases, the common tag set every
# taggable resource merges in, and the deterministic S3 bucket name.

locals {
  # Aliases for inputs so the rest of the module can reference them uniformly.
  # Formerly sourced from the sibling prerequisites workspace via
  # data.terraform_remote_state.
  aws_region      = var.aws_region
  cluster_name    = var.cluster_name
  n8n_domain      = var.n8n_domain
  vpc_id          = var.vpc_id
  private_subnets = var.private_subnets
  public_subnets  = var.public_subnets
  vpc_cidr_block  = var.vpc_cidr_block
  certificate_arn = (
    var.route53_zone_id != null ? aws_acm_certificate_validation.n8n[0].certificate_arn :
    var.cloudflare_zone_id != null ? aws_acm_certificate_validation.n8n_cf[0].certificate_arn :
    var.certificate_arn
  )

  common_tags = merge(
    {
      ManagedBy = "terraform"
      Project   = "n8n"
    },
    var.tags,
  )

  # cluster_name + last 6 digits of the account ID keeps names unique across
  # both clusters in the same account and accounts with the same cluster name.
  s3_bucket_name = "n8n-${local.cluster_name}-${substr(data.aws_caller_identity.current.account_id, 6, 6)}"
}
