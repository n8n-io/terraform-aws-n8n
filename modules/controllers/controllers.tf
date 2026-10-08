# ── Install ordering ──────────────────────────────────────────────────────────
# The four controller releases install one at a time, in this order:
#
#   cluster_autoscaler -> metrics_server -> lbc -> keda (keda.tf)
#
# Each release lists every earlier release in depends_on, not only the one
# before it. The install_* toggles are independent, and a depends_on on a
# release whose count is 0 is a no-op. Listing every earlier release makes
# the order independent of which releases are turned off, without relying on
# how Terraform passes ordering through a release whose count is 0.
#
# Why serialize at all (issue #174): on a fresh cluster, one release failed on
# a transient API timeout while the others were still installing. The other
# in-flight releases were then cancelled (cause not confirmed), and one was
# left in Helm's pending-install state with nothing behind it. Neither atomic
# nor cleanup_on_fail covers that case, and the next apply fails on the
# release name. With one release at a time, a failed release makes Terraform
# skip every later one, so none of them is in flight when the run stops. A
# stranded release is then only possible if the run is interrupted while a
# release is mid-install. See docs/troubleshooting.md for the cleanup.
#
# Why this order: Cluster Autoscaler needs none of the others and goes first,
# so it can add nodes if a later controller's pods do not fit on the node
# group's starting nodes. Cluster Autoscaler and metrics-server install before
# LBC registers its cluster-wide Service mutating webhook (see keda.tf), and
# KEDA installs only once LBC's own install has finished with wait = true.
# The cost is a longer first apply and destroy: a fresh apply takes about the
# sum of the install times, and a full destroy about the sum of the uninstall
# times, rather than the longest one.
#
# The mocked terraform test suites cannot assert this: assert reads values,
# not dependency edges, and the mock providers do not enforce ordering. Only a
# live fresh apply shows the releases installing one at a time.

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
    # LBC pods are unhealthy during destroy. With the policy set to Ignore the
    # webhook is best-effort: if LBC can't respond, the API server proceeds.
    #
    # The key really is spelled "ingressValdationFailurePolicy", missing an
    # "i". That typo is upstream's, in the chart's own values.yaml (verified
    # against aws-load-balancer-controller chart 3.5.0, this module's
    # lbc_chart_version default), and the template reads only that spelling.
    # Helm silently accepts unknown --set paths, so the corrected spelling
    # applies cleanly and does nothing, leaving the webhook on its chart
    # default of Fail. Keep this matching whatever the pinned chart version
    # actually reads when bumping lbc_chart_version.
    {
      name  = "webhookConfig.ingressValdationFailurePolicy"
      value = "Ignore"
    },
  ]

  depends_on = [
    aws_iam_role_policy_attachment.lbc,
    aws_eks_pod_identity_association.lbc,
    helm_release.cluster_autoscaler,
    helm_release.metrics_server,
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

  depends_on = [
    helm_release.cluster_autoscaler,
  ]
}
