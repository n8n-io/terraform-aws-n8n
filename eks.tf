# ── Cluster IAM role ──────────────────────────────────────────────────────────
# Skipped when create_eks = false along with every other resource in this
# file: the caller's existing_eks_cluster_name names a cluster this module
# does not own, so it creates no IAM role for it either.

resource "aws_iam_role" "cluster" {
  count = var.create_eks ? 1 : 0

  name = "${local.cluster_name}-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  permissions_boundary = var.iam_permissions_boundary_arn

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "cluster_policy" {
  count = var.create_eks ? 1 : 0

  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.cluster[0].name
}

# ── Node group IAM role ───────────────────────────────────────────────────────

resource "aws_iam_role" "nodes" {
  count = var.create_eks ? 1 : 0

  name = "${local.cluster_name}-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  permissions_boundary = var.iam_permissions_boundary_arn

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "nodes_worker" {
  count = var.create_eks ? 1 : 0

  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.nodes[0].name
}

resource "aws_iam_role_policy_attachment" "nodes_cni" {
  count = var.create_eks ? 1 : 0

  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.nodes[0].name
}

resource "aws_iam_role_policy_attachment" "nodes_ecr" {
  count = var.create_eks ? 1 : 0

  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.nodes[0].name
}

# ── Customer Managed KMS key for cluster secrets + control-plane logs ────────
# A single CMK envelope-encrypts Kubernetes Secrets (CKV_AWS_58) and encrypts
# the control-plane CloudWatch log group below (CKV_AWS_158), replacing the
# AWS-managed default. Mirrors the RDS (database.tf) / Aurora
# (examples/large/aurora.tf) CMK pattern.
#
# Gated on var.eks_secrets_encryption_enabled so existing unencrypted clusters
# can opt out: enabling secrets encryption on an existing cluster may force
# EKS cluster replacement depending on the AWS provider version in use, so
# flip this on an existing deployment only after testing against a
# non-production cluster.
#
# Also gated on var.create_eks: this key's only consumer is the
# encryption_config block on aws_eks_cluster.n8n below, which this module
# never creates on the create_eks = false path, and its policy grants
# aws_iam_role.cluster, which likewise does not exist there. An existing
# cluster's own secrets-encryption posture (or lack of one) is not this
# module's to manage.
#
# enable_key_rotation = true → annual rotation, no operator action.
# deletion_window_in_days = 7 → AWS minimum, so `terraform destroy` recycles
# the key as fast as AWS permits.

locals {
  eks_kms_key_arn = try(aws_kms_key.eks[0].arn, null)
}

resource "aws_kms_key" "eks" {
  count = var.create_eks && var.eks_secrets_encryption_enabled ? 1 : 0

  description             = "CMK for EKS cluster ${local.cluster_name} (secrets envelope encryption + control-plane logs)"
  enable_key_rotation     = true
  deletion_window_in_days = 7

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "EnableRootAccess"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        Sid       = "AllowEKSClusterRole"
        Effect    = "Allow"
        Principal = { AWS = aws_iam_role.cluster[0].arn }
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:DescribeKey",
          "kms:CreateGrant",
        ]
        Resource = "*"
      },
      {
        Sid       = "AllowCloudWatchLogsEncrypt"
        Effect    = "Allow"
        Principal = { Service = "logs.${local.aws_region}.amazonaws.com" }
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:DescribeKey",
        ]
        Resource = "*"
        Condition = {
          ArnLike = {
            "kms:EncryptionContext:aws:logs:arn" = "arn:aws:logs:${local.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/eks/${local.cluster_name}/cluster"
          }
        }
      },
    ]
  })

  tags = merge(local.common_tags, { Name = "n8n-eks-${local.cluster_name}" })
}

resource "aws_kms_alias" "eks" {
  count = var.create_eks && var.eks_secrets_encryption_enabled ? 1 : 0

  name_prefix   = "alias/n8n-eks-${local.cluster_name}-"
  target_key_id = aws_kms_key.eks[0].key_id
}

# ── Control-plane CloudWatch Log Group ────────────────────────────────────────
# Created explicitly so we own retention (CKV_AWS_338); without this resource,
# EKS auto-creates /aws/eks/<cluster>/cluster with "Never expire" retention as
# soon as enabled_cluster_log_types is set on the cluster below. Gated on
# var.create_eks: enabled_cluster_log_types is only ever set on the
# module-created cluster (aws_eks_cluster.n8n below), so this module has no
# control-plane logging to retain on the create_eks = false path; an existing
# cluster's own log group belongs to whoever manages that cluster.

resource "aws_cloudwatch_log_group" "eks_cluster" {
  count = var.create_eks ? 1 : 0

  name              = "/aws/eks/${local.cluster_name}/cluster"
  retention_in_days = 365
  kms_key_id        = local.eks_kms_key_arn

  tags = merge(local.common_tags, { Name = "n8n-eks-${local.cluster_name}-logs" })
}

# ── EKS Cluster ───────────────────────────────────────────────────────────────

resource "aws_eks_cluster" "n8n" {
  # checkov:skip=CKV_AWS_38:Public endpoint is this module's default posture, for zero-friction kubectl access right after apply. Restrict via var.cluster_endpoint_public_access_cidrs, or disable entirely via var.cluster_endpoint_public_access = false plus var.cluster_endpoint_private_access = true.
  # checkov:skip=CKV_AWS_39:Same rationale as CKV_AWS_38 above - the endpoint access variables let operators lock this down per-environment.
  # checkov:skip=CKV_AWS_58:Secrets encryption IS enabled by default (var.eks_secrets_encryption_enabled defaults to true, wiring aws_kms_key.eks into the encryption_config block below). Checkov resolves no `dynamic` block at all here, not just this conditional one: an isolated aws_eks_cluster with `dynamic "encryption_config" { for_each = [1] ... }` fails CKV_AWS_58 too, while the same block written statically passes, so the check reads encryption_config/[0]/resources straight from the HCL and never expands the dynamic. The block cannot be written statically, because provider.key_arn is required and there is no key to point it at when eks_secrets_encryption_enabled = false. Tooling limitation, not a gap: `terraform plan` shows encryption_config populated under the module's default var values.
  count = var.create_eks ? 1 : 0

  name     = local.cluster_name
  role_arn = aws_iam_role.cluster[0].arn
  version  = var.kubernetes_version

  vpc_config {
    subnet_ids              = concat(local.public_subnets, local.private_subnets)
    endpoint_public_access  = var.cluster_endpoint_public_access
    endpoint_private_access = var.cluster_endpoint_private_access
    public_access_cidrs     = var.cluster_endpoint_public_access_cidrs
  }

  # API auth mode replaces the legacy aws-auth ConfigMap. Cluster access is
  # granted via aws_eks_access_entry + aws_eks_access_policy_association.
  # bootstrap_cluster_creator_admin_permissions gives the principal that creates
  # the cluster (the one running `terraform apply`) immediate admin access so
  # `kubectl` works right after apply.
  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = true
  }

  # All 5 control-plane log types (CKV_AWS_37). The explicit log group above
  # (rather than letting EKS auto-create one) means retention and encryption
  # are ours to set instead of defaulting to "Never expire" / AWS-managed key.
  enabled_cluster_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  dynamic "encryption_config" {
    for_each = var.eks_secrets_encryption_enabled ? [1] : []

    content {
      resources = ["secrets"]
      provider {
        key_arn = local.eks_kms_key_arn
      }
    }
  }

  tags = local.common_tags

  depends_on = [
    aws_iam_role_policy_attachment.cluster_policy,
    aws_cloudwatch_log_group.eks_cluster,
  ]
}

# ── Managed node group ────────────────────────────────────────────────────────
# 3 nodes by default — enough for 6 pods at minimum replicas.
# HPA scales pods horizontally; Cluster Autoscaler (controllers.tf) adds/removes
# nodes between node_min and node_max as pod demand changes.

resource "aws_eks_node_group" "n8n" {
  count = var.create_eks ? 1 : 0

  cluster_name    = aws_eks_cluster.n8n[0].name
  node_group_name = "n8n-nodes"
  node_role_arn   = aws_iam_role.nodes[0].arn
  subnet_ids      = local.private_subnets
  instance_types  = [var.node_instance_type]

  scaling_config {
    desired_size = var.node_desired
    min_size     = var.node_min
    max_size     = var.node_max
  }

  # Required for Cluster Autoscaler auto-discovery. The CA scans for ASGs
  # tagged with these two keys to know which node groups it can scale.
  tags = merge(local.common_tags, {
    "k8s.io/cluster-autoscaler/${local.cluster_name}" = "owned"
    "k8s.io/cluster-autoscaler/enabled"               = "true"
  })

  depends_on = [
    aws_iam_role_policy_attachment.nodes_worker,
    aws_iam_role_policy_attachment.nodes_cni,
    aws_iam_role_policy_attachment.nodes_ecr,
  ]

  # The Cluster Autoscaler owns desired_size after creation (see tags above).
  # Without this, every plan after an autoscaler scaling event tries to reset
  # desired_size back to var.node_desired, and applying that drains live nodes.
  lifecycle {
    ignore_changes = [scaling_config[0].desired_size]
  }
}

# ── EKS Pod Identity Agent ────────────────────────────────────────────────────
# The agent runs as a DaemonSet and injects AWS credentials into pods whose
# service accounts are bound via aws_eks_pod_identity_association. This is the
# AWS-recommended replacement for IRSA — no OIDC provider, no federated trust
# policies, no service account annotations.
#
# Skipped when create_eks = false: data.aws_eks_addon.existing_pod_identity_agent
# below reads for its presence on the caller's cluster instead of installing it.

resource "aws_eks_addon" "pod_identity_agent" {
  count = var.create_eks ? 1 : 0

  cluster_name = aws_eks_cluster.n8n[0].name
  addon_name   = "eks-pod-identity-agent"

  tags = local.common_tags

  depends_on = [aws_eks_node_group.n8n]
}

# ── Bring your own EKS cluster ────────────────────────────────────────────────
# create_eks = false skips every resource above and instead reads an existing
# cluster named by existing_eks_cluster_name. local.eks_cluster_name / _endpoint
# / _ca_data (locals.tf) resolve to either this data source or the resources
# above, so every other file in the module reads through those locals rather
# than branching on create_eks itself.

data "aws_eks_cluster" "existing" {
  count = var.create_eks ? 0 : 1

  name = var.existing_eks_cluster_name

  # Hard-fails the plan rather than warning, unlike the Kubernetes-version
  # check below. Every security group, subnet and route this module writes
  # assumes the cluster's ENIs live in vpc_id; a cluster in a different VPC
  # makes all of that silently wrong (traffic that never arrives, security
  # group rules that reference the wrong VPC) rather than merely suboptimal.
  lifecycle {
    postcondition {
      condition     = self.vpc_config[0].vpc_id == var.vpc_id
      error_message = "existing_eks_cluster_name resolves to a cluster in ${self.vpc_config[0].vpc_id}, but this module is configured with vpc_id = ${var.vpc_id}. Every security group, subnet and route this module writes assumes the cluster's ENIs live in vpc_id, so a mismatch here must block the plan rather than produce infrastructure that looks correct and silently cannot reach it."
    }
  }
}

# The AWS provider's aws_eks_addon data source errors at plan time (a
# ResourceNotFoundException) when the named addon is not installed on the
# cluster, rather than returning an empty result this module could branch on.
# That failure happens before any aws_eks_pod_identity_association is
# attempted, which is the property that matters here, so no additional
# validation is written against this data source. Re-confirm this behavior
# against the AWS provider version this module pins before relying on it.
# Read for the plan-time failure its own existence causes, never for its
# result value.
# tflint-ignore: terraform_unused_declarations
data "aws_eks_addon" "existing_pod_identity_agent" {
  count = var.create_eks ? 0 : 1

  cluster_name = var.existing_eks_cluster_name
  addon_name   = "eks-pod-identity-agent"
}

# Advisory only, unlike the VPC precondition above: a control-plane version
# one release ahead of or behind var.kubernetes_version is frequently still a
# fine combination (Kubernetes has a documented +/-1 minor version skew
# policy between control plane and node group), so this warns rather than
# blocking the plan.
check "existing_eks_cluster_kubernetes_version_matches" {
  assert {
    condition = var.create_eks ? true : data.aws_eks_cluster.existing[0].version == var.kubernetes_version
    error_message = join("", [
      "existing_eks_cluster_name resolves to a cluster running Kubernetes ${try(data.aws_eks_cluster.existing[0].version, "")}, but ",
      "kubernetes_version is set to ${var.kubernetes_version}. kubernetes_version is otherwise unused on the create_eks = false path, so this is ",
      "informational rather than a mismatch this module can act on: confirm the deployed version is the one your node group, addons and Helm charts ",
      "were validated against.",
    ])
  }
}

# The inverse mistake, and the same "X is ignored when Y" shape as
# existing_s3_bucket_name_requires_create_s3_bucket_false (s3.tf) and the
# external-database checks in database.tf: naming an existing cluster while
# leaving create_eks at its default plans and applies cleanly, and quietly
# builds a brand new cluster next to the one the caller meant to deploy onto.
# That is the most expensive silent discard in the module, so it is worth
# saying out loud even though it is not an error.

check "existing_eks_cluster_name_requires_create_eks_false" {
  assert {
    condition = var.create_eks ? var.existing_eks_cluster_name == null : true
    error_message = join("", [
      "existing_eks_cluster_name is set while create_eks = true (the default), so it is ignored: the module ",
      "creates its own EKS cluster and deploys n8n onto that, not onto ${coalesce(var.existing_eks_cluster_name, "the cluster you named")}. ",
      "Set create_eks = false to deploy onto the existing cluster instead.",
    ])
  }
}
