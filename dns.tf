# ── ACM + DNS (Route53 automated path) ────────────────────────────────────────
# Route53 path: issues a DNS-validated ACM certificate and writes an alias
# A-record for n8n_domain — single terraform apply, no manual DNS steps.
#
# Cloudflare and GoDaddy DNS automation lives in the respective examples
# (examples/cloudflare/dns.tf, examples/godaddy/dns.tf). Those examples issue
# the ACM certificate themselves and pass the validated certificate_arn into
# this module. The root module only manages AWS-native DNS.

locals {
  dns_automated = var.route53_zone_id != null

  # The alias A-record points at the ALB the module's own Ingress provisions.
  # With create_ingress = false there is no such ALB to look up, so the record
  # is the caller's to create. The ACM certificate above is still issued, and
  # remains useful for the caller's own Ingresses.
  dns_alias_managed = local.dns_automated && var.create_ingress
}

# ── ACM certificate ────────────────────────────────────────────────────────────

resource "aws_acm_certificate" "n8n" {
  count = local.dns_automated ? 1 : 0

  domain_name       = var.n8n_domain
  validation_method = "DNS"

  tags = local.common_tags

  lifecycle {
    create_before_destroy = true
  }
}

# ── Route53 validation + alias record ─────────────────────────────────────────

resource "aws_route53_record" "cert_validation" {
  # Keyed off var.n8n_domain, not the certificate's own domain_validation_options.
  # The certificate carries a single domain_name and no SANs, so the key is
  # identical either way, but for_each keys have to be known at plan time and
  # domain_validation_options is computed. Deriving the key from the input keeps
  # this plannable on a fresh apply; the record values below stay computed,
  # which for_each permits.
  for_each = local.dns_automated ? toset([var.n8n_domain]) : toset([])

  zone_id         = var.route53_zone_id
  name            = one(aws_acm_certificate.n8n[0].domain_validation_options).resource_record_name
  type            = one(aws_acm_certificate.n8n[0].domain_validation_options).resource_record_type
  records         = [one(aws_acm_certificate.n8n[0].domain_validation_options).resource_record_value]
  ttl             = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "n8n" {
  count = local.dns_automated ? 1 : 0

  certificate_arn         = aws_acm_certificate.n8n[0].arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]
}

resource "aws_route53_record" "n8n_alias" {
  count = local.dns_alias_managed ? 1 : 0

  zone_id = var.route53_zone_id
  name    = var.n8n_domain
  type    = "A"

  alias {
    name                   = data.aws_lb.n8n[0].dns_name
    zone_id                = data.aws_lb.n8n[0].zone_id
    evaluate_target_health = false
  }
}

# ── ALB lookup (Route53 alias record needs zone_id, not just hostname) ─────────
# The AWS Load Balancer Controller provisions the ALB asynchronously after the
# Ingress is created. We look up the ALB by the tags that LBC applies — this is
# more robust than parsing the ALB hostname with a regex, which varies between
# LBC versions and hostname formats.
#
# wait_for_load_balancer = true on kubernetes_ingress_v1.n8n ensures the ALB
# exists before this data source evaluates.

data "aws_lb" "n8n" {
  count = local.dns_alias_managed ? 1 : 0

  tags = {
    "elbv2.k8s.aws/cluster" = local.cluster_name
    "ingress.k8s.aws/stack" = "${var.namespace}/n8n-ingress"
  }

  depends_on = [kubernetes_ingress_v1.n8n]
}
