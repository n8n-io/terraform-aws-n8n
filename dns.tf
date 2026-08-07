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

  # null rather than [] when there are no additional domains, so a deployment
  # that predates this input sees no diff on a ForceNew attribute. Lowercased
  # to match local.acm_domain_names: ACM normalizes names to lowercase anyway,
  # and sending the caller's casing would leave a permanent diff against what
  # the API stores.
  subject_alternative_names = length(var.n8n_additional_domains) > 0 ? [for d in var.n8n_additional_domains : lower(d)] : null

  tags = local.common_tags

  lifecycle {
    create_before_destroy = true
  }
}

# ── Route53 validation + alias record ─────────────────────────────────────────

resource "aws_route53_record" "cert_validation" {
  # Keyed off the domain inputs, not the certificate's own
  # domain_validation_options. for_each keys must be known at plan time and
  # domain_validation_options is computed, so deriving the keys from inputs is
  # what keeps this plannable. The record values below stay computed, which
  # for_each permits.
  #
  # This set must cover every name on the certificate. ACM issues one validation
  # record per name and aws_acm_certificate_validation below waits on all of
  # them, so a name missing here never gets its record written and the apply
  # hangs until it times out. That is why local.acm_domain_names, not a list
  # built here, feeds both this resource and the certificate's own
  # domain_name / subject_alternative_names: the two cannot drift apart.
  for_each = local.dns_automated ? toset(local.acm_domain_names) : toset([])

  zone_id = var.route53_zone_id

  # Select this domain's validation option rather than assuming there is only
  # one, so adding a subject alternative name needs no change here.
  name    = one([for o in aws_acm_certificate.n8n[0].domain_validation_options : o.resource_record_name if o.domain_name == each.value])
  type    = one([for o in aws_acm_certificate.n8n[0].domain_validation_options : o.resource_record_type if o.domain_name == each.value])
  records = [one([for o in aws_acm_certificate.n8n[0].domain_validation_options : o.resource_record_value if o.domain_name == each.value])]

  ttl             = 60
  allow_overwrite = true
}

# ── Additional-domain diagnostics ─────────────────────────────────────────────

# n8n_additional_domains only reaches the certificate on the Route 53 path,
# where the module issues it. With a caller-supplied certificate_arn the module
# cannot add names to someone else's certificate, so the Ingress happily starts
# routing a hostname the certificate does not cover and browsers get a name
# mismatch. The plan looks clean either way, which is what makes it a footgun.

check "additional_domains_need_a_certificate_that_covers_them" {
  assert {
    condition = length(var.n8n_additional_domains) == 0 ? true : var.route53_zone_id != null
    error_message = join("", [
      "n8n_additional_domains is set while the module is using a caller-supplied certificate_arn. ",
      "The module can only add subject alternative names to a certificate it issues itself, so these ",
      "names are added to the Ingress but not to your certificate. Either set route53_zone_id and let ",
      "the module issue the certificate, or reissue certificate_arn covering every name in ",
      "n8n_additional_domains. TLS fails with a name mismatch otherwise.",
    ])
  }
}

# Deliberately no warning for n8n_additional_domains with create_ingress = false.
# That combination is a supported pattern, not a mistake: the caller lets the
# module issue and validate one multi-name certificate, consumes it through the
# certificate_arn output, and attaches it to Ingress resources it owns.
# examples/split-ingress does exactly this. The module still writes the
# validation records for every name, so the certificate is usable; only routing
# and the alias records belong to the caller, which is the whole point of
# create_ingress = false.

resource "aws_acm_certificate_validation" "n8n" {
  count = local.dns_automated ? 1 : 0

  certificate_arn         = aws_acm_certificate.n8n[0].arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]

  # The nastiest failure in this file, because it does not look like a failure.
  # A name on the certificate with no validation record means ACM never
  # validates that name, so this resource blocks until it times out tens of
  # minutes later, pointing at itself rather than at the missing record.
  #
  # It cannot happen while the certificate's names and the record set both come
  # from local.acm_domain_names, which is the point of that local. The
  # precondition asserts the invariant anyway, so that if someone later sources
  # a certificate name from somewhere else they get a clear error in seconds
  # rather than a hung apply.
  #
  # A precondition rather than a check block: domain_validation_options is
  # computed, so the comparison is unknown at plan. A precondition defers
  # quietly to apply, where it fails fast before the wait begins, whereas a
  # check block reports an unevaluable assertion at plan time.
  lifecycle {
    precondition {
      condition = length(aws_route53_record.cert_validation) == length(aws_acm_certificate.n8n[0].domain_validation_options)
      error_message = join("", [
        "The ACM certificate carries names with no Route 53 validation record, so validation would ",
        "never complete and this apply would hang until it timed out. Every name on ",
        "aws_acm_certificate.n8n must appear in local.acm_domain_names, which is what ",
        "aws_route53_record.cert_validation iterates.",
      ])
    }
  }
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

# Kept separate from n8n_alias above rather than folding both into one for_each
# resource. Switching that resource from count to for_each would move it from
# .n8n_alias[0] to .n8n_alias["<domain>"], and a moved block cannot express that
# because its addresses must be static, so every existing deployment would
# destroy and recreate its alias record. A second resource costs a little
# duplication and no churn.
resource "aws_route53_record" "n8n_alias_additional" {
  # Lowercased to keep the keys aligned with local.acm_domain_names and the
  # validation records. Route 53 is case-insensitive, so only the key changes.
  for_each = local.dns_alias_managed ? toset([for d in var.n8n_additional_domains : lower(d)]) : toset([])

  zone_id = var.route53_zone_id
  name    = each.value
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
    "elbv2.k8s.aws/cluster" = local.eks_cluster_name
    "ingress.k8s.aws/stack" = "${var.namespace}/n8n-ingress"
  }

  depends_on = [kubernetes_ingress_v1.n8n]
}
