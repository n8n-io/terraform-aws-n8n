# ── App DNS + access ──────────────────────────────────────────────────────────

output "alb_hostname" {
  description = "ALB hostname. The alias A-record for n8n_domain is already created in Route53. This output is informational."
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

# ── Customer-managed EKS cluster (stand-in) ──────────────────────────────────
# In a real deployment this would already be known: your existing cluster's
# own name. This output exists only so this example is self-demonstrating.

output "customer_managed_cluster_name" {
  description = "Name of the stand-in EKS cluster this example creates, playing the part of a platform team's already-existing cluster. This is the value that fills module.n8n's existing_eks_cluster_name in this example; in a real deployment it would be your own cluster's name instead."
  value       = aws_eks_cluster.customer_managed.name
}

# ── Secrets ───────────────────────────────────────────────────────────────────
# Retrieve with: terraform output -raw <name>

output "n8n_encryption_key" {
  description = "n8n encryption key. Back this up in a password manager."
  value       = module.n8n.n8n_encryption_key
  sensitive   = true
}

output "db_password" {
  description = "RDS PostgreSQL password. Back this up in a password manager."
  value       = module.n8n.db_password
  sensitive   = true
}
