# ── ACM validation CNAME ──────────────────────────────────────────────────────
# ACM will not issue the certificate until you add this CNAME at your DNS
# provider. Fetch both values during the first apply:
#   terraform output -raw acm_validation_cname_name
#   terraform output -raw acm_validation_cname_value

output "acm_validation_cname_name" {
  description = "CNAME record NAME to add at your DNS provider (certificate validation)"
  value       = tolist(aws_acm_certificate.n8n.domain_validation_options)[0].resource_record_name
}

output "acm_validation_cname_value" {
  description = "CNAME record VALUE to add at your DNS provider (certificate validation)"
  value       = tolist(aws_acm_certificate.n8n.domain_validation_options)[0].resource_record_value
}

# ── App DNS + access ──────────────────────────────────────────────────────────

output "alb_hostname" {
  description = "ALB hostname — create a CNAME record: n8n_domain → this value."
  value       = module.n8n.alb_hostname
}

output "n8n_url" {
  description = "URL to access n8n once DNS propagates."
  value       = module.n8n.n8n_url
}

output "kubectl_config_command" {
  description = "Command to configure kubectl for this cluster."
  value       = module.n8n.kubectl_config_command
}

# ── Secrets ───────────────────────────────────────────────────────────────────
# Retrieve with: terraform output -raw <name>

output "n8n_encryption_key" {
  description = "n8n encryption key — back this up in a password manager."
  value       = module.n8n.n8n_encryption_key
  sensitive   = true
}

output "db_password" {
  description = "RDS PostgreSQL password — back this up in a password manager."
  value       = module.n8n.db_password
  sensitive   = true
}
