# ── KEDA ──────────────────────────────────────────────────────────────────────
# Kubernetes Event-Driven Autoscaling — scales n8n workers based on Redis queue
# depth rather than CPU, so workers appear only when there is work to do.

resource "helm_release" "keda" {
  name             = "keda"
  repository       = "https://kedacore.github.io/charts"
  chart            = "keda"
  namespace        = "keda"
  create_namespace = true
  wait             = true
  timeout          = 300

  depends_on = [aws_eks_node_group.n8n]
}
