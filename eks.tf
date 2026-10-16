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

# ── Managed node group launch template ────────────────────────────────────────
# EKS does not copy aws_eks_node_group.n8n's own tags to the EC2 instances,
# EBS volumes or network interfaces it launches (#198), so tagging them (for
# AWS Partner Revenue Measurement, among anything else in local.common_tags)
# needs an explicit launch template with tag_specifications. No image_id,
# iam_instance_profile, or network_interfaces/subnet_id/security group: EKS
# rejects a node group launch template that sets any of those
# (CreateNodegroup's launchTemplate docs), and omitting them keeps the same
# AMI, instance profile and cluster security group resolution EKS performs
# with no launch template at all. instance_types stays on the node group
# itself (unaffected by this launch template, which defines no instance_type
# of its own) rather than moving here, which keeps room for more than one
# type later: EKS rejects a node group whose launch template AND instanceTypes
# both set an instance type.
#
# block_device_mappings replaces the node group's own disk_size, which the EKS
# API rejects outright once a launch template is attached. device_name,
# volume_type and delete_on_termination are measured off the implicit launch
# template EKS generates when no launch_template is set at all (live
# DescribeLaunchTemplateVersions on a deployment from #187): gp3, /dev/xvda,
# delete-on-termination enabled. encrypted is set explicitly rather than left
# to the region's EBS encryption-by-default setting, so node root volumes are
# encrypted at rest like every other storage layer the module creates. With no
# kms_key_id, EC2 uses the region's default EBS key (aws/ebs unless it has been
# changed). volume_size is left unset when var.node_disk_size
# is null so the volume still inherits the AMI snapshot's 20 GiB default
# instead of a hard-coded one.
#
# metadata_options matches that same implicit launch template's IMDS posture
# (IMDSv2 required, hop limit 1, instance metadata tags disabled) rather than
# the aws_launch_template resource's own defaults, so a future EKS default
# change cannot silently loosen it.

resource "aws_launch_template" "node" {
  count = var.create_eks && var.node_launch_template_enabled ? 1 : 0

  name_prefix = "${local.cluster_name}-node-"

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_size           = var.node_disk_size
      volume_type           = "gp3"
      encrypted             = "true"
      delete_on_termination = true
    }
  }

  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "disabled"
  }

  tag_specifications {
    resource_type = "instance"
    tags          = local.common_tags
  }

  tag_specifications {
    resource_type = "volume"
    tags          = local.common_tags
  }

  tag_specifications {
    resource_type = "network-interface"
    tags          = local.common_tags
  }

  tags = local.common_tags
}

# ── Managed node group ────────────────────────────────────────────────────────
# 3 nodes by default — enough for 6 pods at minimum replicas.
# HPA scales pods horizontally; Cluster Autoscaler (controllers.tf) adds/removes
# nodes between node_min and node_max as pod demand changes.
#
# update_config caps how many nodes a managed update takes down in parallel
# (for example a launch template version bump from a tag or node_disk_size
# change) at one. EKS also surges replacement nodes before it drains the old
# ones, so a rolling update needs spare EC2 quota and subnet IPs. Neither
# guarantees workload availability: that still depends on replica counts and
# PodDisruptionBudgets.
#
# Replacement is create-before-destroy. Some changes cannot be made to a
# running managed node group (instance_types, attaching the launch template,
# the node group's own disk_size), so Terraform replaces the group. With a
# fixed node_group_name it had to delete the old group first, because EKS
# rejects a second group with the same name in the cluster: every node went
# away before the new ones joined, a full outage (about 10 minutes measured
# live, about 4 to 5 of them with no response at all). node_group_name_prefix
# gives each group a unique, cluster-specific name, so Terraform creates the
# new group and waits for EKS to report it ACTIVE before it deletes the old
# one. The account needs EC2 quota and subnet IPs for both groups during the
# switch. Measured live on examples/small, the create-before-destroy
# replacement caused no full outage: about 2.5 minutes with fewer n8n pods and
# one 502. Deleting the old group is not a rolling update: EKS scales it to
# zero and cordons and drains all of its nodes at once (update_config does not
# apply), and it can terminate them after a timeout without waiting for
# PodDisruptionBudgets. Pods on the old nodes move to the new ones, and
# single-replica workloads and running executions can still be interrupted.
#
# create_before_destroy also applies to this resource's dependencies when they
# are replaced (Terraform propagates it). aws_eks_cluster.n8n and
# aws_iam_role.nodes have fixed names, so a change that replaces either one
# without renaming it now fails at create with a name conflict instead of
# destroying the old one first. A cluster_name change renames both, which
# avoids that collision. The one module input that replaces the cluster without renaming
# it is eks_secrets_encryption_enabled = true -> false (the AWS provider forces
# replacement when encryption_config is removed, because EKS cannot turn
# envelope encryption off): that plan now fails at apply instead of destroying
# the cluster and everything on it.

resource "aws_eks_node_group" "n8n" {
  count = var.create_eks ? 1 : 0

  cluster_name           = aws_eks_cluster.n8n[0].name
  node_group_name_prefix = "${local.cluster_name}-nodes-"
  node_role_arn          = aws_iam_role.nodes[0].arn
  subnet_ids             = local.private_subnets
  instance_types         = [var.node_instance_type]
  # The EKS API rejects disk_size outright once launch_template is set below,
  # so this only takes effect with the launch template disabled.
  disk_size = var.node_launch_template_enabled ? null : var.node_disk_size

  scaling_config {
    desired_size = var.node_desired
    min_size     = var.node_min
    max_size     = var.node_max
  }

  update_config {
    max_unavailable = 1
  }

  # Attaching the launch template sets launch_template.id, which the AWS
  # provider marks ForceNew: the first apply with
  # var.node_launch_template_enabled = true on an existing node group replaces
  # the whole group, create-before-destroy (see above). After that, a change to the launch
  # template's contents only bumps launch_template.version, which is NOT
  # ForceNew: EKS rolls it out via UpdateNodegroupVersion, honoring
  # update_config above, instead of a Terraform replacement.
  #
  # Detaching is not symmetric. The outer launch_template block is not
  # ForceNew and id is Optional+Computed, so removing the block can plan as an
  # in-place update that does not actually detach the template from the node
  # group. Disabling the toggle on an attached node group therefore needs an
  # explicit `terraform apply -replace` of this resource, which is again
  # create-before-destroy. See
  # var.node_launch_template_enabled and README.md → "AWS Partner Revenue
  # Measurement tag".
  dynamic "launch_template" {
    for_each = var.node_launch_template_enabled ? [1] : []

    content {
      id      = aws_launch_template.node[0].id
      version = aws_launch_template.node[0].latest_version
    }
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
  #
  # create_before_destroy: see the banner comment above this resource.
  lifecycle {
    create_before_destroy = true
    ignore_changes        = [scaling_config[0].desired_size]
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

# ── VPC CNI NetworkPolicy enforcement ──────────────────────────────────────────
# EKS bootstraps vpc-cni as a self-managed workload at cluster creation, so
# adopting it into an EKS-managed aws_eks_addon needs resolve_conflicts_on_create
# = "OVERWRITE" to take it over, the same shape examples/large/main.tf uses for
# its own WARM_ENI_TARGET/WARM_IP_TARGET tuning. Only one Terraform resource may
# own a given cluster's vpc-cni addon: do not combine this with a root module
# (examples/large included) that already manages its own aws_eks_addon for
# vpc-cni on the same cluster, see var.eks_network_policy_enabled's description.
#
# configuration_values.enableNetworkPolicy must be the string "true", not a
# JSON boolean, the addon's schema rejects a boolean here. AWS documents a
# minimum of Kubernetes 1.26.7 (platform eks.6) or 1.27.4 (eks.5);
# var.eks_network_policy_enabled's validation sets the module's floor at
# kubernetes_version 1.27. It checks the minor version only, not the patch
# or platform version; new clusters start on the latest platform version.
# addon_version is left unpinned (see docs/versioning.md), so EKS picks its
# default vpc-cni build for the cluster's Kubernetes version at creation.
# https://docs.aws.amazon.com/eks/latest/userguide/cni-network-policy-configure.html
#
# preserve = true: flipping var.eks_network_policy_enabled back to false
# destroys this resource, which otherwise calls EKS's DeleteAddon without
# preserving anything, removing the aws-node DaemonSet from a live cluster and
# cutting off pod networking for existing nodes and new ones alike. preserve
# tells DeleteAddon to leave the running vpc-cni DaemonSet and its
# configuration in place as a self-managed installation instead: only EKS's
# own management of the addon goes away, not vpc-cni itself. That retained
# configuration still has enableNetworkPolicy on, so opting out does not
# disable enforcement; the variable's description links AWS's procedure for
# that.
# https://docs.aws.amazon.com/eks/latest/APIReference/API_DeleteAddon.html
#
# Skipped when create_eks = false: check.existing_eks_cluster_needs_its_own_network_policy_toggle
# below warns if var.eks_network_policy_enabled is left true on that path.

resource "aws_eks_addon" "vpc_cni" {
  count = var.create_eks && var.eks_network_policy_enabled ? 1 : 0

  cluster_name                = aws_eks_cluster.n8n[0].name
  addon_name                  = "vpc-cni"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
  preserve                    = true

  configuration_values = jsonencode({
    enableNetworkPolicy = "true"
  })

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

# The same "X is ignored when Y" shape as existing_eks_cluster_needs_its_own_storage_toggle
# (storage.tf): unlike create_ebs_csi, aws_eks_addon.vpc_cni above is already
# gated on create_eks, so this combination creates nothing rather than failing
# outright, the warning exists purely so a caller who flips this toggle
# expecting NetworkPolicy enforcement on their existing cluster learns why
# nothing changed, instead of assuming the apply silently worked.
check "existing_eks_cluster_needs_its_own_network_policy_toggle" {
  assert {
    condition = var.create_eks ? true : !var.eks_network_policy_enabled
    error_message = join("", [
      "eks_network_policy_enabled = true while create_eks = false, so it is ignored: the module manages no ",
      "vpc-cni addon on an existing cluster, only aws_eks_addon.vpc_cni on the create_eks = true path (eks.tf). ",
      "Enable NetworkPolicy enforcement on ${coalesce(var.existing_eks_cluster_name, "the existing cluster")} by ",
      "adopting its vpc-cni addon yourself (configuration_values = {enableNetworkPolicy = \"true\"}), or ask its ",
      "owning team to.",
    ])
  }
}
