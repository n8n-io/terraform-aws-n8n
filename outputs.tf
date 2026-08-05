# ── App DNS ───────────────────────────────────────────────────────────────────

output "certificate_arn" {
  description = "ARN of the ACM certificate n8n is served with. When route53_zone_id is set this is the module-issued certificate, already validated, covering n8n_domain plus every entry in n8n_additional_domains. When certificate_arn is supplied instead, it is echoed back unchanged. A caller owning its own Ingress resources (create_ingress = false) attaches this to their alb.ingress.kubernetes.io/certificate-arn annotation, which lets the module issue and validate a multi-name certificate on their behalf rather than the caller hand-rolling one. Sourced from aws_acm_certificate_validation, so consuming it orders the caller's resources after validation completes."
  value       = local.certificate_arn
}

output "alb_hostname" {
  description = "ALB hostname of the module-managed Ingress. When route53_zone_id is set, the module already creates the alias record, so this output is informational. When certificate_arn is used, create a CNAME: your domain → this value. Null when create_ingress = false, since the caller then owns the load balancers."
  value = var.create_ingress ? try(
    kubernetes_ingress_v1.n8n[0].status[0].load_balancer[0].ingress[0].hostname,
    "ALB not yet provisioned — run: kubectl get ingress n8n-ingress -n ${var.namespace}"
  ) : null
}

output "n8n_service_name" {
  description = "Name of the Kubernetes Service fronting the n8n main pods (the editor UI and REST API), on port 5678. Point a bring-your-own Ingress at this when create_ingress = false."
  value       = local.n8n_service_name
}

output "n8n_webhook_service_name" {
  description = "Name of the Kubernetes Service fronting the n8n webhook processors, on port 5678. Production webhooks are disabled on the main pods, so a bring-your-own Ingress must route /webhook here."
  value       = local.n8n_webhook_service_name
}

output "n8n_webhook_path_prefixes" {
  description = "Path prefixes that must be routed to n8n_webhook_service_name rather than n8n_service_name. The main pods run with production webhooks disabled, so every one of these returns 404 if it reaches them: /webhook, /webhook-waiting (also carries the Slack and Telegram human-in-the-loop callbacks), /form, /form-waiting, and /mcp. Route all of them when building your own Ingress with create_ingress = false."
  value       = local.n8n_webhook_path_prefixes
}

output "n8n_service_port" {
  description = "Port both n8n Services listen on. Use with n8n_service_name / n8n_webhook_service_name when building your own Ingress."
  value       = local.n8n_service_port
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
  description = "Database password — module-managed when create_database = true, or the value of var.db_password when using an external database. Retrieve with: terraform output -raw db_password"
  value       = var.create_database ? random_password.db_password.result : var.db_password
  sensitive   = true
}

# ── Infrastructure ─────────────────────────────────────────────────────────────

output "rds_endpoint" {
  description = "Database endpoint — module-managed RDS when create_database = true, or the value of var.db_host when using an external database (e.g. Aurora)."
  value       = var.create_database ? aws_db_instance.n8n[0].address : var.db_host
}

output "redis_endpoint" {
  description = "ElastiCache Redis endpoint"
  value       = aws_elasticache_cluster.n8n.cache_nodes[0].address
}

output "s3_bucket_name" {
  description = "S3 bucket used for n8n binary storage, and for execution data when n8n_execution_data_storage_mode = \"s3\". The module attaches no lifecycle configuration: binary data is pruned only by S3 while execution data is pruned by n8n itself, and the two cannot be separated by a prefix filter. Read the S3 lifecycle section of the README before attaching one."
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
  description = "Kubernetes namespace n8n is deployed into."
  # Deliberately sourced from the resource rather than var.namespace. Returning
  # the variable makes this a plan-time constant, which leaves a caller's own
  # kubernetes_* resources with no dependency edge to the namespace: Terraform
  # schedules them concurrently and they fail with `namespaces "n8n" not found`.
  # That trap is easy to hit on the create_ingress = false path, where the
  # caller's Ingresses are the first thing to reference this output. Reading the
  # resource attribute gives every consumer the dependency implicitly.
  value = kubernetes_namespace.n8n.metadata[0].name
}
