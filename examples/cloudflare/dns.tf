# ── ACM certificate + Cloudflare DNS validation ────────────────────────────────
# This example manages its own ACM certificate and DNS records so the root
# module stays AWS-only. The validated certificate_arn is passed into module.n8n.
#
# Cloudflare note: validation records are created with proxied=false — ACM
# resolves the CNAME directly. The n8n CNAME also defaults to proxied=false.
# To enable Cloudflare proxying, set proxied=true on cloudflare_record.n8n_cname
# and set Cloudflare SSL/TLS mode to "Full (strict)".

resource "aws_acm_certificate" "n8n" {
  domain_name       = var.n8n_domain
  validation_method = "DNS"

  tags = local.common_tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "cloudflare_record" "cert_validation" {
  for_each = {
    for o in aws_acm_certificate.n8n.domain_validation_options : o.domain_name => {
      name    = o.resource_record_name
      type    = o.resource_record_type
      content = o.resource_record_value
    }
  }

  zone_id = var.cloudflare_zone_id
  # ACM returns FQDNs with trailing dots; strip them before passing to Cloudflare.
  name    = trimsuffix(each.value.name, ".")
  type    = each.value.type
  content = each.value.content
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
