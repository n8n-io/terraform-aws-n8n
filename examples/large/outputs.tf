# ── App DNS + access ──────────────────────────────────────────────────────────

output "alb_hostname" {
  description = "ALB hostname. The alias A-record for n8n_domain is already created in Route53 — this output is informational."
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
  description = "Kubernetes namespace n8n is deployed into."
  value       = module.n8n.namespace
}

# ── Database ──────────────────────────────────────────────────────────────────

output "aurora_writer_endpoint" {
  description = "Aurora cluster writer endpoint — used by PgBouncer to connect to the primary instance."
  value       = aws_rds_cluster.n8n.endpoint
}

output "aurora_reader_endpoint" {
  description = "Aurora cluster reader endpoint — use this for read-only reporting queries."
  value       = aws_rds_cluster.n8n.reader_endpoint
}

# ── Secrets ───────────────────────────────────────────────────────────────────
# Retrieve with: terraform output -raw <name>

output "n8n_encryption_key" {
  description = "n8n encryption key — back this up in a password manager."
  value       = module.n8n.n8n_encryption_key
  sensitive   = true
}

output "db_password" {
  description = "Aurora PostgreSQL password — back this up in a password manager."
  value       = module.n8n.db_password
  sensitive   = true
}
