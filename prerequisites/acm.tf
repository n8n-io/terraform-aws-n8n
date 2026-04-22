# ── ACM Certificate ───────────────────────────────────────────────────────────
# Requests a TLS certificate for your domain using DNS validation.
# AWS will not issue the certificate until you add a CNAME record at your
# DNS provider. During `terraform apply`, the validation resource below
# blocks for up to 15 minutes so you can fetch the CNAME from state (see
# README — Step 4) and add it at your DNS provider.

resource "aws_acm_certificate" "n8n" {
  domain_name       = var.n8n_domain
  validation_method = "DNS"

  tags = local.common_tags

  lifecycle {
    create_before_destroy = true
  }
}

# Waits (up to 15 minutes) for ACM to confirm the DNS record exists and
# issues the certificate. The installation workspace reads certificate_arn
# from this workspace's outputs, so the cert must be issued before the
# installation apply can succeed.
resource "aws_acm_certificate_validation" "n8n" {
  certificate_arn = aws_acm_certificate.n8n.arn

  timeouts {
    create = "15m"
  }
}
