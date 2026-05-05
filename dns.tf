# ── ACM + DNS (automated paths) ───────────────────────────────────────────────
# Two automated DNS paths: Route53 (dns_automated) and Cloudflare (dns_cloudflare).
# Both issue a DNS-validated ACM certificate and write the DNS record for
# n8n_domain so a single terraform apply completes the deployment end to end.
# When both are null, the caller supplies a pre-validated certificate_arn.
#
# Shared resources (ACM cert, ALB lookup) are gated on either path being active.
#
# Cloudflare note: validation records are created with proxied=false — ACM
# resolves the CNAME directly. The n8n CNAME also defaults to proxied=false.
# To enable Cloudflare proxying, set proxied=true on cloudflare_record.n8n_cname
# and set Cloudflare SSL/TLS mode to "Full (strict)".

locals {
  dns_automated  = var.route53_zone_id != null
  dns_cloudflare = var.cloudflare_zone_id != null
}

# ── ACM certificate (shared by both automated paths) ──────────────────────────

resource "aws_acm_certificate" "n8n" {
  count = (local.dns_automated || local.dns_cloudflare) ? 1 : 0

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

# ── Cloudflare validation + CNAME record ──────────────────────────────────────

resource "cloudflare_record" "cert_validation" {
  for_each = local.dns_cloudflare ? {
    for o in aws_acm_certificate.n8n[0].domain_validation_options : o.domain_name => {
      name    = o.resource_record_name
      type    = o.resource_record_type
      content = o.resource_record_value
    }
  } : {}

  zone_id = var.cloudflare_zone_id
  # ACM returns FQDNs with trailing dots; strip them before passing to Cloudflare.
  name    = trimsuffix(each.value.name, ".")
  type    = each.value.type
  content = each.value.content
  ttl     = 60
  proxied = false
}

resource "aws_acm_certificate_validation" "n8n_cf" {
  count = local.dns_cloudflare ? 1 : 0

  certificate_arn         = aws_acm_certificate.n8n[0].arn
  validation_record_fqdns = [for r in cloudflare_record.cert_validation : r.hostname]
}

resource "cloudflare_record" "n8n_cname" {
  count = local.dns_cloudflare ? 1 : 0

  zone_id = var.cloudflare_zone_id
  name    = var.n8n_domain
  type    = "CNAME"
  content = data.aws_lb.n8n[0].dns_name
  ttl     = 60
  proxied = false

  depends_on = [aws_acm_certificate_validation.n8n_cf]
}

# ── ALB lookup (shared by both automated paths) ────────────────────────────────
# The AWS Load Balancer Controller provisions the ALB asynchronously after the
# Ingress is created. We look up the ALB by the tags that LBC applies — this is
# more robust than parsing the ALB hostname with a regex, which varies between
# LBC versions and hostname formats.
#
# wait_for_load_balancer = true on the Ingress resource ensures the ALB exists
# before this data source evaluates.

data "aws_lb" "n8n" {
  count = (local.dns_automated || local.dns_cloudflare) ? 1 : 0

  tags = {
    "elbv2.k8s.aws/cluster" = local.cluster_name
    "ingress.k8s.aws/stack" = "${var.namespace}/n8n-ingress"
  }

  depends_on = [kubernetes_ingress_v1.n8n]
}
