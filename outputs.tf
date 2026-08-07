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
  description = "Name of the Kubernetes Service fronting the n8n main pods (the editor UI and REST API), on port 5678. Point a customer-managed Ingress at this when create_ingress = false."
  value       = local.n8n_service_name
}

output "n8n_webhook_service_name" {
  description = "Name of the Kubernetes Service fronting the n8n webhook processors, on port 5678. Production webhooks are disabled on the main pods, so a customer-managed Ingress must route /webhook here."
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
  description = "n8n encryption key, back this up in a password manager. Losing it makes all stored credentials unreadable. Also the value to pass as var.n8n_encryption_key when restoring this database (e.g. an RDS snapshot) into a new stack, so the new deployment can still decrypt it."
  value       = local.n8n_encryption_key
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
  description = "Redis host n8n and KEDA connect to. The single cache node's address by default; the replication group's primary endpoint when redis_high_availability_enabled or redis_transit_encryption_enabled is true, which is the name AWS repoints at the surviving node on failover; or the value of var.redis_host when create_elasticache = false. Reached over TLS and requiring redis_auth_token when redis_transit_encryption_enabled = true and redis_transit_encryption_mode = \"required\" (the default); with redis_transit_encryption_mode = \"preferred\", the transitional state used while migrating an existing replication group, the endpoint still accepts plaintext and there is no token."
  value       = local.redis_host
}

output "redis_auth_token" {
  description = "The Redis AUTH token in effect, or null when there is none. Module-generated when create_elasticache = true and redis_transit_encryption_enabled = true (AWS requires transit_encryption_mode = \"required\" before the token exists; see the variable). Echoes var.redis_auth_token back when create_elasticache = false and it was supplied. Also null when redis_auth_token_secret_ref is set instead: the token then lives in a Secret the module never reads. Retrieve with: terraform output -raw redis_auth_token"
  value       = (local.redis_auth_active && var.redis_auth_token_secret_ref == null) ? local.redis_auth_token_value : null
  sensitive   = true
}

output "redis_port" {
  description = "Port n8n and KEDA connect to Redis on. Always 6379 for module-managed ElastiCache; the value of var.redis_port when create_elasticache = false. Paired with redis_endpoint so a caller wiring its own queue-depth scaler or a debug pod does not have to assume the port."
  value       = local.redis_port
}

output "s3_bucket_name" {
  description = "S3 bucket used for n8n binary storage, and for execution data when n8n_execution_data_storage_mode = \"s3\". Module-managed when create_s3_bucket = true (the default), or the value of var.existing_s3_bucket_name when using an existing bucket. The module attaches no lifecycle configuration: binary data is pruned only by S3 while execution data is pruned by n8n itself, and the two cannot be separated by a prefix filter. Read the S3 lifecycle section of the README before attaching one."
  value       = local.s3_bucket_name
}

output "cluster_name" {
  description = "EKS cluster name: the cluster this module created (create_eks = true, the default), or the value of existing_eks_cluster_name when create_eks = false."
  value       = local.eks_cluster_name
}

output "cluster_endpoint" {
  description = "EKS cluster API endpoint, resolved the same way as cluster_name. Pass to the kubernetes/helm providers as host."
  value       = local.eks_cluster_endpoint
}

output "cluster_certificate_authority_data" {
  description = "Base64-encoded EKS cluster CA certificate, resolved the same way as cluster_name. Pass to kubernetes/helm providers as cluster_ca_certificate (after base64decode)."
  value       = local.eks_cluster_ca_data
}

output "node_group_role_arn" {
  description = "IAM role ARN the EKS node group runs under, and therefore the principal the kubelet pulls container images as. Name it in a cross-account ECR repository policy to let this cluster pull a custom n8n image from a registry in another account, which is the mechanism to reach for there: an ECR authorization token lasts 12 hours, so an imagePullSecrets holding one goes stale long before the next apply. For registries that issue static credentials, use n8n_image_pull_secrets instead. Null when create_eks = false: the module creates no node group on that path, and an existing node group's role (if the caller even runs a conventional EKS-managed one) is not something this module can discover generically."
  value       = var.create_eks ? aws_iam_role.nodes[0].arn : null
}

output "aws_region" {
  description = "AWS region"
  value       = local.aws_region
}

output "kubectl_config_command" {
  description = "Command to configure kubectl for this cluster"
  value       = "aws eks update-kubeconfig --name ${local.eks_cluster_name} --region ${local.aws_region}"
}

output "namespace" {
  description = "Kubernetes namespace n8n is deployed into."
  # Deliberately sourced from local.namespace_name rather than var.namespace
  # directly. On the create_namespace = true path (the default), that local
  # reads the resource attribute rather than the plan-time-constant variable,
  # so a caller's own kubernetes_* resources referencing this output get a
  # dependency edge on the namespace; without it Terraform schedules them
  # concurrently and they fail with `namespaces "n8n" not found`. That trap is
  # easy to hit on the create_ingress = false path, where the caller's
  # Ingresses are the first thing to reference this output. On the
  # create_namespace = false path there is no module-owned namespace resource
  # to depend on, so the local is just var.namespace, and there is nothing for
  # a consumer to wait on: the namespace already existed before this apply.
  value = local.namespace_name
}
