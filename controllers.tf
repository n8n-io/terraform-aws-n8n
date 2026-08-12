# ── Cluster controllers ────────────────────────────────────────────────────────
# LBC, Cluster Autoscaler, metrics-server, KEDA and the EBS CSI driver all live
# in modules/controllers, extracted out of the root module so an advanced
# caller deploying onto an existing cluster (create_eks = false) can invoke
# that submodule directly with only the controllers they actually need,
# instead of getting five root-level install_* booleans with no way to omit
# the ones they will never touch. This call is what every existing deployment
# still gets by default: every install_* / create_ebs_csi toggle here is the
# same root-level variable, same name, same default, that existed before this
# submodule did, so a greenfield deployment's plan is unchanged by this
# refactor. See docs/customer-managed-infrastructure.md.
#
# depends_on the node group and the Pod Identity Agent addon as a whole: every
# controller resource inside this submodule needs schedulable nodes, and every
# controller's Pod Identity association needs the agent DaemonSet already
# running Pod Identity credentials into pods. Both are root-module resources
# (eks.tf), gated on create_eks, so on the create_eks = false path they
# contribute zero instances and this depends_on is a no-op, same as it was
# when these were flat root resources depending on them directly.
module "controllers" {
  source = "./modules/controllers"

  cluster_name     = local.cluster_name
  eks_cluster_name = local.eks_cluster_name
  aws_region       = local.aws_region
  vpc_id           = local.vpc_id
  create_eks       = var.create_eks

  iam_permissions_boundary_arn = var.iam_permissions_boundary_arn
  common_tags                  = local.common_tags

  install_lbc                = var.install_lbc
  install_cluster_autoscaler = var.install_cluster_autoscaler
  install_metrics_server     = var.install_metrics_server
  install_keda               = var.install_keda
  create_ebs_csi             = var.create_ebs_csi

  lbc_chart_repository                = var.lbc_chart_repository
  lbc_chart_version                   = var.lbc_chart_version
  cluster_autoscaler_chart_repository = var.cluster_autoscaler_chart_repository
  cluster_autoscaler_chart_version    = var.cluster_autoscaler_chart_version
  metrics_server_chart_repository     = var.metrics_server_chart_repository
  metrics_server_chart_version        = var.metrics_server_chart_version
  keda_chart_repository               = var.keda_chart_repository
  keda_chart_version                  = var.keda_chart_version

  depends_on = [
    aws_eks_node_group.n8n,
    aws_eks_addon.pod_identity_agent,
  ]
}
