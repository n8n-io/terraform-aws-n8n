# ── App DNS + access ──────────────────────────────────────────────────────────

output "alb_hostname" {
  description = "ALB hostname. The CNAME for n8n_domain is already created in Cloudflare — this output is informational."
  value       = module.n8n.alb_hostname
}

output "n8n_url" {
  description = "URL to access n8n once the ALB finishes provisioning (~5 min after apply)."
  value       = module.n8n.n8n_url
}

output "kubectl_config_command" {
  description = "Command to configure kubectl for this cluster."
  value       = module.n8n.kubectl_config_command
}

output "namespace" {
  description = "Kubernetes namespace n8n is deployed into. Read by tests/scripts/smoke-test.sh."
  value       = module.n8n.namespace
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
