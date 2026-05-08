# ── ACM certificate + Cloudflare DNS validation ────────────────────────────────
# This example manages its own ACM certificate and DNS records so the root
# module stays AWS-only. The validated certificate_arn is passed into module.n8n.
#
# Cloudflare note: validation records are created with proxied=false — ACM
# resolves the CNAME directly. The n8n CNAME also defaults to proxied=false.
# To enable Cloudflare proxying, set proxied=true on cloudflare_record.n8n_cname
# and set Cloudflare SSL/TLS mode to "Full (strict)".
#
# Unlike the GoDaddy example, record names are passed as full FQDNs (Cloudflare
# accepts both forms), so n8n_domain can be nested arbitrarily deep below the
# zone (e.g. n8n.prod.example.com under example.com).
#
# We `for_each` on toset([var.n8n_domain]) (a static, plan-time-known key set)
# rather than on aws_acm_certificate.n8n.domain_validation_options (whose keys
# are unknown at plan). This is safe because we only request a certificate for
# a single domain — for a multi-SAN cert, switch to the dynamic-key idiom.

resource "aws_acm_certificate" "n8n" {
  domain_name       = var.n8n_domain
  validation_method = "DNS"

  tags = local.common_tags

  lifecycle {
    create_before_destroy = true
  }
}

locals {
  # Lookup keyed by domain_name. Values are unknown at plan time but the keys
  # in for_each below come from var.n8n_domain, so plan succeeds.
  cert_validation = {
    for o in aws_acm_certificate.n8n.domain_validation_options : o.domain_name => o
  }
}

resource "cloudflare_record" "cert_validation" {
  for_each = toset([var.n8n_domain])

  zone_id = var.cloudflare_zone_id
  # ACM returns FQDNs with trailing dots; strip them before passing to Cloudflare.
  name    = trimsuffix(local.cert_validation[each.key].resource_record_name, ".")
  type    = local.cert_validation[each.key].resource_record_type
  content = local.cert_validation[each.key].resource_record_value
  ttl     = 60
  proxied = false
}

resource "aws_acm_certificate_validation" "n8n" {
  certificate_arn         = aws_acm_certificate.n8n.arn
  validation_record_fqdns = [for r in cloudflare_record.cert_validation : r.hostname]
}

resource "cloudflare_record" "n8n_cname" {
  zone_id = var.cloudflare_zone_id
  name    = var.n8n_domain
  type    = "CNAME"
  content = module.n8n.alb_hostname
  ttl     = 60
  proxied = false

  depends_on = [aws_acm_certificate_validation.n8n]
}
