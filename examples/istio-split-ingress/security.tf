# ── Internal NLB security group ────────────────────────────────────────────────
# ALB Ingresses have an inbound-cidrs annotation (see examples/split-ingress's
# admin_allowed_cidr_blocks); a Network Load Balancer has no equivalent
# annotation. LBC instead reads a security group attached directly to the
# Service via service.beta.kubernetes.io/aws-load-balancer-security-groups
# (gateways.tf), so this example builds a real one rather than approximating
# the restriction some other way. This rule only restricts CLIENTS reaching
# the load balancer's listener (443); see the node-authorization rule below
# for the separate, backend-side half of this.

resource "aws_security_group" "internal_gateway" {
  # checkov:skip=CKV2_AWS_5:This group IS attached, to the internal NLB, via the Kubernetes Service annotation service.beta.kubernetes.io/aws-load-balancer-security-groups (gateways.tf), rendered through helm_release.values. That is a stronger blind spot than the count-based one already documented on aws_security_group.redis (redis.tf) and aws_security_group.rds (database.tf): there is no Terraform-native attachment resource at all here, native or count-expanded, for checkov's graph to walk, because the consumer is the AWS Load Balancer Controller reading a Kubernetes object's annotation string, not a Terraform resource. Verified live: aws ec2 describe-security-groups against the internal NLB's ENIs shows exactly this group attached, and no others (see README.md, "Verified against a live cluster").
  name_prefix = "${var.cluster_name}-istio-internal-"
  description = "Internal NLB for the Istio admin ingress gateway (examples/istio-split-ingress)"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description = "HTTPS from admin_allowed_cidr_blocks (or anywhere routable to the private subnets, if empty)"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = length(var.admin_allowed_cidr_blocks) > 0 ? var.admin_allowed_cidr_blocks : ["0.0.0.0/0"]
  }

  tags = local.common_tags

  lifecycle {
    create_before_destroy = true
  }
}

# Egress is deliberately scoped to the VPC, on the same traffic + health-check
# port range as the node-authorization rule below, rather than 0.0.0.0/0: the
# NLB only ever needs to reach the gateway pods it targets, all inside the VPC,
# so there is a real destination to name here (unlike module.n8n's RDS/Redis
# security groups, where "AWS API calls with no fixed destination" makes an
# egress-all skip the honest answer instead of a fixable gap).
resource "aws_vpc_security_group_egress_rule" "internal_gateway_egress_to_nodes" {
  security_group_id = aws_security_group.internal_gateway.id
  cidr_ipv4         = module.vpc.vpc_cidr_block
  ip_protocol       = "tcp"
  from_port         = local.internal_gateway_traffic_port
  to_port           = 15021
  description       = "Internal NLB reaching node-hosted gateway pods for forwarded traffic and health checks"

  tags = local.common_tags
}

# ── Authorizing the NLB into the node security group ─────────────────────────
# Confirmed live: supplying a caller-managed security group via
# aws-load-balancer-security-groups (gateways.tf) makes the internal NLB's
# ENIs carry ONLY aws_security_group.internal_gateway. The AWS Load Balancer
# Controller normally auto-authorizes its own shared backend security group
# (tagged elbv2.k8s.aws/targetGroupBinding=shared) into the EKS cluster
# security group so target-type=ip health checks and forwarded traffic can
# reach the pods; it does this ONLY for its own auto-managed security group,
# never for a caller-supplied one. Without this rule the public gateway comes
# up fine (it carries no custom security group, so LBC's default handling
# still applies) while the internal one's targets report
# Target.FailedHealthChecks indefinitely, because the node security group
# never learns to trust the new custom security group at all.
#
# The cluster security group id has no module output, so it is read directly
# via the EKS API rather than added to the module's public surface for one
# example's use.

data "aws_eks_cluster" "n8n" {
  name = module.n8n.cluster_name
}

locals {
  # Matches the containerPort gateways.tf's service.ports maps 443 to: 8080
  # when the NLB itself terminates TLS (istio_tls_mode = "nlb"), 8443 when
  # Envoy terminates TLS itself (istio_tls_mode = "gateway"). Both are below
  # 15021, so a single contiguous range covers the traffic port and the
  # health-check port together, the same shape LBC's own auto-managed rule
  # uses (8080-15021).
  internal_gateway_traffic_port = var.istio_tls_mode == "nlb" ? 8080 : 8443
}

resource "aws_vpc_security_group_ingress_rule" "internal_gateway_to_nodes" {
  security_group_id            = data.aws_eks_cluster.n8n.vpc_config[0].cluster_security_group_id
  referenced_security_group_id = aws_security_group.internal_gateway.id
  ip_protocol                  = "tcp"
  from_port                    = local.internal_gateway_traffic_port
  to_port                      = 15021
  description                  = "Internal Istio gateway NLB (custom security group) reaching node-hosted pods for health checks and forwarded traffic"

  tags = local.common_tags
}
