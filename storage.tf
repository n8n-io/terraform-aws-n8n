# ── Cluster storage: EBS CSI driver + default gp3 StorageClass ────────────────
# Multi-main n8n itself is stateless (RDS + S3 replace the PVC), but without a
# CSI driver the cluster ships in a silently broken state: the EKS-created gp2
# StorageClass uses the removed in-tree provisioner and carries no default
# annotation, so any PVC without an explicit storageClassName stays Pending
# forever (issue #22). Ship persistence working by default for workloads users
# run beside n8n. Decision record: solutions-catalog ADR-0041.

resource "aws_eks_addon" "ebs_csi" {
  cluster_name = aws_eks_cluster.n8n.name
  addon_name   = "aws-ebs-csi-driver"

  # The CSI controller gets AWS credentials via EKS Pod Identity, the same
  # mechanism as the LBC and Cluster Autoscaler (iam.tf); no IRSA, no OIDC
  # provider. The association is declared on the addon itself so it exists
  # before the controller pods start (avoids pods caching empty credentials).
  pod_identity_association {
    role_arn        = aws_iam_role.ebs_csi.arn
    service_account = "ebs-csi-controller-sa"
  }

  tags = local.common_tags

  # Node group: controller pods need nodes to schedule on. Pod Identity agent:
  # credentials flow through the agent DaemonSet. Policy attachment: the role
  # must never be live without AmazonEBSCSIDriverPolicy.
  depends_on = [
    aws_eks_node_group.n8n,
    aws_eks_addon.pod_identity_agent,
    aws_iam_role_policy_attachment.ebs_csi,
  ]
}

# Default StorageClass backed by the CSI driver. The legacy gp2 class is left
# in place on purpose: EKS creates it outside Terraform and it carries no
# default annotation on current EKS versions, so it is inert; patching or
# deleting a resource the module did not create would need imperative kubectl
# workarounds. gp3 becomes the default purely by being the only annotated class.
resource "kubernetes_storage_class_v1" "gp3" {
  metadata {
    name = "gp3"
    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "true"
    }
  }

  storage_provisioner    = "ebs.csi.aws.com"
  reclaim_policy         = "Delete"
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true

  parameters = {
    type = "gp3"
    # Encrypted at rest with the default aws/ebs managed key. Customer-managed
    # keys are out of scope (would need extra KMS grants on the CSI role).
    encrypted = "true"
  }

  depends_on = [aws_eks_addon.ebs_csi]
}
