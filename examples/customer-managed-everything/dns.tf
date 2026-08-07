# ── DNS ───────────────────────────────────────────────────────────────────────
# The certificate is issued by the module, not here: route53_zone_id makes
# module.n8n issue, validate and expose it via certificate_arn as usual.
# create_ingress = false only means the module writes no alias record, since
# it owns no load balancer to point one at; that record is this example's to
# own instead, same as examples/split-ingress's dns.tf.

# The Load Balancer Controller provisions the ALB asynchronously after the
# Ingress is created, so the alias record needs the ALB's canonical hosted
# zone ID, not just its hostname. Look it up by the tags LBC applies, which is
# more robust than parsing the hostname (whose format varies between LBC
# versions). wait_for_load_balancer = true on the Ingress guarantees the ALB
# exists by the time this evaluates.
data "aws_lb" "n8n" {
  tags = {
    "elbv2.k8s.aws/cluster" = var.cluster_name
    "ingress.k8s.aws/stack" = "${module.n8n.namespace}/n8n-ingress"
  }

  depends_on = [kubernetes_ingress_v1.n8n]
}

resource "aws_route53_record" "n8n" {
  zone_id = var.route53_zone_id
  name    = var.n8n_domain
  type    = "A"

  alias {
    name                   = data.aws_lb.n8n.dns_name
    zone_id                = data.aws_lb.n8n.zone_id
    evaluate_target_health = false
  }
}
