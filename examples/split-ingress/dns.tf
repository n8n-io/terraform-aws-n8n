# ── DNS ───────────────────────────────────────────────────────────────────────
# The certificate is issued by the module, not here. Passing route53_zone_id and
# n8n_additional_domains makes the module issue one certificate covering both
# hostnames, write a validation record for each, and validate it. The Ingresses
# in ingress.tf attach it through the module's certificate_arn output.
#
# The module writes no alias records for this example: create_ingress = false
# means it owns no load balancer to point them at. There are two ALBs here and
# each hostname resolves to a different one, so the alias records below are the
# example's to own.

# ── ALB lookups ───────────────────────────────────────────────────────────────
# The Load Balancer Controller provisions each ALB asynchronously after its
# Ingress is created, so an alias record needs the ALB's canonical hosted zone
# ID, not just the hostname. Look each up by the tags LBC applies. That is more robust
# than parsing the hostname, whose format varies between LBC versions.
#
# wait_for_load_balancer = true on both Ingresses guarantees the ALB exists by
# the time these evaluate.

data "aws_lb" "webhook_public" {
  tags = {
    "elbv2.k8s.aws/cluster" = var.cluster_name
    "ingress.k8s.aws/stack" = "${module.n8n.namespace}/n8n-webhook-public"
  }

  depends_on = [kubernetes_ingress_v1.webhook_public]
}

data "aws_lb" "admin_internal" {
  tags = {
    "elbv2.k8s.aws/cluster" = var.cluster_name
    "ingress.k8s.aws/stack" = "${module.n8n.namespace}/n8n-admin-internal"
  }

  depends_on = [kubernetes_ingress_v1.admin_internal]
}

# ── Alias records ─────────────────────────────────────────────────────────────

resource "aws_route53_record" "webhook_public" {
  zone_id = var.route53_zone_id
  name    = local.webhook_domain
  type    = "A"

  alias {
    name                   = data.aws_lb.webhook_public.dns_name
    zone_id                = data.aws_lb.webhook_public.zone_id
    evaluate_target_health = false
  }
}

# Public record, private addresses. Anyone can resolve this name; only clients
# inside the VPC or on the VPN can open a connection to what it points at. If
# even the name should stay hidden, move this record to a private hosted zone
# attached to the VPC.
resource "aws_route53_record" "admin_internal" {
  zone_id = var.route53_zone_id
  name    = var.n8n_domain
  type    = "A"

  alias {
    name                   = data.aws_lb.admin_internal.dns_name
    zone_id                = data.aws_lb.admin_internal.zone_id
    evaluate_target_health = false
  }
}
