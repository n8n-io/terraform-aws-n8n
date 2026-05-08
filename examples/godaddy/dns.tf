# ── ACM certificate + GoDaddy DNS validation ──────────────────────────────────
# This example manages its own ACM certificate and DNS records so the root
# module stays AWS-only. The validated certificate_arn is passed into module.n8n.
#
# The record name must be relative to the domain — strip the trailing dot and
# domain suffix that ACM appends to resource_record_name.
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

resource "godaddy-dns_record" "cert_validation" {
  for_each = toset([var.n8n_domain])

  domain = var.godaddy_domain
  # ACM returns FQDNs with trailing dots; strip the dot and parent domain.
  name = trimsuffix(trimsuffix(local.cert_validation[each.key].resource_record_name, "."), ".${var.godaddy_domain}")
  type = local.cert_validation[each.key].resource_record_type
  data = trimsuffix(local.cert_validation[each.key].resource_record_value, ".")
  ttl  = 600
}

resource "aws_acm_certificate_validation" "n8n" {
  certificate_arn = aws_acm_certificate.n8n.arn
  validation_record_fqdns = [
    for r in godaddy-dns_record.cert_validation : "${r.name}.${var.godaddy_domain}"
  ]
}

resource "godaddy-dns_record" "n8n_cname" {
  domain = var.godaddy_domain
  name   = trimsuffix(var.n8n_domain, ".${var.godaddy_domain}")
  type   = "CNAME"
  data   = module.n8n.alb_hostname
  ttl    = 600

  depends_on = [aws_acm_certificate_validation.n8n]
}
