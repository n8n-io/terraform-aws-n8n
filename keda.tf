# ── KEDA ──────────────────────────────────────────────────────────────────────
# Kubernetes Event-Driven Autoscaling — scales n8n workers based on Redis queue
# depth rather than CPU, so workers appear only when there is work to do.
#
# Destroy ordering: helm_release.n8n depends_on this release, so during destroy
# the n8n release (including its ScaledObjects) is deleted FIRST while the KEDA
# operator is still running. KEDA processes the ScaledObject deletions and
# removes its own "finalizer.keda.sh" finalizer. KEDA is then uninstalled only
# after all ScaledObjects are gone — no orphaned finalizers.
#
# Install ordering: depends_on helm_release.lbc. The AWS Load Balancer
# Controller registers a cluster-wide MutatingWebhookConfiguration
# (mservice.elbv2.k8s.aws) that intercepts Service creations everywhere — not
# just for ALB-targeted services. If KEDA runs in parallel with the LBC chart,
# the LBC webhook may already be registered while LBC pods aren't yet Ready,
# causing KEDA's metrics/admission Services to fail with:
#   "failed calling webhook ... no endpoints available for service
#    aws-load-balancer-webhook-service".
# Serializing on lbc (which has wait = true) guarantees LBC pods are Ready
# before any KEDA Service hits the webhook.

resource "helm_release" "keda" {
  name             = "keda"
  repository       = "https://kedacore.github.io/charts"
  chart            = "keda"
  namespace        = "keda"
  create_namespace = true
  wait             = true
  timeout          = 300
  atomic           = true
  cleanup_on_fail  = true

  depends_on = [
    aws_eks_node_group.n8n,
    helm_release.lbc,
  ]
}
