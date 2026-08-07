# ── AWS Load Balancer Controller ──────────────────────────────────────────────
# The Helm chart creates its own ServiceAccount (aws-load-balancer-controller
# in kube-system) and EKS Pod Identity binds it to the IAM role via iam.tf.
#
# Destroy ordering: n8n Helm depends_on this release (via depends_on =
# [module.controllers] in the root module), so during destroy the n8n release
# and ingress are deleted FIRST (while LBC is still running to clean up the
# ALB). LBC is destroyed only after all ingresses are gone.
#
# failurePolicy=Ignore on the webhook prevents the LBC admission webhook from
# blocking Ingress mutations when LBC pods are unhealthy during destroy.

resource "helm_release" "lbc" {
  count = var.install_lbc ? 1 : 0

  name            = "aws-load-balancer-controller"
  repository      = var.lbc_chart_repository
  chart           = "aws-load-balancer-controller"
  version         = var.lbc_chart_version
  namespace       = "kube-system"
  wait            = true
  timeout         = 300
  atomic          = true
  cleanup_on_fail = true

  set = [
    {
      name  = "clusterName"
      value = var.eks_cluster_name
    },
    {
      name  = "vpcId"
      value = var.vpc_id
    },
    # Prevent the LBC validating webhook from blocking Ingress deletions when
    # LBC pods are unhealthy during destroy. With failurePolicy=Ignore, the
    # webhook is best-effort — if LBC can't respond, the API server proceeds.
    {
      name  = "webhookConfig.failurePolicy"
      value = "Ignore"
    },
  ]

  depends_on = [
    aws_iam_role_policy_attachment.lbc,
    aws_eks_pod_identity_association.lbc,
  ]
}

# ── Cluster Autoscaler ────────────────────────────────────────────────────────
# Watches for Pending pods that can't schedule due to insufficient node capacity
# and adds nodes up to node_max. Removes underutilised nodes down to node_min.
# Requires the auto-discovery tags on the node group (set in the root module's
# eks.tf).
# The chart creates ServiceAccount `cluster-autoscaler` in kube-system, bound
# to the IAM role via Pod Identity (iam.tf).

resource "helm_release" "cluster_autoscaler" {
  count = var.install_cluster_autoscaler ? 1 : 0

  name            = "cluster-autoscaler"
  repository      = var.cluster_autoscaler_chart_repository
  chart           = "cluster-autoscaler"
  version         = var.cluster_autoscaler_chart_version
  namespace       = "kube-system"
  wait            = true
  timeout         = 300
  atomic          = true
  cleanup_on_fail = true

  set = [
    {
      name  = "autoDiscovery.clusterName"
      value = var.eks_cluster_name
    },
    {
      name  = "awsRegion"
      value = var.aws_region
    },
    {
      name  = "rbac.serviceAccount.name"
      value = "cluster-autoscaler"
    },
  ]

  depends_on = [
    aws_iam_role_policy_attachment.cluster_autoscaler,
    aws_eks_pod_identity_association.cluster_autoscaler,
  ]
}

# ── Metrics Server ────────────────────────────────────────────────────────────
# Required for HPA to read pod CPU metrics. EKS does NOT ship with metrics-server
# by default — without it every HPA target shows "cpu: <unknown>" and scale-up
# never triggers regardless of actual load.
#
# --kubelet-insecure-tls: EKS kubelets present self-signed TLS certificates that
#   metrics-server cannot verify. Without this flag, scrapes fail and all metrics
#   remain unknown.
# --kubelet-preferred-address-types=InternalIP: Tells metrics-server to reach
#   kubelets via their VPC private IP rather than hostname, which may not resolve
#   inside the VPC.

resource "helm_release" "metrics_server" {
  count = var.install_metrics_server ? 1 : 0

  name            = "metrics-server"
  repository      = var.metrics_server_chart_repository
  chart           = "metrics-server"
  version         = var.metrics_server_chart_version
  namespace       = "kube-system"
  wait            = true
  timeout         = 300
  atomic          = true
  cleanup_on_fail = true

  set = [
    {
      name  = "args[0]"
      value = "--kubelet-insecure-tls"
    },
    {
      name  = "args[1]"
      value = "--kubelet-preferred-address-types=InternalIP"
    },
  ]
}
