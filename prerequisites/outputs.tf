# ── Re-exported inputs ────────────────────────────────────────────────────────
# The root module reads these back out of state instead of declaring the same
# variables again. Set them once here.

output "aws_region" {
  description = "AWS region the VPC and certificate were created in"
  value       = var.aws_region
}

output "cluster_name" {
  description = "EKS cluster name the root module must use (subnet tags reference this)"
  value       = var.cluster_name
}

output "n8n_domain" {
  description = "Domain name the ACM certificate was issued for"
  value       = var.n8n_domain
}

# ── Network ───────────────────────────────────────────────────────────────────

output "vpc_id" {
  description = "VPC ID — used by the AWS Load Balancer Controller and security groups in the root module"
  value       = module.vpc.vpc_id
}

output "private_subnets" {
  description = "Private subnet IDs — nodes, RDS, and ElastiCache attach here"
  value       = module.vpc.private_subnets
}

output "public_subnets" {
  description = "Public subnet IDs — the ALB attaches here"
  value       = module.vpc.public_subnets
}

output "vpc_cidr_block" {
  description = "VPC CIDR block — used by RDS and Redis security groups to allow intra-VPC traffic"
  value       = module.vpc.vpc_cidr_block
}

# ── Certificate ───────────────────────────────────────────────────────────────

output "certificate_arn" {
  description = "ARN of the validated ACM certificate — wired into the ALB Ingress by the root module"
  value       = aws_acm_certificate_validation.n8n.certificate_arn
}

# ── Certificate validation CNAME ──────────────────────────────────────────────
# Add these as a CNAME record at your DNS provider to prove domain ownership.
# ACM will not issue the certificate until this record exists.

output "acm_validation_cname_name" {
  description = "CNAME record NAME to add at your DNS provider (certificate validation)"
  value       = tolist(aws_acm_certificate.n8n.domain_validation_options)[0].resource_record_name
}

output "acm_validation_cname_value" {
  description = "CNAME record VALUE to add at your DNS provider (certificate validation)"
  value       = tolist(aws_acm_certificate.n8n.domain_validation_options)[0].resource_record_value
}
