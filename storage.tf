# ── Cluster storage: EBS CSI driver + default gp3 StorageClass ────────────────
# The actual addon, its IAM, and the default gp3 StorageClass now live in
# modules/controllers (storage.tf there), alongside the other optional
# controllers. This file keeps only the cross-variable validation below, since
# it checks create_eks and existing_eks_cluster_name, both root-module
# variables the submodule has no reason to know about.

check "existing_eks_cluster_needs_its_own_storage_toggle" {
  assert {
    condition = var.create_eks ? true : !var.create_ebs_csi
    error_message = join("", [
      "create_eks = false and create_ebs_csi is still true (its default), so this module is about to install aws_eks_addon.ebs_csi and ",
      "kubernetes_storage_class_v1.gp3 onto ${coalesce(var.existing_eks_cluster_name, "the existing cluster")}. If that cluster already runs a CSI driver ",
      "(likely, for any cluster already hosting other workloads), this install fails outright rather than degrading gracefully. Set create_ebs_csi = ",
      "false if the cluster already provides its own default StorageClass.",
    ])
  }
}
