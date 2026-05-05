# ── App DNS ───────────────────────────────────────────────────────────────────

output "alb_hostname" {
  description = "ALB hostname. When route53_zone_id is set, the module already creates the alias record — this output is informational. When certificate_arn is used, create a CNAME: your domain → this value."
  value = try(
    kubernetes_ingress_v1.n8n.status[0].load_balancer[0].ingress[0].hostname,
    "ALB not yet provisioned — run: kubectl get ingress n8n-ingress -n ${var.namespace}"
  )
}

output "n8n_url" {
  description = "URL to access n8n once DNS propagates"
  value       = "https://${local.n8n_domain}"
}

# ── Secrets ────────────────────────────────────────────────────────────────────
# Both values are sensitive — retrieve them with terraform output -raw <name>

output "n8n_encryption_key" {
  description = "n8n encryption key — back this up in a password manager. Losing it makes all stored credentials unreadable."
  value       = random_id.n8n_encryption_key.hex
  sensitive   = true
}

output "db_password" {
  description = "RDS PostgreSQL password — back this up in a password manager."
  value       = random_password.db_password.result
  sensitive   = true
}

# ── Infrastructure ─────────────────────────────────────────────────────────────

output "rds_endpoint" {
  description = "RDS PostgreSQL endpoint"
  value       = aws_db_instance.n8n.address
}

output "redis_endpoint" {
  description = "ElastiCache Redis endpoint"
  value       = aws_elasticache_cluster.n8n.cache_nodes[0].address
}

output "s3_bucket_name" {
  description = "S3 bucket used for n8n binary storage"
  value       = aws_s3_bucket.n8n.bucket
}

output "cluster_name" {
  description = "EKS cluster name"
  value       = aws_eks_cluster.n8n.name
}

output "cluster_endpoint" {
  description = "EKS cluster API endpoint — pass to the kubernetes/helm providers as host."
  value       = aws_eks_cluster.n8n.endpoint
}

output "cluster_certificate_authority_data" {
  description = "Base64-encoded EKS cluster CA certificate — pass to kubernetes/helm providers as cluster_ca_certificate (after base64decode)."
  value       = aws_eks_cluster.n8n.certificate_authority[0].data
}

output "aws_region" {
  description = "AWS region"
  value       = local.aws_region
}

output "kubectl_config_command" {
  description = "Command to configure kubectl for this cluster"
  value       = "aws eks update-kubeconfig --name ${aws_eks_cluster.n8n.name} --region ${local.aws_region}"
}

output "namespace" {
  description = "Kubernetes namespace n8n is deployed into"
  value       = var.namespace
}
