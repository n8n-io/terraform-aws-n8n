# ── App DNS + access ──────────────────────────────────────────────────────────
# module.n8n.alb_hostname is null here: create_ingress = false means the
# module owns no ALB. n8n_url and alb_hostname below are this example's own,
# sourced from ingress.tf/dns.tf instead.

output "n8n_url" {
  description = "URL to access n8n once the ALB finishes provisioning (~5 min after apply)."
  value       = "https://${var.n8n_domain}"
}

output "alb_hostname" {
  description = "Hostname of the ALB this example's own Ingress provisions, via the directly-invoked module.controllers' Load Balancer Controller. The alias A-record for n8n_domain already points at it."
  value       = data.aws_lb.n8n.dns_name
}

output "kubectl_config_command" {
  description = "Command to configure kubectl for this cluster."
  value       = module.n8n.kubectl_config_command
}

output "namespace" {
  description = "Kubernetes namespace n8n is deployed into."
  value       = module.n8n.namespace
}

# ── Customer-managed infrastructure (stand-ins) ──────────────────────────────
# In a real deployment each of these would already be known: your own
# existing cluster, database, cache and bucket. These outputs exist only so
# this example is self-demonstrating.

output "customer_managed_cluster_name" {
  description = "Name of the stand-in EKS cluster this example creates, playing the part of a platform team's already-existing cluster. This is the value that fills module.n8n's existing_eks_cluster_name in this example."
  value       = aws_eks_cluster.customer_managed.name
}

output "customer_managed_rds_endpoint" {
  description = "Address of the stand-in RDS instance this example creates, playing the part of a customer's already-existing database. This is the value that fills module.n8n's db_host in this example."
  value       = aws_db_instance.customer_managed.address
}

output "customer_managed_redis_endpoint" {
  description = "Primary endpoint of the stand-in replication group this example creates, playing the part of a customer's existing Redis. This is the value that fills module.n8n's redis_host in this example."
  value       = aws_elasticache_replication_group.customer_managed.primary_endpoint_address
}

output "customer_managed_s3_bucket_name" {
  description = "Name of the stand-in bucket this example creates, playing the part of a customer's existing S3 bucket. This is the value that fills module.n8n's existing_s3_bucket_name in this example."
  value       = aws_s3_bucket.customer_managed.id
}

# ── Secrets ───────────────────────────────────────────────────────────────────
# Retrieve with: terraform output -raw <name>

output "n8n_encryption_key" {
  description = "n8n encryption key. Back this up in a password manager."
  value       = module.n8n.n8n_encryption_key
  sensitive   = true
}

output "db_password" {
  description = "RDS PostgreSQL password in effect. Echoes customer_managed_db_password back in this example, since create_database = false."
  value       = module.n8n.db_password
  sensitive   = true
}

