# ── Cluster access ────────────────────────────────────────────────────────────

output "kubectl_config_command" {
  description = "Command to configure kubectl for this cluster."
  value       = module.n8n.kubectl_config_command
}

output "cluster_name" {
  description = "EKS cluster name. The Load Balancer Controller and Cluster Autoscaler charts need it."
  value       = module.n8n.cluster_name
}

output "vpc_id" {
  description = "VPC ID. The Load Balancer Controller chart needs it."
  value       = module.vpc.vpc_id
}

output "namespace" {
  description = "Namespace to install n8n into. The module does not create it in this example; the S3 Pod Identity association is bound to this name."
  value       = module.n8n.namespace
}

# ── App DNS ───────────────────────────────────────────────────────────────────

output "n8n_url" {
  description = "URL n8n answers on once the Ingress and DNS record you create are in place."
  value       = module.n8n.n8n_url
}

output "certificate_arn" {
  description = "ARN of the validated ACM certificate. Attach it to your Ingress with the alb.ingress.kubernetes.io/certificate-arn annotation."
  value       = module.n8n.certificate_arn
}

# ── Helm values and secrets ───────────────────────────────────────────────────
# Retrieve with: terraform output -raw <name>

output "n8n_helm_values" {
  description = "Values for the n8n Helm chart. Write to a file with terraform output -raw n8n_helm_values > values.yaml and install the chart with it as release n8n."
  value       = module.n8n.n8n_helm_values
  sensitive   = true
}

output "db_password" {
  description = "RDS PostgreSQL password. Goes into the Secret n8n-enterprise-db-secret under the key password."
  value       = module.n8n.db_password
  sensitive   = true
}

output "redis_auth_token" {
  description = "Redis AUTH token, or null when Redis runs without one (the default). When set, it goes into the Secret n8n-enterprise-redis-secret under the key password."
  value       = module.n8n.redis_auth_token
  sensitive   = true
}
