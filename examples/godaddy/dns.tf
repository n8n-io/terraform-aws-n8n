# ── ACM certificate + GoDaddy DNS validation ──────────────────────────────────
# This example manages its own ACM certificate and DNS records so the root
# module stays AWS-only. The validated certificate_arn is passed into module.n8n.
#
# The record name must be relative to the domain — strip the trailing dot and
# domain suffix that ACM appends to resource_record_name.

resource "aws_acm_certificate" "n8n" {
  domain_name       = var.n8n_domain
  validation_method = "DNS"

  tags = local.common_tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "godaddy-dns_record" "cert_validation" {
  for_each = {
    for o in aws_acm_certificate.n8n.domain_validation_options : o.domain_name => {
      name = o.resource_record_name
      type = o.resource_record_type
      data = o.resource_record_value
    }
  }

  domain = var.godaddy_domain
  # ACM returns FQDNs with trailing dots; strip the dot and parent domain.
  name = trimsuffix(trimsuffix(each.value.name, "."), ".${var.godaddy_domain}")
  type = each.value.type
  data = trimsuffix(each.value.data, ".")
  ttl  = 600
}

resource "aws_acm_certificate_validation" "n8n" {
  certificate_arn = aws_acm_certificate.n8n.arn
  validation_record_fqdns = [
    for k, r in godaddy-dns_record.cert_validation : "${r.name}.${var.godaddy_domain}"
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
