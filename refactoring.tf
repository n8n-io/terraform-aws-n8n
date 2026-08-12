# ── State refactoring ─────────────────────────────────────────────────────────
# Every `moved` block in the module lives here rather than beside the resource
# it renames. Collecting them makes the upgrade surface reviewable in a single
# diff: what a consumer needs to know before bumping the module version is
# exactly this file.
#
# `moved` blocks are declarative and position-independent, so relocating them
# from the resource files changes nothing about how Terraform applies them.
#
# Do not delete entries. A consumer upgrading across several releases at once
# replays the whole chain, so removing an old block turns an in-place upgrade
# into a destroy and recreate for anyone who skipped that version.

# ── Adding count to previously unconditional resources ────────────────────────
# Gating a resource on a `create_*` toggle changes its address from `.n8n` to
# `.n8n[0]`. Without these, existing deployments plan a destroy and recreate.

# create_database (0.2.0). Skipped when the caller supplies an external
# database, e.g. an Aurora cluster created in the example folder.
moved {
  from = aws_db_subnet_group.n8n
  to   = aws_db_subnet_group.n8n[0]
}

moved {
  from = aws_db_instance.n8n
  to   = aws_db_instance.n8n[0]
}

# aws_security_group.rds was unconditional even though its only consumer,
# aws_db_instance.n8n, is gated on create_database. Gating it to match leaves
# no security group behind on the external-database path.
moved {
  from = aws_security_group.rds
  to   = aws_security_group.rds[0]
}

# create_namespace. Skipped when the caller deploys into a namespace that
# already exists outside Terraform.
moved {
  from = kubernetes_namespace.n8n
  to   = kubernetes_namespace.n8n[0]
}

# install_lbc, install_cluster_autoscaler, install_metrics_server, install_keda.
# Skipped when an identical install already exists in the cluster, e.g. one a
# platform team manages through GitOps.
moved {
  from = helm_release.lbc
  to   = helm_release.lbc[0]
}

moved {
  from = helm_release.cluster_autoscaler
  to   = helm_release.cluster_autoscaler[0]
}

moved {
  from = helm_release.metrics_server
  to   = helm_release.metrics_server[0]
}

moved {
  from = helm_release.keda
  to   = helm_release.keda[0]
}

# n8n_webhook_hpa_enabled. Skipped when the caller brings their own
# autoscaling policy for the webhook processor Deployment.
moved {
  from = kubernetes_horizontal_pod_autoscaler_v2.n8n_webhook
  to   = kubernetes_horizontal_pod_autoscaler_v2.n8n_webhook[0]
}

# create_ingress. Recreating this one would also tear down the ALB the Load
# Balancer Controller provisioned for it, so the block matters more than most.
moved {
  from = kubernetes_ingress_v1.n8n
  to   = kubernetes_ingress_v1.n8n[0]
}

# create_elasticache. Skipped when the caller points n8n at an external Redis,
# e.g. one endpoint shared between regions in a cross-region HA/DR topology.
#
# These three cover the default path only, where the Redis tier stays a
# single-node cluster. There is deliberately no block for the replication group
# that redis_high_availability_enabled or redis_transit_encryption_enabled
# creates: `moved` cannot bridge two different resource types, so either switch
# is a destroy and recreate no matter how it is written. See redis.tf and
# README → "Redis high availability".
moved {
  from = aws_security_group.redis
  to   = aws_security_group.redis[0]
}

moved {
  from = aws_elasticache_subnet_group.n8n
  to   = aws_elasticache_subnet_group.n8n[0]
}

moved {
  from = aws_elasticache_cluster.n8n
  to   = aws_elasticache_cluster.n8n[0]
}

# n8n_encryption_key. Skipped when the caller supplies an existing key, e.g.
# restoring a database from an earlier deployment that must keep decrypting
# its credentials under the same key.
moved {
  from = random_id.n8n_encryption_key
  to   = random_id.n8n_encryption_key[0]
}

# ── modules/controllers extraction ────────────────────────────────────────────
# LBC, Cluster Autoscaler, metrics-server, KEDA and the EBS CSI driver moved
# from flat root-level resources into a nested modules/controllers submodule,
# so an advanced caller on an existing cluster can invoke it directly with
# only the controllers they need. Every existing deployment still gets the
# root module calling this submodule by default (controllers.tf), so these
# blocks are the only thing standing between an upgrading deployment and a
# destroy-and-recreate of every Helm release and IAM role below. Each entry
# chains from whatever the resource's prior moved block (above) left it at, to
# its new address inside module.controllers.

moved {
  from = helm_release.lbc[0]
  to   = module.controllers.helm_release.lbc[0]
}

moved {
  from = helm_release.cluster_autoscaler[0]
  to   = module.controllers.helm_release.cluster_autoscaler[0]
}

moved {
  from = helm_release.metrics_server[0]
  to   = module.controllers.helm_release.metrics_server[0]
}

moved {
  from = helm_release.keda[0]
  to   = module.controllers.helm_release.keda[0]
}

# LBC and Cluster Autoscaler IAM: never previously gated by count (see
# variables.tf → "Cluster controllers" for why), so these move straight across
# with no index change.
moved {
  from = aws_iam_policy.lbc
  to   = module.controllers.aws_iam_policy.lbc
}

moved {
  from = aws_iam_role.lbc
  to   = module.controllers.aws_iam_role.lbc
}

moved {
  from = aws_iam_role_policy_attachment.lbc
  to   = module.controllers.aws_iam_role_policy_attachment.lbc
}

# Combined with the controllers-submodule extraction move below: this
# resource gained a create_eks || install_lbc count gate in the same
# unreleased branch that introduced the submodule (dbb80b1 and after), so
# there is no released version where consumers landed on the un-indexed
# module.controllers address: safe to move straight to [0] in one hop
# rather than chaining two moved blocks.
moved {
  from = aws_eks_pod_identity_association.lbc
  to   = module.controllers.aws_eks_pod_identity_association.lbc[0]
}

moved {
  from = aws_iam_policy.cluster_autoscaler
  to   = module.controllers.aws_iam_policy.cluster_autoscaler
}

moved {
  from = aws_iam_role.cluster_autoscaler
  to   = module.controllers.aws_iam_role.cluster_autoscaler
}

moved {
  from = aws_iam_role_policy_attachment.cluster_autoscaler
  to   = module.controllers.aws_iam_role_policy_attachment.cluster_autoscaler
}

# Same reasoning as the lbc moved block above: no released version ever had
# consumers land on the un-indexed address, so one hop straight to [0].
moved {
  from = aws_eks_pod_identity_association.cluster_autoscaler
  to   = module.controllers.aws_eks_pod_identity_association.cluster_autoscaler[0]
}

# EBS CSI driver: already gated on create_ebs_csi before this extraction, so
# the index carries straight across.
moved {
  from = aws_eks_addon.ebs_csi[0]
  to   = module.controllers.aws_eks_addon.ebs_csi[0]
}

moved {
  from = aws_iam_role.ebs_csi[0]
  to   = module.controllers.aws_iam_role.ebs_csi[0]
}

moved {
  from = aws_iam_role_policy_attachment.ebs_csi[0]
  to   = module.controllers.aws_iam_role_policy_attachment.ebs_csi[0]
}

moved {
  from = kubernetes_storage_class_v1.gp3[0]
  to   = module.controllers.kubernetes_storage_class_v1.gp3[0]
}
