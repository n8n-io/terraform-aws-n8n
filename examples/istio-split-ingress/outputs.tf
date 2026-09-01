# ── App DNS + access ──────────────────────────────────────────────────────────

output "n8n_url" {
  description = "URL for the n8n editor UI. Resolves to the internal NLB, so it is reachable only from inside the VPC or over VPN."
  value       = "https://${var.n8n_domain}"
}

output "webhook_base_url" {
  description = "Public base URL for webhooks, forms and MCP. This is what n8n hands out in generated webhook URLs (passed to the module as n8n_webhook_url)."
  value       = "https://${local.webhook_domain}"
}

output "webhook_nlb_hostname" {
  description = "Hostname of the internet-facing Network Load Balancer fronting the public Istio ingress gateway."
  value       = data.aws_lb.webhook_public.dns_name
}

output "admin_nlb_hostname" {
  description = "Hostname of the internal Network Load Balancer fronting the internal Istio ingress gateway."
  value       = data.aws_lb.admin_internal.dns_name
}

output "webhook_path_prefixes" {
  description = "Path prefixes routed to the webhook processors on the public gateway. Sourced from the module so this example cannot drift from what n8n actually serves."
  value       = module.n8n.n8n_webhook_path_prefixes
}

output "istio_tls_mode" {
  description = "Which of the two TLS termination paths is live: \"nlb\" (both NLBs terminate TLS with module.n8n.certificate_arn) or \"gateway\" (Envoy terminates TLS itself from the BYO PEM secrets in gateway-tls.tf)."
  value       = var.istio_tls_mode
}

output "kubectl_config_command" {
  description = "Command to configure kubectl for this cluster."
  value       = module.n8n.kubectl_config_command
}

output "namespace" {
  description = "Kubernetes namespace n8n is deployed into."
  value       = module.n8n.namespace
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
