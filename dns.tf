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
  for_each = local.dns_automated ? {
    for o in aws_acm_certificate.n8n[0].domain_validation_options : o.domain_name => {
      name   = o.resource_record_name
      type   = o.resource_record_type
      record = o.resource_record_value
    }
  } : {}

  zone_id         = var.route53_zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.record]
  ttl             = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "n8n" {
  count = local.dns_automated ? 1 : 0

  certificate_arn         = aws_acm_certificate.n8n[0].arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]
}

resource "aws_route53_record" "n8n_alias" {
  count = local.dns_automated ? 1 : 0

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

data "aws_lb" "n8n" {
  count = local.dns_automated ? 1 : 0

  tags = {
    "elbv2.k8s.aws/cluster" = local.cluster_name
    "ingress.k8s.aws/stack" = "${var.namespace}/n8n-ingress"
  }

  depends_on = [kubernetes_ingress_v1.n8n]
}
