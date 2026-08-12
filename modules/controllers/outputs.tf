# Whole-resource outputs exist to let the root module's test suite assert on
# this submodule's resources without duplicating every attribute it checks as
# its own output. terraform test's assert.condition cannot reach into a child
# module's internal resources directly (module.controllers.aws_iam_role.lbc is
# not valid the way it would be inside this module itself); it can only see
# what the module declares as an output. Count-gated resources come back as
# lists (0 or 1 elements, mirroring the resource's own count), same as
# referencing them bare (without an index) from inside this module would.

output "lbc_helm_release" {
  value = helm_release.lbc
}

output "cluster_autoscaler_helm_release" {
  value = helm_release.cluster_autoscaler
}

output "metrics_server_helm_release" {
  value = helm_release.metrics_server
}

output "keda_helm_release" {
  value = helm_release.keda
}

# Narrowed to permissions_boundary rather than the whole resource: aws_iam_role
# carries a deprecated inline_policy computed attribute, and outputting the
# whole resource touches it on every plan, surfacing a "Deprecated value used"
# warning to every consumer of this module for an attribute nothing here sets
# or reads.
output "lbc_iam_role" {
  value = [for r in aws_iam_role.lbc : {
    permissions_boundary = r.permissions_boundary
  }]
}

output "cluster_autoscaler_iam_role" {
  value = [for r in aws_iam_role.cluster_autoscaler : {
    permissions_boundary = r.permissions_boundary
  }]
}

output "lbc_pod_identity_association" {
  value = aws_eks_pod_identity_association.lbc
}

output "cluster_autoscaler_pod_identity_association" {
  value = aws_eks_pod_identity_association.cluster_autoscaler
}

output "ebs_csi_addon" {
  value = aws_eks_addon.ebs_csi
}

# Same narrowing as lbc_iam_role/cluster_autoscaler_iam_role above, kept as a
# list to mirror this resource's own count (0 or 1).
output "ebs_csi_iam_role" {
  value = [for r in aws_iam_role.ebs_csi : {
    permissions_boundary = r.permissions_boundary
    assume_role_policy   = r.assume_role_policy
  }]
}

output "ebs_csi_iam_role_policy_attachment" {
  value = aws_iam_role_policy_attachment.ebs_csi
}

output "gp3_storage_class" {
  value = kubernetes_storage_class_v1.gp3
}
